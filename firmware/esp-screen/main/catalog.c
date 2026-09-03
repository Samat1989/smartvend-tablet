#include "catalog.h"

#include <string.h>

#include "cJSON.h"
#include "cfg.h"
#include "cloud.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "catalog";

// Кэш лежит в своём разделе сырым блобом: заголовок и массив записей. Файловая
// система тут была бы лишним слоем — каталог всегда пишется целиком, читается
// целиком и переживать частичную запись ему не нужно.
#define CACHE_MAGIC 0x53435231u   // 'SCR1'

typedef struct {
    uint32_t magic;
    uint32_t count;
    uint32_t bytes;
    // Отпечаток лежит рядом с данными не ради экономии трафика, а чтобы после
    // перезагрузки не тянуть с сервера то, что и так лежит на флеше.
    char digest[40];
} cache_header_t;

static catalog_item_t s_items[CATALOG_MAX_ITEMS];
static int s_count;
static char s_digest[40];

// Каталог перезаписывает фоновая задача биения, а читают его сразу двое:
// задача LVGL (нумпад и корзина) и задача оформления заказа. Без замка
// покупатель мог поймать полузаписанную строку — половина имени от старого
// товара, uuid от нового. Оплата по такому uuid — уже деньги.
static SemaphoreHandle_t s_lock;

static void catalog_lock(void)
{
    if (s_lock) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
    }
}

static void catalog_unlock(void)
{
    if (s_lock) {
        xSemaphoreGive(s_lock);
    }
}

static const esp_partition_t *cache_partition(void)
{
    return esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS,
                                    "storage");
}

static void cache_save(void)
{
    const esp_partition_t *part = cache_partition();
    if (!part) {
        return;
    }
    cache_header_t hdr = {
        .magic = CACHE_MAGIC,
        .count = (uint32_t)s_count,
        .bytes = (uint32_t)(s_count * sizeof(catalog_item_t)),
    };
    strncpy(hdr.digest, s_digest, sizeof(hdr.digest) - 1);
    if (esp_partition_erase_range(part, 0, 4096) != ESP_OK) {
        return;
    }
    esp_partition_write(part, 0, &hdr, sizeof(hdr));
    esp_partition_write(part, sizeof(hdr), s_items, hdr.bytes);
    ESP_LOGI(TAG, "кэш записан: %d позиций", s_count);
}

esp_err_t catalog_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    const esp_partition_t *part = cache_partition();
    ESP_RETURN_ON_FALSE(part != NULL, ESP_ERR_NOT_FOUND, TAG, "нет раздела storage");

    cache_header_t hdr = {0};
    ESP_RETURN_ON_ERROR(esp_partition_read(part, 0, &hdr, sizeof(hdr)), TAG, "чтение кэша");
    if (hdr.magic != CACHE_MAGIC || hdr.count > CATALOG_MAX_ITEMS) {
        ESP_LOGI(TAG, "кэша нет — ждём первой загрузки с сервера");
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(esp_partition_read(part, sizeof(hdr), s_items, hdr.bytes), TAG, "кэш");
    s_count = (int)hdr.count;
    hdr.digest[sizeof(hdr.digest) - 1] = 0;
    strncpy(s_digest, hdr.digest, sizeof(s_digest) - 1);
    ESP_LOGI(TAG, "из кэша поднято %d позиций", s_count);
    return ESP_OK;
}

esp_err_t catalog_refresh(const char *digest)
{
    // ~110 байт на позицию; берём с запасом и в PSRAM, чтобы не отъедать
    // внутреннюю память, которая нужна TLS в момент оплаты.
    const size_t cap = 16 * 1024;
    char *body = heap_caps_malloc(cap, MALLOC_CAP_SPIRAM);
    ESP_RETURN_ON_FALSE(body != NULL, ESP_ERR_NO_MEM, TAG, "буфер ответа");

    esp_err_t err = cloud_fetch_catalog(body, cap);
    if (err != ESP_OK) {
        free(body);
        return err;
    }

    cJSON *root = cJSON_Parse(body);
    free(body);
    ESP_RETURN_ON_FALSE(cJSON_IsArray(root), ESP_ERR_INVALID_RESPONSE, TAG, "ответ не массив");

    catalog_lock();
    int n = 0;
    const cJSON *row = NULL;
    cJSON_ArrayForEach(row, root) {
        if (n >= CATALOG_MAX_ITEMS) {
            ESP_LOGW(TAG, "в машине больше %d позиций — лишние не поместятся на нумпад",
                     CATALOG_MAX_ITEMS);
            break;
        }
        const cJSON *cell = cJSON_GetObjectItem(row, "motor_id");
        const cJSON *id = cJSON_GetObjectItem(row, "id");
        const cJSON *name = cJSON_GetObjectItem(row, "name");
        const cJSON *price = cJSON_GetObjectItem(row, "price");
        const cJSON *stock = cJSON_GetObjectItem(row, "stock");
        if (!cJSON_IsNumber(cell) || !cJSON_IsString(id)) {
            continue;
        }

        catalog_item_t *item = &s_items[n++];
        memset(item, 0, sizeof(*item));
        item->cell = cell->valueint;
        strncpy(item->id, id->valuestring, CATALOG_UUID_LEN - 1);
        if (cJSON_IsString(name)) {
            strncpy(item->name, name->valuestring, CATALOG_NAME_LEN - 1);
        }
        // Цена приходит как numeric — в JSON это может быть и строка «1».
        item->price = cJSON_IsNumber(price) ? (int)price->valuedouble
                    : cJSON_IsString(price) ? atoi(price->valuestring)
                                            : 0;
        item->stock = cJSON_IsNumber(stock) ? stock->valueint : 0;
    }
    cJSON_Delete(root);

    s_count = n;
    if (digest) {
        strncpy(s_digest, digest, sizeof(s_digest) - 1);
    }
    ESP_LOGI(TAG, "каталог обновлён: %d позиций", s_count);
    cache_save();
    catalog_unlock();
    return ESP_OK;
}

const char *catalog_digest(void)
{
    return s_digest;
}

int catalog_count(void)
{
    return s_count;
}

bool catalog_get(int cell, catalog_item_t *out)
{
    bool found = false;
    catalog_lock();
    for (int i = 0; i < s_count; i++) {
        if (s_items[i].cell == cell) {
            *out = s_items[i];   // копия, а не указатель: строку могут переписать
            found = true;
            break;
        }
    }
    catalog_unlock();
    return found;
}

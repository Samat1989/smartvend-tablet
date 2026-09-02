#include "cloud.h"

#include <stdio.h>
#include <string.h>

#include "cfg.h"
#include "cJSON.h"
#include "esp_app_desc.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "cloud";

// Публичные и по замыслу: адрес проекта и publishable-ключ уезжают в каждый
// браузер, открывший витрину. Секрет машины сюда не входит — он приходит с
// сервера в device-provision и живёт только в NVS.
#define SUPABASE_URL "https://cgvfhtvdtdjsyluhlcbq.supabase.co"
#define SUPABASE_KEY "sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD"

// Двадцать пять секунд, а не пятнадцать.
//
// complete-order намеренно держит ответ около двенадцати секунд: он сам делает
// четыре попытки payment_result с паузой в три секунды и отвечает 503, пока
// оплаты нет. Пятнадцати секунд на это вместе с TLS-рукопожатием не хватало —
// запрос обрывался по таймауту (в логе «ответил -1»), попытка сгорала впустую,
// и покупатель ждал лишний круг.
#define HTTP_TIMEOUT_MS 25000
#define RESP_MAX 2048

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} resp_t;

// Одно живое соединение с Supabase на всё устройство.
//
// Раньше каждый запрос поднимал своё: TCP, TLS-рукопожатие, проверка цепочки
// сертификатов — на ESP32 это полторы-две секунды чистого ожидания, и платил их
// каждый вызов. Хуже всего это било по оплате: покупатель нажимал «Оплатить»,
// прошивка досинхронизировала каталог (рукопожатие), потом создавала заказ
// (ещё одно), и код появлялся на пару секунд позже, чем мог бы.
//
// Теперь handle один и живёт между запросами: пока сервер держит keep-alive,
// второй и следующие запросы уходят по готовому каналу. Побочный эффект —
// подготовка каталога в момент набора номера заодно прогревает соединение для
// оплаты.
//
// Мьютекс обязателен: в сеть ходят четыре задачи (пинг, досинхронизация
// каталога, создание заказа, опрос оплаты), а handle не потокобезопасен.
static SemaphoreHandle_t s_lock;
static esp_http_client_handle_t s_client;

static esp_err_t on_http_event(esp_http_client_event_t *evt)
{
    if (evt->event_id != HTTP_EVENT_ON_DATA) {
        return ESP_OK;
    }
    resp_t *r = evt->user_data;
    if (!r || !r->buf) {
        return ESP_OK;
    }
    const size_t room = r->cap - r->len - 1;
    const size_t take = (size_t)evt->data_len < room ? (size_t)evt->data_len : room;
    memcpy(r->buf + r->len, evt->data, take);
    r->len += take;
    r->buf[r->len] = 0;
    return ESP_OK;
}

// Один запрос к Supabase. body == NULL — это GET.
static int request(const char *url, const char *body, char *out, size_t out_size)
{
    resp_t resp = { .buf = out, .len = 0, .cap = out_size };
    if (out && out_size) {
        out[0] = 0;
    }

    if (!s_lock) {
        s_lock = xSemaphoreCreateMutex();
        if (!s_lock) {
            return -1;
        }
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);

    if (!s_client) {
        const esp_http_client_config_t cfg = {
            .url = url,
            .timeout_ms = HTTP_TIMEOUT_MS,
            .event_handler = on_http_event,
            .user_data = &resp,
            .crt_bundle_attach = esp_crt_bundle_attach,
            .keep_alive_enable = true,
        };
        s_client = esp_http_client_init(&cfg);
        if (!s_client) {
            xSemaphoreGive(s_lock);
            return -1;
        }
        esp_http_client_set_header(s_client, "apikey", SUPABASE_KEY);
        esp_http_client_set_header(s_client, "Authorization", "Bearer " SUPABASE_KEY);
    }

    esp_http_client_set_user_data(s_client, &resp);
    esp_http_client_set_url(s_client, url);
    esp_http_client_set_method(s_client, body ? HTTP_METHOD_POST : HTTP_METHOD_GET);
    if (body) {
        esp_http_client_set_header(s_client, "Content-Type", "application/json");
        esp_http_client_set_post_field(s_client, body, strlen(body));
    } else {
        // GET с телом от прошлого запроса ушёл бы с чужим Content-Length.
        esp_http_client_set_post_field(s_client, NULL, 0);
        esp_http_client_delete_header(s_client, "Content-Type");
    }

    // Одна повторная попытка — но только на обрыве, не на ответе сервера.
    // Сохранённое соединение сервер закрывает по своему таймауту в любой
    // момент, и узнаём мы об этом ровно в тот запрос, который в него попал.
    // Ошибка HTTP (4xx/5xx) — это ответ, повторять его нельзя: create-payment
    // на второй попытке завёл бы второй заказ.
    int status = -1;
    for (int attempt = 0; attempt < 2; attempt++) {
        const int64_t t0 = esp_timer_get_time();
        const esp_err_t err = esp_http_client_perform(s_client);
        const long long ms = (esp_timer_get_time() - t0) / 1000;
        if (err == ESP_OK) {
            status = esp_http_client_get_status_code(s_client);
            // Уровень INFO намеренно: время каждого запроса — единственный
            // способ понять по логу с точки, где именно тормозит оплата.
            ESP_LOGI(TAG, "%s → %d за %lld мс", url + sizeof(SUPABASE_URL) - 1, status, ms);
            break;
        }
        ESP_LOGW(TAG, "%s: %s за %lld мс%s", url, esp_err_to_name(err), ms,
                 attempt ? "" : ", соединение переоткрываем");
        resp.len = 0;
        if (out && out_size) {
            out[0] = 0;
        }
        esp_http_client_close(s_client);
    }

    xSemaphoreGive(s_lock);
    return status;
}

// Идентификатор устройства для claim_machine — MAC платы. Он же уезжает в
// device_ping: по нему сервер отличает «эту плату» от подменённой и умеет
// сказать «тебя отвязали в панели».
static const char *device_id(void)
{
    static char id[18];
    if (id[0] == 0) {
        uint8_t mac[6];
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        snprintf(id, sizeof(id), "%02x%02x%02x%02x%02x%02x",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    }
    return id;
}

int cloud_post(const char *path, const char *body, char *out, size_t out_size)
{
    char url[320];
    snprintf(url, sizeof(url), SUPABASE_URL "%s", path);
    return request(url, body, out, out_size);
}

pair_result_t cloud_pair(const char *machid)
{
    char url[192];
    char resp[RESP_MAX];
    char body[256];

    // 1. Секрет машины по её номеру. Монтажник его не вводит и не видит.
    snprintf(url, sizeof(url), SUPABASE_URL "/functions/v1/device-provision?machid=%s", machid);
    int status = request(url, NULL, resp, sizeof(resp));
    if (status < 0) {
        return PAIR_NETWORK;
    }
    if (status == 404) {
        return PAIR_NOT_FOUND;
    }
    if (status != 200) {
        return PAIR_NETWORK;
    }

    cJSON *json = cJSON_Parse(resp);
    const cJSON *secret_node = cJSON_GetObjectItem(json, "secret");
    if (!cJSON_IsString(secret_node) || secret_node->valuestring[0] == 0) {
        cJSON_Delete(json);
        return PAIR_NOT_FOUND;
    }
    char secret[64];
    strncpy(secret, secret_node->valuestring, sizeof(secret) - 1);
    secret[sizeof(secret) - 1] = 0;
    cJSON_Delete(json);

    // 2. Тип машины. Экран не должен вставать на вендинг или static-QR: там
    // другой платёжный поток, и молчаливая ошибка вскроется только на кассе.
    snprintf(body, sizeof(body), "{\"p_machid\":%s,\"p_secret\":\"%s\"}", machid, secret);
    snprintf(url, sizeof(url), SUPABASE_URL "/rest/v1/rpc/verify_pairing");
    status = request(url, body, resp, sizeof(resp));
    if (status < 0) {
        return PAIR_NETWORK;
    }
    if (status != 200) {
        return PAIR_NOT_FOUND;
    }
    if (!strstr(resp, "micromarket_screen")) {
        ESP_LOGW(TAG, "тип машины: %s", resp);
        return PAIR_WRONG_KIND;
    }

    // 3. Занимаем машину. Без этого device_ping не сможет сообщить об отвязке.
    snprintf(body, sizeof(body), "{\"p_machid\":%s,\"p_secret\":\"%s\",\"p_device_id\":\"%s\"}",
             machid, secret, device_id());
    snprintf(url, sizeof(url), SUPABASE_URL "/rest/v1/rpc/claim_machine");
    status = request(url, body, resp, sizeof(resp));
    if (status < 0) {
        return PAIR_NETWORK;
    }
    if (status != 200) {
        return PAIR_NETWORK;
    }
    if (strstr(resp, "\"ok\":false") || strstr(resp, "taken")) {
        return PAIR_TAKEN;
    }

    cfg_set("machid", machid);
    cfg_set("secret", secret);
    ESP_LOGI(TAG, "машина %s привязана", machid);
    return PAIR_OK;
}

esp_err_t cloud_ping(claim_state_t *claim_out, char *catalog_out, size_t catalog_size)
{
    char machid[16] = {0};
    char secret[64] = {0};
    if (cfg_get("machid", machid, sizeof(machid)) != ESP_OK ||
        cfg_get("secret", secret, sizeof(secret)) != ESP_OK) {
        return ESP_ERR_INVALID_STATE;
    }

    const esp_app_desc_t *app = esp_app_get_description();
    char body[320];
    snprintf(body, sizeof(body),
             "{\"p_machid\":%s,\"p_secret\":\"%s\",\"p_app_version\":\"%s\","
             "\"p_device_id\":\"%s\",\"p_board_ok\":true}",
             machid, secret, app->version, device_id());

    char resp[RESP_MAX];
    const int status = request(SUPABASE_URL "/rest/v1/rpc/device_ping", body, resp, sizeof(resp));
    if (status != 200) {
        return ESP_FAIL;
    }

    if (claim_out) {
        *claim_out = strstr(resp, "\"claim\":\"lost\"")     ? CLAIM_LOST
                   : strstr(resp, "\"claim\":\"released\"") ? CLAIM_RELEASED
                                                            : CLAIM_OK;
    }
    if (catalog_out && catalog_size) {
        catalog_out[0] = 0;
        cJSON *json = cJSON_Parse(resp);
        const cJSON *cat = cJSON_GetObjectItem(json, "catalog");
        if (cJSON_IsString(cat)) {
            strncpy(catalog_out, cat->valuestring, catalog_size - 1);
            catalog_out[catalog_size - 1] = 0;
        }
        cJSON_Delete(json);
    }
    return ESP_OK;
}

esp_err_t cloud_fetch_catalog(char *out, size_t out_size)
{
    char machid[16] = {0};
    if (cfg_get("machid", machid, sizeof(machid)) != ESP_OK) {
        return ESP_ERR_INVALID_STATE;
    }

    // Фильтр motor_id=not.is.null здесь и в отпечатке device_ping — одно и то
    // же условие. Разъедутся — устройство либо перестанет видеть правки, либо
    // будет грузить каталог вечно.
    char url[320];
    snprintf(url, sizeof(url),
             SUPABASE_URL "/rest/v1/inventory?micromarket_id=eq.%s&motor_id=not.is.null"
             "&select=motor_id,id,name,price,stock&order=motor_id",
             machid);

    const int status = request(url, NULL, out, out_size);
    if (status != 200) {
        ESP_LOGW(TAG, "каталог не отдан, код %d", status);
        return ESP_FAIL;
    }
    return ESP_OK;
}

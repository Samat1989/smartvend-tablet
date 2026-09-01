#include "payment.h"

#include <stdio.h>
#include <string.h>

#include "cart.h"
#include "catalog.h"
#include "cfg.h"
#include "cJSON.h"
#include "cloud.h"
#include "esp_log.h"

static const char *TAG = "payment";

esp_err_t payment_create(payment_t *out)
{
    char machid[16] = {0};
    if (cfg_get("machid", machid, sizeof(machid)) != ESP_OK) {
        return ESP_ERR_INVALID_STATE;
    }

    // Состав отдаём по uuid строк инвентаря: create-payment принимает только
    // их. Каталог перед этим перечитан (см. ui_shop), поэтому uuid свежие даже
    // если оператор только что перевесил номер ячейки на другой товар.
    char items[512] = "[";
    size_t len = 1;
    for (int i = 0; i < cart_lines(); i++) {
        const cart_line_t *line = cart_line(i);
        catalog_item_t item;
        if (!catalog_get(line->cell, &item)) {
            continue;
        }
        len += (size_t)snprintf(items + len, sizeof(items) - len, "%s{\"id\":\"%s\",\"count\":%d}",
                                len > 1 ? "," : "", item.id, line->count);
        if (len >= sizeof(items) - 64) {
            break;
        }
    }
    snprintf(items + len, sizeof(items) - len, "]");

    char body[640];
    // marketId, а не token: qr_token устройству не нужен, номер аппарата у него
    // и так есть. Ветка legacy в create-payment, но для экрана она несущая.
    snprintf(body, sizeof(body), "{\"marketId\":%s,\"items\":%s}", machid, items);

    char resp[768];
    const int status = cloud_post("/functions/v1/create-payment", body, resp, sizeof(resp));
    if (status != 200) {
        ESP_LOGE(TAG, "заказ не создан, код %d: %s", status, resp);
        return ESP_FAIL;
    }

    cJSON *json = cJSON_Parse(resp);
    const cJSON *url = cJSON_GetObjectItem(json, "paymentUrl");
    const cJSON *orderid = cJSON_GetObjectItem(json, "orderid");
    if (!cJSON_IsString(url) || !cJSON_IsString(orderid)) {
        cJSON_Delete(json);
        return ESP_ERR_INVALID_RESPONSE;
    }
    memset(out, 0, sizeof(*out));
    strncpy(out->url, url->valuestring, PAYMENT_URL_LEN - 1);
    strncpy(out->orderid, orderid->valuestring, PAYMENT_ORDERID_LEN - 1);
    cJSON_Delete(json);

    ESP_LOGI(TAG, "заказ %s создан", out->orderid);
    return ESP_OK;
}

payment_state_t payment_poll(const char *orderid)
{
    char body[128];
    snprintf(body, sizeof(body), "{\"orderid\":\"%s\"}", orderid);

    char resp[256];
    const int status = cloud_post("/functions/v1/complete-order", body, resp, sizeof(resp));
    switch (status) {
    case 200:
        ESP_LOGI(TAG, "заказ %s оплачен", orderid);
        return PAYMENT_PAID;
    case 503:
        return PAYMENT_WAITING;
    case 404:
        // Заказа нет в базе — открывать замок нельзя ни при каких условиях.
        ESP_LOGE(TAG, "заказ %s серверу неизвестен", orderid);
        return PAYMENT_UNKNOWN;
    default:
        ESP_LOGW(TAG, "complete-order ответил %d", status);
        return PAYMENT_ERROR;
    }
}

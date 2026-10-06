#include "beat.h"

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sb_realtime.h"
#include "store.h"

static const char *TAG = "beat";

#define FIRST_BEAT_MS   20000UL           // soon after the first join
#define BEAT_EVERY_MS   (15UL * 60 * 1000)
#define RETRY_MS        60000UL           // failed beat: try again in a minute

static bool send_beat(void) {
    char body[192];
    snprintf(body, sizeof(body), "{\"p_topic\":\"%s\",\"p_key\":\"%s\",\"p_ver\":\"%s\"}",
             g_cfg.rt_topic, g_cfg.rt_key, FW_VERSION_NAME);
    esp_http_client_config_t c = {
        .url = "https://" SUPABASE_HOST "/rest/v1/rpc/device_beat",
        .method = HTTP_METHOD_POST,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 20000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&c);
    if (!cli) return false;
    esp_http_client_set_header(cli, "apikey", SUPABASE_KEY);
    esp_http_client_set_header(cli, "Authorization", "Bearer " SUPABASE_KEY);
    esp_http_client_set_header(cli, "Content-Type", "application/json");
    esp_http_client_set_post_field(cli, body, strlen(body));
    esp_err_t err = esp_http_client_perform(cli);
    int status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);
    if (err != ESP_OK || status != 200) {
        ESP_LOGW(TAG, "beat failed: %s, HTTP %d", esp_err_to_name(err), status);
        return false;
    }
    ESP_LOGI(TAG, "beat ok (free heap %lu)", (unsigned long)esp_get_free_heap_size());
    return true;
}

static void beat_task(void *pv) {
    vTaskDelay(pdMS_TO_TICKS(FIRST_BEAT_MS));
    while (true) {
        // Not in the channel means the link is down or coming back; a beat over
        // the same dead link would only time out, so wait for the join.
        if (!sbrt_joined()) { vTaskDelay(pdMS_TO_TICKS(5000)); continue; }
        bool ok = send_beat();
        vTaskDelay(pdMS_TO_TICKS(ok ? BEAT_EVERY_MS : RETRY_MS));
    }
}

void beat_start(void) {
    xTaskCreate(beat_task, "beat", 6144, NULL, 3, NULL);
}

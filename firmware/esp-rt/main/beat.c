#include "beat.h"

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "cJSON.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "pair.h"
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
    char resp[96];
    int status = 0;
    esp_err_t err = rpc_post("device_beat", body, resp, sizeof(resp), &status);
    if (err != ESP_OK || status != 200) {
        ESP_LOGW(TAG, "beat failed: %s, HTTP %d", esp_err_to_name(err), status);
        return false;
    }
    cJSON *root = cJSON_Parse(resp);
    bool ok = cJSON_IsTrue(cJSON_GetObjectItem(root, "ok"));
    cJSON_Delete(root);
    if (!ok) {
        // The server does not know this channel any more: the owner unpaired
        // the board. Forget the credentials and start over (setup portal).
        ESP_LOGW(TAG, "unpaired on the server — rebooting");
        store_erase("rt_topic");
        store_erase("rt_key");
        vTaskDelay(pdMS_TO_TICKS(500));
        esp_restart();
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

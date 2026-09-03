#include "cfg.h"

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"

#define CFG_NAMESPACE "screen"

static const char *TAG = "cfg";

esp_err_t cfg_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        // Раздел от прошивки с другой раскладкой — стираем, иначе первый же
        // cfg_get будет возвращать ошибку навсегда.
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    return err;
}

esp_err_t cfg_get(const char *key, char *out, size_t out_size)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(CFG_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_get_str(h, key, out, &out_size);
    nvs_close(h);
    return err;
}

esp_err_t cfg_set(const char *key, const char *value)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(CFG_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_str(h, key, value);
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    ESP_LOGI(TAG, "сохранено %s", key);
    return err;
}

esp_err_t cfg_erase(const char *key)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(CFG_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_erase_key(h, key);
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

bool cfg_is_paired(void)
{
    char buf[64];
    if (cfg_get("machid", buf, sizeof(buf)) != ESP_OK || buf[0] == 0) {
        return false;
    }
    if (cfg_get("secret", buf, sizeof(buf)) != ESP_OK || buf[0] == 0) {
        return false;
    }
    return true;
}

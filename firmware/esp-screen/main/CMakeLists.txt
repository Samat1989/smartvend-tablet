idf_component_register(SRCS "main.c" "panel_qspi.c" "display.c" "cfg.c" "net.c" "cloud.c" "catalog.c" "cart.c" "payment.c" "lock.c" "heartbeat.c" "ui_setup.c" "ui_home.c" "ui_shop.c" "ui_font_20.c" "ui_font_28.c" "ui_font_40.c"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES nvs_flash esp_partition esp_psram app_update esp_timer spi_flash esp_lcd driver esp_wifi esp_event esp_netif esp_http_client esp-tls json mbedtls)

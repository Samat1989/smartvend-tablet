idf_component_register(SRCS "main.c" "board.c" "store.c" "net.c" "portal.c" "pair.c" "app.c" "ota.c"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES sb_realtime json esp_wifi esp_event esp_netif nvs_flash driver
                                  esp_http_client esp_http_server esp_https_ota app_update mbedtls)

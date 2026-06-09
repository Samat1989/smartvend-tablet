idf_component_register(SRCS "main.c"
                    INCLUDE_DIRS "."
                    PRIV_REQUIRES mqtt json esp_wifi esp_event esp_netif nvs_flash driver esp_http_client esp_http_server)

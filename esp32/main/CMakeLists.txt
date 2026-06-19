idf_component_register(SRCS   "main.c"
                              "nus.c"
                              "nus_protocol.c"
                              "nav_model.c"
                              "map_model.c"
                              "clock_model.c"
                              "projection.c"
                              "display.c"
                             
                              "lv_font_vi_12.c"
                    PRIV_REQUIRES bt nvs_flash esp_lcd driver esp_timer spiffs lvgl
                    INCLUDE_DIRS ".")

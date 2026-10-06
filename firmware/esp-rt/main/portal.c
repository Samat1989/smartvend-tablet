#include "portal.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "board.h"
#include "config.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "net.h"
#include "store.h"

static const char *TAG = "portal";

#define PORTAL_TIMEOUT_MS 180000
#define SCAN_MAX_APS 16
#define SCAN_TTL_MS  60000

static volatile bool s_activity, s_committing;
static char *s_rows;
static TickType_t s_rows_at;

static void touch(void) { s_activity = true; }

static void reboot_soon(void *pv) {
    vTaskDelay(pdMS_TO_TICKS(2500));   // let the reply reach the phone
    lock_close();
    esp_restart();
}

// The portal is an open AP: a board forgotten in setup mode can be reconfigured
// by anyone nearby. After 3 min without a request it reboots to normal mode.
static void timeout_task(void *pv) {
    int idle = 0;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (s_activity || s_committing) { s_activity = false; idle = 0; continue; }
        if ((idle += 1000) >= PORTAL_TIMEOUT_MS) {
            ESP_LOGW(TAG, "idle — rebooting to normal mode");
            lock_close();
            esp_restart();
        }
    }
}

static const char PAGE_HEAD[] =
    "<!DOCTYPE html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>SmartVend Setup</title><style>"
    "*{box-sizing:border-box}"
    "body{font-family:system-ui,-apple-system,sans-serif;background:#0f172a;color:#e2e8f0;margin:0 auto;padding:22px;max-width:460px}"
    "h2{font-size:19px;font-weight:600;margin:0 0 18px}"
    ".lbl{display:block;margin:16px 0 6px;font-size:13px;color:#94a3b8}"
    "input{width:100%;padding:12px;border-radius:10px;border:1px solid #334155;background:#1e293b;color:#fff;font-size:16px}"
    ".net{display:flex;align-items:center;gap:12px;padding:12px 14px;margin-bottom:8px;border:1px solid #334155;border-radius:10px;background:#1e293b;cursor:pointer}"
    ".net input{display:none}"
    ".net:has(:checked){border-color:#F14635;background:#3a2020}"
    ".net input:checked~.nm{color:#F14635;font-weight:600}"
    ".nm{flex:1;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;font-size:15px}"
    ".net i{font-style:normal;color:#22c55e}"
    ".err{margin:0 0 14px;padding:12px;border-radius:10px;background:#3a2020;color:#fca5a5;font-size:14px}"
    ".ok{margin:0 0 14px;padding:12px;border-radius:10px;background:#123024;color:#86efac;font-size:14px}"
    "button{width:100%;margin-top:22px;padding:14px;border:none;border-radius:10px;background:#F14635;color:#fff;font-size:16px;font-weight:600}"
    "button[disabled]{background:#6b2b23}"
    "</style></head><body><h2>SmartVend — настройка</h2>";

static const char PAGE_FORM_A[] =
    "<form id=f method=POST action=/save>"
    "<span class=lbl>Способ связи</span>"
    "<label class=net><input type=radio name=netmode value=wifi onclick=m()><span class=nm>WiFi</span></label>"
    "<label class=net><input type=radio name=netmode value=gsm checked onclick=m()><span class=nm>GSM (SIM / LTE)</span></label>"
    "<div id=w style=display:none><span class=lbl>WiFi сеть</span>";
// network rows here
static const char PAGE_FORM_B[] =
    "<span class=lbl>WiFi пароль</span><input name=pass type=password></div>"
    "<span class=lbl>Номер аппарата</span>"
    "<input name=machid required inputmode=numeric pattern='[0-9]+' value=\"";
// machid here
static const char PAGE_FORM_C[] =
    "\"><span class=lbl>Код привязки из панели (6 цифр)</span>"
    "<input name=code inputmode=numeric pattern='[0-9]{6}' maxlength=6 autocomplete=off";
// " required" or a placeholder here
static const char PAGE_FORM_D[] =
    "><span class=lbl>Время открытия замка, сек</span>"
    "<input name=opensec type=number min=1 max=600 inputmode=numeric value='";
// opensec here
static const char PAGE_TAIL[] =
    "'><button id=sb type=submit>Сохранить</button></form>"
    "<script>function m(){var g=document.querySelector('input[name=netmode]:checked').value=='gsm';"
    "document.getElementById('w').style.display=g?'none':'';"
    "document.querySelectorAll('#w input[type=radio]').forEach(function(x){x.required=!g})}m();"
    "document.getElementById('f').addEventListener('submit',function(){setTimeout(function(){"
    "var b=document.getElementById('sb');b.disabled=true;b.textContent='Сохраняем…'},0)});"
    "</script></body></html>";

static void scan_refresh(void) {
    TickType_t now = xTaskGetTickCount();
    if (s_rows && now - s_rows_at < pdMS_TO_TICKS(SCAN_TTL_MS)) return;
    wifi_scan_config_t sc = { .show_hidden = false };
    if (esp_wifi_scan_start(&sc, true) != ESP_OK) return;
    uint16_t n = SCAN_MAX_APS;
    wifi_ap_record_t recs[SCAN_MAX_APS];
    if (esp_wifi_scan_get_ap_records(&n, recs) != ESP_OK || n == 0) return;
    size_t cap = (size_t)n * 192 + 1, len = 0;
    char *buf = malloc(cap);
    if (!buf) return;
    for (uint16_t i = 0; i < n; i++) {
        const char *ssid = (const char *)recs[i].ssid;
        if (!ssid[0] || strpbrk(ssid, "\"<&")) continue;
        bool dup = false;
        for (uint16_t j = 0; j < i && !dup; j++) dup = strcmp((const char *)recs[j].ssid, ssid) == 0;
        if (dup) continue;
        int r = recs[i].rssi;
        const char *bars = r >= -55 ? "▂▄▆█" : r >= -65 ? "▂▄▆" : r >= -72 ? "▂▄" : "▂";
        int w = snprintf(buf + len, cap - len,
                         "<label class=net><input type=radio name=ssid value=\"%s\"><span class=nm>%s</span><i>%s</i></label>",
                         ssid, ssid, bars);
        if (w < 0 || (size_t)w >= cap - len) break;
        len += w;
    }
    buf[len] = 0;
    free(s_rows);
    s_rows = buf;
    s_rows_at = now;
}

static esp_err_t root_get(httpd_req_t *req) {
    touch();
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_sendstr_chunk(req, PAGE_HEAD);
    if (g_cfg.pair_error) {
        httpd_resp_sendstr_chunk(req, "<p class=err>Код привязки не принят: он неверный или истёк. "
                                      "Получите новый код в панели («Привязать плату») и введите его ещё раз.</p>");
    } else if (store_paired()) {
        httpd_resp_sendstr_chunk(req, "<p class=ok>Плата привязана. Чтобы сменить только связь, "
                                      "оставьте код пустым.</p>");
    }
    httpd_resp_sendstr_chunk(req, PAGE_FORM_A);
    scan_refresh();
    if (s_rows && s_rows[0]) httpd_resp_sendstr_chunk(req, s_rows);
    httpd_resp_sendstr_chunk(req, PAGE_FORM_B);
    // A zero-length chunk would end the chunked response: send only when set.
    if (g_cfg.machid[0]) httpd_resp_sendstr_chunk(req, g_cfg.machid);
    httpd_resp_sendstr_chunk(req, PAGE_FORM_C);
    httpd_resp_sendstr_chunk(req, store_paired() ? " placeholder='не менять'" : " required");
    httpd_resp_sendstr_chunk(req, PAGE_FORM_D);
    char os[8];
    snprintf(os, sizeof(os), "%d", g_cfg.opensec);
    httpd_resp_sendstr_chunk(req, os);
    httpd_resp_sendstr_chunk(req, PAGE_TAIL);
    httpd_resp_sendstr_chunk(req, NULL);
    return ESP_OK;
}

static esp_err_t send_msg(httpd_req_t *req, const char *title, const char *body) {
    char page[1024];
    snprintf(page, sizeof(page),
             "<!DOCTYPE html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
             "<style>body{font-family:sans-serif;background:#1f2937;color:#fff;padding:24px;text-align:center}"
             "a{color:#F14635}</style></head><body><h2>%s</h2><p>%s</p></body></html>", title, body);
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, page, HTTPD_RESP_USE_STRLEN);
}

static void url_decode(const char *src, char *dst, size_t sz) {
    size_t di = 0;
    for (size_t i = 0; src[i] && di + 1 < sz; i++) {
        if (src[i] == '%' && isxdigit((unsigned char)src[i + 1]) && isxdigit((unsigned char)src[i + 2])) {
            char h[3] = { src[i + 1], src[i + 2], 0 };
            dst[di++] = (char)strtol(h, NULL, 16);
            i += 2;
        } else {
            dst[di++] = src[i] == '+' ? ' ' : src[i];
        }
    }
    dst[di] = 0;
}

static void form_field(const char *body, const char *name, char *out, size_t sz) {
    out[0] = 0;
    char key[24];
    snprintf(key, sizeof(key), "%s=", name);
    const char *p = body;
    // Match at the start or right after '&' so "pass" never matches inside "xpass".
    while ((p = strstr(p, key)) && p != body && p[-1] != '&') p++;
    if (!p) return;
    p += strlen(key);
    const char *end = strchr(p, '&');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    char raw[160];
    if (len >= sizeof(raw)) len = sizeof(raw) - 1;
    memcpy(raw, p, len);
    raw[len] = 0;
    url_decode(raw, out, sz);
}

static bool all_digits(const char *s) {
    if (!*s) return false;
    for (; *s; s++) if (!isdigit((unsigned char)*s)) return false;
    return true;
}

static esp_err_t save_post(httpd_req_t *req) {
    touch();
    s_committing = true;
    char body[640];
    int len = httpd_req_recv(req, body, sizeof(body) - 1);
    if (len <= 0) { s_committing = false; return ESP_FAIL; }
    body[len] = 0;

    char netmode[8], ssid[64], pass[64], machid[16], code[12], opensec[8];
    form_field(body, "netmode", netmode, sizeof(netmode));
    form_field(body, "ssid", ssid, sizeof(ssid));
    form_field(body, "pass", pass, sizeof(pass));
    form_field(body, "machid", machid, sizeof(machid));
    form_field(body, "code", code, sizeof(code));
    form_field(body, "opensec", opensec, sizeof(opensec));
    bool wifi = strcmp(netmode, "wifi") == 0;

    if (!all_digits(machid)) {
        s_committing = false;
        return send_msg(req, "Ошибка", "Впишите номер аппарата цифрами. <a href=/>Назад</a>");
    }
    // A new machine number always needs a new code; the same one may keep its
    // pairing when only the connection changes.
    bool same_machine = strcmp(machid, g_cfg.machid) == 0 && store_paired() && !g_cfg.pair_error;
    if (code[0] ? !(strlen(code) == 6 && all_digits(code)) : !same_machine) {
        s_committing = false;
        return send_msg(req, "Ошибка", "Введите 6-значный код привязки из панели. <a href=/>Назад</a>");
    }
    if (wifi) {
        if (!ssid[0]) { s_committing = false; return send_msg(req, "Ошибка", "Выберите сеть. <a href=/>Назад</a>"); }
        if (!net_wifi_try(ssid, pass)) {
            s_committing = false;
            return send_msg(req, "WiFi не подключился", "Проверьте сеть и пароль. <a href=/>Назад</a>");
        }
    }

    int os = atoi(opensec);
    if (os < 1 || os > 600) os = DEFAULT_OPEN_SECONDS;
    store_set_str("netmode", wifi ? "wifi" : "gsm");
    store_set_str("ssid", wifi ? ssid : "");
    store_set_str("pass", wifi ? pass : "");
    store_set_str("machid", machid);
    store_set_int("opensec", os);
    store_set_int("pairerr", 0);
    if (code[0]) {
        store_set_str("code", code);
        store_erase("rt_topic");   // the old pairing ends here
        store_erase("rt_key");
    }
    ESP_LOGI(TAG, "saved: %s machid=%s code=%s", wifi ? "wifi" : "gsm", machid, code[0] ? "new" : "kept");
    send_msg(req, "Готово",
             code[0] ? "Плата перезагрузится, выйдет в сеть и привяжется к аппарату. "
                       "По GSM это 30–60 секунд. Если код не подойдёт, точка настройки откроется снова."
                     : "Плата перезагрузится с новыми настройками связи.");
    xTaskCreate(reboot_soon, "reboot", 2048, NULL, 5, NULL);
    return ESP_OK;
}

static esp_err_t captive_redirect(httpd_req_t *req, httpd_err_code_t err) {
    touch();
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "http://192.168.4.1/");
    return httpd_resp_send(req, NULL, 0);
}

// Answers every DNS query with 192.168.4.1 so the phone opens the captive page.
static void dns_task(void *pv) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(53), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (sock < 0 || bind(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) { vTaskDelete(NULL); return; }
    uint8_t buf[512];
    while (true) {
        struct sockaddr_in cl;
        socklen_t cll = sizeof(cl);
        int len = recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr *)&cl, &cll);
        if (len < 12 || (size_t)len + 16 > sizeof(buf)) continue;
        buf[2] = 0x81; buf[3] = 0x80;
        buf[6] = 0x00; buf[7] = 0x01;
        const uint8_t ans[16] = { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 0x3C, 0, 4, 192, 168, 4, 1 };
        memcpy(buf + len, ans, sizeof(ans));
        sendto(sock, buf, len + sizeof(ans), 0, (struct sockaddr *)&cl, cll);
    }
}

void portal_start(bool can_time_out) {
    led_set_portal(true);
#if !CONFIG_ESPRT_LOCK_RELAY
    // Pulse boards keep the lock line open while in setup so the installer can
    // check the mechanism without the cloud (same as esp-pulse). Every exit is
    // a reboot through lock_close().
    lock_open();
#endif
    net_portal_mode();
    esp_netif_t *ap = esp_netif_create_default_wifi_ap();
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));

    esp_netif_dns_info_t dns = {0};
    dns.ip.type = ESP_IPADDR_TYPE_V4;
    esp_ip4_addr_t apip;
    esp_netif_str_to_ip4("192.168.4.1", &apip);
    dns.ip.u_addr.ip4.addr = apip.addr;
    esp_netif_dhcps_stop(ap);
    esp_netif_set_dns_info(ap, ESP_NETIF_DNS_MAIN, &dns);
    uint8_t offer_dns = 0x02;
    esp_netif_dhcps_option(ap, ESP_NETIF_OP_SET, ESP_NETIF_DOMAIN_NAME_SERVER, &offer_dns, sizeof(offer_dns));
    esp_netif_dhcps_start(ap);

    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_AP, mac);
    wifi_config_t apc = {0};
    snprintf((char *)apc.ap.ssid, sizeof(apc.ap.ssid), "SmartVend-Setup-%02X%02X", mac[4], mac[5]);
    apc.ap.ssid_len = strlen((char *)apc.ap.ssid);
    apc.ap.authmode = WIFI_AUTH_OPEN;
    apc.ap.max_connection = 2;
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &apc));
    ESP_ERROR_CHECK(esp_wifi_start());
    esp_wifi_set_ps(WIFI_PS_NONE);
    ESP_LOGI(TAG, "AP '%s' — open http://192.168.4.1", apc.ap.ssid);

    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    hc.stack_size = 8192;
    hc.lru_purge_enable = true;
    httpd_handle_t srv = NULL;
    if (httpd_start(&srv, &hc) == ESP_OK) {
        httpd_uri_t root = { .uri = "/", .method = HTTP_GET, .handler = root_get };
        httpd_uri_t save = { .uri = "/save", .method = HTTP_POST, .handler = save_post };
        httpd_register_uri_handler(srv, &root);
        httpd_register_uri_handler(srv, &save);
        httpd_register_err_handler(srv, HTTPD_404_NOT_FOUND, captive_redirect);
    }
    xTaskCreate(dns_task, "dns", 4096, NULL, 5, NULL);
    if (can_time_out) xTaskCreate(timeout_task, "portal_to", 2560, NULL, 4, NULL);
}

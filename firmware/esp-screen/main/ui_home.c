#include "ui_home.h"

#include <stdio.h>

#include "board.h"
#include "cfg.h"
#include "display.h"
#include "lvgl.h"
#include "ui_fonts.h"
#include "ui_setup.h"

static lv_obj_t *s_status;

void ui_home_show(void)
{
    lv_obj_t *scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0D1117), 0);
    lv_obj_set_style_pad_all(scr, 0, 0);
    lv_obj_set_style_border_width(scr, 0, 0);

    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "Микромаркет");
    lv_obj_set_style_text_color(title, lv_color_hex(0xE6EDF3), 0);
    lv_obj_set_style_text_font(title, &ui_font_40, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 60);

    // Номер аппарата на виду: сервисному инженеру не нужно лезть в панель,
    // чтобы понять, к какой машине он подошёл.
    char machid[16] = {0};
    cfg_get("machid", machid, sizeof(machid));
    lv_obj_t *num = lv_label_create(scr);
    lv_label_set_text_fmt(num, "Аппарат %s", machid[0] ? machid : "—");
    lv_obj_set_style_text_color(num, lv_color_hex(0x8B949E), 0);
    lv_obj_align(num, LV_ALIGN_TOP_MID, 0, 110);

    lv_obj_t *hint = lv_label_create(scr);
    lv_label_set_text(hint, "Каталог загружается");
    lv_obj_set_style_text_color(hint, lv_color_hex(0x8B949E), 0);
    lv_obj_align(hint, LV_ALIGN_CENTER, 0, 0);

    s_status = lv_label_create(scr);
    lv_label_set_text(s_status, "");
    lv_obj_set_style_text_color(s_status, lv_color_hex(0x6E7681), 0);
    lv_obj_align(s_status, LV_ALIGN_BOTTOM_MID, 0, -16);

    display_load_screen(scr);
    ui_setup_attach_service_corner();
}

void ui_home_set_status(const char *text)
{
    if (!s_status || !display_lock(200)) {
        return;
    }
    lv_label_set_text(s_status, text ? text : "");
    display_unlock();
}

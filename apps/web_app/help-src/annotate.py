#!/usr/bin/env python3
"""Рисует номерные выноски ①②③ на скриншотах инструкции.

Исходники (чистые кадры) лежат в help-src/img-raw/, результат кладётся в
public/help/img/. Скрипт идемпотентен: он всегда читает img-raw, поэтому его
можно гонять сколько угодно раз, а координаты выносок править по месту.

Номера соответствуют подписям под картинкой в src/help/content/*/NN-*.md —
меняете список подписей, меняйте и координаты здесь.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent
RAW = ROOT / 'img-raw'
OUT = ROOT.parent / 'public' / 'help' / 'img'
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'

BADGE_FILL = (37, 99, 235)      # синий, как акцент панели
BADGE_RING = (255, 255, 255)    # белое кольцо — читается и на тёмном экране
BADGE_TEXT = (255, 255, 255)

# image -> (радиус значка, [(номер, x, y) — центр значка])
SHOTS = {
    'panel-login.png': (15, [
        (1, 362, 172), (2, 362, 258), (3, 358, 320),
    ]),
    'panel-sales.png': (20, [
        (1, 1345, 155), (2, 1478, 155), (3, 1820, 152), (4, 40, 240),
    ]),
    'panel-devices.png': (20, [
        (1, 1178, 458), (2, 1345, 462), (3, 1650, 458), (4, 1650, 617),
    ]),
    'panel-inventory-screen.png': (20, [
        (1, 58, 208), (2, 1487, 290), (3, 56, 398), (4, 75, 538),
        (5, 395, 588), (6, 1600, 526), (7, 1700, 526),
    ]),
    'panel-inventory-edit.png': (16, [
        (1, 40, 143), (2, 38, 325), (3, 38, 558), (4, 325, 558),
    ]),
    'panel-catalog.png': (20, [
        (1, 56, 378), (2, 1002, 243), (3, 1570, 553),
    ]),
    'panel-product-modal.png': (17, [
        (1, 52, 231), (2, 243, 190), (3, 243, 281),
        (4, 52, 420), (5, 402, 420), (6, 52, 578),
    ]),
    'panel-users.png': (20, [
        (1, 48, 278), (2, 1683, 250), (3, 1772, 252), (4, 1856, 252),
        (5, 1455, 147),
    ]),
    'tablet-home.png': (26, [
        (1, 215, 148), (2, 240, 540), (3, 275, 195),
        (4, 1090, 940), (5, 1100, 1878),
    ]),
    'tablet-cart.png': (26, [
        (1, 98, 330), (2, 505, 1790), (3, 905, 1851), (4, 1075, 168),
    ]),
    'tablet-payment.png': (26, [
        (1, 480, 512), (2, 735, 626), (3, 150, 1075), (4, 525, 1564),
    ]),
    'tablet-pairing.png': (26, [
        (1, 272, 1041), (2, 272, 1140), (3, 272, 1247), (4, 272, 1373),
    ]),
    'tablet-login.png': (26, [
        (1, 268, 268),
    ]),
    'tablet-board.png': (26, [
        (1, 35, 205), (2, 232, 417), (3, 40, 535), (4, 175, 758), (5, 200, 901),
    ]),
}

# Подсветка цели: овал вокруг элемента, по которому надо нажимать.
# image -> [(x0, y0, x1, y1)]
RINGS = {
    'tablet-login.png': [(296, 296, 504, 444)],
}

# Кадры админского раздела сняты на живом аккаунте: почты владельцев и выданные
# им пароли не должны уехать в публичную папку. Замазываем до отрисовки выносок.
REDACT = {
    'panel-users.png': [
        (128, y - 24, 460, y + 22)
        for y in (278, 366, 454, 542, 630, 718, 806, 894, 960)
    ] + [(1680, 52, 1830, 80)],
}

RENAMES = {'panel-inventory-vending.png': 'panel-inventory-screen.png'}


def pixelate(img, box, block=12):
    x0, y0, x1, y1 = box
    x1, y1 = min(x1, img.width), min(y1, img.height)
    if x1 <= x0 or y1 <= y0:
        return
    crop = img.crop((x0, y0, x1, y1))
    small = crop.resize((max(1, crop.width // block), max(1, crop.height // block)), Image.BILINEAR)
    img.paste(small.resize(crop.size, Image.NEAREST), (x0, y0))


def ring(draw, box):
    x0, y0, x1, y1 = box
    draw.ellipse((x0 - 4, y0 - 4, x1 + 4, y1 + 4), outline=BADGE_RING, width=10)
    draw.ellipse(box, outline=BADGE_FILL, width=5)


def badge(draw, n, x, y, r, font):
    draw.ellipse((x - r - 3, y - r - 3, x + r + 3, y + r + 3), fill=BADGE_RING)
    draw.ellipse((x - r, y - r, x + r, y + r), fill=BADGE_FILL)
    t = str(n)
    l, t_, rr, b = draw.textbbox((0, 0), t, font=font)
    draw.text((x - (rr + l) / 2, y - (b + t_) / 2), t, font=font, fill=BADGE_TEXT)


def main():
    for raw_name, (r, marks) in SHOTS.items():
        src_name = next((k for k, v in RENAMES.items() if v == raw_name), raw_name)
        src = RAW / src_name
        if not src.exists():
            print(f'!! нет исходника {src_name}')
            continue
        img = Image.open(src).convert('RGB')
        for box in REDACT.get(raw_name, []):
            pixelate(img, box)
        font = ImageFont.truetype(FONT, int(r * 1.35))
        d = ImageDraw.Draw(img)
        for box in RINGS.get(raw_name, []):
            ring(d, box)
        for n, x, y in marks:
            badge(d, n, x, y, r, font)
        img.save(OUT / raw_name, optimize=True)
        print(f'{raw_name:32s} {len(marks)} выносок')

    # кадры без выносок просто копируются из исходников
    for src in sorted(RAW.glob('*.png')):
        name = RENAMES.get(src.name, src.name)
        if name in SHOTS:
            continue
        Image.open(src).convert('RGB').save(OUT / name, optimize=True)
        print(f'{name:32s} без выносок')


if __name__ == '__main__':
    main()

"""Draw the sample character portraits (simple shapes) and install them in both apps.

    python3 app/tool/portraits/sample_portraits.py            # into app/assets/characters/ and g2/public/characters/
    python3 app/tool/portraits/sample_portraits.py --out DIR  # somewhere else

They are placeholders that ship with the source. To use your own pictures, run radio_portrait.py
on them (see its --help). Needs Pillow.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

from radio_portrait import CHARACTERS, INSTALL_DIRS, PIC_H, PIC_W, radio_portrait

S = 600  # drawing size
LIGHT, MID, DARK, INK = 235, 170, 105, 25


def canvas():
    img = Image.new('L', (S, S), 255)  # on white, like an illustration: radio_portrait removes it
    return img, ImageDraw.Draw(img)


def eyes(d, y, dx=70, r=22, glasses=False):
    for x in (S / 2 - dx, S / 2 + dx):
        if glasses:
            d.ellipse((x - r * 2, y - r * 2, x + r * 2, y + r * 2), outline=LIGHT, width=8)
        d.ellipse((x - r, y - r, x + r, y + r), fill=INK)


def commander():
    img, d = canvas()
    d.rectangle((180, 470, 420, 600), fill=DARK)  # collar
    d.ellipse((160, 150, 440, 480), fill=MID)  # face
    d.polygon([(170, 330), (430, 330), (380, 470), (300, 500), (220, 470)], fill=DARK)  # beard
    d.rectangle((150, 120, 450, 215), fill=LIGHT)  # cap
    d.polygon([(140, 215), (460, 215), (420, 250), (180, 250)], fill=INK)  # visor
    d.ellipse((280, 140, 320, 180), fill=DARK)  # badge
    eyes(d, 290, dx=60, r=16)
    return img


def owl():
    img, d = canvas()
    d.polygon([(170, 150), (220, 230), (150, 250)], fill=MID)  # ear tufts
    d.polygon([(430, 150), (380, 230), (450, 250)], fill=MID)
    d.ellipse((140, 170, 460, 600), fill=MID)  # body
    d.ellipse((190, 300, 410, 600), fill=LIGHT)  # breast
    for x in (230, 370):
        d.ellipse((x - 65, 210, x + 65, 340), fill=LIGHT)
        d.ellipse((x - 28, 248, x + 28, 304), fill=INK)
    d.polygon([(280, 320), (320, 320), (300, 370)], fill=DARK)  # beak
    return img


def sphinx():
    img, d = canvas()
    d.polygon([(300, 110), (470, 220), (500, 560), (100, 560), (130, 220)], fill=LIGHT)  # headdress
    for i, y in enumerate(range(240, 560, 40)):
        d.line((125 + i * 2, y, 160, y), fill=DARK, width=10)
        d.line((440, y, 475 - i * 2, y), fill=DARK, width=10)
    d.ellipse((190, 190, 410, 470), fill=MID)  # face
    d.rectangle((275, 460, 325, 560), fill=DARK)  # beard
    eyes(d, 300, dx=50, r=14)
    d.line((300, 320, 300, 380), fill=DARK, width=8)  # nose
    return img


def dino():
    img, d = canvas()
    for x in range(190, 420, 55):
        d.polygon([(x, 200), (x + 27, 120), (x + 55, 200)], fill=LIGHT)  # spikes
    d.rounded_rectangle((150, 180, 450, 520), radius=120, fill=MID)  # head
    d.rounded_rectangle((180, 380, 420, 560), radius=80, fill=LIGHT)  # snout
    eyes(d, 300, dx=80, r=24)
    for x in (260, 340):
        d.ellipse((x - 10, 440, x + 10, 460), fill=INK)  # nostrils
    return img


def fox():
    img, d = canvas()
    d.polygon([(140, 100), (260, 230), (150, 300)], fill=MID)  # ears
    d.polygon([(460, 100), (340, 230), (450, 300)], fill=MID)
    d.polygon([(110, 230), (490, 230), (300, 560)], fill=MID)  # face
    d.polygon([(130, 330), (300, 360), (300, 560)], fill=LIGHT)  # cheeks
    d.polygon([(470, 330), (300, 360), (300, 560)], fill=LIGHT)
    eyes(d, 320, dx=75, r=16)
    d.ellipse((280, 520, 320, 555), fill=INK)  # nose
    return img


def monkey():
    img, d = canvas()
    for x in (130, 470):
        d.ellipse((x - 60, 270, x + 60, 390), fill=MID)  # ears
    d.ellipse((150, 150, 450, 520), fill=DARK)  # head
    d.ellipse((200, 230, 300, 360), fill=LIGHT)  # face mask
    d.ellipse((300, 230, 400, 360), fill=LIGHT)
    d.ellipse((200, 320, 400, 500), fill=LIGHT)
    eyes(d, 300, dx=50, r=16)
    d.arc((250, 380, 350, 450), 20, 160, fill=INK, width=8)  # smile
    d.arc((110, 90, 490, 470), 190, 350, fill=INK, width=24)  # headphones
    for x in (115, 485):
        d.rounded_rectangle((x - 35, 250, x + 35, 400), radius=20, fill=INK)
    return img


def seal():
    img, d = canvas()
    d.ellipse((110, 160, 490, 560), fill=LIGHT)  # head
    eyes(d, 320, dx=90, r=26)
    d.ellipse((260, 380, 340, 430), fill=INK)  # nose
    for dy in (-20, 10, 40):
        d.line((240, 430, 130, 420 + dy), fill=DARK, width=6)  # whiskers
        d.line((360, 430, 470, 420 + dy), fill=DARK, width=6)
    d.rectangle((150, 300, 450, 312), fill=DARK)  # glasses bridge
    for x in (210, 390):
        d.ellipse((x - 50, 270, x + 50, 370), outline=DARK, width=10)
    return img


def cat():
    img, d = canvas()
    d.polygon([(150, 160), (240, 250), (140, 300)], fill=MID)  # ears
    d.polygon([(450, 160), (360, 250), (460, 300)], fill=MID)
    d.ellipse((130, 200, 470, 540), fill=MID)  # head
    for x in (190, 300, 410):
        d.ellipse((x - 80, 40, x + 80, 190), fill=LIGHT)  # chef hat
    d.rectangle((180, 130, 420, 230), fill=LIGHT)
    eyes(d, 360, dx=70, r=18)
    d.polygon([(285, 410), (315, 410), (300, 430)], fill=INK)  # nose
    for dy in (-15, 15):
        d.line((250, 430, 140, 420 + dy), fill=LIGHT, width=5)  # whiskers
        d.line((350, 430, 460, 420 + dy), fill=LIGHT, width=5)
    return img


DRAW = {
    'commander': commander,
    'owl': owl,
    'sphinx': sphinx,
    'dino': dino,
    'fox': fox,
    'monkey': monkey,
    'seal': seal,
    'cat': cat,
}


def main() -> int:
    parser = argparse.ArgumentParser(description='Draw the sample portraits and install them in both apps.')
    parser.add_argument('--out', type=Path, help='write them here instead of the apps')
    args = parser.parse_args()
    assert DRAW.keys() == CHARACTERS.keys()
    dirs = [args.out] if args.out else INSTALL_DIRS
    for name, draw in DRAW.items():
        w = round(S * PIC_W / PIC_H)  # crop to the portrait's proportions
        portrait = radio_portrait(draw().crop(((S - w) // 2, 0, (S + w) // 2, S)), seed=len(name))
        for d in dirs:
            d.mkdir(parents=True, exist_ok=True)
            portrait.save(d / f'{name}.png', optimize=True)
        print(f'{name}: {CHARACTERS[name]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

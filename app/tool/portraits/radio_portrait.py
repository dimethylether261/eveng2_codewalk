"""Give a picture the look of a CODEWALK character portrait: a radio screen.

    python3 app/tool/portraits/radio_portrait.py face.png --character owl            # writes ./owl.png
    python3 app/tool/portraits/radio_portrait.py face.png --character owl --install  # into both apps
    python3 app/tool/portraits/radio_portrait.py face.png --character owl --preview owl_glasses.png

Crop and frame the picture yourself first: it is fitted to the portrait as it is (centre-cropped
only if its proportions differ). The picture area is 260 x 300 (about 0.87 : 1).

The result is 292 x 332: the picture in green on a dark screen, with soft edges, scanlines, grain,
a couple of glitches and a double frame. A white background that touches the edges of the picture becomes the dark
screen, so illustrations on white work as they are (--keep-background turns this off); so does a
transparent one. The phone app shows the portrait as it is; the glasses app turns it into greys and
blacks out its darkest part (g2/src/photo.ts), which --preview imitates.

Needs Pillow.
"""

import argparse
import random
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[3]
INSTALL_DIRS = [ROOT / 'app/assets/characters', ROOT / 'g2/public/characters']

# File name -> who it is. The apps map character ids to these names (portraitFiles in
# app/lib/radio_widgets.dart, PORTRAIT_FILES in g2/src/photo.ts).
CHARACTERS = {
    'commander': 'シレイ / Commander (commander)',
    'owl': 'フクロウ / Owl (history)',
    'sphinx': 'スフィンクス / Sphinx (architecture)',
    'dino': 'キョウリュウ / Dino (nature)',
    'fox': 'キツネ / Fox (place names)',
    'monkey': 'サル / Monkey (anime, film, music)',
    'seal': 'アザラシ / Seal (gadgets, tech)',
    'cat': 'ネコ / Cat (food, sake)',
}

W, H = 292, 332
INSET = 16  # the picture sits inside the frames
PIC_W, PIC_H = W - 2 * INSET, H - 2 * INSET

# Colours, measured on the portraits the store build ships (on the brighter scanline rows).
SCREEN = (3, 9, 4)  # behind the frames
OUTER_FRAME = (30, 110, 55)  # 2 px, 8 px in from the edge
INNER_FRAME = (90, 255, 140)  # 2 px, 13 px in
BACKGROUND = (10, 26, 19)  # the removed background
GREEN_BLACK, GREEN_WHITE = 44, 213  # green for black ... white in the picture
RED, BLUE = 0.41, 0.58  # red and blue as a share of green
DIM_ROW = 0.81  # every other row is dimmer: the scanlines
GRAIN = 17  # +- green levels of static
WHITE = 245  # background removal: lighter than this on all channels counts as white

# The glasses' portrait box and tone (FACE_W / FACE_H in g2/src/render.ts, PORTRAIT_TONE in photo.ts).
FACE_W, FACE_H = 98, 112
FACE_BLACK = 0.4


def fit(img: Image.Image, w: int, h: int) -> Image.Image:
    """Resize [img] to w x h, centre-cropping whatever does not fit."""
    scale = max(w / img.width, h / img.height)
    cw, ch = w / scale, h / scale
    left, top = (img.width - cw) / 2, (img.height - ch) / 2
    return img.resize((w, h), Image.LANCZOS, box=(left, top, left + cw, top + ch))


def background_mask(img: Image.Image) -> Image.Image:
    """'L' mask: 255 where the picture is white (or transparent) and connected to its edges."""
    flat = Image.new('RGBA', img.size, (255, 255, 255, 255))
    flat.alpha_composite(img.convert('RGBA'))
    r, g, b = flat.convert('RGB').split()
    darkest = ImageChops.darker(ImageChops.darker(r, g), b)
    work = Image.new('L', (img.width + 2, img.height + 2), 255)  # a white margin joins all the edges
    work.paste(darkest.point(lambda v: 255 if v >= WHITE else 0), (1, 1))
    ImageDraw.floodfill(work, (0, 0), 128)
    return work.crop((1, 1, img.width + 1, img.height + 1)).point(lambda v: 255 if v == 128 else 0)


def radio_portrait(src: Image.Image, keep_background=False, seed=1) -> Image.Image:
    """The 292 x 332 portrait for [src] (already cropped as wanted)."""
    rand = random.Random(seed)
    pic = fit(src.convert('RGBA'), PIC_W, PIC_H)
    if keep_background:
        bg = Image.new('L', pic.size, 0)
    else:
        bg = background_mask(pic).filter(ImageFilter.GaussianBlur(1.5))  # soft outline
    flat = Image.new('RGBA', pic.size, (255, 255, 255, 255))
    flat.alpha_composite(pic)
    lum = flat.convert('L').filter(ImageFilter.GaussianBlur(1.8)).load()  # soft, like a small screen
    bgpx = bg.load()

    out = Image.new('RGB', (W, H), SCREEN)
    px = out.load()
    cx, cy = PIC_W / 2, PIC_H / 2
    for y in range(PIC_H):
        for x in range(PIC_W):
            g = GREEN_BLACK + (GREEN_WHITE - GREEN_BLACK) * lum[x, y] / 255
            # A little darker towards the corners.
            r2 = ((x - cx) / cx) ** 2 + ((y - cy) / cy) ** 2
            g *= 1 - 0.25 * min(1.0, r2 / 2)
            colour = (g * RED, g, g * BLUE)
            t = bgpx[x, y] / 255
            colour = [c * (1 - t) + k * t for c, k in zip(colour, BACKGROUND)]
            grain = rand.uniform(-GRAIN, GRAIN)
            px[x + INSET, y + INSET] = tuple(
                max(0, min(255, round(c + grain * f))) for c, f in zip(colour, (RED, 1, BLUE))
            )

    def frame(at: int, colour: tuple[int, int, int]):
        for i in range(2):
            for x in range(at, W - at):
                px[x, at + i] = px[x, H - at - 1 - i] = colour
            for y in range(at, H - at):
                px[at + i, y] = px[W - at - 1 - i, y] = colour

    # Glitches: two short bands of rows shifted sideways, like a weak signal (as photo.ts does).
    for _ in range(2):
        y0 = INSET + rand.randrange(PIC_H - 4)
        shift = rand.randint(2, 6) * rand.choice((-1, 1))
        for y in range(y0, y0 + rand.randint(1, 3)):
            row = [px[x, y] for x in range(INSET, W - INSET)]
            for i in range(PIC_W):
                px[INSET + i, y] = row[min(PIC_W - 1, max(0, i - shift))]

    frame(8, OUTER_FRAME)
    frame(13, INNER_FRAME)
    # Scanlines over everything: the even rows are dimmer.
    for y in range(0, H, 2):
        for x in range(W):
            px[x, y] = tuple(round(c * DIM_ROW) for c in px[x, y])
    return out


def glasses_preview(portrait: Image.Image, scale=3) -> Image.Image:
    """Roughly what the glasses show: 98 x 112 greys, darkest 40% black, 16 levels (in green, scaled up)."""
    grey = fit(portrait.convert('L'), FACE_W, FACE_H)
    values = sorted(grey.getdata())
    lo, hi = values[int(len(values) * FACE_BLACK)], values[int(len(values) * 0.99)]
    hi = max(hi, lo + 1)
    toned = grey.point(lambda g: round(max(0, min(1, (g - lo) / (hi - lo))) * 15) * 17)
    green = Image.merge('RGB', (toned.point(lambda g: 0), toned, toned.point(lambda g: g // 3)))
    return green.resize((FACE_W * scale, FACE_H * scale), Image.NEAREST)


def main() -> int:
    who = '\n'.join(f'  {name:10} {desc}' for name, desc in CHARACTERS.items())
    parser = argparse.ArgumentParser(
        description='Give a picture the look of a CODEWALK character portrait (292 x 332, a radio screen).',
        epilog=f'Crop the picture yourself first (about 0.87 : 1, e.g. 260 x 300).\n\ncharacters:\n{who}',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('image', type=Path, help='the picture (PNG, JPEG, ...), already cropped')
    parser.add_argument('--character', '-c', required=True, choices=CHARACTERS, help='whose portrait it is (the file name)')
    parser.add_argument('--install', action='store_true', help='write it into app/assets/characters/ and g2/public/characters/')
    parser.add_argument('--out', '-o', type=Path, help='where to write it (default: ./<character>.png)')
    parser.add_argument('--keep-background', action='store_true', help='keep a white background instead of turning it into the dark screen')
    parser.add_argument('--seed', type=int, default=1, help='grain pattern (default: 1)')
    parser.add_argument('--preview', type=Path, help='also write a rough preview of how the glasses show it')
    args = parser.parse_args()

    src = Image.open(args.image)
    ratio = (src.width / src.height) / (PIC_W / PIC_H)
    if not 0.95 <= ratio <= 1.05:
        print(f'note: {src.width} x {src.height} is not about {PIC_W} : {PIC_H}; the sides that do not fit are cut off', file=sys.stderr)
    portrait = radio_portrait(src, args.keep_background, args.seed)
    targets = [d / f'{args.character}.png' for d in INSTALL_DIRS] if args.install else []
    if args.out or not targets:
        targets.append(args.out or Path(f'{args.character}.png'))
    for path in targets:
        portrait.save(path, optimize=True)
        print(f'wrote {path}')
    if args.preview:
        glasses_preview(portrait).save(args.preview)
        print(f'wrote {args.preview}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

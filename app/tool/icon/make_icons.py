"""Render the CODEWALK launcher icons (design A3: footprints walking into a call).

    python3 app/tool/icon/make_icons.py

Needs Pillow and Google Chrome (headless) to rasterise the SVGs. Writes:
  app/android/app/src/main/res/mipmap-*/ic_launcher{,_foreground,_background}.png
  app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
  app/tool/icon/codewalk_512.png                      (store art)
  g2/store/icon_24_{white,black}.png                  (Even Hub, 24x24 monochrome)
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
RES = ROOT / 'app/android/app/src/main/res'
G2_STORE = ROOT / 'g2/store'

DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
MASTER = 1024

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
"""

# Even Hub icon: drawn pixel by pixel (scaling the vector art down to 24 px only gives blur).
# Three prints zigzag up to the right into a ring with a dot: the same idea as A3.
# Even Hub rule: every lit pixel must be part of at least one fully lit 2x2 block (no 1 px lines).
PRINT = [  # 4 x 8, leaning up-right like the walk: sole, gap, heel
    '..##',
    '.###',
    '####',
    '###.',
    '##..',
    '....',
    '##..',
    '##..',
]
RING = [  # 10 x 10, 2 px thick, with a 2 x 2 dot
    '..######..',
    '.########.',
    '###....###',
    '##......##',
    '##..##..##',
    '##..##..##',
    '##......##',
    '###....###',
    '.########.',
    '..######..',
]
G2_PARTS = [(PRINT, 2, 14), (PRINT, 10, 13), (PRINT, 6, 3), (RING, 13, 1)]  # (art, left, top)


def chrome() -> str:
    for name in ('google-chrome', 'chromium', 'chromium-browser'):
        if path := shutil.which(name):
            return path
    raise SystemExit('Google Chrome (or Chromium) is needed to render the SVGs')


def render(svg: Path, size: int) -> Image.Image:
    """Rasterise at MASTER px with transparency, then downsample (Chrome won't open tiny windows)."""
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / 'icon.html'
        page.write_text(
            '<!doctype html><style>html,body{margin:0;background:transparent}img{display:block}</style>'
            f'<img src="{svg.as_uri()}" width="{MASTER}" height="{MASTER}">'
        )
        shot = Path(tmp) / 'shot.png'
        subprocess.run(
            [chrome(), '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
             '--allow-file-access-from-files', '--default-background-color=00000000',
             f'--window-size={MASTER},{MASTER}', f'--screenshot={shot}', page.as_uri()],
            check=True, capture_output=True, timeout=60,
        )
        im = Image.open(shot).convert('RGBA').crop((0, 0, MASTER, MASTER))
    return im if size == MASTER else im.resize((size, size), Image.LANCZOS)


def g2_bitmap() -> list[list[int]]:
    bits = [[0] * 24 for _ in range(24)]
    owner = {}
    for i, (art, left, top) in enumerate(G2_PARTS):
        for y, row in enumerate(art):
            for x, c in enumerate(row):
                if c == '#':
                    bits[top + y][left + x] = 1
                    owner[(left + x, top + y)] = i
    # parts keep at least 1 px of space between them (no touching, not even diagonally)
    for (x, y), i in owner.items():
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                j = owner.get((x + dx, y + dy), i)
                assert j == i, f'parts {i} and {j} touch at {x},{y}'
    lit = lambda x, y: 0 <= x < 24 and 0 <= y < 24 and bits[y][x]
    for (x, y) in owner:
        assert any(all(lit(x + ox + a, y + oy + b) for a in (0, 1) for b in (0, 1))
                   for ox in (-1, 0) for oy in (-1, 0)), f'pixel {x},{y} is not in a lit 2x2 block'
    return bits


def main() -> None:
    fg, bg, legacy = (render(HERE / f'{n}.svg', MASTER) for n in ('foreground', 'background', 'legacy'))
    for density, scale in DENSITIES.items():
        out = RES / f'mipmap-{density}'
        out.mkdir(parents=True, exist_ok=True)
        legacy.resize((round(48 * scale),) * 2, Image.LANCZOS).save(out / 'ic_launcher.png')
        layer = (round(108 * scale),) * 2
        fg.resize(layer, Image.LANCZOS).save(out / 'ic_launcher_foreground.png')
        bg.convert('RGB').resize(layer, Image.LANCZOS).save(out / 'ic_launcher_background.png')
    anydpi = RES / 'mipmap-anydpi-v26'
    anydpi.mkdir(exist_ok=True)
    (anydpi / 'ic_launcher.xml').write_text(ADAPTIVE_XML)
    legacy.resize((512, 512), Image.LANCZOS).save(HERE / 'codewalk_512.png')

    G2_STORE.mkdir(parents=True, exist_ok=True)
    bits = g2_bitmap()
    for tone, value in (('white', 255), ('black', 0)):
        im = Image.new('LA', (24, 24), (0, 0))
        for y, row in enumerate(bits):
            for x, on in enumerate(row):
                if on:
                    im.putpixel((x, y), (value, 255))
        im.save(G2_STORE / f'icon_24_{tone}.png')
    print('\n'.join(''.join('#' if b else '.' for b in row) for row in bits))


if __name__ == '__main__':
    main()

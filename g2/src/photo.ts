// The spot photo shown beside the dialogue (and the portraits). The photo comes from Wikimedia
// Commons, the portraits from public/characters; here they are cropped to the image container,
// turned into greyscale with levels stretched, and given a radio-style noise (scanlines, grain, two glitch bands). The host then reduces
// the PNG to the glasses' 16 greens. No outline / tone tricks: photos look as on the phone.
import { pngBytes } from './minimap'

// 4:3, small enough to leave room for the speaker's portrait and the dialogue.
export const PHOTO_W = 160
export const PHOTO_H = 120

/** Source rectangle that fills dw x dh without distortion (centre crop, like CSS cover). */
export function coverCrop(sw: number, sh: number, dw: number, dh: number) {
  const scale = Math.max(dw / sw, dh / sh)
  const w = dw / scale
  const h = dh / scale
  return { sx: (sw - w) / 2, sy: (sh - h) / 2, sw: w, sh: h }
}

/**
 * Levels for a contrast stretch: the darkest [lowCut] of pixels become black and the brightest
 * [highCut] white (default 2% each, for photos).
 */
export function stretchLevels(grey: Uint8ClampedArray | number[], lowCut = 0.02, highCut = 0.02): [number, number] {
  const hist = new Array(256).fill(0)
  for (const g of grey) hist[Math.round(g)]++
  let lo = 0
  let hi = 255
  for (let acc = 0; lo < 255 && acc + hist[lo] <= grey.length * lowCut; lo++) acc += hist[lo]
  for (let acc = 0; hi > 0 && acc + hist[hi] <= grey.length * highCut; hi--) acc += hist[hi]
  return hi > lo ? [lo, hi] : [0, 255]
}

/** Small deterministic PRNG (mulberry32), so an image always gets the same noise pattern. */
export function rng(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/**
 * Radio-style interference on a greyscale image (in place): dark scanlines every third
 * row, fine grain, and a couple of rows shifted sideways like a glitchy signal.
 * Static (the image is sent once), and the same for the same seed.
 */
export function radioNoise(grey: Uint8ClampedArray, w: number, h: number, seed = 1): Uint8ClampedArray {
  const rand = rng(seed)
  // Glitch bands: 2 short bands of rows shifted 2-6 px.
  for (let band = 0; band < 2; band++) {
    const y0 = Math.floor(rand() * (h - 4))
    const rows = 1 + Math.floor(rand() * 3)
    const shift = (2 + Math.floor(rand() * 5)) * (rand() < 0.5 ? -1 : 1)
    for (let y = y0; y < Math.min(h, y0 + rows); y++) {
      const row = grey.slice(y * w, (y + 1) * w)
      for (let x = 0; x < w; x++) grey[y * w + x] = row[Math.min(w - 1, Math.max(0, x - shift))]
    }
  }
  for (let y = 0; y < h; y++) {
    const scan = y % 3 === 2 ? 0.55 : 1 // scanlines
    for (let x = 0; x < w; x++) {
      const i = y * w + x
      const grain = (rand() - 0.5) * 36 // fine static
      grey[i] = (grey[i] + grain) * scan
    }
  }
  return grey
}

/** Seed from the image size and a few pixels, so each image keeps its own pattern. */
function seedOf(grey: Uint8ClampedArray): number {
  let s = grey.length
  for (let i = 0; i < grey.length; i += 97) s = (Math.imul(s, 31) + grey[i]) >>> 0
  return s
}

async function loadImage(blob: Blob): Promise<HTMLImageElement> {
  const url = URL.createObjectURL(blob)
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    return img
  } finally {
    URL.revokeObjectURL(url)
  }
}

/** How a character portrait is toned for the glasses. */
export type PortraitTone = { black: number; gamma: number }

/**
 * The character images are dim green on dark green with their own scanlines. On the glasses the
 * dark green still glows, so the darkest 40% becomes black (unlit) and the rest is stretched:
 * faces stand out from the background. No extra noise.
 */
export const PORTRAIT_TONE: PortraitTone = { black: 0.4, gamma: 1 }

/** Per-character tweaks, checked one by one on a glasses preview. */
export const PORTRAIT_TONES: Record<string, PortraitTone> = {
  // ネコ: the frying pan on the left is much darker than the cat; lift the darks so it stays visible.
  kagura: { black: 0.35, gamma: 0.45 },
}

export const portraitTone = (id: string): PortraitTone => PORTRAIT_TONES[id] ?? PORTRAIT_TONE

/**
 * Portrait image per character id, in public/characters/. Files are named after the characters
 * (the ids are kept: dialogues and logs store them). Same as portraitFiles in app/lib/radio_widgets.dart.
 */
export const PORTRAIT_FILES: Record<string, string> = {
  ootori: 'commander',
  shiori: 'owl',
  tetsu: 'sphinx',
  midori: 'dino',
  kotoha: 'fox',
  rei: 'monkey',
  gear: 'seal',
  kagura: 'cat',
}

/** The portrait's path in the app, or null for an unknown id. */
export const portraitPath = (id: string): string | null =>
  Object.hasOwn(PORTRAIT_FILES, id) ? `./characters/${PORTRAIT_FILES[id]}.png` : null

/** 0-255 after levels [lo, hi] and a gamma curve (gamma < 1 lifts the darks). */
export function toneValue(g: number, lo: number, hi: number, gamma = 1): number {
  const t = Math.max(0, Math.min(1, (g - lo) / (hi - lo)))
  return 255 * Math.pow(t, gamma)
}

/**
 * Greyscale PNG of [blob] cropped to w x h, levels stretched. Photos get radio noise; character
 * portraits (`portrait` = their tone) keep their own scanlines.
 */
export async function photoPng(blob: Blob, w = PHOTO_W, h = PHOTO_H, portrait?: PortraitTone): Promise<Uint8Array> {
  const img = await loadImage(blob)
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d')!
  const c = coverCrop(img.naturalWidth, img.naturalHeight, w, h)
  ctx.drawImage(img, c.sx, c.sy, c.sw, c.sh, 0, 0, w, h)
  const data = ctx.getImageData(0, 0, w, h)
  const px = data.data
  const grey = new Uint8ClampedArray(w * h)
  for (let i = 0; i < grey.length; i++) {
    grey[i] = 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2]
  }
  const [lo, hi] = portrait ? stretchLevels(grey, portrait.black, 0.01) : stretchLevels(grey)
  for (let i = 0; i < grey.length; i++) grey[i] = toneValue(grey[i], lo, hi, portrait?.gamma ?? 1)
  if (!portrait) radioNoise(grey, w, h, seedOf(grey))
  for (let i = 0; i < grey.length; i++) {
    // Snap to the glasses' 16 levels (multiples of 17) so the host doesn't dither in-between greys.
    const g = Math.round(grey[i] / 17) * 17
    px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = g
    px[i * 4 + 3] = 255
  }
  ctx.putImageData(data, 0, 0)
  return pngBytes(canvas)
}

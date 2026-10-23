import { describe, expect, it } from 'vitest'
import { PORTRAIT_FILES, coverCrop, portraitPath, portraitTone, radioNoise, rng, stretchLevels, toneValue } from './photo'

describe('photo', () => {
  it('crops the centre to fill the container without distortion', () => {
    expect(coverCrop(800, 600, 192, 144)).toEqual({ sx: 0, sy: 0, sw: 800, sh: 600 }) // same 4:3
    expect(coverCrop(800, 400, 192, 144)).toEqual({ sx: (800 - 533.3333333333334) / 2, sy: 0, sw: 533.3333333333334, sh: 400 })
    const tall = coverCrop(600, 900, 192, 144)
    expect(tall.sw).toBe(600)
    expect(tall.sh).toBeCloseTo(450)
    expect(tall.sy).toBeCloseTo(225)
  })

  it('stretches a dull photo to the full range, ignoring a few outliers', () => {
    const grey = [...new Array(98).fill(100), 0, 255] // mostly mid-grey with two outliers
    grey.push(...new Array(100).fill(150))
    expect(stretchLevels(grey)).toEqual([100, 150])
    expect(stretchLevels(new Array(50).fill(80))).toEqual([0, 255]) // flat image: unchanged
    // portraits: the darkest 40% (the dark-green background) goes black
    const portrait = [...new Array(60).fill(40), ...new Array(40).fill(150)]
    expect(stretchLevels(portrait, 0.4, 0.01)[0]).toBe(40)
  })
  it('adds radio noise: scanlines darken every third row, the same pattern for the same seed', () => {
    const w = 40, h = 30
    const flat = () => new Uint8ClampedArray(w * h).fill(200)
    const a = radioNoise(flat(), w, h, 42)
    expect(radioNoise(flat(), w, h, 42)).toEqual(a) // deterministic
    expect(radioNoise(flat(), w, h, 7)).not.toEqual(a)
    const rowMean = (y: number) => a.slice(y * w, (y + 1) * w).reduce((x, v) => x + v, 0) / w
    expect(rowMean(2)).toBeLessThan(rowMean(1) * 0.7) // scanline row
    expect(Math.abs(rowMean(0) - 200)).toBeLessThan(15) // grain only on the other rows
    expect(rng(1)()).toBe(rng(1)())
  })
  it('tones portraits: black point per character, gamma lifts the darks for the cat', () => {
    expect(portraitTone('shiori')).toEqual({ black: 0.4, gamma: 1 })
    expect(portraitTone('kagura').gamma).toBeLessThan(1)
    expect(toneValue(50, 50, 250)).toBe(0)
    expect(toneValue(250, 50, 250)).toBe(255)
    expect(toneValue(100, 50, 250, 0.45)).toBeGreaterThan(toneValue(100, 50, 250) * 2) // a dark pan, lifted
  })
})

describe('portraits', () => {
  it('are named after the characters, one file per character id', () => {
    expect(portraitPath('shiori')).toBe('./characters/owl.png')
    expect(portraitPath('../x')).toBeNull()
    expect(portraitPath('toString')).toBeNull()
    const shipped = Object.keys(import.meta.glob('../public/characters/*.png')).map(p => p.split('/').pop())
    expect(shipped.sort()).toEqual(Object.values(PORTRAIT_FILES).map(f => `${f}.png`).sort())
  })
})

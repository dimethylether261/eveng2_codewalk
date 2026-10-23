import { describe, expect, it } from 'vitest'
import { parseLang } from './lang'

describe('lang', () => {
  it('the saved language wins; nothing saved falls back to the phone language', () => {
    expect(parseLang('en', 'ja')).toBe('en')
    expect(parseLang('', 'ja')).toBe('ja')
    expect(parseLang('fr', 'en')).toBe('en')
  })
})

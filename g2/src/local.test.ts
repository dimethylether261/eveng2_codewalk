import { describe, expect, it } from 'vitest'
import { defaultSettings, parseSettings } from './local'

describe('standalone settings', () => {
  it('start from the defaults in the phone language', () => {
    expect(parseSettings('', 'en')).toEqual(defaultSettings('en'))
    expect(parseSettings('{broken', 'ja').lang).toBe('ja')
  })

  it('unknown or missing values fall back; the key is trimmed', () => {
    const s = parseSettings(
      JSON.stringify({ apiKey: ' sk-ant-x ', lang: 'fr', frequency: 'often', themes: [], pinRange: 'week', adultConfirmed: 'yes' }),
      'ja',
    )
    expect(s).toMatchObject({ apiKey: 'sk-ant-x', lang: 'ja', frequency: 'normal', pinRange: 'week', adultConfirmed: false })
    expect(s.themes).toEqual(['history', 'architecture', 'nature'])
    expect(s.minimap).toBe(true)
    expect(parseSettings(JSON.stringify({ minimap: false }), 'ja').minimap).toBe(false)
  })
})

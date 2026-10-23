import { describe, expect, it } from 'vitest'
import { choose, parseMode } from './mode'

describe('mode', () => {
  it('nothing saved (or something unknown) means auto', () => {
    expect(parseMode('')).toBe('auto')
    expect(parseMode('phone')).toBe('phone')
    expect(parseMode('glasses')).toBe('auto')
  })

  it('auto asks for the phone app; the fixed modes never do', async () => {
    let asked = 0
    const running = (yes: boolean) => async () => {
      asked++
      return yes
    }
    expect(await choose('auto', running(true))).toBe('phone')
    expect(await choose('auto', running(false))).toBe('standalone')
    expect(await choose('phone', running(false))).toBe('phone')
    expect(await choose('standalone', running(true))).toBe('standalone')
    expect(asked).toBe(2)
  })
})

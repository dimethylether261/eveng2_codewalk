import { describe, expect, it } from 'vitest'
import { normalizeCode, phoneUrl } from './link'

describe('link to the phone app', () => {
  it('takes the pairing code as typed: case, spaces and the hyphen do not matter', () => {
    expect(normalizeCode(' abcd-2345 ')).toBe('ABCD2345')
    expect(normalizeCode('')).toBe('')
  })

  it('sends the code with every request', () => {
    expect(phoneUrl('/state', 'abcd-2345')).toBe('http://127.0.0.1:8765/state?t=ABCD2345')
    expect(phoneUrl('/cmd?c=next', 'ABCD2345')).toBe('http://127.0.0.1:8765/cmd?c=next&t=ABCD2345')
    expect(phoneUrl('/ws', 'ABCD2345', 'ws')).toBe('ws://127.0.0.1:8765/ws?t=ABCD2345')
  })
})

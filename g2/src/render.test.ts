import { describe, expect, it } from 'vitest'
import { BLINK_MS, W, blink, clock, command, distance, layoutKey, render, setupScreen, type WalkState, type Screen } from './render'

const sp = (name: string, frequency: string, id?: string) => ({ id, name, frequency })
const base: WalkState = {
  v: 1, walking: true, status: '', codename: 'ウォーカー', freq: '147.20', stats: { walkedM: 1234 },
  incoming: null, call: null,
}
const call = {
  spot: '品川神社',
  commander: sp('シレイ', '147.20', 'ootori'),
  specialist: sp('フクロウ', '146.35', 'shiori'),
  lines: [
    { id: 'ootori', who: 'シレイ', text: 'ウォーカー、聞こえるか。' },
    { id: 'shiori', who: 'フクロウ', text: '鳥居に龍がいるの。' },
  ],
  index: 0,
  finished: false,
  sources: ['品川神社'],
}
const map = { origin: [35.6, 139.7] as [number, number], roadsVersion: 1, pos: [0, 0] as [number, number], heard: [] }
const text = (s: Screen, name: string) => s.blocks.find(b => b.name === name)?.content

function checkLayout(s: Screen) {
  expect(s.blocks.filter(b => b.capture)).toHaveLength(1) // exactly one container takes the gestures
  const ids = [...s.blocks.map(b => b.id), ...s.images.map(i => i.id)]
  expect(new Set(ids).size).toBe(ids.length)
  for (const r of [...s.blocks, ...s.images]) {
    expect(r.x).toBeGreaterThanOrEqual(0)
    expect(r.y).toBeGreaterThanOrEqual(0)
    expect(r.x + r.w).toBeLessThanOrEqual(W)
    expect(r.y + r.h).toBeLessThanOrEqual(288)
  }
  for (const i of s.images) expect(i.w <= 288 && i.h <= 144).toBe(true)
  for (const b of s.blocks) expect(b.content.length).toBeLessThan(1000)
}

describe('render', () => {
  it('before the core has a state: a getting-ready card', () => {
    const s = render(null)
    expect(s.mode).toBe('offline')
    checkLayout(s)
  })

  it('waiting: frequency + status line, minimap, and the distance walked', () => {
    const s = render({ ...base, map })
    expect(s.mode).toBe('idle')
    expect(text(s, 'status')).toBe('◀ 147.20 ▶　無線を待機しています')
    expect(text(s, 'stats')).toBe('散歩 1.2km')
    expect(text(render({ ...base, map }, 'ja', new Date(2026, 9, 21, 9, 5)), 'clock')).toBe('9:05')
    expect(clock(new Date(2026, 9, 21, 23, 59))).toBe('23:59')
    expect(s.images.map(i => i.kind)).toEqual(['map'])
    expect(s.map).toBe(map)
    checkLayout(s)
    expect(text(render({ ...base, status: '近くの3か所について調べています…' }), 'status')).toContain('近くの3か所')
    const stopped = render({ ...base, walking: false, map })
    expect(text(stopped, 'status')).toContain('散歩は止まっています')
    expect(text(stopped, 'clock')).toMatch(/^\d{1,2}:\d{2}$/)
    expect(stopped.images).toEqual([])
    checkLayout(stopped)
  })

  it('waiting: the minimap can be turned off (phone page settings)', () => {
    const now = new Date(2026, 9, 21, 9, 5)
    const on = render({ ...base, map }, 'ja', now)
    const off = render({ ...base, map }, 'ja', now, false)
    expect(off.images).toEqual([])
    expect(off.map).toBeNull()
    expect(text(off, 'stats')).toBe('散歩 1.2km')
    expect(layoutKey(off)).not.toBe(layoutKey(on)) // the page is rebuilt without the image
    checkLayout(off)
  })

  it('incoming: blinking CALL title, commander portrait, tap answers, swipe saves for later', () => {
    const s = render({ ...base, incoming: { spot: '品川神社', area: false, commander: call.commander, specialist: call.specialist } })
    expect(s.mode).toBe('incoming')
    expect(text(s, 'info')).toBe('シレイから無線\n147.20 ▶ 146.35 フクロウ\n\n品川神社')
    expect(s.portrait).toBe('ootori')
    checkLayout(s)
    expect(command(s.mode, 'tap')).toBe('answer')
    expect(command(s.mode, 'down')).toBe('later')
    expect(text(blink(s, 0), 'title')).toBe('◆◆  C A L L  ◆◆')
    expect(text(blink(s, 600), 'title')).toBe('◇◇  C A L L  ◇◇')
    expect(text(blink(s, BLINK_MS + 600), 'title')).toBe('◆◆  C A L L  ◆◆')
    expect(layoutKey(blink(s, 600))).toBe(layoutKey(s)) // blinking only changes text
  })

  it('call: speaker portrait and name, dimmed previous line, framed current line, progress', () => {
    const s = render({ ...base, call: { ...call, index: 1 } })
    expect(s.mode).toBe('call')
    expect(s.portrait).toBe('shiori')
    expect(text(s, 'who')).toBe('フクロウ')
    expect(text(s, 'freq')).toBe('146.35')
    const face = s.images.find(i => i.name === 'face')!
    expect(s.blocks.find(b => b.name === 'freq')!.y).toBeGreaterThanOrEqual(face.y + face.h) // right under the portrait
    expect(text(s, 'prev')).toBe('シレイ：ウォーカー、聞こえるか。')
    expect(text(s, 'cur')).toBe('鳥居に龍がいるの。')
    expect(text(s, 'footer')).toBe('品川神社　2/2　タップ: 次へ')
    expect(s.blocks.find(b => b.name === 'prev')?.brightness).toBe(2)
    expect(s.blocks.find(b => b.name === 'cur')?.brightness).toBeUndefined() // full brightness
    expect(s.blocks.find(b => b.name === 'cur')?.capture).toBe(true)
    checkLayout(s)
    const first = render({ ...base, call })
    expect(text(first, 'prev')).toBe('')
    expect(first.portrait).toBe('ootori')
    expect(layoutKey(first)).toBe(layoutKey(s)) // next line: texts change, containers stay
    expect(command('call', 'tap')).toBe('next')
    expect(command('call', 'up')).toBe('prev')
  })

  it('a photo sits on the right and narrows the dialogue; its credit goes on the sources page', () => {
    const withPhoto = { ...call, photo: { key: 7, credit: 'Someone / CC BY-SA 4.0' } }
    const s = render({ ...base, call: withPhoto })
    expect(s.photo).toBe(7)
    expect(s.images.map(i => i.kind)).toEqual(['face', 'photo'])
    const cur = (x: Screen) => x.blocks.find(b => b.name === 'cur')!
    expect(cur(s).w).toBeLessThan(cur(render({ ...base, call })).w)
    // portrait and photo line up with the top of the current-line frame
    expect(s.images.map(i => i.y)).toEqual([cur(s).y, cur(s).y])
    checkLayout(s)
    const src = render({ ...base, call: { ...withPhoto, finished: true } })
    expect(src.mode).toBe('sources')
    expect(text(src, 'body')).toBe('・品川神社\n\n写真: Someone / CC BY-SA 4.0')
    expect(src.images).toEqual([])
    expect(command(src.mode, 'tap')).toBe('end')
  })

  it('a call in progress wins over a new incoming one; idle does nothing', () => {
    const s = render({ ...base, call, incoming: { spot: 'x', area: true, commander: call.commander, specialist: call.specialist } })
    expect(s.mode).toBe('call')
    expect(command('idle', 'tap')).toBeNull()
  })

  it('formats distance', () => {
    expect(distance(234)).toBe('230m')
    expect(distance(1234)).toBe('1.2km')
  })
})

describe('english', () => {
  it('follows the chosen language; offline uses the fallback one', () => {
    const en = { ...base, lang: 'en' as const }
    expect(text(render(en), 'status')).toBe('◀ 147.20 ▶　Standing by')
    expect(text(render(en), 'stats')).toBe('Walked 1.2 km')
    const inc = render({ ...en, incoming: { spot: 'Shinagawa Shrine', area: true, commander: sp('Commander', '147.20', 'ootori'), specialist: sp('Owl', '146.35', 'shiori') } })
    expect(text(inc, 'info')).toBe('Call from Commander\n147.20 ▶ 146.35 Owl\n\nTown trivia: Shinagawa Shrine')
    expect(text(inc, 'hint')).toBe('Tap: answer / Swipe: later')
    expect(text(render({ ...en, call: { ...call, finished: true } }), 'hint')).toBe('Tap: end call / Swipe: back')
    expect(text(render(null, 'en'), 'body')).toContain('Not connected')
    expect(text(render(null), 'body')).toContain('つながっていません')
  })

  it('first launch: the glasses point to the phone page, in both languages', () => {
    const s = setupScreen()
    expect(text(s, 'body')).toContain('言語と接続モード')
    expect(text(s, 'body')).toContain('Choose the language')
    checkLayout(s)
  })

  it('a long press on the ring starts / ends the walk, only while waiting', () => {
    expect(command('idle', 'ringhold')).toBe('walk')
    for (const mode of ['incoming', 'call', 'sources', 'offline'] as const) expect(command(mode, 'ringhold')).toBeNull()
    expect(command('idle', 'tap')).toBeNull()
    const paused = render({ ...base, walking: false })
    expect(text(paused, 'status')).toContain('リング長押しで開始')
  })
})

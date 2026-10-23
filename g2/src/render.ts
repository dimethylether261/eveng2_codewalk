// What the glasses show for a given walk state: a list of text blocks and images per screen.
// Pure functions (tested in render.test.ts); main.ts turns them into SDK containers.
//
// The glasses have one font, one colour and left-aligned text, so hierarchy comes from
// position, frames, symbols and images (radio style: portrait | dialogue | photo).
import { MAP_H, MAP_W, type MapState } from './minimap'
import { PHOTO_H, PHOTO_W } from './photo'

export type Speaker = { id?: string; name: string; frequency: string }

/** State from the core in this app (app/lib/standalone/walk_core.dart, g2State). */
export type Lang = 'ja' | 'en'

/** Glasses texts per language (the state carries the language chosen on the phone page). */
export const TEXT = {
  ja: {
    offline: 'CODEWALK を準備しています…',
    exitHint: 'ダブルタップ: 終了',
    more: (n: number) => `ほか${n}件`,
    photo: '写真: ',
    sourcesTitle: (spot: string) => `出典 ─ ${spot}`,
    noSources: '（出典なし）',
    sourcesHint: 'タップ: 通信を終える ／ スワイプ: 戻る',
    next: 'タップ: 次へ',
    calling: (name: string) => `${name}から無線`,
    townTrivia: '町の雑学：',
    incomingHint: 'タップ: 応答 ／ スワイプ: あとで',
    paused: '散歩は止まっています（リング長押しで開始）',
    standingBy: '無線を待機しています',
    walked: (d: string) => `散歩 ${d}`,
  },
  en: {
    offline: 'Getting CODEWALK ready…',
    exitHint: 'Double-tap: exit',
    more: (n: number) => `+${n} more`,
    photo: 'Photo: ',
    sourcesTitle: (spot: string) => `Sources ─ ${spot}`,
    noSources: '(no sources)',
    sourcesHint: 'Tap: end call / Swipe: back',
    next: 'Tap: next',
    calling: (name: string) => `Call from ${name}`,
    townTrivia: 'Town trivia: ',
    incomingHint: 'Tap: answer / Swipe: later',
    paused: 'Walk paused (hold the ring to start)',
    standingBy: 'Standing by',
    walked: (d: string) => `Walked ${d}`,
  },
} satisfies Record<Lang, unknown>

export type WalkState = {
  v: number
  /** Language of the conversations (texts on the glasses follow it). */
  lang?: Lang
  walking: boolean
  status: string
  codename: string
  /** The commander's frequency (shown while waiting). */
  freq?: string
  stats?: { walkedM: number }
  /** Minimap data while walking (waiting screen only). */
  map?: MapState | null
  incoming: null | { spot: string; area: boolean; commander: Speaker; specialist: Speaker }
  call: null | {
    spot: string
    commander: Speaker
    specialist: Speaker
    /** id: speaker id (portrait), who: display name. */
    lines: { id?: string; who: string; text: string }[]
    index: number
    finished: boolean
    sources: string[]
    /** The spot photo, served by the phone at /photo (standalone: fetched from url); key changes with the photo. */
    photo?: { key: number; credit: string; url?: string } | null
  }
}

export type Mode = 'offline' | 'idle' | 'incoming' | 'call' | 'sources'

/** A text container. Exactly one block per screen has `capture` (it receives the gestures). */
export type Block = {
  id: number
  name: string
  x: number
  y: number
  w: number
  h: number
  content: string
  frame?: boolean
  capture?: boolean
  /** Text brightness 0-4 (SDK textColor; the glasses' default is 4). */
  brightness?: number
}

/** An image container; its pixels come from the minimap, the call photo or a portrait. */
export type Img = { id: number; name: string; x: number; y: number; w: number; h: number; kind: 'map' | 'photo' | 'face' }

export type Screen = {
  mode: Mode
  blocks: Block[]
  images: Img[]
  map: MapState | null
  /** The call photo's key when shown. */
  photo: number | null
  /** Character id of the portrait shown. */
  portrait: string | null
}

/** What a tap / swipe does in each mode (sent as a command to the core). */
/** ringhold: a long press on the ring (the temples' long press is left to the system). */
export type Gesture = 'tap' | 'up' | 'down' | 'ringhold'

export const W = 576
export const H = 288
export const FACE_W = 98 // same proportions as the character images (292 x 332)
export const FACE_H = 112
/** Bottom-row width for the speaker's name ("スフィンクス", the longest, on one line; the frequency is under the portrait). */
export const WHO_W = 200

const noImages = { images: [] as Img[], map: null, photo: null, portrait: null }

export function distance(m: number, lang: Lang = 'ja'): string {
  const sep = lang === 'en' ? ' ' : ''
  return m < 1000 ? `${Math.round(m / 10) * 10}${sep}m` : `${(m / 1000).toFixed(1)}${sep}km`
}

/** Title + framed body + hint: offline and sources. */
function card(mode: Mode, title: string, body: string, hint: string): Screen {
  return {
    mode,
    ...noImages,
    blocks: [
      { id: 1, name: 'title', x: 0, y: 0, w: W, h: 36, content: title },
      { id: 2, name: 'body', x: 0, y: 40, w: W, h: 204, content: body, frame: true, capture: true },
      { id: 3, name: 'hint', x: 0, y: 252, w: W, h: 36, content: hint },
    ],
  }
}

/** First launch: the phone page asks for the language (both languages: none is chosen yet). */
export function setupScreen(): Screen {
  return card(
    'offline',
    'CODEWALK',
    'スマホの画面で、言語を選んでください\n\nChoose the language on your phone',
    'ダブルタップ: 終了 / Double tap: exit',
  )
}

/** [fallbackLang]: language before the core has a state (the one chosen on the phone page). */
/** The time on the waiting screen (24-hour, the phone's local time). */
export function clock(now: Date): string {
  return `${now.getHours()}:${String(now.getMinutes()).padStart(2, '0')}`
}

/** [showMap]: the minimap on the waiting screen (turned on / off in the phone page's settings). */
export function render(state: WalkState | null, fallbackLang: Lang = 'ja', now: Date = new Date(), showMap = true): Screen {
  const lang: Lang = state?.lang ?? fallbackLang
  const t = TEXT[lang]
  if (!state) return card('offline', 'CODEWALK', t.offline, t.exitHint)

  const call = state.call
  if (call && call.finished) {
    const list = call.sources.slice(0, 4).map(s => `・${s}`)
    if (call.sources.length > 4) list.push(t.more(call.sources.length - 4))
    if (call.photo) list.push('', `${t.photo}${call.photo.credit}`)
    return card('sources', t.sourcesTitle(call.spot), list.length ? list.join('\n') : t.noSources, t.sourcesHint)
  }

  if (call) {
    //             previous line (unframed, dimmed, full width)
    // [portrait]  ┌ current line (framed) ┐  [photo]     <- images aligned with the frame
    // frequency   └───────────────────────┘
    // name                spot 2/4 hint                   <- one bottom row: long names fit
    const cur = call.lines[call.index]
    const prev = call.index > 0 ? call.lines[call.index - 1] : null
    const speaker = cur?.who === call.commander.name ? call.commander : call.specialist
    const hasPhoto = !!call.photo
    const textX = FACE_W + 12
    const textW = (hasPhoto ? W - PHOTO_W - 12 : W) - textX
    const frameY = 102
    const images: Img[] = [{ id: 10, name: 'face', x: 4, y: frameY, w: FACE_W, h: FACE_H, kind: 'face' }]
    if (hasPhoto) images.push({ id: 11, name: 'photo', x: W - PHOTO_W - 4, y: frameY, w: PHOTO_W, h: PHOTO_H, kind: 'photo' })
    return {
      mode: 'call',
      blocks: [
        // Speaker name on the bottom row: the column under the portrait is too narrow for 6 letters (スフィンクス).
        { id: 1, name: 'who', x: 0, y: 252, w: WHO_W, h: 36, content: cur?.who ?? '' },
        // The frequency fits under the portrait (digits are narrow), like a radio screen.
        { id: 5, name: 'freq', x: 0, y: frameY + FACE_H + 2, w: FACE_W + 8, h: 252 - (frameY + FACE_H + 2), content: speaker.frequency },
        // The previous line, dimmed: context, not the line being said now.
        { id: 2, name: 'prev', x: textX, y: 0, w: W - textX - 4, h: 100, content: prev ? `${prev.who}：${prev.text}` : '', brightness: 2 },
        { id: 3, name: 'cur', x: textX, y: frameY, w: textW, h: 144, content: cur?.text ?? '', frame: true, capture: true },
        {
          id: 4,
          name: 'footer',
          x: WHO_W + 4,
          y: 252,
          w: W - WHO_W - 4,
          h: 36,
          content: `${call.spot}　${call.index + 1}/${call.lines.length}　${t.next}`,
        },
      ],
      images,
      map: null,
      photo: hasPhoto ? call.photo!.key : null,
      portrait: cur?.id ?? null,
    }
  }

  const inc = state.incoming
  if (inc) {
    return {
      mode: 'incoming',
      blocks: [
        { id: 1, name: 'title', x: 168, y: 8, w: 300, h: 40, content: '◆◆  C A L L  ◆◆' },
        {
          id: 2,
          name: 'info',
          x: FACE_W + 40,
          y: 64,
          w: W - FACE_W - 48,
          h: 150,
          content: `${t.calling(inc.commander.name)}\n${inc.commander.frequency} ▶ ${inc.specialist.frequency} ${inc.specialist.name}\n\n${inc.area ? t.townTrivia : ''}${inc.spot}`,
          capture: true,
        },
        { id: 3, name: 'hint', x: FACE_W + 40, y: 240, w: W - FACE_W - 48, h: 40, content: t.incomingHint },
      ],
      images: [{ id: 10, name: 'face', x: 24, y: 64, w: FACE_W, h: FACE_H, kind: 'face' }],
      map: null,
      photo: null,
      portrait: inc.commander.id ?? null, // the commander is calling
    }
  }

  // Waiting: one sentence (like the phone's status), the time, the minimap and the distance walked.
  const freq = state.freq ?? '147.20'
  const mapX = (W - MAP_W) / 2
  const time: Block = { id: 3, name: 'clock', x: 0, y: 44, w: mapX - 8, h: 36, content: clock(now) } // left of the map
  if (!state.walking) {
    return {
      mode: 'idle',
      ...noImages,
      blocks: [{ id: 1, name: 'status', x: 0, y: 0, w: W, h: 40, content: `◀ ${freq} ▶　${t.paused}`, capture: true }, time],
    }
  }
  const map = showMap ? (state.map ?? null) : null
  const blocks: Block[] = [
    { id: 1, name: 'status', x: 0, y: 0, w: W, h: 40, content: `◀ ${freq} ▶　${state.status || t.standingBy}`, capture: true },
    time,
  ]
  if (state.stats) {
    blocks.push({
      id: 2,
      name: 'stats',
      x: mapX,
      y: map ? 44 + MAP_H + 4 : 48,
      w: MAP_W,
      h: 36,
      content: t.walked(distance(state.stats.walkedM, lang)),
    })
  }
  return {
    mode: 'idle',
    blocks,
    images: map ? [{ id: 10, name: 'map', x: mapX, y: 44, w: MAP_W, h: MAP_H, kind: 'map' }] : [],
    map,
    photo: null,
    portrait: null,
  }
}

/** How long an incoming call blinks before it stays lit (saves battery and BLE traffic). */
export const BLINK_MS = 10_000
export const BLINK_PERIOD_MS = 500

/** Incoming call: the title blinks ◆ / ◇ for the first [BLINK_MS] after it rang. */
export function blink(s: Screen, sinceRingMs: number): Screen {
  if (s.mode !== 'incoming' || sinceRingMs >= BLINK_MS) return s
  const off = Math.floor(sinceRingMs / BLINK_PERIOD_MS) % 2 === 1
  if (!off) return s
  return { ...s, blocks: s.blocks.map(b => (b.name === 'title' ? { ...b, content: b.content.replace(/◆/g, '◇') } : b)) }
}

/** The containers (not their contents) of a screen: when this changes the page is rebuilt. */
export function layoutKey(s: Screen): string {
  return [
    ...s.blocks.map(b => `${b.id}:${b.x},${b.y},${b.w},${b.h},${b.frame ? 1 : 0}${b.capture ? 'c' : ''}${b.brightness ?? ''}`),
    ...s.images.map(i => `i${i.id}:${i.x},${i.y},${i.w},${i.h}`),
  ].join('|')
}

/** Command for the core, or null when the gesture does nothing in this mode. */
export function command(mode: Mode, g: Gesture): string | null {
  switch (mode) {
    case 'incoming':
      return g === 'ringhold' ? null : g === 'tap' ? 'answer' : 'later'
    case 'call':
      return g === 'ringhold' ? null : g === 'up' ? 'prev' : 'next'
    case 'sources':
      return g === 'tap' ? 'end' : g === 'ringhold' ? null : 'prev'
    case 'idle':
      // Start or end the walk. Only while waiting: a long press during
      // a call should not end the walk by accident.
      return g === 'ringhold' ? 'walk' : null
    default:
      return null
  }
}

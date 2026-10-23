// Link to the CODEWALK phone app, which serves its state on this phone only (127.0.0.1).
// Every request carries the pairing code shown in the phone app's settings (the phone app refuses
// requests without it, so web pages in the phone's browser can't use the link).
// WebSocket first; if that keeps failing (Android may drop sockets of a suspended WebView),
// poll /state over HTTP until the socket works again.
import type { Roads } from './minimap'
import type { WalkState } from './render'

// VITE_CODEWALK_PHONE: point a dev build at another address (e.g. a mock on 127.0.0.1:8766).
export const PHONE: string = import.meta.env.VITE_CODEWALK_PHONE || '127.0.0.1:8765'
/** The pairing code, kept in the Even Hub storage. */
export const PAIR_KEY = 'cw.pair'

/** A code as typed: case, spaces and hyphens do not matter (as normalizeCode in app/lib/g2_bridge.dart). */
export const normalizeCode = (code: string): string => code.toUpperCase().replace(/[^A-Z0-9]/g, '')

/** URL of [path] on the phone app, with the pairing code. */
export function phoneUrl(path: string, code: string, scheme = 'http'): string {
  const sep = path.includes('?') ? '&' : '?'
  return `${scheme}://${PHONE}${path}${sep}t=${encodeURIComponent(normalizeCode(code))}`
}

/**
 * connected: the phone app answers; unpaired: it refuses the code (or none is entered yet);
 * locked: it refuses everything for a few minutes after many wrong codes; offline: no answer.
 */
export type LinkStatus = 'connected' | 'unpaired' | 'locked' | 'offline'

export class PhoneLink {
  private ws: WebSocket | null = null
  private pollTimer: ReturnType<typeof setInterval> | null = null
  private retry = 0
  private stopped = false

  constructor(
    private code: string,
    private onState: (s: WalkState | null, status: LinkStatus) => void,
  ) {}

  start() {
    this.stopped = false
    if (!normalizeCode(this.code)) return this.onState(null, 'unpaired') // nothing to try yet
    this.connect()
  }

  stop() {
    this.stopped = true
    this.ws?.close()
    this.stopPolling()
  }

  send(cmd: string) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ cmd }))
      return
    }
    this.fetchState(`/cmd?c=${encodeURIComponent(cmd)}`)
  }

  /** Roads for the minimap (only fetched when the state's roadsVersion changes). */
  async fetchRoads(): Promise<Roads> {
    const r = await fetch(phoneUrl('/roads', this.code))
    return (await r.json()) as Roads
  }

  /** A character portrait (PNG) served by the phone app: the same asset its radio screen shows. */
  async fetchPortrait(id: string): Promise<Blob> {
    const r = await fetch(phoneUrl(`/portrait?id=${encodeURIComponent(id)}`, this.code))
    if (!r.ok) throw new Error(`portrait ${r.status}`)
    return r.blob()
  }

  /** The photo of the call being played. */
  async fetchPhoto(): Promise<Blob> {
    const r = await fetch(phoneUrl('/photo', this.code))
    if (!r.ok) throw new Error(`photo ${r.status}`)
    return r.blob()
  }

  /** The state over HTTP (also the answer to /cmd). A refused code stops all retries: each wrong try
   * counts towards the phone app's lockout, so wait for the code to be entered again. */
  private fetchState(path: string) {
    fetch(phoneUrl(path, this.code))
      .then(async r => {
        if (r.status === 401 || r.status === 429) {
          this.stop()
          return this.onState(null, r.status === 401 ? 'unpaired' : 'locked')
        }
        this.onState((await r.json()) as WalkState, 'connected')
      })
      .catch(() => this.onState(null, 'offline'))
  }

  private connect() {
    if (this.stopped) return
    let ws: WebSocket
    try {
      ws = new WebSocket(phoneUrl('/ws', this.code, 'ws'))
    } catch {
      this.scheduleReconnect()
      return
    }
    this.ws = ws
    ws.onopen = () => {
      this.retry = 0
      this.stopPolling()
    }
    ws.onmessage = ev => {
      try {
        this.onState(JSON.parse(String(ev.data)) as WalkState, 'connected')
      } catch {
        /* ignore malformed frames */
      }
    }
    ws.onclose = () => {
      if (this.ws === ws) this.ws = null
      this.scheduleReconnect()
    }
    ws.onerror = () => ws.close()
  }

  private scheduleReconnect() {
    if (this.stopped) return
    this.retry++
    // A refused WebSocket can't tell why; one HTTP request can (and polling keeps the screen going).
    if (this.retry >= 2) this.startPolling()
    setTimeout(() => this.connect(), Math.min(1000 * 2 ** Math.min(this.retry, 4), 15000))
  }

  private startPolling() {
    if (this.pollTimer) return
    const poll = () => this.fetchState('/state')
    poll()
    this.pollTimer = setInterval(poll, 3000)
  }

  private stopPolling() {
    if (this.pollTimer) clearInterval(this.pollTimer)
    this.pollTimer = null
  }
}

/** Is the CODEWALK phone app running on this phone? (/hello needs no code and says nothing else.) */
export async function phoneAppRunning(): Promise<boolean> {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), 1500)
  try {
    return (await fetch(`http://${PHONE}/hello`, { signal: ctl.signal })).ok
  } catch {
    return false
  } finally {
    clearTimeout(timer)
  }
}

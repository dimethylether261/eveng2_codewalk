// The walk runs inside the glasses app itself.
// The Dart core (public/codewalk_core.js) finds spots and writes dialogues; this file feeds it the
// Even Hub location, keeps its data in the Even Hub storage and serves the glasses what they draw.
import { AppLocationAccuracy, type AppLocation, type EvenAppBridge } from '@evenrealities/even_hub_sdk'
import type { Catalog, Core, LogItem, LogRange } from './core'
import type { Roads } from './minimap'
import { portraitPath } from './photo'
import type { WalkState } from './render'

export type Settings = {
  apiKey: string
  codename: string
  lang: 'ja' | 'en'
  themes: string[]
  frequency: 'more' | 'normal' | 'less'
  pinRange: 'today' | 'week' | 'all'
  contact: string
  adultConfirmed: boolean
  /** The minimap on the glasses' waiting screen (the glasses only: the core ignores it). */
  minimap: boolean
}

export const defaultSettings = (lang: 'ja' | 'en'): Settings => ({
  apiKey: '',
  codename: '',
  lang,
  themes: ['history', 'architecture', 'nature'],
  frequency: 'normal',
  pinRange: 'today',
  contact: '',
  adultConfirmed: false,
  minimap: true,
})

/** Settings saved by an older version (or by hand) never break the app: unknown values fall back. */
export function parseSettings(json: string, lang: 'ja' | 'en'): Settings {
  const d = defaultSettings(lang)
  let raw: Partial<Settings> = {}
  try {
    raw = (JSON.parse(json || '{}') ?? {}) as Partial<Settings>
  } catch {
    raw = {}
  }
  const pick = <T extends string>(v: unknown, allowed: readonly T[], fallback: T) =>
    allowed.includes(v as T) ? (v as T) : fallback
  return {
    apiKey: typeof raw.apiKey === 'string' ? raw.apiKey.trim() : '',
    codename: typeof raw.codename === 'string' ? raw.codename : '',
    lang: pick(raw.lang, ['ja', 'en'] as const, d.lang),
    themes: Array.isArray(raw.themes) && raw.themes.length ? raw.themes.filter(t => typeof t === 'string') : d.themes,
    frequency: pick(raw.frequency, ['more', 'normal', 'less'] as const, d.frequency),
    pinRange: pick(raw.pinRange, ['today', 'week', 'all'] as const, d.pinRange),
    contact: typeof raw.contact === 'string' ? raw.contact : '',
    adultConfirmed: raw.adultConfirmed === true,
    minimap: raw.minimap !== false,
  }
}

/** The glasses' status line while the location is stuck (one line: ~27 characters). */
const STALE = {
  ja: '位置が止まっています（常時表示の通知を確認）',
  en: 'Location stopped (check background notification)',
}

const month = (t = new Date()) => `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}`

/** A bridge call the host never answers must not freeze the app. */
export function within<T>(p: Promise<T>, fallback: T, ms = 5000): Promise<T> {
  return Promise.race([p.catch(() => fallback), new Promise<T>(r => setTimeout(() => r(fallback), ms))])
}

const KEY = { settings: 'cw.settings', store: 'cw.store', log: 'cw.log', spend: 'cw.spend' }

export class LocalLink {
  core: Core | null = null
  settings: Settings
  /** Why the walk can't run (shown on the phone page), or ''. */
  problem = ''
  private spend: Record<string, number> = {}
  private pending = false
  private stopLocation: (() => void) | null = null
  private photo: { url: string; blob: Blob } | null = null

  constructor(
    private bridge: EvenAppBridge,
    private onState: (s: WalkState | null) => void,
    /** The phone page should redraw (log, status, spend). */
    private onChange: () => void,
    lang: 'ja' | 'en',
  ) {
    this.settings = defaultSettings(lang)
  }

  private load = async (key: string) => (await within(this.bridge.getLocalStorage(key), '')) ?? ''
  private save = (key: string, value: string) => within(this.bridge.setLocalStorage(key, value), false)

  async start() {
    const [settings, store, log, spend] = await Promise.all(
      [KEY.settings, KEY.store, KEY.log, KEY.spend].map(k => this.load(k)),
    )
    this.settings = parseSettings(settings, this.settings.lang)
    try {
      this.spend = JSON.parse(spend || '{}') as Record<string, number>
    } catch {
      this.spend = {}
    }
    const create = globalThis.createCodewalkCore
    if (!create) {
      this.problem = 'core'
      this.onChange()
      return
    }
    this.core = create(
      {
        changed: () => this.changed(),
        save: (key, value) => this.save(key === 'store' ? KEY.store : KEY.log, value),
        spend: usd => {
          const m = month()
          this.spend[m] = (this.spend[m] ?? 0) + usd
          this.save(KEY.spend, JSON.stringify(this.spend))
          this.onChange()
        },
        debug: message => console.debug('[core]', message),
      },
      store,
      log,
      JSON.stringify(this.settings),
    )
    this.core.start()
    await this.startLocation()
    this.changed()
  }

  /** Developer builds only (VITE_CODEWALK_FAKE_POS="lat,lon"): walk slowly north from there, for the simulator. */
  private fakeWalk(): boolean {
    const fake = (import.meta.env.VITE_CODEWALK_FAKE_POS as string | undefined)?.split(',').map(Number)
    if (!fake || fake.length !== 2 || fake.some(Number.isNaN)) return false
    let [lat, lon] = fake
    const step = () => {
      lat += 0.00005 // ~5 m
      this.core?.position(lat, lon, 1.2)
    }
    step()
    setInterval(step, 5000)
    return true
  }

  private lastFixAt = 0
  private watchdog: ReturnType<typeof setInterval> | null = null

  /** The Even app keeps answering with its last fix when it stops locating (screen off without its
   * background-task notification): such a fix is not a position. */
  static staleMs = 15_000
  /** Say so after the fixes have been stale this long. */
  static staleNoticeMs = 20_000
  /** The location has stopped updating (shown on the glasses' status line and the phone page). */
  stale = false
  private staleSince = 0

  private fix(l: AppLocation | null) {
    if (!l || !Number.isFinite(l.latitude) || !Number.isFinite(l.longitude)) return
    const now = Date.now()
    this.lastFixAt = now
    if (this.problem === 'location') {
      this.problem = ''
      this.onChange()
    }
    if (l.timestamp && now - l.timestamp > LocalLink.staleMs) {
      this.staleSince ||= now
      if (!this.stale && now - this.staleSince >= LocalLink.staleNoticeMs) {
        this.stale = true
        this.changed()
      }
      return // not used for distance, the map or the radar
    }
    this.staleSince = 0
    if (this.stale) {
      this.stale = false
      this.changed()
    }
    this.core?.position(l.latitude, l.longitude, l.speed ?? 0)
  }

  /** Updates from the Even app, plus a one-off fix at start and whenever the updates go quiet: on a
   * real phone the update stream may stay silent (no first fix until moving, or not at all). */
  private async startLocation() {
    if (this.fakeWalk()) return
    this.stopLocation?.()
    this.stopLocation = this.bridge.onAppLocationChanged(l => this.fix(l))
    const started = await within(
      // distanceFilter 0, as in the spike that got a fix at once: the core ignores tiny moves itself
      this.bridge.startAppLocationUpdates({ accuracy: AppLocationAccuracy.High, intervalMs: 5000, distanceFilter: 0 }),
      false,
      15_000, // the first call may wait for the permission prompt
    )
    const startedAt = Date.now()
    let asking = false
    const ask = async () => {
      if (asking) return // one request at a time
      asking = true
      try {
        this.fix(await within(this.bridge.getAppLocation({ accuracy: AppLocationAccuracy.High, timeoutMs: 10_000 }), null, 12_000))
      } finally {
        asking = false
      }
    }
    await ask()
    if (this.watchdog) clearInterval(this.watchdog)
    this.watchdog = setInterval(async () => {
      const quiet = Date.now() - (this.lastFixAt || startedAt)
      if (quiet < LocalLink.quietMs) return
      await ask()
      // Still nothing: say so on the phone page (permission off, or the Even app can't get a fix).
      if (Date.now() - (this.lastFixAt || startedAt) >= LocalLink.giveUpMs && this.problem !== 'location') {
        this.problem = 'location'
        this.onChange()
      }
    }, LocalLink.pollMs)
    if (!started && !this.lastFixAt) this.problem = 'location'
  }

  /** Ask for a fix ourselves after this long without one, every [pollMs]; warn after [giveUpMs].
   * On a real phone the update stream barely fired, so these polls are the walk's positions: every
   * 5 s like the Android app's location stream (20 s left 30-50 m between updates). */
  static quietMs = 4_500 // under [pollMs]: with a silent stream, every poll asks
  static pollMs = 5_000
  static giveUpMs = 30_000

  /** Coalesce bursts of changes into one redraw. */
  private changed() {
    if (this.pending) return
    this.pending = true
    queueMicrotask(() => {
      this.pending = false
      const core = this.core
      const state = core ? (JSON.parse(core.state()) as WalkState) : null
      // A stopped location matters more than "standing by": put it on the glasses' status line.
      if (state && this.stale) state.status = STALE[this.settings.lang]
      this.onState(state)
      this.onChange()
    })
  }

  async stop() {
    this.stopLocation?.()
    this.stopLocation = null
    if (this.watchdog) clearInterval(this.watchdog)
    this.watchdog = null
    await within(this.bridge.stopAppLocationUpdates(), false)
    this.core?.stop()
    await this.core?.flush()
  }

  // --- what the glasses need ---------------------------------------------------------------------
  send(cmd: string) {
    this.core?.command(cmd)
  }

  async fetchRoads(): Promise<Roads> {
    return JSON.parse(this.core?.roads() ?? '{"version":0,"roads":[]}') as Roads
  }

  /** Character portraits ship with the app (public/characters). */
  async fetchPortrait(id: string): Promise<Blob> {
    const path = portraitPath(id)
    if (!path) throw new Error(`no portrait for ${id}`)
    const r = await fetch(path)
    if (!r.ok) throw new Error(`portrait ${r.status}`)
    return r.blob()
  }

  /** The spot photo (Wikimedia Commons), fetched once per call. */
  async fetchPhoto(): Promise<Blob> {
    const url = (JSON.parse(this.core?.state() ?? '{}') as WalkState).call?.photo?.url
    if (!url) throw new Error('no photo')
    if (this.photo?.url === url) return this.photo.blob
    const r = await fetch(url)
    if (!r.ok) throw new Error(`photo ${r.status}`)
    this.photo = { url, blob: await r.blob() }
    return this.photo.blob
  }

  // --- the phone page ---------------------------------------------------------------------------
  async saveSettings(patch: Partial<Settings>) {
    this.settings = { ...this.settings, ...patch }
    await this.save(KEY.settings, JSON.stringify(this.settings))
    this.core?.settings(JSON.stringify(this.settings))
    this.onChange()
  }

  catalog(): Catalog | null {
    return this.core ? (JSON.parse(this.core.catalog()) as Catalog) : null
  }

  logItems(range: LogRange = 'all'): LogItem[] {
    return this.core ? (JSON.parse(this.core.log(range)) as LogItem[]) : []
  }

  checkKey(): Promise<string> {
    return this.core ? this.core.checkKey() : Promise.resolve('error core')
  }

  replay(id: string) {
    this.core?.replay(id)
  }

  get walking() {
    return this.core?.walking() ?? false
  }

  toggleWalk() {
    if (!this.core) return
    if (this.core.walking()) this.core.stop()
    else this.core.start()
    this.changed()
  }

  get logCount() {
    return this.core?.logCount() ?? 0
  }

  get cachedDialogues() {
    return this.core?.cachedDialogues() ?? 0
  }

  async clearLog() {
    await this.core?.clearLog()
  }

  async clearCache() {
    await this.core?.clearCache()
    this.onChange()
  }

  get spentThisMonth() {
    return this.spend[month()] ?? 0
  }
}

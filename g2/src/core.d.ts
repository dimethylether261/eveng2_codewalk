// The standalone core: app/lib/standalone/js_main.dart compiled to public/codewalk_core.js
// (`npm run core`). It runs the walk (spots, dialogues, call log) inside the glasses app.

export interface CoreHost {
  /** Something on the glasses or the phone page changed. */
  changed(): void
  /** Persist a value ('store': engine cache, 'log': call log). */
  save(key: string, value: string): Promise<unknown>
  /** A finished generation cost this much (USD). */
  spend(usd: number): void
  debug(message: string): void
}

export interface Core {
  /** CoreSettings as JSON (apiKey, codename, lang, themes, frequency, pinRange, contact). */
  settings(json: string): void
  position(lat: number, lon: number, speed: number): void
  start(): void
  stop(): void
  walking(): boolean
  command(cmd: string): Promise<unknown>
  replay(id: string): Promise<unknown>
  /** The state the glasses draw (WalkState), plus call.photo.url. */
  state(): string
  roads(): string
  /** LogItem[] as JSON, newest first: today, the last 7 days, or all (at most 100). */
  log(range: LogRange): string
  /** Catalog as JSON. */
  catalog(): string
  /** 'ok' | 'bad_key' | 'no_key' | 'error …' */
  checkKey(): Promise<string>
  flush(): Promise<unknown>
  cachedDialogues(): number
  logCount(): number
  clearLog(): Promise<unknown>
  clearCache(): Promise<unknown>
}

/** The call log periods (as in the phone app's log): today, the last 7 days, everything. */
export type LogRange = 'today' | 'week' | 'all'

export type LogItem = {
  id: string
  at: number
  played: boolean
  spot: string
  theme: string
  specialist: string
  sources: { title: string; url: string }[]
}

export type Catalog = {
  lang: 'ja' | 'en'
  commander: { name: string; frequency: string }
  themes: { id: string; label: string; topics: string; name: string; frequency: string; adult: boolean }[]
  frequencies: Record<string, string>
  ranges: Record<string, string>
  aiNotice: string
}

declare global {
  // eslint-disable-next-line no-var
  var createCodewalkCore: ((host: CoreHost, storeJson: string, logJson: string, settingsJson: string) => Core) | undefined
}

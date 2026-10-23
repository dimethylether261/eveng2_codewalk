// The phone page of the glasses app (shown in the Even app), in three tabs: the walk (start / end
// and notices), the call log (today / this week / all) and the settings. Built once; only the live
// parts (status, spend, log) are redrawn, so typing in a field is never interrupted by a location
// update.
import type { Catalog, LogItem, LogRange } from './core'
import type { LocalLink, Settings } from './local'
import type { WalkState } from './render'

const TEXT = {
  ja: {
    title: 'CODEWALK',
    lead: 'メガネだけで動くモードです。歩くと近くの場所について無線が入ります。',
    stale: '位置が更新されていません。スマホの画面を消しているなら、Even アプリの設定の「バックグラウンドタスク」で「常時表示の通知」をオンにしてください。画面をつけると再開します。',
    background: 'スマホの画面を消して歩くときは、Even アプリの設定の「バックグラウンドタスク」で「常時表示の通知」をオンにしてください。オフのままだと、画面オフ中は位置が更新されず、無線が入りません。',
    start: '散歩を始める',
    stop: '散歩を終える',
    walking: '散歩中',
    idle: '停止中',
    apiKey: 'Claude API キー',
    apiKeyHelp: 'ご自身のキーを使います。利用料はキーに課金されます。キーはこの端末の Even アプリ内にだけ保存します。',
    saveCheck: '保存して確認',
    keyOk: 'キーを確認しました',
    keyBad: 'キーが正しくありません',
    keyNone: 'キーを入れてください',
    keyError: (e: string) => `確認できませんでした（${e}）`,
    keySaved: '保存済み',
    codename: 'コードネーム',
    codenameHelp: '無線で呼ばれる名前（空ならウォーカー）',
    themes: '聞くテーマ',
    adult: '20歳以上です（酒・食文化のテーマに必要）',
    frequency: '無線の頻度',
    pins: '地図のピン',
    minimap: 'メガネの待機画面に地図を出す（散歩中）',
    contact: '連絡先（任意）',
    contactHelp: 'Wikipedia と OpenStreetMap（Nominatim）に送る識別情報に入れます（メールアドレスや URL）',
    mapCredit: '地図データ',
    spent: (usd: string) => `今月の Claude 利用額（概算）: $${usd}`,
    tabWalk: '散歩',
    tabLog: '無線ログ',
    tabSettings: '設定',
    log: '無線ログ',
    logEmpty: 'まだ無線はありません',
    logEmptyRange: 'この期間の無線はありません',
    sources: (n: number) => `出典（${n}件）`,
    play: '再生',
    unplayed: '未再生',
    noCore: 'アプリの読み込みに失敗しました。Even アプリでもう一度開いてください。',
    noLocation: '位置情報を取得できません。Even アプリの位置情報の許可（常に許可）と、設定の「バックグラウンドタスク」の「常時表示の通知」がオンかを確認してください。',
    atLeastOne: 'テーマは1つ以上選んでください',
    saved: '保存データ',
    logCount: (n: number) => `保存されている無線: ${n}件（この端末だけに保存）`,
    clearLog: '無線ログをすべて消す',
    clearLogNote: '受けた無線と地図のピンが消えます。元に戻せません。会話のキャッシュは残るので、同じ会話がまた流れることがあります。',
    cacheCount: (n: number) => `保存済みの会話: ${n}件（同じ場所でもう一度流れるときに使う。30日で作り直し）`,
    clearCache: '会話のキャッシュを消す',
    clearCacheNote: '保存済みの会話と周りの場所の検索結果を消します。新しい会話が聞けますが、Claude の利用料がかかり、無線が入るまで少し時間がかかります。',
    confirm: 'もう一度押すと消します',
    done: '消しました',
  },
  en: {
    title: 'CODEWALK',
    lead: 'Glasses-only mode. Walk around and radio calls come in about places nearby.',
    stale: 'The location is not updating. If the phone screen is off, turn on the persistent notification under Background tasks in the Even app settings; turning the screen on resumes it.',
    background: 'To walk with the phone screen off, turn on the persistent notification under Background tasks in the Even app settings. Without it, the location stops updating while the screen is off and no calls come in.',
    start: 'Start walk',
    stop: 'End walk',
    walking: 'Walking',
    idle: 'Stopped',
    apiKey: 'Claude API key',
    apiKeyHelp: 'Your own key; usage is billed to it. The key is stored only in the Even app on this phone.',
    saveCheck: 'Save and check',
    keyOk: 'Key checked',
    keyBad: 'This key is not valid',
    keyNone: 'Enter a key',
    keyError: (e: string) => `Could not check (${e})`,
    keySaved: 'Saved',
    codename: 'Codename',
    codenameHelp: 'What the radio calls you (Walker if empty)',
    themes: 'Topics',
    adult: 'I am 20 or older (needed for the food and drink topic)',
    frequency: 'How often',
    pins: 'Map pins',
    minimap: 'Show the map on the glasses while waiting (on a walk)',
    contact: 'Contact (optional)',
    contactHelp: 'Sent to Wikipedia and OpenStreetMap (Nominatim) to identify the app (email or URL)',
    mapCredit: 'Map data',
    spent: (usd: string) => `Claude spend this month (estimate): $${usd}`,
    tabWalk: 'Walk',
    tabLog: 'Call log',
    tabSettings: 'Settings',
    log: 'Call log',
    logEmpty: 'No calls yet',
    logEmptyRange: 'No calls in this period',
    sources: (n: number) => `Sources (${n})`,
    play: 'Play',
    unplayed: 'Not played',
    noCore: 'The app failed to load. Open it again from the Even app.',
    noLocation: 'No location. Check that the Even app may always use the location, and that the persistent notification under Background tasks is on in its settings.',
    atLeastOne: 'Choose at least one topic',
    saved: 'Saved data',
    logCount: (n: number) => `Saved calls: ${n} (stored only on this phone)`,
    clearLog: 'Delete the whole call log',
    clearLogNote: 'Every call and map pin is deleted; this cannot be undone. The conversation cache stays, so you may hear the same conversation again.',
    cacheCount: (n: number) => `Cached conversations: ${n} (reused when a place calls again; rewritten after 30 days)`,
    clearCache: 'Delete the conversation cache',
    clearCacheNote: 'Cached conversations and nearby place lookups are deleted. You hear new conversations, but it costs Claude usage and calls take a little longer.',
    confirm: 'Tap again to delete',
    done: 'Deleted',
  },
}

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

type Tab = 'walk' | 'log' | 'settings'
const TABS: Tab[] = ['walk', 'log', 'settings']
const RANGES: LogRange[] = ['today', 'week', 'all']

export class Companion {
  private built = ''
  private state: WalkState | null = null
  /** The open tab: the walk, or the settings while there is no API key yet. */
  private tab: Tab | null = null
  private range: LogRange = 'today'

  constructor(
    private root: HTMLElement,
    private link: LocalLink,
  ) {}

  setState(s: WalkState | null) {
    this.state = s
  }

  /** Redraw: the whole form when the language changes, otherwise only the live parts. */
  render() {
    const s = this.link.settings
    const cat = this.link.catalog()
    const key = `${s.lang}|${cat ? 'core' : this.link.problem}`
    if (key !== this.built) {
      this.build(s, cat)
      this.built = key
    }
    this.live()
  }

  private get t() {
    return TEXT[this.link.settings.lang]
  }

  private build(s: Settings, cat: Catalog | null) {
    const t = this.t
    if (!cat) {
      this.root.innerHTML = `<main class="cw"><h1>${t.title}</h1><p class="warn">${esc(this.link.problem === 'core' ? t.noCore : '…')}</p></main>`
      return
    }
    const themes = cat.themes
      .map(
        th => `<label class="theme"><input type="checkbox" data-theme="${th.id}" ${s.themes.includes(th.id) ? 'checked' : ''} ${th.adult && !s.adultConfirmed ? 'disabled' : ''}>
          <span><b>${esc(th.label)}</b> ${esc(th.name)} ${th.frequency}<small>${esc(th.topics)}</small></span></label>`,
      )
      .join('')
    const options = (values: Record<string, string>, current: string) =>
      Object.entries(values)
        .map(([v, label]) => `<option value="${v}" ${v === current ? 'selected' : ''}>${esc(label)}</option>`)
        .join('')
    this.tab ??= s.apiKey ? 'walk' : 'settings'
    const tabLabel = { walk: t.tabWalk, log: t.tabLog, settings: t.tabSettings }
    this.root.innerHTML = `
      <main class="cw">
        <h1>${t.title}</h1>
        <nav class="tabs" role="tablist">${TABS.map(
          tab => `<button role="tab" id="cw-tab-${tab}" data-tab="${tab}" aria-controls="cw-panel-${tab}">${tabLabel[tab]}</button>`,
        ).join('')}</nav>

        <section role="tabpanel" id="cw-panel-walk" aria-labelledby="cw-tab-walk">
        <p class="lead">${t.lead}</p>
        <section class="walk"><span id="cw-status"></span><button id="cw-walk"></button></section>
        <p class="warn" id="cw-problem" hidden></p>
        <p class="warn">${t.background}</p>
        <p class="note">${esc(cat.aiNotice)}</p>
        </section>

        <section role="tabpanel" id="cw-panel-log" aria-labelledby="cw-tab-log">
        <div class="ranges" role="group" aria-label="${t.log}">${RANGES.map(
          r => `<button data-range="${r}"><span>${esc(cat.ranges[r] ?? r)}</span> <small data-count="${r}"></small></button>`,
        ).join('')}</div>
        <ul id="cw-log"></ul>
        </section>

        <section role="tabpanel" id="cw-panel-settings" aria-labelledby="cw-tab-settings">
        <label class="field"><span>${t.apiKey}</span>
          <span class="row"><input id="cw-key" type="password" autocomplete="off" placeholder="${s.apiKey ? t.keySaved : 'sk-ant-…'}"><button id="cw-key-save">${t.saveCheck}</button></span>
          <small id="cw-key-state">${t.apiKeyHelp}</small></label>

        <label class="field"><span>${t.codename}</span><input id="cw-codename" value="${esc(s.codename)}" placeholder="${s.lang === 'en' ? 'Walker' : 'ウォーカー'}"><small>${t.codenameHelp}</small></label>

        <fieldset><legend>${t.themes}</legend>${themes}
          <label class="theme"><input type="checkbox" id="cw-adult" ${s.adultConfirmed ? 'checked' : ''}><span>${t.adult}</span></label>
          <small id="cw-theme-warn" class="warn" hidden>${t.atLeastOne}</small></fieldset>

        <label class="field"><span>${t.frequency}</span><select id="cw-frequency">${options(cat.frequencies, s.frequency)}</select></label>
        <label class="field"><span>${t.pins}</span><select id="cw-pins">${options(cat.ranges, s.pinRange)}</select></label>
        <label class="theme"><input type="checkbox" id="cw-minimap" ${s.minimap ? 'checked' : ''}><span>${t.minimap}</span></label>
        <label class="field"><span>${t.contact}</span><input id="cw-contact" value="${esc(s.contact)}" inputmode="email"><small>${t.contactHelp}</small></label>
        <p class="note" id="cw-spent"></p>

        <h2>${t.saved}</h2>
        <section class="saved">
          <small id="cw-log-count"></small>
          <button class="danger" id="cw-clear-log">${t.clearLog}</button>
          <small>${t.clearLogNote}</small>
          <small id="cw-cache-count"></small>
          <button class="danger" id="cw-clear-cache">${t.clearCache}</button>
          <small>${t.clearCacheNote}</small>
        </section>
        </section>

        <small>${t.mapCredit} © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors · © <a href="https://openmaptiles.org/">OpenMapTiles</a> · <a href="https://openfreemap.org/">OpenFreeMap</a></small>
      </main>`
    this.wire()
  }

  private el<T extends HTMLElement>(id: string) {
    return this.root.querySelector<T>(`#${id}`)!
  }

  /** Show the open tab and the chosen period (no rebuild: fields keep what is typed). */
  private showTab() {
    for (const tab of TABS) {
      const on = tab === this.tab
      this.el(`cw-tab-${tab}`).setAttribute('aria-selected', String(on))
      this.el(`cw-panel-${tab}`).hidden = !on
    }
    this.root.querySelectorAll<HTMLButtonElement>('button[data-range]').forEach(b =>
      b.setAttribute('aria-pressed', String(b.dataset.range === this.range)),
    )
  }

  private wire() {
    const t = this.t
    this.root.querySelectorAll<HTMLButtonElement>('button[data-tab]').forEach(b => {
      b.onclick = () => {
        this.tab = b.dataset.tab as Tab
        this.showTab()
        window.scrollTo(0, 0)
      }
    })
    this.root.querySelectorAll<HTMLButtonElement>('button[data-range]').forEach(b => {
      b.onclick = () => {
        this.range = b.dataset.range as LogRange
        this.showTab()
        this.live()
      }
    })
    this.showTab()
    this.el('cw-walk').onclick = () => this.link.toggleWalk()
    this.el('cw-key-save').onclick = async () => {
      const input = this.el<HTMLInputElement>('cw-key')
      const state = this.el('cw-key-state')
      const value = input.value.trim()
      if (value) await this.link.saveSettings({ apiKey: value })
      input.value = ''
      input.placeholder = this.link.settings.apiKey ? t.keySaved : 'sk-ant-…'
      state.textContent = '…'
      const r = await this.link.checkKey()
      state.textContent = r === 'ok' ? t.keyOk : r === 'bad_key' ? t.keyBad : r === 'no_key' ? t.keyNone : t.keyError(r)
    }
    const text = (id: string, field: 'codename' | 'contact') => {
      const input = this.el<HTMLInputElement>(id)
      input.onchange = () => this.link.saveSettings({ [field]: input.value.trim() })
    }
    text('cw-codename', 'codename')
    text('cw-contact', 'contact')
    this.el<HTMLSelectElement>('cw-frequency').onchange = e =>
      this.link.saveSettings({ frequency: (e.target as HTMLSelectElement).value as Settings['frequency'] })
    this.el<HTMLSelectElement>('cw-pins').onchange = e =>
      this.link.saveSettings({ pinRange: (e.target as HTMLSelectElement).value as Settings['pinRange'] })
    this.el<HTMLInputElement>('cw-minimap').onchange = e =>
      this.link.saveSettings({ minimap: (e.target as HTMLInputElement).checked })
    this.el<HTMLInputElement>('cw-adult').onchange = e => {
      const on = (e.target as HTMLInputElement).checked
      const cat = this.link.catalog()
      const adult = new Set(cat?.themes.filter(th => th.adult).map(th => th.id))
      this.root.querySelectorAll<HTMLInputElement>('input[data-theme]').forEach(box => {
        if (adult.has(box.dataset.theme!)) {
          box.disabled = !on
          if (!on) box.checked = false
        }
      })
      const themes = on ? this.link.settings.themes : this.link.settings.themes.filter(id => !adult.has(id))
      this.link.saveSettings({ adultConfirmed: on, themes: themes.length ? themes : ['history'] })
    }
    // confirm() may not show in the Even app's WebView: the first tap arms the button, the second deletes.
    const twoTap = (id: string, label: string, run: () => Promise<void>) => {
      const button = this.el<HTMLButtonElement>(id)
      let armed = 0
      button.onclick = async () => {
        if (!armed) {
          button.textContent = t.confirm
          armed = window.setTimeout(() => {
            armed = 0
            button.textContent = label
          }, 4000)
          return
        }
        clearTimeout(armed)
        armed = 0
        await run()
        button.textContent = t.done
        setTimeout(() => (button.textContent = label), 2000)
        this.live()
      }
    }
    twoTap('cw-clear-log', t.clearLog, () => this.link.clearLog())
    twoTap('cw-clear-cache', t.clearCache, () => this.link.clearCache())
    this.root.querySelectorAll<HTMLInputElement>('input[data-theme]').forEach(box => {
      box.onchange = () => {
        const chosen = [...this.root.querySelectorAll<HTMLInputElement>('input[data-theme]:checked')].map(b => b.dataset.theme!)
        const warn = this.el('cw-theme-warn')
        if (!chosen.length) {
          box.checked = true // at least one topic stays on
          warn.hidden = false
          return
        }
        warn.hidden = true
        this.link.saveSettings({ themes: chosen })
      }
    })
  }

  private live() {
    if (!this.link.catalog()) return
    const t = this.t
    const walking = this.link.walking
    const status = this.state?.status ?? ''
    this.el('cw-status').textContent = `${walking ? t.walking : t.idle}${status ? ` · ${status}` : ''}`
    this.el('cw-walk').textContent = walking ? t.stop : t.start
    const problem = this.el('cw-problem')
    problem.hidden = this.link.problem !== 'location' && !this.link.stale
    problem.textContent = this.link.problem === 'location' ? t.noLocation : t.stale
    this.el('cw-spent').textContent = t.spent(this.link.spentThisMonth.toFixed(2))
    for (const r of RANGES) {
      const n = r === 'all' ? this.link.logCount : this.link.logItems(r).length
      this.el(`cw-panel-log`).querySelector(`[data-count="${r}"]`)!.textContent = String(n)
    }
    this.el('cw-log-count').textContent = t.logCount(this.link.logCount)
    this.el('cw-cache-count').textContent = t.cacheCount(this.link.cachedDialogues)
    this.renderLog(this.link.logItems(this.range))
  }

  private logKey = ''
  /** One compact row per call: place and time, then the character and "not played"; the sources
   * stay folded until tapped. */
  private renderLog(items: LogItem[]) {
    const lang = this.link.settings.lang
    const today = new Date().toDateString()
    const key = `${this.range}|${lang}|${today}|` + items.map(i => `${i.id}${i.played ? 1 : 0}`).join(',')
    if (key === this.logKey) return
    this.logKey = key
    const t = this.t
    const time = (ms: number) => {
      const d = new Date(ms)
      return d.toLocaleString(lang === 'ja' ? 'ja-JP' : 'en-US', {
        ...(d.toDateString() === today ? {} : { month: 'numeric', day: 'numeric' }),
        hour: '2-digit', minute: '2-digit',
      })
    }
    const list = this.el('cw-log')
    list.innerHTML = items.length
      ? items
          .map(
            i => `<li><div>
              <div class="head"><b>${esc(i.spot)}</b><time>${time(i.at)}</time></div>
              <small>${esc(i.specialist)}${i.played ? '' : ` · <em>${t.unplayed}</em>`}</small>
              ${i.sources.length ? `<details><summary>${t.sources(i.sources.length)}</summary>${i.sources
                .map(s => `<a href="${esc(s.url)}" target="_blank" rel="noopener">${esc(s.title)}</a>`)
                .join('')}</details>` : ''}
              </div><button data-play="${i.id}">${t.play}</button></li>`,
          )
          .join('')
      : `<li class="empty">${this.range === 'all' ? t.logEmpty : t.logEmptyRange}</li>`
    list.querySelectorAll<HTMLButtonElement>('button[data-play]').forEach(b => (b.onclick = () => this.link.replay(b.dataset.play!)))
  }
}

// First launch: before anything starts, the phone page asks for the language (shown in both
// languages, since none is chosen yet) and then the mode, explained in that language.
import type { Mode } from './mode'
import type { Lang } from './render'

const TEXT = {
  ja: {
    modeTitle: '使い方を選んでください',
    modeLead: 'あとから画面の一番上で変えられます。',
    modes: {
      auto: ['自動（おすすめ）', 'スマホの CODEWALK アプリ（Android）が動いていれば連携し、なければメガネだけで動きます。迷ったらこれ。'],
      phone: ['スマホの CODEWALK と連携', 'スマホの CODEWALK アプリで散歩します。会話づくり・設定・ログはそちらで行います。'],
      standalone: ['メガネ単体', 'CODEWALK アプリなしで、このアプリだけで動きます（iPhone でも）。Claude の API キーが必要です。画面を消して歩くには、Even アプリの設定の「バックグラウンドタスク」で「常時表示の通知」をオンにします。'],
    } as Record<Mode, [string, string]>,
    start: 'はじめる',
    back: '言語を選び直す',
  },
  en: {
    modeTitle: 'How do you want to use it?',
    modeLead: 'You can change this later at the top of this page.',
    modes: {
      auto: ['Auto (recommended)', 'Uses the CODEWALK app on this phone (Android) when it runs, otherwise runs on the glasses alone. Pick this if unsure.'],
      phone: ['Linked to CODEWALK on this phone', 'Walk with the CODEWALK phone app; it writes the conversations and keeps the settings and log.'],
      standalone: ['Glasses only', 'Runs in this app alone, without the CODEWALK app (iPhone too). Needs your Claude API key. To walk with the screen off, turn on the persistent notification under Background tasks in the Even app settings.'],
    } as Record<Mode, [string, string]>,
    start: 'Start',
    back: 'Choose the language again',
  },
}

export function runOnboarding(root: HTMLElement, suggested: Lang): Promise<{ lang: Lang; mode: Mode }> {
  return new Promise(resolve => {
    const language = () => {
      root.className = ''
      root.innerHTML = `<main class="cw onboarding">
        <h1>CODEWALK</h1>
        <p class="lead">言語を選んでください<br>Choose your language</p>
        <div class="choices">
          <button data-lang="ja" class="${suggested === 'ja' ? 'primary' : ''}">日本語</button>
          <button data-lang="en" class="${suggested === 'en' ? 'primary' : ''}">English</button>
        </div>
      </main>`
      root.querySelectorAll<HTMLButtonElement>('button[data-lang]').forEach(b => {
        b.onclick = () => mode(b.dataset.lang === 'en' ? 'en' : 'ja')
      })
    }
    const mode = (lang: Lang) => {
      const t = TEXT[lang]
      root.innerHTML = `<main class="cw onboarding">
        <h1>CODEWALK</h1>
        <h2>${t.modeTitle}</h2>
        <p class="note">${t.modeLead}</p>
        <fieldset class="modes">
          ${(Object.keys(t.modes) as Mode[])
            .map(
              m => `<label class="mode-choice"><input type="radio" name="cw-first-mode" value="${m}" ${m === 'auto' ? 'checked' : ''}>
                <span><b>${t.modes[m][0]}</b><small>${t.modes[m][1]}</small></span></label>`,
            )
            .join('')}
        </fieldset>
        <button id="cw-start">${t.start}</button>
        <button id="cw-back" class="link">${t.back}</button>
      </main>`
      root.querySelector<HTMLButtonElement>('#cw-back')!.onclick = language
      root.querySelector<HTMLButtonElement>('#cw-start')!.onclick = () => {
        const picked = root.querySelector<HTMLInputElement>('input[name="cw-first-mode"]:checked')?.value as Mode | undefined
        resolve({ lang, mode: picked ?? 'auto' })
      }
    }
    language()
  })
}

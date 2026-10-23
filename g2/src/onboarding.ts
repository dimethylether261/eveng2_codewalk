// First launch: before anything starts, the phone page asks for the language (shown in both
// languages, since none is chosen yet) and then says what the app needs, in that language.
import type { Lang } from './render'

const TEXT = {
  ja: {
    introTitle: 'はじめる前に',
    intro: [
      'Claude の API キーが必要です（次の画面の設定で入れます）。利用料はキーに課金されます。',
      'スマホの画面を消して歩くには、Even アプリの設定の「バックグラウンドタスク」で「常時表示の通知」をオンにします。',
    ],
    start: 'はじめる',
    back: '言語を選び直す',
  },
  en: {
    introTitle: 'Before you start',
    intro: [
      'You need your own Claude API key (enter it in the settings on the next page). Usage is billed to it.',
      'To walk with the phone screen off, turn on the persistent notification under Background tasks in the Even app settings.',
    ],
    start: 'Start',
    back: 'Choose the language again',
  },
}

export function runOnboarding(root: HTMLElement, suggested: Lang): Promise<{ lang: Lang }> {
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
        b.onclick = () => intro(b.dataset.lang === 'en' ? 'en' : 'ja')
      })
    }
    const intro = (lang: Lang) => {
      const t = TEXT[lang]
      root.innerHTML = `<main class="cw onboarding">
        <h1>CODEWALK</h1>
        <h2>${t.introTitle}</h2>
        ${t.intro.map(p => `<p>${p}</p>`).join('')}
        <button id="cw-start">${t.start}</button>
        <button id="cw-back" class="link">${t.back}</button>
      </main>`
      root.querySelector<HTMLButtonElement>('#cw-back')!.onclick = language
      root.querySelector<HTMLButtonElement>('#cw-start')!.onclick = () => resolve({ lang })
    }
    language()
  })
}

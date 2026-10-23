// The language bar at the top of the phone page (a first launch shows onboarding.ts before it).
import type { Lang } from './render'

/** The language chosen on the phone page (also the conversations'). */
export const LANG_KEY = 'cw.lang'

export const parseLang = (v: unknown, fallback: Lang): Lang => (v === 'ja' || v === 'en' ? v : fallback)

const TEXT = {
  ja: { language: '言語 / Language' },
  en: { language: 'Language / 言語' },
}

export function renderLangBar(root: HTMLElement, lang: Lang, onLang: (l: Lang) => void) {
  const t = TEXT[lang]
  root.innerHTML = `<label for="cw-lang">${t.language}</label>
    <select id="cw-lang">
      <option value="ja" ${lang === 'ja' ? 'selected' : ''}>日本語</option>
      <option value="en" ${lang === 'en' ? 'selected' : ''}>English</option>
    </select>`
  root.querySelector<HTMLSelectElement>('#cw-lang')!.onchange = e => onLang(parseLang((e.target as HTMLSelectElement).value, lang))
}

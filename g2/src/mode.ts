// Which source feeds the glasses, chosen under the language bar of the phone page:
// auto = the CODEWALK phone app if it answers when a source is chosen (at launch and on a mode
// change), else the glasses app alone.
import type { Lang } from './render'

export type Mode = 'auto' | 'phone' | 'standalone'
export type Active = 'phone' | 'standalone'
export const MODES: Mode[] = ['auto', 'phone', 'standalone']
export const MODE_KEY = 'cw.mode'

/** A saved value from an older version (or nothing) means auto. */
export const parseMode = (v: unknown): Mode => (MODES.includes(v as Mode) ? (v as Mode) : 'auto')

/** Which source to use: phone and standalone are fixed; auto asks [phoneAppRunning]. */
export async function choose(mode: Mode, phoneAppRunning: () => Promise<boolean>): Promise<Active> {
  if (mode !== 'auto') return mode
  return (await phoneAppRunning()) ? 'phone' : 'standalone'
}

const TEXT = {
  ja: {
    label: '接続モード',
    auto: '自動（スマホの CODEWALK があれば連携）',
    phone: 'スマホの CODEWALK と連携',
    standalone: 'メガネ単体',
    now: (a: Active) => `いまは: ${a === 'phone' ? 'スマホの CODEWALK と連携' : 'メガネ単体'}`,
  },
  en: {
    label: 'Mode',
    auto: 'Auto (use CODEWALK on this phone if it runs)',
    phone: 'Linked to CODEWALK on this phone',
    standalone: 'Glasses only',
    now: (a: Active) => `Now: ${a === 'phone' ? 'linked to CODEWALK on this phone' : 'glasses only'}`,
  },
}

/** The mode picker under the language bar. */
export function renderModeBar(root: HTMLElement, mode: Mode, active: Active, lang: Lang, onMode: (m: Mode) => void) {
  const t = TEXT[lang]
  root.innerHTML = `<label for="cw-mode">${t.label}</label>
    <select id="cw-mode">${MODES.map(m => `<option value="${m}" ${m === mode ? 'selected' : ''}>${t[m]}</option>`).join('')}</select>
    <small>${t.now(active)}</small>`
  root.querySelector<HTMLSelectElement>('#cw-mode')!.onchange = e => onMode(parseMode((e.target as HTMLSelectElement).value))
}

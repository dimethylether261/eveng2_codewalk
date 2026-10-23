// The phone page while linked to the CODEWALK phone app: how the link is doing, and the pairing
// code (shown in the phone app's settings) to enter once. Everything else happens in the phone app.
import { normalizeCode, type LinkStatus } from './link'
import type { Lang } from './render'

const TEXT = {
  ja: {
    connected: 'スマホの CODEWALK とつながっています。メガネを見てください。',
    offline: 'スマホの CODEWALK を探しています…',
    unpaired: 'スマホの CODEWALK の「設定 → Even G2」にあるペアリングコードを入れてください。',
    locked: '違うコードが続いたため、スマホの CODEWALK が数分間つながりを止めています。少し待ってから、コードを入れ直してください。',
    code: 'ペアリングコード',
    save: 'つなぐ',
  },
  en: {
    connected: 'Connected to CODEWALK on your phone. Look at your glasses.',
    offline: 'Looking for CODEWALK on your phone…',
    unpaired: 'Enter the pairing code from Settings → Even G2 in the CODEWALK phone app.',
    locked: 'After several wrong codes, the CODEWALK phone app stops the link for a few minutes. Wait a little, then enter the code again.',
    code: 'Pairing code',
    save: 'Connect',
  },
}

/** Draws the page; the code field keeps what is typed while only the status changes. */
export class PhonePage {
  private built = ''

  constructor(
    private root: HTMLElement,
    private onCode: (code: string) => void,
  ) {}

  render(lang: Lang, status: LinkStatus, code: string) {
    const t = TEXT[lang]
    if (this.built !== lang) {
      this.built = lang
      this.root.className = ''
      this.root.innerHTML = `<main class="cw">
        <h1>CODEWALK</h1>
        <p id="cw-link-status"></p>
        <label class="field"><span>${t.code}</span>
          <span class="row"><input id="cw-pair" autocomplete="off" autocapitalize="characters" placeholder="ABCD-EFGH"><button id="cw-pair-save">${t.save}</button></span></label>
      </main>`
      const input = this.root.querySelector<HTMLInputElement>('#cw-pair')!
      input.value = code
      this.root.querySelector<HTMLButtonElement>('#cw-pair-save')!.onclick = () => this.onCode(normalizeCode(input.value))
    }
    this.root.querySelector('#cw-link-status')!.textContent = t[status]
  }
}

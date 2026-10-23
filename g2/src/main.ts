// CODEWALK on Even G2: shows incoming radio calls and the dialogue.
// The walk runs inside this app (LocalLink: the Dart core in public/codewalk_core.js finds spots
// and writes dialogues here); this file draws its state on the glasses and forwards gestures.
import {
  CreateStartUpPageContainer,
  EventSourceType,
  ImageContainerProperty,
  ImageRawDataUpdate,
  OsEventTypeList,
  RebuildPageContainer,
  TextContainerProperty,
  TextContainerUpgrade,
  waitForEvenAppBridge,
} from '@evenrealities/even_hub_sdk'
import { Companion } from './companion'
import { LANG_KEY, parseLang, renderLangBar } from './lang'
import { LocalLink, within } from './local'
import { runOnboarding } from './onboarding'
import { draw, pngBytes, shouldRedraw, type Drawn, type Roads } from './minimap'
import { photoPng, portraitTone } from './photo'
import {
  BLINK_MS,
  BLINK_PERIOD_MS,
  FACE_H,
  FACE_W,
  blink,
  clock,
  command,
  layoutKey,
  render,
  setupScreen,
  type Gesture,
  type Img,
  type Lang,
  type WalkState,
  type Screen,
} from './render'

const companion = document.getElementById('app')
const langBar = document.getElementById('lang')

function texts(s: Screen) {
  return s.blocks.map(
    b =>
      new TextContainerProperty({
        xPosition: b.x, yPosition: b.y, width: b.w, height: b.h,
        borderWidth: b.frame ? 1 : 0, borderColor: 8, borderRadius: b.frame ? 4 : 0, paddingLength: b.frame ? 8 : 4,
        containerID: b.id, containerName: b.name, content: b.content, isEventCapture: b.capture ? 1 : 0,
        ...(b.brightness !== undefined ? { textColor: b.brightness } : {}),
      }),
  )
}

function images(s: Screen) {
  return s.images.map(
    i => new ImageContainerProperty({ xPosition: i.x, yPosition: i.y, width: i.w, height: i.h, containerID: i.id, containerName: i.name }),
  )
}

const bridge = await waitForEvenAppBridge()

let shown: Screen = render(null)
const created = await bridge.createStartUpPageContainer(
  new CreateStartUpPageContainer({ containerTotalNum: shown.blocks.length, textObject: texts(shown) }),
)
if (created !== 0) console.error('createStartUpPageContainer failed:', created)

async function pushImage(img: Img | undefined, png: Uint8Array) {
  if (!img) return
  const result = await bridge.updateImageRawData(
    new ImageRawDataUpdate({ containerID: img.id, containerName: img.name, imageData: png }),
  )
  if (result !== 'success') console.error(`updateImageRawData(${img.name}):`, result)
}
const imageOf = (s: Screen, kind: Img['kind']) => s.images.find(i => i.kind === kind)

// Minimap: roads are fetched only when their version changes; the image is pushed only when it changes.
const canvas = document.createElement('canvas')
let roads: Roads | null = null
let roadsLoading = 0
let drawn: Drawn | null = null

async function pushMap(s: Screen, rebuilt: boolean) {
  const map = s.map
  if (!map) return
  if (map.roadsVersion > 0 && roads?.version !== map.roadsVersion && roadsLoading !== map.roadsVersion) {
    roadsLoading = map.roadsVersion
    if (!link) return
    link
      .fetchRoads()
      .then(r => {
        roads = r
        show(screenNow()) // redraw with the new roads
      })
      .catch(() => (roadsLoading = 0))
  }
  const now = Date.now()
  const rv = roads?.version ?? 0
  if (!rebuilt && !shouldRedraw(drawn, map, rv, now)) return
  draw(canvas, map, roads)
  await pushImage(imageOf(s, 'map'), pngBytes(canvas))
  drawn = { pos: map.pos, roadsVersion: rv, heard: map.heard.length, at: now }
}

// Portrait: pushed when the speaker changes (one small image per line at most); PNGs cached per character.
let faceShown: string | null = null
const faces = new Map<string, Uint8Array>()

async function pushPortrait(s: Screen, rebuilt: boolean) {
  const id = s.portrait
  if (id === null) return
  if (rebuilt) faceShown = null
  if (faceShown === id) return
  let png = faces.get(id)
  if (!png) {
    if (!link) return
    png = await photoPng(await link.fetchPortrait(id), FACE_W, FACE_H, portraitTone(id))
    faces.set(id, png)
  }
  await pushImage(imageOf(s, 'face'), png)
  faceShown = id
}

// Photo: fetched and converted once per call, pushed again only when the page was rebuilt.
let photoShown: number | null = null
let photoCache: { key: number; png: Uint8Array } | null = null

async function pushPhoto(s: Screen, rebuilt: boolean) {
  const key = s.photo
  if (key === null) return
  if (rebuilt) photoShown = null
  if (photoShown === key) return
  if (photoCache?.key !== key) {
    if (!link) return
    photoCache = { key, png: await photoPng(await link.fetchPhoto()) }
  }
  await pushImage(imageOf(s, 'photo'), photoCache.png)
  photoShown = key
}

// Serialize writes so quick taps can't interleave updates.
let writing: Promise<unknown> = Promise.resolve()
function show(next: Screen, force = false) {
  writing = writing.then(async () => {
    const rebuild = force || layoutKey(next) !== layoutKey(shown)
    if (rebuild) {
      const t = texts(next)
      const i = images(next)
      await bridge.rebuildPageContainer(
        new RebuildPageContainer({ containerTotalNum: t.length + i.length, textObject: t, imageObject: i }),
      )
    } else {
      // Same containers: update only the texts that changed (fast, no flicker).
      for (const b of next.blocks) {
        const old = shown.blocks.find(o => o.id === b.id)
        if (old?.content !== b.content) {
          await bridge.textContainerUpgrade(new TextContainerUpgrade({ containerID: b.id, containerName: b.name, content: b.content }))
        }
      }
    }
    shown = next
    // Image data can only be sent after the page exists, and never two at once (this chain is serial).
    try {
      await pushMap(next, rebuild)
      await pushPortrait(next, rebuild)
      await pushPhoto(next, rebuild)
    } catch (e) {
      console.error('image:', e) // the text screen keeps working without the images
    }
  })
}

let state: WalkState | null = null
let lastLang: Lang = navigator.language?.startsWith('ja') ? 'ja' : 'en' // until a language is chosen
// Incoming call: blink the title for a few seconds (only its text changes: no flicker).
let ringAt = 0
function screenNow(): Screen {
  if (state?.lang) lastLang = state.lang
  const s = render(state, lastLang, new Date(), link?.settings.minimap ?? true)
  if (s.mode !== 'incoming') ringAt = 0
  else if (!ringAt) ringAt = Date.now()
  return blink(s, ringAt ? Date.now() - ringAt : 0)
}
setInterval(() => {
  if (ringAt && Date.now() - ringAt <= BLINK_MS + BLINK_PERIOD_MS) show(screenNow())
}, BLINK_PERIOD_MS)
// Waiting screen: the clock moves on (only its text is sent, once a minute).
setInterval(() => {
  const old = shown.blocks.find(b => b.name === 'clock')
  if (old && old.content !== clock(new Date())) show(screenNow())
}, 1000)

let link: LocalLink | null = null
const savedLang = await within(bridge.getLocalStorage(LANG_KEY), '')
/** The language picked on the phone page (until then: the phone's language). */
let chosenLang: Lang = parseLang(savedLang, lastLang)
lastLang = chosenLang

function drawLangBar() {
  if (langBar) renderLangBar(langBar, lastLang, l => switchLang(l))
}

async function switchLang(next: Lang) {
  chosenLang = lastLang = next
  await within(bridge.setLocalStorage(LANG_KEY, next), false)
  await link?.saveSettings({ lang: next }) // conversations, glasses and the page follow
  drawLangBar()
  show(screenNow())
}

/** Start the walk core and the phone page (once, after the first-launch questions). */
async function connect() {
  let page: Companion | null = null
  const local: LocalLink = new LocalLink(
    bridge,
    s => {
      state = s
      page?.setState(s)
      show(screenNow())
    },
    () => {
      lastLang = local.settings.lang
      drawLangBar()
      page?.render()
      show(screenNow()) // settings such as the minimap show on the glasses at once
    },
    lastLang,
  )
  if (companion) {
    companion.className = ''
    companion.textContent = ''
    page = new Companion(companion, local)
  }
  link = local
  await local.start()
  if (local.settings.lang !== chosenLang) await local.saveSettings({ lang: chosenLang })
  page?.render()
  drawLangBar()
  show(screenNow(), true)
}

// First launch (no language saved yet): ask for the language before anything starts.
// (Developer builds with a fake walk, or VITE_CODEWALK_SKIP_SETUP for screenshots, skip it: the
// simulator can't tap the phone page.)
if (!savedLang && companion && !import.meta.env.VITE_CODEWALK_FAKE_POS && !import.meta.env.VITE_CODEWALK_SKIP_SETUP) {
  show(setupScreen())
  const first = await runOnboarding(companion, lastLang)
  chosenLang = lastLang = first.lang
  await within(bridge.setLocalStorage(LANG_KEY, first.lang), false)
}
await connect()

// CLICK_EVENT is 0 and protobuf drops zero fields, so a tap arrives with eventType undefined.
// Resolve the default inside the envelope check (see the official templates).
function eventTypeOf(envelope?: { eventType?: OsEventTypeList }): OsEventTypeList | null {
  if (!envelope) return null
  return envelope.eventType ?? OsEventTypeList.CLICK_EVENT
}

let lastGestureAt = 0
function gesture(g: Gesture) {
  const now = Date.now()
  if (now - lastGestureAt < 300) return // scroll events fire in bursts
  lastGestureAt = now
  const cmd = command(render(state, lastLang).mode, g)
  if (cmd) link?.send(cmd)
}

const unsubscribe = bridge.onEvenHubEvent(event => {
  const sysType = eventTypeOf(event.sysEvent)
  const textType = eventTypeOf(event.textEvent)
  const types = [sysType, textType]

  // Root page: double tap must always offer to exit (Even Hub review rule).
  if (types.includes(OsEventTypeList.DOUBLE_CLICK_EVENT)) {
    bridge.shutDownPageContainer(1)
    return
  }
  // Long press on the ring: start / end the walk (waiting screen only, see render.command).
  if (sysType === OsEventTypeList.LONG_PRESS_EVENT && event.sysEvent?.eventSource === EventSourceType.TOUCH_EVENT_FROM_RING) {
    return gesture('ringhold')
  }
  if (sysType === OsEventTypeList.LONG_PRESS_EVENT || sysType === OsEventTypeList.LONG_PRESS_RELEASE_EVENT) return
  if (types.includes(OsEventTypeList.SCROLL_TOP_EVENT)) return gesture('up')
  if (types.includes(OsEventTypeList.SCROLL_BOTTOM_EVENT)) return gesture('down')
  if (sysType === OsEventTypeList.FOREGROUND_ENTER_EVENT) {
    show(screenNow(), true) // the host cleared the page (e.g. after the exit prompt)
    return
  }
  if (sysType === OsEventTypeList.SYSTEM_EXIT_EVENT || sysType === OsEventTypeList.ABNORMAL_EXIT_EVENT) {
    link?.stop() // standalone: also saves the engine cache
    unsubscribe()
    return
  }
  if (types.includes(OsEventTypeList.CLICK_EVENT)) gesture('tap')
})

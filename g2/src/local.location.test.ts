import { afterEach, describe, expect, it, vi } from 'vitest'
import type { EvenAppBridge } from '@evenrealities/even_hub_sdk'
import type { Core } from './core'
import { LocalLink } from './local'

/** A core that only records positions. */
function fakeCore(positions: number[][]): Core {
  return {
    settings() {}, position: (lat, lon) => void positions.push([lat, lon]), start() {}, stop() {}, walking: () => true,
    command: async () => {}, replay: async () => {}, state: () => '{"v":1,"walking":true,"status":"","codename":"","incoming":null,"call":null}',
    roads: () => '{"version":0,"roads":[]}', log: () => '[]', catalog: () => 'null', checkKey: async () => 'ok', flush: async () => {},
    cachedDialogues: () => 0, logCount: () => 0, clearLog: async () => {}, clearCache: async () => {},
  }
}

/** An Even app whose update stream never fires (what a real phone did); [fix] answers getAppLocation. */
function fakeBridge(fix: { latitude: number; longitude: number; timestamp?: number } | null) {
  let asked = 0
  const bridge = {
    getLocalStorage: async () => '',
    setLocalStorage: async () => true,
    startAppLocationUpdates: async () => true,
    stopAppLocationUpdates: async () => true,
    onAppLocationChanged: () => () => {},
    getAppLocation: async () => {
      asked++
      return fix
    },
  } as unknown as EvenAppBridge
  return { bridge, asked: () => asked }
}

describe('standalone location', () => {
  afterEach(() => {
    vi.useRealTimers()
    delete (globalThis as { createCodewalkCore?: unknown }).createCodewalkCore
  })

  it('asks for a fix itself when the update stream stays silent', async () => {
    vi.useFakeTimers()
    const positions: number[][] = []
    globalThis.createCodewalkCore = () => fakeCore(positions)
    const { bridge, asked } = fakeBridge({ latitude: 35.62, longitude: 139.74 })
    const link = new LocalLink(bridge, () => {}, () => {}, 'ja')
    await link.start()
    expect(positions).toEqual([[35.62, 139.74]]) // the one-off fix at start
    await vi.advanceTimersByTimeAsync(60_000)
    // Asked again every few seconds once the stream stayed quiet: about as often as the Android app's updates.
    expect(asked()).toBeGreaterThanOrEqual(1 + 60_000 / LocalLink.pollMs - 1) // a fix every 5 s
    expect(link.problem).toBe('')
    await link.stop()
  })

  it('no fix at all: the phone page says the location is missing', async () => {
    vi.useFakeTimers()
    globalThis.createCodewalkCore = () => fakeCore([])
    const { bridge } = fakeBridge(null)
    const link = new LocalLink(bridge, () => {}, () => {}, 'ja')
    await link.start()
    await vi.advanceTimersByTimeAsync(LocalLink.giveUpMs + LocalLink.pollMs * 2)
    expect(link.problem).toBe('location')
    await link.stop()
  })

  it('an old fix (the Even app stopped locating) is not used, and after a while the glasses say so', async () => {
    vi.useFakeTimers()
    const positions: number[][] = []
    globalThis.createCodewalkCore = () => fakeCore(positions)
    const fix = { latitude: 35.62, longitude: 139.74, timestamp: Date.now() }
    const { bridge } = fakeBridge(fix)
    const states: (string | undefined)[] = []
    const link = new LocalLink(bridge, s => states.push(s?.status), () => {}, 'ja')
    await link.start()
    expect(positions).toHaveLength(1) // fresh: used
    fix.timestamp = Date.now() - 60_000 // from now on the same old fix comes back
    await vi.advanceTimersByTimeAsync(LocalLink.staleNoticeMs + LocalLink.pollMs * 2)
    expect(positions).toHaveLength(1) // old fixes: not used
    expect(link.stale).toBe(true)
    expect(states.at(-1)).toContain('位置が止まっています')
    fix.timestamp = Date.now() + 10 ** 9 // fresh again (any recent timestamp)
    await vi.advanceTimersByTimeAsync(LocalLink.pollMs * 2)
    expect(link.stale).toBe(false)
    expect(positions.length).toBeGreaterThan(1)
    await link.stop()
  })
})

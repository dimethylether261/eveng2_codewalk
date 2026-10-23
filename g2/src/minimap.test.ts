import { describe, expect, it } from 'vitest'
import { MAP_H, MAP_W, project, shouldRedraw, type MapState } from './minimap'

const map = (pos: [number, number], heard: [number, number][] = []): MapState =>
  ({ origin: [35.6, 139.7], roadsVersion: 1, pos, heard })

describe('minimap', () => {
  it('puts the user in the centre, north up, 0.8 px per metre', () => {
    expect(project([100, 50], 100, 50)).toEqual([MAP_W / 2, MAP_H / 2])
    expect(project([0, 0], 100, 0)).toEqual([MAP_W / 2 + 80, MAP_H / 2]) // 100 m east
    expect(project([0, 0], 0, 50)).toEqual([MAP_W / 2, MAP_H / 2 - 40]) // 50 m north is up
  })

  it('redraws only when the picture changes', () => {
    expect(shouldRedraw(null, map([0, 0]), 1, 0)).toBe(true)
    const last = { pos: [0, 0] as [number, number], roadsVersion: 1, heard: 0, at: 0 }
    expect(shouldRedraw(last, map([5, 5]), 1, 1000)).toBe(false) // a few metres, just now
    expect(shouldRedraw(last, map([12, 9]), 1, 1000)).toBe(true) // 15 m
    expect(shouldRedraw(last, map([3, 0]), 1, 31_000)).toBe(true) // small move, 30 s later
    expect(shouldRedraw(last, map([0, 0]), 1, 60_000)).toBe(false) // standing still
    expect(shouldRedraw(last, map([0, 0]), 2, 1000)).toBe(true) // new roads
    expect(shouldRedraw(last, map([0, 0], [[10, 10]]), 1, 1000)).toBe(true) // a call was heard
  })
})

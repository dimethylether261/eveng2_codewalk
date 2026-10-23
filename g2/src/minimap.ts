// Radar-style minimap for the waiting screen. North up, centred on the user.
// Coordinates come from minimap.dart (in the glasses app's core) as whole metres
// east (x) / north (y) of a shared origin.

export const MAP_W = 288 // the largest image container the glasses accept (288 x 144)
export const MAP_H = 144
export const PX_PER_M = 0.8 // 360 m x 180 m around the user

export type MapState = {
  origin: [number, number]
  roadsVersion: number
  pos: [number, number]
  heard: [number, number][]
}

/** `[major(0/1), x1, y1, x2, y2, ...]` per road. */
export type Roads = { version: number; origin?: [number, number]; roads: number[][] }

/** Metres (relative to the origin) -> pixel on the map image, with the user in the centre. */
export function project(pos: [number, number], x: number, y: number): [number, number] {
  return [MAP_W / 2 + (x - pos[0]) * PX_PER_M, MAP_H / 2 - (y - pos[1]) * PX_PER_M]
}

export type Drawn = { pos: [number, number]; roadsVersion: number; heard: number; at: number }

/** Image updates are slow (~0.1 s each over BLE): redraw only when the picture really changes. */
export function shouldRedraw(last: Drawn | null, map: MapState, roadsVersion: number, now: number): boolean {
  if (!last) return true
  if (roadsVersion !== last.roadsVersion || map.heard.length !== last.heard) return true
  const moved = Math.hypot(map.pos[0] - last.pos[0], map.pos[1] - last.pos[1])
  return moved >= 15 || (moved >= 2 && now - last.at >= 30_000)
}

function polyline(ctx: CanvasRenderingContext2D, pos: [number, number], pts: number[], from: number) {
  ctx.beginPath()
  for (let i = from; i + 1 < pts.length; i += 2) {
    const [px, py] = project(pos, pts[i], pts[i + 1])
    if (i === from) ctx.moveTo(px, py)
    else ctx.lineTo(px, py)
  }
  ctx.stroke()
}

/** Draws the map; the host converts it to the glasses' 16 greens, so only brightness matters. */
export function draw(canvas: HTMLCanvasElement, map: MapState, roads: Roads | null) {
  canvas.width = MAP_W
  canvas.height = MAP_H
  const ctx = canvas.getContext('2d')!
  ctx.fillStyle = '#000'
  ctx.fillRect(0, 0, MAP_W, MAP_H)
  ctx.lineCap = 'round'
  ctx.lineJoin = 'round'

  // Roads only if they share the state's origin (otherwise they are from an older fetch).
  const sameOrigin = roads?.origin && roads.origin[0] === map.origin[0] && roads.origin[1] === map.origin[1]
  if (roads && sameOrigin) {
    for (const major of [0, 1]) {
      ctx.strokeStyle = major ? '#8c8c8c' : '#4a4a4a'
      ctx.lineWidth = major ? 2.5 : 1.2
      for (const r of roads.roads) if (r[0] === major) polyline(ctx, map.pos, r, 1)
    }
  }

  // Places where a call was heard.
  ctx.strokeStyle = '#ffffff'
  ctx.lineWidth = 1.5
  for (const [x, y] of map.heard) {
    const [px, py] = project(map.pos, x, y)
    ctx.strokeRect(px - 3, py - 3, 6, 6)
  }

  // You: a dot with a ring, always in the centre.
  ctx.fillStyle = '#ffffff'
  ctx.beginPath()
  ctx.arc(MAP_W / 2, MAP_H / 2, 3.5, 0, Math.PI * 2)
  ctx.fill()
  ctx.strokeStyle = '#a0a0a0'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.arc(MAP_W / 2, MAP_H / 2, 8, 0, Math.PI * 2)
  ctx.stroke()

  // Scale: 100 m.
  const bar = 100 * PX_PER_M
  ctx.strokeStyle = '#a0a0a0'
  ctx.lineWidth = 1.5
  ctx.beginPath()
  ctx.moveTo(8, MAP_H - 8)
  ctx.lineTo(8 + bar, MAP_H - 8)
  ctx.moveTo(8, MAP_H - 11)
  ctx.lineTo(8, MAP_H - 5)
  ctx.moveTo(8 + bar, MAP_H - 11)
  ctx.lineTo(8 + bar, MAP_H - 5)
  ctx.stroke()
  ctx.fillStyle = '#a0a0a0'
  ctx.font = '10px sans-serif'
  ctx.fillText('100m', 12 + bar, MAP_H - 5)

  // North marker and frame.
  ctx.fillStyle = '#a0a0a0'
  ctx.beginPath()
  ctx.moveTo(MAP_W - 10, 4)
  ctx.lineTo(MAP_W - 14, 12)
  ctx.lineTo(MAP_W - 6, 12)
  ctx.closePath()
  ctx.fill()
  ctx.strokeStyle = '#5a5a5a'
  ctx.lineWidth = 1
  ctx.strokeRect(0.5, 0.5, MAP_W - 1, MAP_H - 1)
}

/** PNG file bytes of the canvas (the SDK accepts encoded images). */
export function pngBytes(canvas: HTMLCanvasElement): Uint8Array {
  const b64 = canvas.toDataURL('image/png').split(',')[1]
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

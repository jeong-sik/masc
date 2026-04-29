// Activity heatmap — pure Canvas 2D drawing functions (no framework deps).
// Extracted so the same code can run in a Web Worker.

export const DAY_LABELS = ['월', '화', '수', '목', '금', '토', '일'] as const
export const HOUR_LABELS = [0, 3, 6, 9, 12, 15, 18, 21] as const

export const CELL = 20
export const GAP = 2
export const LEFT_MARGIN = 28
export const TOP_PAD = 20
export const LEGEND_HEIGHT = 32

const COLORS: readonly [string, string, string, string, string] = [
  'var(--slate-800)',
  '#0e4a5c',
  '#0e6e7e',
  '#14919b',
  'var(--cyan)',
]

type HeatmapCanvasContext = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D

export function intensityColor(count: number, max: number): string {
  if (count === 0) return COLORS[0]
  if (max === 0) return COLORS[0]
  const ratio = count / max
  if (ratio <= 0.25) return COLORS[1]
  if (ratio <= 0.50) return COLORS[2]
  if (ratio <= 0.75) return COLORS[3]
  return COLORS[4]
}

export function canvasWidth(): number {
  return LEFT_MARGIN + 24 * (CELL + GAP) - GAP
}

export function canvasHeight(): number {
  return TOP_PAD + 7 * (CELL + GAP) - GAP + LEGEND_HEIGHT
}

export interface HeatmapCell {
  day: number
  hour: number
  count: number
}

export function drawHeatmap(
  ctx: HeatmapCanvasContext,
  matrix: number[][],
  max: number,
) {
  const w = canvasWidth()
  const h = canvasHeight()

  // Background
  ctx.fillStyle = '#0f1117'
  ctx.fillRect(0, 0, w, h)

  // Hour labels (top)
  ctx.font = '10px system-ui, sans-serif'
  ctx.fillStyle = 'var(--slate-500)'
  ctx.textAlign = 'center'
  for (const hour of HOUR_LABELS) {
    const x = LEFT_MARGIN + hour * (CELL + GAP) + CELL / 2
    ctx.fillText(String(hour), x, TOP_PAD - 6)
  }

  // Day labels (left) + cells
  ctx.textAlign = 'right'
  for (let day = 0; day < 7; day++) {
    const y = TOP_PAD + day * (CELL + GAP)
    const label = DAY_LABELS[day]!

    ctx.fillStyle = 'var(--slate-400)'
    ctx.font = '11px system-ui, sans-serif'
    ctx.fillText(label, LEFT_MARGIN - 6, y + CELL / 2 + 4)

    for (let hour = 0; hour < 24; hour++) {
      const count = matrix[day]![hour]!
      const x = LEFT_MARGIN + hour * (CELL + GAP)
      ctx.fillStyle = intensityColor(count, max)
      ctx.beginPath()
      ctx.roundRect(x, y, CELL, CELL, 3)
      ctx.fill()
    }
  }

  // Legend
  const legendY = TOP_PAD + 7 * (CELL + GAP) + 8
  ctx.font = '10px system-ui, sans-serif'
  ctx.fillStyle = 'var(--slate-500)'
  ctx.textAlign = 'left'
  ctx.fillText('적음', LEFT_MARGIN, legendY + 10)

  const legendStartX = LEFT_MARGIN + 28
  for (let i = 0; i < COLORS.length; i++) {
    const lx = legendStartX + i * (CELL + 2)
    ctx.fillStyle = COLORS[i] ?? COLORS[0]
    ctx.beginPath()
    ctx.roundRect(lx, legendY, CELL, 12, 2)
    ctx.fill()
  }

  ctx.fillStyle = 'var(--slate-500)'
  ctx.textAlign = 'left'
  ctx.fillText('많음', legendStartX + COLORS.length * (CELL + 2) + 4, legendY + 10)
}

export function hitTest(mx: number, my: number): HeatmapCell | null {
  for (let day = 0; day < 7; day++) {
    const cy = TOP_PAD + day * (CELL + GAP)
    if (my < cy || my > cy + CELL) continue
    for (let hour = 0; hour < 24; hour++) {
      const cx = LEFT_MARGIN + hour * (CELL + GAP)
      if (mx >= cx && mx <= cx + CELL) {
        return { day, hour, count: 0 }
      }
    }
  }
  return null
}

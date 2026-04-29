// Activity heatmap — Canvas 2D day-of-week x hour-of-day density grid.
// Uses server-projected density from the full filtered event set.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState } from './common/feedback-state'
import { HEATMAP_COLORS } from '../config/constants'
import type { ActivityGraphResponse } from '../types'

const DAY_LABELS = ['월', '화', '수', '목', '금', '토', '일'] as const
const HOUR_LABELS = [0, 3, 6, 9, 12, 15, 18, 21] as const

const CELL = 20
const GAP = 2
const LEFT_MARGIN = 28
const TOP_PAD = 20
const LEGEND_HEIGHT = 32

const COLORS = HEATMAP_COLORS

interface HeatmapCell {
  day: number
  hour: number
  count: number
}

interface TooltipInfo {
  x: number
  y: number
  cell: HeatmapCell
}

interface HeatmapProps {
  data: ActivityGraphResponse
}

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

function drawHeatmap(
  ctx: CanvasRenderingContext2D,
  matrix: number[][],
  max: number,
  tooltip: TooltipInfo | null,
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
    ctx.fillStyle = COLORS[i]!
    ctx.beginPath()
    ctx.roundRect(lx, legendY, CELL, 12, 2)
    ctx.fill()
  }

  ctx.fillStyle = 'var(--slate-500)'
  ctx.textAlign = 'left'
  ctx.fillText('많음', legendStartX + COLORS.length * (CELL + 2) + 4, legendY + 10)

  // Tooltip
  if (tooltip) {
    const { x, y, cell } = tooltip
    const dayName = DAY_LABELS[cell.day] ?? '?'
    const text = `${dayName}요일 ${cell.hour}시 — ${cell.count}건`

    ctx.font = '11px system-ui, sans-serif'
    const metrics = ctx.measureText(text)
    const padX = 10
    const padY = 6
    const boxW = metrics.width + padX * 2
    const boxH = 24

    const tx = Math.min(x + 12, w - boxW - 4)
    const ty = Math.max(y - boxH - 4, 4)

    ctx.fillStyle = 'rgba(15, 23, 42, 0.95)'
    ctx.beginPath()
    ctx.roundRect(tx, ty, boxW, boxH, 6)
    ctx.fill()
    ctx.strokeStyle = 'rgba(100, 116, 139, 0.3)'
    ctx.lineWidth = 1
    ctx.stroke()

    ctx.fillStyle = 'var(--frost-100)'
    ctx.textAlign = 'left'
    ctx.fillText(text, tx + padX, ty + padY + 11)
  }
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

export function ActivityHeatmap({ data }: HeatmapProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const tooltipRef = useRef<TooltipInfo | null>(null)

  const matrix = data.heatmap.matrix
  const max = data.heatmap.max
  const total = data.heatmap.total

  useEffect(() => {
    const canvas = canvasRef.current
    const container = containerRef.current
    if (!canvas || !container) return

    const w = canvasWidth()
    const h = canvasHeight()
    const dpr = window.devicePixelRatio || 1

    canvas.width = w * dpr
    canvas.height = h * dpr
    canvas.style.width = `${w}px`
    canvas.style.height = `${h}px`

    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    drawHeatmap(ctx, matrix, max, tooltipRef.current)

    function handleMouse(event: MouseEvent) {
      const canvasEl = canvasRef.current
      if (!canvasEl) return

      const rect = canvasEl.getBoundingClientRect()
      const scaleX = canvasWidth() / rect.width
      const scaleY = canvasHeight() / rect.height
      const mx = (event.clientX - rect.left) * scaleX
      const my = (event.clientY - rect.top) * scaleY

      const hit = hitTest(mx, my)
      const prev = tooltipRef.current

      if (hit) {
        hit.count = matrix[hit.day]![hit.hour]!
        tooltipRef.current = { x: mx, y: my, cell: hit }
        canvasEl.style.cursor = 'pointer'
      } else {
        tooltipRef.current = null
        canvasEl.style.cursor = 'default'
      }

      const changed = (hit !== null) !== (prev !== null)
        || (hit && prev && (hit.day !== prev.cell.day || hit.hour !== prev.cell.hour))
      if (changed) {
        const ctx2 = canvasEl.getContext('2d')
        if (ctx2) {
          const dpr2 = window.devicePixelRatio || 1
          ctx2.setTransform(dpr2, 0, 0, dpr2, 0, 0)
          drawHeatmap(ctx2, matrix, max, tooltipRef.current)
        }
      }
    }

    function handleLeave() {
      const canvasEl = canvasRef.current
      if (!canvasEl) return
      tooltipRef.current = null
      const ctx2 = canvasEl.getContext('2d')
      if (ctx2) {
        const dpr2 = window.devicePixelRatio || 1
        ctx2.setTransform(dpr2, 0, 0, dpr2, 0, 0)
        drawHeatmap(ctx2, matrix, max, null)
      }
      canvasEl.style.cursor = 'default'
    }

    canvas.addEventListener('mousemove', handleMouse)
    canvas.addEventListener('mouseleave', handleLeave)

    return () => {
      canvas.removeEventListener('mousemove', handleMouse)
      canvas.removeEventListener('mouseleave', handleLeave)
    }
  }, [data, matrix, max])

  if (total === 0) {
    return html`
      <${Card} title="활동 히트맵" testId="activity_heatmap">
        <${EmptyState}>히트맵을 표시할 이벤트가 없습니다.<//>
      <//>
    `
  }

  return html`
    <${Card} title="활동 히트맵" testId="activity_heatmap">
      <div class="mb-2">
        <p class="text-sm text-[var(--color-fg-muted)]">필터링된 전체 이벤트를 기준으로 요일별, 시간대별 활동 밀도를 보여줍니다.</p>
      </div>
      <div ref=${containerRef} class="relative overflow-x-auto bg-[#0f1117] rounded p-3 contain-content">
        <canvas ref=${canvasRef} class="block" role="img" aria-label="요일별 시간대별 활동 밀도 히트맵" />
      </div>
    <//>
  `
}

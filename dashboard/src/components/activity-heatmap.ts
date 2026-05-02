// Activity heatmap — Canvas 2D day-of-week x hour-of-day density grid.
// PR-4.8: Offloads the static heatmap render to a Web Worker using
// OffscreenCanvas. The main thread only does a lightweight drawImage()
// and HTML tooltip overlay. Falls back to main-thread rendering when
// Worker or OffscreenCanvas are unavailable.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState } from './common/feedback-state'
import type { ActivityGraphResponse } from '../types'
import {
  intensityColor,
  canvasWidth,
  canvasHeight,
  drawHeatmap,
  hitTest,
  DAY_LABELS,
} from './activity-heatmap-draw'

// Re-export for test consumers that assert on pure functions.
export { intensityColor, canvasWidth, canvasHeight, hitTest }

interface HeatmapProps {
  data: ActivityGraphResponse
}

interface TooltipState {
  x: number
  y: number
  text: string
}

let workerInstance: Worker | null = null
function getHeatmapWorker(): Worker | null {
  if (workerInstance) return workerInstance
  if (typeof Worker === 'undefined' || typeof OffscreenCanvas === 'undefined') return null
  try {
    workerInstance = new Worker(
      new URL('../workers/activity-heatmap.worker.ts', import.meta.url),
    )
    return workerInstance
  } catch {
    return null
  }
}

export function ActivityHeatmap({ data }: HeatmapProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const [tooltip, setTooltip] = useState<TooltipState | null>(null)
  const pendingJobRef = useRef(false)

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

    const worker = getHeatmapWorker()
    if (worker && !pendingJobRef.current) {
      pendingJobRef.current = true
      const onMessage = (event: MessageEvent<{ bitmap: ImageBitmap | null }>) => {
        pendingJobRef.current = false
        const { bitmap } = event.data
        if (bitmap) {
          ctx.save()
          ctx.setTransform(1, 0, 0, 1, 0, 0)
          ctx.clearRect(0, 0, canvas.width, canvas.height)
          ctx.drawImage(bitmap, 0, 0)
          ctx.restore()
          bitmap.close()
        } else {
          // Worker failed — fallback to main-thread render.
          ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
          drawHeatmap(ctx, matrix, max)
        }
      }
      worker.addEventListener('message', onMessage, { once: true })
      worker.postMessage({ matrix, max, dpr })
    } else {
      // Worker unavailable or job already in flight — main-thread fallback.
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      drawHeatmap(ctx, matrix, max)
    }

    function handleMouse(event: MouseEvent) {
      const canvasEl = canvasRef.current
      if (!canvasEl) return

      const rect = canvasEl.getBoundingClientRect()
      const scaleX = canvasWidth() / rect.width
      const scaleY = canvasHeight() / rect.height
      const mx = (event.clientX - rect.left) * scaleX
      const my = (event.clientY - rect.top) * scaleY

      const hit = hitTest(mx, my)
      if (hit) {
        hit.count = matrix[hit.day]![hit.hour]!
        const dayName = DAY_LABELS[hit.day] ?? '?'
        setTooltip({
          x: event.clientX - rect.left,
          y: event.clientY - rect.top,
          text: `${dayName}요일 ${hit.hour}시 — ${hit.count}건`,
        })
        canvasEl.style.cursor = 'pointer'
      } else {
        setTooltip(null)
        canvasEl.style.cursor = 'default'
      }
    }

    function handleLeave() {
      setTooltip(null)
      const canvasEl = canvasRef.current
      if (canvasEl) canvasEl.style.cursor = 'default'
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
      <div ref=${containerRef} class="relative overflow-x-auto bg-[var(--color-bg-surface)] rounded p-3 contain-content">
        <canvas ref=${canvasRef} class="block" role="img" aria-label="요일별 시간대별 활동 밀도 히트맵" />
        ${tooltip
          ? html`
            <div
              class="absolute pointer-events-none z-10 px-2.5 py-1.5 rounded-md text-xs whitespace-nowrap"
              style=${{
                left: `${Math.min(tooltip.x + 12, canvasWidth() - 140)}px`,
                top: `${Math.max(tooltip.y - 32, 4)}px`,
                background: 'var(--color-bg-elevated)',
                border: '1px solid var(--color-border-default)',
                color: 'var(--frost-100)',
              }}
            >
              ${tooltip.text}
            </div>
          `
          : null}
      </div>
    <//>
  `
}

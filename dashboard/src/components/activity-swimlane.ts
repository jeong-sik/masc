// Activity swimlane — Canvas 2D per-agent timeline visualization
// Shows horizontal time spans per agent, color-coded by kind.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState, LoadingState } from './common/feedback-state'
import { fetchSwimlane } from '../api'
import { registerActivityRefresh } from '../sse-store'
import type { SwimlaneResponse, AgentSpan } from '../types'
import { selectedNodeId, highlightedAgentId } from './activity-graph-view'
import { formatDurationMs } from '../lib/format-time'
import { createAsyncResource } from '../lib/async-state'

const swimlaneResource = createAsyncResource<SwimlaneResponse | null>()

const LANE_HEIGHT = 32
const LANE_GAP = 4
const LEFT_MARGIN = 80
const RIGHT_PAD = 16
const TOP_PAD = 24
const BOTTOM_PAD = 28

function spanColor(kind: string): string {
  switch (kind) {
    case 'task': return '#fbbf24'
    case 'operation': return '#4ade80'
    case 'autonomy': return '#22d3ee'
    case 'presence': return 'rgba(148, 163, 184, 0.25)'
    default: return '#94a3b8'
  }
}

function loadSwimlane(since?: string) {
  return swimlaneResource.load(() => fetchSwimlane(since))
}

interface TooltipInfo {
  x: number
  y: number
  span: AgentSpan
}

function drawSwimlane(
  ctx: CanvasRenderingContext2D,
  data: SwimlaneResponse,
  canvasWidth: number,
  canvasHeight: number,
  tooltip: TooltipInfo | null,
  highlightedAgent: string | null = null,
) {
  const { agents, spans, time_range } = data
  const drawWidth = canvasWidth - LEFT_MARGIN - RIGHT_PAD
  const timeSpan = time_range.max_ms - time_range.min_ms || 1

  // Background
  ctx.fillStyle = '#0f1117'
  ctx.fillRect(0, 0, canvasWidth, canvasHeight)

  // Time axis ticks
  const tickCount = Math.min(6, Math.max(2, Math.floor(drawWidth / 100)))
  ctx.font = '10px system-ui, sans-serif'
  ctx.fillStyle = '#64748b'
  ctx.textAlign = 'center'

  for (let i = 0; i <= tickCount; i++) {
    const frac = i / tickCount
    const x = LEFT_MARGIN + frac * drawWidth
    const timeMs = time_range.min_ms + frac * timeSpan
    const date = new Date(timeMs)
    const label = `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`

    ctx.fillText(label, x, TOP_PAD - 6)

    ctx.beginPath()
    ctx.moveTo(x, TOP_PAD)
    ctx.lineTo(x, canvasHeight - BOTTOM_PAD)
    ctx.strokeStyle = 'rgba(100, 116, 139, 0.12)'
    ctx.lineWidth = 1
    ctx.stroke()
  }

  // Agent lanes
  for (let i = 0; i < agents.length; i++) {
    const agentName = agents[i]!
    const y = TOP_PAD + i * (LANE_HEIGHT + LANE_GAP)
    const isHighlighted = highlightedAgent === agentName

    // Highlighted lane background
    if (isHighlighted) {
      ctx.fillStyle = 'rgba(251, 191, 36, 0.08)'
      ctx.fillRect(LEFT_MARGIN, y, drawWidth, LANE_HEIGHT)
    }

    // Agent name — brighter if highlighted
    ctx.fillStyle = isHighlighted ? '#fbbf24' : '#94a3b8'
    ctx.font = '11px system-ui, sans-serif'
    ctx.textAlign = 'right'
    const displayName = agentName.length > 10 ? agentName.slice(0, 9) + '..' : agentName
    ctx.fillText(displayName, LEFT_MARGIN - 8, y + LANE_HEIGHT / 2 + 4)

    // Lane background (default, drawn on top of highlight if present)
    if (!isHighlighted) {
      ctx.fillStyle = 'rgba(30, 41, 59, 0.3)'
      ctx.fillRect(LEFT_MARGIN, y, drawWidth, LANE_HEIGHT)
    }
  }

  // Draw spans
  for (const span of spans) {
    const agentIdx = agents.indexOf(span.agent)
    if (agentIdx < 0) continue

    const y = TOP_PAD + agentIdx * (LANE_HEIGHT + LANE_GAP)
    const x1 = LEFT_MARGIN + ((span.start_ms - time_range.min_ms) / timeSpan) * drawWidth
    const x2 = LEFT_MARGIN + ((span.end_ms - time_range.min_ms) / timeSpan) * drawWidth
    const w = Math.max(x2 - x1, 3) // min 3px visibility
    const color = spanColor(span.kind)

    ctx.fillStyle = color
    ctx.globalAlpha = span.kind === 'presence' ? 0.25 : 0.7
    ctx.beginPath()
    ctx.roundRect(x1, y + 4, w, LANE_HEIGHT - 8, 3)
    ctx.fill()
    ctx.globalAlpha = 1.0

    // Label inside span if wide enough
    if (w > 50 && span.label) {
      ctx.fillStyle = '#0f172a'
      ctx.font = '10px system-ui, sans-serif'
      ctx.textAlign = 'left'
      const text = span.label.length > 20 ? span.label.slice(0, 18) + '..' : span.label
      ctx.save()
      ctx.beginPath()
      ctx.rect(x1, y, w, LANE_HEIGHT)
      ctx.clip()
      ctx.fillText(text, x1 + 4, y + LANE_HEIGHT / 2 + 3)
      ctx.restore()
    }
  }

  // Tooltip
  if (tooltip) {
    const { x, y, span } = tooltip
    const duration = formatDurationMs(span.end_ms - span.start_ms)
    const lines = [
      span.label || span.kind,
      `종류: ${span.kind}`,
      `지속: ${duration}`,
    ]
    const lineHeight = 16
    const padX = 10
    const padTop = 8
    const boxW = 180
    const boxH = padTop * 2 + lines.length * lineHeight

    const tx = Math.min(x + 12, canvasWidth - boxW - 8)
    const ty = Math.max(y - boxH - 4, 4)

    ctx.fillStyle = 'rgba(15, 23, 42, 0.95)'
    ctx.beginPath()
    ctx.roundRect(tx, ty, boxW, boxH, 6)
    ctx.fill()
    ctx.strokeStyle = 'rgba(100, 116, 139, 0.3)'
    ctx.lineWidth = 1
    ctx.stroke()

    ctx.fillStyle = '#e2e8f0'
    ctx.font = '11px system-ui, sans-serif'
    ctx.textAlign = 'left'
    for (let i = 0; i < lines.length; i++) {
      ctx.fillText(lines[i]!, tx + padX, ty + padTop + (i + 1) * lineHeight - 2)
    }
  }
}

function hitTestSpan(
  data: SwimlaneResponse,
  mx: number,
  my: number,
  canvasWidth: number,
): AgentSpan | null {
  const { agents, spans, time_range } = data
  const drawWidth = canvasWidth - LEFT_MARGIN - RIGHT_PAD
  const timeSpan = time_range.max_ms - time_range.min_ms || 1

  for (const span of spans) {
    const agentIdx = agents.indexOf(span.agent)
    if (agentIdx < 0) continue

    const y = TOP_PAD + agentIdx * (LANE_HEIGHT + LANE_GAP)
    const x1 = LEFT_MARGIN + ((span.start_ms - time_range.min_ms) / timeSpan) * drawWidth
    const x2 = LEFT_MARGIN + ((span.end_ms - time_range.min_ms) / timeSpan) * drawWidth
    const w = Math.max(x2 - x1, 3)

    if (mx >= x1 && mx <= x1 + w && my >= y + 4 && my <= y + LANE_HEIGHT - 4) {
      return span
    }
  }
  return null
}

export function ActivitySwimlane({ since }: { since?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const tooltipRef = useRef<TooltipInfo | null>(null)

  useEffect(() => {
    void loadSwimlane(since)
    return registerActivityRefresh(() => {
      void loadSwimlane(since)
    })
  }, [since])

  const s = swimlaneResource.state.value
  const data = s.status === 'loaded' ? s.data : undefined

  useEffect(() => {
    const canvas = canvasRef.current
    const container = containerRef.current
    if (!canvas || !container || !data || data.agents.length === 0) return

    const rect = container.getBoundingClientRect()
    const width = Math.max(rect.width, 400)
    const agentCount = data.agents.length
    const contentHeight = TOP_PAD + agentCount * (LANE_HEIGHT + LANE_GAP) + BOTTOM_PAD
    const height = Math.max(120, Math.min(400, contentHeight))
    const dpr = window.devicePixelRatio || 1

    canvas.width = width * dpr
    canvas.height = height * dpr
    canvas.style.width = `${width}px`
    canvas.style.height = `${height}px`

    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    const currentHighlightedAgent = highlightedAgentId.value
    drawSwimlane(ctx, data, width, height, tooltipRef.current, currentHighlightedAgent)

    function handleClick(event: MouseEvent) {
      const canvasEl = canvasRef.current
      const containerEl = containerRef.current
      if (!canvasEl || !containerEl || !data) return

      const canvasRect = canvasEl.getBoundingClientRect()
      const mx = event.clientX - canvasRect.left
      const my = event.clientY - canvasRect.top

      const containerRect = containerEl.getBoundingClientRect()
      const cWidth = Math.max(containerRect.width, 400)

      const span = hitTestSpan(data, mx, my, cWidth)
      if (span) {
        selectedNodeId.value = 'agent:' + span.agent
        highlightedAgentId.value = span.agent
      } else {
        selectedNodeId.value = null
        highlightedAgentId.value = null
      }
    }

    function handleMouse(event: MouseEvent) {
      const canvasEl = canvasRef.current
      const containerEl = containerRef.current
      if (!canvasEl || !containerEl || !data) return

      const canvasRect = canvasEl.getBoundingClientRect()
      const mx = event.clientX - canvasRect.left
      const my = event.clientY - canvasRect.top

      const containerRect = containerEl.getBoundingClientRect()
      const cWidth = Math.max(containerRect.width, 400)

      const span = hitTestSpan(data, mx, my, cWidth)
      const prev = tooltipRef.current

      if (span) {
        tooltipRef.current = { x: mx, y: my, span }
        canvasEl.style.cursor = 'pointer'
      } else {
        tooltipRef.current = null
        canvasEl.style.cursor = 'default'
      }

      // Redraw if tooltip changed
      const changed = (span !== null) !== (prev !== null) || (span && prev && span !== prev.span)
      if (changed) {
        const ctx2 = canvasEl.getContext('2d')
        if (ctx2) {
          const dpr2 = window.devicePixelRatio || 1
          ctx2.setTransform(dpr2, 0, 0, dpr2, 0, 0)
          drawSwimlane(ctx2, data, cWidth, canvasEl.height / dpr2, tooltipRef.current, highlightedAgentId.value)
        }
      }
    }

    canvas.addEventListener('mousemove', handleMouse)
    canvas.addEventListener('click', handleClick)
    return () => {
      canvas.removeEventListener('mousemove', handleMouse)
      canvas.removeEventListener('click', handleClick)
    }
  }, [data, highlightedAgentId.value])

  if (s.status === 'loading' || s.status === 'idle') {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${LoadingState}>타임라인 불러오는 중...<//>
      <//>
    `
  }

  if (s.status === 'error') {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${EmptyState}>타임라인을 불러올 수 없습니다: ${s.message}<//>
      <//>
    `
  }

  if (!data || data.agents.length === 0) {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${EmptyState}>표시할 에이전트 활동 타임라인이 없습니다.<//>
      <//>
    `
  }

  return html`
    <${Card} title="활동 타임라인" testId="activity_swimlane">
      <div class="mb-2">
        <p class="text-[13px] text-[var(--text-muted)]">에이전트별 활동 구간을 시간축으로 보여줍니다.</p>
      </div>
      <div ref=${containerRef} class="relative w-full overflow-hidden bg-[#0f1117] rounded-xl">
        <canvas ref=${canvasRef} class="block w-full" />
      </div>
      <div class="flex flex-wrap gap-3 mt-3 text-[11px] text-[var(--text-muted)]">
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[#fbbf24] inline-block"></span>작업</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[#4ade80] inline-block"></span>운영</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[#22d3ee] inline-block"></span>자율</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[rgba(148,163,184,0.5)] inline-block"></span>접속</span>
      </div>
    <//>
  `
}

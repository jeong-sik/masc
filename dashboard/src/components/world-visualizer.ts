// World Visualizer — 7 Physical Laws Visualization
// Renders Stigmergy Intensity, Local Sight (K=6), and Active Inference
// using real keeper fleet data from SSE-driven signals (no Yjs dependency).

import { html } from 'htm/preact'
import { useRef, useState, useCallback, useEffect } from 'preact/hooks'
import { keepers, messages, tasks } from '../store'
import { kSlot, kSigil } from './keeper-badge'
import { getPhaseStyle } from './keeper-phase-indicator'
import type { Keeper } from '../types'

// ── CSS custom property resolver for Canvas 2D ────────────────────
// Canvas doesn't understand CSS var() — we resolve at paint time via
// getComputedStyle and cache until theme changes invalidate the map.

const cssVarCache = new Map<string, string>()

function cssVar(prop: string): string {
  if (typeof window === 'undefined' || typeof document === 'undefined') return 'CanvasText'
  const cached = cssVarCache.get(prop)
  if (cached !== undefined) return cached
  const value = getComputedStyle(document.documentElement).getPropertyValue(prop).trim()
  if (!value) {
    cssVarCache.set(prop, 'CanvasText')
    return 'CanvasText'
  }
  cssVarCache.set(prop, value)
  return value
}

function keeperColor(keeper: Keeper): string {
  const id = keeper.keeper_id ?? keeper.name
  const slot = kSlot(id)
  return cssVar(`--color-keeper-${slot}`)
}

interface InteractionJudgeData {
  judge_online?: boolean
  refreshing?: boolean
  last_error?: string | null
  data?: {
    stigmergy?: Record<string, number>
    interactions?: { source: string; target: string; strength: number; reasoning?: string }[]
  }
}

function getJudgeInteractionStrength(judgeData: InteractionJudgeData | null, a: Keeper, b: Keeper): number {
  if (!judgeData || !judgeData.data || !judgeData.data.interactions) return 0
  const aName = a.name.toLowerCase()
  const bName = b.name.toLowerCase()
  const match = judgeData.data.interactions.find(i => 
    (i.source.toLowerCase() === aName && i.target.toLowerCase() === bName) ||
    (i.source.toLowerCase() === bName && i.target.toLowerCase() === aName)
  )
  return match ? match.strength : 0
}

function getJudgeStigmergy(judgeData: InteractionJudgeData | null, keeper: Keeper): number {
  if (!judgeData || !judgeData.data || !judgeData.data.stigmergy) return 0
  const val = judgeData.data.stigmergy[keeper.name] || judgeData.data.stigmergy[keeper.name.toLowerCase()]
  return val ?? 0
}

// ── Free energy from active inference ─────────────────────────────
// convergence=1 → freeEnergy=0 (stable). convergence=0 → freeEnergy=1 (unstable).

function freeEnergy(keeper: Keeper): number {
  const c = keeper.goal_progress?.convergence
  if (typeof c === 'number' && Number.isFinite(c) && c >= 0) return Math.max(0, 1 - c)
  return 0.5
}

// ── Canvas constants ──────────────────────────────────────────────

const K_LOCAL_SIGHT = 6
const CANVAS_H = 360
const FLEET_RING_BASE = 130
const KEEPER_RADIUS = 10

// ── Component ─────────────────────────────────────────────────────

export function WorldVisualizer() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [paletteVersion, setPaletteVersion] = useState(0)
  const [judgeData, setJudgeData] = useState<InteractionJudgeData | null>(null)
  const animRef = useRef<number>(0)

  useEffect(() => {
    const fetchJudge = async () => {
      try {
        const res = await fetch('/api/v1/dashboard/interaction-judge')
        if (res.ok) {
          const json = await res.json()
          setJudgeData(json)
        }
      } catch (e) {
        console.warn('Failed to fetch interaction judge data', e)
      }
    }
    fetchJudge()
    const timer = setInterval(fetchJudge, 10000)
    return () => clearInterval(timer)
  }, [])

  // Theme change detection — invalidate CSS var cache on class/style mutation
  const refreshPalette = useCallback(() => {
    cssVarCache.clear()
    setPaletteVersion(v => v + 1)
  }, [])

  // Palette observer (theme switch invalidates cached CSS colors)
  const paletteObserverRef = useRef<MutationObserver | null>(null)
  if (paletteObserverRef.current === null && typeof MutationObserver !== 'undefined') {
    const obs = new MutationObserver(refreshPalette)
    obs.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'data-theme', 'style'],
    })
    paletteObserverRef.current = obs
  }

  // Re-render canvas on every data or palette change
  const fleet = keepers.value
  const msgList = messages.value
  const taskList = tasks.value

  // Draw loop — reads signals directly (no useState for fleet data)
  const draw = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const dpr = typeof window !== 'undefined' && window.devicePixelRatio
      ? Math.min(window.devicePixelRatio, 2) : 1
    const w = canvas.clientWidth
    const h = canvas.clientHeight
    canvas.width = w * dpr
    canvas.height = h * dpr
    ctx.scale(dpr, dpr)

    ctx.clearRect(0, 0, w, h)
    const cx = w / 2
    const cy = h / 2

    const n = fleet.length
    const ringRadius = Math.min(FLEET_RING_BASE, Math.min(w, h) / 2 - 60)

    // Pre-compute positions (parallel arrays for type-safe indexed access)
    const positions = fleet.map((_, i) => {
      const angle = (i / n) * 2 * Math.PI - Math.PI / 2
      return { x: cx + Math.cos(angle) * ringRadius, y: cy + Math.sin(angle) * ringRadius }
    })

    // Count per-keeper messages for stigmergy
    const msgCountByKeeper = new Map<string, number>()
    for (const m of msgList) {
      const from = m.from ?? ''
      msgCountByKeeper.set(from, (msgCountByKeeper.get(from) ?? 0) + 1)
    }

    // ── 1. Stigmergy Intensity ────────────────────────────────────
    let idx = 0
    for (const k of fleet) {
      const p = positions[idx]!
      const intensity = getJudgeStigmergy(judgeData, k)
      if (intensity >= 0.05) {
        const color = keeperColor(k)
        const rings = Math.ceil(intensity * 4)
        for (let r = rings; r >= 1; r--) {
          const ringR = KEEPER_RADIUS + r * 14
          ctx.beginPath()
          ctx.arc(p.x, p.y, ringR, 0, 2 * Math.PI)
          ctx.globalAlpha = 0.06 * (1 - r / (rings + 1))
          ctx.fillStyle = color
          ctx.fill()
        }
        ctx.globalAlpha = 1
      }
      idx++
    }

    // ── 2. Local Sight (K=6) ─────────────────────────────────────
    const okColor = cssVar('--color-status-ok')
    for (let i = 0; i < n; i++) {
      const ki = fleet[i]!
      const pi = positions[i]!
      const scored: { j: number; strength: number }[] = []
      for (let j = 0; j < n; j++) {
        if (i === j) continue
        const kj = fleet[j]!
        scored.push({ j, strength: getJudgeInteractionStrength(judgeData, ki, kj) })
      }
      scored.sort((a, b) => b.strength - a.strength)

      for (let s = 0; s < scored.length; s++) {
        const entry = scored[s]!
        if (entry.strength < 1) continue
        const pj = positions[entry.j]!
        const withinSight = s < K_LOCAL_SIGHT
        ctx.beginPath()
        ctx.moveTo(pi.x, pi.y)
        ctx.lineTo(pj.x, pj.y)
        ctx.strokeStyle = withinSight ? okColor : cssVar('--color-fg-muted')
        ctx.globalAlpha = withinSight ? Math.min(0.35, entry.strength * 0.08) : 0.06
        ctx.lineWidth = withinSight ? Math.min(2, 0.5 + entry.strength * 0.3) : 0.5
        if (!withinSight) ctx.setLineDash([3, 4])
        else ctx.setLineDash([])
        ctx.stroke()
        ctx.setLineDash([])
      }
    }
    ctx.globalAlpha = 1

    // ── 3. Active Inference — convergence bars ────────────────────
    const okStatusColor = cssVar('--color-status-ok')
    const errStatusColor = cssVar('--color-status-err')

    idx = 0
    for (const k of fleet) {
      const p = positions[idx]!
      const fe = freeEnergy(k)
      const convergence = 1 - fe
      const barH = 28
      const barW = 4
      const barX = p.x + KEEPER_RADIUS + 4
      const barY = p.y - barH / 2

      ctx.fillStyle = errStatusColor
      ctx.globalAlpha = 0.2
      ctx.fillRect(barX, barY, barW, barH)

      ctx.globalAlpha = 0.7
      ctx.fillStyle = okStatusColor
      const fillH = barH * convergence
      ctx.fillRect(barX, barY + barH - fillH, barW, fillH)
      ctx.globalAlpha = 1
      idx++
    }

    // Fleet gauge at center
    const avgConvergence = fleet.reduce((sum, k) => sum + (1 - freeEnergy(k)), 0) / n
    const gaugeR = 30
    const gaugeW = 5

    ctx.beginPath()
    ctx.arc(cx, cy, gaugeR, 0, 2 * Math.PI)
    ctx.strokeStyle = cssVar('--color-border-default')
    ctx.lineWidth = gaugeW
    ctx.globalAlpha = 0.2
    ctx.stroke()
    ctx.globalAlpha = 1

    const startAngle = -Math.PI / 2
    const endAngle = startAngle + avgConvergence * 2 * Math.PI
    ctx.beginPath()
    ctx.arc(cx, cy, gaugeR, startAngle, endAngle)
    ctx.strokeStyle = avgConvergence > 0.6 ? okStatusColor : avgConvergence > 0.3 ? cssVar('--color-status-warn') : errStatusColor
    ctx.lineWidth = gaugeW
    ctx.lineCap = 'round'
    ctx.stroke()
    ctx.lineCap = 'butt'

    ctx.fillStyle = cssVar('--color-fg-primary')
    ctx.font = 'bold 11px system-ui, sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(`${Math.round(avgConvergence * 100)}%`, cx, cy - 4)
    ctx.font = '9px system-ui, sans-serif'
    ctx.fillStyle = cssVar('--color-fg-muted')
    ctx.fillText('convergence', cx, cy + 9)

    // ── Keeper nodes ──────────────────────────────────────────────
    idx = 0
    for (const k of fleet) {
      const p = positions[idx]!
      const color = keeperColor(k)
      // `k.phase` is already typed as `KeeperPhase | null | undefined`
      // on the Keeper interface (`types/core.ts:898`). The previous
      // `as KeeperPhase | null` assertion was a no-op cast; `getPhaseStyle`
      // accepts `KeeperPhase | string | null | undefined` natively.
      const phaseStyle = getPhaseStyle(k.phase)

      ctx.beginPath()
      ctx.arc(p.x, p.y, KEEPER_RADIUS + 2, 0, 2 * Math.PI)
      ctx.globalAlpha = 0.3
      ctx.strokeStyle = phaseStyle.color.startsWith('var(') ? color : phaseStyle.color
      ctx.lineWidth = 2
      ctx.stroke()
      ctx.globalAlpha = 1

      ctx.beginPath()
      ctx.arc(p.x, p.y, KEEPER_RADIUS, 0, 2 * Math.PI)
      ctx.fillStyle = color
      ctx.fill()

      ctx.fillStyle = cssVar('--color-bg-0')
      ctx.font = 'bold 9px monospace'
      ctx.textAlign = 'center'
      ctx.textBaseline = 'middle'
      ctx.fillText(kSigil(k.keeper_id ?? k.name), p.x, p.y)

      ctx.fillStyle = cssVar('--color-fg-primary')
      ctx.font = '10px system-ui, sans-serif'
      ctx.textAlign = 'center'
      ctx.textBaseline = 'top'
      const label = k.name.length > 12 ? k.name.slice(0, 11) + '…' : k.name
      ctx.fillText(label, p.x, p.y + KEEPER_RADIUS + 4)
      idx++
    }
  }, [fleet, msgList, taskList, paletteVersion])

  const fleetSize = fleet.length
  const avgConv = fleetSize > 0
    ? fleet.reduce((s, k) => s + (1 - freeEnergy(k)), 0) / fleetSize
    : 0

  // Skip animation frame scheduling when there's no data — empty state has no canvas to draw
  if (fleetSize > 0) {
    if (animRef.current) cancelAnimationFrame(animRef.current)
    animRef.current = requestAnimationFrame(draw)
  }

  return html`
    <div
      class="v2-shell-panel relative rounded-[var(--r-2)] border border-solid border-[var(--color-border-default)] bg-[var(--color-bg-0)] overflow-hidden"
      style="padding: var(--sp-4) var(--sp-5); margin-bottom: var(--sp-5);"
    >
      <div class="flex items-center justify-between ${fleetSize > 0 ? 'mb-3' : ''}">
        <div>
          <h2 class="text-sm font-semibold text-[var(--color-fg-primary)] m-0">
            Physical Laws Visualization
          </h2>
          <p class="text-3xs text-[var(--color-fg-muted)] mt-1 mb-0">
            Stigmergy Intensity · Local Sight (K=${K_LOCAL_SIGHT}) · Active Inference
          </p>
        </div>
        ${fleetSize > 0 ? html`
          <div class="flex items-center gap-3 text-3xs text-[var(--color-fg-muted)] font-mono">
            ${judgeData && judgeData.judge_online === false ? html`
              <span class="inline-flex items-center gap-1 text-[var(--color-status-warn)] border border-solid border-[var(--color-status-warn)] rounded-[var(--r-1)] px-1 py-0.5" title="Judge offline — interactions not computed">
                <svg width="10" height="10" viewBox="0 0 16 16" fill="currentColor">
                  <path d="M8 1.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13zM0 8a8 8 0 1116 0A8 8 0 010 8z"></path>
                  <path d="M11.854 4.146a.5.5 0 010 .708l-7 7a.5.5 0 01-.708-.708l7-7a.5.5 0 01.708 0z"></path>
                </svg>
                Judge Offline
              </span>
            ` : null}
            <span title="Fleet size">${fleetSize} keepers</span>
            <span title="Average convergence">${Math.round(avgConv * 100)}% conv</span>
          </div>
        ` : null}
      </div>
      ${fleetSize > 0 ? html`
        <canvas
          ref=${canvasRef}
          style="width: 100%; height: ${CANVAS_H}px; display: block;"
        />
        <div class="flex gap-4 mt-2 text-3xs text-[var(--color-fg-muted)]">
          <span class="inline-flex items-center gap-1">
            <span class="inline-block w-2 h-2 rounded-full bg-[var(--color-status-ok)] opacity-50"></span>
            Stigmergy ring = activity intensity
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="inline-block w-4 h-0.5 bg-[var(--color-status-ok)]"></span>
            Solid = within K=${K_LOCAL_SIGHT} sight
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="inline-block w-4 h-0 border-t border-dashed border-[var(--color-fg-muted)] opacity-40"></span>
            Dashed = beyond sight
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="inline-block w-1 h-3 bg-[var(--color-status-ok)] opacity-70"></span>
            Bar = convergence
          </span>
        </div>
      ` : html`
        <p class="mt-3 text-3xs text-[var(--color-fg-muted)] m-0">
          keeper 플릿 데이터 대기 중 — 서버에서 keeper 상태를 수신하면 자동으로 시각화됩니다.
        </p>
      `}
    </div>
  `
}

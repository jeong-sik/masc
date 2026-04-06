// Session progress header — Copilot-style session summary bar
// Shows total duration, status, generation, tool call stats, cost, context usage.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import type { Keeper } from '../types'
import type { TraceSummary } from './session-trace/session-trace-state'
import { formatDuration } from './tool-call-shared'

// ── Helpers ──────────────────────────────────────────────

function sessionDurationMs(keeper: Keeper): number | null {
  if (!keeper.created_at) return null
  const start = new Date(keeper.created_at).getTime()
  if (Number.isNaN(start)) return null
  return Date.now() - start
}

function isOnline(status: string): boolean {
  return ['active', 'running', 'idle', 'busy', 'listening', 'working'].includes(
    status.trim().toLowerCase(),
  )
}

function isError(status: string): boolean {
  return ['error', 'critical', 'crashed', 'dead'].includes(
    status.trim().toLowerCase(),
  )
}

function statusLabel(status: string): { text: string; color: string; bgColor: string } {
  const s = status.trim().toLowerCase()
  if (s === 'active' || s === 'running' || s === 'working')
    return { text: '실행 중', color: 'text-[var(--ok)]', bgColor: 'bg-[rgba(74,222,128,0.12)]' }
  if (s === 'idle' || s === 'quiet')
    return { text: '대기', color: 'text-[var(--warn)]', bgColor: 'bg-[rgba(251,191,36,0.1)]' }
  if (s === 'paused')
    return { text: '일시정지', color: 'text-[var(--warn)]', bgColor: 'bg-[rgba(251,191,36,0.1)]' }
  if (isError(s))
    return { text: '오류', color: 'text-[var(--bad)]', bgColor: 'bg-[var(--bad-10)]' }
  if (s === 'offline' || s === 'inactive' || s === 'stopped' || s === 'unbooted')
    return { text: '오프라인', color: 'text-[#94a3b8]', bgColor: 'bg-[rgba(148,163,184,0.1)]' }
  return { text: status, color: 'text-[#86a0cf]', bgColor: 'bg-[rgba(138,163,211,0.08)]' }
}

// ── Live elapsed timer ────────────────────────────────────

function ElapsedTimer({ startMs }: { startMs: number }) {
  const elapsed = useSignal(Date.now() - startMs)
  const rafRef = useRef<number>(0)

  useEffect(() => {
    let mounted = true
    const tick = () => {
      if (!mounted) return
      elapsed.value = Date.now() - startMs
      rafRef.current = requestAnimationFrame(tick)
    }
    // Update once per second instead of every frame
    const interval = setInterval(() => { elapsed.value = Date.now() - startMs }, 1000)
    tick()
    return () => {
      mounted = false
      cancelAnimationFrame(rafRef.current)
      clearInterval(interval)
    }
  }, [startMs])

  return html`<span class="font-mono tabular-nums">${formatDuration(elapsed.value)}</span>`
}

// ── Main component ────────────────────────────────────────

interface SessionProgressHeaderProps {
  keeper: Keeper
  summary: TraceSummary | null
}

export function SessionProgressHeader({ keeper, summary }: SessionProgressHeaderProps) {
  const status = statusLabel(keeper.status)
  const online = isOnline(keeper.status)
  const gen = keeper.generation ?? 0
  const ctxRatio = keeper.context_ratio ?? 0
  const ctxPct = Math.round(ctxRatio * 100)
  const ctxColor = ctxPct > 85 ? 'var(--bad)' : ctxPct > 70 ? 'var(--warn)' : 'var(--ok)'

  const startMs = keeper.created_at ? new Date(keeper.created_at).getTime() : null
  const durationMs = sessionDurationMs(keeper)

  const toolCount = summary?.tool_call_count ?? keeper.latest_tool_call_count ?? 0
  const cost = summary?.total_cost_usd ?? 0

  return html`
    <div class="flex flex-col gap-3 px-5 py-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] backdrop-blur-sm">

      ${'' /* Row 1: Status + Duration + Generation */}
      <div class="flex items-center justify-between flex-wrap gap-3">
        <div class="flex items-center gap-3">
          ${'' /* Status badge */}
          <div class="flex items-center gap-1.5 px-3 py-1 rounded-full ${status.bgColor}">
            ${online ? html`
              <span class="relative flex size-2">
                <span class="animate-ping absolute inline-flex h-full w-full rounded-full opacity-75 ${status.color === 'text-[var(--ok)]' ? 'bg-[var(--ok)]' : 'bg-current'}"></span>
                <span class="relative inline-flex size-2 rounded-full ${status.color === 'text-[var(--ok)]' ? 'bg-[var(--ok)]' : 'bg-current'}"></span>
              </span>
            ` : html`<span class="size-2 rounded-full bg-current ${status.color}"></span>`}
            <span class="text-xs font-semibold ${status.color}">${status.text}</span>
          </div>

          ${'' /* Duration */}
          ${startMs && !Number.isNaN(startMs) ? html`
            <div class="flex items-center gap-1.5 text-sm ${online ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'}">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="opacity-60">
                <circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>
              </svg>
              ${online
                ? html`<${ElapsedTimer} startMs=${startMs} />`
                : durationMs != null
                  ? html`<span class="font-mono">${formatDuration(durationMs)}</span>`
                  : null
              }
            </div>
          ` : null}

          ${'' /* Generation */}
          ${gen > 0 ? html`
            <span class="text-[11px] font-mono px-2 py-0.5 rounded-md bg-[var(--white-5)] border border-[var(--white-8)] text-[var(--text-muted)]">
              Gen ${gen}
            </span>
          ` : null}
        </div>

        ${'' /* Right: quick stats */}
        <div class="flex items-center gap-3 text-[11px] text-[var(--text-muted)]">
          ${toolCount > 0 ? html`
            <span class="flex items-center gap-1">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="opacity-50">
                <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
              </svg>
              <span class="font-mono">${toolCount}</span> 호출
            </span>
          ` : null}
          ${cost > 0 ? html`
            <span class="font-mono text-[var(--accent)]">$${cost.toFixed(3)}</span>
          ` : null}
        </div>
      </div>

      ${'' /* Row 2: Context usage bar */}
      ${ctxPct > 0 ? html`
        <div class="flex items-center gap-3">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-dim)] w-16 flex-shrink-0">컨텍스트</span>
          <div class="flex-1 h-1.5 rounded-full bg-[var(--white-5)] overflow-hidden">
            <div class="h-full rounded-full transition-all duration-500" style="width: ${ctxPct}%; background: ${ctxColor}"></div>
          </div>
          <span class="text-[11px] font-mono w-10 text-right" style="color: ${ctxColor}">${ctxPct}%</span>
        </div>
      ` : null}
    </div>
  `
}

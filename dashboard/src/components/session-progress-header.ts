// Session progress header — status badge + live elapsed timer.
// Lightweight: all metric KPIs live in KpiGrid to avoid duplication.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import type { Keeper } from '../types'
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

  useEffect(() => {
    // Format granularity is seconds, so a 1 Hz tick is sufficient.
    const interval = setInterval(() => {
      elapsed.value = Date.now() - startMs
    }, 1000)
    return () => clearInterval(interval)
  }, [startMs])

  return html`<span class="font-mono tabular-nums">${formatDuration(elapsed.value)}</span>`
}

// ── Main component ────────────────────────────────────────

interface SessionProgressHeaderProps {
  keeper: Keeper
  summary?: unknown  // deprecated — metrics moved to KpiGrid
}

export function SessionProgressHeader({ keeper }: SessionProgressHeaderProps) {
  const status = statusLabel(keeper.status)
  const online = isOnline(keeper.status)

  const startMs = keeper.created_at ? new Date(keeper.created_at).getTime() : null
  const durationMs = sessionDurationMs(keeper)

  return html`
    <div class="flex items-center gap-3 px-5 py-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] backdrop-blur-sm">
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
    </div>
  `
}

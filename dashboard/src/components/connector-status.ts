// Connector Status — Channel Gate per-channel diagnostics panel.
// Shows connector health, success rate, duplicates, and latest failure context.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { lastEvent } from '../sse'
import { StatCard } from './common/stat-card'

interface ChannelInfo {
  channel: string
  message_count: number
  success_count: number
  error_count: number
  duplicate_count: number
  validation_error_count: number
  keeper_error_count: number
  dispatch_unavailable_count: number
  internal_error_count: number
  last_activity: string
  last_success: string
  last_error_at: string
  last_keeper: string
  last_room_id: string
  last_error: string
  last_error_kind: string
  last_outcome: string
  avg_duration_ms: number
  max_duration_ms: number
  slow_count: number
  slow_rate_pct: number
  success_rate_pct: number
  room_count: number
  health: 'idle' | 'healthy' | 'degraded' | 'failing' | string
}

interface GateStatusData {
  channels: ChannelInfo[]
  total_messages: number
  total_success: number
  total_errors: number
  total_duplicates: number
  success_rate_pct: number
  dedup_table_size: number
  uptime_seconds: number
}

const data = signal<GateStatusData | null>(null)
const loading = signal(false)
const error = signal<string | null>(null)

let inflightRequest: Promise<void> | null = null

async function refresh() {
  if (inflightRequest) return
  loading.value = true
  inflightRequest = (async () => {
    try {
      const result = await get<GateStatusData>('/api/v1/gate/status')
      data.value = result
      error.value = null
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'fetch failed'
    } finally {
      loading.value = false
      inflightRequest = null
    }
  })()
  return inflightRequest
}

const CHANNEL_ICONS: Record<string, string> = {
  discord: '\u{1F3AE}',
  telegram: '\u{2708}',
  slack: '\u{1F4AC}',
  signal: '\u{1F512}',
  webchat: '\u{1F310}',
  api: '\u{26A1}',
  internal: '\u{2699}',
}

function channelIcon(ch: string): string {
  return CHANNEL_ICONS[ch] ?? '\u{1F517}'
}

function formatUptime(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  return m > 0 ? `${h}h ${m}m` : `${h}h`
}

function timeAgo(iso: string): string {
  if (iso === 'never') return 'never'
  const diff = (Date.now() - new Date(iso).getTime()) / 1000
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

function healthTone(health: string): { dot: string; badge: string; label: string } {
  switch (health) {
    case 'healthy':
      return {
        dot: 'var(--green)',
        badge: 'border border-emerald-400/30 bg-emerald-500/12 text-emerald-100',
        label: 'healthy',
      }
    case 'degraded':
      return {
        dot: 'var(--yellow)',
        badge: 'border border-amber-400/30 bg-amber-500/12 text-amber-100',
        label: 'degraded',
      }
    case 'failing':
      return {
        dot: 'var(--red)',
        badge: 'border border-rose-400/35 bg-rose-500/12 text-rose-100',
        label: 'failing',
      }
    default:
      return {
        dot: 'var(--text-dim)',
        badge: 'border border-[var(--white-8)] bg-[var(--white-4)] text-[var(--text-dim)]',
        label: health || 'idle',
      }
  }
}

function shortText(value: string, limit = 96): string {
  const trimmed = value.trim()
  if (!trimmed) return ''
  if (trimmed.length <= limit) return trimmed
  return `${trimmed.slice(0, limit - 1)}…`
}

function ChannelCard({ ch }: { ch: ChannelInfo }) {
  const tone = healthTone(ch.health)
  const lastError = shortText(ch.last_error)

  return html`
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-lg">${channelIcon(ch.channel)}</span>
          <div>
            <div class="text-sm font-medium text-[var(--text-body)]">${ch.channel}</div>
            <div class="text-[10px] uppercase tracking-[0.18em] text-[var(--text-dim)]">
              ${ch.last_keeper ? `keeper ${ch.last_keeper}` : 'no keeper yet'}
            </div>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <div class="h-2 w-2 rounded-full" style="background: ${tone.dot}"></div>
          <span class=${`rounded-full px-2 py-1 text-[10px] uppercase tracking-[0.16em] ${tone.badge}`}>
            ${tone.label}
          </span>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-2 text-xs">
        <div>
          <div class="text-[var(--text-dim)]">messages</div>
          <div class="font-mono text-[var(--text-body)]">${ch.message_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">success</div>
          <div class="font-mono text-[var(--text-body)]">${ch.success_rate_pct}%</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">errors</div>
          <div class="font-mono text-[var(--text-body)]">${ch.error_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">duplicates</div>
          <div class="font-mono text-[var(--text-body)]">${ch.duplicate_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">namespaces</div>
          <div class="font-mono text-[var(--text-body)]">${ch.room_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">last active</div>
          <div class="font-mono text-[var(--text-body)]">${timeAgo(ch.last_activity)}</div>
        </div>
      </div>

      <div class="mt-3 grid grid-cols-2 gap-2 text-[11px] text-[var(--text-dim)]">
        <div>
          avg ${(ch.avg_duration_ms / 1000).toFixed(1)}s
          <span class="text-[var(--text-dim)]"> / max ${(ch.max_duration_ms / 1000).toFixed(1)}s</span>
        </div>
        <div>
          slow ${ch.slow_count}
          <span class="text-[var(--text-dim)]"> (${ch.slow_rate_pct}%)</span>
        </div>
        <div>
          last outcome
          <span class="font-mono text-[var(--text-body)]"> ${ch.last_outcome}</span>
        </div>
        <div>
          last namespace
          <span class="font-mono text-[var(--text-body)]"> ${ch.last_room_id || '-'}</span>
        </div>
      </div>

      ${lastError
        ? html`
            <div class="mt-3 rounded-md border border-rose-400/20 bg-rose-500/8 px-3 py-2 text-[11px] text-rose-100">
              <div class="mb-1 uppercase tracking-[0.16em] text-rose-200/80">
                ${ch.last_error_kind || 'error'} · ${timeAgo(ch.last_error_at)}
              </div>
              <div>${lastError}</div>
            </div>
          `
        : null}
    </div>
  `
}

export function ConnectorStatusPanel() {
  useEffect(() => {
    refresh()
  }, [])

  useEffect(() => {
    const event = lastEvent.value
    if (event && data.value) {
      const timer = setTimeout(refresh, 2000)
      return () => clearTimeout(timer)
    }
  }, [lastEvent.value])

  const d = data.value

  if (loading.value && !d) {
    return html`<div class="text-xs text-[var(--text-dim)]">Loading connector status...</div>`
  }

  if (error.value && !d) {
    return html`<div class="text-xs text-[var(--red)]">Gate: ${error.value}</div>`
  }

  if (!d) return null

  return html`
    <div>
      <div class="mb-3 flex items-center justify-between gap-3">
        <h3 class="text-sm font-semibold text-[var(--text-body)]">Channel Gate</h3>
        <div class="text-[10px] uppercase tracking-[0.16em] text-[var(--text-dim)]">
          success ${d.success_rate_pct}% · uptime ${formatUptime(d.uptime_seconds)}
        </div>
      </div>

      <div class="mb-3 grid grid-cols-4 gap-2 max-[720px]:grid-cols-2">
        <${StatCard} label="Messages" value=${d.total_messages} />
        <${StatCard} label="Success" value=${d.total_success} />
        <${StatCard} label="Errors" value=${d.total_errors} />
        <${StatCard} label="Dedup Keys" value=${d.dedup_table_size} />
      </div>

      <div class="mb-4 grid grid-cols-2 gap-2 text-[11px] text-[var(--text-dim)] max-[720px]:grid-cols-1">
        <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
          duplicate suppressions
          <span class="ml-2 font-mono text-[var(--text-body)]">${d.total_duplicates}</span>
        </div>
        <div class="rounded-md border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
          active connectors
          <span class="ml-2 font-mono text-[var(--text-body)]">${d.channels.length}</span>
        </div>
      </div>

      ${d.channels.length === 0
        ? html`<div class="py-4 text-center text-xs text-[var(--text-dim)]">No active connectors</div>`
        : html`
            <div class="grid grid-cols-2 gap-2 max-[900px]:grid-cols-1">
              ${d.channels.map(ch => html`<${ChannelCard} ch=${ch} />`)}
            </div>
          `}
    </div>
  `
}

export function resetConnectorStatusState() {
  data.value = null
  loading.value = false
  error.value = null
  inflightRequest = null
}

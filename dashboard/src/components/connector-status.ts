// Connector Status — Channel Gate per-channel metrics panel.
// Shows connected channels, message counts, last activity, avg latency.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { lastEvent } from '../sse'
import { StatCard } from './common/stat-card'

interface ChannelInfo {
  channel: string
  message_count: number
  error_count: number
  last_activity: string
  last_keeper: string
  avg_duration_ms: number
}

interface GateStatusData {
  channels: ChannelInfo[]
  total_messages: number
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
  discord: '\u{1F3AE}',   // game controller
  telegram: '\u{2708}',    // airplane (paper plane)
  slack: '\u{1F4AC}',      // speech bubble
  signal: '\u{1F512}',     // lock
  webchat: '\u{1F310}',    // globe
  api: '\u{26A1}',         // zap
  internal: '\u{2699}',    // gear
}

function channelIcon(ch: string): string {
  return CHANNEL_ICONS[ch] ?? '\u{1F517}' // link
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

function ChannelCard({ ch }: { ch: ChannelInfo }) {
  const errorRate = ch.message_count > 0
    ? Math.round((ch.error_count / ch.message_count) * 100)
    : 0
  const statusColor = errorRate > 20 ? 'var(--red)' : errorRate > 5 ? 'var(--yellow)' : 'var(--green)'

  return html`
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <span class="text-lg">${channelIcon(ch.channel)}</span>
          <span class="text-sm font-medium text-[var(--text-body)]">${ch.channel}</span>
        </div>
        <div class="w-2 h-2 rounded-full" style="background: ${statusColor}"></div>
      </div>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <div>
          <div class="text-[var(--text-dim)]">messages</div>
          <div class="font-mono text-[var(--text-body)]">${ch.message_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">errors</div>
          <div class="font-mono" style="color: ${ch.error_count > 0 ? 'var(--red)' : 'var(--text-body)'}">${ch.error_count}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">avg latency</div>
          <div class="font-mono text-[var(--text-body)]">${ch.avg_duration_ms > 0 ? `${(ch.avg_duration_ms / 1000).toFixed(1)}s` : '-'}</div>
        </div>
        <div>
          <div class="text-[var(--text-dim)]">last active</div>
          <div class="font-mono text-[var(--text-body)]">${timeAgo(ch.last_activity)}</div>
        </div>
      </div>
      ${ch.last_keeper ? html`
        <div class="mt-2 text-[10px] text-[var(--text-dim)]">keeper: ${ch.last_keeper}</div>
      ` : null}
    </div>
  `
}

export function ConnectorStatusPanel() {
  useEffect(() => {
    refresh()
  }, [])

  // Refresh on SSE events (debounced by sse-store)
  useEffect(() => {
    const _event = lastEvent.value
    if (_event && data.value) {
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
      <h3 class="text-sm font-semibold text-[var(--text-body)] mb-3">Channel Gate</h3>

      <div class="grid grid-cols-3 gap-2 mb-3">
        <${StatCard} label="Messages" value=${d.total_messages} />
        <${StatCard} label="Dedup Keys" value=${d.dedup_table_size} />
        <${StatCard} label="Uptime" value=${formatUptime(d.uptime_seconds)} />
      </div>

      ${d.channels.length === 0
        ? html`<div class="text-xs text-[var(--text-dim)] text-center py-4">No active connectors</div>`
        : html`
          <div class="grid grid-cols-2 gap-2 max-[600px]:grid-cols-1">
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

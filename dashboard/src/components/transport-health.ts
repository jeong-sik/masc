// MASC Dashboard -- Transport Health Panel
// Shows SSE sessions, gRPC streams, heartbeat status, and broadcast latency.

import { html } from 'htm/preact'
import { signal, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'

interface TransportHealthData {
  sse: {
    sessions_observer: number
    sessions_coordinator: number
    sessions_total: number
    broadcast_avg_seconds: number
    broadcast_count: number
  }
  grpc: {
    active_streams: number
    subscribers: number
    heartbeat_avg_seconds: number
    events_delivered: number
  }
  agent_health: {
    stale_total: number
  }
  generated_at: string
}

const transportHealth: Signal<TransportHealthData | null> = signal(null)
const loading: Signal<boolean> = signal(false)
const error: Signal<string | null> = signal(null)

async function refreshTransportHealth(): Promise<void> {
  loading.value = true
  error.value = null
  try {
    const data = await get<TransportHealthData>('/api/v1/dashboard/transport-health')
    transportHealth.value = data
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    loading.value = false
  }
}

function formatLatency(seconds: number): string {
  if (seconds === 0) return '-'
  if (seconds < 0.001) return `${(seconds * 1_000_000).toFixed(0)}us`
  if (seconds < 1) return `${(seconds * 1000).toFixed(1)}ms`
  return `${seconds.toFixed(2)}s`
}

function latencyStatus(avgSeconds: number): 'ok' | 'warn' | 'bad' {
  if (avgSeconds === 0) return 'ok'
  if (avgSeconds < 0.1) return 'ok'
  if (avgSeconds < 0.5) return 'warn'
  return 'bad'
}

function statusDot(status: 'ok' | 'warn' | 'bad'): string {
  if (status === 'ok') return 'bg-[var(--ok)]'
  if (status === 'warn') return 'bg-[var(--warn)]'
  return 'bg-[var(--bad)]'
}

function MetricRow({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return html`
    <div class="flex items-center justify-between py-1.5">
      <span class="text-xs text-text-muted">${label}</span>
      <div class="flex items-center gap-1.5">
        <span class="text-sm font-mono font-medium text-text-strong">${value}</span>
        ${sub ? html`<span class="text-[10px] text-text-muted">${sub}</span>` : null}
      </div>
    </div>
  `
}

function SectionCard({ title, icon, children }: { title: string; icon: string; children: any }) {
  return html`
    <div class="rounded-lg border border-card-border bg-bg-1/60 p-4">
      <div class="flex items-center gap-2 mb-3">
        <span class="text-sm">${icon}</span>
        <span class="text-xs font-semibold text-text-strong uppercase tracking-wider">${title}</span>
      </div>
      <div class="divide-y divide-card-border/50">
        ${children}
      </div>
    </div>
  `
}

export function TransportHealthPanel() {
  useEffect(() => {
    refreshTransportHealth()
    const interval = setInterval(() => void refreshTransportHealth(), 15_000)
    return () => clearInterval(interval)
  }, [])

  const data = transportHealth.value

  if (loading.value && !data) {
    return html`
      <div class="p-6 text-center text-text-muted text-sm">
        Transport health loading...
      </div>
    `
  }

  if (error.value && !data) {
    return html`
      <div class="p-6 text-center text-[var(--bad)] text-sm">
        ${error.value}
      </div>
    `
  }

  if (!data) return null

  const broadcastStatus = latencyStatus(data.sse.broadcast_avg_seconds)
  const grpcStatus = data.grpc.active_streams > 0 ? 'ok' : 'warn'
  const staleStatus: 'ok' | 'warn' | 'bad' = data.agent_health.stale_total === 0 ? 'ok' : data.agent_health.stale_total < 3 ? 'warn' : 'bad'

  return html`
    <div class="space-y-4">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="text-base">Transport</span>
          <div class="flex items-center gap-1">
            <span class="w-1.5 h-1.5 rounded-full ${statusDot(broadcastStatus)}"></span>
            <span class="w-1.5 h-1.5 rounded-full ${statusDot(grpcStatus)}"></span>
            <span class="w-1.5 h-1.5 rounded-full ${statusDot(staleStatus)}"></span>
          </div>
        </div>
        <button
          class="text-[10px] text-text-muted hover:text-text-body transition-colors"
          onClick=${() => refreshTransportHealth()}
        >refresh</button>
      </div>

      <!-- SSE -->
      <${SectionCard} title="SSE" icon="">
        <${MetricRow} label="Observer Sessions" value=${data.sse.sessions_observer} />
        <${MetricRow} label="Coordinator Sessions" value=${data.sse.sessions_coordinator} />
        <${MetricRow} label="Total Sessions" value=${data.sse.sessions_total} />
        <${MetricRow}
          label="Broadcast Latency (avg)"
          value=${formatLatency(data.sse.broadcast_avg_seconds)}
          sub=${`(${data.sse.broadcast_count} events)`}
        />
      <//>

      <!-- gRPC -->
      <${SectionCard} title="gRPC" icon="">
        <${MetricRow} label="Active Streams" value=${data.grpc.active_streams} />
        <${MetricRow} label="Subscribers" value=${data.grpc.subscribers} />
        <${MetricRow}
          label="Heartbeat Latency (avg)"
          value=${formatLatency(data.grpc.heartbeat_avg_seconds)}
        />
        <${MetricRow} label="Events Delivered" value=${data.grpc.events_delivered} />
      <//>

      <!-- Agent Health -->
      <${SectionCard} title="Agent Health" icon="">
        <${MetricRow} label="Stale Agents" value=${data.agent_health.stale_total} />
      <//>
    </div>
  `
}

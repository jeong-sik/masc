import { html } from 'htm/preact'
import { signal, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import type { ComponentChildren } from 'preact'
import { get } from '../api/core'
import { lastEvent } from '../sse'
import type { SSEEvent } from '../types'

type StatusTone = 'ok' | 'warn' | 'bad'

interface HotSession {
  session_id: string
  kind: string
  queue_depth: number
  last_event_id: number
  idle_seconds: number
}

interface TransportHealthData {
  summary: {
    primary_path: string
    queue_pressure: string
    recent_messages: number
    external_fanout_targets: number
  }
  sse: {
    sessions_observer: number
    sessions_coordinator: number
    sessions_total: number
    external_subscribers: number
    broadcast_avg_seconds: number
    broadcast_count: number
    queue_avg_depth: number
    queue_max_depth: number
    hot_sessions: HotSession[]
  }
  grpc: {
    enabled: boolean
    configured: boolean
    listening: boolean
    port: number
    active_streams: number
    subscribers: number
    heartbeat_avg_seconds: number
    events_delivered: number
  }
  websocket: {
    enabled: boolean
    configured: boolean
    listening: boolean
    mode: string
    port: number
    sessions: number
    relay_source: string
  }
  webrtc: {
    enabled: boolean
    pending_offers: number
    active_peers: number
    live_connections: number
    connected_channels: number
    ice_server_count: number
  }
  streamable_http: {
    endpoint: string
    observer_stream: string
    managed_endpoint: string
    operator_endpoint: string
    delete_endpoint: string
    legacy_sse_endpoint: string
    legacy_messages_endpoint: string
    default_transport: string
    supports_post: boolean
    supports_sse_upgrade: boolean
    supports_delete: boolean
  }
  http2: {
    listener_mode: string
    multiplex_ready: boolean
    prior_knowledge_path: string
  }
  cluster: {
    cluster: string
    room_id: string
    total_units: number
    managed_units: number
    live_agents: number
    active_operations: number
    stale_units: number
  }
  agent_health: {
    stale_total: number
  }
  generated_at: string
}

type PracticalCase = {
  id: string
  title: string
  transport: string
  endpoint: (data: TransportHealthData) => string
  description: string
  live: (data: TransportHealthData) => string
}

const transportHealth: Signal<TransportHealthData | null> = signal(null)
const loading: Signal<boolean> = signal(false)
const error: Signal<string | null> = signal(null)

const PRACTICAL_CASES: PracticalCase[] = [
  {
    id: 'wallboard',
    title: 'Wallboard / dashboard',
    transport: 'SSE',
    endpoint: (data) => data.streamable_http.observer_stream,
    description: '읽기 전용 현황판은 observer SSE가 가장 단순하고 안정적입니다. HTTP/2 multiplexing이 붙으면 브라우저 연결 한계도 피하기 쉽습니다.',
    live: (data) => `${data.sse.sessions_observer} observer · qmax ${data.sse.queue_max_depth}`,
  },
  {
    id: 'agent-fanout',
    title: 'Agent fanout / heartbeat',
    transport: 'gRPC',
    endpoint: (data) => `:${data.grpc.port}`,
    description: '양방향 스트림과 subscribe bridge가 필요한 agent control에는 gRPC가 맞습니다. heartbeat와 backlog replay가 이미 붙어 있습니다.',
    live: (data) => `${data.grpc.listening ? 'live' : 'down'} · ${data.grpc.subscribers} subs · ${data.grpc.active_streams} streams`,
  },
  {
    id: 'duplex-ui',
    title: 'Duplex UI / browser bridge',
    transport: 'WebSocket',
    endpoint: (_data) => '/ws',
    description: '브라우저나 operator UI가 request/response를 한 socket에서 주고받아야 하면 standalone WS가 더 낫습니다.',
    live: (data) => `${data.websocket.listening ? 'live' : 'down'} · ${data.websocket.sessions} sessions · port ${data.websocket.port}`,
  },
  {
    id: 'p2p-fastlane',
    title: 'P2P fast lane',
    transport: 'WebRTC',
    endpoint: (_data) => '/webrtc/offer -> /webrtc/answer',
    description: '서버 signaling 이후 DataChannel로 peer-to-peer 경로를 올립니다. 빠른 a2a messaging이나 edge peer 연결에 적합합니다.',
    live: (data) => `${data.webrtc.connected_channels} channels · ${data.webrtc.active_peers} peers`,
  },
  {
    id: 'stateless-control',
    title: 'Stateless scripting / queue trigger',
    transport: 'Streamable HTTP',
    endpoint: (data) => data.streamable_http.endpoint,
    description: 'curl, harness, worker bootstrap처럼 빠르게 치고 빠지는 제어면 POST /mcp가 기본 경로입니다. 세션 없이도 바로 호출 가능합니다.',
    live: (data) => `${data.summary.recent_messages} recent msgs · ${data.cluster.active_operations} active ops`,
  },
]

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

function shouldRefreshFromEvent(event: SSEEvent): boolean {
  const type = (event.type ?? '').trim()
  if (!type) return false
  if (type === 'keeper_heartbeat') return false
  if (type === 'broadcast' || type === 'masc/broadcast') return true
  if (type === 'agent_joined' || type === 'masc/agent_joined') return true
  if (type === 'agent_left' || type === 'masc/agent_left') return true
  if (type.startsWith('task_') || type.startsWith('masc/task_')) return true
  if (type.startsWith('keeper_') || type.startsWith('masc/keeper_')) return true
  if (type.startsWith('decision_') || type === 'governance_param_changed') return true
  return type.startsWith('client_input_')
}

function formatLatency(seconds: number): string {
  if (seconds === 0) return '-'
  if (seconds < 0.001) return `${(seconds * 1_000_000).toFixed(0)}us`
  if (seconds < 1) return `${(seconds * 1000).toFixed(1)}ms`
  return `${seconds.toFixed(2)}s`
}

function formatFloat(value: number): string {
  if (value === 0) return '0'
  if (value < 1) return value.toFixed(2)
  return value.toFixed(1)
}

function formatIdle(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  return `${Math.round(seconds / 3600)}h`
}

function compactId(value: string): string {
  if (value.length <= 18) return value
  return `${value.slice(0, 8)}...${value.slice(-6)}`
}

function statusDot(status: StatusTone): string {
  if (status === 'ok') return 'bg-[var(--ok)]'
  if (status === 'warn') return 'bg-[var(--warn)]'
  return 'bg-[var(--bad)]'
}

function toneClass(status: StatusTone): string {
  if (status === 'ok') return 'text-[var(--ok)]'
  if (status === 'warn') return 'text-[var(--warn)]'
  return 'text-[var(--bad)]'
}

function queuePressureTone(pressure: string): StatusTone {
  if (pressure === 'high') return 'bad'
  if (pressure === 'watch') return 'warn'
  return 'ok'
}

function transportTone(configured: boolean, listening: boolean, active: boolean): StatusTone {
  if (!configured) return 'warn'
  if (!listening) return 'bad'
  return active ? 'ok' : 'warn'
}

function grpcTone(data: TransportHealthData): StatusTone {
  return transportTone(
    data.grpc.configured,
    data.grpc.listening,
    data.grpc.subscribers > 0 || data.grpc.active_streams > 0,
  )
}

function websocketTone(data: TransportHealthData): StatusTone {
  return transportTone(
    data.websocket.configured,
    data.websocket.listening,
    data.websocket.sessions > 0,
  )
}

function webrtcTone(data: TransportHealthData): StatusTone {
  return transportTone(data.webrtc.enabled, true, data.webrtc.connected_channels > 0)
}

function http2Tone(data: TransportHealthData): StatusTone {
  return data.http2.multiplex_ready ? 'ok' : 'warn'
}

function staleTone(staleTotal: number): StatusTone {
  if (staleTotal === 0) return 'ok'
  if (staleTotal < 3) return 'warn'
  return 'bad'
}

function MetricRow({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return html`
    <div class="flex items-center justify-between gap-3 py-1.5">
      <span class="text-xs text-text-muted">${label}</span>
      <div class="flex items-center gap-2 min-w-0">
        <span class="text-sm font-mono font-medium text-text-strong truncate">${value}</span>
        ${sub ? html`<span class="text-[10px] text-text-muted truncate">${sub}</span>` : null}
      </div>
    </div>
  `
}

function transportEyebrow(configured: boolean, listening: boolean, port: number): string {
  if (!configured) return 'disabled'
  return listening ? `:${port} live` : `:${port} down`
}

function SectionCard({
  title,
  status,
  eyebrow,
  children,
}: {
  title: string
  status: StatusTone
  eyebrow?: string
  children: ComponentChildren
}) {
  return html`
    <div class="rounded-xl border border-card-border bg-bg-1/60 p-4">
      <div class="flex items-center justify-between gap-3 mb-3">
        <div class="flex items-center gap-2 min-w-0">
          <span class=${`w-2 h-2 rounded-full shrink-0 ${statusDot(status)}`}></span>
          <span class="text-xs font-semibold text-text-strong uppercase tracking-wider truncate">${title}</span>
        </div>
        ${eyebrow ? html`<span class=${`text-[10px] uppercase tracking-wider ${toneClass(status)}`}>${eyebrow}</span>` : null}
      </div>
      <div class="divide-y divide-card-border/50">
        ${children}
      </div>
    </div>
  `
}

function CaseCard({ item, data }: { item: PracticalCase; data: TransportHealthData }) {
  return html`
    <div class="rounded-xl border border-card-border/70 bg-card/40 p-4">
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="text-sm font-semibold text-text-strong">${item.title}</div>
        <div class="text-[10px] uppercase tracking-wider text-text-muted">${item.transport}</div>
      </div>
      <div class="text-[11px] text-text-muted mb-2 font-mono break-all">${item.endpoint(data)}</div>
      <div class="text-[12px] text-text-body leading-relaxed">${item.description}</div>
      <div class="mt-3 text-[11px] text-[var(--accent)]">${item.live(data)}</div>
    </div>
  `
}

export function TransportHealthPanel() {
  useEffect(() => {
    void refreshTransportHealth()

    const interval = setInterval(() => {
      void refreshTransportHealth()
    }, 30_000)

    let debounceTimer: ReturnType<typeof setTimeout> | null = null
    const unsubscribe = lastEvent.subscribe((event) => {
      if (!event || !shouldRefreshFromEvent(event)) return
      if (debounceTimer) clearTimeout(debounceTimer)
      debounceTimer = setTimeout(() => {
        void refreshTransportHealth()
        debounceTimer = null
      }, 1200)
    })

    return () => {
      clearInterval(interval)
      unsubscribe()
      if (debounceTimer) clearTimeout(debounceTimer)
    }
  }, [])

  const data = transportHealth.value

  if (loading.value && !data) {
    return html`<div class="p-6 text-center text-text-muted text-sm">Transport health loading...</div>`
  }

  if (error.value && !data) {
    return html`<div class="p-6 text-center text-[var(--bad)] text-sm">${error.value}</div>`
  }

  if (!data) return null

  const sseStatus = queuePressureTone(data.summary.queue_pressure)
  const grpcStatus = grpcTone(data)
  const wsStatus = websocketTone(data)
  const webrtcStatus = webrtcTone(data)
  const h2Status = http2Tone(data)
  const clusterStatus = staleTone(data.agent_health.stale_total)

  return html`
    <div class="space-y-4">
      <div class="flex items-start justify-between gap-4">
        <div>
          <div class="flex items-center gap-2">
            <span class="text-base text-text-strong">Transport</span>
            <span class="text-[10px] uppercase tracking-wider text-text-muted">${data.cluster.cluster} / ${data.cluster.room_id}</span>
          </div>
          <div class="mt-1 text-sm text-text-body">
            primary path: <span class="font-mono text-text-strong">${data.summary.primary_path}</span>
            <span class=${`ml-2 text-[11px] uppercase tracking-wider ${toneClass(sseStatus)}`}>${data.summary.queue_pressure}</span>
          </div>
        </div>
        <button
          class="text-[10px] text-text-muted hover:text-text-body transition-colors"
          onClick=${() => void refreshTransportHealth()}
        >refresh</button>
      </div>

      <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
        <${SectionCard} title="SSE" status=${sseStatus} eyebrow=${`${data.sse.sessions_total} live`}>
          <${MetricRow} label="Observer" value=${data.sse.sessions_observer} />
          <${MetricRow} label="Coordinator" value=${data.sse.sessions_coordinator} />
          <${MetricRow} label="External Fanout" value=${data.sse.external_subscribers} />
          <${MetricRow} label="Queue" value=${data.sse.queue_max_depth} sub=${`max / avg ${formatFloat(data.sse.queue_avg_depth)}`} />
          <${MetricRow} label="Broadcast Avg" value=${formatLatency(data.sse.broadcast_avg_seconds)} sub=${`${data.sse.broadcast_count} events`} />
        <//>

        <${SectionCard} title="gRPC" status=${grpcStatus} eyebrow=${transportEyebrow(data.grpc.configured, data.grpc.listening, data.grpc.port)}>
          <${MetricRow} label="Listener" value=${data.grpc.listening ? 'live' : 'down'} />
          <${MetricRow} label="Subscribers" value=${data.grpc.subscribers} />
          <${MetricRow} label="Active Streams" value=${data.grpc.active_streams} />
          <${MetricRow} label="Heartbeat Avg" value=${formatLatency(data.grpc.heartbeat_avg_seconds)} />
          <${MetricRow} label="Events Delivered" value=${data.grpc.events_delivered} />
        <//>

        <${SectionCard} title="WebSocket" status=${wsStatus} eyebrow=${transportEyebrow(data.websocket.configured, data.websocket.listening, data.websocket.port)}>
          <${MetricRow} label="Listener" value=${data.websocket.listening ? 'live' : 'down'} />
          <${MetricRow} label="Sessions" value=${data.websocket.sessions} />
          <${MetricRow} label="Mode" value=${data.websocket.mode} />
          <${MetricRow} label="Relay Source" value=${data.websocket.relay_source} />
        <//>

        <${SectionCard} title="WebRTC" status=${webrtcStatus} eyebrow=${data.webrtc.enabled ? `${data.webrtc.ice_server_count} ICE` : 'disabled'}>
          <${MetricRow} label="Connected Channels" value=${data.webrtc.connected_channels} />
          <${MetricRow} label="Active Peers" value=${data.webrtc.active_peers} />
          <${MetricRow} label="Pending Offers" value=${data.webrtc.pending_offers} />
          <${MetricRow} label="Live Connections" value=${data.webrtc.live_connections} />
        <//>

        <${SectionCard} title="HTTP" status=${h2Status} eyebrow=${data.http2.listener_mode}>
          <${MetricRow} label="POST" value=${data.streamable_http.endpoint} />
          <${MetricRow} label="Observer Stream" value=${data.streamable_http.observer_stream} />
          <${MetricRow} label="Operator Surface" value=${data.streamable_http.operator_endpoint} />
          <${MetricRow} label="Legacy" value=${data.streamable_http.legacy_sse_endpoint} sub=${'deprecated'} />
        <//>

        <${SectionCard} title="Cluster" status=${clusterStatus} eyebrow=${`${data.cluster.live_agents} live`}>
          <${MetricRow} label="Managed Units" value=${data.cluster.managed_units} sub=${`${data.cluster.total_units} total`} />
          <${MetricRow} label="Active Ops" value=${data.cluster.active_operations} />
          <${MetricRow} label="Stale Units" value=${data.cluster.stale_units} />
          <${MetricRow} label="Stale Agents" value=${data.agent_health.stale_total} />
        <//>
      </div>

      ${data.sse.hot_sessions.length > 0
        ? html`
            <div class="rounded-xl border border-card-border/70 bg-card/35 p-4">
              <div class="flex items-center justify-between gap-3 mb-3">
                <span class="text-xs font-semibold text-text-strong uppercase tracking-wider">Hot Queues</span>
                <span class="text-[10px] text-text-muted">backpressure candidates</span>
              </div>
              <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
                ${data.sse.hot_sessions.map((session) => html`
                  <div class="rounded-lg border border-card-border/60 bg-bg-1/60 p-3">
                    <div class="flex items-center justify-between gap-2 mb-1">
                      <span class="text-[11px] font-mono text-text-strong">${compactId(session.session_id)}</span>
                      <span class="text-[10px] uppercase tracking-wider text-text-muted">${session.kind}</span>
                    </div>
                    <div class="text-[11px] text-text-body">queue ${session.queue_depth}</div>
                    <div class="text-[10px] text-text-muted mt-1">idle ${formatIdle(session.idle_seconds)} · last ${session.last_event_id}</div>
                  </div>
                `)}
              </div>
            </div>
          `
        : null}

      <div class="rounded-xl border border-card-border/70 bg-card/35 p-4">
        <div class="flex items-center justify-between gap-3 mb-3">
          <span class="text-xs font-semibold text-text-strong uppercase tracking-wider">Practical Paths</span>
          <span class="text-[10px] text-text-muted">${data.generated_at}</span>
        </div>
        <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
          ${PRACTICAL_CASES.map((item) => html`<${CaseCard} item=${item} data=${data} />`)}
        </div>
      </div>
    </div>
  `
}

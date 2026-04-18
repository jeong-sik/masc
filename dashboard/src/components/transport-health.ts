import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import type { ComponentChildren } from 'preact'
import { lastEvent } from '../sse'
import type { SSEEvent } from '../types'
import { FetchScheduler } from '../lib/fetch-scheduler'
import {
  fetchTransportHealth,
  decodeTransportHealthData,
  type HotSession,
  type TransportHealthData,
} from '../api/transport-health'
import { createManagedAsyncResource } from '../lib/async-state'
import { TextInput } from './common/input'
import { StatusDot } from './common/status-dot'
import { CopyIdButton } from './common/copy-id-button'

type StatusTone = 'ok' | 'warn' | 'bad'

type PracticalCase = {
  id: string
  title: string
  transport: string
  endpoint: (data: TransportHealthData) => string
  description: string
  live: (data: TransportHealthData) => string
}

const transportHealthResource = createManagedAsyncResource<TransportHealthData>()
let inflightTransportHealthRefresh: Promise<void> | null = null

// Module-scoped search state for the hot-sessions list (stale-filter-carryover
// bug guard: must be cleared in resetTransportHealthState).
const hotSessionsSearchQuery = signal('')

/**
 * Case-insensitive substring filter over hot sessions.
 * Searches: session_id (full uuid), kind, last_event_id (number → string).
 * Does NOT match queue_depth (numeric, not useful for user search).
 *
 * Empty/whitespace query returns the input reference unchanged (no mutation,
 * no new array allocation — referentially stable for memoization callers).
 */
export function filterHotSessions(
  sessions: readonly HotSession[],
  query: string,
): readonly HotSession[] {
  const q = query.trim().toLowerCase()
  if (q === '') return sessions
  return sessions.filter((session) => {
    if (session.session_id.toLowerCase().includes(q)) return true
    if (session.kind.toLowerCase().includes(q)) return true
    if (String(session.last_event_id).toLowerCase().includes(q)) return true
    return false
  })
}

export function resetTransportHealthState(): void {
  inflightTransportHealthRefresh = null
  hotSessionsSearchQuery.value = ''
  transportHealthResource.reset()
}

/** Hydrate transport health from SSE payload — zero HTTP fetch. */
export function hydrateTransportHealthFromSSE(data: unknown): void {
  const decoded = decodeTransportHealthData(data)
  if (!decoded) return
  transportHealthResource.reset(decoded)
}

const PRACTICAL_CASES: PracticalCase[] = [
  {
    id: 'wallboard',
    title: '월보드 / 대시보드',
    transport: 'SSE',
    endpoint: (data) => data.streamable_http.observer_stream,
    description: 'Observer SSE 읽기 전용 스트림.',
    live: (data) => `${data.sse.sessions_observer} observer · qmax ${data.sse.queue_max_depth}`,
  },
  {
    id: 'agent-fanout',
    title: '에이전트 팬아웃 / 하트비트',
    transport: 'gRPC',
    endpoint: (data) => `:${data.grpc.port}`,
    description: '양방향 스트림. heartbeat, backlog replay 지원.',
    live: (data) => `${data.grpc.listening ? 'live' : 'down'} · ${data.grpc.subscribers} subs · ${data.grpc.active_streams} streams`,
  },
  {
    id: 'duplex-ui',
    title: '양방향 UI / 브라우저 브릿지',
    transport: 'WebSocket',
    endpoint: () => '/ws',
    description: '양방향 소켓. operator UI 제어용.',
    live: (data) => `${data.websocket.listening ? 'live' : 'down'} · ${data.websocket.sessions} sessions · port ${data.websocket.port}`,
  },
  {
    id: 'p2p-fastlane',
    title: 'P2P 패스트 레인',
    transport: 'WebRTC',
    endpoint: () => '/webrtc/offer -> /webrtc/answer',
    description: 'DataChannel P2P. signaling 후 직접 연결.',
    live: (data) => `${data.webrtc.connected_channels} channels · ${data.webrtc.active_peers} peers`,
  },
  {
    id: 'stateless-control',
    title: '스테이트리스 스크립팅 / 큐 트리거',
    transport: 'Streamable HTTP',
    endpoint: (data) => data.streamable_http.endpoint,
    description: 'Stateless POST. 세션 불필요.',
    live: (data) => `${formatMetricValue(data.summary.recent_messages)} recent msgs · ${formatMetricValue(data.cluster.active_operations)} active ops`,
  },
]

async function refreshTransportHealth(): Promise<void> {
  if (inflightTransportHealthRefresh) return inflightTransportHealthRefresh
  inflightTransportHealthRefresh = transportHealthResource
    .load((signal) => fetchTransportHealth({ signal }))
    .then(() => {})
    .finally(() => {
      inflightTransportHealthRefresh = null
    })
  return inflightTransportHealthRefresh
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

function sseTone(data: TransportHealthData): StatusTone {
  if (data.sse.relay_drop_total > 0) return 'bad'
  if (data.sse.relay_retry_total > 0 || data.sse.relay_queue_depth > 0) return 'warn'
  return queuePressureTone(data.summary.queue_pressure)
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

function webrtcActive(data: TransportHealthData): boolean {
  return data.webrtc.connected_channels > 0
    || data.webrtc.live_connections > 0
    || data.webrtc.active_peers > 0
}

function webrtcTone(data: TransportHealthData): StatusTone {
  return transportTone(
    data.webrtc.configured,
    data.webrtc.signaling_available,
    webrtcActive(data),
  )
}

function http2Tone(data: TransportHealthData): StatusTone {
  return data.http2.multiplex_ready ? 'ok' : 'warn'
}

function staleTone(staleTotal: number): StatusTone {
  if (staleTotal === 0) return 'ok'
  if (staleTotal < 3) return 'warn'
  return 'bad'
}

function agentPoolTone(data: TransportHealthData): StatusTone {
  const staleStatus = staleTone(data.agent_health.stale_total)
  if (staleStatus !== 'ok') return staleStatus
  return data.agent_health.lifecycle_dispatch_rejections_total > 0 ? 'warn' : 'ok'
}

function formatMetricValue(value: number | null): string | number {
  return value === null ? 'n/a' : value
}

function transportTruthLine(data: TransportHealthData): string | null {
  const diagnostics = data.projection_diagnostics
  if (!diagnostics) return null
  const parts = [
    diagnostics.source,
    `cache ${diagnostics.cache_state}`,
  ]
  if (diagnostics.stale_age_ms !== null) {
    parts.push(`stale ${diagnostics.stale_age_ms}ms`)
  } else if (diagnostics.last_success_at) {
    parts.push(`last ok ${diagnostics.last_success_at}`)
  }
  return parts.join(' · ')
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

function webrtcEyebrow(data: TransportHealthData): string {
  if (!data.webrtc.configured) return 'disabled'
  return data.webrtc.signaling_available
    ? `${data.webrtc.ice_server_count} ICE · signaling ready`
    : 'signaling down'
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
    <div class="rounded border border-card-border bg-bg-1/60 p-4">
      <div class="flex items-center justify-between gap-3 mb-3">
        <div class="flex items-center gap-2 min-w-0">
          <${StatusDot} size="sm" class=${statusDot(status)} />
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
    <div class="rounded border border-card-border/70 bg-card/40 p-4">
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
    const sseRefreshScheduler = new FetchScheduler(
      () => refreshTransportHealth(),
      { cooldownMs: 0, debounceMs: 1200 },
    )

    const interval = setInterval(() => {
      void refreshTransportHealth()
    }, 30_000)

    const unsubscribe = lastEvent.subscribe((event) => {
      if (!event || !shouldRefreshFromEvent(event)) return
      sseRefreshScheduler.request()
    })

    return () => {
      clearInterval(interval)
      unsubscribe()
      sseRefreshScheduler.dispose()
    }
  }, [])

  const { data, loading, error } = transportHealthResource.state.value

  if (loading && !data) {
    return html`<div class="p-6 text-center text-text-muted text-sm">트랜스포트 상태 로딩 중...</div>`
  }

  if (error && !data) {
    return html`<div class="p-6 text-center text-[var(--bad)] text-sm">${error}</div>`
  }

  if (!data) return null
  if (!data.summary || !data.agent_health) {
    return html`<div class="p-6 text-center text-text-muted text-sm">트랜스포트 데이터 불완전. <button class="underline" onClick=${() => void refreshTransportHealth()}>재시도</button></div>`
  }

  const sseStatus = sseTone(data)
  const grpcStatus = grpcTone(data)
  const wsStatus = websocketTone(data)
  const webrtcStatus = webrtcTone(data)
  const h2Status = http2Tone(data)
  const clusterStatus = data.cluster.topology_available ? agentPoolTone(data) : 'warn'
  const hasAnyBadTransport = [sseStatus, grpcStatus, wsStatus, webrtcStatus, h2Status, clusterStatus].includes('bad')
  const clusterEyebrow = data.cluster.topology_available
    ? `${formatMetricValue(data.cluster.live_agents)} live`
    : data.cluster.topology_source
  const managedUnitsSub = data.cluster.topology_available
    ? `${formatMetricValue(data.cluster.total_units)} 전체`
    : `topology ${data.cluster.topology_source}`
  const namespaceChip =
    data.cluster.cluster && data.cluster.cluster !== 'unknown' && data.cluster.cluster !== 'default'
      ? `${data.cluster.cluster} / namespace ${data.cluster.room_id}`
      : `namespace ${data.cluster.room_id}`
  const truthLine = transportTruthLine(data)

  return html`
    <div class="space-y-4">
      <div class="flex items-start justify-between gap-4">
        <div>
          <div class="flex items-center gap-2">
            <span class="text-base text-text-strong">트랜스포트</span>
            <span class="text-[10px] uppercase tracking-wider text-text-muted">${namespaceChip}</span>
          </div>
          <div class="mt-1 text-sm text-text-body">
            primary path: <span class="font-mono text-text-strong">${data.summary.primary_path}</span>
            <span class=${`ml-2 text-[11px] uppercase tracking-wider ${toneClass(sseStatus)}`}>${data.summary.queue_pressure}</span>
          </div>
          ${truthLine
            ? html`<div class="mt-1 text-[11px] text-text-muted">${truthLine}</div>`
            : null}
        </div>
        <button
          class="text-[10px] text-text-muted hover:text-text-body transition-colors"
          onClick=${() => void refreshTransportHealth()}
        >새로고침</button>
      </div>

      <details class="group rounded border border-card-border/50 bg-card/18 overflow-hidden" open=${hasAnyBadTransport}>
        <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer text-[13px] font-semibold text-text-strong bg-card/28 hover:bg-card/44 transition-colors">
          <span>트랜스포트 상세</span>
          <span class="ml-auto flex items-center gap-2 text-[11px] font-normal text-text-muted">
            <span class="inline-flex items-center gap-1"><${StatusDot} size="xs" class=${statusDot(sseStatus)} />SSE</span>
            <span class="inline-flex items-center gap-1"><${StatusDot} size="xs" class=${statusDot(grpcStatus)} />gRPC</span>
            <span class="inline-flex items-center gap-1"><${StatusDot} size="xs" class=${statusDot(wsStatus)} />WS</span>
            <span class="inline-flex items-center gap-1"><${StatusDot} size="xs" class=${statusDot(webrtcStatus)} />RTC</span>
            <span class="inline-flex items-center gap-1"><${StatusDot} size="xs" class=${statusDot(h2Status)} />HTTP</span>
          </span>
        </summary>
        <div class="p-4">
          <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
            <${SectionCard} title="SSE" status=${sseStatus} eyebrow=${`${data.sse.sessions_total} live`}>
              <${MetricRow} label="Observer" value=${data.sse.sessions_observer} />
              <${MetricRow} label="Coordinator" value=${data.sse.sessions_coordinator} />
              <${MetricRow} label="External Fanout" value=${data.sse.external_subscribers} />
              <${MetricRow} label="Queue" value=${data.sse.queue_max_depth} sub=${`max / avg ${formatFloat(data.sse.queue_avg_depth)}`} />
              <${MetricRow} label="Relay Queue" value=${data.sse.relay_queue_depth} />
              <${MetricRow} label="Relay Retries" value=${data.sse.relay_retry_total} sub=${`append ${data.sse.relay_retry_append} · broadcast ${data.sse.relay_retry_broadcast}`} />
              <${MetricRow} label="Relay Drops" value=${data.sse.relay_drop_total} sub=${`queue ${data.sse.relay_drop_queue} · append ${data.sse.relay_drop_append} · broadcast ${data.sse.relay_drop_broadcast}`} />
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
              <${MetricRow} label="리스너" value=${data.websocket.listening ? 'live' : 'down'} />
              <${MetricRow} label="세션" value=${data.websocket.sessions} />
              <${MetricRow} label="모드" value=${data.websocket.mode} />
              <${MetricRow} label="릴레이 소스" value=${data.websocket.relay_source} />
            <//>

            <${SectionCard} title="WebRTC" status=${webrtcStatus} eyebrow=${webrtcEyebrow(data)}>
              <${MetricRow} label="시그널링" value=${data.webrtc.signaling_available ? 'ready' : 'down'} sub=${data.webrtc.signaling_mode} />
              <${MetricRow} label="연결된 채널" value=${data.webrtc.connected_channels} />
              <${MetricRow} label="활성 피어" value=${data.webrtc.active_peers} />
              <${MetricRow} label="대기 오퍼" value=${data.webrtc.pending_offers} />
              <${MetricRow} label="라이브 연결" value=${data.webrtc.live_connections} />
            <//>

            <${SectionCard} title="HTTP" status=${h2Status} eyebrow=${data.http2.listener_mode}>
              <${MetricRow} label="POST" value=${data.streamable_http.endpoint} />
              <${MetricRow} label="옵저버 스트림" value=${data.streamable_http.observer_stream} />
              <${MetricRow} label="오퍼레이터 표면" value=${data.streamable_http.operator_endpoint} />
              <${MetricRow} label="레거시" value=${data.streamable_http.legacy_sse_endpoint} sub=${'deprecated'} />
            <//>

            <${SectionCard} title="에이전트 풀" status=${clusterStatus} eyebrow=${clusterEyebrow}>
              <div class="text-[10px] text-text-muted mb-2">클러스터 내 관리 유닛 풀. 부실(stale) = 하트비트가 끊긴 에이전트.</div>
              <${MetricRow} label="관리 유닛" value=${formatMetricValue(data.cluster.managed_units)} sub=${managedUnitsSub} />
              <${MetricRow} label="활성 작업" value=${formatMetricValue(data.cluster.active_operations)} />
              <${MetricRow} label="부실 유닛" value=${formatMetricValue(data.cluster.stale_units)} />
              <${MetricRow} label="부실 에이전트" value=${data.agent_health.stale_total} />
              <${MetricRow} label="Lifecycle Rejects" value=${data.agent_health.lifecycle_dispatch_rejections_total} />
            <//>
          </div>
        </div>
      </details>

      ${data.sse.hot_sessions.length > 0
        ? (() => {
            const query = hotSessionsSearchQuery.value
            const filtered = filterHotSessions(data.sse.hot_sessions, query)
            const isFiltered = query.trim() !== ''
            return html`
            <details class="group rounded border border-card-border/50 bg-card/18 overflow-hidden" open=${data.sse.hot_sessions.length >= 3}>
              <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer text-[13px] font-semibold text-text-strong bg-card/28 hover:bg-card/44 transition-colors">
                <span>핫 큐</span>
                <span class="ml-auto text-[11px] font-normal text-text-muted">${data.sse.hot_sessions.length}개 세션 -- SSE 백프레셔 위험</span>
              </summary>
              <div class="p-4">
                <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
                  <div class="text-[11px] text-text-muted">SSE 세션 중 메시지 큐가 쌓여 있는 세션입니다. 큐 depth가 높으면 해당 클라이언트가 이벤트 처리를 따라가지 못하고 있습니다.</div>
                  <${TextInput}
                    type="search"
                    class="min-w-[180px] flex-1 !py-1 !text-[11px]"
                    name="hot_sessions_search"
                    ariaLabel="핫 세션 검색 (session id, kind, last event id)"
                    autoComplete="off"
                    placeholder="검색 (id / kind / last event)"
                    value=${query}
                    onInput=${(e: Event) => {
                      hotSessionsSearchQuery.value = (e.target as HTMLInputElement).value
                    }}
                  />
                </div>
                ${isFiltered ? html`
                  <div class="mb-2 text-[11px] text-text-muted">${filtered.length} / ${data.sse.hot_sessions.length}개 세션</div>
                ` : null}
                ${filtered.length === 0 ? html`
                  <div class="text-[11px] text-text-muted py-3">검색 결과 없음</div>
                ` : html`
                  <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
                    ${filtered.map((session) => html`
                      <div key=${session.session_id} class="rounded border border-card-border/60 bg-bg-1/60 p-3">
                        <div class="flex items-center justify-between gap-2 mb-1">
                          <div class="flex min-w-0 items-center gap-1">
                            <span class="truncate text-[11px] font-mono text-text-strong">${compactId(session.session_id)}</span>
                            <${CopyIdButton} value=${session.session_id} label="session_id" />
                          </div>
                          <span class="text-[10px] uppercase tracking-wider text-text-muted">${session.kind}</span>
                        </div>
                        <div class="text-[11px] text-text-body">queue ${session.queue_depth}</div>
                        <div class="text-[10px] text-text-muted mt-1">idle ${formatIdle(session.idle_seconds)} · last ${session.last_event_id}</div>
                      </div>
                    `)}
                  </div>
                `}
              </div>
            </details>
          `
          })()
        : null}

      <details class="group rounded border border-card-border/50 bg-card/18 overflow-hidden">
        <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer text-[13px] font-semibold text-text-strong bg-card/28 hover:bg-card/44 transition-colors">
          <span>실용 경로</span>
          <span class="ml-auto text-[11px] font-normal text-text-muted">각 트랜스포트의 실제 연결 방법 레퍼런스</span>
        </summary>
        <div class="p-4">
          <div class="text-[11px] text-text-muted mb-3">5가지 트랜스포트(SSE, gRPC, WebSocket, WebRTC, HTTP)를 실제로 어떻게 연결하는지 보여주는 가이드입니다. 운영 데이터가 아닌 참조용 정보입니다.</div>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
            ${PRACTICAL_CASES.map((item) => html`<${CaseCard} item=${item} data=${data} />`)}
          </div>
        </div>
      </details>
    </div>
  `
}

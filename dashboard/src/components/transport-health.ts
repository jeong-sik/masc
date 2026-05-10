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
import { ActionButton } from './common/button'
import { StatTile } from './common/stat-tile'
import { SectionCard } from './common/card'

export type StatusTone = 'ok' | 'warn' | 'bad'

function toneToStatus(tone: StatusTone): 'ok' | 'warn' | 'crit' {
  return tone === 'bad' ? 'crit' : tone
}

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

export function shouldRefreshFromEvent(event: SSEEvent): boolean {
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

export function formatLatency(seconds: number): string {
  if (seconds === 0) return '-'
  if (seconds < 0.001) return `${(seconds * 1_000_000).toFixed(0)}us`
  if (seconds < 1) return `${(seconds * 1000).toFixed(1)}ms`
  return `${seconds.toFixed(2)}s`
}

export function formatFloat(value: number): string {
  if (value === 0) return '0'
  if (value < 1) return value.toFixed(2)
  return value.toFixed(1)
}

export function formatIdle(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  return `${Math.round(seconds / 3600)}h`
}

export function compactId(value: string): string {
  if (value.length <= 18) return value
  return `${value.slice(0, 8)}...${value.slice(-6)}`
}

// Hit ratio formatter: returns "—" when the cache has seen no traffic
// (hits + misses = 0).  Rendering "0% (0/0)" would look like a failure
// mode when it actually means "nothing has happened yet".
export function formatHitRate(hits: number, misses: number): string {
  const total = hits + misses
  if (total <= 0) return '—'
  const pct = Math.round((hits * 100) / total)
  return `${pct}%`
}

// Average bytes per ack from histogram sum + count.  Histogram backend
// accumulates a sum; dividing by the auto-created _count gives the
// mean.  Guard against zero count to avoid NaN.
export function formatAvgBufferedBytes(sum: number, count: number): string {
  if (count <= 0) return '—'
  const avg = sum / count
  if (avg < 1024) return `${Math.round(avg)} B`
  if (avg < 1024 * 1024) return `${(avg / 1024).toFixed(1)} KB`
  return `${(avg / (1024 * 1024)).toFixed(2)} MB`
}

export function statusDot(status: StatusTone): string {
  if (status === 'ok') return 'bg-[var(--color-status-ok)]'
  if (status === 'warn') return 'bg-[var(--color-status-warn)]'
  return 'bg-[var(--color-status-err)]'
}

export function toneClass(status: StatusTone): string {
  if (status === 'ok') return 'text-[var(--color-status-ok)]'
  if (status === 'warn') return 'text-[var(--color-status-warn)]'
  return 'text-[var(--color-status-err)]'
}

export function queuePressureTone(pressure: string): StatusTone {
  if (pressure === 'high') return 'bad'
  if (pressure === 'watch') return 'warn'
  return 'ok'
}

export function sseTone(data: TransportHealthData): StatusTone {
  if (data.sse.relay_drop_total > 0) return 'bad'
  if (data.sse.relay_retry_total > 0 || data.sse.relay_queue_depth > 0) return 'warn'
  return queuePressureTone(data.summary.queue_pressure)
}

export function transportTone(configured: boolean, listening: boolean, active: boolean): StatusTone {
  if (!configured) return 'warn'
  if (!listening) return 'bad'
  return active ? 'ok' : 'warn'
}

export function grpcTone(data: TransportHealthData): StatusTone {
  const base = transportTone(
    data.grpc.configured,
    data.grpc.listening,
    data.grpc.subscribers > 0 || data.grpc.active_streams > 0,
  )
  // Subscriber capacity pressure (buffer-full drops) is worth an
  // operator nudge but does not downgrade a ['bad'] base — a dead
  // listener stays dead, drops on top are downstream of that.
  if (base === 'ok' && data.grpc.events_dropped > 0) {
    return 'warn'
  }
  return base
}

export function websocketTone(data: TransportHealthData): StatusTone {
  const base = transportTone(
    data.websocket.configured,
    data.websocket.listening,
    data.websocket.sessions > 0,
  )
  // A healthy transport that has tripped the backpressure circuit at
  // least once is not in the 'bad' state — WS is still carrying
  // traffic — but the operator should notice.  Degrade 'ok' to 'warn'
  // and leave an already-bad state alone.
  if (base === 'ok' && data.websocket.delivery.throttled_deliveries > 0) {
    return 'warn'
  }
  return base
}

export function webrtcActive(data: TransportHealthData): boolean {
  return data.webrtc.connected_channels > 0
    || data.webrtc.live_connections > 0
    || data.webrtc.active_peers > 0
}

export function webrtcTone(data: TransportHealthData): StatusTone {
  return transportTone(
    data.webrtc.configured,
    data.webrtc.signaling_available,
    webrtcActive(data),
  )
}

export function http2Tone(data: TransportHealthData): StatusTone {
  return data.http2.multiplex_ready ? 'ok' : 'warn'
}

export function staleTone(staleTotal: number): StatusTone {
  if (staleTotal === 0) return 'ok'
  if (staleTotal < 3) return 'warn'
  return 'bad'
}

export function agentPoolTone(data: TransportHealthData): StatusTone {
  const staleStatus = staleTone(data.agent_health.stale_total)
  if (staleStatus !== 'ok') return staleStatus
  return data.agent_health.lifecycle_dispatch_rejections_total > 0 ? 'warn' : 'ok'
}

export function formatMetricValue(value: number | null): string | number {
  return value === null ? 'n/a' : value
}

export function transportTruthLine(data: TransportHealthData): string | null {
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
        ${sub ? html`<span class="text-3xs text-text-muted truncate">${sub}</span>` : null}
      </div>
    </div>
  `
}

export function transportEyebrow(configured: boolean, listening: boolean, port: number): string {
  if (!configured) return '비활성'
  return listening ? `:${port} 활성` : `:${port} 중단`
}

export function webrtcEyebrow(data: TransportHealthData): string {
  if (!data.webrtc.configured) return '비활성'
  return data.webrtc.signaling_available
    ? `${data.webrtc.ice_server_count} ICE · 시그널링 준비`
    : '시그널링 중단'
}

function TransportStatusBadge({ status, label }: { status: StatusTone; label: string }) {
  return html`<span class="inline-flex items-center gap-1"><${StatusDot} size="xs" class=${statusDot(status)} />${label}</span>`
}

function CaseCard({ item, data }: { item: PracticalCase; data: TransportHealthData }) {
  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/70 bg-card/40 p-4">
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="text-sm font-semibold text-text-strong">${item.title}</div>
        <div class="text-3xs uppercase tracking-wider text-text-muted">${item.transport}</div>
      </div>
      <div class="text-2xs text-text-muted mb-2 font-mono break-all">${item.endpoint(data)}</div>
      <div class="text-xs text-text-body leading-relaxed">${item.description}</div>
      <div class="mt-3 text-2xs text-[var(--color-accent-fg)]">${item.live(data)}</div>
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
    return html`<div class="p-6 text-center text-text-muted text-sm" role="status">트랜스포트 상태 로딩 중...</div>`
  }

  if (error && !data) {
    return html`<div class="p-6 text-center text-[var(--color-status-err)] text-sm" role="alert">${error}</div>`
  }

  if (!data) return null
  if (!data.summary || !data.agent_health) {
    return html`<div class="p-6 text-center text-text-muted text-sm">트랜스포트 데이터 불완전. <${ActionButton} variant="subtle" size="sm" class="underline" onClick=${() => void refreshTransportHealth()}>재시도<//></div>`
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
            <span class="text-3xs uppercase tracking-wider text-text-muted">${namespaceChip}</span>
          </div>
          <div class="mt-1 text-sm text-text-body">
            primary path: <span class="font-mono text-text-strong">${data.summary.primary_path}</span>
            <span class=${`ml-2 text-2xs uppercase tracking-wider ${toneClass(sseStatus)}`}>${data.summary.queue_pressure}</span>
          </div>
          ${truthLine
            ? html`<div class="mt-1 text-2xs text-text-muted">${truthLine}</div>`
            : null}
        </div>
        <${ActionButton}
          variant="subtle"
          size="sm"
          class="text-3xs"
          onClick=${() => void refreshTransportHealth()}
        >새로고침<//>
      </div>

      <div class="grid grid-cols-4 gap-3 max-[880px]:grid-cols-2">
        <${StatTile}
          label="SSE 세션"
          value=${String(data.sse.sessions_total)}
          status=${toneToStatus(sseStatus)}
          delta=${sseStatus !== 'ok' ? { direction: sseStatus === 'bad' ? 'down' : 'flat', text: sseStatus === 'bad' ? '이상' : '주의' } : undefined}
        />
        <${StatTile}
          label="큐 압력"
          value=${data.summary.queue_pressure.toUpperCase()}
          status=${toneToStatus(queuePressureTone(data.summary.queue_pressure))}
        />
        <${StatTile}
          label="최근 메시지"
          value=${formatMetricValue(data.summary.recent_messages)}
          status="brass"
        />
        <${StatTile}
          label="Live 에이전트"
          value=${formatMetricValue(data.cluster.live_agents)}
          status=${toneToStatus(clusterStatus)}
          delta=${data.cluster.active_operations ? { direction: 'flat', text: `${formatMetricValue(data.cluster.active_operations)} ops` } : undefined}
        />
      </div>

      <details class="group rounded-[var(--r-1)] border border-card-border/50 bg-card/18 overflow-hidden" open=${hasAnyBadTransport}>
        <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer text-sm font-semibold text-text-strong bg-card/28 hover:bg-card/44 transition-colors">
          <span>트랜스포트 상세</span>
          <span class="ml-auto flex items-center gap-2 text-2xs font-normal text-text-muted">
            <${TransportStatusBadge} status=${sseStatus} label="SSE" />
            <${TransportStatusBadge} status=${grpcStatus} label="gRPC" />
            <${TransportStatusBadge} status=${wsStatus} label="WS" />
            <${TransportStatusBadge} status=${webrtcStatus} label="RTC" />
            <${TransportStatusBadge} status=${h2Status} label="HTTP" />
          </span>
        </summary>
        <div class="p-4">
          <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
            <${SectionCard} title="SSE" status=${sseStatus} eyebrow=${`${data.sse.sessions_total} 활성`}>
              <div class="divide-y divide-card-border/50">
                <${MetricRow} label="옵저버" value=${data.sse.sessions_observer} />
                <${MetricRow} label="코디네이터" value=${data.sse.sessions_coordinator} />
                <${MetricRow} label="프레즌스" value=${data.sse.sessions_presence} />
                <${MetricRow} label="외부 팬아웃" value=${data.sse.external_subscribers} />
                <${MetricRow} label="큐" value=${data.sse.queue_max_depth} sub=${`최대 / 평균 ${formatFloat(data.sse.queue_avg_depth)}`} />
                <${MetricRow} label="릴레이 큐" value=${data.sse.relay_queue_depth} />
                <${MetricRow} label="릴레이 재시도" value=${data.sse.relay_retry_total} sub=${`append ${data.sse.relay_retry_append} · broadcast ${data.sse.relay_retry_broadcast}`} />
                <${MetricRow} label="릴레이 드롭" value=${data.sse.relay_drop_total} sub=${`queue ${data.sse.relay_drop_queue} · append ${data.sse.relay_drop_append} · broadcast ${data.sse.relay_drop_broadcast}`} />
                <${MetricRow} label="브로드캐스트 평균" value=${formatLatency(data.sse.broadcast_avg_seconds)} sub=${`${data.sse.broadcast_count}개 이벤트`} />
              </div>
            <//>

            <${SectionCard} title="gRPC" status=${grpcStatus} eyebrow=${transportEyebrow(data.grpc.configured, data.grpc.listening, data.grpc.port)}>
              <div class="divide-y divide-card-border/50">
                <${MetricRow} label="리스너" value=${data.grpc.listening ? '활성' : '중단'} />
                <${MetricRow} label="구독자" value=${data.grpc.subscribers} />
                <${MetricRow} label="활성 스트림" value=${data.grpc.active_streams} />
                <${MetricRow} label="하트비트 평균" value=${formatLatency(data.grpc.heartbeat_avg_seconds)} />
                <${MetricRow} label="전달된 이벤트" value=${data.grpc.events_delivered} />
                <${MetricRow}
                  label="드롭된 이벤트"
                  value=${data.grpc.events_dropped}
                  sub=${data.grpc.events_dropped > 0 ? '버퍼 포화' : '정상'}
                />
              </div>
            <//>

            <${SectionCard} title="WebSocket" status=${wsStatus} eyebrow=${transportEyebrow(data.websocket.configured, data.websocket.listening, data.websocket.port)}>
              <div class="divide-y divide-card-border/50">
                <${MetricRow} label="리스너" value=${data.websocket.listening ? 'live' : 'down'} />
                <${MetricRow} label="세션" value=${data.websocket.sessions} />
                <${MetricRow} label="모드" value=${data.websocket.mode} />
                <${MetricRow} label="릴레이 소스" value=${data.websocket.relay_source} />
                <${MetricRow}
                  label="파싱 캐시"
                  value=${formatHitRate(data.websocket.delivery.parse_cache_hits, data.websocket.delivery.parse_cache_misses)}
                  sub=${`${data.websocket.delivery.parse_cache_hits} 히트 / ${data.websocket.delivery.parse_cache_misses} 미스`}
                />
                <${MetricRow}
                  label="바이트 캐시"
                  value=${formatHitRate(data.websocket.delivery.bytes_cache_hits, data.websocket.delivery.bytes_cache_misses)}
                  sub=${`${data.websocket.delivery.bytes_cache_hits} 히트 / ${data.websocket.delivery.bytes_cache_misses} 미스`}
                />
                <${MetricRow}
                  label="클라이언트 드레인"
                  value=${formatAvgBufferedBytes(data.websocket.delivery.client_buffered_bytes_sum, data.websocket.delivery.client_buffered_bytes_count)}
                  sub=${`${data.websocket.delivery.client_acks} ack`}
                />
                <${MetricRow}
                  label="억제된 전달"
                  value=${data.websocket.delivery.throttled_deliveries}
                  sub=${data.websocket.delivery.throttled_deliveries > 0 ? '서킷 오픈' : '정상'}
                />
              </div>
            <//>

            <${SectionCard} title="WebRTC" status=${webrtcStatus} eyebrow=${webrtcEyebrow(data)}>
              <div class="divide-y divide-card-border/50">
                <${MetricRow} label="시그널링" value=${data.webrtc.signaling_available ? 'ready' : 'down'} sub=${data.webrtc.signaling_mode} />
                <${MetricRow} label="연결된 채널" value=${data.webrtc.connected_channels} />
                <${MetricRow} label="활성 피어" value=${data.webrtc.active_peers} />
                <${MetricRow} label="대기 오퍼" value=${data.webrtc.pending_offers} />
                <${MetricRow} label="라이브 연결" value=${data.webrtc.live_connections} />
              </div>
            <//>

            <${SectionCard} title="HTTP" status=${h2Status} eyebrow=${data.http2.listener_mode}>
              <div class="divide-y divide-card-border/50">
                <${MetricRow} label="POST" value=${data.streamable_http.endpoint} />
                <${MetricRow} label="옵저버 스트림" value=${data.streamable_http.observer_stream} />
                <${MetricRow} label="프레즌스 스트림" value=${data.streamable_http.presence_stream} />
                <${MetricRow} label="오퍼레이터 표면" value=${data.streamable_http.operator_endpoint} />
                <${MetricRow} label="레거시" value=${data.streamable_http.legacy_sse_endpoint} sub=${'deprecated'} />
              </div>
            <//>

            <${SectionCard} title="에이전트 풀" status=${clusterStatus} eyebrow=${clusterEyebrow}>
              <div class="divide-y divide-card-border/50">
                <div class="text-3xs text-text-muted mb-2">클러스터 내 관리 유닛 풀. 부실(stale) = 하트비트가 끊긴 에이전트.</div>
                <${MetricRow} label="관리 유닛" value=${formatMetricValue(data.cluster.managed_units)} sub=${managedUnitsSub} />
                <${MetricRow} label="활성 작업" value=${formatMetricValue(data.cluster.active_operations)} />
                <${MetricRow} label="부실 유닛" value=${formatMetricValue(data.cluster.stale_units)} />
                <${MetricRow} label="부실 에이전트" value=${data.agent_health.stale_total} />
                <${MetricRow} label="라이프사이클 거부" value=${data.agent_health.lifecycle_dispatch_rejections_total} />
              </div>
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
            <details class="group rounded-[var(--r-1)] border border-card-border/50 bg-card/18 overflow-hidden" open=${data.sse.hot_sessions.length >= 3}>
              <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer text-sm font-semibold text-text-strong bg-card/28 hover:bg-card/44 transition-colors">
                <span>핫 큐</span>
                <span class="ml-auto text-2xs font-normal text-text-muted">${data.sse.hot_sessions.length}개 세션 -- SSE 백프레셔 위험</span>
              </summary>
              <div class="p-4">
                <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
                  <div class="text-2xs text-text-muted">SSE 세션 중 메시지 큐가 쌓여 있는 세션입니다. 큐 depth가 높으면 해당 클라이언트가 이벤트 처리를 따라가지 못하고 있습니다.</div>
                  <${TextInput}
                    type="search"
                    class="min-w-45 flex-1 !py-1 !text-2xs"
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
                  <div class="mb-2 text-2xs text-text-muted">${filtered.length} / ${data.sse.hot_sessions.length}개 세션</div>
                ` : null}
                ${filtered.length === 0 ? html`
                  <div class="text-2xs text-text-muted py-3">검색 결과 없음</div>
                ` : html`
                  <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
                    ${filtered.map((session) => html`
                      <div key=${session.session_id} class="rounded-[var(--r-1)] border border-card-border/60 bg-bg-1/60 p-3">
                        <div class="flex items-center justify-between gap-2 mb-1">
                          <div class="flex min-w-0 items-center gap-1">
                            <span class="truncate text-2xs font-mono text-text-strong">${compactId(session.session_id)}</span>
                            <${CopyIdButton} value=${session.session_id} label="session_id" />
                          </div>
                          <span class="text-3xs uppercase tracking-wider text-text-muted">${session.kind}</span>
                        </div>
                        <div class="text-2xs text-text-body">queue ${session.queue_depth}</div>
                        <div class="text-3xs text-text-muted mt-1">idle ${formatIdle(session.idle_seconds)} · last ${session.last_event_id}</div>
                      </div>
                    `)}
                  </div>
                `}
              </div>
            </details>
          `
          })()
        : null}

      <details class="group rounded-[var(--r-1)] border border-card-border/50 bg-card/18 overflow-hidden">
        <summary class="flex items-center gap-3 px-4 py-3 cursor-pointer text-sm font-semibold text-text-strong bg-card/28 hover:bg-card/44 transition-colors">
          <span>실용 경로</span>
          <span class="ml-auto text-2xs font-normal text-text-muted">각 트랜스포트의 실제 연결 방법 레퍼런스</span>
        </summary>
        <div class="p-4">
          <div class="text-2xs text-text-muted mb-3">5가지 트랜스포트(SSE, gRPC, WebSocket, WebRTC, HTTP)를 실제로 어떻게 연결하는지 보여주는 가이드입니다. 운영 데이터가 아닌 참조용 정보입니다.</div>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
            ${PRACTICAL_CASES.map((item) => html`<${CaseCard} item=${item} data=${data} />`)}
          </div>
        </div>
      </details>
    </div>
  `
}

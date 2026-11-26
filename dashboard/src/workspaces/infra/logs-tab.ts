/**
 * Infra L1 Tab 3: Activity & Logs
 *
 * - Virtualized chronological LOG + EVT timeline (ALL | LOGS | EVENTS + level filters +
 *   K/V detail inspector).
 * - Streamed via acquireViewStream('infra-logs', ...) on /api/v1/dashboard/logs/stream
 *   (automatically pauses on document.hidden via ViewStreamSlot!).
 * - Interleaves Observer SSE EVT frames via subscribeObserverFrames.
 * - Strictly <1,000 DOM even with 1,000+ log entries thanks to VirtualList.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { fetchWithTimeout } from '../../api/core'
import {
  OBSERVER_SSE_INSTANCE_HEADER,
  acquireViewStream,
  apiGet,
  authSession,
  getSingleUserToken,
  isEpochCurrent,
  observerSseInstanceId,
  resolveWorkspaceUrl,
  sessionEpoch,
  subscribeObserverFrames,
  viewStreamPaused,
} from '../../core'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { DEFAULT_GET_TIMEOUT_MS } from '../../config/constants'
import { isRecord } from '../../lib/type-guards'
import { formatTimestampKo } from '../../lib/format-time'
import { OBSERVER_IDLE_TIMEOUT_HEADER } from '../../lib/observer-protocol'
import { readSse } from '../../lib/sse-reader'
import { PopoverMenu, VirtualList } from '../../components/primitives'
import type {
  TimelineEntry,
  TimelineLevel,
  WorkspaceViewProps,
} from './types'

const MAX_TIMELINE_ENTRIES = 1000

type KindFilter = 'ALL' | 'LOGS' | 'EVENTS'
type LevelFilter = 'ALL' | TimelineLevel
type SnapshotState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'ready'; readonly observedAt: number }
  | { readonly kind: 'failed'; readonly message: string }

interface PendingTimeline {
  readonly entries: readonly TimelineEntry[]
  readonly resetLogs: boolean
}

function normalizeLevel(raw: unknown): TimelineLevel {
  const s = typeof raw === 'string' ? raw.toUpperCase() : 'INFO'
  if (s === 'DEBUG' || s === 'WARN' || s === 'ERROR') return s
  return 'INFO'
}

function parseLogEntriesFromPayload(raw: unknown): { reset: boolean; entries: TimelineEntry[] } {
  if (!isRecord(raw) || !Array.isArray(raw.entries)) return { reset: false, entries: [] }
  const reset = raw.reset === true
  const out: TimelineEntry[] = []

  for (const item of raw.entries) {
    if (!item || typeof item !== 'object') continue
    const e = item as Record<string, unknown>
    const seq = typeof e.seq === 'number' ? e.seq : null
    const ts = typeof e.ts === 'string' ? e.ts : new Date().toISOString()
    const parsedMs = Date.parse(ts)
    const tsUnix = Number.isFinite(parsedMs) ? parsedMs / 1000 : Date.now() / 1000
    const details = e.details && typeof e.details === 'object' && !Array.isArray(e.details)
      ? (e.details as Record<string, unknown>)
      : {}
    out.push({
      id: seq === null ? `log:unknown:${ts}:${out.length}` : `log:${seq}`,
      kind: 'LOG',
      seq,
      tsUnix,
      tsDisplay: ts.replace('T', ' ').slice(11, 19),
      level: normalizeLevel(e.level),
      source: typeof e.source === 'string' ? e.source : 'structured',
      module: typeof e.module === 'string' ? e.module : '',
      keeper: typeof e.keeper_name === 'string' && e.keeper_name ? e.keeper_name : null,
      message: typeof e.message === 'string' ? e.message : '',
      details,
    })
  }
  return { reset, entries: out }
}

function levelColor(level: TimelineLevel): string {
  switch (level) {
    case 'ERROR': return 'var(--err-fg)'
    case 'WARN': return 'var(--warn-fg)'
    case 'INFO': return 'var(--info-fg)'
    case 'DEBUG': return 'var(--fg-3)'
  }
}

function mergeTimeline(prev: readonly TimelineEntry[], incoming: readonly TimelineEntry[], resetLogs: boolean): TimelineEntry[] {
  const base = resetLogs ? prev.filter((e) => e.kind !== 'LOG') : [...prev]
  const seen = new Set(base.map((e) => e.id))
  for (const item of incoming) {
    if (!seen.has(item.id)) {
      seen.add(item.id)
      base.push(item)
    }
  }
  base.sort((a, b) => b.tsUnix - a.tsUnix || (b.seq ?? 0) - (a.seq ?? 0))
  return base.slice(0, MAX_TIMELINE_ENTRIES)
}

export function LogsTab(props: WorkspaceViewProps) {
  const epoch = sessionEpoch.value
  return html`<${LogsTimeline} ...${props} key=${epoch} epoch=${epoch} />`
}

function LogsTimeline({ epoch, ...props }: WorkspaceViewProps & { epoch: number }) {
  const [entries, setEntries] = useState<readonly TimelineEntry[]>([])
  const [kindFilter, setKindFilter] = useState<KindFilter>('ALL')
  const [levelFilter, setLevelFilter] = useState<LevelFilter>('ALL')
  const [query, setQuery] = useState('')
  const [selectedEntry, setSelectedEntry] = useState<TimelineEntry | null>(null)
  const [streamStatus, setStreamStatus] = useState<'connecting' | 'live' | 'error'>('connecting')
  const [streamAttempt, setStreamAttempt] = useState(0)
  const [snapshot, setSnapshot] = useState<SnapshotState>({ kind: 'loading' })
  const [pausedByUser, setPausedByUser] = useState(false)
  const [bufferedCount, setBufferedCount] = useState(0)
  const pausedByUserRef = useRef(false)
  pausedByUserRef.current = pausedByUser
  const pendingLiveRef = useRef<PendingTimeline>({ entries: [], resetLogs: false })
  const streamObserved = useRef(false)
  const liveSupported = authSession.value.kind === 'single_user_local'
  const sseInstanceId = liveSupported ? observerSseInstanceId.value : null
  const pausedByVisibility = sseInstanceId !== null && viewStreamPaused.value

  const enqueueLiveEntries = useCallback((incoming: readonly TimelineEntry[], resetLogs: boolean) => {
    if (pausedByUserRef.current) {
      const pending = pendingLiveRef.current
      const entries = mergeTimeline(pending.entries, incoming, resetLogs)
      pendingLiveRef.current = { entries, resetLogs: pending.resetLogs || resetLogs }
      setBufferedCount(entries.length)
      return
    }
    setEntries((prev) => mergeTimeline(prev, incoming, resetLogs))
  }, [])

  const toggleUserPause = useCallback(() => {
    if (pausedByUserRef.current) {
      const flushed = pendingLiveRef.current
      pendingLiveRef.current = { entries: [], resetLogs: false }
      setBufferedCount(0)
      pausedByUserRef.current = false
      setPausedByUser(false)
      if (flushed.resetLogs || flushed.entries.length > 0) {
        setEntries((prev) => mergeTimeline(prev, flushed.entries, flushed.resetLogs))
      }
    } else {
      pausedByUserRef.current = true
      setPausedByUser(true)
    }
  }, [])

  useEffect(() => {
    const controller = new AbortController()
    const { signal } = controller
    void apiGet('/api/v1/dashboard/logs?limit=200', {
      signal,
      decode: (raw) => {
        if (!isRecord(raw) || !Array.isArray(raw.entries)) {
          throw new Error('서버가 로그 목록을 반환하지 않았습니다.')
        }
        return parseLogEntriesFromPayload(raw).entries
      },
    }).then((res) => {
      if (signal.aborted || !isEpochCurrent(epoch) || streamObserved.current) return
      if (res.ok) {
        setSnapshot({ kind: 'ready', observedAt: Date.now() })
        enqueueLiveEntries(res.value, false)
      } else {
        setSnapshot({ kind: 'failed', message: res.error.message })
      }
    })

    // Interleave Observer SSE EVT entries chronologically
    const unsubObserver = subscribeObserverFrames((frame) => {
      if (!isEpochCurrent(epoch)) return
      const nowSec = Date.now() / 1000
      const nowIso = new Date(nowSec * 1000).toISOString()
      const dataObj = frame.data && typeof frame.data === 'object' && !Array.isArray(frame.data)
        ? (frame.data as Record<string, unknown>)
        : { raw: frame.raw }
      const evtEntry: TimelineEntry = {
        id: `evt:${frame.id ?? nowSec}:${frame.event}:${Math.random().toString(36).slice(2, 7)}`,
        kind: 'EVT',
        seq: null,
        tsUnix: nowSec,
        tsDisplay: nowIso.replace('T', ' ').slice(11, 19),
        level: 'INFO',
        source: 'observer_sse',
        module: frame.event,
        keeper: typeof dataObj.keeper === 'string' ? dataObj.keeper : null,
        message: typeof dataObj.summary === 'string'
          ? dataObj.summary
          : typeof dataObj.type === 'string'
            ? dataObj.type
            : frame.event,
        details: dataObj,
      }
      enqueueLiveEntries([evtEntry], false)
    })

    return () => {
      controller.abort()
      unsubObserver()
    }
  }, [epoch, enqueueLiveEntries])

  // Single view-scoped SSE via ViewStreamSlot (auto-pauses on document.hidden!)
  // Waits for observer x-masc-sse-instance-id so zero premature HTTP 400s fire.
  useEffect(() => {
    if (!sseInstanceId) return
    const handle = acquireViewStream('infra-logs', (signal) => {
      if (authSession.peek().kind !== 'single_user_local') return
      setStreamStatus('connecting')
      const streamUrl = resolveWorkspaceUrl('/api/v1/dashboard/logs/stream?limit=200')
      const headers: Record<string, string> = {
        Accept: 'text/event-stream',
        [OBSERVER_SSE_INSTANCE_HEADER]: sseInstanceId,
      }
      const token = getSingleUserToken()
      if (token) headers.Authorization = `Bearer ${token}`
      void (async () => {
        try {
          const res = await fetchWithTimeout(streamUrl, {
            method: 'GET',
            credentials: 'same-origin',
            headers,
            signal,
          }, DEFAULT_GET_TIMEOUT_MS)
          const body = res.body
          if (signal.aborted || !isEpochCurrent(epoch)) {
            void body?.cancel().catch(() => {})
            return
          }
          const timeout = res.headers.get(OBSERVER_IDLE_TIMEOUT_HEADER)
          const idleTimeoutMs = timeout !== null && /^[1-9][0-9]*$/.test(timeout) ? Number(timeout) : NaN
          if (!res.ok || !body
            || !res.headers.get('content-type')?.toLowerCase().startsWith('text/event-stream')
            || res.headers.get(OBSERVER_SSE_INSTANCE_HEADER) !== sseInstanceId
            || !Number.isSafeInteger(idleTimeoutMs) || idleTimeoutMs > 2_147_483_647) {
            void body?.cancel().catch(() => {})
            setStreamStatus('error')
            return
          }
          let receivedInitial = false
          await readSse(body, (_event, data) => {
            if (signal.aborted || !isEpochCurrent(epoch)) return
            const sample = parseLogEntriesFromPayload(JSON.parse(data))
            if (!receivedInitial) {
              if (!sample.reset) throw new Error('The log stream did not send its initial snapshot')
              receivedInitial = true
              streamObserved.current = true
              setStreamStatus('live')
            }
            if (sample.entries.length > 0 || sample.reset) {
              setSnapshot({ kind: 'ready', observedAt: Date.now() })
              enqueueLiveEntries(sample.entries, sample.reset)
            }
          }, { signal, idleTimeoutMs })
        } catch {
          // The previous sample stays available when the stream fails.
        } finally {
          if (!signal.aborted && isEpochCurrent(epoch)) setStreamStatus('error')
        }
      })()
    })

    return () => {
      handle.release()
    }
  }, [sseInstanceId, epoch, streamAttempt, enqueueLiveEntries])

  const live = sseInstanceId !== null && streamStatus === 'live'
  const connecting = sseInstanceId !== null && streamStatus === 'connecting'
  const disconnected = sseInstanceId !== null && streamStatus === 'error'
  const paused = pausedByUser || pausedByVisibility
  const snapshotError = snapshot.kind === 'failed' ? snapshot.message : null
  const sourceLabel = pausedByUser ? `⏸ PAUSED${bufferedCount > 0 ? ` (+${bufferedCount})` : ''}`
    : pausedByVisibility ? '⏸ PAUSED (hidden)'
    : live ? '● LIVE SSE'
    : connecting ? 'CONNECTING'
    : snapshot.kind === 'ready' ? '○ SNAPSHOT'
    : snapshot.kind === 'failed' ? '○ UNAVAILABLE'
    : 'LOADING'

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return entries.filter((item) => {
      if (kindFilter === 'LOGS' && item.kind !== 'LOG') return false
      if (kindFilter === 'EVENTS' && item.kind !== 'EVT') return false
      if (levelFilter !== 'ALL' && item.level !== levelFilter) return false
      if (q) {
        const haystack = `${item.module} ${item.keeper ?? ''} ${item.message}`.toLowerCase()
        if (!haystack.includes(q)) return false
      }
      return true
    })
  }, [entries, kindFilter, levelFilter, query])

  const openInspector = (entry: TimelineEntry) => {
    if (!isEpochCurrent(epoch)) return
    setSelectedEntry(entry)
    props.onInspect({
      title: `${entry.kind} · ${entry.module || entry.source}`,
      subtitle: `${entry.tsDisplay} · ${entry.level}${entry.seq !== null ? ` · #${entry.seq}` : ''}`,
      kind: 'infra_log_entry',
      data: entry,
      render: () => html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          <div class="wka-card" style=${{ fontSize: 'var(--fs-12)' }}>
            <div style=${{ fontWeight: 600, marginBottom: 'var(--sp-1)' }}>${entry.message}</div>
            <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
              source=${entry.source} · module=${entry.module || '없음'} · keeper=${entry.keeper ?? '없음'}
            </div>
          </div>
          <div class="wka-card">
            <h4 style=${{ margin: '0 0 var(--sp-1)', fontSize: 'var(--fs-12)' }}>Structured K/V Details</h4>
            <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap' }}>
              ${JSON.stringify(entry.details, null, 2)}
            </pre>
          </div>
        </div>
      `,
    })
  }

  return html`
    <div class="v2-logs-surface" data-testid="infra-logs-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">6 INFRA · ACTIVITY & LOGS</span>
          <h1>통합 활동 · 로그 타임라인 (LOG + EVT)</h1>
        </div>
        <div class="v2-logs-head-actions">
          <span
            class="mono"
            data-testid="logs-stream-status"
            role="status"
            style=${{
              padding: 'var(--sp-0) var(--sp-2)',
              borderRadius: 'var(--radius-pill)',
              fontSize: 'var(--fs-11)',
              border: `1px solid ${(pausedByUser || pausedByVisibility) ? 'var(--warn-border)' : live ? 'var(--ok-border)' : 'var(--line-2)'}`,
              background: (pausedByUser || pausedByVisibility) ? 'var(--warn-soft)' : live ? 'var(--ok-soft)' : 'var(--bg-2)',
              color: (pausedByUser || pausedByVisibility) ? 'var(--warn-fg)' : live ? 'var(--ok-fg)' : 'var(--fg-2)',
            }}
          >
            ${!paused && (connecting || (!live && snapshot.kind === 'loading')) && html`<${InlineSpinner} /> `}
            ${sourceLabel}
            ${!paused && !live && snapshot.kind === 'ready' && html`
              · <time dateTime=${new Date(snapshot.observedAt).toISOString()} title="마지막 로그 확인">
                ${formatTimestampKo(snapshot.observedAt / 1000)}
              </time>
            `}
          </span>
          ${disconnected && !pausedByVisibility && html`
            <button
              type="button"
              class="btn-ghost"
              data-testid="logs-reconnect-btn"
              aria-label="실시간 로그 스트림 연결이 끊겼습니다. 다시 연결"
              title="실시간 로그 스트림 연결이 끊겼습니다. 클릭하여 다시 연결합니다."
              onClick=${() => {
                setStreamStatus('connecting')
                setStreamAttempt(attempt => attempt + 1)
              }}
            >
              다시 연결
            </button>
          `}
          <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            ${filtered.length} / ${entries.length}
          </span>
        </div>
      </header>

      ${snapshotError && html`<div class="ap-error" role="alert">로그 조회 실패: ${snapshotError}</div>`}

      <section class="v2-logs-panel" style=${{ overflow: 'visible' }}>
        <div
          class="v2-logs-toolbar"
          style=${{ borderTopLeftRadius: 'var(--radius-md)', borderTopRightRadius: 'var(--radius-md)' }}
        >
          <${PopoverMenu}
            triggerLabel=${html`<span>종류: <strong class="mono">${kindFilter}</strong> ▾</span>`}
            triggerTestId="logs-kind-filter"
            popoverTestId="logs-kind-menu"
            ariaLabel=${`타임라인 종류 (${kindFilter})`}
            items=${(['ALL', 'LOGS', 'EVENTS'] as const).map((k) => ({
              id: k,
              label: k,
              active: kindFilter === k,
              testId: `logs-kind-option-${k}`,
              onSelect: () => setKindFilter(k),
            }))}
          />

          <${PopoverMenu}
            triggerLabel=${html`<span>레벨: <strong class="mono">${levelFilter}</strong> ▾</span>`}
            triggerTestId="logs-level-filter"
            popoverTestId="logs-level-menu"
            ariaLabel=${`로그 레벨 필터 (${levelFilter})`}
            items=${(['ALL', 'DEBUG', 'INFO', 'WARN', 'ERROR'] as const).map((lv) => ({
              id: lv,
              label: lv,
              active: levelFilter === lv,
              testId: `logs-level-option-${lv}`,
              onSelect: () => setLevelFilter(lv),
            }))}
          />

          <input
            type="search"
            aria-label="로그 검색"
            placeholder="모듈 / Keeper / 메시지 검색…"
            value=${query}
            onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
            style=${{ flex: '1 1 180px', minWidth: 0, minHeight: 'var(--btn-h, 32px)', fontSize: 'var(--fs-12)', padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />

          <button
            type="button"
            class="btn-ghost"
            data-testid="logs-pause-toggle"
            aria-pressed=${pausedByUser ? 'true' : 'false'}
            onClick=${toggleUserPause}
          >
            ${pausedByUser ? `▶ 재개${bufferedCount > 0 ? ` (+${bufferedCount})` : ''}` : '⏸ 일시정지'}
          </button>

          <button
            type="button"
            class="btn-ghost"
            onClick=${() => {
              pendingLiveRef.current = { entries: [], resetLogs: false }
              setBufferedCount(0)
              setEntries([])
            }}
          >
            버퍼 비우기
          </button>
        </div>

        <div style=${{ overflowX: 'auto', minWidth: 0, borderBottomLeftRadius: 'var(--radius-md)', borderBottomRightRadius: 'var(--radius-md)' }}>
          <div class="v2-logs-table-header mono" aria-hidden="true" style=${{ minWidth: '520px' }}>
            <span>TIME</span>
            <span>KIND</span>
            <span>LEVEL</span>
            <span>MODULE</span>
            <span>MESSAGE</span>
          </div>

          <${VirtualList}
            items=${filtered}
            estimateSize=${34}
            height=${460}
            ariaLabel="통합 로그 및 이벤트 타임라인"
            getItemKey=${(item: TimelineEntry) => item.id}
            empty=${snapshotError ? null : html`
              <div style=${{ padding: 'var(--sp-4)' }} class="dtable-absent">
                ${snapshot.kind === 'loading' ? '로그 불러오는 중…' : '표시할 로그 또는 이벤트가 없습니다.'}
              </div>`}
            renderItem=${(item: TimelineEntry) => {
              const isSel = selectedEntry?.id === item.id
              return html`
                <div
                  class="v2-logs-row v2-logs-line mono"
                  role="button"
                  tabIndex=${0}
                  onClick=${() => openInspector(item)}
                  onKeyDown=${(e: KeyboardEvent) => {
                    if (e.isComposing || e.keyCode === 229) return
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault()
                      openInspector(item)
                    }
                  }}
                  style=${{
                    cursor: 'pointer',
                    background: isSel ? 'var(--bg-4)' : undefined,
                    height: '34px',
                    minWidth: '520px',
                    overflow: 'hidden',
                  }}
                >
                  <span class="tnum" style=${{ color: 'var(--fg-3)' }}>${item.tsDisplay}</span>
                  <span style=${{ color: item.kind === 'EVT' ? 'var(--brass-1)' : 'var(--fg-2)' }}>${item.kind}</span>
                  <span style=${{ color: levelColor(item.level), fontWeight: 600 }}>${item.level}</span>
                  <span style=${{ color: 'var(--fg-2)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    ${item.module || item.keeper || 'system'}
                  </span>
                  <span style=${{ color: 'var(--fg-1)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    ${item.message}
                  </span>
                </div>
              `
            }}
          />
        </div>
      </section>

      ${selectedEntry && html`
        <section class="wka-card" data-testid="logs-kv-inspector" aria-label="선택된 로그 K/V 상세">
          <div class="wka-h">
            <h3>K/V 상세 · ${selectedEntry.kind} ${selectedEntry.module}</h3>
            <button type="button" class="btn-ghost" onClick=${() => setSelectedEntry(null)}>닫기</button>
          </div>
          <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)', marginBottom: 'var(--sp-2)' }}>
            ts=${selectedEntry.tsDisplay} · level=${selectedEntry.level} · source=${selectedEntry.source} · keeper=${selectedEntry.keeper ?? '없음'}
          </div>
          <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', background: 'var(--bg-0)', padding: 'var(--sp-2)', borderRadius: 'var(--radius-sm)' }}>
            ${JSON.stringify(selectedEntry.details, null, 2)}
          </pre>
        </section>
      `}
    </div>
  `
}

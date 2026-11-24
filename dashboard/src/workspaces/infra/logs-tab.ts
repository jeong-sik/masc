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
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  OBSERVER_SSE_INSTANCE_HEADER,
  acquireViewStream,
  apiGet,
  authSession,
  currentSessionEpoch,
  getSingleUserToken,
  isEpochCurrent,
  observerSseInstanceId,
  parseSseBlock,
  resolveWorkspaceUrl,
  subscribeObserverFrames,
  viewStreamPaused,
} from '../../core'
import { VirtualList } from '../../components/primitives'
import type {
  TimelineEntry,
  TimelineLevel,
  WorkspaceViewProps,
} from './types'

const MAX_TIMELINE_ENTRIES = 1000

type KindFilter = 'ALL' | 'LOGS' | 'EVENTS'
type LevelFilter = 'ALL' | TimelineLevel

function normalizeLevel(raw: unknown): TimelineLevel {
  const s = typeof raw === 'string' ? raw.toUpperCase() : 'INFO'
  if (s === 'DEBUG' || s === 'WARN' || s === 'ERROR') return s
  return 'INFO'
}

function parseLogEntriesFromPayload(raw: unknown): { reset: boolean; entries: TimelineEntry[] } {
  if (!raw || typeof raw !== 'object') return { reset: false, entries: [] }
  const rec = raw as Record<string, unknown>
  const reset = rec.reset === true
  const rawEntries = Array.isArray(rec.entries) ? rec.entries : []
  const out: TimelineEntry[] = []

  for (const item of rawEntries) {
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
      id: `log:${seq ?? ts}:${out.length}`,
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
  const [entries, setEntries] = useState<readonly TimelineEntry[]>([])
  const [kindFilter, setKindFilter] = useState<KindFilter>('ALL')
  const [levelFilter, setLevelFilter] = useState<LevelFilter>('ALL')
  const [query, setQuery] = useState('')
  const [selectedEntry, setSelectedEntry] = useState<TimelineEntry | null>(null)
  const [streamStatus, setStreamStatus] = useState<'connecting' | 'live' | 'error'>('connecting')
  const pausedByVisibility = viewStreamPaused.value
  const sseInstanceId = observerSseInstanceId.value

  useEffect(() => {
    // Initial snapshot load so users immediately see logs before SSE frame arrives
    void apiGet<unknown>('/api/v1/dashboard/logs?limit=200').then((res) => {
      if (res.ok) {
        const parsed = parseLogEntriesFromPayload(res.value)
        if (parsed.entries.length > 0) {
          setEntries((prev) => mergeTimeline(prev, parsed.entries, false))
        }
      }
    })

    // Interleave Observer SSE EVT entries chronologically
    const unsubObserver = subscribeObserverFrames((frame) => {
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
      setEntries((prev) => mergeTimeline(prev, [evtEntry], false))
    })

    return () => {
      unsubObserver()
    }
  }, [])

  // Single view-scoped SSE via ViewStreamSlot (auto-pauses on document.hidden!)
  // Waits for observer x-masc-sse-instance-id so zero premature HTTP 400s fire.
  useEffect(() => {
    if (!sseInstanceId) {
      setStreamStatus('connecting')
      return
    }
    const handle = acquireViewStream('infra-logs', (signal) => {
      const startEpoch = currentSessionEpoch()
      const streamUrl = resolveWorkspaceUrl('/api/v1/dashboard/logs/stream?limit=200')
      const headers: Record<string, string> = {
        Accept: 'text/event-stream',
        [OBSERVER_SSE_INSTANCE_HEADER]: sseInstanceId,
      }
      const session = authSession.peek()
      if (session.kind !== 'multi_account_signed_in') {
        const token = getSingleUserToken()
        if (token) headers.Authorization = `Bearer ${token}`
      }
      void (async () => {
        try {
          const res = await fetch(streamUrl, {
            method: 'GET',
            credentials: 'same-origin',
            headers,
            signal,
          })
          if (signal.aborted || !isEpochCurrent(startEpoch)) return
          if (!res.ok || !res.body) {
            setStreamStatus('error')
            return
          }
          setStreamStatus('live')
          const reader = res.body.getReader()
          const decoder = new TextDecoder()
          let buffer = ''
          try {
            while (!signal.aborted && isEpochCurrent(startEpoch)) {
              const { value, done } = await reader.read()
              if (done) break
              if (signal.aborted || !isEpochCurrent(startEpoch)) break
              buffer += decoder.decode(value, { stream: true })
              const blocks = buffer.split(/\r?\n\r?\n/)
              buffer = blocks.pop() ?? ''
              for (const block of blocks) {
                if (signal.aborted || !isEpochCurrent(startEpoch)) return
                const frame = parseSseBlock(block)
                if (!frame) continue
                const parsed = parseLogEntriesFromPayload(frame.data)
                if (parsed.entries.length > 0 || parsed.reset) {
                  setEntries((prev) => mergeTimeline(prev, parsed.entries, parsed.reset))
                }
              }
            }
          } finally {
            reader.releaseLock()
          }
        } catch {
          if (!signal.aborted && isEpochCurrent(startEpoch)) setStreamStatus('error')
        }
      })()
    })

    return () => {
      handle.release()
    }
  }, [sseInstanceId])

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
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}>
          <span
            class="mono"
            data-testid="logs-stream-status"
            style=${{
              padding: 'var(--sp-0) var(--sp-2)',
              borderRadius: 'var(--radius-pill)',
              fontSize: 'var(--fs-11)',
              border: `1px solid ${pausedByVisibility ? 'var(--warn-border)' : streamStatus === 'live' ? 'var(--ok-border)' : 'var(--line-2)'}`,
              background: pausedByVisibility ? 'var(--warn-soft)' : streamStatus === 'live' ? 'var(--ok-soft)' : 'var(--bg-2)',
              color: pausedByVisibility ? 'var(--warn-fg)' : streamStatus === 'live' ? 'var(--ok-fg)' : 'var(--fg-2)',
            }}
          >
            ${pausedByVisibility ? '⏸ PAUSED (hidden)' : streamStatus === 'live' ? '● LIVE SSE' : streamStatus === 'error' ? '○ SNAPSHOT' : '◐ CONNECTING'}
          </span>
          <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            ${filtered.length} / ${entries.length}
          </span>
        </div>
      </header>

      <section class="v2-logs-panel">
        <div class="v2-logs-toolbar">
          <div class="ap-viewseg" role="group" aria-label="타임라인 종류">
            ${(['ALL', 'LOGS', 'EVENTS'] as const).map((k) => html`
              <button
                key=${k}
                type="button"
                class=${`ap-viewbtn ${kindFilter === k ? 'on' : ''}`}
                onClick=${() => setKindFilter(k)}
              >
                ${k}
              </button>
            `)}
          </div>

          <div class="ap-viewseg" role="group" aria-label="로그 레벨 필터">
            ${(['ALL', 'DEBUG', 'INFO', 'WARN', 'ERROR'] as const).map((lv) => html`
              <button
                key=${lv}
                type="button"
                class=${`ap-viewbtn ${levelFilter === lv ? 'on' : ''}`}
                onClick=${() => setLevelFilter(lv)}
              >
                ${lv}
              </button>
            `)}
          </div>

          <input
            type="search"
            aria-label="로그 검색"
            placeholder="모듈 / Keeper / 메시지 검색…"
            value=${query}
            onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
            style=${{ flex: '1 1 180px', minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />

          <button type="button" class="btn-ghost" onClick=${() => setEntries([])}>버퍼 비우기</button>
        </div>

        <div style=${{ overflowX: 'auto', minWidth: 0 }}>
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
            empty=${html`<div style=${{ padding: 'var(--sp-4)' }} class="dtable-absent">표시할 로그 또는 이벤트가 없습니다.</div>`}
            renderItem=${(item: TimelineEntry) => {
              const isSel = selectedEntry?.id === item.id
              return html`
                <div
                  class="v2-logs-row v2-logs-line mono"
                  role="button"
                  tabIndex=${0}
                  onClick=${() => openInspector(item)}
                  onKeyDown=${(e: KeyboardEvent) => {
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

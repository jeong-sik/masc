// EventStream — AX molecule for real-time event log visualization.
//
// Kimi design system sec02 reference: 2.1.3 agent log stream with level-based
// color coding and live append semantics.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

export interface StreamEvent {
  id: string
  timestamp: number
  level: 'info' | 'warn' | 'error'
  message: string
  source?: string
}

export type EventStreamStatus = 'empty' | 'ok' | 'warning' | 'error'
export type EventStreamAttractionBand = 'high' | 'medium' | 'low'

export interface EventStreamSummary {
  totalCount: number
  visibleCount: number
  hiddenCount: number
  infoCount: number
  warnCount: number
  errorCount: number
  latestTimestamp: number | null
  oldestVisibleTimestamp: number | null
  temporalSyncGroupCount: number
  maxTemporalSyncGroupSize: number
  highAttractionCount: number
  maxAttractionScore: number
  status: EventStreamStatus
}

export interface TemporalSyncStreamRow {
  event: StreamEvent
  syncGroupId: string
  syncGroupSize: number
  syncAnchorTimestamp: number | null
}

interface EventStreamProps {
  events: StreamEvent[]
  maxItems?: number
  temporalSyncWindowMs?: number
  testId?: string
}

function levelColor(level: string): string {
  return level === 'error'
    ? 'var(--color-status-err)'
    : level === 'warn'
      ? 'var(--color-status-warn)'
      : 'var(--color-status-info)'
}

function levelLabel(level: string): string {
  return level === 'error' ? '에러' : level === 'warn' ? '경고' : '정보'
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return '--:--:--'
  return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}:${d.getSeconds().toString().padStart(2, '0')}`
}

function formatDateTime(ts: number): string | undefined {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return undefined
  return d.toISOString()
}

export function getVisibleStreamEvents(events: StreamEvent[], maxItems: number): StreamEvent[] {
  const itemLimit = Number.isFinite(maxItems) ? Math.max(0, Math.floor(maxItems)) : 0
  if (itemLimit === 0) return []
  return events.slice(-itemLimit).reverse()
}

function finiteTimestamp(value: number): number | null {
  return Number.isFinite(value) ? value : null
}

function normalizedSyncWindowMs(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value))
}

function roundedScore(value: number): number {
  return Math.round(value * 100) / 100
}

function levelAttraction(level: StreamEvent['level']): number {
  switch (level) {
    case 'error':
      return 1
    case 'warn':
      return 0.7
    case 'info':
      return 0.45
  }
}

export function streamEventAttractionScore(
  row: TemporalSyncStreamRow,
  visibleIndex: number,
  visibleCount: number,
): number {
  const recency = visibleCount <= 1 ? 1 : 1 - (visibleIndex / Math.max(1, visibleCount - 1))
  const syncBonus = row.syncGroupSize > 1 ? 0.1 : 0
  return roundedScore(clamp01((levelAttraction(row.event.level) * 0.7) + (recency * 0.2) + syncBonus))
}

export function streamEventAttractionBand(score: number): EventStreamAttractionBand {
  if (score >= 0.8) return 'high'
  if (score >= 0.55) return 'medium'
  return 'low'
}

export function buildTemporalSyncRows(
  events: StreamEvent[],
  temporalSyncWindowMs: number,
): TemporalSyncStreamRow[] {
  const windowMs = normalizedSyncWindowMs(temporalSyncWindowMs)
  const rows: TemporalSyncStreamRow[] = []
  let pending: StreamEvent[] = []
  let anchorTimestamp: number | null = null
  let groupIndex = 0

  const flush = () => {
    if (pending.length === 0) return
    const syncGroupId = `sync-${groupIndex}`
    const syncGroupSize = pending.length
    for (const event of pending) {
      rows.push({
        event,
        syncGroupId,
        syncGroupSize,
        syncAnchorTimestamp: anchorTimestamp,
      })
    }
    groupIndex += 1
    pending = []
    anchorTimestamp = null
  }

  for (const event of events) {
    const eventTimestamp = finiteTimestamp(event.timestamp)
    const canJoin =
      pending.length > 0
      && anchorTimestamp != null
      && eventTimestamp != null
      && Math.abs(anchorTimestamp - eventTimestamp) <= windowMs

    if (pending.length === 0 || canJoin) {
      pending.push(event)
      if (anchorTimestamp == null) anchorTimestamp = eventTimestamp
      continue
    }

    flush()
    pending.push(event)
    anchorTimestamp = eventTimestamp
  }

  flush()
  return rows
}

export function summarizeEventStream(
  events: StreamEvent[],
  maxItems: number,
  temporalSyncWindowMs = 5000,
): EventStreamSummary {
  const visible = getVisibleStreamEvents(events, maxItems)
  const syncRows = buildTemporalSyncRows(visible, temporalSyncWindowMs)
  const infoCount = visible.filter(e => e.level === 'info').length
  const warnCount = visible.filter(e => e.level === 'warn').length
  const errorCount = visible.filter(e => e.level === 'error').length
  const syncedGroups = new Set(
    syncRows
      .filter(row => row.syncGroupSize > 1)
      .map(row => row.syncGroupId),
  )
  const attractionScores = syncRows.map((row, index) =>
    streamEventAttractionScore(row, index, syncRows.length),
  )
  const highAttractionCount = attractionScores.filter(score => streamEventAttractionBand(score) === 'high').length
  const status: EventStreamStatus =
    visible.length === 0
      ? 'empty'
      : errorCount > 0
        ? 'error'
        : warnCount > 0
          ? 'warning'
          : 'ok'

  return {
    totalCount: events.length,
    visibleCount: visible.length,
    hiddenCount: Math.max(0, events.length - visible.length),
    infoCount,
    warnCount,
    errorCount,
    latestTimestamp: visible[0]?.timestamp ?? null,
    oldestVisibleTimestamp: visible[visible.length - 1]?.timestamp ?? null,
    temporalSyncGroupCount: syncedGroups.size,
    maxTemporalSyncGroupSize: syncRows.reduce((max, row) => Math.max(max, row.syncGroupSize), 0),
    highAttractionCount,
    maxAttractionScore: attractionScores.reduce((max, score) => Math.max(max, score), 0),
    status,
  }
}

function attractionRowClass(band: EventStreamAttractionBand, isSynced: boolean): string {
  if (band === 'high') return 'border-[var(--color-accent)] bg-[var(--color-bg-elevated)]'
  if (band === 'medium') {
    return isSynced
      ? 'border-[var(--color-accent)] bg-[var(--color-bg-elevated)]'
      : 'border-[var(--color-border-strong)]'
  }
  return 'border-transparent opacity-80'
}

export function EventStream({
  events,
  maxItems = 100,
  temporalSyncWindowMs = 5000,
  testId,
}: EventStreamProps) {
  const visible = useMemo(() => getVisibleStreamEvents(events, maxItems), [events, maxItems])
  const syncRows = useMemo(
    () => buildTemporalSyncRows(visible, temporalSyncWindowMs),
    [visible, temporalSyncWindowMs],
  )
  const summary = useMemo(
    () => summarizeEventStream(events, maxItems, temporalSyncWindowMs),
    [events, maxItems, temporalSyncWindowMs],
  )

  return html`
    <div
      class="h-64 space-y-2 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2"
      data-event-stream
      data-event-stream-total-count=${summary.totalCount}
      data-event-stream-visible-count=${summary.visibleCount}
      data-event-stream-hidden-count=${summary.hiddenCount}
      data-event-stream-info-count=${summary.infoCount}
      data-event-stream-warn-count=${summary.warnCount}
      data-event-stream-error-count=${summary.errorCount}
      data-event-stream-status=${summary.status}
      data-event-stream-latest-timestamp=${summary.latestTimestamp ?? ''}
      data-event-stream-oldest-visible-timestamp=${summary.oldestVisibleTimestamp ?? ''}
      data-event-stream-temporal-sync-window-ms=${normalizedSyncWindowMs(temporalSyncWindowMs)}
      data-event-stream-temporal-sync-group-count=${summary.temporalSyncGroupCount}
      data-event-stream-max-temporal-sync-group-size=${summary.maxTemporalSyncGroupSize}
      data-event-stream-high-attraction-count=${summary.highAttractionCount}
      data-event-stream-max-attraction-score=${summary.maxAttractionScore.toFixed(2)}
      data-testid=${testId}
    >
      <div
        class="grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="이벤트 스트림 요약"
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">전체</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">표시</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">
            ${summary.visibleCount}/${summary.totalCount}
          </div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">에러</div>
          <div class="font-mono text-sm text-[var(--color-status-err)]">${summary.errorCount}</div>
        </div>
      </div>
      <div
        role="log"
        aria-label="이벤트 스트림, 이벤트 ${summary.visibleCount}개, 에러 ${summary.errorCount}개"
        aria-live="polite"
        aria-atomic="false"
      >
        ${visible.length === 0
          ? html`<div class="text-3xs text-[var(--color-fg-muted)]">이벤트 없음</div>`
          : html`
            <div class="space-y-1" role="list">
              ${syncRows.map(
                (row, index) => {
                  const e = row.event
                  const isSynced = row.syncGroupSize > 1
                  const attractionScore = streamEventAttractionScore(row, index, syncRows.length)
                  const attractionBand = streamEventAttractionBand(attractionScore)
                  return html`
                  <div
                    key=${e.id}
                    class=${`flex min-w-0 items-start gap-2 rounded-[var(--r-1)] border-l-2 px-2 py-1 hover:bg-[var(--color-bg-hover)] ${attractionRowClass(attractionBand, isSynced)}`}
                    role="listitem"
                    data-stream-event-id=${e.id}
                    data-stream-event-level=${e.level}
                    data-stream-event-source=${e.source ?? ''}
                    data-stream-event-timestamp=${e.timestamp}
                    data-stream-event-visible-index=${index}
                    data-stream-event-sync-group=${row.syncGroupId}
                    data-stream-event-sync-size=${row.syncGroupSize}
                    data-stream-event-sync-anchor=${row.syncAnchorTimestamp ?? ''}
                    data-stream-event-attraction-score=${attractionScore.toFixed(2)}
                    data-stream-event-attraction-band=${attractionBand}
                  >
                    <span
                      class="mt-0.5 inline-block h-1.5 w-1.5 flex-shrink-0 rounded-full"
                      style=${{ background: levelColor(e.level) }}
                      aria-hidden="true"
                    ></span>
                    <time
                      class="shrink-0 font-mono text-3xs text-[var(--color-fg-secondary)] tabular-nums"
                      datetime=${formatDateTime(e.timestamp)}
                      >${formatTime(e.timestamp)}</time
                    >
                    ${e.source
                      ? html`<span
                          class="max-w-24 shrink-0 truncate text-3xs text-[var(--color-fg-muted)]"
                          title=${e.source}
                        >[${e.source}]</span
                        >`
                      : null}
                    ${isSynced
                      ? html`<span class="shrink-0 rounded-[var(--r-0)] border border-[var(--color-border-default)] px-1 font-mono text-3xs text-[var(--color-fg-muted)]">sync ${row.syncGroupSize}</span>`
                      : null}
                    <span class="min-w-0 flex-1 break-words text-xs text-[var(--color-fg-primary)]"
                      >${e.message}</span
                    >
                    ${isSynced
                      ? html`<span class="sr-only">동기화 그룹 ${row.syncGroupSize}개 이벤트</span>`
                      : null}
                    <span class="sr-only">${levelLabel(e.level)}</span>
                  </div>
                `},
              )}
            </div>
          `}
      </div>
    </div>
  `
}

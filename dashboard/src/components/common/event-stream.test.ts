import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  buildIntentProjectionRows,
  buildSemanticGravityRows,
  buildTemporalSyncRows,
  DEFAULT_TEMPORAL_SYNC_WINDOW_MS,
  EventStream,
  getVisibleStreamEvents,
  summarizeEventStream,
  streamEventAttractionBand,
  streamEventAttractionScore,
  streamEventSemanticGravityScore,
} from './event-stream'

const baseEvents = [
  { id: 'e1', timestamp: new Date('2024-01-01T09:30:00').getTime(), level: 'info' as const, message: 'started', source: 'agent-a' },
  { id: 'e2', timestamp: new Date('2024-01-01T09:31:00').getTime(), level: 'warn' as const, message: 'slow', source: 'agent-b' },
  { id: 'e3', timestamp: new Date('2024-01-01T09:32:00').getTime(), level: 'error' as const, message: 'failed' },
]

const projectionEvents = [
  { id: 'p1', timestamp: new Date('2024-01-01T10:00:00').getTime(), level: 'info' as const, message: 'edit app.ts', source: 'editor' },
  { id: 'p2', timestamp: new Date('2024-01-01T10:01:00').getTime(), level: 'error' as const, message: 'test failed', source: 'test' },
  { id: 'p3', timestamp: new Date('2024-01-01T10:02:00').getTime(), level: 'info' as const, message: 'edit app.ts', source: 'editor' },
  { id: 'p4', timestamp: new Date('2024-01-01T10:03:00').getTime(), level: 'info' as const, message: 'test passed', source: 'test' },
  { id: 'p5', timestamp: new Date('2024-01-01T10:04:00').getTime(), level: 'info' as const, message: 'edit app.ts', source: 'editor' },
  { id: 'p6', timestamp: new Date('2024-01-01T10:05:00').getTime(), level: 'info' as const, message: 'update docs', source: 'docs' },
]

describe('EventStream', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    expect(container.querySelector('[data-event-stream]')).not.toBeNull()
  })

  it('renders log role', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    expect(container.querySelector('[role="log"]')).not.toBeNull()
  })

  it('renders aria-label', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.getAttribute('aria-label')).toContain('이벤트 스트림')
    expect(el?.getAttribute('aria-label')).toContain('이벤트 0개')
  })

  it('renders empty state', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    expect(container.textContent).toContain('이벤트 없음')
  })

  it('renders events', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('started')
    expect(container.textContent).toContain('slow')
    expect(container.textContent).toContain('failed')
    expect(container.textContent).toContain('전체')
    expect(container.textContent).toContain('표시')
    expect(container.textContent).toContain('에러')
  })

  it('renders source labels', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('agent-a')
    expect(container.textContent).toContain('agent-b')
  })

  it('renders timestamps', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('09:30:00')
    expect(container.textContent).toContain('09:31:00')
  })

  it('renders listitems', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(3)
  })

  it('reverses order (newest first)', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items[0]?.textContent).toContain('failed')
    expect(items[2]?.textContent).toContain('started')
  })

  it('limits to maxItems', () => {
    const container = document.createElement('div')
    const many = Array.from({ length: 10 }, (_, i) => ({
      id: `e${i}`,
      timestamp: Date.now() + i * 1000,
      level: 'info' as const,
      message: `msg-${i}`,
    }))
    render(h(EventStream, { events: many, maxItems: 5 }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(5)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    expect(root.dataset.eventStreamTotalCount).toBe('10')
    expect(root.dataset.eventStreamVisibleCount).toBe('5')
    expect(root.dataset.eventStreamHiddenCount).toBe('5')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [], testId: 'es-1' }), container)
    expect(container.querySelector('[data-testid="es-1"]')).not.toBeNull()
  })

  it('renders sr-only level labels', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('정보')
    expect(container.textContent).toContain('경고')
    expect(container.textContent).toContain('에러')
  })

  it('exposes stream summary metadata', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    const latest = baseEvents[2]!

    expect(root.dataset.eventStreamStatus).toBe('error')
    expect(root.dataset.eventStreamTotalCount).toBe('3')
    expect(root.dataset.eventStreamVisibleCount).toBe('3')
    expect(root.dataset.eventStreamInfoCount).toBe('1')
    expect(root.dataset.eventStreamWarnCount).toBe('1')
    expect(root.dataset.eventStreamErrorCount).toBe('1')
    expect(root.dataset.eventStreamLatestTimestamp).toBe(String(latest.timestamp))
    expect(root.dataset.eventStreamTemporalSyncWindowMs).toBe(String(DEFAULT_TEMPORAL_SYNC_WINDOW_MS))
    expect(root.dataset.eventStreamTemporalSyncGroupCount).toBe('0')
    expect(root.dataset.eventStreamMaxTemporalSyncGroupSize).toBe('1')
    expect(root.dataset.eventStreamHighAttractionCount).toBe('1')
    expect(root.dataset.eventStreamMaxAttractionScore).toBe('0.90')
  })

  it('exposes event row metadata and datetime', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    const item = container.querySelector('[data-stream-event-id="e3"]') as HTMLElement
    const time = item.querySelector('time') as HTMLTimeElement
    const latest = baseEvents[2]!

    expect(item.dataset.streamEventLevel).toBe('error')
    expect(item.dataset.streamEventVisibleIndex).toBe('0')
    expect(item.dataset.streamEventTimestamp).toBe(String(latest.timestamp))
    expect(time.dateTime).toBe(new Date(latest.timestamp).toISOString())
  })

  it('summarizes visible event status', () => {
    expect(summarizeEventStream([], 100)).toMatchObject({
      totalCount: 0,
      visibleCount: 0,
      status: 'empty',
    })
    expect(summarizeEventStream(baseEvents.slice(0, 1), 100)).toMatchObject({
      visibleCount: 1,
      infoCount: 1,
      status: 'ok',
    })
    expect(summarizeEventStream(baseEvents.slice(0, 2), 100)).toMatchObject({
      visibleCount: 2,
      warnCount: 1,
      status: 'warning',
    })
    expect(summarizeEventStream(baseEvents, 2)).toMatchObject({
      totalCount: 3,
      visibleCount: 2,
      hiddenCount: 1,
      status: 'error',
    })
  })

  it('omits non-finite timestamps from summary and row metadata', () => {
    const invalidEvents = [
      { id: 'bad-1', timestamp: Number.NaN, level: 'info' as const, message: 'bad latest' },
      { id: 'bad-2', timestamp: Number.POSITIVE_INFINITY, level: 'warn' as const, message: 'bad oldest' },
    ]
    const container = document.createElement('div')
    render(h(EventStream, { events: invalidEvents }), container)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    const latest = container.querySelector('[data-stream-event-id="bad-2"]') as HTMLElement

    expect(summarizeEventStream(invalidEvents, 100)).toMatchObject({
      latestTimestamp: null,
      oldestVisibleTimestamp: null,
    })
    expect(root.dataset.eventStreamLatestTimestamp).toBe('')
    expect(root.dataset.eventStreamOldestVisibleTimestamp).toBe('')
    expect(latest.dataset.streamEventTimestamp).toBe('')
  })

  it('groups visible events by anchor timestamp inside the temporal synchronization window', () => {
    const rows = buildTemporalSyncRows(getVisibleStreamEvents(baseEvents, 100), 65000)

    expect(rows.map(row => row.event.id)).toEqual(['e3', 'e2', 'e1'])
    expect(rows[0]?.syncGroupId).toBe(rows[1]?.syncGroupId)
    expect(rows[0]?.syncGroupSize).toBe(2)
    expect(rows[1]?.syncGroupSize).toBe(2)
    expect(rows[2]?.syncGroupSize).toBe(1)
    expect(summarizeEventStream(baseEvents, 100, 65000)).toMatchObject({
      temporalSyncGroupCount: 1,
      maxTemporalSyncGroupSize: 2,
    })
  })

  it('scores gradient attraction by severity, recency, and sync grouping', () => {
    const rows = buildTemporalSyncRows(getVisibleStreamEvents(baseEvents, 100), 65000)
    const latestScore = streamEventAttractionScore(rows[0]!, 0, rows.length)
    const neighborScore = streamEventAttractionScore(rows[1]!, 1, rows.length)
    const olderScore = streamEventAttractionScore(rows[2]!, 2, rows.length)

    expect(latestScore).toBe(1)
    expect(neighborScore).toBe(0.69)
    expect(olderScore).toBe(0.32)
    expect(streamEventAttractionBand(latestScore)).toBe('high')
    expect(streamEventAttractionBand(neighborScore)).toBe('medium')
    expect(streamEventAttractionBand(olderScore)).toBe('low')
  })

  it('renders temporal synchronization metadata and cue badges', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents, temporalSyncWindowMs: 65000 }), container)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    const latest = container.querySelector('[data-stream-event-id="e3"]') as HTMLElement
    const neighbor = container.querySelector('[data-stream-event-id="e2"]') as HTMLElement
    const older = container.querySelector('[data-stream-event-id="e1"]') as HTMLElement

    expect(root.dataset.eventStreamTemporalSyncWindowMs).toBe('65000')
    expect(root.dataset.eventStreamTemporalSyncGroupCount).toBe('1')
    expect(root.dataset.eventStreamMaxTemporalSyncGroupSize).toBe('2')
    expect(latest.dataset.streamEventSyncGroup).toBe(neighbor.dataset.streamEventSyncGroup)
    expect(latest.dataset.streamEventSyncSize).toBe('2')
    expect(neighbor.dataset.streamEventSyncSize).toBe('2')
    expect(older.dataset.streamEventSyncSize).toBe('1')
    expect(container.textContent).toContain('sync 2')
    const syncBadge = Array.from(container.querySelectorAll('span'))
      .find(el => el.textContent === 'sync 2') as HTMLElement | undefined
    expect(syncBadge?.getAttribute('aria-hidden')).toBe('true')
  })

  it('renders gradient attraction metadata on event rows', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    const latest = container.querySelector('[data-stream-event-id="e3"]') as HTMLElement
    const middle = container.querySelector('[data-stream-event-id="e2"]') as HTMLElement
    const older = container.querySelector('[data-stream-event-id="e1"]') as HTMLElement

    expect(root.dataset.eventStreamHighAttractionCount).toBe('1')
    expect(latest.dataset.streamEventAttractionScore).toBe('0.90')
    expect(latest.dataset.streamEventAttractionBand).toBe('high')
    expect(middle.dataset.streamEventAttractionBand).toBe('medium')
    expect(older.dataset.streamEventAttractionBand).toBe('low')
  })

  it('scores semantic gravity from the current focus', () => {
    const score = streamEventSemanticGravityScore(baseEvents[0]!, ['agent-a', 'started'])
    const unrelated = streamEventSemanticGravityScore(baseEvents[2]!, ['agent-a', 'started'])

    expect(score).toBe(0.85)
    expect(unrelated).toBe(0)
  })

  it('orders semantically related events before unrelated visible rows', () => {
    const rows = buildSemanticGravityRows(
      buildTemporalSyncRows(getVisibleStreamEvents(baseEvents, 100), 5000),
      ['agent-a', 'started'],
    )

    expect(rows.map(row => row.event.id)).toEqual(['e1', 'e3', 'e2'])
    expect(rows[0]?.semanticGravityScore).toBe(0.85)
    expect(rows[0]?.semanticGravityRank).toBe(1)
    expect(rows[0]?.originalVisibleIndex).toBe(2)
    expect(summarizeEventStream(baseEvents, 100, 5000, ['agent-a', 'started'])).toMatchObject({
      semanticGravityTermCount: 2,
      semanticGravityMatchCount: 1,
      maxSemanticGravityScore: 0.85,
      maxAttractionScore: 0.9,
    })
  })

  it('renders semantic gravity metadata on event rows', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents, semanticFocus: ['agent-a', 'started'] }), container)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    const items = container.querySelectorAll('[role="listitem"]')
    const focused = container.querySelector('[data-stream-event-id="e1"]') as HTMLElement

    expect(root.dataset.eventStreamSemanticGravityTermCount).toBe('2')
    expect(root.dataset.eventStreamSemanticGravityMatchCount).toBe('1')
    expect(root.dataset.eventStreamMaxSemanticGravityScore).toBe('0.85')
    expect(root.dataset.eventStreamMaxAttractionScore).toBe('0.90')
    expect(items[0]?.getAttribute('data-stream-event-id')).toBe('e1')
    expect(focused.dataset.streamEventVisibleIndex).toBe('2')
    expect(focused.dataset.streamEventAttractionScore).toBe('0.32')
    expect(focused.dataset.streamEventSemanticGravityScore).toBe('0.85')
    expect(focused.dataset.streamEventSemanticGravityRank).toBe('1')
  })

  it('projects likely next intent from focused event history', () => {
    const rows = buildIntentProjectionRows(projectionEvents, 'editor')

    expect(rows.map(row => row.key)).toEqual(['source:test', 'source:docs'])
    expect(rows[0]).toMatchObject({
      label: 'test',
      targetKind: 'source',
      probability: 0.67,
      evidenceCount: 2,
    })
    expect(rows[1]).toMatchObject({
      label: 'docs',
      probability: 0.33,
      evidenceCount: 1,
    })
    expect(summarizeEventStream(projectionEvents, 100, DEFAULT_TEMPORAL_SYNC_WINDOW_MS, 'editor')).toMatchObject({
      intentProjectionCount: 2,
      topIntentProjectionProbability: 0.67,
    })
  })

  it('renders intentional projection metadata and suggestion chips', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: projectionEvents, semanticFocus: 'editor' }), container)
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    const projections = container.querySelectorAll('[data-intent-projection-key]')
    const top = projections[0] as HTMLElement

    expect(root.dataset.eventStreamIntentProjectionCount).toBe('2')
    expect(root.dataset.eventStreamTopIntentProjectionProbability).toBe('0.67')
    expect(top.dataset.intentProjectionKey).toBe('source:test')
    expect(top.dataset.intentProjectionTargetKind).toBe('source')
    expect(top.dataset.intentProjectionProbability).toBe('0.67')
    expect(top.dataset.intentProjectionEvidenceCount).toBe('2')
    expect(container.textContent).toContain('test')
    expect(container.textContent).toContain('67%')
  })

  it('limits intentional projections', () => {
    const rows = buildIntentProjectionRows(projectionEvents, 'editor', 1)

    expect(rows).toHaveLength(1)
    expect(rows[0]?.key).toBe('source:test')
  })

  it('treats maxItems zero as an empty visible window', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents, maxItems: 0 }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(0)
    expect(getVisibleStreamEvents(baseEvents, 0)).toEqual([])
    const root = container.querySelector('[data-event-stream]') as HTMLElement
    expect(root.dataset.eventStreamTotalCount).toBe('3')
    expect(root.dataset.eventStreamVisibleCount).toBe('0')
    expect(root.dataset.eventStreamHiddenCount).toBe('3')
    expect(root.dataset.eventStreamStatus).toBe('empty')
  })
})

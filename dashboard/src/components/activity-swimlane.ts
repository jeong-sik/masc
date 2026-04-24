// Activity swimlane — vis-timeline per-agent timeline visualization
// Shows horizontal time spans per agent, color-coded by kind.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { DataSet } from 'vis-data'
import { Timeline, TimelineOptions } from 'vis-timeline'
import { Card } from './common/card'
import { EmptyState, LoadingState } from './common/feedback-state'
import { fetchSwimlane } from '../api'
import { registerActivityRefresh } from '../sse-store'
import type { SwimlaneResponse } from '../types'
import { selectedNodeId, highlightedAgentId } from './activity-graph-selection'
import { formatDurationMs } from '../lib/format-time'
import { createManagedAsyncResource } from '../lib/async-state'
import { escapeHtml, tooltipHtml } from '../lib/escape-html'
import 'vis-timeline/styles/vis-timeline-graph2d.css'

const swimlaneResource = createManagedAsyncResource<SwimlaneResponse | null>(null)
type TimelineItemId = number

interface SwimlaneTimelineItem {
  id: TimelineItemId
  group: string
  start: Date
  end: Date
  content: string
  title: string
  type: 'range'
  className: string
  style: string
}

export function truncateLabel(value: string, max = 20): string {
  return value.length > max ? `${value.slice(0, max - 2)}..` : value
}

function syncHighlightedGroups(
  container: HTMLDivElement,
  agents: string[],
  highlightedAgent: string | null,
) {
  const sync = (elements: HTMLElement[]) => {
    elements.slice(0, agents.length).forEach((element, index) => {
      const agent = agents[index]
      element.dataset.agentId = agent
      element.classList.toggle('activity-swimlane-group-highlighted', agent === highlightedAgent)
    })
  }

  sync(Array.from(container.querySelectorAll<HTMLElement>('.vis-labelset .vis-label')))
  sync(Array.from(container.querySelectorAll<HTMLElement>('.vis-center .vis-group')))
}

function syncTimelineSelection(
  timeline: Timeline,
  container: HTMLDivElement,
  agents: string[],
  itemIdsByAgent: Map<string, TimelineItemId[]>,
  highlightedAgent: string | null,
) {
  const selectedItems = highlightedAgent ? itemIdsByAgent.get(highlightedAgent) ?? [] : []

  timeline.setSelection(selectedItems)
  const firstSelectedItem = selectedItems[0]
  if (firstSelectedItem !== undefined) {
    timeline.focus(firstSelectedItem, {
      animation: {
        duration: 200,
        easingFunction: 'easeInOutQuad',
      },
    })
  }

  requestAnimationFrame(() => {
    syncHighlightedGroups(container, agents, highlightedAgent)
  })
}

const SPAN_STYLES: Record<string, { bg: string; text: string }> = {
  task:      { bg: 'var(--warn)', text: 'var(--panel-dark)' },
  operation: { bg: 'var(--ok)', text: 'var(--panel-dark)' },
  autonomy:  { bg: 'var(--cyan)', text: 'var(--panel-dark)' },
  presence:  { bg: 'rgba(148, 163, 184, 0.25)', text: 'var(--frost-100)' },
}
const SPAN_DEFAULT = { bg: 'var(--slate-400)', text: 'var(--panel-dark)' } as const

export function spanStyle(kind: string) {
  return SPAN_STYLES[kind] ?? SPAN_DEFAULT
}

function loadSwimlane(since?: string) {
  return swimlaneResource.load((signal) => fetchSwimlane(since, { signal }))
}

export function ActivitySwimlane({ since }: { since?: string }) {
  const containerRef = useRef<HTMLDivElement>(null)
  const timelineRef = useRef<Timeline | null>(null)
  const itemIdsByAgentRef = useRef<Map<string, TimelineItemId[]>>(new Map())

  useEffect(() => {
    void loadSwimlane(since)
    return registerActivityRefresh(() => {
      void loadSwimlane(since)
    })
  }, [since])

  const s = swimlaneResource.state.value
  const data = s.data ?? undefined

  useEffect(() => {
    const container = containerRef.current
    if (!container || !data || data.agents.length === 0) return

    const groups = new DataSet(data.agents.map((agent, i) => ({
      id: agent,
      content: agent.length > 16 ? agent.slice(0, 15) + '..' : agent,
      title: agent,
      className: 'agent-swimlane-group text-2xs font-system text-[var(--slate-400)]',
      order: i
    })))

    const itemIdsByAgent = new Map<string, TimelineItemId[]>()
    let idCounter = 1
    const items = new DataSet<SwimlaneTimelineItem>(data.spans.map(span => {
      const { bg: color, text: textColor } = spanStyle(span.kind)
      const duration = formatDurationMs(span.end_ms - span.start_ms)
      const itemId = idCounter++
      const title = tooltipHtml([span.label || span.kind, `종류: ${span.kind}`, `지속: ${duration}`])
      const content = span.label ? escapeHtml(truncateLabel(span.label)) : ''

      const agentItemIds = itemIdsByAgent.get(span.agent) ?? []
      agentItemIds.push(itemId)
      itemIdsByAgent.set(span.agent, agentItemIds)

      const item: SwimlaneTimelineItem = {
        id: itemId,
        group: span.agent,
        start: new Date(span.start_ms),
        end: new Date(span.end_ms),
        content,
        title,
        type: 'range',
        className: span.kind === 'presence'
          ? 'activity-swimlane-item activity-swimlane-item--presence'
          : 'activity-swimlane-item',
        style: `background-color: ${color}; border-color: ${color}; color: ${textColor}; font-size: 10px; border-radius: 3px; font-family: system-ui, sans-serif; overflow: hidden;`,
      }
      return item
    }))

    const options: TimelineOptions = {
      orientation: 'top',
      maxHeight: 400,
      minHeight: 120,
      zoomMin: 1000 * 60, // 1 minute
      zoomMax: 1000 * 60 * 60 * 24 * 7, // 7 days
      margin: {
        item: { horizontal: 0, vertical: 4 },
        axis: 4
      },
      tooltip: {
        followMouse: true,
        overflowMethod: 'cap'
      },
      showCurrentTime: true,
      timeAxis: { scale: 'minute', step: 15 }
    }

    const timeline = new Timeline(container, items, groups, options)
    timelineRef.current = timeline
    itemIdsByAgentRef.current = itemIdsByAgent
    syncTimelineSelection(timeline, container, data.agents, itemIdsByAgent, highlightedAgentId.value)

    timeline.on('select', (props) => {
      const firstId = props.items[0]
      if (firstId != null) {
        const item = items.get(firstId as TimelineItemId)
        if (item && !Array.isArray(item) && item.group) {
          selectedNodeId.value = 'agent:' + item.group
          highlightedAgentId.value = item.group
        }
      } else {
        selectedNodeId.value = null
        highlightedAgentId.value = null
      }
    })

    return () => {
      timeline.destroy()
      timelineRef.current = null
    }
  }, [data])

  useEffect(() => {
    const container = containerRef.current
    const timeline = timelineRef.current
    if (!container || !timeline || !data) return
    syncTimelineSelection(
      timeline,
      container,
      data.agents,
      itemIdsByAgentRef.current,
      highlightedAgentId.value,
    )
  }, [data, highlightedAgentId.value])

  if (s.loading && !data) {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${LoadingState}>타임라인 불러오는 중...<//>
      <//>
    `
  }

  if (s.error && !data) {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${EmptyState}>타임라인을 불러올 수 없습니다: ${s.error}<//>
      <//>
    `
  }

  if (!data) {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${LoadingState}>activity feed 워밍업 중...<//>
      <//>
    `
  }

  if (data.agents.length === 0) {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${EmptyState}>표시할 에이전트 활동 타임라인이 없습니다.<//>
      <//>
    `
  }

  return html`
    <${Card} title="활동 타임라인" testId="activity_swimlane">
      <div class="mb-2">
        <p class="text-sm text-[var(--text-muted)]">에이전트별 활동 구간을 시간축으로 보여줍니다. 마우스 휠로 줌인/아웃, 드래그로 이동이 가능합니다.</p>
      </div>
      <div class="w-full bg-[#0f1117] rounded border border-[var(--card-border)] overflow-hidden swimlane-vis-container">
        <div ref=${containerRef} class="w-full"></div>
      </div>
      <div class="flex flex-wrap gap-3 mt-3 text-2xs text-[var(--text-muted)]">
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[var(--warn)] inline-block"></span>작업</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[var(--ok)] inline-block"></span>운영</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[var(--cyan)] inline-block"></span>자율</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[rgba(148,163,184,0.5)] inline-block"></span>접속</span>
      </div>
    <//>
  `
}

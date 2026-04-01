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
import { selectedNodeId, highlightedAgentId } from './activity-graph-view'
import { formatDurationMs } from '../lib/format-time'
import { createAsyncResource } from '../lib/async-state'
import 'vis-timeline/styles/vis-timeline-graph2d.css'

const swimlaneResource = createAsyncResource<SwimlaneResponse | null>()

function spanColor(kind: string): string {
  switch (kind) {
    case 'task': return '#fbbf24'
    case 'operation': return '#4ade80'
    case 'autonomy': return '#22d3ee'
    case 'presence': return 'rgba(148, 163, 184, 0.25)'
    default: return '#94a3b8'
  }
}

function loadSwimlane(since?: string) {
  return swimlaneResource.load(() => fetchSwimlane(since))
}

export function ActivitySwimlane({ since }: { since?: string }) {
  const containerRef = useRef<HTMLDivElement>(null)
  const timelineRef = useRef<Timeline | null>(null)

  useEffect(() => {
    void loadSwimlane(since)
    return registerActivityRefresh(() => {
      void loadSwimlane(since)
    })
  }, [since])

  const s = swimlaneResource.state.value
  const data = s.status === 'loaded' ? s.data : undefined

  useEffect(() => {
    const container = containerRef.current
    if (!container || !data || data.agents.length === 0) return

    const groups = new DataSet(data.agents.map((agent, i) => ({
      id: agent,
      content: agent.length > 10 ? agent.slice(0, 9) + '..' : agent,
      title: agent,
      className: 'agent-swimlane-group text-[11px] font-system text-[#94a3b8]',
      order: i
    })))

    let idCounter = 1;
    const items = new DataSet(data.spans.map(span => {
      const color = spanColor(span.kind)
      const duration = formatDurationMs(span.end_ms - span.start_ms)
      const title = `${span.label || span.kind}\n종류: ${span.kind}\n지속: ${duration}`
      
      const content = span.label && span.label.length > 20 
        ? span.label.slice(0, 18) + '..' 
        : (span.label || '')

      return {
        id: idCounter++,
        group: span.agent,
        start: new Date(span.start_ms),
        end: new Date(span.end_ms),
        content,
        title,
        type: 'range',
        className: span.kind === 'presence' ? 'opacity-40' : '',
        style: `background-color: ${color}; border-color: ${color}; color: #0f172a; font-size: 10px; border-radius: 3px; font-family: system-ui, sans-serif; overflow: hidden;`
      }
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

    timeline.on('select', (props) => {
      if (props.items.length > 0) {
        const item = items.get(props.items[0]) as any
        if (item && item.group) {
          selectedNodeId.value = 'agent:' + item.group
          highlightedAgentId.value = item.group as string
        }
      } else {
        selectedNodeId.value = null
        highlightedAgentId.value = null
      }
    })

    return () => {
      timeline.destroy()
    }
  }, [data])

  /* 
  useEffect(() => {
    if (!timelineRef.current || !data) return
    const _highlighted = highlightedAgentId.value
    
    // Custom styling injection for highlighting a group row
    const elements = document.querySelectorAll('.vis-group')
    elements.forEach(el => {
      // const _groupId = el.getAttribute('data-group-id') // Or parsed from internal structure
      // Wait, vis-timeline doesn't easily highlight groups natively via api.
      // We can rely on CSS or just ignore row highlighting for now.
    })

  }, [highlightedAgentId.value, data]) 
  */

  if (s.status === 'loading' || s.status === 'idle') {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${LoadingState}>타임라인 불러오는 중...<//>
      <//>
    `
  }

  if (s.status === 'error') {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${EmptyState}>타임라인을 불러올 수 없습니다: ${s.message}<//>
      <//>
    `
  }

  if (!data || data.agents.length === 0) {
    return html`
      <${Card} title="활동 타임라인" testId="activity_swimlane">
        <${EmptyState}>표시할 에이전트 활동 타임라인이 없습니다.<//>
      <//>
    `
  }

  return html`
    <${Card} title="활동 타임라인" testId="activity_swimlane">
      <div class="mb-2">
        <p class="text-[13px] text-[var(--text-muted)]">에이전트별 활동 구간을 시간축으로 보여줍니다. 마우스 휠로 줌인/아웃, 드래그로 이동이 가능합니다.</p>
      </div>
      <div class="w-full bg-[#0f1117] rounded-xl border border-[var(--card-border)] overflow-hidden swimlane-vis-container">
        <div ref=${containerRef} class="w-full"></div>
      </div>
      <div class="flex flex-wrap gap-3 mt-3 text-[11px] text-[var(--text-muted)]">
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[#fbbf24] inline-block"></span>작업</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[#4ade80] inline-block"></span>운영</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[#22d3ee] inline-block"></span>자율</span>
        <span class="flex items-center gap-1.5"><span class="w-3 h-2 rounded-sm bg-[rgba(148,163,184,0.5)] inline-block"></span>접속</span>
      </div>
      <style>
        .swimlane-vis-container .vis-timeline {
          border: none;
          font-family: system-ui, sans-serif;
        }
        .swimlane-vis-container .vis-item {
          border-color: transparent;
          color: #0f172a;
        }
        .swimlane-vis-container .vis-time-axis .vis-text {
          color: #94a3b8;
          font-size: 10px;
        }
        .swimlane-vis-container .vis-labelset .vis-label {
          color: #cbd5e1;
          font-size: 11px;
          border-bottom: 1px solid rgba(100, 116, 139, 0.12);
        }
        .swimlane-vis-container .vis-panel.vis-center,
        .swimlane-vis-container .vis-panel.vis-left,
        .swimlane-vis-container .vis-panel.vis-right,
        .swimlane-vis-container .vis-panel.vis-top,
        .swimlane-vis-container .vis-panel.vis-bottom {
          border-color: rgba(100, 116, 139, 0.12);
        }
        .swimlane-vis-container .vis-current-time {
          background-color: #f43f5e;
        }
        .swimlane-vis-container .vis-tooltip {
          background-color: rgba(15, 23, 42, 0.95);
          border: 1px solid rgba(100, 116, 139, 0.3);
          border-radius: 6px;
          color: #e2e8f0;
          font-size: 11px;
          padding: 8px 10px;
          box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
          white-space: pre-wrap;
        }
        .swimlane-vis-container .vis-item.vis-selected {
          border-color: #fbbf24;
          border-width: 2px;
          box-shadow: 0 0 5px rgba(251, 191, 36, 0.5);
          z-index: 10;
        }
      </style>
    <//>
  `
}

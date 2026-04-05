// Session trace entry — expandable row for a single event in the trace timeline.
// Reuses tool category patterns from keeper-trajectory-timeline.ts.

import { html } from 'htm/preact'
import { JsonViewerCard, parseJsonLikeData } from '../common/json-viewer'
import { TimeAgo } from '../common/time-ago'
import { Markdown } from '../common/markdown'
import { truncate } from '../../lib/truncate'
import type { UnifiedTraceEvent, TraceEventKind } from './session-trace-state'

// ── Constants ──────────────────────────────────────────

const ARGS_PREVIEW_MAX = 80
const ARGS_VALUE_MAX = 30
const ARGS_MAX_KEYS = 3
const BROADCAST_PREVIEW_MAX = 160

// ── Kind styling ───────────────────────────────────────

interface KindStyle {
  icon: string
  color: string
  label: string
}

const KIND_STYLES: Record<TraceEventKind, KindStyle> = {
  broadcast:  { icon: 'M', color: 'text-[#60a5fa]', label: '브로드캐스트' },
  task:       { icon: 'T', color: 'text-[var(--accent)]', label: '태스크' },
  tool_call:  { icon: '>', color: 'text-[var(--ok)]', label: '도구 호출' },
  heartbeat:  { icon: 'H', color: 'text-[#94a3b8]', label: '하트비트' },
  lifecycle:  { icon: 'L', color: 'text-[var(--warn)]', label: '생명주기' },
}

// Tool-specific icon/color overrides (same categories as keeper-trajectory-timeline)
const TOOL_CATEGORIES: Array<{ match: (n: string) => boolean; icon: string; color: string }> = [
  { match: n => n.includes('bash'),                          icon: '>', color: 'text-[var(--ok)]' },
  { match: n => n.includes('edit') || n.includes('fs'),      icon: 'E', color: 'text-[var(--warn)]' },
  { match: n => n.includes('board') || n.includes('social'), icon: 'B', color: 'text-[var(--purple)]' },
  { match: n => n.includes('github'),                        icon: 'G', color: 'text-[var(--accent)]' },
  { match: n => n.includes('search') || n.includes('read'),  icon: 'R', color: 'text-[#60a5fa]' },
]

function toolStyle(name: string): { icon: string; color: string } {
  return TOOL_CATEGORIES.find(c => c.match(name)) ?? { icon: '>', color: 'text-[var(--ok)]' }
}

function durationColor(ms: number): string {
  if (ms < 500) return 'text-[var(--ok)]'
  if (ms < 2000) return 'text-[var(--warn)]'
  return 'text-[var(--bad)]'
}

// ── Formatters ─────────────────────────────────────────

function formatArgs(args: Record<string, unknown> | string): string {
  if (typeof args === 'string') return truncate(args, ARGS_PREVIEW_MAX)
  const keys = Object.keys(args)
  if (keys.length === 0) return '{}'
  const preview = keys.slice(0, ARGS_MAX_KEYS).map(k => {
    const v = args[k]
    const vs = typeof v === 'string'
      ? truncate(v, ARGS_VALUE_MAX)
      : truncate(JSON.stringify(v) ?? '', ARGS_VALUE_MAX)
    return `${k}: ${vs}`
  }).join(', ')
  return keys.length > ARGS_MAX_KEYS ? `{${preview}, …}` : `{${preview}}`
}

// ── Task event helpers ─────────────────────────────────

function taskIcon(type: string): string {
  switch (type) {
    case 'task_completed':  return 'done'
    case 'task_claimed':    return 'claim'
    case 'task_started':    return 'start'
    case 'task_cancelled':  return 'cancel'
    default: return type.replace('task_', '')
  }
}

function taskColor(type: string): string {
  switch (type) {
    case 'task_completed':  return 'text-[var(--ok)]'
    case 'task_cancelled':  return 'text-[var(--bad)]'
    default: return 'text-[var(--accent)]'
  }
}

// ── Components ─────────────────────────────────────────

function ToolCallDetail({ event }: { event: UnifiedTraceEvent }) {
  const gateRejected = event.gate?.status === 'reject'
  return html`
    <div class="mt-2 space-y-1.5">
      ${event.toolArgs ? html`
        <div class="mt-1">
          <${JsonViewerCard} data=${parseJsonLikeData(event.toolArgs)} title="Args" />
        </div>
      ` : null}
      ${event.toolResult || event.error ? html`
        <div class="mt-1">
          <${JsonViewerCard} data=${parseJsonLikeData(event.error ?? event.toolResult)} title=${event.error ? 'Error' : 'Result'} />
        </div>
      ` : null}
      ${gateRejected ? html`
        <div class="text-[10px] px-2 py-1 rounded bg-[var(--bad-10)] text-[var(--bad)] inline-block">
          거부: ${event.gate?.reason ?? ''}
        </div>
      ` : null}
    </div>
  `
}

function BroadcastDetail({ event }: { event: UnifiedTraceEvent }) {
  const content = typeof event.detail.content === 'string' ? event.detail.content : ''
  if (!content) return null
  return html`
    <div class="mt-2 text-[13px] leading-relaxed px-3 py-2 bg-[var(--white-3)] rounded-lg border border-[var(--white-6)]">
      <${Markdown} text=${content} />
    </div>
  `
}

function TaskDetail({ event }: { event: UnifiedTraceEvent }) {
  const d = event.detail
  const taskId = typeof d.task_id === 'string' ? d.task_id : null
  const title = typeof d.title === 'string' ? d.title : null
  const notes = typeof d.completion_notes === 'string' ? d.completion_notes : null
  return html`
    <div class="mt-2 text-[12px] text-[var(--text-body)] space-y-1 px-3 py-2 bg-[var(--white-3)] rounded-lg">
      ${taskId ? html`<div><span class="text-[var(--text-dim)]">ID:</span> <span class="font-mono">${taskId}</span></div>` : null}
      ${title ? html`<div><span class="text-[var(--text-dim)]">제목:</span> ${title}</div>` : null}
      ${notes ? html`<div><span class="text-[var(--text-dim)]">노트:</span> ${notes}</div>` : null}
    </div>
  `
}

export function SessionTraceEntry({ event }: { event: UnifiedTraceEvent }) {
  const kindStyle = KIND_STYLES[event.kind]
  // For tool_call, use tool-specific icon/color
  const style = event.kind === 'tool_call' && event.toolName
    ? toolStyle(event.toolName)
    : kindStyle

  const gateRejected = event.kind === 'tool_call' && event.gate?.status === 'reject'

  // Summary text
  let summaryText = event.summary
  if (event.kind === 'tool_call' && event.toolArgs) {
    summaryText = formatArgs(event.toolArgs)
  } else if (event.kind === 'broadcast') {
    summaryText = truncate(event.summary, BROADCAST_PREVIEW_MAX)
  }

  // Determine if this entry has expandable detail
  const hasDetail = event.kind === 'tool_call'
    || (event.kind === 'broadcast' && typeof event.detail.content === 'string' && event.detail.content.length > BROADCAST_PREVIEW_MAX)
    || event.kind === 'task'

  const row = html`
    <div class="flex items-start gap-3 py-2 px-3 rounded-lg ${gateRejected ? 'opacity-50' : ''}">
      ${'' /* Icon */}
      <div class="flex-shrink-0 mt-0.5 size-7 rounded-md bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-[11px] font-mono font-bold ${style.color}">
        ${style.icon}
      </div>

      ${'' /* Content */}
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          ${event.kind === 'tool_call' && event.toolName
            ? html`<span class="text-xs font-mono font-medium ${style.color}">${event.toolName}</span>`
            : html`<span class="text-[10px] font-medium uppercase tracking-wider ${kindStyle.color}">${kindStyle.label}</span>`}
          ${event.turn != null ? html`<span class="text-[10px] text-[var(--text-dim)]">T${event.turn}R${event.round ?? 0}</span>` : null}
          ${event.kind === 'task' ? html`
            <span class="text-[10px] font-bold uppercase tracking-wider ${taskColor(String(event.detail.type))} bg-[var(--white-5)] px-1.5 py-0.5 rounded">
              ${taskIcon(String(event.detail.type))}
            </span>
          ` : null}
          ${event.error ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">오류</span>` : null}
          ${gateRejected ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">거부</span>` : null}
        </div>
        <div class="mt-0.5 text-[11px] text-[var(--text-muted)] font-mono truncate max-w-full" title=${event.summary}>
          ${summaryText}
        </div>
      </div>

      ${'' /* Right side: duration + time */}
      <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
        ${event.duration_ms != null ? html`
          <span class="text-[11px] font-mono ${durationColor(event.duration_ms)}">${event.duration_ms}ms</span>
        ` : null}
        <${TimeAgo} timestamp=${event.ts_iso} class="text-[10px] text-[var(--text-dim)]" />
      </div>
    </div>
  `

  if (!hasDetail) return row

  return html`
    <details class="rounded-lg hover:bg-[var(--white-3)] transition-colors">
      <summary class="list-none cursor-pointer">${row}</summary>
      <div class="px-3 pb-3 pl-13">
        ${event.kind === 'tool_call' ? html`<${ToolCallDetail} event=${event} />` : null}
        ${event.kind === 'broadcast' ? html`<${BroadcastDetail} event=${event} />` : null}
        ${event.kind === 'task' ? html`<${TaskDetail} event=${event} />` : null}
      </div>
    </details>
  `
}

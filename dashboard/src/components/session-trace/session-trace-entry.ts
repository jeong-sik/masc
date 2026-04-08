// Session trace entry — expandable row for a single event in the trace timeline.
// Reuses tool category patterns from keeper-trajectory-timeline.ts.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { JsonViewerCard, parseJsonLikeData } from '../common/json-viewer'
import { TimeAgo } from '../common/time-ago'
import { Markdown } from '../common/markdown'
import { truncate } from '../../lib/truncate'
import { toolCategory, durationColor, formatDuration, formatArgs as sharedFormatArgs } from '../tool-call-shared'
import type { UnifiedTraceEvent, TraceEventKind } from './session-trace-state'

// ── Constants ──────────────────────────────────────────

const BROADCAST_PREVIEW_MAX = 160
const RESULT_COLLAPSED_MAX_HEIGHT = 200 // px
const RESULT_LINES_THRESHOLD = 12 // lines above which we collapse

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
  thinking:   { icon: '\u{1F4AD}', color: 'text-[#c084fc]', label: '내부 사고' },
}

// Use shared tool category from tool-call-shared (SSOT)
function toolStyle(name: string): { icon: string; color: string } {
  return toolCategory(name)
}

// ── Formatters ─────────────────────────────────────────

// formatArgs delegated to shared module (SSOT: tool-call-shared.ts)
function formatArgs(args: Record<string, unknown> | string): string {
  return sharedFormatArgs(args)
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

// ── Content type detection ─────────────────────────────

type ContentHint = 'plain' | 'code' | 'diff' | 'json'

function detectContentHint(text: string): ContentHint {
  if (!text || text.length < 5) return 'plain'
  const trimmed = text.trimStart()
  // Diff detection: unified diff markers
  if (trimmed.startsWith('@@') || trimmed.startsWith('---') || trimmed.startsWith('+++')
    || /^[-+] /m.test(trimmed.slice(0, 500))) return 'diff'
  // JSON detection
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try { JSON.parse(trimmed); return 'json' } catch { /* not json */ }
  }
  // Code detection: indentation patterns or common code markers
  const lines = trimmed.split('\n').slice(0, 20)
  const indentedLines = lines.filter(l => /^[ \t]{2,}/.test(l)).length
  if (indentedLines > lines.length * 0.4) return 'code'
  if (/^(def |fn |let |const |import |function |class |module |type )/.test(trimmed)) return 'code'
  return 'plain'
}

function isLongContent(text: string): boolean {
  if (!text) return false
  return text.split('\n').length > RESULT_LINES_THRESHOLD || text.length > 1500
}

// ── Diff renderer ─────────────────────────────────────

function DiffBlock({ text }: { text: string }) {
  const allLines = text.split('\n')
  const MAX_LINES = 500
  const lines = allLines.length > MAX_LINES ? allLines.slice(0, MAX_LINES) : allLines
  const truncatedCount = allLines.length - lines.length

  return html`
    <div class="font-mono text-[11px] leading-[1.6] overflow-x-auto">
      ${lines.map((line: string) => {
        const cls =
          line.startsWith('+') && !line.startsWith('+++') ? 'text-[var(--ok)] bg-[rgba(74,222,128,0.06)]'
          : line.startsWith('-') && !line.startsWith('---') ? 'text-[var(--bad)] bg-[rgba(239,68,68,0.06)]'
          : line.startsWith('@@') ? 'text-[var(--accent)] font-semibold'
          : 'text-[var(--text-body)]'
        return html`<div class="${cls} px-2 min-h-[1.6em]">${line || ' '}</div>`
      })}
      ${truncatedCount > 0 ? html`
        <div class="px-2 py-2 text-[var(--text-muted)] italic text-center border-t border-[var(--white-6)]">
          ... ${truncatedCount} lines truncated for performance ...
        </div>
      ` : null}
    </div>
  `
}

// ── Collapsible result viewer ─────────────────────────

function ResultViewer({ text, hint, isError: isErr }: { text: string; hint: ContentHint; isError: boolean }) {
  const expanded = useSignal(false)
  const needsCollapse = isLongContent(text)
  const shouldCollapse = needsCollapse && !expanded.value

  const titleLabel = isErr ? 'Error' : 'Result'
  const titleColor = isErr ? 'text-[var(--bad)]' : 'text-[var(--text-muted)]'
  const borderColor = isErr ? 'border-[rgba(239,68,68,0.2)]' : 'border-[var(--white-8)]'
  const bgColor = isErr ? 'bg-[rgba(239,68,68,0.04)]' : 'bg-[var(--white-3)]'

  const MAX_TEXT_LEN = 100000
  const isTruncatedPlain = hint === 'plain' && text.length > MAX_TEXT_LEN
  const displayText = isTruncatedPlain ? text.slice(0, MAX_TEXT_LEN) + '\n\n... (Output truncated for performance) ...' : text

  return html`
    <div>
      <div class="flex items-center justify-between mb-1">
        <span class="text-[10px] font-semibold uppercase tracking-wider ${titleColor}">${titleLabel}</span>
        ${hint !== 'plain' ? html`
          <span class="text-[9px] px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)] uppercase">${hint}</span>
        ` : null}
      </div>
      <div class="rounded-lg border ${borderColor} ${bgColor} overflow-hidden">
        <div class="${shouldCollapse ? `max-h-[${RESULT_COLLAPSED_MAX_HEIGHT}px] overflow-hidden relative` : ''}"
             style=${shouldCollapse ? `max-height: ${RESULT_COLLAPSED_MAX_HEIGHT}px` : ''}>
          ${hint === 'diff' ? html`<${DiffBlock} text=${text} />`
            : hint === 'json' ? html`<${JsonViewerCard} title=${titleLabel} data=${parseJsonLikeData(text)} />`
            : html`<pre class="m-0 text-[11px] font-mono ${isErr ? 'text-[var(--bad)]' : 'text-[var(--text-body)]'} p-3 overflow-x-auto whitespace-pre-wrap break-all leading-relaxed">${displayText}</pre>`}
          ${shouldCollapse ? html`
            <div class="absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t ${isErr ? 'from-[rgba(239,68,68,0.08)]' : 'from-[var(--white-3)]'} to-transparent pointer-events-none"></div>
          ` : null}
        </div>
        ${needsCollapse ? html`
          <button
            type="button"
            class="w-full py-1.5 text-[10px] font-medium text-[var(--accent)] hover:text-[var(--text-strong)] hover:bg-[var(--white-5)] transition-colors cursor-pointer border-t border-[var(--white-6)] bg-transparent"
            onClick=${() => { expanded.value = !expanded.value }}
          >
            ${expanded.value ? '접기' : `전체 보기 (${text.split('\n').length}줄)`}
          </button>
        ` : null}
      </div>
    </div>
  `
}

// ── Components ─────────────────────────────────────────

function ToolCallDetail({ event }: { event: UnifiedTraceEvent }) {
  const gateRejected = event.gate?.status === 'reject'
  const resultText = event.error ?? event.toolResult ?? null
  const hint = resultText ? detectContentHint(resultText) : 'plain'

  return html`
    <div class="mt-2 space-y-2">
      ${event.toolArgs ? html`
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Args</div>
          <${JsonViewerCard} title="Args" data=${parseJsonLikeData(event.toolArgs)} />
        </div>
      ` : null}
      ${resultText ? html`
        <${ResultViewer} text=${resultText} hint=${hint} isError=${Boolean(event.error)} />
      ` : null}
      ${gateRejected ? html`
        <div class="text-[10px] px-2 py-1 rounded bg-[var(--bad-10)] text-[var(--bad)] inline-block">
          거부: ${event.gate?.reason ?? ''}
        </div>
      ` : null}
      ${'' /* Metadata row */}
      ${event.cost_usd != null && event.cost_usd > 0 ? html`
        <div class="flex gap-3 text-[10px] text-[var(--text-dim)]">
          <span>비용: <span class="font-mono text-[var(--accent)]">$${event.cost_usd.toFixed(4)}</span></span>
          ${event.duration_ms != null ? html`<span>소요: <span class="font-mono ${durationColor(event.duration_ms)}">${formatDuration(event.duration_ms)}</span></span>` : null}
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

function ThinkingDetail({ event }: { event: UnifiedTraceEvent }) {
  if (event.thinkingRedacted) {
    return html`
      <div class="mt-2 px-3 py-2 rounded-lg bg-[rgba(192,132,252,0.06)] border border-[rgba(192,132,252,0.15)] text-xs text-[#c084fc] italic">
        이 사고 과정은 비공개 처리되었습니다.
      </div>
    `
  }
  const content = event.thinkingContent ?? ''
  if (!content) return null
  return html`
    <div class="mt-2 px-3 py-2 rounded-lg bg-[rgba(192,132,252,0.04)] border border-[rgba(192,132,252,0.12)]">
      <div class="text-[13px] leading-relaxed text-[var(--text-body)]">
        <${Markdown} text=${content} />
      </div>
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
    || event.kind === 'thinking'

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
          ${event.error
            ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">오류</span>`
            : gateRejected
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">거부</span>`
              : event.kind === 'tool_call'
                ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[rgba(52,211,153,0.1)] text-[var(--ok)]">완료</span>`
                : null}
        </div>
        <div class="mt-0.5 text-[11px] text-[var(--text-muted)] font-mono truncate max-w-full" title=${event.summary}>
          ${summaryText}
        </div>
      </div>

      ${'' /* Right side: duration + time */}
      <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
        ${event.duration_ms != null ? html`
          <span class="text-[11px] font-mono ${durationColor(event.duration_ms)}">${formatDuration(event.duration_ms)}</span>
        ` : null}
        <${TimeAgo} timestamp=${event.ts_iso} class="text-[10px] text-[var(--text-dim)]" />
      </div>
    </div>
  `

  if (!hasDetail) return row

  return html`
    <details class="rounded-lg hover:bg-[var(--white-3)] transition-colors group">
      <summary class="list-none cursor-pointer relative pr-8">
        ${row}
        <div class="absolute right-3 top-1/2 -translate-y-1/2 opacity-40 group-hover:opacity-100 transition-opacity">
          <svg class="w-4 h-4 text-[var(--text-muted)] group-open:rotate-90 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        </div>
      </summary>
      <div class="px-3 pb-3 pl-13">
        ${event.kind === 'tool_call' ? html`<${ToolCallDetail} event=${event} />` : null}
        ${event.kind === 'broadcast' ? html`<${BroadcastDetail} event=${event} />` : null}
        ${event.kind === 'task' ? html`<${TaskDetail} event=${event} />` : null}
        ${event.kind === 'thinking' ? html`<${ThinkingDetail} event=${event} />` : null}
      </div>
    </details>
  `
}

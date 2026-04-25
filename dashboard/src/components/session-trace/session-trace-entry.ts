// Session trace entry — expandable row for a single event in the trace timeline.
// Reuses tool category patterns from keeper-trajectory-timeline.ts.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { JsonViewerCard, parseJsonLikeData } from '../common/json-viewer'
import { TimeAgo } from '../common/time-ago'
import { Markdown } from '../common/markdown'
import { ProgressBar } from '../common/progress-bar'
import { truncate } from '../../lib/truncate'
import { toolCategory, durationColor, formatDuration, formatArgs as sharedFormatArgs } from '../tool-call-shared'
import type { UnifiedTraceEvent, TraceEventKind } from './session-trace-state'

// ── Constants ──────────────────────────────────────────

const BROADCAST_PREVIEW_MAX = 160

// ── Search highlight ────────────────────────────────────

interface HighlightSegment {
  text: string
  match: boolean
}

function highlightSegments(text: string, query: string): HighlightSegment[] | null {
  if (!query) return null
  const lower = text.toLowerCase()
  const q = query.toLowerCase()
  if (!lower.includes(q)) return null

  const parts: HighlightSegment[] = []
  let lastIndex = 0
  let index = lower.indexOf(q, lastIndex)
  while (index !== -1) {
    if (index > lastIndex) {
      parts.push({ text: text.slice(lastIndex, index), match: false })
    }
    parts.push({ text: text.slice(index, index + q.length), match: true })
    lastIndex = index + q.length
    index = lower.indexOf(q, lastIndex)
  }
  if (lastIndex < text.length) {
    parts.push({ text: text.slice(lastIndex), match: false })
  }
  return parts
}

function HighlightedText({ text, query }: { text: string; query: string }) {
  const segments = highlightSegments(text, query)
  if (!segments) return html`<span>${text}</span>`
  return html`
    <span>${segments.map(seg =>
      seg.match
        ? html`<mark class="bg-[rgba(99,102,241,0.25)] text-[var(--text-strong)] px-0.5 rounded">${seg.text}</mark>`
        : seg.text
    )}</span>
  `
}
const RESULT_COLLAPSED_MAX_HEIGHT = 200 // px
const RESULT_LINES_THRESHOLD = 12 // lines above which we collapse

// ── Kind styling ───────────────────────────────────────

interface KindStyle {
  icon: string
  color: string
  label: string
}

const KIND_STYLES: Record<TraceEventKind, KindStyle> = {
  broadcast:  { icon: 'M', color: 'text-[var(--blue-400)]', label: '브로드캐스트' },
  task:       { icon: 'T', color: 'text-[var(--accent)]', label: '태스크' },
  tool_call:  { icon: '>', color: 'text-[var(--ok)]', label: '도구 호출' },
  heartbeat:  { icon: 'H', color: 'text-[var(--slate-400)]', label: '하트비트' },
  lifecycle:  { icon: 'L', color: 'text-[var(--warn)]', label: '생명주기' },
  thinking:   { icon: '\u{1F4AD}', color: 'text-[#c084fc]', label: '내부 사고' },
  oas_tool:   { icon: 'O', color: 'text-[var(--amber-bright)]', label: 'OAS 도구' },
  oas_turn:   { icon: 'R', color: 'text-[var(--rose-light)]', label: 'OAS 턴' },
  oas_context: { icon: 'C', color: 'text-[var(--sky-400)]', label: 'OAS 압축' },
}

// Use shared tool category from tool-call-shared (SSOT)
function toolStyle(name: string): { icon: string; color: string } {
  return toolCategory(name)
}

// Durable_event projections carry durable_kind in detail; give each
// a distinct icon/tone so LLM, error, and agent lifecycle events
// are visually separable in the trace timeline.
function durableStyle(kind: unknown): { icon: string; color: string } | null {
  switch (kind) {
    case 'llm_request':      return { icon: '>', color: 'text-[var(--sky-400)]' }
    case 'llm_response':     return { icon: '<', color: 'text-[var(--cyan)]' }
    case 'error_occurred':   return { icon: '!', color: 'text-[var(--bad)]' }
    case 'tool_called':      return { icon: 't', color: 'text-[var(--ok)]' }
    case 'tool_completed':   return { icon: 'x', color: 'text-[var(--ok)]' }
    case 'state_transition': return { icon: '>', color: 'text-[var(--accent)]' }
    case 'checkpoint_saved': return { icon: '*', color: 'text-[var(--slate-400)]' }
    case 'turn_started':     return { icon: 'r', color: 'text-[var(--warn)]' }
    default: return null
  }
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
    <div class="font-mono text-2xs leading-loose overflow-x-auto">
      ${lines.map((line: string) => {
        const cls =
          line.startsWith('+') && !line.startsWith('+++') ? 'text-[var(--ok)] bg-[var(--ok-6)]'
          : line.startsWith('-') && !line.startsWith('---') ? 'text-[var(--bad)] bg-[var(--bad-6)]'
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
  const borderColor = isErr ? 'border-[var(--bad-20)]' : 'border-[var(--white-8)]'
  const bgColor = isErr ? 'bg-[var(--bad-6)]' : 'bg-[var(--white-3)]'

  const MAX_TEXT_LEN = 100000
  const isTruncatedPlain = hint === 'plain' && text.length > MAX_TEXT_LEN
  const displayText = isTruncatedPlain ? text.slice(0, MAX_TEXT_LEN) + '\n\n... (Output truncated for performance) ...' : text

  return html`
    <div role="group" aria-label=${titleLabel}>
      <div class="flex items-center justify-between mb-1">
        <span class="text-3xs font-semibold uppercase tracking-wider ${titleColor}">${titleLabel}</span>
        ${hint !== 'plain' ? html`
          <span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)] uppercase">${hint}</span>
        ` : null}
      </div>
      <div class="rounded border ${borderColor} ${bgColor} overflow-hidden">
        <div class="${shouldCollapse ? `max-h-[${RESULT_COLLAPSED_MAX_HEIGHT}px] overflow-hidden relative` : ''}"
             style=${shouldCollapse ? `max-height: ${RESULT_COLLAPSED_MAX_HEIGHT}px` : ''}>
          ${hint === 'diff' ? html`<${DiffBlock} text=${text} />`
            : hint === 'json' ? html`<${JsonViewerCard} title=${titleLabel} data=${parseJsonLikeData(text)} />`
            : html`<pre class="m-0 text-2xs font-mono ${isErr ? 'text-[var(--bad)]' : 'text-[var(--text-body)]'} p-3 overflow-x-auto whitespace-pre-wrap break-all leading-relaxed">${displayText}</pre>`}
          ${shouldCollapse ? html`
            <div class="absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t ${isErr ? 'from-[rgba(239,68,68,0.08)]' : 'from-[var(--white-3)]'} to-transparent pointer-events-none"></div>
          ` : null}
        </div>
        ${needsCollapse ? html`
          <button type="button"
            type="button"
            class="w-full py-1.5 text-3xs font-medium text-[var(--accent)] hover:text-[var(--text-strong)] hover:bg-[var(--white-5)] transition-colors cursor-pointer border-t border-[var(--white-6)] bg-transparent"
            aria-expanded=${expanded.value}
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
          <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Args</div>
          <${JsonViewerCard} title="Args" data=${parseJsonLikeData(event.toolArgs)} />
        </div>
      ` : null}
      ${resultText ? html`
        <${ResultViewer} text=${resultText} hint=${hint} isError=${Boolean(event.error)} />
      ` : null}
      ${gateRejected ? html`
        <div class="text-3xs px-2 py-1 rounded bg-[var(--bad-10)] text-[var(--bad)] inline-block">
          거부: ${event.gate?.reason ?? ''}
        </div>
      ` : null}
      ${!event.toolArgs && !resultText && !gateRejected ? html`
        <div class="text-3xs text-[var(--text-dim)] italic px-2 py-1">
          세부 정보가 기록되지 않았습니다.
        </div>
      ` : null}
      ${'' /* Metadata row */}
      ${event.cost_usd != null && event.cost_usd > 0 ? html`
        <div class="flex gap-3 text-3xs text-[var(--text-dim)]">
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
    <div class="mt-2 text-sm leading-relaxed px-3 py-2 bg-[var(--white-3)] rounded border border-[var(--white-6)]">
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
    <div class="mt-2 text-xs text-[var(--text-body)] space-y-1 px-3 py-2 bg-[var(--white-3)] rounded">
      ${taskId ? html`<div><span class="text-[var(--text-dim)]">ID:</span> <span class="font-mono">${taskId}</span></div>` : null}
      ${title ? html`<div><span class="text-[var(--text-dim)]">제목:</span> ${title}</div>` : null}
      ${notes ? html`<div><span class="text-[var(--text-dim)]">노트:</span> ${notes}</div>` : null}
    </div>
  `
}

function ThinkingDetail({ event }: { event: UnifiedTraceEvent }) {
  if (event.thinkingRedacted) {
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[rgba(192,132,252,0.06)] border border-[rgba(192,132,252,0.15)] text-xs text-[#c084fc] italic">
        이 사고 과정은 비공개 처리되었습니다.
      </div>
    `
  }
  const content = event.thinkingContent ?? ''
  if (!content) return null
  return html`
    <div class="mt-2 px-3 py-2 rounded bg-[rgba(192,132,252,0.04)] border border-[rgba(192,132,252,0.12)]">
      <div class="text-sm leading-relaxed text-[var(--text-body)]">
        <${Markdown} text=${content} />
      </div>
    </div>
  `
}

function OasDetail({ event }: { event: UnifiedTraceEvent }) {
  const d = event.detail

  // ── OAS tool call ──
  if (event.kind === 'oas_tool') {
    const phase = typeof d.phase === 'string' ? d.phase : ''
    const toolName = typeof d.tool_name === 'string' ? d.tool_name : 'unknown'
    const phaseLabel = phase === 'called' ? '호출' : phase === 'completed' ? '완료' : phase
    const phaseColor = phase === 'called' ? 'text-[var(--accent)]' : 'text-[var(--ok)]'
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[var(--white-3)] border border-[var(--white-6)] space-y-1">
        <div class="flex items-center gap-2 text-xs">
          <span class="text-[var(--text-dim)]">단계:</span>
          <span class="font-mono font-semibold ${phaseColor}">${phaseLabel}</span>
        </div>
        <div class="flex items-center gap-2 text-xs">
          <span class="text-[var(--text-dim)]">도구:</span>
          <span class="font-mono text-[var(--text-body)]">${toolName}</span>
        </div>
      </div>
    `
  }

  // ── OAS turn ──
  if (event.kind === 'oas_turn') {
    const phase = typeof d.phase === 'string' ? d.phase : ''
    const turn = d.turn
    const phaseLabel = phase === 'started' ? '시작' : phase === 'completed' ? '완료' : phase
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[var(--white-3)] border border-[var(--white-6)]">
        <div class="flex items-center gap-2 text-xs">
          <span class="text-[var(--text-dim)]">턴 ${turn != null ? String(turn) : '-'}:</span>
          <span class="font-mono font-semibold text-[var(--text-body)]">${phaseLabel}</span>
        </div>
      </div>
    `
  }

  // ── OAS context compaction ──
  if (event.kind === 'oas_context') {
    const before = typeof d.before_tokens === 'number' ? d.before_tokens : null
    const after = typeof d.after_tokens === 'number' ? d.after_tokens : null
    const saved = before != null && after != null ? before - after : null
    const ratio = before != null && after != null && before > 0 ? ((saved ?? 0) / before * 100) : null
    const compactPhase = typeof d.phase === 'string' ? d.phase : ''
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[var(--sky-4)] border border-[rgba(56,189,248,0.15)] space-y-2">
        <div class="flex items-center gap-3 text-xs">
          ${before != null ? html`<span><span class="text-[var(--text-dim)]">Before:</span> <span class="font-mono">${before.toLocaleString()}</span></span>` : null}
          <span class="text-[var(--text-dim)]">→</span>
          ${after != null ? html`<span><span class="text-[var(--text-dim)]">After:</span> <span class="font-mono">${after.toLocaleString()}</span></span>` : null}
        </div>
        ${saved != null && saved > 0 ? html`
          <div class="flex items-center gap-2">
            <${ProgressBar}
              pct=${ratio ?? 0}
              size="md"
              trackTone="muted"
              trackClass="flex-1"
              class="bg-[var(--sky-400)]"
            />
            <span class="text-3xs font-mono text-[var(--sky-400)]">-${saved.toLocaleString()}tok (${(ratio ?? 0).toFixed(0)}%)</span>
          </div>
        ` : null}
        ${compactPhase ? html`<div class="text-3xs text-[var(--text-dim)]">단계: ${compactPhase}</div>` : null}
      </div>
    `
  }

  // ── Lifecycle with durable_kind ──
  const durableKind = typeof d.durable_kind === 'string' ? d.durable_kind : ''

  if (durableKind === 'llm_request') {
    const model = typeof d.model === 'string' ? d.model : 'unknown'
    const inputTokens = typeof d.input_tokens === 'number' ? d.input_tokens : 0
    const turn = d.turn
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[var(--sky-4)] border border-[rgba(56,189,248,0.12)] space-y-1">
        <div class="flex items-center gap-3 text-xs">
          <span><span class="text-[var(--text-dim)]">모델:</span> <span class="font-mono">${model}</span></span>
          <span><span class="text-[var(--text-dim)]">입력:</span> <span class="font-mono">${inputTokens.toLocaleString()}tok</span></span>
          ${turn != null ? html`<span><span class="text-[var(--text-dim)]">턴:</span> <span class="font-mono">${String(turn)}</span></span>` : null}
        </div>
      </div>
    `
  }

  if (durableKind === 'llm_response') {
    const outputTokens = typeof d.output_tokens === 'number' ? d.output_tokens : 0
    const stopReason = typeof d.stop_reason === 'string' ? d.stop_reason : ''
    const durationMs = typeof d.duration_ms === 'number' ? d.duration_ms : null
    const turn = d.turn
    const responseText = typeof d.response_text === 'string' ? d.response_text : ''
    const stopColor = stopReason === 'end_turn' || stopReason === 'stop' ? 'text-[var(--ok)]' : 'text-[var(--warn)]'
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[rgba(34,211,238,0.04)] border border-[var(--cyan-12)] space-y-1">
        <div class="flex items-center gap-3 text-xs flex-wrap">
          <span><span class="text-[var(--text-dim)]">출력:</span> <span class="font-mono">${outputTokens.toLocaleString()}tok</span></span>
          <span><span class="text-[var(--text-dim)]">종료:</span> <span class="font-mono ${stopColor}">${stopReason}</span></span>
          ${durationMs != null ? html`<span><span class="text-[var(--text-dim)]">소요:</span> <span class="font-mono ${durationColor(durationMs)}">${formatDuration(durationMs)}</span></span>` : null}
          ${turn != null ? html`<span><span class="text-[var(--text-dim)]">턴:</span> <span class="font-mono">${String(turn)}</span></span>` : null}
        </div>
        ${responseText ? html`
          <details class="mt-1">
            <summary class="text-3xs text-[var(--text-dim)] cursor-pointer hover:text-[var(--text-body)]">응답 텍스트</summary>
            <pre class="mt-1 p-2 rounded bg-[var(--white-3)] text-2xs font-mono text-[var(--text-body)] whitespace-pre-wrap break-all max-h-75 overflow-auto">${responseText}</pre>
          </details>
        ` : null}
      </div>
    `
  }

  if (durableKind === 'error_occurred') {
    const domain = typeof d.error_domain === 'string' ? d.error_domain : 'unknown'
    const errorDetail = typeof d.detail === 'string' ? d.detail : ''
    return html`
      <div class="mt-2 px-3 py-2 rounded bg-[var(--bad-6)] border border-[var(--bad-soft)] space-y-1">
        <div class="text-xs"><span class="text-[var(--text-dim)]">도메인:</span> <span class="font-mono text-[var(--bad)]">${domain}</span></div>
        ${errorDetail ? html`<div class="text-2xs font-mono text-[var(--text-body)] break-all">${errorDetail}</div>` : null}
      </div>
    `
  }

  // ── Fallback: generic detail rows ──
  const detailRows = Object.entries(d)
    .filter(([, value]) => value != null && value !== '')
    .map(([label, value]) => ({ label, value: typeof value === 'string' ? value : JSON.stringify(value) }))
  if (detailRows.length === 0) return null
  return html`
    <div class="mt-2 grid gap-1.5 px-3 py-2 rounded bg-[var(--white-3)] border border-[var(--white-6)]">
      ${detailRows.map(row => html`
        <div class="flex items-start gap-2 text-xs leading-relaxed">
          <span class="min-w-[92px] text-[var(--text-dim)] font-mono">${row.label}</span>
          <span class="text-[var(--text-body)] font-mono break-all">${row.value}</span>
        </div>
      `)}
    </div>
  `
}

export function SessionTraceEntry({ event, searchQuery }: { event: UnifiedTraceEvent; searchQuery?: string }) {
  const kindStyle = KIND_STYLES[event.kind]
  // For tool_call, use tool-specific icon/color
  // For lifecycle + durable_kind, use durable-specific icon/color
  const durable =
    event.kind === 'lifecycle'
      ? durableStyle(event.detail.durable_kind)
      : null
  const style = event.kind === 'tool_call' && event.toolName
    ? toolStyle(event.toolName)
    : durable ?? kindStyle

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
    || event.kind === 'oas_tool'
    || event.kind === 'oas_turn'
    || event.kind === 'oas_context'
    || (event.kind === 'lifecycle' && event.detail.durable_kind)

  const row = html`
    <div class="flex items-start gap-3 py-2 px-3 rounded ${gateRejected ? 'opacity-50' : ''}">
      ${'' /* Icon */}
      <div class="flex-shrink-0 mt-0.5 size-7 rounded bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-2xs font-mono font-bold ${style.color}">
        ${style.icon}
      </div>

      ${'' /* Content */}
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          ${event.kind === 'tool_call' && event.toolName
            ? html`<span class="text-xs font-mono font-medium ${style.color}">${event.toolName}</span>`
            : html`<span class="text-3xs font-medium uppercase tracking-wider ${kindStyle.color}">${kindStyle.label}</span>`}
          <span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)] uppercase tracking-wider">
            ${event.sourceLane === 'oas' ? 'OAS' : 'MASC'}
          </span>
          ${event.turn != null ? html`
            <span class="text-3xs text-[var(--text-dim)]">
              T${event.turn}${event.round != null ? `R${event.round}` : ''}
            </span>
          ` : null}
          ${event.sessionId ? html`<span class="text-3xs text-[var(--text-dim)] font-mono">S ${event.sessionId}</span>` : null}
          ${event.operationId ? html`<span class="text-3xs text-[var(--text-dim)] font-mono">OP ${event.operationId}</span>` : null}
          ${event.workerRunId ? html`<span class="text-3xs text-[var(--text-dim)] font-mono">WR ${event.workerRunId}</span>` : null}
          ${event.kind === 'task' ? html`
            <span class="text-3xs font-bold uppercase tracking-wider ${taskColor(String(event.detail.type))} bg-[var(--white-5)] px-1.5 py-0.5 rounded">
              ${taskIcon(String(event.detail.type))}
            </span>
          ` : null}
          ${event.error
            ? html`<span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">오류</span>`
            : gateRejected
              ? html`<span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">거부</span>`
              : event.kind === 'tool_call'
                ? html`<span class="text-3xs px-1.5 py-0.5 rounded bg-[rgba(52,211,153,0.1)] text-[var(--ok)]">완료</span>`
                : null}
        </div>
        <div class="mt-0.5 text-2xs text-[var(--text-muted)] font-mono truncate max-w-full" title=${event.summary}>
          <${HighlightedText} text=${summaryText} query=${searchQuery ?? ''} />
        </div>
      </div>

      ${'' /* Right side: duration + time */}
      <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
        ${event.duration_ms != null ? html`
          <span class="text-2xs font-mono ${durationColor(event.duration_ms)}">${formatDuration(event.duration_ms)}</span>
        ` : null}
        <${TimeAgo} timestamp=${event.ts_iso} class="text-3xs text-[var(--text-dim)]" />
      </div>
    </div>
  `

  if (!hasDetail) return row

  return html`
    <details class="rounded hover:bg-[var(--white-3)] transition-colors group" aria-label=${summaryText ?? kindStyle.label}>
      <summary class="list-none cursor-pointer relative pr-8">
        ${row}
        <div class="absolute right-3 top-1/2 -translate-y-1/2 opacity-40 group-hover:opacity-100 transition-opacity">
          <svg aria-hidden="true" class="w-4 h-4 text-[var(--text-muted)] group-open:rotate-90 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        </div>
      </summary>
      <div class="px-3 pb-3 pl-13">
        ${event.kind === 'tool_call' ? html`<${ToolCallDetail} event=${event} />` : null}
        ${event.kind === 'broadcast' ? html`<${BroadcastDetail} event=${event} />` : null}
        ${event.kind === 'task' ? html`<${TaskDetail} event=${event} />` : null}
        ${event.kind === 'thinking' ? html`<${ThinkingDetail} event=${event} />` : null}
        ${event.kind === 'oas_tool' || event.kind === 'oas_turn' || event.kind === 'oas_context'
          || (event.kind === 'lifecycle' && event.detail.durable_kind)
          ? html`<${OasDetail} event=${event} />`
          : null}
      </div>
    </details>
  `
}

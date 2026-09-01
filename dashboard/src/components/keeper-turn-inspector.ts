// Keeper Turn Inspector (RFC-0233 PR-4) — one row per keeper turn from
// GET /api/v1/keepers/:name/turn-records, with the server-computed
// block diff between consecutive turns of the same trace. Answers the
// operator question "which instruction blocks entered, left, or changed
// between turns" without reading source.
//
// v2 refresh: each turn row opens a detail drawer with summary stats,
// token-economics bar, tabbed waterfall, and copyable exact provider input
// styled after keeper-v2 turn-inspector.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchKeeperProviderInput,
  fetchKeeperToolCalls,
  fetchKeeperTurnRecords,
} from '../api/dashboard'
import type {
  MemoryOsFact,
  MemoryOsTurnRecordSnapshot,
  ProviderInputSnapshot,
  ToolCallEntry,
  ToolCallsResponse,
  TurnBlock,
  TurnBlockDiff,
  TurnInputComponent,
  TurnRecordEntry,
  TurnRecordRow,
  TurnRecordsResponse,
  TelemetryFreshnessMetadata,
} from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { formatMsCompact } from '../lib/format-number'
import { LoadingState } from './common/feedback-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { coverageGapDisplay, sourceHealthClass, freshnessText } from './common/source-health'

const INITIAL_TURN_MATCH_WINDOW_SEC = 30 * 60
const EMPTY_TURN_RECORD_ROWS: TurnRecordRow[] = []

export function initialTurnRowForTimestamp(
  rows: TurnRecordRow[],
  timestampIso?: string | null,
): TurnRecordRow | null {
  if (!timestampIso || rows.length === 0) return null
  const targetMs = Date.parse(timestampIso)
  if (!Number.isFinite(targetMs)) return null
  const targetSec = targetMs / 1000
  let best: { row: TurnRecordRow; delta: number } | null = null

  for (const row of rows) {
    const delta = Math.abs(row.record.ts - targetSec)
    if (!best || delta < best.delta) {
      best = { row, delta }
    }
  }

  return best && best.delta <= INITIAL_TURN_MATCH_WINDOW_SEC ? best.row : null
}

// RFC-0233 §7: exact turn join-key match, superseding the 30-min timestamp
// window (§7.6 guard #3). [turnRef] is "<trace_id>#<absolute_turn>" minted
// MASC-side and carried on the originating chat row / board post; split on the
// LAST '#' (a trace_id may itself contain '#') and match trace_id +
// absolute_turn exactly against the server turn records. A malformed key or a
// turn not present in the loaded records returns null — never a fuzzy
// fallback, so an exact key cannot mis-attribute.
export function initialTurnRowForTurnRef(
  rows: TurnRecordRow[],
  turnRef?: string | null,
): TurnRecordRow | null {
  if (!turnRef || rows.length === 0) return null
  const hash = turnRef.lastIndexOf('#')
  if (hash <= 0 || hash === turnRef.length - 1) return null
  const suffix = turnRef.slice(hash + 1)
  if (!/^\d+$/.test(suffix)) return null
  const trace = turnRef.slice(0, hash)
  const turn = Number(suffix)
  return (
    rows.find(
      row => row.record.trace_id === trace && row.record.absolute_turn === turn,
    ) ?? null
  )
}

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  const gap = coverageGapDisplay(data)
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)] v2-monitoring-row">
      <span class="font-mono">${data.source ?? '(unknown source)'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span class="font-mono ${sourceHealthClass(data.health)}">${data.health ?? 'unknown'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span>${freshnessText(data)}</span>
      ${gap ? html`<span class="mx-1" aria-hidden="true">·</span><span>${gap}</span>` : null}
    </div>
  `
}

function BlockRow({ block }: { block: TurnBlock }) {
  return html`
    <div class="flex items-center gap-2 text-2xs font-mono v2-monitoring-row">
      <span class="text-[var(--color-fg-default)]">${block.block}</span>
      <span class="text-[var(--color-fg-muted)]">${block.bytes}B</span>
      <span class="text-[var(--color-fg-disabled)]" title=${block.digest}>
        ${block.digest.slice(0, 12)}
      </span>
    </div>
  `
}

// Bytes label for input components: sub-KB values stay exact so small
// prompt blocks do not all round to "0.0KB".
function formatComponentBytes(bytes: number): string {
  return bytes >= 1024 ? `${(bytes / 1024).toFixed(1)}KB` : `${bytes}B`
}

function sortedInputComponents(record: TurnRecordEntry): TurnInputComponent[] {
  return [...(record.input_components ?? [])].sort((a, b) => b.bytes - a.bytes)
}

function InputComponentRow({
  component,
  totalBytes,
}: {
  component: TurnInputComponent
  totalBytes: number
}) {
  const share = totalBytes > 0 ? Math.round((component.bytes / totalBytes) * 100) : 0
  return html`
    <div class="flex items-center gap-2 text-2xs font-mono v2-monitoring-row">
      <span class="text-[var(--color-fg-default)]">${component.component}</span>
      <span class="text-[var(--color-fg-muted)]">${formatComponentBytes(component.bytes)}</span>
      <span class="text-[var(--color-fg-disabled)]">${share}%</span>
    </div>
  `
}

function latestBlockByName(rows: TurnRecordRow[], blockName: string): TurnBlock | null {
  for (const row of [...rows].reverse()) {
    const block = row.record.blocks.find(item => item.block === blockName)
    if (block) return block
  }
  return null
}

function latestMemoryOsBlock(rows: TurnRecordRow[]): TurnBlock | null {
  return latestBlockByName(rows, 'memory_os_recall')
}

function MemoryOsChangeRow({
  fact,
  kind,
}: {
  fact: MemoryOsFact
  kind: 'added' | 'removed'
}) {
  const marker = kind === 'added' ? '+' : '−'
  const stateClass = kind === 'added'
    ? 'text-[var(--color-status-ok)]'
    : 'text-[var(--color-status-err)]'
  const basis = fact.basis.kind === 'observed'
    ? 'observed'
    : `derived · ${fact.basis.derivations.length} proof(s)`
  return html`
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0 v2-monitoring-row">
      <div class="mb-1 flex min-w-0 flex-wrap items-center gap-2">
        <span class=${`font-mono text-2xs ${stateClass}`}>
          ${marker} ${kind}
        </span>
        <span class="text-3xs font-mono text-[var(--color-fg-muted)]">
          ${fact.memory_id}
        </span>
        <span class="text-3xs font-mono text-[var(--color-fg-muted)]">${basis}</span>
      </div>
      <div class="line-clamp-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${fact.claim}
      </div>
    </div>
  `
}

function MemoryOsInvalidationRow({
  invalidation,
}: {
  invalidation: MemoryOsTurnRecordSnapshot['change']['invalidated'][number]
}) {
  return html`
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0 v2-monitoring-row">
      <div class="mb-1 flex min-w-0 flex-wrap items-center gap-2">
        <span class="font-mono text-2xs text-[var(--color-status-err)]">× support invalidated</span>
        <span class="text-3xs font-mono text-[var(--color-fg-muted)]">
          ${invalidation.fact.memory_id}
        </span>
      </div>
      <div class="line-clamp-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${invalidation.fact.claim}
      </div>
      <div class="mt-1 text-3xs font-mono text-[var(--color-status-err)]">
        missing ${invalidation.missing_premise_ids.join(' · ')}
      </div>
    </div>
  `
}

function MemoryOsRecallSourcePanel({
  snapshot,
  rows,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  rows: TurnRecordRow[]
}) {
  const latestBlock = latestMemoryOsBlock(rows)
  const changes = [
    ...snapshot.change.added.map(fact => ({ fact, kind: 'added' as const })),
    ...snapshot.change.removed.map(fact => ({ fact, kind: 'removed' as const })),
  ]
  const readErrorText = snapshot.read_errors.map(item => `${item.scope}: ${item.error}`).join(' · ')
  const updatedAt = snapshot.updated_at == null
    ? 'fresh state'
    : new Date(snapshot.updated_at * 1000).toISOString()
  const updateSource = snapshot.update_source
    ? `${snapshot.update_source.kind} · ${snapshot.update_source.trace_id}`
    : 'none'

  return html`
    <section
      class="mb-3 border-y border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-3 v2-monitoring-panel"
      data-testid="memory-os-recall-source"
    >
      <div class="flex min-w-0 flex-wrap items-start gap-3 v2-monitoring-toolbar">
        <div class="min-w-0 flex-1">
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">Memory OS recall</div>
          <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">
            ${snapshot.recall_enabled ? 'enabled' : 'disabled'}
            <span class="mx-1" aria-hidden="true">·</span>
            ${latestBlock
              ? html`latest block <span class="font-mono">${latestBlock.bytes}B</span> <span class="font-mono text-[var(--color-fg-disabled)]">${latestBlock.digest.slice(0, 12)}</span>`
              : 'latest block 없음'}
          </div>
        </div>
        <div class="flex flex-wrap gap-2 text-3xs">
          <span class="font-mono text-[var(--color-fg-muted)]">
            revision ${snapshot.revision}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            facts ${snapshot.facts.current}/${snapshot.facts.shown}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            +${snapshot.change.added.length} / −${snapshot.change.removed.length}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            retained ${snapshot.change.retained}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            support invalidated ${snapshot.change.invalidated.length}
          </span>
        </div>
      </div>

      ${readErrorText
        ? html`<div class="mt-2 text-2xs text-[var(--color-status-err)]">${readErrorText}</div>`
        : null}

      <div class="mt-2 divide-y divide-[var(--color-border-muted)] v2-monitoring-row">
        ${changes.length === 0 && snapshot.change.invalidated.length === 0
          ? html`<div class="py-2 text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">latest revision memory change 없음</div>`
          : html`
              ${changes.map(change => html`<${MemoryOsChangeRow}
                key=${`${change.kind}-${change.fact.memory_id}`}
                fact=${change.fact}
                kind=${change.kind}
              />`)}
              ${snapshot.change.invalidated.map(invalidation => html`<${MemoryOsInvalidationRow}
                key=${`invalidated-${invalidation.fact.memory_id}`}
                invalidation=${invalidation}
              />`)}
            `}
      </div>

      <details class="mt-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-detail">
        <summary class="cursor-pointer">current snapshot</summary>
        <div class="mt-1 break-all font-mono">store: ${snapshot.snapshot_store}</div>
        <div class="mt-1 break-all font-mono">updated: ${updatedAt}</div>
        <div class="mt-1 break-all font-mono">source: ${updateSource}</div>
      </details>
    </section>
  `
}

export function KeeperMemoryOsRecallPanel({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)

  useEffect(() => {
    void resource.load(async (signal) => {
      return await fetchKeeperTurnRecords(keeperName, 12, { signal })
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data

  if (resource.state.value.loading) {
    return html`<${LoadingState}>Memory OS recall 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-3 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  if (!response?.memory_os) {
    return html`
      <div class="p-3 text-xs text-[var(--color-fg-muted)] v2-monitoring-panel">
        Memory OS recall source 없음
      </div>
    `
  }

  return html`
    <div class="p-2 v2-monitoring-surface">
      <${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${response.entries} />
    </div>
  `
}

function DiffSection({ diff }: { diff: TurnBlockDiff }) {
  const empty =
    diff.added.length === 0 && diff.removed.length === 0 && diff.changed.length === 0
  if (empty) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">이전 턴과 블록 변화 없음</div>`
  }
  return html`
    <div class="space-y-1 v2-monitoring-row">
      ${diff.added.map(block => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-ok)]">
          <span>+</span>
          <span>${block.block}</span>
          <span class="opacity-70">${block.bytes}B</span>
        </div>
      `)}
      ${diff.removed.map(block => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-err)]">
          <span>−</span>
          <span>${block.block}</span>
          <span class="opacity-70">${block.bytes}B</span>
        </div>
      `)}
      ${diff.changed.map(({ prev, next }) => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-warn)]">
          <span>Δ</span>
          <span>${next.block}</span>
          <span class="opacity-70">${prev.bytes}B → ${next.bytes}B</span>
          <span class="opacity-50" title="${prev.digest} → ${next.digest}">
            ${prev.digest.slice(0, 8)} → ${next.digest.slice(0, 8)}
          </span>
        </div>
      `)}
    </div>
  `
}

/* ═══════════════════════════════════════════════════════════════════════
   Keeper Turn Inspector v2 detail drawer
   ═══════════════════════════════════════════════════════════════════════ */

type TurnPhase = {
  label: string
  kind: 'ctx' | 'reason' | 'tool' | 'gen'
  mono?: boolean
  durationMs: number | null
  durationSource: 'tool_call_log' | 'provider_telemetry' | 'not_recorded'
  // RFC-0233 §10 — time-to-first-token for the gen phase (null when not
  // recorded). Kept separate from durationMs (end-to-end request_latency_ms)
  // so the post-first-chunk decode split is never derived (§9.6 guard).
  ttfrcMs?: number | null
  meta?: string
}

type TurnDetail = {
  traceId: string
  tokIn: number | null
  tokOut: number | null
  // RFC-0233 §8 — null when context_window/price are absent on the record
  // (runtime unknown or operator left runtime.toml unset); render "미상".
  ctxPct: number | null
  contextWindow: number | null
  cost: number | null
  measuredDurationMs: number | null
  maxMeasuredDurationMs: number
  phases: TurnPhase[]
  tools: TurnToolDetail[]
}

type TurnToolDetail = {
  id: string
  toolName: string | null
  durationMs: number | null
  agentSubturn: number | null
}

type TurnInspectorData = {
  turns: TurnRecordsResponse
  toolCalls: ToolCallsResponse | null
  toolCallError: string | null
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function approxTokens(str: string): number {
  return Math.max(1, Math.round(String(str).length / 3.6))
}

function thinkingStateLabel(record: TurnRecordEntry): string {
  if (record.enable_thinking === true) return 'enabled'
  if (record.enable_thinking === false) return 'disabled'
  return 'unknown'
}

function thinkingChipLabel(record: TurnRecordEntry): string {
  if (record.enable_thinking === true) return 'on'
  if (record.enable_thinking === false) return 'off'
  return '—'
}

// lib/types/turn_record.ml:127-135 — the exact-run reference into the keeper's
// raw-trace store. Display only: the run id plus the seq window within it.
function rawTraceRunRefLabel(record: TurnRecordEntry): string {
  const ref = record.raw_trace_run_ref
  if (!ref) return 'n/a'
  return `${ref.worker_run_id} · seq ${ref.start_seq}-${ref.end_seq}`
}

// RFC-0233 §8 — compact "NNNK" form of the runtime's context window, or
// "미상" when the record has no context_window (render absence, not 200K).
function formatCtxWindowK(cw: number | null | undefined): string {
  return cw != null ? `${Math.round(cw / 1000)}K` : '미상'
}

function toolCallIndexByExecutionId(entries: readonly ToolCallEntry[]): Map<string, ToolCallEntry> {
  const index = new Map<string, ToolCallEntry>()
  for (const entry of entries) {
    if (entry.execution_id) index.set(entry.execution_id, entry)
  }
  return index
}

function uniqueNumbers(values: Array<number | null>): number[] {
  return [...new Set(values.filter((value): value is number => typeof value === 'number'))]
    .sort((a, b) => a - b)
}

function formatTurnList(values: number[]): string {
  if (values.length === 0) return '—'
  if (values.length <= 4) return values.map(value => `T${value}`).join(', ')
  return `${values.slice(0, 3).map(value => `T${value}`).join(', ')} +${values.length - 3}`
}

function phaseDurationLabel(phase: TurnPhase): string {
  if (phase.durationMs != null) {
    const base = formatMsCompact(phase.durationMs)
    // RFC-0233 §10 — show time-to-first-token alongside the gen phase's
    // end-to-end duration when ttfrc_ms is recorded. No decode split: the
    // post-first-chunk duration is NOT derived (§9.6 fabrication guard).
    if (phase.kind === 'gen' && phase.ttfrcMs != null) {
      return `${base} · 첫 ${formatMsCompact(phase.ttfrcMs)}`
    }
    return base
  }
  return '측정 없음'
}

function phaseDurationTitle(phase: TurnPhase): string {
  switch (phase.durationSource) {
    case 'tool_call_log':
      return 'duration_ms from /api/v1/keepers/:name/tool-calls'
    case 'provider_telemetry':
      return 'request_latency_ms — provider call wall-clock (Agent Core inference_telemetry)'
    case 'not_recorded':
      return 'duration not recorded for this phase'
  }
}

function measuredPhaseSummary(phases: readonly TurnPhase[]): {
  measuredDurationMs: number | null
  maxMeasuredDurationMs: number
} {
  const durations = phases.flatMap(phase => phase.durationMs == null ? [] : [phase.durationMs])
  return {
    measuredDurationMs: durations.length > 0
      ? durations.reduce((sum, duration) => sum + duration, 0)
      : null,
    maxMeasuredDurationMs: durations.reduce((maximum, duration) => Math.max(maximum, duration), 0),
  }
}

function buildTurnDetail(
  record: TurnRecordEntry,
  toolEntries: readonly ToolCallEntry[],
): TurnDetail {
  const traceId = record.turn_ref
  const tokIn = record.input_tokens ?? null
  const tokOut = record.output_tokens ?? null
  // RFC-0233 §8 — ctx-fill% and cost grounded in runtime.toml-declared facts.
  // context_window is the keeper-resolved effective budget (replaces the
  // hardcoded 200K); prices are USD/1M from the binding (replace Claude $3/$15).
  // Either is null when the record lacks the fact — the view renders "미상".
  const ctxPct =
    tokIn != null && record.context_window != null && record.context_window > 0
      ? (tokIn / record.context_window) * 100
      : null
  const cost =
    tokIn != null &&
      tokOut != null &&
      record.price_input_per_million != null &&
      record.price_output_per_million != null
      ? (tokIn * record.price_input_per_million + tokOut * record.price_output_per_million) / 1e6
      : null
  const toolIndex = toolCallIndexByExecutionId(toolEntries)

  const phases: TurnPhase[] = [{
    label: '컨텍스트 조립',
    kind: 'ctx',
    durationMs: null,
    durationSource: 'not_recorded',
    meta: 'keeper turn pre-dispatch',
  }]
  if (record.enable_thinking === true || record.thinking_budget != null) {
    phases.push({
      label: 'Thinking',
      kind: 'reason',
      durationMs: null,
      durationSource: 'not_recorded',
      meta: record.thinking_budget != null ? `budget ${record.thinking_budget}` : 'enabled',
    })
  }

  const tools = record.execution_ids.map((id): TurnToolDetail => {
    const entry = toolIndex.get(id) ?? null
    return {
      id,
      toolName: entry?.tool ?? null,
      durationMs: entry?.duration_ms ?? null,
      agentSubturn: entry?.turn ?? null,
    }
  })
  tools.forEach(tool => {
    phases.push({
      label: tool.toolName ?? tool.id.slice(0, 24),
      kind: 'tool',
      mono: true,
      durationMs: tool.durationMs,
      durationSource: tool.durationMs != null ? 'tool_call_log' : 'not_recorded',
      meta: [
        tool.agentSubturn != null ? `agent subturn T${tool.agentSubturn}` : null,
        `execution ${tool.id.slice(0, 24)}`,
      ].filter(Boolean).join(' · '),
    })
  })
  phases.push({
    label: '응답 생성',
    kind: 'gen',
    // RFC-0233 §9 — ground the generation phase in Agent Core request_latency_ms
    // (provider call wall-clock). Absent on the error path or before a
    // response existed → render "측정 없음" rather than fabricating a bar.
    durationMs: record.request_latency_ms ?? null,
    durationSource:
      record.request_latency_ms != null ? 'provider_telemetry' : 'not_recorded',
    // RFC-0233 §10 — time-to-first-token. Populated on the streaming path for
    // every provider; null for non-streaming turns and on the error path.
    ttfrcMs: record.ttfrc_ms ?? null,
    meta: (() => {
      if (record.request_latency_ms == null) {
        return 'provider/Agent Core duration is not recorded for this turn'
      }
      if (record.ttfrc_ms != null) {
        return `provider call wall-clock (request_latency_ms) · 첫 토큰 ${formatMsCompact(record.ttfrc_ms)} (ttfrc_ms)`
      }
      return 'provider call wall-clock (request_latency_ms)'
    })(),
  })
  const { measuredDurationMs, maxMeasuredDurationMs } = measuredPhaseSummary(phases)

  return {
    traceId,
    tokIn,
    tokOut,
    ctxPct,
    contextWindow: record.context_window ?? null,
    cost,
    measuredDurationMs,
    maxMeasuredDurationMs,
    phases,
    tools,
  }
}

function CopyBtn({ text, label = '복사' }: { text: string; label?: string }) {
  const [done, setDone] = useState(false)
  const onClick = (e: Event) => {
    e.stopPropagation()
    try {
      void navigator.clipboard?.writeText(text)
    } catch {
      /* ignore */
    }
    setDone(true)
    setTimeout(() => setDone(false), 1200)
  }
  return html`
    <button class="ti-copy ${done ? 'done' : ''}" onClick=${onClick}>
      ${done ? '\u2713 복사됨' : '\u2398 ' + label}
    </button>
  `
}

function CodeCard({ cap, text, htmlContent, tokens }: { cap: string; text: string; htmlContent?: string; tokens?: number }) {
  return html`
    <div class="ti-code">
      <div class="ti-code-h">
        <span class="cap">${cap}</span>
        ${tokens != null ? html`<span class="sz">~${tokens} tok</span>` : null}
        <${CopyBtn} text=${text} />
      </div>
      ${htmlContent
        ? html`<pre dangerouslySetInnerHTML=${{ __html: htmlContent }} />`
        : html`<pre>${text}</pre>`}
    </div>
  `
}

function TimelineTab({ t }: { t: TurnDetail }) {
  const measuredCount = t.phases.filter(p => p.durationMs != null).length
  const unknownCount = t.phases.length - measuredCount
  return html`
    <div class="ti-sec">
      <div class="ti-sec-h">
        <h4>단계별 실측 시간</h4>
        <span class="n">
          ${t.phases.length} 단계 · 실측 ${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : '없음'} · 미측정 ${unknownCount}
        </span>
      </div>
      <div class="ti-wf">
        ${t.phases.map((p, i) => html`
          <div key=${i} class="ti-wf-row">
            <div class="ti-wf-lbl">
              <span class="ti-wf-ico ti-k-${p.kind}"></span>
              <span class="nm ${p.mono ? 'mono' : ''}" title=${p.meta ?? p.label}>${p.label}</span>
            </div>
            <div class="ti-wf-track">
              ${p.durationMs != null && t.maxMeasuredDurationMs > 0
                ? html`
                  <div
                    class=${`ti-wf-bar ti-k-${p.kind}`}
                    title=${phaseDurationTitle(p)}
                    style=${{
                      left: '0',
                      width: `${(p.durationMs / t.maxMeasuredDurationMs) * 100}%`,
                    }}
                  />
                `
                : null}
            </div>
            <span class="ti-wf-dur" title=${phaseDurationTitle(p)}>${phaseDurationLabel(p)}</span>
          </div>
        `)}
      </div>
      <div class="ti-wf-foot">
        <div class="ti-wf-legend">
          <span><i class="ti-k-reason"></i>추론</span>
          <span><i class="ti-k-tool"></i>도구</span>
          <span><i class="ti-k-gen"></i>생성</span>
        </div>
        <span>실측 합계 <b>${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : '없음'}</b></span>
      </div>
    </div>
  `
}

type ProviderInputView =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'loaded'; data: ProviderInputSnapshot }

function toProviderInputView(state: {
  loading: boolean
  error: string | null
  data: ProviderInputSnapshot | null
}): ProviderInputView {
  if (state.error) return { kind: 'error', message: state.error }
  if (state.data) return { kind: 'loaded', data: state.data }
  return { kind: 'loading' }
}

function providerInputContentText(content: unknown): string {
  try {
    return JSON.stringify(content, null, 2) ?? String(content)
  } catch {
    return String(content)
  }
}

function ProviderInputStatus({ input }: { input: ProviderInputView }) {
  if (input.kind === 'loading') {
    return html`
      <div class="text-2xs text-[var(--color-fg-muted)] px-1 pb-1" data-testid="turn-provider-input-loading">
        이 턴의 실제 입력을 불러오는 중…
      </div>
    `
  }
  if (input.kind === 'error') {
    return html`
      <div class="text-2xs text-[var(--color-status-warn)] px-1 pb-1" data-testid="turn-provider-input-error">
        실제 입력을 불러오지 못했습니다 · ${input.message}
      </div>
    `
  }
  return null
}

function MessagesTab({ input }: { input: ProviderInputView }) {
  if (input.kind !== 'loaded') {
    return html`<div class="ti-sec"><${ProviderInputStatus} input=${input} /></div>`
  }
  const snapshot = input.data
  return html`
    <div class="ti-sec">
      <div class="ti-sec-h">
        <h4>실제 전송 메시지</h4>
        <span class="n">${snapshot.messages.length}개 · ${snapshot.turnRef}</span>
      </div>
      <div class="text-3xs text-[var(--color-fg-disabled)] px-1 pb-2" data-testid="turn-provider-wire">
        ${snapshot.wire.provider} / ${snapshot.wire.model} · ${snapshot.wire.httpCodec} ·
        ${snapshot.wire.bodyBytes.toLocaleString()}B · ${snapshot.wire.bodySha256}
      </div>
      <div class="ti-seq-rail" data-testid="turn-provider-messages">
        ${snapshot.messages.map(message => {
          const text = providerInputContentText(message.content)
          return html`
            <div key=${message.index} class="ti-msg">
              <div class="ti-msg-h">
                <span class="ti-msg-role ${message.role}">${message.role}</span>
                <span class="who">전송 메시지</span>
                <span class="seq">#${message.index} · ${message.bytes}B · ${message.sha256.slice(0, 12)}</span>
              </div>
              <${CodeCard} cap="정규화된 메시지 JSON" text=${text} tokens=${approxTokens(text)} />
            </div>
          `
        })}
      </div>
    </div>
  `
}

function ContextTab({ input }: { input: ProviderInputView }) {
  if (input.kind !== 'loaded') {
    return html`<div class="ti-sec"><${ProviderInputStatus} input=${input} /></div>`
  }
  const snapshot = input.data
  const systemPrompt = snapshot.systemPrompt
  return html`
    <div class="ti-sec">
      <div class="ti-ctx-card">
        <div class="ti-ctx-h">
          <span class="t">실제 시스템 프롬프트</span>
          ${systemPrompt
            ? html`<span class="tok">${systemPrompt.bytes}B · ${systemPrompt.sha256.slice(0, 12)}</span>`
            : html`<span class="tok">없음</span>`}
          ${systemPrompt ? html`<${CopyBtn} text=${systemPrompt.text} />` : null}
        </div>
        ${systemPrompt
          ? html`<pre data-testid="turn-provider-system-prompt">${systemPrompt.text}</pre>`
          : html`<div class="ti-msg-b ti-msg-absent" data-testid="turn-provider-system-prompt-absent">
              이 요청에는 별도의 시스템 프롬프트가 없습니다
            </div>`}
      </div>
    </div>
    <div class="ti-sec">
      <div class="ti-sec-h">
        <h4>실제 도구 스키마</h4>
        <span class="n">${snapshot.toolSchemas.length}개</span>
      </div>
      ${snapshot.toolSchemas.length
        ? snapshot.toolSchemas.map(tool => {
          const text = providerInputContentText(tool.content)
          return html`
            <${CodeCard}
              key=${tool.index}
              cap=${`#${tool.index} ${tool.name} · ${tool.bytes}B · ${tool.sha256.slice(0, 12)}`}
              text=${text}
              tokens=${approxTokens(text)}
            />
          `
        })
        : html`<div class="ti-msg-b ti-msg-absent" data-testid="turn-provider-tool-schemas-absent">
            이 요청에 전송된 도구 스키마가 없습니다
          </div>`}
    </div>
  `
}

function MetaTab({ record, t, source }: { record: TurnRecordEntry; t: TurnDetail; source: string }) {
  return html`
    <div class="ti-sec">
      <div class="ti-sec-h"><h4>샘플링 파라미터</h4></div>
      <div class="ti-params">
        <span class="ti-param">temperature<b>${record.temperature ?? '—'}</b></span>
        <span class="ti-param">top_p<b>${record.top_p ?? '—'}</b></span>
        <span class="ti-param">max_tokens<b>${record.max_tokens?.toLocaleString() ?? '—'}</b></span>
        <span class="ti-param">thinking_budget<b>${record.thinking_budget ?? '—'}</b></span>
        <span class="ti-param">enable_thinking<b>${thinkingChipLabel(record)}</b></span>
      </div>
      <div class="ti-sec-h" style=${{ marginTop: '16px' }}><h4>실행 메타데이터</h4></div>
      <div class="ti-kv">
        <span class="k">selected model</span><span class="v">${record.selected_model ?? 'n/a'}</span>
        <span class="k">runtime</span><span class="v">${record.runtime_profile}</span>
        <span class="k">fsm.state</span><span class="v">n/a</span>
        <span class="k">input tokens</span><span class="v">${t.tokIn?.toLocaleString() ?? '미상'}</span>
        <span class="k">output tokens</span><span class="v">${t.tokOut?.toLocaleString() ?? '미상'}</span>
        <span class="k">cache read tokens</span><span class="v">${record.cache_read_input_tokens?.toLocaleString() ?? '미상'}</span>
        <span class="k">cache write tokens</span><span class="v">${record.cache_creation_input_tokens?.toLocaleString() ?? '미상'}</span>
        <span class="k">ctx window${record.context_window != null ? '' : ' · 미상'}</span><span class="v">${t.ctxPct != null ? `${t.ctxPct.toFixed(1)}% / ${record.context_window?.toLocaleString() ?? '미상'}` : '미상'}</span>
        <span class="k">keeper turn</span><span class="v">T${record.absolute_turn}</span>
        <span class="k">agent subturns</span><span class="v">${formatTurnList(uniqueNumbers(t.tools.map(tool => tool.agentSubturn)))}</span>
        <span class="k">thinking</span><span class="v">${thinkingStateLabel(record)}</span>
        <span class="k">tool calls</span><span class="v">${t.tools.length}</span>
        <span class="k">measured phase duration</span><span class="v">${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : 'none'}</span>
        <span class="k">est. cost${record.price_input_per_million != null ? '' : ' · 가격 미구성'}</span><span class="v">${t.cost != null ? `$${t.cost.toFixed(3)}` : '미상'}</span>
        <span class="k">finish_reason</span><span class="v">${record.finish_reason ?? 'n/a'}</span>
        <span class="k">raw trace</span><span class="v" title=${record.raw_trace_run_ref?.path ?? undefined}>${rawTraceRunRefLabel(record)}</span>
        <span class="k">source</span><span class="v">${source}</span>
      </div>
    </div>
  `
}

const TABS: [string, string][] = [
  ['timeline', '타임라인'],
  ['messages', '메시지'],
  ['context', '컨텍스트'],
  ['meta', '메타'],
]

function TurnDetailDrawer({
  keeperName,
  row,
  source,
  toolEntries,
  toolCallError,
  onClose,
}: {
  keeperName: string
  row: TurnRecordRow
  source: string
  toolEntries: readonly ToolCallEntry[]
  toolCallError: string | null
  onClose: () => void
}) {
  const [tab, setTab] = useState('timeline')
  const t = buildTurnDetail(row.record, toolEntries)
  const tokenCounts =
    t.tokIn != null && t.tokOut != null
      ? { input: t.tokIn, output: t.tokOut, total: t.tokIn + t.tokOut }
      : null

  // Fetch only the selected turn's canonical provider input. The endpoint is
  // keyed by the exact turn_ref carried by the TurnRecord; a mismatched
  // response is rejected instead of being shown under the selected turn.
  const turnRef = row.record.turn_ref
  const providerInputResource = useManagedAsyncResource<ProviderInputSnapshot>(null)
  useEffect(() => {
    providerInputResource.reset()
    void providerInputResource.load(async (signal) => {
      const snapshot = await fetchKeeperProviderInput(keeperName, turnRef, { signal })
      if (snapshot.keeper !== keeperName || snapshot.turnRef !== turnRef) {
        throw new Error('provider-input이 선택한 keeper 턴과 일치하지 않습니다')
      }
      return snapshot
    })
    return () => {
      providerInputResource.cancel()
    }
  }, [keeperName, turnRef, providerInputResource])

  const providerInput = toProviderInputView(providerInputResource.state.value)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return html`
    <div
      class="ti-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="턴 상세"
      onClick=${onClose}
      data-testid="turn-detail-drawer"
    >
      <div class="ti-drawer" onClick=${(e: Event) => e.stopPropagation()}>
        <div class="ti-head">
          <h3>턴 상세</h3>
          <span class="tid mono">${t.traceId}</span>
          <div class="ti-head-actions">
            <${CopyBtn} text=${t.traceId} label="ID" />
            <button class="ti-close" onClick=${onClose} title="닫기 (Esc)">\u2715</button>
          </div>
        </div>

        <div class="ti-sub">
          <span class="ti-chip">
            <span class="sub-k">keeper</span>${keeperName}
          </span>
          <span class="ti-chip">
            <span class="sub-k">keeper turn</span>T${row.record.absolute_turn}
          </span>
          <span class="ti-chip">
            <span class="sub-k">agent subturns</span>${formatTurnList(uniqueNumbers(t.tools.map(tool => tool.agentSubturn)))}
          </span>
          <span class="ti-chip">
            <span class="sub-k">thinking</span>${thinkingChipLabel(row.record)}
          </span>
          <span class="ti-chip${row.record.finish_reason ? ' ok' : ''}">
            <span class="sub-k">finish</span>${row.record.finish_reason ?? 'n/a'}
          </span>
          <span class="ti-chip">
            <span class="sub-k">runtime</span>${row.record.runtime_profile}
          </span>
        </div>

        ${toolCallError
          ? html`
            <div
              class="mt-2 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--color-bg-surface)] px-2 py-1.5 text-2xs text-[var(--color-status-warn)]"
              data-testid="turn-timing-source-warning"
            >
              tool-call timing source unavailable · ${toolCallError}
            </div>
          `
          : null}

        <div class="ti-summary" data-testid="turn-summary-stats">
          <div class="ti-stat">
            <div class="k">실측</div>
            <div class="v">${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : '—'}</div>
          </div>
          <div class="ti-stat">
            <div class="k">입력</div>
            <div class="v">${t.tokIn != null ? html`${(t.tokIn / 1000).toFixed(1)}<small>k</small>` : '미상'}</div>
          </div>
          <div class="ti-stat">
            <div class="k">출력</div>
            <div class="v volt">${t.tokOut?.toLocaleString() ?? '미상'}</div>
          </div>
          <div class="ti-stat">
            <div class="k">도구</div>
            <div class="v">${t.tools.length}</div>
          </div>
          <div class="ti-stat">
            <div class="k">추정비용</div>
            <div class="v ok">${t.cost != null ? `$${t.cost.toFixed(2)}` : '미상'}</div>
          </div>
        </div>

        <div class="ti-tok" data-testid="turn-token-bar">
          <div class="ti-tok-top">
            <span class="lbl">토큰 경제</span>
            <span class="ctxpct">${t.ctxPct != null ? `컨텍스트 ${t.ctxPct.toFixed(1)}% / ${formatCtxWindowK(t.contextWindow)}` : '컨텍스트 미상'}</span>
          </div>
          <div class="ti-tok-bar">
            ${tokenCounts != null && tokenCounts.total > 0
              ? html`
                <span
                  class="seg-in"
                  style=${{ width: `${(tokenCounts.input / tokenCounts.total) * 100}%` }}
                />
                <span
                  class="seg-out"
                  style=${{ width: `${(tokenCounts.output / tokenCounts.total) * 100}%` }}
                />
              `
              : html`<span data-testid="turn-token-bar-unobserved">${tokenCounts == null ? '측정 없음' : '0 tokens'}</span>`}
          </div>
          <div class="ti-tok-legend">
            <span class="in"><i></i>입력 <b>${t.tokIn?.toLocaleString() ?? '미상'}</b></span>
            <span class="out"><i></i>출력 <b>${t.tokOut?.toLocaleString() ?? '미상'}</b></span>
          </div>
        </div>

        <div class="ti-tabs" role="tablist" aria-label="턴 상세 탭">
          ${TABS.map(([id, lbl]) => html`
            <button
              key=${id}
              role="tab"
              aria-selected=${tab === id}
              class="ti-tab ${tab === id ? 'on' : ''}"
              onClick=${() => setTab(id)}
              data-testid="turn-tab-${id}"
            >
              ${lbl}
            </button>
          `)}
        </div>

        <div class="ti-body">
          ${tab === 'timeline' && html`<${TimelineTab} t=${t} />`}
          ${tab === 'messages' && html`<${MessagesTab} input=${providerInput} />`}
          ${tab === 'context' && html`<${ContextTab} input=${providerInput} />`}
          ${tab === 'meta' && html`<${MetaTab} record=${row.record} t=${t} source=${source} />`}
        </div>
      </div>
    </div>
  `
}

function TurnRow({
  row,
  onOpen,
}: {
  row: TurnRecordRow
  onOpen: (row: TurnRecordRow) => void
}) {
  const record = row.record
  const tokens =
    record.input_tokens != null || record.output_tokens != null
      ? `${record.input_tokens ?? '?'}→${record.output_tokens ?? '?'} tok`
      : null
  const sampling = [
    record.temperature != null ? `t=${record.temperature}` : null,
    record.top_p != null ? `p=${record.top_p}` : null,
    record.max_tokens != null ? `tok=${record.max_tokens}` : null,
    record.thinking_budget != null ? `think=${record.thinking_budget}` : null,
    record.enable_thinking === false ? 'no-think' : null,
  ].filter(Boolean)

  return html`
    <details class="rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors v2-monitoring-row">
      <summary
        class="ti-turn-summary list-none cursor-pointer flex items-center gap-2 py-1.5 px-2 flex-wrap"
        onClick=${(e: Event) => {
          // Only open the drawer on direct summary clicks, not on the expand chevron area.
          if (e.target === e.currentTarget || (e.target as HTMLElement).closest('.ti-turn-summary') === e.currentTarget) {
            onOpen(row)
          }
        }}
      >
        <span class="text-xs font-mono font-medium text-[var(--color-fg-default)]">
          T${record.absolute_turn}
        </span>
        <span class="text-3xs text-[var(--color-fg-disabled)]">${formatTimeHms(record.ts)}</span>
        <span class="text-3xs font-mono text-[var(--color-fg-muted)]">${record.runtime_profile}</span>
        ${tokens ? html`<span class="text-3xs font-mono text-[var(--color-fg-muted)]">${tokens}</span>` : null}
        ${sampling.length > 0
          ? html`<span class="text-3xs font-mono text-[var(--color-fg-disabled)]">${sampling.join(' ')}</span>`
          : null}
        <span class="text-3xs text-[var(--color-fg-disabled)]">
          블록 ${record.blocks.length} · 도구 ${record.execution_ids.length}
        </span>
        ${row.diff_vs_prev
          && (row.diff_vs_prev.added.length > 0
            || row.diff_vs_prev.removed.length > 0
            || row.diff_vs_prev.changed.length > 0)
          ? html`<span class="text-3xs font-mono text-[var(--color-status-warn)]">
              +${row.diff_vs_prev.added.length} −${row.diff_vs_prev.removed.length} Δ${row.diff_vs_prev.changed.length}
            </span>`
          : null}
        <span class="open-hint">턴 상세</span>
      </summary>
      <div class="px-3 pb-2 space-y-2 v2-monitoring-panel">
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            컨텍스트 블록 (조립 순서)
          </div>
          ${record.blocks.length === 0
            ? html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">기록된 블록 없음</div>`
            : record.blocks.map(block => html`<${BlockRow} block=${block} />`)}
        </div>
        ${(() => {
          // Rendered outside the composition panel: input_components can be
          // absent on a turn whose window observation succeeded (they come from
          // two independent observations), and nesting this inside it hid the
          // number on exactly those turns.
          const transmitted = record.transmitted_atoms
          const total = record.total_atoms
          if (transmitted == null || total == null || total <= 0) return null
          // Built as concatenation so the html template holds no nested literal.
          const label =
            '이력 '
            + transmitted.toLocaleString()
            + ' / '
            + total.toLocaleString()
            + ' atom ('
            + ((transmitted / total) * 100).toFixed(1)
            + '% 전송)'
          // A turn measured against the durable shape budgeted for reasoning
          // the wire deletes, so its window is narrower than it needed to be.
          // Said here because the count alone reads as an ordinary bad turn.
          const declined = record.model_input_measurement === 'durable_shape'
          return html`
            <div data-testid="turn-transmitted-atoms" class="flex items-center gap-2 text-2xs font-mono v2-monitoring-row">
              <span class="text-[var(--color-fg-muted)]">${label}</span>
              ${declined
                ? html`<span data-testid="turn-measurement-declined" class="text-[var(--color-status-warn)]">· 체크포인트 형태로 측정 (전송되지 않는 reasoning 포함)</span>`
                : null}
            </div>
          `
        })()}
        ${record.input_components && record.input_components.length > 0
          ? (() => {
              const components = sortedInputComponents(record)
              const totalBytes = components.reduce((sum, c) => sum + c.bytes, 0)
              return html`
                <div data-testid="turn-input-components">
                  <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
                    입력 구성 (요청 조립 뷰, 큰 순)
                  </div>
                  ${components.map(component =>
                    html`<${InputComponentRow} component=${component} totalBytes=${totalBytes} />`)}
                  <div class="flex items-center gap-2 text-2xs font-mono v2-monitoring-row">
                    <span class="text-[var(--color-fg-muted)]">합계 ${formatComponentBytes(totalBytes)}</span>
                    ${record.request_body_bytes != null
                      ? html`<span class="text-[var(--color-fg-disabled)]">· wire ${formatComponentBytes(record.request_body_bytes)} (방언 투영 후 실제 요청 본문)</span>`
                      : null}
                  </div>
                </div>
              `
            })()
          : null}
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            이전 턴 대비
          </div>
          ${row.diff_vs_prev
            ? html`<${DiffSection} diff=${row.diff_vs_prev} />`
            : html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">같은 trace의 이전 턴 없음</div>`}
        </div>
        ${record.execution_ids.length > 0
          ? html`
            <div>
              <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
                execution_ids
              </div>
              <div class="text-2xs font-mono text-[var(--color-fg-muted)] break-all v2-monitoring-row">
                ${record.execution_ids.join(', ')}
              </div>
            </div>
          `
          : null}
      </div>
    </details>
  `
}

export function KeeperTurnInspector({
  keeperName,
  initialTurnTimestamp,
  initialTurnRef,
}: {
  keeperName: string
  initialTurnTimestamp?: string | null
  // RFC-0233 §7: exact turn join key from the originating chat row / board
  // post. When present it supersedes [initialTurnTimestamp] (exact match, no
  // window). Callers thread it as the turn_ref data flows (PR-C / follow-up).
  initialTurnRef?: string | null
}) {
  const resource = useManagedAsyncResource<TurnInspectorData | null>(null)
  const [selectedRow, setSelectedRow] = useState<TurnRecordRow | null>(null)
  const [initialMatchState, setInitialMatchState] = useState<'idle' | 'matched' | 'missed'>('idle')
  const appliedInitialTurnKey = useRef<string | null>(null)

  useEffect(() => {
    void resource.load(async (signal) => {
      const [turns, toolCalls] = await Promise.all([
        fetchKeeperTurnRecords(keeperName, 50, { signal }),
        fetchKeeperToolCalls(keeperName, 200, { signal }).then(
          toolCalls => ({ toolCalls, toolCallError: null }),
          error => ({ toolCalls: null, toolCallError: errorMessage(error) }),
        ),
      ])
      return { turns, toolCalls: toolCalls.toolCalls, toolCallError: toolCalls.toolCallError }
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data?.turns
  const toolEntries = resource.state.value.data?.toolCalls?.entries ?? []
  const toolCallError = resource.state.value.data?.toolCallError ?? null
  const rows = response?.entries ?? EMPTY_TURN_RECORD_ROWS
  // Server returns oldest-first; show newest first.
  const sorted = useMemo(() => [...rows].reverse(), [rows])
  const initialMatchedRow = useMemo(() => {
    const exact = initialTurnRowForTurnRef(rows, initialTurnRef)
    if (exact) return exact
    // WORKAROUND (RFC-0233 §7.6 #3): legacy chat rows / board posts carry no
    // turn_ref, so fall back to the 30-min timestamp window for those only.
    // When a turn_ref IS present, a miss stays null — no fuzzy attribution.
    // removal target: turn_ref backfilled onto persisted rows + populated by
    // every producer (RFC-0233 follow-up).
    if (initialTurnRef) return null
    return initialTurnRowForTimestamp(rows, initialTurnTimestamp)
  }, [rows, initialTurnRef, initialTurnTimestamp])

  // Identity of the requested turn: the exact join key when available, else the
  // timestamp. Drives the apply-once tracking below so either entry point works.
  const initialTurnKey = initialTurnRef ?? initialTurnTimestamp ?? null

  useEffect(() => {
    appliedInitialTurnKey.current = null
    setInitialMatchState('idle')
    setSelectedRow(null)
  }, [keeperName, initialTurnKey])

  useEffect(() => {
    if (
      !initialTurnKey
      || rows.length === 0
      || appliedInitialTurnKey.current === initialTurnKey
    ) {
      return
    }

    setSelectedRow(initialMatchedRow)
    setInitialMatchState(initialMatchedRow ? 'matched' : 'missed')
    appliedInitialTurnKey.current = initialTurnKey
  }, [initialTurnKey, initialMatchedRow, rows.length])

  if (resource.state.value.loading) {
    return html`<${LoadingState}>턴 레코드 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-4 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  const memoryOsPanel = response?.memory_os
    ? html`<${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${rows} />`
    : null

  if (rows.length === 0) {
    return html`
      <div class="p-4 space-y-1 v2-monitoring-panel">
        ${memoryOsPanel}
        ${response?.health === 'incompatible'
          ? html`<div class="text-xs text-[var(--color-status-warn)]">
              current decoder가 최근 ${response.skipped_rows}행을 모두 거부했습니다
            </div>`
          : html`<div class="text-xs text-[var(--color-fg-muted)]">턴 레코드 없음 (서버 재시작 이후 keeper 턴까지 기록됩니다)</div>`}
        <${FreshnessLine} data=${response ?? { source: 'turn_record' }} />
      </div>
    `
  }

  return html`
    <div class="p-2 space-y-1 v2-monitoring-surface">
      <div class="flex items-center justify-between px-1 v2-monitoring-toolbar">
        <${FreshnessLine} data=${response} />
        ${response && response.skipped_rows > 0
          ? html`<span class="text-3xs text-[var(--color-status-warn)]">
              malformed ${response.skipped_rows}행 제외됨
            </span>`
          : null}
        ${toolCallError
          ? html`<span class="text-3xs text-[var(--color-status-warn)]" data-testid="turn-timing-source-warning">
              tool-call timing source unavailable
            </span>`
          : null}
      </div>
      ${memoryOsPanel}
      ${initialMatchState === 'missed'
        ? html`
          <div
            class="rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--color-bg-surface)] px-2 py-1.5 text-2xs text-[var(--color-fg-muted)] v2-monitoring-row"
            data-testid="turn-linked-empty"
          >
            ${initialTurnRef
              ? '연결된 turn record를 찾지 못했습니다. 리스트에서 직접 선택하세요.'
              : '메시지 시각과 30분 이내의 turn record 없음. 리스트에서 직접 선택하세요.'}
          </div>
        `
        : null}
      ${sorted.map(row => html`<${TurnRow}
        key=${`${row.record.trace_id}-${row.record.absolute_turn}-${row.record.ts}`}
        row=${row}
        onOpen=${setSelectedRow}
      />`)}
      ${selectedRow
        ? html`<${TurnDetailDrawer}
            keeperName=${keeperName}
            row=${selectedRow}
            source=${response?.source ?? 'turn_record'}
            toolEntries=${toolEntries}
            toolCallError=${toolCallError}
            onClose=${() => setSelectedRow(null)}
          />`
        : null}
    </div>
  `
}

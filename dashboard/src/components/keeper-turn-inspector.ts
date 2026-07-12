// Keeper Turn Inspector (RFC-0233 PR-4) — one row per keeper turn from
// GET /api/v1/keepers/:name/turn-records, with the server-computed
// block diff between consecutive turns of the same trace. Answers the
// operator question "which instruction blocks entered, left, or changed
// between turns" without reading source.
//
// v2 refresh: each turn row opens a detail drawer with summary stats,
// token-economics bar, tabbed waterfall, structured transcript, and
// copyable context blocks styled after keeper-v2 turn-inspector.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchKeeperToolCalls,
  fetchKeeperTurnRecords,
  fetchKeeperTurnTranscript,
} from '../api/dashboard'
import type {
  KeeperUserModelItem,
  KeeperUserModelSnapshot,
  MemoryOsEpisodeSummary,
  MemoryOsTurnRecordSnapshot,
  ToolCallEntry,
  ToolCallOutputBlob,
  ToolCallsResponse,
  TurnBlock,
  TurnBlockDiff,
  TurnRecordEntry,
  TurnRecordRow,
  TurnRecordsResponse,
  TurnTranscript,
  TurnTranscriptLine,
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

function latestUserModelBlock(rows: TurnRecordRow[]): TurnBlock | null {
  return latestBlockByName(rows, 'user_model')
}

function compactIso(value: string | null): string {
  if (!value) return 'none'
  return value.replace('T', ' ').replace(/Z$/, 'Z')
}

function episodeTtlLabel(episode: MemoryOsEpisodeSummary): string {
  if (!episode.valid_until_iso) return 'no TTL'
  return episode.current
    ? `until ${compactIso(episode.valid_until_iso)}`
    : `expired ${compactIso(episode.valid_until_iso)}`
}

function MemoryOsEpisodeRow({ episode }: { episode: MemoryOsEpisodeSummary }) {
  return html`
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0 v2-monitoring-row">
      <div class="mb-1 flex min-w-0 flex-wrap items-center gap-2">
        <span class="font-mono text-2xs text-[var(--color-fg-default)]">
          ${episode.trace_id} g${episode.generation.toString().padStart(4, '0')}
        </span>
        <span class="text-3xs font-mono ${episode.current ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-warn)]'}">
          ${episodeTtlLabel(episode)}
        </span>
        ${episode.terminal_marker
          ? html`<span class="rounded-[var(--r-1)] bg-[var(--accent-12)] px-1.5 py-0.5 text-3xs font-mono text-[var(--color-accent-fg)]">
              terminal=${episode.terminal_marker}
            </span>`
          : null}
        <span class="text-3xs text-[var(--color-fg-disabled)]">${episode.claim_count} claims</span>
      </div>
      <div class="line-clamp-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${episode.summary}
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
  const episodes = [...snapshot.episodes.items].reverse().slice(0, 5)
  const readErrorText = snapshot.read_errors.map(item => `${item.scope}: ${item.error}`).join(' · ')

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
            ep ${snapshot.episodes.current}/${snapshot.episodes.shown}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            expired ${snapshot.episodes.expired}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            terminal ${snapshot.episodes.terminal_markers}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            facts ${snapshot.facts.current}/${snapshot.facts.shown}
          </span>
        </div>
      </div>

      ${readErrorText
        ? html`<div class="mt-2 text-2xs text-[var(--color-status-err)]">${readErrorText}</div>`
        : null}

      <div class="mt-2 divide-y divide-[var(--color-border-muted)] v2-monitoring-row">
        ${episodes.length === 0
          ? html`<div class="py-2 text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">recent episodes 없음</div>`
          : episodes.map(episode => html`<${MemoryOsEpisodeRow} key=${`${episode.trace_id}-${episode.generation}-${episode.created_at}`} episode=${episode} />`)}
      </div>

      <details class="mt-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-detail">
        <summary class="cursor-pointer">stores</summary>
        <div class="mt-1 break-all font-mono">facts: ${snapshot.facts_store}</div>
        <div class="mt-1 break-all font-mono">episodes: ${snapshot.episodes_store}</div>
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

function userModelSourceLabel(item: KeeperUserModelItem): string {
  if (item.source !== 'shared') return item.source
  return item.observed_by.length > 0
    ? `shared via ${item.observed_by.join(',')}`
    : 'shared'
}

function UserModelItemRow({ item }: { item: KeeperUserModelItem }) {
  return html`
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0 v2-monitoring-row">
      <div class="mb-1 flex min-w-0 flex-wrap items-center gap-2">
        <span class="font-mono text-3xs text-[var(--color-fg-muted)]">
          ${userModelSourceLabel(item)}
        </span>
        <span class="font-mono text-3xs text-[var(--color-fg-disabled)]">
          ${item.category} turn=${item.turn}
        </span>
        ${item.last_verified_at_iso
          ? html`<span class="font-mono text-3xs text-[var(--color-fg-disabled)]">
              verified ${compactIso(item.last_verified_at_iso)}
            </span>`
          : null}
      </div>
      <div class="line-clamp-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${item.claim}
      </div>
    </div>
  `
}

function UserModelList({
  title,
  items,
}: {
  title: string
  items: KeeperUserModelItem[]
}) {
  const shown = items.slice(0, 5)
  return html`
    <div class="min-w-0 flex-1">
      <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
        ${title} ${items.length}
      </div>
      <div class="divide-y divide-[var(--color-border-muted)] v2-monitoring-row">
        ${shown.length === 0
          ? html`<div class="py-2 text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">기록 없음</div>`
          : shown.map(item => html`<${UserModelItemRow} key=${`${item.source}-${item.turn}-${item.claim}`} item=${item} />`)}
      </div>
    </div>
  `
}

function UserModelSourcePanel({
  snapshot,
  rows,
}: {
  snapshot: KeeperUserModelSnapshot
  rows: TurnRecordRow[]
}) {
  const latestBlock = latestUserModelBlock(rows)
  const readErrorText = snapshot.read_errors.map(item => `${item.scope}: ${item.error}`).join(' · ')

  return html`
    <section
      class="mb-3 border-y border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-3 v2-monitoring-panel"
      data-testid="user-model-source"
    >
      <div class="flex min-w-0 flex-wrap items-start gap-3 v2-monitoring-toolbar">
        <div class="min-w-0 flex-1">
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">User model</div>
          <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">
            ${snapshot.enabled ? 'enabled' : 'disabled'}
            <span class="mx-1" aria-hidden="true">·</span>
            ${latestBlock
              ? html`latest block <span class="font-mono">${latestBlock.bytes}B</span> <span class="font-mono text-[var(--color-fg-disabled)]">${latestBlock.digest.slice(0, 12)}</span>`
              : 'latest block 없음'}
          </div>
        </div>
        <div class="flex flex-wrap gap-2 text-3xs">
          <span class="font-mono text-[var(--color-fg-muted)]">
            pref ${snapshot.preferences.length}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            constraints ${snapshot.constraints.length}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            facts ${snapshot.source_fact_count}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            shared ${snapshot.shared_fact_count}
          </span>
        </div>
      </div>

      ${readErrorText
        ? html`<div class="mt-2 text-2xs text-[var(--color-status-err)]">${readErrorText}</div>`
        : null}

      <div class="mt-2 grid gap-3 md:grid-cols-2">
        <${UserModelList} title="Preferences" items=${snapshot.preferences} />
        <${UserModelList} title="Constraints" items=${snapshot.constraints} />
      </div>

      <details class="mt-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-detail">
        <summary class="cursor-pointer">stores</summary>
        <div class="mt-1 break-all font-mono">facts: ${snapshot.facts_store}</div>
        <div class="mt-1 break-all font-mono">shared: ${snapshot.shared_facts_store}</div>
      </details>
    </section>
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
  durationSource: 'tool_call_log' | 'provider_telemetry' | 'estimated' | 'not_recorded'
  // RFC-0233 §10 — time-to-first-token for the gen phase (null when not
  // recorded). Kept separate from durationMs (end-to-end request_latency_ms)
  // so the post-first-chunk decode split is never derived (§9.6 guard).
  ttfrcMs?: number | null
  visualDurationMs: number
  visualOffsetMs: number
  meta?: string
}

type TurnDetail = {
  traceId: string
  tokIn: number
  tokOut: number
  // RFC-0233 §8 — null when context_window/price are absent on the record
  // (runtime unknown or operator left runtime.toml unset); render "미상".
  ctxPct: number | null
  contextWindow: number | null
  cost: number | null
  measuredDurationMs: number | null
  visualTotalMs: number
  phases: TurnPhase[]
  tools: TurnToolDetail[]
  systemPrompt: string
  injectedCtx: string
}

type TurnToolDetail = {
  id: string
  toolName: string | null
  status: 'ok' | 'bad' | 'unknown'
  durationMs: number | null
  agentSubturn: number | null
  keeperTurn: number | null
  // RFC-0233 §1.1: the real tool call I/O, joined from the tool-call log on
  // execution_id (already boundary-redacted at write in keeper_tool_call_log).
  // [matched] is false when no tool-call entry carried this execution id —
  // the inspector renders explicit absence, never a fabricated result.
  matched: boolean
  input: unknown
  output: string | ToolCallOutputBlob | null
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

function buildSystemPrompt(keeperName: string, record: TurnRecordEntry): string {
  return `당신은 MASC 코디네이션 서버의 keeper "${keeperName}" 입니다.
runtime · profile : ${record.runtime_profile}
absolute turn     : T${record.absolute_turn}
trace id          : ${record.trace_id}

원칙
- 모든 작업은 trace 로 기록한다.
- 컨텍스트 사용량이 85% 를 넘으면 compact() 를 호출한다.
- 소유하지 않은 태스크는 핸드오프(HandingOff)로 넘긴다.
- 답변은 근거(도구 결과·trace)를 함께 제시한다.`
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

// RFC-0233 §8 — compact "NNNK" form of the runtime's context window, or
// "미상" when the record has no context_window (render absence, not 200K).
function formatCtxWindowK(cw: number | null | undefined): string {
  return cw != null ? `${Math.round(cw / 1000)}K` : '미상'
}

function buildInjectedCtx(record: TurnRecordEntry, ctxPct: number | null, tokIn: number): string {
  const ctxLine = ctxPct != null
    ? `${ctxPct.toFixed(1)}%   (${tokIn.toLocaleString()} / ${record.context_window?.toLocaleString() ?? '미상'} tok)`
    : `미상   (${tokIn.toLocaleString()} / 미상 tok, runtime 미구성)`
  return `# world snapshot
fsm.state      = n/a
model          = ${record.model ?? 'n/a'}
finish_reason  = ${record.finish_reason ?? 'n/a'}
ctx.window     = ${ctxLine}
keeper.turn    = T${record.absolute_turn}
thinking       = ${thinkingStateLabel(record)}
thinking.budget= ${record.thinking_budget ?? '—'}

# context blocks (조립 순서)
${record.blocks.length
    ? record.blocks.map(b => `  - ${b.block}  ${b.bytes}B  ${b.digest.slice(0, 12)}`).join('\n')
    : '  (none)'}

# tool executions
${record.execution_ids.length
    ? record.execution_ids.map(id => `  - ${id}`).join('\n')
    : '  (none)'}`
}

function toolCallStatus(entry: ToolCallEntry | null): 'ok' | 'bad' | 'unknown' {
  if (!entry) return 'unknown'
  return entry.success && entry.semantic_success !== false ? 'ok' : 'bad'
}

function toolStatusClass(status: TurnToolDetail['status']): string {
  if (status === 'ok') return 'ok'
  if (status === 'bad') return 'bad'
  return ''
}

function toolStatusLabel(status: TurnToolDetail['status']): string {
  if (status === 'ok') return 'success'
  if (status === 'bad') return 'error'
  return 'unmatched'
}

// Tool input args as copyable text. Strings pass through; structured input is
// pretty-printed JSON.
function toolInputText(input: unknown): string {
  if (input == null) return ''
  if (typeof input === 'string') return input
  try {
    return JSON.stringify(input, null, 2)
  } catch {
    return String(input)
  }
}

// Tool output as copyable text. A string is the result verbatim; a blob ref
// (output spilled out-of-line by the server) yields its stored preview.
function toolOutputText(output: string | ToolCallOutputBlob | null): string {
  if (output == null) return ''
  if (typeof output === 'string') return output
  return output._blob.preview
}

// Provenance line for a blob-backed output so the operator knows the preview is
// truncated, with the sha to fetch the full payload elsewhere.
function toolOutputMeta(output: string | ToolCallOutputBlob | null): string | null {
  if (output == null || typeof output === 'string') return null
  const { bytes, mime, sha256 } = output._blob
  return `blob · ${bytes}B · ${mime} · ${sha256.slice(0, 12)}`
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
  if (phase.durationSource === 'estimated') return '추정'
  return '측정 없음'
}

function phaseDurationTitle(phase: TurnPhase): string {
  switch (phase.durationSource) {
    case 'tool_call_log':
      return 'duration_ms from /api/v1/keepers/:name/tool-calls'
    case 'provider_telemetry':
      return 'request_latency_ms — provider call wall-clock (OAS inference_telemetry)'
    case 'estimated':
      return 'estimated only; no durable duration for this phase'
    case 'not_recorded':
      return 'duration not recorded for this phase'
  }
}

function finalizePhaseOffsets(phases: TurnPhase[]): { visualTotalMs: number; measuredDurationMs: number | null } {
  let visualOffsetMs = 0
  let measuredDurationMs = 0
  let measuredCount = 0
  for (const phase of phases) {
    phase.visualOffsetMs = visualOffsetMs
    phase.visualDurationMs = phase.durationMs ?? 100
    visualOffsetMs += phase.visualDurationMs
    if (phase.durationMs != null) {
      measuredDurationMs += phase.durationMs
      measuredCount += 1
    }
  }
  return {
    visualTotalMs: Math.max(visualOffsetMs, 1),
    measuredDurationMs: measuredCount > 0 ? measuredDurationMs : null,
  }
}

function buildTurnDetail(
  keeperName: string,
  record: TurnRecordEntry,
  toolEntries: readonly ToolCallEntry[],
): TurnDetail {
  const traceId = `${record.trace_id}_${String(record.absolute_turn).padStart(4, '0')}`
  const tokIn = record.input_tokens ?? Math.max(1, Math.round(record.blocks.reduce((sum, b) => sum + b.bytes, 0) / 4))
  const tokOut = record.output_tokens ?? 120
  // RFC-0233 §8 — ctx-fill% and cost grounded in runtime.toml-declared facts.
  // context_window is the keeper-resolved effective budget (replaces the
  // hardcoded 200K); prices are USD/1M from the binding (replace Claude $3/$15).
  // Either is null when the record lacks the fact — the view renders "미상".
  const ctxPct =
    record.context_window != null && record.context_window > 0
      ? Math.min(100, (tokIn / record.context_window) * 100)
      : null
  const cost =
    record.price_input_per_million != null && record.price_output_per_million != null
      ? (tokIn * record.price_input_per_million + tokOut * record.price_output_per_million) / 1e6
      : null
  const toolIndex = toolCallIndexByExecutionId(toolEntries)

  const phases: TurnPhase[] = [{
    label: '컨텍스트 조립',
    kind: 'ctx',
    durationMs: null,
    durationSource: 'not_recorded',
    visualDurationMs: 0,
    visualOffsetMs: 0,
    meta: 'keeper turn pre-dispatch',
  }]
  if (record.enable_thinking === true || record.thinking_budget != null) {
    phases.push({
      label: 'Thinking',
      kind: 'reason',
      durationMs: null,
      durationSource: 'not_recorded',
      visualDurationMs: 0,
      visualOffsetMs: 0,
      meta: record.thinking_budget != null ? `budget ${record.thinking_budget}` : 'enabled',
    })
  }

  const tools = record.execution_ids.map((id): TurnToolDetail => {
    const entry = toolIndex.get(id) ?? null
    return {
      id,
      toolName: entry?.tool ?? null,
      status: toolCallStatus(entry),
      durationMs: entry?.duration_ms ?? null,
      agentSubturn: entry?.turn ?? null,
      keeperTurn: entry?.keeper_turn_id ?? null,
      matched: entry !== null,
      input: entry?.input ?? null,
      output: entry?.output ?? null,
    }
  })
  tools.forEach(tool => {
    phases.push({
      label: tool.toolName ?? tool.id.slice(0, 24),
      kind: 'tool',
      mono: true,
      durationMs: tool.durationMs,
      durationSource: tool.durationMs != null ? 'tool_call_log' : 'not_recorded',
      visualDurationMs: 0,
      visualOffsetMs: 0,
      meta: [
        tool.agentSubturn != null ? `agent subturn T${tool.agentSubturn}` : null,
        `execution ${tool.id.slice(0, 24)}`,
      ].filter(Boolean).join(' · '),
    })
  })
  phases.push({
    label: '응답 생성',
    kind: 'gen',
    // RFC-0233 §9 — ground the generation phase in OAS request_latency_ms
    // (provider call wall-clock). Absent on the error path or before a
    // response existed → render "측정 없음" rather than fabricating a bar.
    durationMs: record.request_latency_ms ?? null,
    durationSource:
      record.request_latency_ms != null ? 'provider_telemetry' : 'not_recorded',
    // RFC-0233 §10 — time-to-first-token. Populated on the streaming path for
    // every provider; null for non-streaming turns and on the error path.
    ttfrcMs: record.ttfrc_ms ?? null,
    visualDurationMs: 0,
    visualOffsetMs: 0,
    meta: (() => {
      if (record.request_latency_ms == null) {
        return 'provider/OAS duration is not recorded for this turn'
      }
      if (record.ttfrc_ms != null) {
        return `provider call wall-clock (request_latency_ms) · 첫 토큰 ${formatMsCompact(record.ttfrc_ms)} (ttfrc_ms)`
      }
      return 'provider call wall-clock (request_latency_ms)'
    })(),
  })
  const { visualTotalMs, measuredDurationMs } = finalizePhaseOffsets(phases)

  const systemPrompt = buildSystemPrompt(keeperName, record)
  const injectedCtx = buildInjectedCtx(record, ctxPct, tokIn)

  return {
    traceId,
    tokIn,
    tokOut,
    ctxPct,
    contextWindow: record.context_window ?? null,
    cost,
    measuredDurationMs,
    visualTotalMs,
    phases,
    tools,
    systemPrompt,
    injectedCtx,
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
    <button class="kti-copy ${done ? 'done' : ''}" onClick=${onClick}>
      ${done ? '\u2713 복사됨' : '\u2398 ' + label}
    </button>
  `
}

function CodeCard({ cap, text, htmlContent, tokens }: { cap: string; text: string; htmlContent?: string; tokens?: number }) {
  return html`
    <div class="kti-code">
      <div class="kti-code-h">
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
    <div class="kti-sec">
      <div class="kti-sec-h">
        <h4>턴 워터폴</h4>
        <span class="n">
          ${t.phases.length} 단계 · 실측 ${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : '없음'} · 미측정 ${unknownCount}
        </span>
      </div>
      <div class="kti-wf">
        ${t.phases.map((p, i) => html`
          <div key=${i} class="kti-wf-row">
            <div class="kti-wf-lbl">
              <span class="kti-wf-ico kti-k-${p.kind}"></span>
              <span class="nm ${p.mono ? 'mono' : ''}" title=${p.meta ?? p.label}>${p.label}</span>
            </div>
            <div class="kti-wf-track">
              <div
                class=${`kti-wf-bar kti-k-${p.kind}${p.durationSource === 'not_recorded' ? ' is-unmeasured' : ''}`}
                title=${phaseDurationTitle(p)}
                style=${{
                  left: `${(p.visualOffsetMs / t.visualTotalMs) * 100}%`,
                  width: `${Math.max(0.6, (p.visualDurationMs / t.visualTotalMs) * 100)}%`,
                }}
              />
            </div>
            <span class="kti-wf-dur" title=${phaseDurationTitle(p)}>${phaseDurationLabel(p)}</span>
          </div>
        `)}
      </div>
      <div class="kti-wf-foot">
        <div class="kti-wf-legend">
          <span><i class="kti-k-reason"></i>추론</span>
          <span><i class="kti-k-tool"></i>도구</span>
          <span><i class="kti-k-gen"></i>생성</span>
        </div>
        <span>실측 합계 <b>${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : '없음'}</b></span>
      </div>
    </div>
  `
}

// Lazy-loaded transcript state for the open turn (RFC-0233 §7). Distinct from
// `null` (not yet requested) so the renderer can show loading vs absence.
type TranscriptView =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'loaded'; data: TurnTranscript }

// Map the async-resource state to a transcript view. Error wins over a stale
// data value; absence of both reads as still-loading (the lazy fetch fires on
// drawer open).
function toTranscriptView(state: {
  loading: boolean
  error: string | null
  data: TurnTranscript | null
}): TranscriptView {
  if (state.error) return { kind: 'error', message: state.error }
  if (state.data) return { kind: 'loaded', data: state.data }
  return { kind: 'loading' }
}

// One operator request line. Renders the real persisted content; explicit
// absence when the turn carried no joinable user row.
function OperatorLine({ line, seq }: { line: TurnTranscriptLine | null; seq: number }) {
  return html`
    <div class="kti-msg">
      <div class="kti-msg-h">
        <span class="kti-msg-role user">user</span>
        <span class="who">operator</span>
        <span class="seq">#${seq}</span>
      </div>
      ${line
        ? html`<div class="kti-msg-b" data-testid="turn-transcript-user">${line.content}</div>`
        : html`<div class="kti-msg-b kti-msg-absent" data-testid="turn-transcript-user-absent">
            operator 요청이 이 턴에 기록되지 않았습니다 (turn_ref 미연결 또는 보존 윈도 밖)
          </div>`}
    </div>
  `
}

// One keeper response line. A transport-failure or agent-failure row
// (masc#24314 / oas#2585) is labelled distinctly by its writer-declared
// cause and never presented as the keeper's own utterance.
function KeeperLine({
  keeperName,
  line,
  seq,
}: {
  keeperName: string
  line: TurnTranscriptLine | null
  seq: number
}) {
  const failureLabel =
    line?.kind === 'transport_failure' ? 'transport failure'
    : line?.kind === 'agent_failure' ? 'agent failure'
    : null
  return html`
    <div class="kti-msg">
      <div class="kti-msg-h">
        <span class="kti-msg-role assistant">assistant</span>
        <span class="who">${keeperName}</span>
        ${failureLabel
          ? html`<span class="pill bad" data-testid="turn-transcript-assistant-failure">${failureLabel}</span>`
          : null}
        <span class="seq">#${seq}</span>
      </div>
      ${line
        ? html`<div class="kti-msg-b" data-testid="turn-transcript-assistant">${line.content}</div>`
        : html`<div class="kti-msg-b kti-msg-absent" data-testid="turn-transcript-assistant-absent">
            keeper 응답이 이 턴에 기록되지 않았습니다
          </div>`}
    </div>
  `
}

function MessagesTab({
  keeperName,
  t,
  transcript,
}: {
  keeperName: string
  t: TurnDetail
  transcript: TranscriptView
}) {
  let seq = 0
  const userLines = transcript.kind === 'loaded' ? transcript.data.user : []
  const assistantLines = transcript.kind === 'loaded' ? transcript.data.assistant : []
  // 2 synthetic (system + context) + real user lines + tools + real assistant
  // lines. Falls back to one placeholder slot each while loading/absent.
  const userSlots = userLines.length || 1
  const assistantSlots = assistantLines.length || 1
  const messageCount = 2 + userSlots + t.tools.length + assistantSlots
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h">
        <h4>모델에 전달된 시퀀스</h4>
        <span class="n">${messageCount} 메시지</span>
      </div>
      ${transcript.kind === 'loading'
        ? html`<div class="text-2xs text-[var(--color-fg-muted)] px-1 pb-1" data-testid="turn-transcript-loading">전사 불러오는 중…</div>`
        : null}
      ${transcript.kind === 'error'
        ? html`<div class="text-2xs text-[var(--color-status-warn)] px-1 pb-1" data-testid="turn-transcript-error">전사 불러오기 실패 · ${transcript.message}</div>`
        : null}
      <div class="kti-seq-rail">
        <div class="kti-msg">
          <div class="kti-msg-h">
            <span class="kti-msg-role system">system</span>
            <span class="who">시스템 프롬프트</span>
            <span class="seq">#${++seq}</span>
          </div>
          <div class="kti-msg-b mono">${t.systemPrompt}</div>
        </div>
        <div class="kti-msg">
          <div class="kti-msg-h">
            <span class="kti-msg-role context">context</span>
            <span class="who">주입 컨텍스트</span>
            <span class="seq">#${++seq}</span>
          </div>
          <div class="kti-msg-b mono">${t.injectedCtx}</div>
        </div>
        ${userLines.length
          ? userLines.map(line => html`<${OperatorLine} line=${line} seq=${++seq} />`)
          : html`<${OperatorLine} line=${null} seq=${++seq} />`}
        ${t.tools.map((tool, i) => html`
          <div key=${i} class="kti-tool">
            <div class="kti-tool-h">
              <span class="seq">#${++seq}</span>
              <span class="tnm mono">${tool.toolName ?? tool.id}</span>
              <span class="pill ${toolStatusClass(tool.status)}">
                ${toolStatusLabel(tool.status)}
              </span>
              ${tool.agentSubturn != null
                ? html`<span class="seq">agent subturn T${tool.agentSubturn}</span>`
                : null}
              ${tool.durationMs != null
                ? html`<span class="seq">${formatMsCompact(tool.durationMs)}</span>`
                : html`<span class="seq">duration 없음</span>`}
            </div>
            <div class="kti-tool-b">
              ${tool.matched
                ? html`
                  <${CodeCard}
                    cap="요청 · input"
                    text=${toolInputText(tool.input)}
                    tokens=${approxTokens(toolInputText(tool.input))}
                  />
                  <${CodeCard}
                    cap=${toolOutputMeta(tool.output) ? `응답 · result (${toolOutputMeta(tool.output)})` : '응답 · result'}
                    text=${toolOutputText(tool.output)}
                    tokens=${approxTokens(toolOutputText(tool.output))}
                  />
                `
                : html`
                  <div class="kti-msg-b kti-msg-absent" data-testid="turn-tool-io-absent">
                    이 execution(${tool.id.slice(0, 24)})의 tool-call I/O를 tool-call 로그에서 찾지 못했습니다 (보존 윈도 밖이거나 미기록)
                  </div>
                `}
            </div>
          </div>
        `)}
        ${assistantLines.length
          ? assistantLines.map(line => html`<${KeeperLine} keeperName=${keeperName} line=${line} seq=${++seq} />`)
          : html`<${KeeperLine} keeperName=${keeperName} line=${null} seq=${++seq} />`}
      </div>
    </div>
  `
}

function ContextTab({ t }: { t: TurnDetail }) {
  return html`
    <div class="kti-sec">
      <div class="kti-ctx-card">
        <div class="kti-ctx-h">
          <span class="t">시스템 프롬프트</span>
          <span class="tok">~${approxTokens(t.systemPrompt)} tok</span>
          <${CopyBtn} text=${t.systemPrompt} />
        </div>
        <pre>${t.systemPrompt}</pre>
      </div>
    </div>
    <div class="kti-sec">
      <div class="kti-ctx-card">
        <div class="kti-ctx-h">
          <span class="t">주입 컨텍스트 · blocks · executions</span>
          <span class="tok">~${approxTokens(t.injectedCtx)} tok</span>
          <${CopyBtn} text=${t.injectedCtx} />
        </div>
        <pre>${t.injectedCtx}</pre>
      </div>
    </div>
  `
}

function MetaTab({ record, t, source }: { record: TurnRecordEntry; t: TurnDetail; source: string }) {
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h"><h4>샘플링 파라미터</h4></div>
      <div class="kti-params">
        <span class="kti-param">temperature<b>${record.temperature ?? '—'}</b></span>
        <span class="kti-param">top_p<b>${record.top_p ?? '—'}</b></span>
        <span class="kti-param">max_tokens<b>${record.max_tokens?.toLocaleString() ?? '—'}</b></span>
        <span class="kti-param">thinking_budget<b>${record.thinking_budget ?? '—'}</b></span>
        <span class="kti-param">enable_thinking<b>${thinkingChipLabel(record)}</b></span>
      </div>
      <div class="kti-sec-h" style=${{ marginTop: '16px' }}><h4>실행 메타데이터</h4></div>
      <div class="kti-kv">
        <span class="k">model</span><span class="v">${record.model ?? 'n/a'}</span>
        <span class="k">runtime</span><span class="v">${record.runtime_profile}</span>
        <span class="k">fsm.state</span><span class="v">n/a</span>
        <span class="k">input tokens</span><span class="v">${t.tokIn.toLocaleString()}</span>
        <span class="k">output tokens</span><span class="v">${t.tokOut.toLocaleString()}</span>
        <span class="k">ctx window${record.context_window != null ? '' : ' · 미상'}</span><span class="v">${t.ctxPct != null ? `${t.ctxPct.toFixed(1)}% / ${record.context_window?.toLocaleString() ?? '미상'}` : '미상'}</span>
        <span class="k">keeper turn</span><span class="v">T${record.absolute_turn}</span>
        <span class="k">agent subturns</span><span class="v">${formatTurnList(uniqueNumbers(t.tools.map(tool => tool.agentSubturn)))}</span>
        <span class="k">thinking</span><span class="v">${thinkingStateLabel(record)}</span>
        <span class="k">tool calls</span><span class="v">${t.tools.length}</span>
        <span class="k">measured phase duration</span><span class="v">${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : 'none'}</span>
        <span class="k">est. cost${record.price_input_per_million != null ? '' : ' · 가격 미구성'}</span><span class="v">${t.cost != null ? `$${t.cost.toFixed(3)}` : '미상'}</span>
        <span class="k">finish_reason</span><span class="v">${record.finish_reason ?? 'n/a'}</span>
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
  const t = buildTurnDetail(keeperName, row.record, toolEntries)

  // RFC-0233 §7: lazily fetch this turn's transcript by its join key
  // "<trace_id>#<absolute_turn>". Loaded per-open so the (potentially large)
  // transcript never bloats the turn-records list.
  const turnRef = `${row.record.trace_id}#${row.record.absolute_turn}`
  const transcriptResource = useManagedAsyncResource<TurnTranscript | null>(null)
  useEffect(() => {
    void transcriptResource.load((signal) =>
      fetchKeeperTurnTranscript(keeperName, turnRef, { signal }),
    )
    return () => {
      transcriptResource.cancel()
    }
  }, [keeperName, turnRef, transcriptResource])

  const transcript = toTranscriptView(transcriptResource.state.value)

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
      class="kti-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="턴 상세"
      onClick=${onClose}
      data-testid="turn-detail-drawer"
    >
      <div class="kti-drawer" onClick=${(e: Event) => e.stopPropagation()}>
        <div class="kti-head">
          <h3>턴 상세</h3>
          <span class="tid mono">${t.traceId}</span>
          <div class="kti-head-actions">
            <${CopyBtn} text=${t.traceId} label="ID" />
            <button class="kti-close" onClick=${onClose} title="닫기 (Esc)">\u2715</button>
          </div>
        </div>

        <div class="kti-sub">
          <span class="kti-chip">
            <span class="sub-k">keeper</span>${keeperName}
          </span>
          <span class="kti-chip">
            <span class="sub-k">keeper turn</span>T${row.record.absolute_turn}
          </span>
          <span class="kti-chip">
            <span class="sub-k">agent subturns</span>${formatTurnList(uniqueNumbers(t.tools.map(tool => tool.agentSubturn)))}
          </span>
          <span class="kti-chip">
            <span class="sub-k">thinking</span>${thinkingChipLabel(row.record)}
          </span>
          <span class="kti-chip${row.record.finish_reason ? ' ok' : ''}">
            <span class="sub-k">finish</span>${row.record.finish_reason ?? 'n/a'}
          </span>
          <span class="kti-chip">
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

        <div class="kti-summary" data-testid="turn-summary-stats">
          <div class="kti-stat">
            <div class="k">실측</div>
            <div class="v">${t.measuredDurationMs != null ? formatMsCompact(t.measuredDurationMs) : '—'}</div>
          </div>
          <div class="kti-stat">
            <div class="k">입력</div>
            <div class="v">${(t.tokIn / 1000).toFixed(1)}<small>k</small></div>
          </div>
          <div class="kti-stat">
            <div class="k">출력</div>
            <div class="v volt">${t.tokOut.toLocaleString()}</div>
          </div>
          <div class="kti-stat">
            <div class="k">도구</div>
            <div class="v">${t.tools.length}</div>
          </div>
          <div class="kti-stat">
            <div class="k">추정비용</div>
            <div class="v ok">${t.cost != null ? `$${t.cost.toFixed(2)}` : '미상'}</div>
          </div>
        </div>

        <div class="kti-tok" data-testid="turn-token-bar">
          <div class="kti-tok-top">
            <span class="lbl">토큰 경제</span>
            <span class="ctxpct">${t.ctxPct != null ? `컨텍스트 ${t.ctxPct.toFixed(1)}% / ${formatCtxWindowK(t.contextWindow)}` : '컨텍스트 미상'}</span>
          </div>
          <div class="kti-tok-bar">
            <span
              class="seg-in"
              style=${{ width: `${(t.tokIn / (t.tokIn + t.tokOut)) * 100}%` }}
            />
            <span
              class="seg-out"
              style=${{ width: `${(t.tokOut / (t.tokIn + t.tokOut)) * 100}%` }}
            />
          </div>
          <div class="kti-tok-legend">
            <span class="in"><i></i>입력 <b>${t.tokIn.toLocaleString()}</b></span>
            <span class="out"><i></i>출력 <b>${t.tokOut.toLocaleString()}</b></span>
          </div>
        </div>

        <div class="kti-tabs" role="tablist" aria-label="턴 상세 탭">
          ${TABS.map(([id, lbl]) => html`
            <button
              key=${id}
              role="tab"
              aria-selected=${tab === id}
              class="kti-tab ${tab === id ? 'on' : ''}"
              onClick=${() => setTab(id)}
              data-testid="turn-tab-${id}"
            >
              ${lbl}
            </button>
          `)}
        </div>

        <div class="kti-body">
          ${tab === 'timeline' && html`<${TimelineTab} t=${t} />`}
          ${tab === 'messages' && html`<${MessagesTab} keeperName=${keeperName} t=${t} transcript=${transcript} />`}
          ${tab === 'context' && html`<${ContextTab} t=${t} />`}
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
        class="kti-turn-summary list-none cursor-pointer flex items-center gap-2 py-1.5 px-2 flex-wrap"
        onClick=${(e: Event) => {
          // Only open the drawer on direct summary clicks, not on the expand chevron area.
          if (e.target === e.currentTarget || (e.target as HTMLElement).closest('.kti-turn-summary') === e.currentTarget) {
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
  const userModelPanel = response?.user_model
    ? html`<${UserModelSourcePanel} snapshot=${response.user_model} rows=${rows} />`
    : null

  if (rows.length === 0) {
    return html`
      <div class="p-4 space-y-1 v2-monitoring-panel">
        ${memoryOsPanel}
        ${userModelPanel}
        <div class="text-xs text-[var(--color-fg-muted)]">턴 레코드 없음 (서버 재시작 이후 keeper 턴까지 기록됩니다)</div>
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
      ${userModelPanel}
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

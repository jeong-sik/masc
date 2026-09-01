// MASC v2 — Keeper memory inspector (read-only overlay-drawer).
//
// Pixel-matched to the Claude-Design prototype keeper-v2/memory.jsx — same
// drawer shell, section headers, scope toggle, and `.mem-*` classes
// (memory-inspector-v2.css). Every datum is fetched from
// `GET /api/v1/keepers/:name/turn-records`.
//
// Section data sources:
//   최종 provider 입력   ← real final-input content bytes + provider wire bytes/runtime
//                           (entries[latest].input_components/request_* fields)
//   장기 메모리 스토어    ← real memory_os.facts.items (typed category, derived memory_id)
//                           with each row's place in memory_os.change.{added,removed}
//   최근 회상·주입        ← real memory_os_recall prompt blocks (entries[*].blocks)
// Any future-only section must render an honest disclosure rather than fabricated
// rows (no-stub): disclose absence instead of faking presence.

import { Fragment } from 'preact'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { formatDateTimeKo, formatTimeAgo } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { isAbortError } from '../lib/async-state'
import {
  fetchKeeperTurnRecords,
  type TurnRecordsResponse,
  type MemoryOsTurnRecordSnapshot,
  type MemoryOsFact,
  type MemoryOsFactCategory,
  type MemoryOsFactCategoryTag,
  type TurnBlock,
  type TurnInputComponent,
  type TurnInputComponentId,
  type TurnPromptBlockId,
  type TurnRecordRow,
} from '../api/dashboard'
import { KeeperPromptCapture } from './keeper-turn-inspector-panel'

export interface MemoryKeeper {
  readonly id: string
  readonly status: 'run' | 'pause' | 'off' | 'unknown'
}

// ── byte / token formatters ──
export function memFmtTok(n: number): string {
  const a = Math.abs(n)
  const s = a >= 1000 ? `${(a / 1000).toFixed(1)}k` : String(a)
  return (n < 0 ? '−' : '') + s
}

export function memFmtBytes(n: number): string {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)}MB`
  if (n >= 1024) return `${(n / 1024).toFixed(1)}KB`
  return `${n}B`
}

// ── prompt-block composition (real, from turn_record blocks) ──
// PROMPT_BLOCK_META mirrors the OCaml Prompt_block_id closed sum
// (lib/types/prompt_block_id.ml — to_string is the wire SSOT). Unknown tokens
// are protocol drift and are rejected at the API decoder.
interface BlockMeta {
  readonly lbl: string
  readonly color: string
  // Whether this block is the memory-os contribution to the prompt. Mirrors the
  // prototype MEM_BLOCKS `mem` flag (memory.jsx) — only memory_os_recall
  // carries recalled memory; the rest are instructions/context/surface.
  readonly mem: boolean
}
const PROMPT_BLOCK_META: Readonly<Record<TurnPromptBlockId, BlockMeta>> = {
  keeper_instructions: { lbl: 'Keeper 지침', color: 'var(--text-dim)', mem: false },
  dynamic_context: { lbl: '동적 컨텍스트', color: 'var(--volt)', mem: false },
  temporal_summary: { lbl: '시간 요약', color: 'var(--status-warn)', mem: false },
  memory_os_recall: { lbl: '메모리 회상', color: 'var(--volt-strong)', mem: true },
  // RFC-0366: one operator sentence, rendered for one turn and then stamped
  // consumed. Not memory — it never reaches the recall block.
  operator_note: { lbl: '운영자 노트', color: 'var(--status-warn)', mem: false },
}
export function promptBlockMeta(token: TurnPromptBlockId): BlockMeta {
  return PROMPT_BLOCK_META[token]
}

export interface CompositionPart {
  readonly key: string
  readonly lbl: string
  readonly bytes: number
  readonly color: string
  readonly mem: boolean
}
export interface Composition {
  readonly totalBytes: number
  readonly parts: readonly CompositionPart[]
}

// Composition from a turn's assembled prompt blocks. The bar is a BYTES ratio
// (each block's real byte size); no token magic, no fabricated parts. Zero-byte
// blocks are dropped so the legend matches the bar.
export function memCompositionFromBlocks(blocks: readonly TurnBlock[]): Composition {
  const parts: CompositionPart[] = blocks
    .filter(b => b.bytes > 0)
    .map(b => {
      const meta = promptBlockMeta(b.block)
      return { key: b.block, lbl: meta.lbl, bytes: b.bytes, color: meta.color, mem: meta.mem }
    })
  const totalBytes = parts.reduce((sum, p) => sum + p.bytes, 0)
  return { totalBytes, parts }
}

const INPUT_COMPONENT_META: Readonly<Record<TurnInputComponentId, BlockMeta>> = {
  'prompt.keeper_instructions': PROMPT_BLOCK_META.keeper_instructions,
  'prompt.dynamic_context': PROMPT_BLOCK_META.dynamic_context,
  'prompt.temporal_summary': PROMPT_BLOCK_META.temporal_summary,
  'prompt.memory_os_recall': PROMPT_BLOCK_META.memory_os_recall,
  'prompt.operator_note': PROMPT_BLOCK_META.operator_note,
  tool_schemas: { lbl: '도구 스키마', color: 'var(--status-warn)', mem: false },
  message_user: { lbl: '사용자 메시지', color: 'var(--info)', mem: false },
  message_system: { lbl: '시스템 메시지', color: 'var(--text-dim)', mem: false },
  message_assistant_text: { lbl: '어시스턴트 응답', color: 'var(--status-ok)', mem: false },
  message_thinking: { lbl: '사고', color: 'var(--volt)', mem: false },
  message_redacted_thinking: { lbl: '비공개 사고', color: 'var(--volt)', mem: false },
  message_tool_use: { lbl: '도구 호출', color: 'var(--status-bad)', mem: false },
  message_tool_result: { lbl: '도구 결과', color: 'var(--volt-strong)', mem: false },
  message_image: { lbl: '이미지', color: 'var(--info)', mem: false },
  message_document: { lbl: '문서', color: 'var(--status-warn)', mem: false },
  message_audio: { lbl: '오디오', color: 'var(--status-ok)', mem: false },
}

export function inputComponentMeta(token: TurnInputComponentId): BlockMeta {
  return INPUT_COMPONENT_META[token]
}

export function memCompositionFromInputComponents(
  components: readonly TurnInputComponent[],
): Composition {
  const parts: CompositionPart[] = components
    .filter(component => component.bytes > 0)
    .map(component => {
      const meta = inputComponentMeta(component.component)
      return {
        key: component.component,
        lbl: meta.lbl,
        bytes: component.bytes,
        color: meta.color,
        mem: meta.mem,
      }
    })
  return {
    totalBytes: parts.reduce((sum, part) => sum + part.bytes, 0),
    parts,
  }
}

// The most recent turn that actually assembled a prompt (has blocks). Entries
// are append-ordered; an error/empty-block turn at the tail is skipped so the
// composition reflects the last real prompt assembly — and the header token
// figures are read from this same row, never a blank tail.
export function latestEntryWithBlocks(rows: readonly TurnRecordRow[]): TurnRecordRow | null {
  for (let i = rows.length - 1; i >= 0; i--) {
    const row = rows[i]
    if (row && row.record.blocks.length > 0) return row
  }
  return null
}

export function latestEntryWithInputComponents(
  rows: readonly TurnRecordRow[],
): TurnRecordRow | null {
  for (let i = rows.length - 1; i >= 0; i--) {
    const row = rows[i]
    if (
      row
      && (
        row.record.input_components !== null
        || row.record.request_body_bytes != null
      )
    ) return row
  }
  return null
}

export interface MemoryRecallInjection {
  readonly traceId: string
  readonly turn: number
  readonly ts: number
  readonly bytes: number
  readonly digest: string
}

export function recentMemoryRecallInjections(
  rows: readonly TurnRecordRow[],
  limit = 5,
): readonly MemoryRecallInjection[] {
  const injections: MemoryRecallInjection[] = []
  for (let i = rows.length - 1; i >= 0 && injections.length < limit; i--) {
    const row = rows[i]
    const block = row?.record.blocks.find(b => b.block === 'memory_os_recall' && b.bytes > 0)
    if (!row || !block) continue
    injections.push({
      traceId: row.record.trace_id,
      turn: row.record.absolute_turn,
      ts: row.record.ts,
      bytes: block.bytes,
      digest: block.digest,
    })
  }
  return injections
}

// ── fact category meta (real, exhaustive over the typed union) ──
export interface FactCategoryMeta {
  readonly lbl: string
  readonly glyph: string
  readonly color: string
}
// Exhaustive switch over MemoryOsFactCategory. A new arm added to the OCaml
// `category` sum (and its TS mirror) forces a compile error here via the
// `never` guard — no `_ -> default` swallow, no silent miscolour.
export function factCategoryMeta(category: MemoryOsFactCategory): FactCategoryMeta {
  const tag = category.tag
  switch (tag) {
    case 'code_change':
      return { lbl: '코드 변경', glyph: '◆', color: 'var(--info)' }
    case 'fact':
      return { lbl: '사실', glyph: '◈', color: 'var(--status-ok)' }
    case 'preference':
      return { lbl: '선호', glyph: '○', color: 'var(--volt-strong)' }
    case 'blocker':
      return { lbl: '블로커', glyph: '▲', color: 'var(--status-bad)' }
    case 'goal':
      return { lbl: '목표', glyph: '◎', color: 'var(--volt)' }
    case 'constraint':
      return { lbl: '제약', glyph: '▢', color: 'var(--status-warn)' }
    case 'validated_approach':
      return { lbl: '검증된 접근', glyph: '✓', color: 'var(--status-ok)' }
    case 'lesson':
      return { lbl: '교훈', glyph: '★', color: 'var(--volt-strong)' }
  }
  const _exhaustive: never = tag
  return _exhaustive
}

// Claim age uses the producer-owned insertion timestamp. Snapshot membership is
// the only current-state authority.
function factAgeLabel(fact: MemoryOsFact): string {
  return formatTimeAgo(fact.first_seen)
}

export function sortMemoryFactsForReview(facts: readonly MemoryOsFact[]): MemoryOsFact[] {
  return [...facts]
}

function formatInstant(ts: number): string {
  return formatDateTimeKo(ts)
}

// A store row's place in the latest librarian delta (memory_os.change).
// `removed` rows are no longer in the store; they are listed at the tail of the
// store so the last revision's change is visible in place instead of in a
// second list that repeats the same claims.
export type StoreRowDelta = 'added' | 'removed' | null

export interface StoreRow {
  readonly fact: MemoryOsFact
  readonly delta: StoreRowDelta
}

export function storeRowsFromSnapshot(snapshot: MemoryOsTurnRecordSnapshot): StoreRow[] {
  const addedIds = new Set(snapshot.change.added.map(fact => fact.memory_id))
  const current: StoreRow[] = sortMemoryFactsForReview(snapshot.facts.items).map(fact => ({
    fact,
    delta: addedIds.has(fact.memory_id) ? 'added' : null,
  }))
  const removed: StoreRow[] = snapshot.change.removed.map(fact => ({ fact, delta: 'removed' }))
  return [...current, ...removed]
}

// Store list filter: every row, only the latest-delta rows, or one category.
export type StoreFilter =
  | { readonly kind: 'all' }
  | { readonly kind: 'delta' }
  | { readonly kind: 'category'; readonly tag: MemoryOsFactCategoryTag }

export function storeRowMatches(row: StoreRow, filter: StoreFilter): boolean {
  switch (filter.kind) {
    case 'all':
      return true
    case 'delta':
      return row.delta !== null
    case 'category':
      return row.fact.category.tag === filter.tag
  }
  const _exhaustive: never = filter
  return _exhaustive
}

function latestMemoryRecallBlock(row: TurnRecordRow | null): TurnBlock | null {
  return row?.record.blocks.find(block => block.block === 'memory_os_recall') ?? null
}

// ── rendering ──

function MemBar({ parts, total }: { parts: readonly CompositionPart[]; total: number }) {
  return html`
    <div class="mem-bar" title="최종 provider 입력 콘텐츠 구성 (bytes)">
      ${parts.map(p => html`<span key=${p.key} style=${{ width: `${(p.bytes / total) * 100}%`, background: p.color }}></span>`)}
    </div>`
}

function MemCompoReal({ row }: { row: TurnRecordRow | null }) {
  const components = row?.record.input_components ?? []
  const { totalBytes, parts } = memCompositionFromInputComponents(components)
  if (!row) {
    return html`<div class="mem-empty">최종 provider 입력 구성 관측 없음.</div>`
  }
  const inputTok = row.record.input_tokens
  const requestBodyBytes = row.record.request_body_bytes
  const inputComponentsUnavailable = row.record.input_components === null
  const ctxWin = row.record.context_window
  const pct = inputTok != null && ctxWin != null && ctxWin > 0
    ? Math.round((inputTok / ctxWin) * 100)
    : null
  return html`
    <div class="mem-compo">
      <div class="mem-compo-head">
        <span class="mono mem-compo-tot">
          ${requestBodyBytes == null
            ? html`wire 측정 없음 · ${memFmtBytes(totalBytes)} content`
            : html`${memFmtBytes(requestBodyBytes)} wire · ${memFmtBytes(totalBytes)} content`}
        </span>
        <span class="mem-compo-sub">
          ${inputTok != null
            ? html`${memFmtTok(inputTok)} provider tok${ctxWin != null ? html` / ${memFmtTok(ctxWin)} 윈도우` : null}${pct != null ? html` · ${pct}%` : null}`
            : html`${parts.length}개 구성요소`}
          ${row.record.request_runtime_profile != null
            ? html` · ${row.record.request_runtime_profile}`
            : null}
        </span>
      </div>
      ${inputComponentsUnavailable
        ? html`<div class="mem-empty">content 구성 관측 불가 — 빈 입력으로 간주하지 않습니다.</div>`
        : totalBytes === 0
          ? html`<div class="mem-empty">관측된 content 구성요소가 없습니다.</div>`
        : html`
            <${MemBar} parts=${parts} total=${totalBytes} />
            <div class="mem-legend">
              ${parts.map(p => html`
                <div key=${p.key} class="mem-leg">
                  <span class="mem-leg-sw" style=${{ background: p.color }}></span>
                  <span class="mem-leg-lbl">${p.lbl}${p.mem ? html`<span class="mem-leg-tag">메모리</span>` : null}</span>
                  <span class="mem-leg-v mono">${memFmtBytes(p.bytes)}</span>
                </div>`)}
            </div>
          `}
    </div>`
}

function MemoryTrustStrip({
  snapshot,
  latestPromptRow,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  latestPromptRow: TurnRecordRow | null
}) {
  const memoryBlock = latestMemoryRecallBlock(latestPromptRow)
  const promptTurn = latestPromptRow
    ? `${latestPromptRow.record.trace_id}#${latestPromptRow.record.absolute_turn}`
    : 'none'
  const sourceLabel = snapshot.update_source
    ? `${snapshot.update_source.kind} · ${snapshot.update_source.trace_id}`
    : 'fresh state'
  return html`
    <div class="mem-trust">
      <div class="mem-trust-card">
        <span class="mem-trust-k">store</span>
        <span class="mem-trust-v mono">revision ${snapshot.revision}</span>
        <span class="mem-trust-sub mono">${snapshot.facts.shown} facts · current snapshot</span>
      </div>
      <div class="mem-trust-card">
        <span class="mem-trust-k">scope</span>
        <span class="mem-trust-v mono">${snapshot.keeper}</span>
        <span class="mem-trust-sub mono">${sourceLabel}</span>
      </div>
      <div class="mem-trust-card">
        <span class="mem-trust-k">prompt link</span>
        <span class="mem-trust-v mono">${memoryBlock ? `${memFmtBytes(memoryBlock.bytes)} memory_os_recall` : 'no memory block'}</span>
        <span class="mem-trust-sub mono">${promptTurn}</span>
      </div>
    </div>
  `
}

function MemoryCurrentContract({ snapshot }: { snapshot: MemoryOsTurnRecordSnapshot }) {
  const writer = snapshot.update_source?.kind ?? 'fresh state'
  return html`
    <div class="mem-policy">
      <div class="mem-policy-row"><span>writer</span><code>${writer}</code><b>latest snapshot writer</b></div>
      <div class="mem-policy-row"><span>commit</span><code>${snapshot.snapshot_store}</code><b>single atomic snapshot</b></div>
      <div class="mem-policy-row"><span>recall</span><code>memory_os_recall</code><b>exact current facts · no ranking/truncation</b></div>
      <div class="mem-policy-row"><span>delta</span><code>revision ${snapshot.revision}</code><b>exact added / removed / retained</b></div>
    </div>
  `
}

function MemoryPromptEvidence({
  snapshot,
  row,
  keeperId,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  row: TurnRecordRow | null
  keeperId: string
}) {
  const memoryBlock = latestMemoryRecallBlock(row)
  const writer = snapshot.update_source?.kind ?? 'fresh state'
  const promptOpen = useSignal(false)
  return html`
    <div class="mem-prompt-evidence">
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">1</span>
        <div><b>snapshot writer</b><span>${writer}</span></div>
      </div>
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">2</span>
        <div><b>snapshot</b><span class="mono">${snapshot.snapshot_store}</span></div>
      </div>
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">3</span>
        <div><b>recall block</b><span class="mono">${memoryBlock ? `${memoryBlock.digest.slice(0, 12)} · ${memFmtBytes(memoryBlock.bytes)}` : 'not present in latest prompt record'}</span></div>
      </div>
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">4</span>
        <div>
          <b>Full Prompt</b>
          <button
            type="button"
            class="mem-prompt-toggle"
            aria-expanded=${promptOpen.value}
            onClick=${() => { promptOpen.value = !promptOpen.value }}
          >${promptOpen.value ? '마지막 캡처 닫기' : '마지막 캡처 보기'}</button>
        </div>
      </div>
      ${promptOpen.value ? html`<div class="mem-prompt-capture"><${KeeperPromptCapture} keeper=${keeperId} /></div>` : null}
      ${row ? html`
        <div class="mem-prompt-foot mono">
          latest assembly ${row.record.trace_id}#${row.record.absolute_turn} · ${formatInstant(row.record.ts)}
        </div>
      ` : null}
    </div>
  `
}

function RecentRecallTimeline({ rows }: { rows: readonly TurnRecordRow[] }) {
  const injections = recentMemoryRecallInjections(rows)
  if (injections.length === 0) {
    return html`<div class="mem-empty">최근 memory_os_recall 주입 없음.</div>`
  }
  // keeper-v2/memory.jsx 메모리 형성 에피소드 timeline (.mem-timeline >
  // .mem-tl-row): op chip / timestamp / text+range / freed bytes. Every row
  // here is a real memory_os_recall injection, so the op chip is always
  // 'recall' — the design's compact/summarize/evict roles have no live event
  // source and are not rendered.
  return html`
    <div class="mem-timeline">
      ${injections.map(inj => html`
        <div class="mem-tl-row" key=${`${inj.traceId}:${inj.turn}:${inj.digest}`}>
          <span class="mem-op recall">${'◈'} 회상</span>
          <span class="mem-tl-at">${formatTimeAgo(inj.ts)}</span>
          <span class="mem-tl-text">
            <span class="mono">${inj.traceId}#${inj.turn}</span>
            <span class="mem-tl-range mono">${inj.digest}</span>
          </span>
          <span class="mem-tl-tok">${memFmtBytes(inj.bytes)}</span>
        </div>
      `)}
    </div>
  `
}

// Row shape follows keeper-v2/memory.jsx MemStoreRow: category chip, claim,
// one meta line. The wire carries `first_seen` only (no provenance, no
// verification time), so the meta line is the insertion age with the absolute
// instant in the title, plus the row's place in the latest revision delta.
// The state chip renders the live `current` flag: store rows are current by
// construction, while change.removed rows are exact non-current delta evidence.
// `srcOverride` adds the owning keeper label in the aggregate current-facts list.
function FactRow({
  fact,
  delta = null,
  srcOverride,
}: {
  fact: MemoryOsFact
  delta?: StoreRowDelta
  srcOverride?: string
}) {
  const meta = factCategoryMeta(fact.category)
  const basisLabel = fact.basis.kind === 'observed'
    ? '관측'
    : `파생 · 증명 ${fact.basis.derivations.length}`
  const basisTitle = fact.basis.kind === 'observed'
    ? '직접 관측된 현재 사실'
    : fact.basis.derivations
        .map(derivation => `${derivation.rule_id}: ${derivation.premise_ids.join(', ')}`)
        .join('\n')
  return html`
    <div class=${delta === 'removed' ? 'mem-store-row removed' : 'mem-store-row'}>
      <span class="mem-kind" style=${{ color: meta.color, borderColor: meta.color }}>${meta.glyph} ${meta.lbl}</span>
      <div class="mem-store-main">
        <div class="mem-store-text">${fact.claim}</div>
        <div class="mem-store-meta">
          ${fact.current
            ? html`<span class="mem-state current">유효</span>`
            : html`<span class="mem-state removed">제거됨</span>`}
          ${delta === 'added' ? html`<span class="mem-delta added" title="이번 revision부터 current memory에 존재">+ 추가됨 · 현재 기억에 들어옴</span>` : null}
          ${delta === 'removed' ? html`<span class="mem-delta removed" title="직전 revision에는 있었지만 현재 memory에서는 삭제됨">− 제거됨 · 현재 기억에서 빠짐</span>` : null}
          <span class="mem-src mono" title=${basisTitle}>${basisLabel}</span>
          <span class="mono" title=${formatInstant(fact.first_seen)}>저장 ${factAgeLabel(fact)}</span>
          ${srcOverride ? html`<span class="mem-src mono">${srcOverride}</span>` : null}
        </div>
      </div>
    </div>`
}

function SupportInvalidations({ snapshot }: { snapshot: MemoryOsTurnRecordSnapshot }) {
  if (snapshot.change.invalidated.length === 0) return null
  return html`
    <div class="turn-sec">
      <div class="mem-sec-head">
        <h4>지지 무효화 · support retraction</h4>
        <span class="mem-n mono">${snapshot.change.invalidated.length}</span>
      </div>
      <div class="mem-store">
        ${snapshot.change.invalidated.map(invalidation => html`
          <div key=${invalidation.fact.memory_id} class="mem-store-row removed">
            <span class="mem-kind">× 지지 없음</span>
            <div class="mem-store-main">
              <div class="mem-store-text">${invalidation.fact.claim}</div>
              <div class="mem-store-meta">
                <span class="mem-delta removed">missing premises</span>
                ${invalidation.missing_premise_ids.map(premiseId => html`
                  <code key=${premiseId} class="mono">${premiseId}</code>
                `)}
              </div>
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}

// Honest disclosure for a section whose backend source lands in a later RFC
// phase. NOT a stub: it states the absence and the phase, renders no fabricated
// data, and is visually distinct from a real-data section.
function DisclosureNote({ text }: { text: string }) {
  return html`<div class="mem-empty mem-disclosure">${'ⓘ'} ${text}</div>`
}

function MemoryOsMissingState({ response }: { response: TurnRecordsResponse | null | undefined }) {
  const recordCount = response?.count ?? 0
  const source = response?.source ?? 'turn_record'
  const health = response?.health ?? 'unknown'
  const staleReason = response?.stale_reason ?? 'none'
  const skipped = response?.skipped_rows ?? 0
  const durableStore = response?.durable_store ?? null
  const hasTurnRecords = recordCount > 0
  return html`
    <div class="mem-empty">
      <strong>memory-os 소스 없음</strong><br />
      ${hasTurnRecords
        ? html`turn-records ${recordCount}건은 있지만 memory_os projection이 null입니다.`
        : html`이 keeper의 turn-records가 비어 있음`}
      <br />
      <span class="mono">source=${source} · health=${health} · stale=${staleReason} · skipped=${skipped}</span>
      ${durableStore ? html`<br /><span class="mono">${durableStore}</span>` : null}
    </div>
  `
}

function ReadErrors({ snapshot }: { snapshot: MemoryOsTurnRecordSnapshot }) {
  if (snapshot.read_errors.length === 0) return null
  const text = snapshot.read_errors.map(e => `${e.scope}: ${e.error}`).join(' · ')
  return html`<div class="mem-read-error" role="alert">${'⚠'} 읽기 오류 — ${text}</div>`
}

function memDotState(status: MemoryKeeper['status']): 'ok' | 'idle' | 'bad' {
  return status === 'run' ? 'ok' : status === 'off' ? 'bad' : 'idle'
}

// Filter chips follow keeper-v2/memory.jsx (전체 + one chip per category
// present, only when there is more than one category to choose between). The
// delta chip is added only when the latest revision changed rows, so a chip
// never filters to an empty list.
function StoreFilters({
  cats,
  deltaCount,
  active,
  onPick,
}: {
  cats: readonly MemoryOsFactCategory[]
  deltaCount: number
  active: StoreFilter
  onPick: (filter: StoreFilter) => void
}) {
  if (cats.length <= 1 && deltaCount === 0) return null
  return html`
    <div class="mem-filters">
      <button class=${`mem-filter ${active.kind === 'all' ? 'on' : ''}`} onClick=${() => onPick({ kind: 'all' })}>전체</button>
      ${cats.length > 1
        ? cats.map(c => {
          const meta = factCategoryMeta(c)
          const tag = c.tag
          const on = active.kind === 'category' && active.tag === tag
          return html`<button key=${tag} class=${`mem-filter ${on ? 'on' : ''}`} onClick=${() => onPick({ kind: 'category', tag })}>${meta.glyph} ${meta.lbl}</button>`
        })
        : null}
      ${deltaCount > 0
        ? html`<button class=${`mem-filter ${active.kind === 'delta' ? 'on' : ''}`} title="이번 revision에서 들어오거나 빠진 기억만" onClick=${() => onPick({ kind: 'delta' })}>± 변경 ${deltaCount}</button>`
        : null}
    </div>`
}

function factTag(fact: MemoryOsFact): string {
  return fact.category.tag
}

function OneKeeperMemoryReal({
  snapshot,
  rows,
  keeperId,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  rows: readonly TurnRecordRow[]
  keeperId: string
}) {
  const storeFilter = useSignal<StoreFilter>({ kind: 'all' })
  const latestPromptRow = latestEntryWithBlocks(rows)
  const latestInputRow = latestEntryWithInputComponents(rows)
  const storeRows = storeRowsFromSnapshot(snapshot)
  const seen = new Set<MemoryOsFactCategoryTag>()
  const cats: MemoryOsFactCategory[] = []
  for (const row of storeRows) {
    const tag = row.fact.category.tag
    if (!seen.has(tag)) {
      seen.add(tag)
      cats.push(row.fact.category)
    }
  }
  const deltaCount = storeRows.filter(row => row.delta !== null).length
  // A chip that no longer has rows behind it (the snapshot changed under the
  // open drawer) falls back to the full list rather than an empty one.
  const requested = storeFilter.value
  const filter: StoreFilter =
    (requested.kind === 'category' && !seen.has(requested.tag))
      || (requested.kind === 'delta' && deltaCount === 0)
      ? { kind: 'all' }
      : requested
  const visibleRows = storeRows.filter(row => storeRowMatches(row, filter))
  return html`
    <${Fragment}>
      <${ReadErrors} snapshot=${snapshot} />
      <${MemoryTrustStrip} snapshot=${snapshot} latestPromptRow=${latestPromptRow} />

      <div class="turn-sec">
        <h4>최종 provider 입력 구성</h4>
        <${MemCompoReal} row=${latestInputRow} />
      </div>

      <div class="turn-sec">
        <h4>회상 연결 · Full Prompt</h4>
        <${MemoryPromptEvidence} snapshot=${snapshot} row=${latestPromptRow} keeperId=${keeperId} />
      </div>

      <div class="turn-sec">
        <h4>현재 기억 계약 · ${snapshot.update_source?.kind ?? 'fresh state'}</h4>
        <${MemoryCurrentContract} snapshot=${snapshot} />
      </div>

      <div class="turn-sec">
        <div class="mem-sec-head">
          <h4>장기 메모리 스토어 · memory-os</h4>
          <span class="mem-n mono">${snapshot.facts.shown}</span>
          <span class="mem-n mono" title=${`revision ${snapshot.revision}: +는 새 current fact, −는 직전 snapshot에서 삭제된 fact`}>추가 ${snapshot.change.added.length} · 제거 ${snapshot.change.removed.length} · 지지 무효화 ${snapshot.change.invalidated.length} · 유지 ${snapshot.change.retained}</span>
        </div>
        ${storeRows.length
          ? html`
            <${Fragment}>
              <${StoreFilters}
                cats=${cats}
                deltaCount=${deltaCount}
                active=${filter}
                onPick=${(next: StoreFilter) => { storeFilter.value = next }}
              />
              <div class="mem-store">
                ${visibleRows.map(row => html`<${FactRow} key=${`${row.delta ?? 'retained'}:${row.fact.memory_id}`} fact=${row.fact} delta=${row.delta} />`)}
              </div>
            </>`
          : html`<div class="mem-empty">장기 메모리 항목 없음.</div>`}
      </div>

      <${SupportInvalidations} snapshot=${snapshot} />

      <div class="turn-sec">
        <h4>최근 회상 · 주입</h4>
        <${RecentRecallTimeline} rows=${rows} />
      </div>
    </>`
}

interface AggregateCategoryCount {
  readonly category: MemoryOsFactCategory
  readonly count: number
}

interface AggregateRecentFact {
  readonly keeperId: string
  readonly fact: MemoryOsFact
}

interface AggregateMemoryRow {
  readonly keeper: MemoryKeeper
  readonly memoryPresent: boolean
  readonly error: string | null
  readonly source: string
  readonly currentFacts: number
  readonly shownFacts: number
  readonly revision: number
  readonly added: number
  readonly removed: number
  readonly recallBlockBytes: number
  readonly latestPrompt: string
  readonly readErrors: number
  // Category tally over this keeper's projected facts (all rows, current or not),
  // and its most-recently-verified facts. Empty for error / no-memory keepers.
  readonly categoryCounts: readonly AggregateCategoryCount[]
  readonly recentFacts: readonly MemoryOsFact[]
}

// Tally facts by the closed typed category tag.
function tallyFactCategories(facts: readonly MemoryOsFact[]): readonly AggregateCategoryCount[] {
  const byTag = new Map<string, AggregateCategoryCount>()
  for (const fact of facts) {
    const tag = factTag(fact)
    const existing = byTag.get(tag)
    byTag.set(tag, existing
      ? { category: existing.category, count: existing.count + 1 }
      : { category: fact.category, count: 1 })
  }
  return [...byTag.values()]
}

// Merge per-keeper category tallies into a fleet distribution, sorted by count
// descending (ties keep first-seen order). Reuses factTag as the merge key.
function mergeAggregateCategoryCounts(
  rows: readonly AggregateMemoryRow[],
): readonly AggregateCategoryCount[] {
  const byTag = new Map<string, AggregateCategoryCount>()
  for (const row of rows) {
    for (const entry of row.categoryCounts) {
      const tag = entry.category.tag
      const existing = byTag.get(tag)
      byTag.set(tag, existing
        ? { category: existing.category, count: existing.count + entry.count }
        : { category: entry.category, count: entry.count })
    }
  }
  return [...byTag.values()].sort((a, b) => b.count - a.count)
}

// Fleet-wide current facts with their owning keeper. Ordering comes from the
// current snapshot, not from a local salience or verification heuristic.
function mergeAggregateFacts(rows: readonly AggregateMemoryRow[]): readonly AggregateRecentFact[] {
  const flattened: AggregateRecentFact[] = []
  for (const row of rows) {
    for (const fact of row.recentFacts) {
      flattened.push({ keeperId: row.keeper.id, fact })
    }
  }
  return flattened
}

function aggregateMemoryRowFromResponse(
  keeper: MemoryKeeper,
  response: TurnRecordsResponse,
): AggregateMemoryRow {
  const latestPromptRow = latestEntryWithBlocks(response.entries)
  const memoryBlock = latestMemoryRecallBlock(latestPromptRow)
  const latestPrompt = latestPromptRow
    ? `${latestPromptRow.record.trace_id}#${latestPromptRow.record.absolute_turn}`
    : 'none'
  const snapshot = response.memory_os
  if (!snapshot) {
    return {
      keeper,
      memoryPresent: false,
      error: null,
      source: response.source ?? 'turn_record',
      currentFacts: 0,
      shownFacts: 0,
      revision: 0,
      added: 0,
      removed: 0,
      recallBlockBytes: memoryBlock?.bytes ?? 0,
      latestPrompt,
      readErrors: 0,
      categoryCounts: [],
      recentFacts: [],
    }
  }
  return {
    keeper,
    memoryPresent: true,
    error: null,
    source: snapshot.snapshot_store,
    currentFacts: snapshot.facts.current,
    shownFacts: snapshot.facts.shown,
    revision: snapshot.revision,
    added: snapshot.change.added.length,
    removed: snapshot.change.removed.length,
    recallBlockBytes: memoryBlock?.bytes ?? 0,
    latestPrompt,
    readErrors: snapshot.read_errors.length,
    categoryCounts: tallyFactCategories(snapshot.facts.items),
    recentFacts: snapshot.facts.items,
  }
}

function aggregateMemoryErrorRow(keeper: MemoryKeeper, error: unknown): AggregateMemoryRow {
  return {
    keeper,
    memoryPresent: false,
    error: error instanceof Error ? error.message : String(error),
    source: 'fetch_error',
    currentFacts: 0,
    shownFacts: 0,
    revision: 0,
    added: 0,
    removed: 0,
    recallBlockBytes: 0,
    latestPrompt: 'none',
    readErrors: 0,
    categoryCounts: [],
    recentFacts: [],
  }
}

type AggregateRowsUpdate = (rows: readonly AggregateMemoryRow[]) => void

function materializedAggregateRows(
  rows: readonly (AggregateMemoryRow | null)[],
): readonly AggregateMemoryRow[] {
  return rows.filter((row): row is AggregateMemoryRow => row !== null)
}

async function fetchAggregateMemoryRows(
  keepers: readonly MemoryKeeper[],
  signal: AbortSignal,
  onRows?: AggregateRowsUpdate,
): Promise<readonly AggregateMemoryRow[]> {
  let rows: readonly (AggregateMemoryRow | null)[] = keepers.map(() => null)
  const publishRows = () => {
    if (!signal.aborted) onRows?.(materializedAggregateRows(rows))
  }
  return Promise.all(keepers.map(async (keeper, index) => {
    let row: AggregateMemoryRow
    try {
      const response = await fetchKeeperTurnRecords(keeper.id, 12, { signal })
      row = aggregateMemoryRowFromResponse(keeper, response)
    } catch (error) {
      if (isAbortError(error)) throw error
      row = aggregateMemoryErrorRow(keeper, error)
    }
    rows = rows.map((current, rowIndex) => rowIndex === index ? row : current)
    publishRows()
    return row
  }))
}

function AggregateMemoryReal({
  keepers,
  rows,
  loading,
  error,
  onPick,
}: {
  keepers: readonly MemoryKeeper[]
  rows: readonly AggregateMemoryRow[] | null
  loading: boolean
  error: string | null
  onPick: (id: string) => void
}) {
  const data = rows ?? []
  const loadedCount = data.length
  const failedCount = data.filter(row => row.error != null).length
  const noMemoryCount = data.filter(row => row.error == null && !row.memoryPresent).length
  const currentTotal = data.reduce((sum, row) => sum + row.currentFacts, 0)
  const shownTotal = data.reduce((sum, row) => sum + row.shownFacts, 0)
  const addedTotal = data.reduce((sum, row) => sum + row.added, 0)
  const removedTotal = data.reduce((sum, row) => sum + row.removed, 0)
  const linkedCount = data.filter(row => row.recallBlockBytes > 0).length
  const recallBytes = data.reduce((sum, row) => sum + row.recallBlockBytes, 0)
  const categoryTotals = mergeAggregateCategoryCounts(data)
  const categorizedFacts = categoryTotals.reduce((sum, entry) => sum + entry.count, 0)
  const recentFacts = mergeAggregateFacts(data)
  const maxRecallBytes = Math.max(1, ...data.map(row => row.recallBlockBytes))
  return html`
    <${Fragment}>
      <div class="turn-sec">
        <h4>전체 memory-os</h4>
        <div class="mem-stats" data-testid="memory-aggregate-stats">
          <div class="mem-stat"><span class="v mono">${keepers.length}</span><span class="k">keeper</span></div>
          <div class="mem-stat"><span class="v mono">${shownTotal}</span><span class="k">스토어 항목</span></div>
          <div class="mem-stat"><span class="v mono">${memFmtBytes(recallBytes)}</span><span class="k">메모리 블록</span></div>
        </div>
        <div class="mem-trust">
          <div class="mem-trust-card">
            <span class="mem-trust-k">keepers</span>
            <span class="mem-trust-v mono">${loadedCount}/${keepers.length} loaded</span>
            <span class="mem-trust-sub mono">${failedCount} failed · ${noMemoryCount} no memory_os</span>
          </div>
          <div class="mem-trust-card">
            <span class="mem-trust-k">facts</span>
            <span class="mem-trust-v mono">${currentTotal}/${shownTotal} current</span>
            <span class="mem-trust-sub mono">current snapshots only</span>
          </div>
          <div class="mem-trust-card">
            <span class="mem-trust-k">prompt links</span>
            <span class="mem-trust-v mono">${linkedCount}/${loadedCount} linked</span>
            <span class="mem-trust-sub mono">${memFmtBytes(recallBytes)} memory_os_recall</span>
          </div>
        </div>
        ${loading ? html`<${DisclosureNote} text="전체 keeper memory-os 집계 불러오는 중." />` : null}
        ${error ? html`<div class="mem-read-error" role="alert">${'⚠'} 전체 집계 실패 — ${error}</div>` : null}
      </div>
      ${categorizedFacts > 0
        ? html`
          <div class="turn-sec">
            <h4>category별 분포 <span class="mem-hint">실제 fact.category</span></h4>
            <div class="mem-kinds-dist">
              ${categoryTotals.map(entry => {
                const meta = factCategoryMeta(entry.category)
                const tag = entry.category.tag
                return html`
                  <div key=${tag} class="mem-kd-row">
                    <span class="mem-kind" style=${{ color: meta.color, borderColor: meta.color }}>${meta.glyph} ${meta.lbl}</span>
                    <div class="mem-kd-bar"><span style=${{ width: `${(entry.count / categorizedFacts) * 100}%` }}></span></div>
                    <span class="mono mem-kd-n">${entry.count}</span>
                  </div>`
              })}
            </div>
          </div>`
        : null}
      <div class="turn-sec">
        <h4>keeper별 메모리 · ${keepers.length}</h4>
        <div class="mem-table">
          <div class="mem-tr mem-th"><span>keeper</span><span>facts</span><span>revision</span><span>delta</span><span>prompt link</span></div>
          ${data.map(row => html`
            <button key=${row.keeper.id} type="button" class="mem-tr" title=${row.error ?? row.source} onClick=${() => onPick(row.keeper.id)}>
              <span class="mem-td-id"><span class=${`mem-dot ${memDotState(row.keeper.status)}`}></span><span class="mono">${row.keeper.id}</span></span>
              ${row.error
                ? html`
                  <span class="mono">error</span>
                  <span class="mono">-</span>
                  <span class="mono">-</span>
                  <span class="mono">${row.error}</span>
                `
                : html`
                  <span class="mono">${row.currentFacts}/${row.shownFacts}</span>
                  <span class="mono">${row.revision}${row.readErrors > 0 ? html` · err ${row.readErrors}` : null}</span>
                  <span class="mono">+${row.added} / −${row.removed}</span>
                  <span class="mem-td-bar">
                    <i style=${{ width: `${(row.recallBlockBytes / maxRecallBytes) * 100}%` }}></i>
                    <b class="mono">${row.recallBlockBytes > 0 ? html`${memFmtBytes(row.recallBlockBytes)} · ${row.latestPrompt}` : html`no memory block · ${row.latestPrompt}`}</b>
                  </span>
                `}
            </button>`)}
        </div>
        ${!loading && data.length === 0
          ? html`<div class="mem-empty">집계할 keeper memory-os 행 없음.</div>`
          : null}
        <${DisclosureNote} text=${`전체 탭은 keeper별 current snapshot을 직접 조회한 읽기 전용 집계 — latest delta +${addedTotal} / −${removedTotal}.`} />
      </div>
      ${recentFacts.length > 0
        ? html`
          <div class="turn-sec">
            <h4>저장된 사실 · 전체 <span class="mem-hint">keeper별 source order</span></h4>
            <div class="mem-store">
              ${recentFacts.map(({ keeperId, fact }) => html`<${FactRow}
                key=${keeperId + fact.memory_id}
                fact=${fact}
                srcOverride=${keeperId}
              />`)}
            </div>
          </div>`
        : null}
    </>`
}

export interface MemoryInspectorProps {
  readonly keeper: MemoryKeeper
  readonly onClose: () => void
  readonly keepers?: readonly MemoryKeeper[]
}

export function MemoryInspector({
  keeper,
  onClose,
  keepers: providedKeepers,
}: MemoryInspectorProps) {
  const keepers = providedKeepers ?? [keeper]
  const scope = useSignal<'one' | 'all'>('one')
  // The keeper the one-scope view is bound to. Starts at the opened keeper and can
  // be re-pointed by clicking an aggregate row (전체 → 개별), mirroring the prototype.
  const pickId = useSignal(keeper.id)
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)
  const aggregateResource = useManagedAsyncResource<readonly AggregateMemoryRow[]>([])
  const activeId = pickId.value
  const keepersKey = keepers.map(k => `${k.id}:${k.status}`).join('|')

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

  // Re-bind the one-scope target to the inbound keeper whenever the prop changes.
  // Without this, reopening/reusing the inspector for a different keeper keeps the
  // previous pickId and would fetch /keepers/<old>/turn-records — a stale keeper
  // identity. The aggregate-row onPick still re-points pickId within an open
  // inspector because that path does not change the keeper prop.
  useEffect(() => {
    pickId.value = keeper.id
  }, [keeper.id, pickId])

  useEffect(() => {
    void resource.load(async (signal) => fetchKeeperTurnRecords(activeId, 24, { signal }))
    return () => {
      resource.cancel()
    }
  }, [activeId, resource])

  const isOne = scope.value === 'one'

  useEffect(() => {
    if (isOne) {
      aggregateResource.cancel()
      return
    }
    aggregateResource.reset([])
    void aggregateResource.load(async (signal) =>
      fetchAggregateMemoryRows(keepers, signal, (rows) => {
        aggregateResource.state.value = { data: rows, loading: true, error: null }
      }))
    return () => {
      aggregateResource.cancel()
    }
  }, [isOne, keepersKey, aggregateResource])

  const state = resource.state.value
  const response = state.data
  const aggregateState = aggregateResource.state.value

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div class="turn-drawer mem-drawer" onClick=${(e: MouseEvent) => e.stopPropagation()}>
        <div class="turn-hd">
          <h3>Keeper 메모리</h3>
          <span class="tid">${isOne ? activeId : '전체 keeper'}</span>
          <div class="mem-scope">
            <button class=${isOne ? 'on' : ''} onClick=${() => { scope.value = 'one' }}>이 keeper</button>
            <button class=${!isOne ? 'on' : ''} onClick=${() => { scope.value = 'all' }}>전체</button>
          </div>
          <button class="turn-close" onClick=${onClose} title="닫기 (Esc)">${'✕'}</button>
        </div>
        <div class="turn-body">
          ${!isOne
            ? html`<${AggregateMemoryReal}
                keepers=${keepers}
                rows=${aggregateState.data}
                loading=${aggregateState.loading}
                error=${aggregateState.error}
                onPick=${(id: string) => { pickId.value = id; scope.value = 'one' }}
              />`
            : state.loading
              ? html`<div class="mem-empty">메모리 불러오는 중…</div>`
              : state.error
                ? html`<div class="mem-read-error" role="alert">${'⚠'} 메모리 불러오기 실패 — ${state.error}</div>`
                : response?.memory_os
                  ? html`<${OneKeeperMemoryReal} snapshot=${response.memory_os} rows=${response.entries} keeperId=${activeId} />`
                  : html`<${MemoryOsMissingState} response=${response} />`}
        </div>
      </div>
    </div>`
}

// MASC v2 — Keeper memory inspector (read-only overlay-drawer).
//
// Pixel-matched to the Claude-Design prototype keeper-v2/memory.jsx — same
// drawer shell, section headers, scope toggle, and `.mem-*` classes
// (memory-inspector-v2.css) — but every datum is REAL, fetched from
// `GET /api/v1/keepers/:name/turn-records` (RFC-keeper-memory-panel-real-data). The prototype's
// fixture model (fabricated `memComposition` magic + the RFC-0247-deleted
// salience/uses/lastUsed score fields) is gone.
//
// Section data sources (RFC-keeper-memory-panel-real-data §4; hybrid treatment confirmed 2026-06-24):
//   컨텍스트 구성        ← real prompt-assembly block bytes (entries[latest].blocks)
//   장기 메모리 스토어    ← real memory_os.facts.items (typed category, provenance, TTL)
//   압축 유지·요약        ← real memory_os.episodes.items (summary + terminal_marker)
//   핀 고정 사실          ⓘ Phase 2 (operator pins — no backend source yet)
//   최근 회상·주입        ⓘ Phase 3 (per-op timeline — no event feed yet)
// The two ⓘ sections render an honest "연결 예정" disclosure, never fabricated
// rows (no-stub): they DISCLOSE absence rather than fake presence.

import { Fragment } from 'preact'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { formatDateTimeKo, formatTimeAgo, formatTimeUntil } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import {
  fetchKeeperTurnRecords,
  type TurnRecordsResponse,
  type MemoryOsTurnRecordSnapshot,
  type MemoryOsEpisodeSummary,
  type MemoryOsFact,
  type MemoryOsFactCategory,
  type MemoryOsSelectionPolicy,
  type TurnBlock,
  type TurnRecordRow,
} from '../api/dashboard'

// Minimal keeper shape the inspector reads. Only `id` (the keeper name used as
// the API key) and `status` (the header dot) are consumed now; `ctx`/`tasks`/
// `traces` remain for call-site back-compat (they drove the removed fabricated
// composition and are no longer read).
export interface MemoryKeeper {
  readonly id: string
  readonly ctx: number
  readonly status: string
  readonly tasks?: number
  readonly traces?: number
}

// Keeper roster fallback for the agent-profile mount (agent-detail-memory.ts)
// when an agent id is outside the live keepers signal. Identity-only — carries
// no memory content (that is fetched per keeper).
export const DEFAULT_MEMORY_KEEPERS: readonly MemoryKeeper[] = [
  { id: 'masc-improver', ctx: 0, status: 'run' },
  { id: 'nick0cave', ctx: 0, status: 'run' },
  { id: 'sangsu', ctx: 0, status: 'run' },
  { id: 'qa-king', ctx: 0, status: 'pause' },
  { id: 'analyst', ctx: 0, status: 'run' },
  { id: 'drifter', ctx: 0, status: 'off' },
]

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
// (lib/types/prompt_block_id.ml — to_string is the wire SSOT). A token outside
// the closed set is an `Other name` block; it keeps its raw label so a new
// block id surfaces verbatim rather than as a silent miscolour.
interface BlockMeta {
  readonly lbl: string
  readonly color: string
}
const PROMPT_BLOCK_META: Readonly<Record<string, BlockMeta>> = {
  persona: { lbl: '페르소나', color: 'var(--text-dim)' },
  continuity: { lbl: '연속성', color: 'var(--info)' },
  dynamic_context: { lbl: '동적 컨텍스트', color: 'var(--volt)' },
  temporal_summary: { lbl: '시간 요약', color: 'var(--status-warn)' },
  claimed_task_nudge: { lbl: '태스크 넛지', color: 'var(--status-ok)' },
  retry_nudge: { lbl: '재시도 넛지', color: 'var(--status-bad)' },
  memory_os_recall: { lbl: '메모리 회상', color: 'var(--volt-strong)' },
  user_model: { lbl: '사용자 모델', color: 'var(--info)' },
  connected_surface: { lbl: '연결 표면', color: 'var(--status-warn)' },
}
export function promptBlockMeta(token: string): BlockMeta {
  return PROMPT_BLOCK_META[token] ?? { lbl: token, color: 'var(--text-dim)' }
}

export interface CompositionPart {
  readonly key: string
  readonly lbl: string
  readonly bytes: number
  readonly color: string
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
      return { key: b.block, lbl: meta.lbl, bytes: b.bytes, color: meta.color }
    })
  const totalBytes = parts.reduce((sum, p) => sum + p.bytes, 0)
  return { totalBytes, parts }
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

// ── fact category meta (real, exhaustive over the typed union) ──
export interface FactKindMeta {
  readonly lbl: string
  readonly glyph: string
  readonly color: string
}
// Exhaustive switch over MemoryOsFactCategory. A new arm added to the OCaml
// `category` sum (and its TS mirror) forces a compile error here via the
// `never` guard — no `_ -> default` swallow, no silent miscolour.
export function factCategoryMeta(category: MemoryOsFactCategory): FactKindMeta {
  switch (category.tag) {
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
    case 'ephemeral':
      return { lbl: '임시', glyph: '◌', color: 'var(--text-dim)' }
    case 'validated_approach':
      return { lbl: '검증된 접근', glyph: '✓', color: 'var(--status-ok)' }
    case 'lesson':
      return { lbl: '교훈', glyph: '★', color: 'var(--volt-strong)' }
    case 'unknown':
      return { lbl: category.raw || '미분류', glyph: '◇', color: 'var(--text-dim)' }
    default: {
      const _exhaustive: never = category
      return _exhaustive
    }
  }
}

// claim age (staleness anchor = reference_time) and TTL display.
function factAgeLabel(fact: MemoryOsFact): string {
  return formatTimeAgo(fact.reference_time)
}
export function factTtlLabel(fact: MemoryOsFact): string {
  if (fact.valid_until == null) return '영구'
  // current ⟺ valid_until is in the future: show the remaining TTL ("…후").
  // formatTimeAgo would floor the future delta to 0 and render "만료 지금",
  // the exact opposite of a not-yet-elapsed deadline. Past expiry keeps "…전".
  return fact.current
    ? `만료 ${formatTimeUntil(fact.valid_until)}`
    : `만료됨 ${formatTimeAgo(fact.valid_until)}`
}

const DEFAULT_FACT_ROW_LIMIT = 12
const LIBRARIAN_UNSTRUCTURED_FALLBACK_MARKER = 'librarian_unstructured_fallback'
type FactVisibilityFilter = 'recallable' | 'diagnostic' | 'all'

export function sortMemoryFactsForReview(facts: readonly MemoryOsFact[]): MemoryOsFact[] {
  return [...facts].sort((a, b) => {
    const aRecallable = a.current && a.prompt_recallable
    const bRecallable = b.current && b.prompt_recallable
    if (aRecallable !== bRecallable) return aRecallable ? -1 : 1
    if (a.current !== b.current) return a.current ? -1 : 1
    return b.reference_time - a.reference_time
  })
}

function isPromptRecallableFact(fact: MemoryOsFact): boolean {
  return fact.current && fact.prompt_recallable
}

function isDiagnosticEvidenceFact(fact: MemoryOsFact): boolean {
  return !isPromptRecallableFact(fact)
}

function formatFactInstant(ts: number, iso: string | null): string {
  return formatDateTimeKo(iso ?? ts)
}

function factClaimKindLabel(fact: MemoryOsFact): string {
  switch (fact.claim_kind) {
    case 'durable_knowledge':
      return 'durable'
    case 'external_state':
      return 'external'
    case 'self_observation':
      return 'self'
    case 'diagnostic':
      return 'diagnostic'
    case null:
      return 'untyped'
    default: {
      const _exhaustive: never = fact.claim_kind
      return _exhaustive
    }
  }
}

export function factSelectionReason(fact: MemoryOsFact): string {
  const meta = factCategoryMeta(fact.category)
  const state = !fact.prompt_recallable
    ? 'diagnostic evidence row'
    : fact.current ? 'active recall candidate' : 'expired evidence row'
  return `${state} · ${meta.lbl} · ${factClaimKindLabel(fact)}`
}

function latestMemoryRecallBlock(row: TurnRecordRow | null): TurnBlock | null {
  return row?.record.blocks.find(block => block.block === 'memory_os_recall') ?? null
}

// ── rendering ──

function MemBar({ parts, total }: { parts: readonly CompositionPart[]; total: number }) {
  return html`
    <div class="mem-bar" title="프롬프트 구성 (bytes)">
      ${parts.map(p => html`<span key=${p.key} style=${{ width: `${(p.bytes / total) * 100}%`, background: p.color }}></span>`)}
    </div>`
}

function MemCompoReal({ row }: { row: TurnRecordRow | null }) {
  const blocks = row?.record.blocks ?? []
  const { totalBytes, parts } = memCompositionFromBlocks(blocks)
  if (!row || totalBytes === 0) {
    return html`<div class="mem-empty">조립된 프롬프트 블록 없음 — 활성 컨텍스트 없음.</div>`
  }
  const inputTok = row.record.input_tokens
  const ctxWin = row.record.context_window
  const pct = inputTok != null && ctxWin != null && ctxWin > 0
    ? Math.round((inputTok / ctxWin) * 100)
    : null
  return html`
    <div class="mem-compo">
      <div class="mem-compo-head">
        <span class="mono mem-compo-tot">${memFmtBytes(totalBytes)}</span>
        <span class="mem-compo-sub">
          ${inputTok != null
            ? html`${memFmtTok(inputTok)} tok${ctxWin != null ? html` / ${memFmtTok(ctxWin)} 윈도우` : null}${pct != null ? html` · ${pct}%` : null}`
            : html`${parts.length}개 블록`}
        </span>
      </div>
      <${MemBar} parts=${parts} total=${totalBytes} />
      <div class="mem-legend">
        ${parts.map(p => html`
          <div key=${p.key} class="mem-leg">
            <span class="mem-leg-sw" style=${{ background: p.color }}></span>
            <span class="mem-leg-lbl">${p.lbl}</span>
            <span class="mem-leg-v mono">${memFmtBytes(p.bytes)}</span>
          </div>`)}
      </div>
    </div>`
}

function MemoryTrustStrip({
  snapshot,
  latestPromptRow,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  latestPromptRow: TurnRecordRow | null
}) {
  const policy = snapshot.selection_policy
  const memoryBlock = latestMemoryRecallBlock(latestPromptRow)
  const recallableFacts = snapshot.facts.items.filter(isPromptRecallableFact).length
  const diagnosticFacts = snapshot.facts.items.filter(isDiagnosticEvidenceFact).length
  const promptTurn = latestPromptRow
    ? `${latestPromptRow.record.trace_id}#${latestPromptRow.record.absolute_turn}`
    : 'none'
  const scopeLabel = policy?.shared_scope
    ? `${policy.keeper_scope} + ${policy.shared_scope}`
    : (policy?.keeper_scope ?? snapshot.keeper)
  return html`
    <div class="mem-trust">
      <div class="mem-trust-card">
        <span class="mem-trust-k">store</span>
        <span class="mem-trust-v mono">${recallableFacts}/${snapshot.facts.shown} recallable</span>
        <span class="mem-trust-sub mono">${diagnosticFacts} diagnostic/evidence · ${snapshot.source}</span>
      </div>
      <div class="mem-trust-card">
        <span class="mem-trust-k">scope</span>
        <span class="mem-trust-v mono">${scopeLabel}</span>
        <span class="mem-trust-sub">${policy?.shared_scope ? 'private + shared recall tiers' : 'keeper-local recall tier'}</span>
      </div>
      <div class="mem-trust-card">
        <span class="mem-trust-k">prompt link</span>
        <span class="mem-trust-v mono">${memoryBlock ? `${memFmtBytes(memoryBlock.bytes)} memory_os_recall` : 'no memory block'}</span>
        <span class="mem-trust-sub mono">${promptTurn}</span>
      </div>
    </div>
  `
}

function MemoryPolicyDisclosure({ policy }: { policy: MemoryOsSelectionPolicy | null }) {
  if (!policy) {
    return html`<${DisclosureNote} text="selection_policy 없음 — 대시보드는 fact timestamps/provenance만 표시." />`
  }
  return html`
    <div class="mem-policy">
      <div class="mem-policy-row"><span>private facts</span><code>${policy.facts_source}</code><b>dashboard ${policy.dashboard_fact_tail_limit} · prompt ${policy.recall_private_fact_limit}</b></div>
      ${policy.shared_scope && policy.shared_facts_source
        ? html`<div class="mem-policy-row"><span>shared facts</span><code>${policy.shared_facts_source}</code><b>${policy.shared_scope} · prompt ${policy.recall_shared_fact_limit}</b></div>`
        : null}
      <div class="mem-policy-row"><span>episodes</span><code>${policy.episodes_source}</code><b>dashboard ${policy.dashboard_episode_tail_limit} · prompt ${policy.recall_episode_limit}</b></div>
      <div class="mem-policy-row"><span>librarian</span><code>${policy.category_source} + ${policy.claim_kind_source}</code><b>typed labels</b></div>
      <div class="mem-policy-row"><span>prompt</span><code>${policy.recall_block}</code><b>${policy.prompt_record}</b></div>
    </div>
  `
}

function MemoryPromptEvidence({
  snapshot,
  row,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  row: TurnRecordRow | null
}) {
  const memoryBlock = latestMemoryRecallBlock(row)
  return html`
    <div class="mem-prompt-evidence">
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">1</span>
        <div><b>librarian</b><span>${snapshot.producer}</span></div>
      </div>
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">2</span>
        <div><b>store</b><span class="mono">${snapshot.facts_store}</span></div>
      </div>
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">3</span>
        <div><b>recall block</b><span class="mono">${memoryBlock ? `${memoryBlock.digest.slice(0, 12)} · ${memFmtBytes(memoryBlock.bytes)}` : 'not present in latest prompt record'}</span></div>
      </div>
      <div class="mem-prompt-step">
        <span class="mem-prompt-n">4</span>
        <div><b>Full Prompt</b><span>raw text not persisted here; turn-record keeps ordered block digests and byte sizes.</span></div>
      </div>
      ${row ? html`
        <div class="mem-prompt-foot mono">
          latest assembly ${row.record.trace_id}#${row.record.absolute_turn} · ${formatFactInstant(row.record.ts, null)}
        </div>
      ` : null}
    </div>
  `
}

function FactRow({ fact }: { fact: MemoryOsFact }) {
  const meta = factCategoryMeta(fact.category)
  const provenance = `${fact.source.trace_id}#${fact.source.turn}`
  return html`
    <div class="mem-store-row">
      <span class="mem-kind" style=${{ color: meta.color, borderColor: meta.color }}>${meta.glyph} ${meta.lbl}</span>
      <div class="mem-store-main">
        <div class="mem-store-text">${fact.claim}</div>
        <div class="mem-store-meta">
          <span class="mono">저장 ${formatFactInstant(fact.first_seen, fact.first_seen_iso)}</span>
          <span class="mono">기준 ${factAgeLabel(fact)}</span>
          ${fact.last_verified_at != null
            ? html`<span class="mono">검증 ${formatFactInstant(fact.last_verified_at, null)}</span>`
            : null}
          <span class=${`mono ${fact.current ? '' : 'mem-expired'}`}>${factTtlLabel(fact)}</span>
          <span class="mem-src mono">${provenance}</span>
        </div>
        <div class="mem-store-why">${factSelectionReason(fact)}</div>
      </div>
    </div>`
}

// Honest disclosure for a section whose backend source lands in a later RFC
// phase. NOT a stub: it states the absence and the phase, renders no fabricated
// data, and is visually distinct from a real-data section.
function DisclosureNote({ text }: { text: string }) {
  return html`<div class="mem-empty mem-disclosure">${'ⓘ'} ${text}</div>`
}

function ReadErrors({ snapshot }: { snapshot: MemoryOsTurnRecordSnapshot }) {
  if (snapshot.read_errors.length === 0) return null
  const text = snapshot.read_errors.map(e => `${e.scope}: ${e.error}`).join(' · ')
  return html`<div class="mem-read-error" role="alert">${'⚠'} 읽기 오류 — ${text}</div>`
}

function memDotState(status: string): 'ok' | 'idle' | 'bad' {
  return status === 'run' ? 'ok' : status === 'pause' ? 'idle' : 'bad'
}

function CategoryFilters({
  cats,
  active,
  onPick,
}: {
  cats: readonly MemoryOsFactCategory[]
  active: string
  onPick: (tag: string) => void
}) {
  if (cats.length <= 1) return null
  return html`
    <div class="mem-filters">
      <button class=${`mem-filter ${active === 'all' ? 'on' : ''}`} onClick=${() => onPick('all')}>전체</button>
      ${cats.map(c => {
        const meta = factCategoryMeta(c)
        const tag = c.tag === 'unknown' ? `unknown:${c.raw}` : c.tag
        return html`<button key=${tag} class=${`mem-filter ${active === tag ? 'on' : ''}`} onClick=${() => onPick(tag)}>${meta.glyph} ${meta.lbl}</button>`
      })}
    </div>`
}

function factTag(fact: MemoryOsFact): string {
  return fact.category.tag === 'unknown' ? `unknown:${fact.category.raw}` : fact.category.tag
}

function OneKeeperMemoryReal({
  snapshot,
  rows,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  rows: readonly TurnRecordRow[]
}) {
  const kindFilter = useSignal<string>('all')
  const visibilityFilter = useSignal<FactVisibilityFilter>('recallable')
  const factRowLimit = useSignal(DEFAULT_FACT_ROW_LIMIT)
  const latestPromptRow = latestEntryWithBlocks(rows)
  const facts = sortMemoryFactsForReview(snapshot.facts.items)
  const recallableFacts = facts.filter(isPromptRecallableFact)
  const diagnosticFacts = facts.filter(isDiagnosticEvidenceFact)
  const allEpisodes = [...snapshot.episodes.items].reverse()
  const episodes = allEpisodes
    .filter(ep => ep.terminal_marker !== LIBRARIAN_UNSTRUCTURED_FALLBACK_MARKER)
    .slice(0, 5)
  const fallbackEpisodes = allEpisodes
    .filter(ep => ep.terminal_marker === LIBRARIAN_UNSTRUCTURED_FALLBACK_MARKER)
    .slice(0, 5)
  // distinct categories present, in first-seen order, deduped by tag
  const seen = new Set<string>()
  const cats: MemoryOsFactCategory[] = []
  for (const f of facts) {
    const tag = factTag(f)
    if (!seen.has(tag)) {
      seen.add(tag)
      cats.push(f.category)
    }
  }
  const filter = kindFilter.value
  const visibilityRows =
    visibilityFilter.value === 'recallable'
      ? recallableFacts
      : visibilityFilter.value === 'diagnostic'
        ? diagnosticFacts
        : facts
  const storeRows =
    filter === 'all' ? visibilityRows : visibilityRows.filter(f => factTag(f) === filter)
  const visibleStoreRows = storeRows.slice(0, factRowLimit.value)
  const hiddenStoreRows = Math.max(0, storeRows.length - visibleStoreRows.length)
  const showFallbackEpisodes = visibilityFilter.value !== 'recallable'

  return html`
    <${Fragment}>
      <${ReadErrors} snapshot=${snapshot} />
      <${MemoryTrustStrip} snapshot=${snapshot} latestPromptRow=${latestPromptRow} />

      <div class="turn-sec">
        <h4>컨텍스트 구성</h4>
        <${MemCompoReal} row=${latestPromptRow} />
      </div>

      <div class="turn-sec">
        <h4>회상 연결 · Full Prompt</h4>
        <${MemoryPromptEvidence} snapshot=${snapshot} row=${latestPromptRow} />
      </div>

      <div class="turn-sec">
        <h4>수집 기준 · librarian</h4>
        <${MemoryPolicyDisclosure} policy=${snapshot.selection_policy} />
      </div>

      <div class="turn-sec">
        <h4>핀 고정 사실</h4>
        <${DisclosureNote} text="operator 핀은 Phase 2에서 연결 예정 — 현재 백엔드 소스 없음." />
      </div>

      <div class="turn-sec">
        <div class="mem-sec-head">
          <h4>장기 메모리 스토어 · memory-os</h4>
          <span class="mem-n mono">${recallableFacts.length}/${snapshot.facts.shown}</span>
        </div>
        ${facts.length
          ? html`
            <${Fragment}>
              <div class="mem-filters">
                <button
                  class=${`mem-filter ${visibilityFilter.value === 'recallable' ? 'on' : ''}`}
                  onClick=${() => { visibilityFilter.value = 'recallable'; factRowLimit.value = DEFAULT_FACT_ROW_LIMIT }}
                >회상 ${recallableFacts.length}</button>
                <button
                  class=${`mem-filter ${visibilityFilter.value === 'diagnostic' ? 'on' : ''}`}
                  onClick=${() => { visibilityFilter.value = 'diagnostic'; factRowLimit.value = DEFAULT_FACT_ROW_LIMIT }}
                >진단/증거 ${diagnosticFacts.length}</button>
                <button
                  class=${`mem-filter ${visibilityFilter.value === 'all' ? 'on' : ''}`}
                  onClick=${() => { visibilityFilter.value = 'all'; factRowLimit.value = DEFAULT_FACT_ROW_LIMIT }}
                >전체 ${facts.length}</button>
              </div>
              <${CategoryFilters} cats=${cats} active=${filter} onPick=${(t: string) => { kindFilter.value = t }} />
              <div class="mem-store">${visibleStoreRows.map(f => html`<${FactRow} key=${factTag(f) + f.source.trace_id + f.source.turn + f.claim} fact=${f} />`)}</div>
              ${hiddenStoreRows > 0
                ? html`
                  <button
                    type="button"
                    class="mem-more"
                    onClick=${() => { factRowLimit.value += DEFAULT_FACT_ROW_LIMIT }}
                  >
                    ${hiddenStoreRows}개 더 보기
                  </button>
                `
                : null}
            </>`
          : html`<div class="mem-empty">장기 메모리 항목 없음.</div>`}
      </div>

      <div class="turn-sec">
        <h4>최근 회상 · 주입</h4>
        <${DisclosureNote} text="회상·주입 op 타임라인은 Phase 3에서 연결 예정 — 현재 event feed 없음." />
      </div>

      <div class="turn-sec">
        <h4>압축 유지 · 요약</h4>
        ${episodes.length
          ? html`
            <${Fragment}>
              <div class="mem-store">
                ${episodes.map(ep => html`<${EpisodeRow} key=${ep.trace_id + ep.generation} episode=${ep} />`)}
              </div>
              <${DisclosureNote} text="유지/요약/폐기 3열 diff는 Phase 3에서 연결 예정 — episode 요약만 표시." />
            </>`
          : html`<div class="mem-empty">압축(episode) 이력 없음.</div>`}
      </div>

      ${showFallbackEpisodes && fallbackEpisodes.length
        ? html`
          <div class="turn-sec">
            <h4>진단 fallback · librarian</h4>
            <div class="mem-store">
              ${fallbackEpisodes.map(ep => html`<${EpisodeRow} key=${ep.trace_id + ep.generation} episode=${ep} />`)}
            </div>
            <${DisclosureNote} text="unstructured fallback은 recall 후보가 아니라 librarian 진단 증거로 분리 표시." />
          </div>
        `
        : null}
    </>`
}

function EpisodeRow({ episode }: { episode: MemoryOsEpisodeSummary }) {
  return html`
    <div class="mem-store-row">
      <span class="mem-kind" style=${{ color: episode.current ? 'var(--status-ok)' : 'var(--text-dim)', borderColor: episode.current ? 'var(--status-ok)' : 'var(--text-dim)' }}>
        ${'◉'} g${episode.generation.toString().padStart(4, '0')}
      </span>
      <div class="mem-store-main">
        <div class="mem-store-text">${episode.summary}</div>
        <div class="mem-store-meta">
          <span class="mono">${episode.claim_count} claims</span>
          ${episode.terminal_marker
            ? html`<span class="mem-tag">terminal=${episode.terminal_marker}</span>`
            : null}
          <span class=${`mono ${episode.current ? '' : 'mem-expired'}`}>${episode.current ? '활성' : '만료'}</span>
          <span class="mem-src mono">${episode.trace_id}</span>
        </div>
      </div>
    </div>`
}

// Aggregate (전체) scope: real keeper roster (id + status dot are real) with an
// honest note that per-keeper memory aggregation needs N× turn-records fetches
// and lands later. No fabricated memory totals.
function AggregateDeferred({ keepers }: { keepers: readonly MemoryKeeper[] }) {
  return html`
    <${Fragment}>
      <div class="turn-sec">
        <h4>전체 keeper</h4>
        <${DisclosureNote} text="전체 집계는 keeper별 turn-records를 모아야 하므로 추후 연결 — 현재는 단일 keeper 실데이터만." />
      </div>
      <div class="turn-sec">
        <h4>keeper 로스터 · ${keepers.length}</h4>
        <div class="mem-table">
          <div class="mem-tr mem-th"><span>keeper</span><span>상태</span></div>
          ${keepers.map(k => html`
            <div key=${k.id} class="mem-tr">
              <span class="mem-td-id"><span class=${`mem-dot ${memDotState(k.status)}`}></span><span class="mono">${k.id}</span></span>
              <span class="mono">${k.status}</span>
            </div>`)}
        </div>
      </div>
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
  keepers = DEFAULT_MEMORY_KEEPERS,
}: MemoryInspectorProps) {
  const scope = useSignal<'one' | 'all'>('one')
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)
  const activeId = keeper.id

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

  useEffect(() => {
    void resource.load(async (signal) => fetchKeeperTurnRecords(activeId, 24, { signal }))
    return () => {
      resource.cancel()
    }
  }, [activeId, resource])

  const isOne = scope.value === 'one'
  const state = resource.state.value
  const response = state.data

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
            ? html`<${AggregateDeferred} keepers=${keepers} />`
            : state.loading
              ? html`<div class="mem-empty">메모리 불러오는 중…</div>`
              : state.error
                ? html`<div class="mem-read-error" role="alert">${'⚠'} 메모리 불러오기 실패 — ${state.error}</div>`
                : response?.memory_os
                  ? html`<${OneKeeperMemoryReal} snapshot=${response.memory_os} rows=${response.entries} />`
                  : html`<div class="mem-empty">memory-os 소스 없음 — 이 keeper의 turn-records가 비어 있음.</div>`}
        </div>
      </div>
    </div>`
}

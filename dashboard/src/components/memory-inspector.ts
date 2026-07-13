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
//   최근 회상·주입        ← real memory_os_recall prompt blocks (entries[*].blocks)
// Any future-only section must render an honest disclosure rather than fabricated
// rows (no-stub): disclose absence instead of faking presence.

import { Fragment } from 'preact'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { formatDateTimeKo, formatTimeAgo, formatTimeUntil } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { isAbortError } from '../lib/async-state'
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
  // Whether this block is the memory-os contribution to the prompt. Mirrors the
  // prototype MEM_BLOCKS `mem` flag (memory.jsx) — only memory_os_recall
  // carries recalled memory; the rest are persona/context/surface.
  readonly mem: boolean
}
const PROMPT_BLOCK_META: Readonly<Record<string, BlockMeta>> = {
  persona: { lbl: '페르소나', color: 'var(--text-dim)', mem: false },
  continuity: { lbl: '연속성', color: 'var(--info)', mem: false },
  dynamic_context: { lbl: '동적 컨텍스트', color: 'var(--volt)', mem: false },
  temporal_summary: { lbl: '시간 요약', color: 'var(--status-warn)', mem: false },
  claimed_task_nudge: { lbl: '태스크 넛지', color: 'var(--status-ok)', mem: false },
  retry_nudge: { lbl: '재시도 넛지', color: 'var(--status-bad)', mem: false },
  memory_os_recall: { lbl: '메모리 회상', color: 'var(--volt-strong)', mem: true },
  connected_surface: { lbl: '연결 표면', color: 'var(--status-warn)', mem: false },
}
export function promptBlockMeta(token: string): BlockMeta {
  return PROMPT_BLOCK_META[token] ?? { lbl: token, color: 'var(--text-dim)', mem: false }
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

export function sortMemoryFactsForReview(facts: readonly MemoryOsFact[]): MemoryOsFact[] {
  return [...facts]
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
  const state = fact.current ? 'current row' : 'expired row'
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
            <span class="mem-leg-lbl">${p.lbl}${p.mem ? html`<span class="mem-leg-tag">메모리</span>` : null}</span>
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
  const promptTurn = latestPromptRow
    ? `${latestPromptRow.record.trace_id}#${latestPromptRow.record.absolute_turn}`
    : 'none'
  const scopeLabel = policy?.keeper_scope ?? snapshot.keeper
  return html`
    <div class="mem-trust">
      <div class="mem-trust-card">
        <span class="mem-trust-k">store</span>
        <span class="mem-trust-v mono">${snapshot.facts.current}/${snapshot.facts.shown} current</span>
        <span class="mem-trust-sub mono">${snapshot.facts.expired} expired · ${snapshot.source}</span>
      </div>
      <div class="mem-trust-card">
        <span class="mem-trust-k">scope</span>
        <span class="mem-trust-v mono">${scopeLabel}</span>
        <span class="mem-trust-sub">keeper-local persisted source order</span>
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
      <div class="mem-policy-row"><span>facts</span><code>${policy.facts_source}</code><b>all rows · source order</b></div>
      <div class="mem-policy-row"><span>episodes</span><code>${policy.episodes_source}</code><b>all rows · source order</b></div>
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

function RecentRecallTimeline({ rows }: { rows: readonly TurnRecordRow[] }) {
  const injections = recentMemoryRecallInjections(rows)
  if (injections.length === 0) {
    return html`<div class="mem-empty">최근 memory_os_recall 주입 없음.</div>`
  }
  return html`
    <div class="mem-store">
      ${injections.map(inj => html`
        <div class="mem-tl-row" key=${`${inj.traceId}:${inj.turn}:${inj.digest}`}>
          <span class="mem-kind">회상</span>
          <span class="mem-tl-at">${formatTimeAgo(inj.ts)}</span>
          <span class="mem-tl-text">
            <span class="mono">${inj.traceId}#${inj.turn}</span>
            <span class="mono"> · ${inj.digest}</span>
          </span>
          <span class="mem-tl-tok">${memFmtBytes(inj.bytes)}</span>
        </div>
      `)}
    </div>
  `
}

// `srcOverride` replaces the trace#turn provenance in the meta row with a caller
// label (used by the aggregate "recent facts" list to show the owning keeper).
function FactRow({ fact, srcOverride }: { fact: MemoryOsFact; srcOverride?: string }) {
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
          <span class=${`mem-ttl ${fact.current ? 'current' : 'expired'}`}>${factTtlLabel(fact)}</span>
          <span class="mem-src mono">${srcOverride ?? provenance}</span>
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
        : html`이 keeper의 turn-records가 비어 있습니다.`}
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
  const latestPromptRow = latestEntryWithBlocks(rows)
  const facts = sortMemoryFactsForReview(snapshot.facts.items)
  const episodes = snapshot.episodes.items
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
  const effectiveFilter = filter === 'all' || seen.has(filter) ? filter : 'all'
  const storeRows =
    effectiveFilter === 'all' ? facts : facts.filter(f => factTag(f) === effectiveFilter)
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
        <div class="mem-sec-head">
          <h4>장기 메모리 스토어 · memory-os</h4>
          <span class="mem-n mono">${snapshot.facts.shown}</span>
        </div>
        ${facts.length
          ? html`
            <${Fragment}>
              <${CategoryFilters} cats=${cats} active=${effectiveFilter} onPick=${(t: string) => { kindFilter.value = t }} />
              ${storeRows.length > 0
                ? html`<div class="mem-store">${storeRows.map(f => html`<${FactRow} key=${factTag(f) + f.source.trace_id + f.source.turn + f.claim} fact=${f} />`)}</div>`
                : html`
                  <div class="mem-empty">
                    현재 필터에 표시할 memory-os fact가 없습니다.<br />
                    <span class="mono">current=${snapshot.facts.current} · expired=${snapshot.facts.expired} · total=${facts.length}</span>
                  </div>
                `}
            </>`
          : html`<div class="mem-empty">장기 메모리 항목 없음.</div>`}
      </div>

      <div class="turn-sec">
        <h4>최근 회상 · 주입</h4>
        <${RecentRecallTimeline} rows=${rows} />
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
    </>`
}

function EpisodeRow({ episode }: { episode: MemoryOsEpisodeSummary }) {
  return html`
    <div class="mem-store-row">
      <span class="mem-kind" style=${{ color: episode.current ? 'var(--status-ok)' : 'var(--text-dim)', borderColor: episode.current ? 'var(--status-ok)' : 'var(--text-dim)' }}>
        ${'◉'} g${episode.generation.toString().padStart(4, '0')}
      </span>
      <div class="mem-store-main">
        <div class="mem-store-text">
          ${episode.summary}
          ${episode.source_turn_range
            ? html`<span class="mem-tl-range mono">turn ${episode.source_turn_range[0]}–${episode.source_turn_range[1]}</span>`
            : null}
        </div>
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

// Bound on the recent-facts list each keeper contributes to (and the fleet-wide
// slice) so the aggregate never carries an unbounded fact tail into the client.

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
  readonly expiredFacts: number
  readonly shownFacts: number
  readonly episodes: number
  readonly recallBlockBytes: number
  readonly latestPrompt: string
  readonly readErrors: number
  // Category tally over this keeper's projected facts (all rows, current or not),
  // and its most-recently-verified facts. Empty for error / no-memory keepers.
  readonly categoryCounts: readonly AggregateCategoryCount[]
  readonly recentFacts: readonly MemoryOsFact[]
}

// Tally facts by typed category tag. An `unknown` arm keys on its raw label so
// two distinct out-of-vocabulary categories stay separate rows, not merged.
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
      const tag = entry.category.tag === 'unknown' ? `unknown:${entry.category.raw}` : entry.category.tag
      const existing = byTag.get(tag)
      byTag.set(tag, existing
        ? { category: existing.category, count: existing.count + entry.count }
        : { category: entry.category, count: entry.count })
    }
  }
  return [...byTag.values()].sort((a, b) => b.count - a.count)
}

// Fleet-wide most-recently-verified facts with their owning keeper, newest first
// (reference_time = last_verified_at else first_seen). NOT a salience sort (RFC-0247).
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
      expiredFacts: 0,
      shownFacts: 0,
      episodes: 0,
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
    source: snapshot.source,
    currentFacts: snapshot.facts.current,
    expiredFacts: snapshot.facts.expired,
    shownFacts: snapshot.facts.shown,
    episodes: snapshot.episodes.items.length,
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
    expiredFacts: 0,
    shownFacts: 0,
    episodes: 0,
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
  const expiredTotal = data.reduce((sum, row) => sum + row.expiredFacts, 0)
  const episodeTotal = data.reduce((sum, row) => sum + row.episodes, 0)
  const linkedCount = data.filter(row => row.recallBlockBytes > 0).length
  const recallBytes = data.reduce((sum, row) => sum + row.recallBlockBytes, 0)
  const categoryTotals = mergeAggregateCategoryCounts(data)
  const categorizedFacts = categoryTotals.reduce((sum, entry) => sum + entry.count, 0)
  const recentFacts = mergeAggregateFacts(data)
  return html`
    <${Fragment}>
      <div class="turn-sec">
        <h4>전체 memory-os</h4>
        <div class="mem-trust">
          <div class="mem-trust-card">
            <span class="mem-trust-k">keepers</span>
            <span class="mem-trust-v mono">${loadedCount}/${keepers.length} loaded</span>
            <span class="mem-trust-sub mono">${failedCount} failed · ${noMemoryCount} no memory_os</span>
          </div>
          <div class="mem-trust-card">
            <span class="mem-trust-k">facts</span>
            <span class="mem-trust-v mono">${currentTotal}/${shownTotal} current</span>
            <span class="mem-trust-sub mono">${expiredTotal} expired</span>
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
                const tag = entry.category.tag === 'unknown' ? `unknown:${entry.category.raw}` : entry.category.tag
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
          <div class="mem-tr mem-th"><span>keeper</span><span>current</span><span>expired</span><span>episode</span><span>prompt link</span></div>
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
                  <span class="mono">${row.expiredFacts}${row.readErrors > 0 ? html` · err ${row.readErrors}` : null}</span>
                  <span class="mono">${row.episodes}</span>
                  <span class="mono">${row.recallBlockBytes > 0 ? html`${memFmtBytes(row.recallBlockBytes)} · ${row.latestPrompt}` : html`no memory block · ${row.latestPrompt}`}</span>
                `}
            </button>`)}
        </div>
        ${!loading && data.length === 0
          ? html`<div class="mem-empty">집계할 keeper memory-os 행 없음.</div>`
          : null}
        <${DisclosureNote} text=${`전체 탭은 keeper별 turn-records를 직접 조회한 읽기 전용 집계 — episodes ${episodeTotal}.`} />
      </div>
      ${recentFacts.length > 0
        ? html`
          <div class="turn-sec">
            <h4>저장된 사실 · 전체 <span class="mem-hint">keeper별 source order</span></h4>
            <div class="mem-store">
              ${recentFacts.map(({ keeperId, fact }) => html`<${FactRow}
                key=${keeperId + factTag(fact) + fact.source.trace_id + fact.source.turn + fact.claim}
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
  keepers = DEFAULT_MEMORY_KEEPERS,
}: MemoryInspectorProps) {
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
                  ? html`<${OneKeeperMemoryReal} snapshot=${response.memory_os} rows=${response.entries} />`
                  : html`<${MemoryOsMissingState} response=${response} />`}
        </div>
      </div>
    </div>`
}

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
import { formatTimeAgo } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import {
  fetchKeeperTurnRecords,
  type TurnRecordsResponse,
  type MemoryOsTurnRecordSnapshot,
  type MemoryOsEpisodeSummary,
  type MemoryOsFact,
  type MemoryOsFactCategory,
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

// Blocks of that row (thin accessor; same row MemCompoReal renders figures from).
export function latestEntryBlocks(rows: readonly TurnRecordRow[]): readonly TurnBlock[] {
  return latestEntryWithBlocks(rows)?.record.blocks ?? []
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
function factTtlLabel(fact: MemoryOsFact): string {
  if (fact.valid_until == null) return '영구'
  return fact.current
    ? `만료 ${formatTimeAgo(fact.valid_until)}`
    : `만료됨 ${formatTimeAgo(fact.valid_until)}`
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

function FactRow({ fact }: { fact: MemoryOsFact }) {
  const meta = factCategoryMeta(fact.category)
  const provenance = `${fact.source.trace_id}#${fact.source.turn}`
  return html`
    <div class="mem-store-row">
      <span class="mem-kind" style=${{ color: meta.color, borderColor: meta.color }}>${meta.glyph} ${meta.lbl}</span>
      <div class="mem-store-main">
        <div class="mem-store-text">${fact.claim}</div>
        <div class="mem-store-meta">
          <span class="mono">${factAgeLabel(fact)}</span>
          <span class=${`mono ${fact.current ? '' : 'mem-expired'}`}>${factTtlLabel(fact)}</span>
          ${fact.external_ref
            ? html`<span class="mem-tag">${fact.external_ref.kind} ${fact.external_ref.id}</span>`
            : null}
          <span class="mem-src mono">${provenance}</span>
        </div>
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
  const facts = snapshot.facts.items
  const episodes = [...snapshot.episodes.items].reverse().slice(0, 5)
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
  const storeRows = filter === 'all' ? facts : facts.filter(f => factTag(f) === filter)

  return html`
    <${Fragment}>
      <${ReadErrors} snapshot=${snapshot} />

      <div class="turn-sec">
        <h4>컨텍스트 구성</h4>
        <${MemCompoReal} row=${latestEntryWithBlocks(rows)} />
      </div>

      <div class="turn-sec">
        <h4>핀 고정 사실</h4>
        <${DisclosureNote} text="operator 핀은 Phase 2에서 연결 예정 — 현재 백엔드 소스 없음." />
      </div>

      <div class="turn-sec">
        <div class="mem-sec-head">
          <h4>장기 메모리 스토어 · memory-os</h4>
          <span class="mem-n mono">${snapshot.facts.current}/${snapshot.facts.shown}</span>
        </div>
        ${facts.length
          ? html`
            <${Fragment}>
              <${CategoryFilters} cats=${cats} active=${filter} onPick=${(t: string) => { kindFilter.value = t }} />
              <div class="mem-store">${storeRows.map(f => html`<${FactRow} key=${factTag(f) + f.source.trace_id + f.source.turn + f.claim} fact=${f} />`)}</div>
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

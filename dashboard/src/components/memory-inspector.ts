// MASC v2 — Keeper memory inspector (read-only overlay-drawer).
//
// Pixel-matched port of the Claude-Design prototype:
//   keeper-v2/memory.jsx        (rendering + scope toggle)
//   keeper-v2/memory-data.jsx   (model: pinned facts, long-term store,
//                                recall timeline, context composition)
//   keeper-v2/styles/memory.css (.mem-* — see memory-inspector-v2.css)
//
// The prototype reads from window.KEEPERS / window.COMPACTIONS globals.
// Here the data is typed and injectable (props) so the component is
// decoupled and unit-testable; the ported fixture is the default. The
// rendering — every section, glyph, Korean/English string, and the
// context-composition math — mirrors the prototype 1:1.
//
// Drawer shell: .turn-overlay / .turn-drawer (ported in
// memory-inspector-v2.css, which the *-v2.css glob in main.ts eagerly
// imports). Scope toggle: 이 keeper / 전체 (memory.jsx:233-234).

import { Fragment } from 'preact'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'

// WORKAROUND: nested fragments use the Fragment tag, not htm's empty-string-tag
// form. An empty string tag makes preact call document.createElement('') on
// nested vnodes, which throws InvalidCharacterError in both jsdom and happy-dom
// (and real browsers). An empty-string fragment only survives as a render *root*
// because the test harness wraps it. Root cause: htm represents a fragment via
// the Fragment export, not an empty tag name. This component is currently
// imported nowhere, so the crash was never exercised; wiring is a later wave.

// ── Window-window constant (memory-data.jsx:116 → ctx * 200000) ──
const CONTEXT_WINDOW_TOK = 200000

// ── store-entry kinds → label + glyph + tone class (memory-data.jsx:9-15) ──
export type MemKind = 'fact' | 'decision' | 'pattern' | 'pref' | 'entity'
interface MemKindMeta {
  readonly lbl: string
  readonly glyph: string
  readonly cls: string
}
export const MEM_KINDS: Readonly<Record<MemKind, MemKindMeta>> = {
  fact: { lbl: '사실', glyph: '◈', cls: 'fact' },
  decision: { lbl: '결정', glyph: '◆', cls: 'decision' },
  pattern: { lbl: '패턴', glyph: '◉', cls: 'pattern' },
  pref: { lbl: '선호', glyph: '○', cls: 'pref' },
  entity: { lbl: '개체', glyph: '▢', cls: 'entity' },
}

// ── recall-timeline operations (memory-data.jsx:18-24) ──
export type MemOp = 'recall' | 'inject' | 'pin' | 'compact' | 'evict'
interface MemOpMeta {
  readonly lbl: string
  readonly glyph: string
  readonly cls: string
}
export const MEM_OPS: Readonly<Record<MemOp, MemOpMeta>> = {
  recall: { lbl: '회상', glyph: '↺', cls: 'recall' },
  inject: { lbl: '주입', glyph: '⤓', cls: 'inject' },
  pin: { lbl: '핀', glyph: '⊙', cls: 'pin' },
  compact: { lbl: '압축', glyph: '◉', cls: 'compact' },
  evict: { lbl: '폐기', glyph: '◌', cls: 'evict' },
}

export interface MemPin {
  readonly id: string
  readonly text: string
  readonly by: 'operator' | 'auto'
  readonly at: string
  readonly tag: string
}
export interface MemStoreEntry {
  readonly id: string
  readonly kind: MemKind
  readonly text: string
  readonly salience: number
  readonly uses?: number
  readonly lastUsed?: string
  readonly src: string
}
export interface MemRecall {
  readonly at: string
  readonly op: MemOp
  readonly text: string
  readonly tok: number
}
export interface KeeperMemoryRecord {
  readonly pinned: readonly MemPin[]
  readonly store: readonly MemStoreEntry[]
  readonly recall: readonly MemRecall[]
}

// Minimal keeper shape the inspector reads (subset of the prototype keeper).
export interface MemoryKeeper {
  readonly id: string
  readonly ctx: number
  readonly status: string
  readonly tasks?: number
  readonly traces?: number
}

export interface Compaction {
  readonly id: string
  readonly at: string
  readonly trigger: string
  readonly kept: readonly string[]
  readonly summarized: readonly string[]
  readonly dropped: readonly string[]
}

// ── fixture (memory-data.jsx:26-112) — ported verbatim ──
export const KEEPER_MEMORY: Readonly<Record<string, KeeperMemoryRecord>> = {
  'masc-improver': {
    pinned: [
      { id: 'p1', text: 'retention 정의: D0 = 가입일, 첫 세션 기준', by: 'operator', at: '2d', tag: 'definition' },
      { id: 'p2', text: 'gp:center_type 미정값은 제외하지 말고 "미정" 버킷으로 유지', by: 'operator', at: '1d', tag: 'caveat' },
      { id: 'p3', text: 'amplitude D0–D3 코호트는 KST 자정 기준으로 끊는다', by: 'auto', at: '5h', tag: 'definition' },
    ],
    store: [
      { id: 's1', kind: 'fact', text: 'trace-store p99 쓰기 지연 목표 < 20ms (현재 19ms)', salience: 0.92, uses: 14, lastUsed: '12분', src: 'T-3902' },
      { id: 's2', kind: 'decision', text: '리텐션 대시보드 = 코호트 히트맵 + D0/D1/D7 3열로 확정', salience: 0.81, uses: 9, lastUsed: '41분', src: 'goal-retention' },
      { id: 's3', kind: 'pattern', text: 'amplitude 쿼리 결과는 표로 정규화 후 캐시 — 동일 segment 재질의 빈번', salience: 0.74, uses: 22, lastUsed: '1h', src: 'self' },
      { id: 's4', kind: 'pref', text: 'operator는 숫자에 천단위 구분 + 단위 명시 선호', salience: 0.55, uses: 6, lastUsed: '3h', src: 'operator' },
      { id: 's5', kind: 'entity', text: 'gp:center_type — 가맹점 분류 차원 (마트/편의점/기타/미정)', salience: 0.68, uses: 11, lastUsed: '2h', src: 'T-3880' },
    ],
    recall: [
      { at: '14:01', op: 'compact', text: '컨텍스트 86% → 컴팩션, 핵심 사실 5건 유지', tok: -110600 },
      { at: '13:58', op: 'recall', text: 'retention 정의 + center_type 메모 회상 (턴 시작)', tok: 1840 },
      { at: '13:52', op: 'inject', text: 'amplitude 표 캐시 주입', tok: 3200 },
      { at: '13:30', op: 'pin', text: 'operator가 "center_type 미정 버킷 유지" 핀 고정', tok: 120 },
      { at: '12:10', op: 'evict', text: '만료된 쿼리 캐시 9건 폐기', tok: -4100 },
    ],
  },
  nick0cave: {
    pinned: [
      { id: 'p1', text: 'compact()는 lock 보유 중 호출 금지 — p95 380ms 스파이크 원인', by: 'operator', at: '6h', tag: 'risk' },
      { id: 'p2', text: '임계값 0.38은 seoul-1 기준, tokyo-2는 RTT 보정 필요', by: 'auto', at: '3h', tag: 'caveat' },
    ],
    store: [
      { id: 's1', kind: 'fact', text: 'core/scheduler jitter p95 회귀 가드: 380ms → 19ms', salience: 0.95, uses: 18, lastUsed: '3분', src: 'T-3902' },
      { id: 's2', kind: 'decision', text: 'unlock 후 압축으로 이동 — compact()를 critical section 밖으로', salience: 0.88, uses: 12, lastUsed: '9분', src: 'T-3902' },
      { id: 's3', kind: 'pattern', text: 'lock 재진입 가설은 trace_window open_fds 메트릭으로 검증', salience: 0.70, uses: 7, lastUsed: '22분', src: 'self' },
      { id: 's4', kind: 'entity', text: 'Exec_policy — 실행 정책 통합 표면 (RFC-0254)', salience: 0.60, uses: 5, lastUsed: '1h', src: 'goal-exec-policy' },
    ],
    recall: [
      { at: '14:01', op: 'compact', text: '컨텍스트 91% → 컴팩션, 182k → 58k', tok: -124200 },
      { at: '13:40', op: 'recall', text: 'jitter 가드 + unlock 결정 회상', tok: 2100 },
      { at: '13:20', op: 'pin', text: 'auto: tokyo-2 RTT 보정 caveat 핀', tok: 90 },
    ],
  },
  sangsu: {
    pinned: [
      { id: 'p1', text: 'round_test.ml 84/84 통과가 머지 게이트 — 깨지면 즉시 중단', by: 'operator', at: '1d', tag: 'gate' },
    ],
    store: [
      { id: 's1', kind: 'fact', text: 'core/runtime dune test 84/84 ok (41.2s)', salience: 0.85, uses: 10, lastUsed: '방금', src: 'self' },
      { id: 's2', kind: 'pattern', text: 'Eio 리소스는 연 Switch가 닫힐 때 해제 — 라이터는 로컬 Switch.run으로', salience: 0.90, uses: 15, lastUsed: '4분', src: 'T-3902' },
      { id: 's3', kind: 'pref', text: 'diff는 side-by-side, 탭 너비 2', salience: 0.40, uses: 3, lastUsed: '2h', src: 'operator' },
    ],
    recall: [
      { at: '방금', op: 'recall', text: 'Switch 수명 패턴 회상', tok: 1500 },
      { at: '12분', op: 'inject', text: 'round_test 결과 주입', tok: 800 },
    ],
  },
  'qa-king': {
    pinned: [
      { id: 'p1', text: 'docs/site는 PR마다 프리뷰 배포 — 링크 깨지면 fail', by: 'auto', at: '8h', tag: 'gate' },
    ],
    store: [
      { id: 's1', kind: 'fact', text: 'docs 사이트 빌드 시간 평균 58s', salience: 0.50, uses: 4, lastUsed: '8분', src: 'self' },
      { id: 's2', kind: 'decision', text: '핸드오프 시 미해결 링크 점검 항목을 다음 keeper에 전달', salience: 0.66, uses: 5, lastUsed: '8분', src: 'self' },
    ],
    recall: [
      { at: '8분', op: 'compact', text: 'HandingOff — 컨텍스트 정리', tok: -42000 },
    ],
  },
  analyst: {
    pinned: [
      { id: 'p1', text: 'search/index 재색인은 야간 윈도우(02:00 KST)에만', by: 'operator', at: '12h', tag: 'caveat' },
    ],
    store: [
      { id: 's1', kind: 'fact', text: 'search/index 문서 ~1.2M, 재색인 ~34분', salience: 0.62, uses: 6, lastUsed: '34분', src: 'self' },
      { id: 's2', kind: 'entity', text: 'gp:center_type 분포 — 분석 코호트 핵심 차원', salience: 0.58, uses: 8, lastUsed: '2h', src: 'T-3880' },
    ],
    recall: [
      { at: '34분', op: 'recall', text: '재색인 윈도우 caveat 회상', tok: 600 },
    ],
  },
  drifter: {
    pinned: [],
    store: [
      { id: 's1', kind: 'fact', text: 'core/runtime overflow 재현: 컨텍스트 100%에서 trace 라이터 fd 누수 누적', salience: 0.70, uses: 3, lastUsed: '3시간', src: 'T-3902' },
    ],
    recall: [
      { at: '3시간', op: 'evict', text: 'Overflowed — 컨텍스트 전체 폐기 직전 스냅샷', tok: -200000 },
    ],
  },
}

// Default keeper roster (subset needed by the inspector) so the
// 전체 (aggregate) scope renders without external wiring. Status values
// mirror the prototype keeper roster intent (run / pause / off).
export const DEFAULT_MEMORY_KEEPERS: readonly MemoryKeeper[] = [
  { id: 'masc-improver', ctx: 0.86, status: 'run', tasks: 4, traces: 27 },
  { id: 'nick0cave', ctx: 0.91, status: 'run', tasks: 4, traces: 38 },
  { id: 'sangsu', ctx: 0.34, status: 'run', tasks: 2, traces: 11 },
  { id: 'qa-king', ctx: 0.22, status: 'pause', tasks: 1, traces: 6 },
  { id: 'analyst', ctx: 0.41, status: 'run', tasks: 1, traces: 9 },
  { id: 'drifter', ctx: 0, status: 'off', tasks: 0, traces: 4 },
]

export const DEFAULT_COMPACTIONS: Readonly<Record<string, readonly Compaction[]>> = {
  nick0cave: [
    {
      id: 'cmp_7f3a', at: '14:01', trigger: '컨텍스트 91% — 자동 임계치',
      kept: ['소유 태스크 4건 (T-3902 외)', 'core/scheduler 최근 변경 요약', 'compact lock 재진입 가설'],
      summarized: ['14:01 이전 라운드 로그 52개 → 6줄 요약', '완료된 trace 29건 → 통계만 보존'],
      dropped: ['중복 도구 결과 11건', '취소된 분기 탐색 로그'],
    },
  ],
  'masc-improver': [
    {
      id: 'cmp_3d90', at: '13:30', trigger: '컨텍스트 86% — 자동 임계치',
      kept: ['리텐션 정의 (D0=가입일)', 'center_type 분류 미정값 메모'],
      summarized: ['amplitude 쿼리 결과 14건 → 표 1개'],
      dropped: ['중복 세그먼트 응답 6건'],
    },
  ],
  'qa-king': [
    {
      id: 'cmp_qa01', at: '8분', trigger: 'HandingOff — 핸드오프 정리',
      kept: ['미해결 링크 점검 항목'],
      summarized: ['docs 빌드 로그 → 요약'],
      dropped: ['완료된 프리뷰 배포 로그'],
    },
  ],
  drifter: [
    {
      id: 'cmp_dr01', at: '3시간', trigger: 'Overflowed — 컨텍스트 전체 폐기',
      kept: [],
      summarized: [],
      dropped: ['컨텍스트 전체 스냅샷'],
    },
  ],
}

// ── token formatter (memory.jsx:8-12) ──
export function memFmtTok(n: number): string {
  const a = Math.abs(n)
  const s = a >= 1000 ? `${(a / 1000).toFixed(1)}k` : String(a)
  return (n < 0 ? '−' : '') + s
}

export function getKeeperMemory(
  k: MemoryKeeper,
  store: Readonly<Record<string, KeeperMemoryRecord>> = KEEPER_MEMORY,
): KeeperMemoryRecord {
  return store[k.id] ?? { pinned: [], store: [], recall: [] }
}

export interface CompositionPart {
  readonly key: string
  readonly lbl: string
  readonly tok: number
  readonly color: string
}
export interface Composition {
  readonly total: number
  readonly parts: readonly CompositionPart[]
}

// context-window composition for a keeper, derived from live ctx tokens
// (memory-data.jsx:115-133). Math ported verbatim.
export function memComposition(
  k: MemoryKeeper,
  store: Readonly<Record<string, KeeperMemoryRecord>> = KEEPER_MEMORY,
): Composition {
  const total = Math.round((k.ctx || 0) * CONTEXT_WINDOW_TOK)
  if (total === 0) return { total: 0, parts: [] }
  const rec = store[k.id] ?? { store: [], pinned: [], recall: [] }
  const mem = rec.store.length * 900 + rec.pinned.length * 220
  const system = 6200
  const tasks = (k.tasks || 0) * 2600
  const traces = Math.min(Math.round(total * 0.42), (k.traces || 0) * 90)
  let nsDialog = total - system - tasks - traces - mem
  if (nsDialog < total * 0.1) nsDialog = Math.round(total * 0.2)
  const parts: CompositionPart[] = [
    { key: 'system', lbl: '시스템·월드 프롬프트', tok: system, color: 'var(--text-dim)' },
    { key: 'ns', lbl: 'namespace · 대화 로그', tok: nsDialog, color: 'var(--volt)' },
    { key: 'tasks', lbl: '소유 태스크', tok: tasks, color: 'var(--info)' },
    { key: 'traces', lbl: '최근 trace', tok: traces, color: 'var(--status-warn)' },
    { key: 'memory', lbl: '메모리 (핀 + 스토어)', tok: mem, color: 'var(--status-ok)' },
  ].filter(p => p.tok > 0)
  return { total, parts }
}

export interface AggregateRow {
  readonly id: string
  readonly ctx: number
  readonly status: string
  readonly pinned: number
  readonly store: number
  readonly memTok: number
}
export interface MemAggregate {
  readonly rows: readonly AggregateRow[]
  readonly pinned: number
  readonly store: number
  readonly memTok: number
  readonly kindTotals: Readonly<Record<string, number>>
  readonly topFacts: readonly (MemStoreEntry & { keeper: string })[]
  readonly keeperCount: number
}

// aggregate across the passed keepers (memory-data.jsx:140-160).
export function memAggregate(
  keepers: readonly MemoryKeeper[],
  store: Readonly<Record<string, KeeperMemoryRecord>> = KEEPER_MEMORY,
): MemAggregate {
  const rows: AggregateRow[] = []
  let pinned = 0
  let storeCount = 0
  let memTok = 0
  const kindTotals: Record<string, number> = {}
  const allFacts: (MemStoreEntry & { keeper: string })[] = []
  keepers.forEach(k => {
    const m = getKeeperMemory(k, store)
    const comp = memComposition(k, store)
    const mt = comp.parts.find(p => p.key === 'memory')?.tok ?? 0
    pinned += m.pinned.length
    storeCount += m.store.length
    memTok += mt
    m.store.forEach(s => {
      kindTotals[s.kind] = (kindTotals[s.kind] ?? 0) + 1
      allFacts.push({ ...s, keeper: k.id })
    })
    rows.push({ id: k.id, ctx: k.ctx, status: k.status, pinned: m.pinned.length, store: m.store.length, memTok: mt })
  })
  const topFacts = [...allFacts].sort((a, b) => b.salience - a.salience).slice(0, 6)
  return { rows, pinned, store: storeCount, memTok, kindTotals, topFacts, keeperCount: keepers.length }
}

// ── rendering ──

function MemBar({ parts, total }: { parts: readonly CompositionPart[]; total: number }) {
  return html`
    <div class="mem-bar" title="컨텍스트 윈도우 구성">
      ${parts.map(p => html`<span key=${p.key} style=${{ width: `${(p.tok / total) * 100}%`, background: p.color }}></span>`)}
    </div>`
}

function MemCompo({ keeper, store }: { keeper: MemoryKeeper; store: Readonly<Record<string, KeeperMemoryRecord>> }) {
  const { total, parts } = memComposition(keeper, store)
  if (!total) return html`<div class="mem-empty">중지된 keeper — 활성 컨텍스트 없음.</div>`
  return html`
    <div class="mem-compo">
      <div class="mem-compo-head">
        <span class="mono mem-compo-tot">${(total / 1000).toFixed(1)}k</span>
        <span class="mem-compo-sub">/ 200k 윈도우 · ${Math.round(keeper.ctx * 100)}%</span>
      </div>
      <${MemBar} parts=${parts} total=${total} />
      <div class="mem-legend">
        ${parts.map(p => html`
          <div key=${p.key} class="mem-leg">
            <span class="mem-leg-sw" style=${{ background: p.color }}></span>
            <span class="mem-leg-lbl">${p.lbl}</span>
            <span class="mem-leg-v mono">${memFmtTok(p.tok)}</span>
          </div>`)}
      </div>
    </div>`
}

function MemSalience({ v }: { v: number }) {
  return html`<span class="mem-sal" title=${`salience ${v.toFixed(2)}`}><span style=${{ width: `${v * 100}%` }}></span></span>`
}

function MemStoreRow({ s, srcOverride }: { s: MemStoreEntry; srcOverride?: string }) {
  const k = MEM_KINDS[s.kind]
  return html`
    <div class="mem-store-row">
      <span class=${`mem-kind ${k.cls}`}>${k.glyph} ${k.lbl}</span>
      <div class="mem-store-main">
        <div class="mem-store-text">${s.text}</div>
        <div class="mem-store-meta">
          <${MemSalience} v=${s.salience} />
          ${s.uses != null ? html`<span class="mono">${s.uses}회 사용</span>` : null}
          ${s.lastUsed ? html`<span>최근 ${s.lastUsed}</span>` : null}
          <span class="mem-src mono">${srcOverride ?? s.src}</span>
        </div>
      </div>
    </div>`
}

// status dot — mirrors prototype StatusDot (memory.jsx:196):
// run → ok, pause → idle, else → bad.
function memDotState(status: string): 'ok' | 'idle' | 'bad' {
  return status === 'run' ? 'ok' : status === 'pause' ? 'idle' : 'bad'
}

function OneKeeperMemory({
  keeper,
  store,
  compactions,
}: {
  keeper: MemoryKeeper
  store: Readonly<Record<string, KeeperMemoryRecord>>
  compactions: Readonly<Record<string, readonly Compaction[]>>
}) {
  const m = getKeeperMemory(keeper, store)
  const comps = compactions[keeper.id] ?? []
  const lastCmp = comps[0]
  const kindFilter = useSignal<'all' | MemKind>('all')
  const kinds = [...new Set(m.store.map(s => s.kind))]
  const filter = kindFilter.value
  const storeRows = filter === 'all' ? m.store : m.store.filter(s => s.kind === filter)
  return html`
    <${Fragment}>
      <div class="turn-sec">
        <h4>컨텍스트 구성</h4>
        <${MemCompo} keeper=${keeper} store=${store} />
      </div>

      <div class="turn-sec">
        <h4>핀 고정 사실 · ${m.pinned.length}</h4>
        ${m.pinned.length ? html`
          <div class="mem-pins">
            ${m.pinned.map(p => html`
              <div key=${p.id} class="mem-pin">
                <span class="mem-pin-ico">${'⊙'}</span>
                <div class="mem-pin-body">
                  <div class="mem-pin-text">${p.text}</div>
                  <div class="mem-pin-meta">
                    <span class=${`mem-by ${p.by}`}>${p.by}</span>
                    <span class="mem-tag">${p.tag}</span>
                    <span class="mono">${p.at} 전</span>
                  </div>
                </div>
              </div>`)}
          </div>` : html`<div class="mem-empty">핀 고정된 사실 없음.</div>`}
      </div>

      <div class="turn-sec">
        <div class="mem-sec-head">
          <h4>장기 메모리 스토어 · memory-os</h4>
          <span class="mem-n mono">${m.store.length}</span>
        </div>
        ${m.store.length ? html`
          <${Fragment}>
            ${kinds.length > 1 ? html`
              <div class="mem-filters">
                <button class=${`mem-filter ${filter === 'all' ? 'on' : ''}`} onClick=${() => { kindFilter.value = 'all' }}>전체</button>
                ${kinds.map(kk => {
                  const d = MEM_KINDS[kk]
                  return html`<button key=${kk} class=${`mem-filter ${filter === kk ? 'on' : ''}`} onClick=${() => { kindFilter.value = kk }}>${d.glyph} ${d.lbl}</button>`
                })}
              </div>` : null}
            <div class="mem-store">${storeRows.map(s => html`<${MemStoreRow} key=${s.id} s=${s} />`)}</div>
          </>` : html`<div class="mem-empty">장기 메모리 항목 없음.</div>`}
      </div>

      <div class="turn-sec">
        <h4>최근 회상 · 주입</h4>
        ${m.recall && m.recall.length ? html`
          <div class="mem-timeline">
            ${m.recall.map((r, i) => {
              const o = MEM_OPS[r.op]
              return html`
                <div key=${i} class="mem-tl-row">
                  <span class="mem-tl-at mono">${r.at}</span>
                  <span class=${`mem-op ${o.cls}`}>${o.glyph} ${o.lbl}</span>
                  <span class="mem-tl-text">${r.text}</span>
                  <span class=${`mem-tl-tok mono ${r.tok < 0 ? 'neg' : 'pos'}`}>${memFmtTok(r.tok)}</span>
                </div>`
            })}
          </div>` : html`<div class="mem-empty">기록된 회상 없음.</div>`}
      </div>

      <div class="turn-sec">
        <h4>압축 유지 · 요약 · 폐기</h4>
        ${lastCmp ? html`
          <${Fragment}>
            <div class="cmp-trigger"><span class="sub-k">최근 컴팩션</span>${lastCmp.at} · ${lastCmp.trigger}</div>
            <div class="cmp-diff">
              <div class="cmp-col kept"><div class="cmp-col-h">${'◈'} 유지</div>${lastCmp.kept.map((x, i) => html`<div key=${i} class="cmp-li">${x}</div>`)}</div>
              <div class="cmp-col summ"><div class="cmp-col-h">${'◉'} 요약</div>${lastCmp.summarized.map((x, i) => html`<div key=${i} class="cmp-li">${x}</div>`)}</div>
              <div class="cmp-col drop"><div class="cmp-col-h">${'◌'} 폐기</div>${lastCmp.dropped.map((x, i) => html`<div key=${i} class="cmp-li">${x}</div>`)}</div>
            </div>
          </>` : html`<div class="mem-empty">컴팩션 이력 없음 — 메모리가 압축된 적 없음.</div>`}
      </div>
    </>`
}

function AllKeepersMemory({
  keepers,
  store,
  onPick,
}: {
  keepers: readonly MemoryKeeper[]
  store: Readonly<Record<string, KeeperMemoryRecord>>
  onPick: (id: string) => void
}) {
  const agg = memAggregate(keepers, store)
  const maxMem = Math.max(1, ...agg.rows.map(r => r.memTok))
  return html`
    <${Fragment}>
      <div class="turn-sec">
        <h4>집계</h4>
        <div class="mem-stats">
          <div class="mem-stat"><span class="v mono">${agg.keeperCount}</span><span class="k">keeper</span></div>
          <div class="mem-stat"><span class="v mono">${agg.pinned}</span><span class="k">핀 고정</span></div>
          <div class="mem-stat"><span class="v mono">${agg.store}</span><span class="k">스토어 항목</span></div>
          <div class="mem-stat"><span class="v mono">${(agg.memTok / 1000).toFixed(1)}k</span><span class="k">메모리 토큰</span></div>
        </div>
      </div>

      <div class="turn-sec">
        <h4>종류별 분포</h4>
        <div class="mem-kinds-dist">
          ${Object.entries(agg.kindTotals).sort((a, b) => b[1] - a[1]).map(([kk, n]) => {
            const d = MEM_KINDS[kk as MemKind] ?? { lbl: kk, glyph: '◈', cls: '' }
            return html`
              <div key=${kk} class="mem-kd-row">
                <span class=${`mem-kind ${d.cls}`}>${d.glyph} ${d.lbl}</span>
                <div class="mem-kd-bar"><span style=${{ width: `${(n / agg.store) * 100}%` }}></span></div>
                <span class="mono mem-kd-n">${n}</span>
              </div>`
          })}
        </div>
      </div>

      <div class="turn-sec">
        <h4>keeper별 메모리 <span class="mem-hint">행을 누르면 개별 보기</span></h4>
        <div class="mem-table">
          <div class="mem-tr mem-th"><span>keeper</span><span>ctx</span><span>핀</span><span>스토어</span><span>mem tok</span></div>
          ${agg.rows.map(r => html`
            <button key=${r.id} class="mem-tr" onClick=${() => onPick(r.id)}>
              <span class="mem-td-id"><span class=${`mem-dot ${memDotState(r.status)}`}></span><span class="mono">${r.id}</span></span>
              <span class="mono">${Math.round(r.ctx * 100)}%</span>
              <span class="mono">${r.pinned}</span>
              <span class="mono">${r.store}</span>
              <span class="mem-td-bar"><i style=${{ width: `${(r.memTok / maxMem) * 100}%` }}></i><b class="mono">${(r.memTok / 1000).toFixed(1)}k</b></span>
            </button>`)}
        </div>
      </div>

      <div class="turn-sec">
        <h4>가장 salient한 사실 · 전체</h4>
        <div class="mem-store">
          ${agg.topFacts.map(s => html`<${MemStoreRow} key=${s.keeper + s.id} s=${s} srcOverride=${s.keeper} />`)}
        </div>
      </div>
    </>`
}

export interface MemoryInspectorProps {
  readonly keeper: MemoryKeeper
  readonly onClose: () => void
  readonly keepers?: readonly MemoryKeeper[]
  readonly memory?: Readonly<Record<string, KeeperMemoryRecord>>
  readonly compactions?: Readonly<Record<string, readonly Compaction[]>>
}

export function MemoryInspector({
  keeper,
  onClose,
  keepers = DEFAULT_MEMORY_KEEPERS,
  memory = KEEPER_MEMORY,
  compactions = DEFAULT_COMPACTIONS,
}: MemoryInspectorProps) {
  const scope = useSignal<'one' | 'all'>('one')
  const pickId = useSignal(keeper.id)

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

  const active = keepers.find(k => k.id === pickId.value) ?? keeper
  const isOne = scope.value === 'one'

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div class="turn-drawer mem-drawer" onClick=${(e: MouseEvent) => e.stopPropagation()}>
        <div class="turn-hd">
          <h3>Keeper 메모리</h3>
          <span class="tid">${isOne ? active.id : '전체 keeper'}</span>
          <div class="mem-scope">
            <button class=${isOne ? 'on' : ''} onClick=${() => { scope.value = 'one' }}>이 keeper</button>
            <button class=${!isOne ? 'on' : ''} onClick=${() => { scope.value = 'all' }}>전체</button>
          </div>
          <button class="turn-close" onClick=${onClose} title="닫기 (Esc)">${'✕'}</button>
        </div>
        <div class="turn-body">
          ${isOne
            ? html`<${OneKeeperMemory} keeper=${active} store=${memory} compactions=${compactions} />`
            : html`<${AllKeepersMemory} keepers=${keepers} store=${memory} onPick=${(id: string) => { pickId.value = id; scope.value = 'one' }} />`}
        </div>
      </div>
    </div>`
}

// MASC v2 — 注入書 (Injection Book): a read-only, paper-styled view of the
// keeper system prompt. Two views:
//   1. 조립 · 9블록 — the 9 canonical Prompt_block_id assembly blocks, each
//      showing its live template body + template_variables + char count from
//      the prompt registry (GET /api/v1/prompts). {{tokens}} render as empty
//      blanks — substitution happens only at server turn time, never here.
//   2. 전체 라이브러리 — every registered prompt grouped into families, marking
//      which families assemble into the keeper turn vs. which are separate
//      subsystems (judge / librarian / governance / verification / orchestrator).
//
// Mounted inside PromptRegistryPanel (Settings › prompts). Consumes the prompts
// the parent already fetched — no new request, no per-keeper substitution (that
// is unbacked: the render only happens server-side, so this view stays a
// keeper-agnostic template book).

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { DashboardPromptItem } from '../../api'

type PromptBookView = 'book' | 'catalog'

// One assembly block. `id`/`label`/`color` mirror the OCaml Prompt_block_id
// closed sum + dashboard PROMPT_BLOCK_META; `src`/`composed`/`always` are the
// block↔md mapping the server API does not expose (a client spec, the same
// approach as keeper-prompt-assembly STAGES). Body/vars/bytes/gloss are NOT
// hardcoded here — they come from the live registry item matched by `src`.
interface BlockSpec {
  id: string
  label: string
  color: string
  src: string
  composed: string[]
  always: boolean
}

// Assembly order = Prompt_block_id.t declaration order (lib/types/prompt_block_id.ml).
const BLOCK_SPEC: readonly BlockSpec[] = [
  {
    id: 'persona',
    label: '페르소나',
    color: 'var(--text-dim)',
    src: 'keeper.unified.system.md',
    composed: ['keeper.capabilities.md', 'keeper.core_behavior.md', 'keeper.reply_guidelines.md'],
    always: true,
  },
  {
    id: 'continuity',
    label: '연속성',
    color: 'var(--info, #6f7ea8)',
    src: 'keeper.constitution.md',
    composed: ['behavior/continuity_contract.md'],
    always: true,
  },
  {
    id: 'dynamic_context',
    label: '동적 컨텍스트',
    color: 'var(--volt)',
    src: 'keeper.world.md',
    composed: [],
    always: true,
  },
  {
    id: 'temporal_summary',
    label: '시간 요약',
    color: 'var(--status-warn)',
    src: 'keeper.recovery_block.md',
    composed: [],
    always: false,
  },
  {
    id: 'claimed_task_nudge',
    label: '태스크 넛지',
    color: 'var(--status-ok)',
    src: 'keeper.immediate_task_move.md',
    composed: ['keeper.turn_intent.claim_guidance_a.md', 'keeper.turn_intent.claim_guidance_b.md'],
    always: false,
  },
  {
    id: 'retry_nudge',
    label: '재시도 넛지',
    color: 'var(--status-bad)',
    src: 'keeper.recovery_block.md',
    composed: [],
    always: false,
  },
  {
    id: 'memory_os_recall',
    label: '메모리 회상',
    color: 'var(--volt-strong, var(--kp8))',
    src: 'keeper.memory_os_recall.context.md',
    composed: [
      'keeper.memory_os_recall.facts_section.md',
      'keeper.memory_os_recall.episodes_section.md',
      'keeper.memory_os_recall.unavailable.md',
    ],
    always: false,
  },
  {
    id: 'user_model',
    label: '사용자 모델',
    color: 'var(--info, #6f7ea8)',
    src: 'behavior/profile_policy.md',
    composed: [],
    always: true,
  },
  {
    id: 'connected_surface',
    label: '연결 표면',
    color: 'var(--status-warn)',
    src: 'behavior/connected_surface_discretion.md',
    composed: [],
    always: false,
  },
]

// Match a block to the registry item that carries its template. The registry key
// drops the `.md` and any directory (keeper.world.md -> keeper.world); file_path
// keeps the full path. Try the full-path suffix first, then the basename key.
function basename(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash >= 0 ? path.slice(slash + 1) : path
}

function matchBlockItem(prompts: readonly DashboardPromptItem[], spec: BlockSpec): DashboardPromptItem | null {
  const bySrcPath = prompts.find(p => p.file_path != null && p.file_path.endsWith(spec.src))
  if (bySrcPath) return bySrcPath
  const wantBase = basename(spec.src)
  const byBasename = prompts.find(p => p.file_path != null && basename(p.file_path) === wantBase)
  if (byBasename) return byBasename
  const wantKey = wantBase.replace(/\.md$/, '')
  return prompts.find(p => p.key === wantKey) ?? null
}

// Inline pass: split a line on {{var}} and `code`. {{var}} always renders as an
// empty blank chip (the .pb-blank ::before/::after add the braces) — this
// read-only view never substitutes keeper values.
function renderInline(text: string): unknown[] {
  const re = /(\{\{[a-zA-Z_]+\}\}|`[^`]+`)/g
  const out: unknown[] = []
  let last = 0
  let key = 0
  let match: RegExpExecArray | null
  while ((match = re.exec(text)) !== null) {
    const tok = match[0]
    if (tok === undefined) break
    if (match.index > last) out.push(text.slice(last, match.index))
    if (tok.startsWith('{{')) {
      out.push(
        html`<span class="pb-blank" key=${key++} title="치환은 서버 턴 시점에만 일어납니다">${tok.slice(2, -2)}</span>`,
      )
    } else {
      out.push(html`<code class="pb-code" key=${key++}>${tok.slice(1, -1)}</code>`)
    }
    last = match.index + tok.length
  }
  if (last < text.length) out.push(text.slice(last))
  return out
}

function PromptBookBody({ text }: { text: string }) {
  const lines = text.split('\n')
  return html`
    <div class="pb-ch-body">
      ${lines.map((line, index) => {
        const heading = line.match(/^(#{2,3})\s+(.*)$/)
        if (heading) {
          const level = heading[1] ?? ''
          const cls = level.length === 2 ? 'pb-h2' : 'pb-h3'
          return html`<div class=${cls} key=${index}>${renderInline(heading[2] ?? '')}</div>`
        }
        if (line.trim() === '') return html`<div class="pb-br" key=${index}></div>`
        return html`<div class="pb-line" key=${index}>${renderInline(line)}</div>`
      })}
    </div>
  `
}

function PromptBookChapter({
  spec,
  item,
  num,
  open,
  onToggle,
}: {
  spec: BlockSpec
  item: DashboardPromptItem | null
  num: number
  open: boolean
  onToggle: () => void
}) {
  const body = item ? (item.effective || item.file_value || '') : ''
  const vars = item?.template_variables ?? []
  return html`
    <section class=${`pb-ch ${open ? 'open' : ''}`} data-block=${spec.id} data-testid="pb-chapter">
      <button class="pb-ch-head" type="button" onClick=${onToggle} aria-expanded=${open}>
        <span class="pb-ch-num">${String(num).padStart(2, '0')}</span>
        <span class="pb-ch-swatch" style=${`background:${spec.color}`}></span>
        <span class="pb-ch-title">${spec.label}</span>
        ${!spec.always ? html`<span class="pb-ch-cond">조건부</span>` : null}
        <span class="pb-ch-src">${spec.src}</span>
        ${item ? html`<span class="pb-ch-bytes">${item.char_count}자</span>` : null}
        <span class="pb-ch-caret">${open ? '▾' : '▸'}</span>
      </button>
      ${item?.description ? html`<div class="pb-ch-gloss">${item.description}</div>` : null}
      ${open
        ? item
          ? html`<${PromptBookBody} text=${body} />`
          : html`<div class="pb-ch-gloss">레지스트리에서 <code class="pb-code">${spec.src}</code> 원문을 찾지 못했습니다.</div>`
        : null}
      ${open && vars.length > 0
        ? html`
            <div class="pb-ch-vars">
              <span class="pb-ch-vars-k">template_variables</span>
              ${vars.map(v => html`<span class="pb-var-chip" key=${v}>${v}</span>`)}
            </div>
          `
        : null}
      ${open && spec.composed.length > 0
        ? html`
            <div class="pb-ch-vars">
              <span class="pb-ch-vars-k">합성 · composed from</span>
              ${spec.composed.map(f => html`<span class="pb-src-chip" key=${f}>${f}</span>`)}
            </div>
          `
        : null}
    </section>
  `
}

function PromptBookAssembly({ prompts }: { prompts: readonly DashboardPromptItem[] }) {
  const [openId, setOpenId] = useState<string | null>(null)
  const chapters = BLOCK_SPEC.map(spec => ({ spec, item: matchBlockItem(prompts, spec) }))
  const matched = chapters.filter(chapter => chapter.item !== null).length
  return html`
    <div class="pb-book" data-testid="prompt-book-assembly">
      <div class="pb-frontis">
        <div class="pb-frontis-mark">注</div>
        <div class="pb-frontis-t">
          <h1>注入書</h1>
          <div class="pb-frontis-sub">
            keeper 시스템 프롬프트를 이루는 9개 조립 블록. 컨텍스트는 매 턴 리셋되고, 이 블록들이 재조립되어 주입됩니다.
          </div>
          <div class="pb-frontis-meta">${matched}/${BLOCK_SPEC.length} 블록 · Prompt_block_id.t 순서</div>
        </div>
      </div>
      <div class="pb-chapters">
        ${chapters.map((chapter, index) => html`
          <${PromptBookChapter}
            key=${chapter.spec.id}
            spec=${chapter.spec}
            item=${chapter.item}
            num=${index + 1}
            open=${openId === chapter.spec.id}
            onToggle=${() => setOpenId(openId === chapter.spec.id ? null : chapter.spec.id)}
          />
        `)}
      </div>
      <div class="pb-colophon">
        <span>조립 순서 = <code class="pb-code">Prompt_block_id.t</code></span>
        <span class="pb-colophon-note">{{빈칸}}은 keeper 턴 시점에만 치환됩니다 · 이 뷰는 read-only 템플릿</span>
      </div>
    </div>
  `
}

// Family classification (client curation). The server exposes category/file_path
// but not a "does this feed the keeper turn" flag — keeper.librarian.system.md is
// category=keeper yet never assembles into a turn — so the feedsTurn split is
// authored here. Ordered specific→generic: the first matching rule wins, so
// keeper.turn_intent / librarian / judge are classified before the generic
// keeper.* family. An unmatched prompt falls to an explicit Other bucket rather
// than being silently folded into a feeding family.
interface FamilyDef {
  id: string
  family: string
  feedsTurn: boolean
  order: number
  note: string
  match: (haystack: string) => boolean
}

const FAMILY_DEFS: readonly FamilyDef[] = [
  {
    id: 'turn_intent',
    family: 'Turn Intent · 조각',
    feedsTurn: true,
    order: 2,
    note: 'unified.system 렌더 뒤 Turn Intent 가이드로 이어붙는 조각',
    match: h => h.includes('keeper.turn_intent'),
  },
  {
    id: 'librarian',
    family: 'Librarian · 메모리',
    feedsTurn: false,
    order: 5,
    note: 'memory-os 라이브러리안 전용 — 별도 호출자',
    match: h => h.includes('librarian'),
  },
  {
    id: 'judge',
    family: 'Judge · 심판',
    feedsTurn: false,
    order: 4,
    note: '대시보드 판정용 — keeper 턴 아님',
    match: h => h.includes('judge'),
  },
  {
    id: 'deliberation',
    family: 'Governance · Deliberation',
    feedsTurn: false,
    order: 6,
    note: '숙의·드라이런 — 다중 keeper 합의',
    match: h => h.includes('governance') || h.includes('deliberation'),
  },
  {
    id: 'tool_contract',
    family: 'Tool Contract',
    feedsTurn: true,
    order: 3,
    note: '태스크 라이프사이클 도구 계약',
    match: h => h.includes('tool_contract'),
  },
  {
    id: 'verification',
    family: 'Verification',
    feedsTurn: false,
    order: 7,
    note: '검증·적대적 리뷰 — verifier 호출자',
    match: h => h.includes('verification'),
  },
  {
    id: 'orchestrator',
    family: 'Orchestrator',
    feedsTurn: false,
    order: 8,
    note: '시스템 오케스트레이션',
    match: h => h.includes('orchestrator'),
  },
  {
    id: 'keeper',
    family: 'keeper 턴 · 조립',
    feedsTurn: true,
    order: 1,
    note: '9개 블록으로 합성되어 매 턴 keeper에 주입',
    match: h => h.includes('keeper.') || h.includes('/behavior/') || h.includes('behavior.'),
  },
]

// Terminal catch-all: an unmatched prompt is surfaced as Other rather than
// folded into a feeding family. Kept as a named const so it is a guaranteed
// (non-undefined) fallback for classifyFamily.
const OTHER_FAMILY: FamilyDef = {
  id: 'other',
  family: 'Other · 기타',
  feedsTurn: false,
  order: 9,
  note: '위 계열에 분류되지 않은 프롬프트',
  match: () => true,
}

function classifyFamily(item: DashboardPromptItem): FamilyDef {
  const haystack = `${item.key}|${item.file_path ?? ''}`
  return FAMILY_DEFS.find(def => def.match(haystack)) ?? OTHER_FAMILY
}

interface FamilyGroup {
  def: FamilyDef
  files: string[]
}

function groupByFamily(prompts: readonly DashboardPromptItem[]): FamilyGroup[] {
  const buckets = new Map<string, FamilyGroup>()
  for (const item of prompts) {
    const def = classifyFamily(item)
    let group = buckets.get(def.id)
    if (!group) {
      group = { def, files: [] }
      buckets.set(def.id, group)
    }
    group.files.push(item.file_path ? basename(item.file_path) : item.key)
  }
  return Array.from(buckets.values()).sort((a, b) => a.def.order - b.def.order)
}

function PromptBookCatalog({ prompts }: { prompts: readonly DashboardPromptItem[] }) {
  const groups = groupByFamily(prompts)
  return html`
    <div class="pb-book pb-catalog" data-testid="prompt-book-catalog">
      <div class="pb-cat-intro">
        <h1>전체 프롬프트 라이브러리</h1>
        <div class="pb-frontis-sub">
          ${prompts.length}개 프롬프트 · 이 중 keeper 턴에 조립되는 계열만 상단에 표시됩니다.
        </div>
      </div>
      ${groups.map(group => html`
        <section class=${`pb-cat-fam ${group.def.feedsTurn ? 'feeds' : ''}`} key=${group.def.id}>
          <div class="pb-cat-fam-head">
            <span class="pb-cat-dot"></span>
            <span class="pb-cat-fam-name">${group.def.family}</span>
            <span class="pb-cat-fam-count">${group.files.length}</span>
            ${group.def.feedsTurn
              ? html`<span class="pb-cat-tag feeds">keeper 턴</span>`
              : html`<span class="pb-cat-tag">별도 계열</span>`}
          </div>
          <div class="pb-cat-fam-note">${group.def.note}</div>
          <div class="pb-cat-files">
            ${group.files.map((file, index) => html`<span class="pb-src-chip" key=${`${file}-${index}`}>${file}</span>`)}
          </div>
        </section>
      `)}
    </div>
  `
}

export function PromptBookPanel({
  prompts,
  loading = false,
}: {
  prompts: readonly DashboardPromptItem[]
  loading?: boolean
}) {
  const [view, setView] = useState<PromptBookView>('book')

  if (prompts.length === 0) {
    return html`
      <div class="pb-wrap" data-theme="paper" data-testid="prompt-book-panel">
        <div class="pb-book">
          <div class="pb-frontis">
            <div class="pb-frontis-mark">注</div>
            <div class="pb-frontis-t">
              <h1>注入書</h1>
              <div class="pb-frontis-sub">
                ${loading ? '프롬프트 레지스트리를 불러오는 중입니다.' : '표시할 프롬프트가 없습니다.'}
              </div>
            </div>
          </div>
        </div>
      </div>
    `
  }

  return html`
    <div class="pb-wrap" data-theme="paper" data-testid="prompt-book-panel">
      <div class="pb-viewbar">
        <div class="pb-seg" role="tablist" data-testid="prompt-book-viewbar">
          <button
            type="button"
            role="tab"
            aria-selected=${view === 'book'}
            class=${`pb-seg-btn ${view === 'book' ? 'on' : ''}`}
            onClick=${() => setView('book')}
          >조립 · 9블록</button>
          <button
            type="button"
            role="tab"
            aria-selected=${view === 'catalog'}
            class=${`pb-seg-btn ${view === 'catalog' ? 'on' : ''}`}
            onClick=${() => setView('catalog')}
          >전체 라이브러리</button>
        </div>
        <div class="pb-viewbar-note">
          ${view === 'book'
            ? '컨텍스트는 매 턴 리셋 — 이 블록들이 재조립되어 주입된다'
            : 'config/prompts/*.md · frontmatter로 자동 등록 (prompt_defaults.ml)'}
        </div>
      </div>
      ${view === 'catalog'
        ? html`<${PromptBookCatalog} prompts=${prompts} />`
        : html`<${PromptBookAssembly} prompts=${prompts} />`}
    </div>
  `
}

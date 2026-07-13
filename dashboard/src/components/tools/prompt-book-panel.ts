// MASC v2 — Prompt library (paper-styled, read-only). Every registered prompt
// grouped into families, marking which families feed the keeper turn vs. which
// are separate subsystems (judge / librarian / analysis / verification /
// orchestrator). This is a curated catalog: the family split and the
// "keeper 턴" flag are client curation over the live prompt list, NOT a runtime
// assembly record.
//
// Note (review #23052): an earlier version also mapped each Prompt_block_id
// assembly block to a registry markdown file and showed that file's body as the
// block body. That mapping is not the runtime source of truth — the actual
// turn-recorded blocks are dynamic/hardcoded strings assembled in
// lib/keeper/keeper_run_tools_hooks.ml (e.g. Retry_nudge / Claimed_task_nudge are
// runtime strings, and Continuity / Connected_surface have no record_block site
// at all), so presenting a markdown file as the block body was fabricated
// provenance. That view was removed; the backed keeper-turn assembly view remains
// the existing KeeperPromptAssemblyPanel in the registry tab.
//
// Mounted inside PromptRegistryPanel (Settings › prompts). Consumes the prompts
// the parent already fetched — no new request.

import { html } from 'htm/preact'
import type { DashboardPromptItem } from '../../api'

function basename(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash >= 0 ? path.slice(slash + 1) : path
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
    note: 'unified.system 렌더 뒤 Turn Intent 가이드로 이어붙는 조각 (큐레이션)',
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
    family: 'Analysis · Deliberation',
    feedsTurn: false,
    order: 6,
    note: '숙의·드라이런 — 다중 keeper 합의',
    match: h => h.includes('analysis.dry_run') || h.includes('deliberation'),
  },
  {
    id: 'tool_contract',
    family: 'Tool Contract',
    feedsTurn: true,
    order: 3,
    note: '태스크 라이프사이클 도구 계약 (큐레이션)',
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
    family: 'keeper 턴 · 계열',
    feedsTurn: true,
    order: 1,
    note: 'keeper 시스템 프롬프트를 이루는 md 계열 (큐레이션 · 런타임 조립과 1:1 아님)',
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
        <h1>프롬프트 라이브러리</h1>
        <div class="pb-frontis-sub">
          ${prompts.length}개 프롬프트 · family 분류와 "keeper 턴" 표시는 클라이언트 큐레이션입니다.
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
  if (prompts.length === 0) {
    return html`
      <div class="pb-wrap" data-theme="paper" data-testid="prompt-book-panel">
        <div class="pb-book">
          <div class="pb-cat-intro">
            <h1>프롬프트 라이브러리</h1>
            <div class="pb-frontis-sub">
              ${loading ? '프롬프트 레지스트리를 불러오는 중입니다.' : '표시할 프롬프트가 없습니다.'}
            </div>
          </div>
        </div>
      </div>
    `
  }

  return html`
    <div class="pb-wrap" data-theme="paper" data-testid="prompt-book-panel">
      <${PromptBookCatalog} prompts=${prompts} />
    </div>
  `
}

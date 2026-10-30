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
import type { DashboardPromptItem, DashboardRuntimePromptAsset } from '../../api'

function basename(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash >= 0 ? path.slice(slash + 1) : path
}

// Family classification (client curation). The server exposes the exact
// frontmatter category but not a "does this feed the keeper turn" flag, so only
// that boolean is authored here. Key/file-name substring matching is forbidden:
// renaming an asset must not silently change its family. An unrecognized
// category lands in an explicit Other bucket.
interface FamilyDef {
  id: string
  family: string
  feedsTurn: boolean
  order: number
  note: string
  category: string
}

const FAMILY_DEFS: readonly FamilyDef[] = [
  {
    id: 'canary',
    family: 'Canary · 연속성',
    feedsTurn: false,
    order: 6,
    note: '메모리 연속성 검증 전용 — keeper 턴 아님',
    category: 'canary',
  },
  {
    id: 'evaluation',
    family: 'Evaluation · 캘리브레이션',
    feedsTurn: false,
    order: 8,
    note: '평가 판정 보정 전용 — keeper 턴 아님',
    category: 'evaluation',
  },
  {
    id: 'librarian',
    family: 'Librarian · 메모리',
    feedsTurn: false,
    order: 5,
    note: 'memory-os 라이브러리안 전용 — 별도 호출자',
    category: 'librarian',
  },
  {
    id: 'judge',
    family: 'Judge · 심판',
    feedsTurn: false,
    order: 4,
    note: '대시보드 판정용 — keeper 턴 아님',
    category: 'judge',
  },
  {
    id: 'verification',
    family: 'Verification',
    feedsTurn: false,
    order: 7,
    note: '검증·적대적 리뷰 — verifier 호출자',
    category: 'verification',
  },
  {
    id: 'keeper',
    family: 'keeper 턴 · 계열',
    feedsTurn: true,
    order: 1,
    note: 'keeper 시스템 프롬프트를 이루는 md 계열 (큐레이션 · 런타임 조립과 1:1 아님)',
    category: 'keeper',
  },
  {
    id: 'mcp',
    family: 'MCP · 도구 프로필',
    feedsTurn: false,
    order: 3,
    note: 'MCP 서버 도구 프로필 전용 — keeper 턴 아님',
    category: 'mcp',
  },
  {
    id: 'probe',
    family: 'Probe · 기능 확인',
    feedsTurn: false,
    order: 2,
    note: '런타임·도구 capability probe 전용 — keeper 턴 아님',
    category: 'probe',
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
  category: 'other',
}

function classifyFamily(item: DashboardPromptItem): FamilyDef {
  return FAMILY_DEFS.find(def => def.category === item.category) ?? OTHER_FAMILY
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

function RuntimePromptAssets({ assets }: { assets: readonly DashboardRuntimePromptAsset[] }) {
  if (assets.length === 0) return null
  return html`
    <section class="pb-cat-fam" data-testid="prompt-book-runtime-assets">
      <div class="pb-cat-fam-head">
        <span class="pb-cat-dot"></span>
        <span class="pb-cat-fam-name">Runtime assets · 읽기 전용</span>
        <span class="pb-cat-fam-count">${assets.length}</span>
        <span class="pb-cat-tag">별도 계열</span>
      </div>
      <div class="pb-cat-fam-note">
        배포된 .txt 지시문입니다. Prompt registry override 대상이 아닙니다.
      </div>
      ${assets.map(asset => html`
        <details class="mt-2" key=${asset.path}>
          <summary class="cursor-pointer text-xs text-[var(--color-fg-secondary)]">
            ${asset.path} · ${asset.file_exists ? `${asset.char_count} chars` : 'missing after sync'}
          </summary>
          <div class="pb-cat-fam-note">${asset.file_path}</div>
          <pre class="mt-2 max-h-72 overflow-auto whitespace-pre-wrap text-xs text-[var(--color-fg-primary)]">${asset.value}</pre>
        </details>
      `)}
    </section>
  `
}

function PromptBookCatalog({
  prompts,
  runtimeAssets,
}: {
  prompts: readonly DashboardPromptItem[]
  runtimeAssets: readonly DashboardRuntimePromptAsset[]
}) {
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
      <${RuntimePromptAssets} assets=${runtimeAssets} />
    </div>
  `
}

export function PromptBookPanel({
  prompts,
  runtimeAssets = [],
  loading = false,
}: {
  prompts: readonly DashboardPromptItem[]
  runtimeAssets?: readonly DashboardRuntimePromptAsset[]
  loading?: boolean
}) {
  if (prompts.length === 0 && runtimeAssets.length === 0) {
    return html`
      <div class="pb-wrap" data-theme="paper" data-testid="prompt-book-panel">
        <div class="pb-book">
          <div class="pb-cat-intro">
            <h1>프롬프트 라이브러리</h1>
            <div class="pb-frontis-sub">
              ${loading ? '불러오는 중…' : '표시할 프롬프트 없음'}
            </div>
          </div>
        </div>
      </div>
    `
  }

  return html`
    <div class="pb-wrap" data-theme="paper" data-testid="prompt-book-panel">
      <${PromptBookCatalog} prompts=${prompts} runtimeAssets=${runtimeAssets} />
    </div>
  `
}

// Keeper config panel — keeper-v2 design blocks (prototypes/keeper-v2/keeper-config.jsx parity).
//
// Every block is wired to a live signal; where the design assumes a control the
// backend does not expose, the block renders read-only with an explicit note
// instead of a fake toggle (mark don't fake):
//   - avatar preview: slot/sigil are the SAME deterministic kSlot/kSigil
//     derivation KeeperBadge uses, so the preview always matches the roster.
//     Portrait picker / slot-color / sigil editing have no keeper avatar API —
//     rendered disabled with the design's own 기획(kcf-plan) badge.
//   - runtime picker: /api/v1/providers catalog (runtimeCatalogState is loaded
//     by the panel); selecting a row drives the existing runtime_id PATCH draft.
//   - goals browser: goal tree linked_keeper_names is the live keeper linkage;
//     assignment write is not exposed, so rows are read-only.
//   - guards: hooks.slots gates of active slots are the registered guard set.
//   - interventions: /api/v1/dashboard/gate approval_queue + recent_resolved
//     filtered to this keeper (every entry is Gate-routed by construction).
//   - tool catalog: /api/v1/dashboard/tools inventory + this keeper's actual
//     call stats (/api/v1/keepers/:name/tool-stats) as the highlight signal.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { DashboardGateResponse, GoalTreeNode, KeeperConfig } from '../types'
import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'
import {
  fetchDashboardGoalsTree,
  fetchDashboardTools,
  fetchKeeperToolStats,
} from '../api/dashboard'
import type { DashboardToolInventoryItem } from '../api/dashboard-tools-prompts'
import type { ToolStat } from '../api/dashboard-keeper-tool-stats'
import { goalTreeData, hydrateGoalTreeSnapshot } from '../goal-tree-state'
import { gateData } from './gate-signals'
import { refreshGate } from './gate-refresh'
import { kSigil, kSlot } from './keeper-badge'
import { formatTokens } from '../lib/format-number'
import { relativeTime } from '../lib/format-time'

// ── shared badges ────────────────────────────────────────

// The design's own marker for fields that are planned but not yet implemented.
export function KcfPlan({ children }: { children?: unknown }) {
  return html`<span class="kcf-plan" title="아직 미구현 — 기획 단계">기획${children ? html`<em>${children}</em>` : null}</span>`
}

export function KcfReadonly({ children }: { children: unknown }) {
  return html`<span class="kcf-ro">${children}</span>`
}

// ── lazy load triggers (panel calls these when a tab opens) ──

let gateRequested = false
export function ensureKcfGateData(): void {
  if (gateRequested || gateData.value != null) return
  gateRequested = true
  void Promise.resolve(refreshGate()).catch(() => {
    gateRequested = false
  })
}

let goalsTreeRequested = false
export function ensureKcfGoalsTree(): void {
  if (goalTreeData.value != null || goalsTreeRequested) return
  goalsTreeRequested = true
  void fetchDashboardGoalsTree()
    .then(payload => {
      hydrateGoalTreeSnapshot(payload)
    })
    .catch(() => {
      goalsTreeRequested = false
    })
}

type KcfToolInventoryStatus = 'idle' | 'loading' | 'loaded' | 'error'
const toolInventoryStatus = signal<KcfToolInventoryStatus>('idle')
const toolInventory = signal<readonly DashboardToolInventoryItem[]>([])
const toolStatsKeeper = signal<string | null>(null)
const toolStatsByName = signal<ReadonlyMap<string, ToolStat>>(new Map())

export function ensureKcfTooling(keeperName: string): void {
  if (toolInventoryStatus.value === 'idle') {
    toolInventoryStatus.value = 'loading'
    void fetchDashboardTools()
      .then(res => {
        toolInventory.value = res.tool_inventory?.tools ?? []
        toolInventoryStatus.value = 'loaded'
      })
      .catch(() => {
        toolInventoryStatus.value = 'error'
      })
  }
  if (toolStatsKeeper.value !== keeperName) {
    toolStatsKeeper.value = keeperName
    toolStatsByName.value = new Map()
    void fetchKeeperToolStats(keeperName)
      .then(res => {
        if (toolStatsKeeper.value !== keeperName) return
        toolStatsByName.value = new Map(res.tools.map(t => [t.name, t]))
      })
      .catch(() => {
        // Tool stats are a highlight signal only; the catalog still renders.
      })
  }
}

// Client-only picker queries. Reset together with the panel drafts.
const runtimePickerQuery = signal('')
const goalsPickerQuery = signal('')

export function resetKeeperConfigV2Blocks(): void {
  runtimePickerQuery.value = ''
  goalsPickerQuery.value = ''
  gateRequested = false
  goalsTreeRequested = false
}

// ── 아바타 (identity tab) ────────────────────────────────
// slot color + sigil monogram are derived from the keeper id (kSlot/kSigil) —
// the same derivation KeeperBadge renders everywhere, so this preview cannot
// drift from the roster. Editing levers have no persistence API and render
// disabled with the design's 기획 badge.
export function KcfAvatarBlock({ keeperName, displayName }: { keeperName: string; displayName: string }) {
  const slot = kSlot(keeperName)
  const sigil = kSigil(keeperName)
  return html`
    <div class="kav">
      <div class="kav-preview">
        <span class="kav-face is-sigil" style=${`background: var(--kp${slot})`}>${sigil}</span>
        <div class="kav-preview-meta">
          <span class="kav-preview-name">${displayName}</span>
          <span class="kav-preview-mode mono">시길 · slot ${slot} · ${sigil}</span>
        </div>
      </div>

      <div class="kav-block">
        <label class="kav-lbl">아바타 소스</label>
        <div class="kav-src">
          <button type="button" class="kav-src-b on" disabled title="시길 — keeper id 에서 결정론적으로 파생됩니다">◈ 시길</button>
          <button type="button" class="kav-src-b" disabled title="초상화 프리셋·업로드는 keeper avatar API 가 없어 기획 단계입니다">◉ 초상화 <${KcfPlan} /></button>
        </div>
      </div>

      <div class="kav-block">
        <label class="kav-lbl">초상화 <span class="kav-lbl-hint">프리셋·업로드 <${KcfPlan} /></span></label>
        <div class="kav-portraits">
          <button
            type="button"
            class="kav-por kav-upload"
            disabled
            title="초상화 프리셋·업로드는 keeper avatar API 가 없어 기획 단계입니다"
          >
            <span class="kav-upload-ic">＋<em>업로드</em></span>
          </button>
        </div>
      </div>

      <div class="kav-block">
        <label class="kav-lbl">슬롯 색 <span class="kav-lbl-hint">시길·칩·강조색 전반에 적용 · id 해시로 결정</span></label>
        <div class="kav-swatches">
          ${Array.from({ length: 12 }, (_, i) => i + 1).map(n => html`
            <button
              key=${n}
              type="button"
              class=${`kav-sw ${slot === n ? 'on' : ''}`}
              style=${`--sw: var(--kp${n})`}
              disabled
              title=${`slot ${n} — keeper id 해시로 결정됩니다`}
            >
              ${slot === n ? html`<span class="kav-sw-tick">✓</span>` : null}
            </button>
          `)}
        </div>
      </div>

      <div class="kav-block kav-block-row">
        <div>
          <label class="kav-lbl">시길 <span class="kav-lbl-hint">2글자 모노그램 · id 에서 파생</span></label>
          <input
            class="kav-sigil-in mono"
            maxLength=${2}
            value=${sigil}
            readOnly
            aria-label="시길"
            title="keeper id 에서 파생 — 편집은 기획 단계"
          />
        </div>
        <span class="kav-sigil-prev mono" style=${`background: var(--kp${slot})`}>${sigil}</span>
      </div>
    </div>
  `
}

// ── 런타임 picker (runtime tab) ──────────────────────────
// The design picks from the full runtime.toml catalog with a search box; the
// live catalog is /api/v1/providers. where/badges are derived only from real
// snapshot fields (endpoint_url, capability flags) — never invented.

function runtimePickerKey(entry: DashboardRuntimeProviderSnapshot): string {
  return entry.runtime_id?.trim() || entry.provider.trim()
}

function runtimePickerModelLabel(entry: DashboardRuntimeProviderSnapshot): string {
  return entry.model_api_name ?? entry.model_id ?? entry.models[0] ?? ''
}

export function runtimePickerWhere(entry: DashboardRuntimeProviderSnapshot): string | null {
  const url = entry.endpoint_url?.trim()
  if (!url) return null
  return /^(https?:\/\/)?(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])/i.test(url) ? '로컬' : '클라우드'
}

export function runtimePickerBadges(entry: DashboardRuntimeProviderSnapshot): readonly string[] {
  const badges: string[] = []
  if (entry.is_default_runtime) badges.push('기본')
  if (entry.supports_extended_thinking || entry.supports_reasoning_budget) badges.push('reasoning')
  if (entry.supports_multimodal_inputs) badges.push('multimodal')
  if (entry.tools_support) badges.push('tools')
  if (entry.supports_prompt_caching) badges.push('cache')
  return badges.slice(0, 4)
}

export function KcfRuntimePicker({
  catalog,
  value,
  onChange,
}: {
  catalog: readonly DashboardRuntimeProviderSnapshot[]
  value: string
  onChange: (id: string) => void
}) {
  const q = runtimePickerQuery.value.trim().toLowerCase()
  const rows = catalog.filter(r => {
    if (q === '') return true
    return (
      runtimePickerKey(r).toLowerCase().includes(q) ||
      runtimePickerModelLabel(r).toLowerCase().includes(q)
    )
  })
  const listed = value.trim() !== '' && catalog.some(r => runtimePickerKey(r) === value)
  return html`
    <div class="kcf-goals">
      <div class="kcf-goals-bar">
        <div class="kcf-search">
          <span class="kcf-search-ic">◌</span>
          <input
            value=${runtimePickerQuery.value}
            onInput=${(e: Event) => { runtimePickerQuery.value = (e.target as HTMLInputElement).value }}
            placeholder="runtime·model 검색…"
            aria-label="런타임 검색"
          />
        </div>
        <span class="kcf-goals-count mono">${rows.length} / ${catalog.length}</span>
      </div>
      ${!listed && value.trim() !== '' ? html`
        <div class="kcf-goals-empty" style="padding:10px 14px; text-align:left;">
          현재 선택 <span class="mono">${value}</span> — providers 카탈로그에 없는 assignment 입니다 (tier 그룹 등).
        </div>
      ` : null}
      <div class="kcf-rt-list">
        ${rows.map(r => {
          const id = runtimePickerKey(r)
          const on = id === value
          const meta = [
            runtimePickerWhere(r),
            r.max_context ? `최대 ${formatTokens(r.max_context)}` : null,
            runtimePickerModelLabel(r),
          ].filter((part): part is string => part !== null && part !== '').join(' · ')
          const badges = runtimePickerBadges(r)
          return html`
            <button key=${id} type="button" class=${`kcf-rt ${on ? 'on' : ''}`} onClick=${() => onChange(id)}>
              <span class="kcf-rt-radio"></span>
              <span class="kcf-rt-body">
                <span class="kcf-rt-id mono">${id}</span>
                <span class="kcf-rt-meta">${meta}</span>
              </span>
              ${badges.length > 0 ? html`
                <span class="kcf-rt-badges">${badges.map(b => html`<span key=${b} class="kcf-rt-badge">${b}</span>`)}</span>
              ` : null}
            </button>
          `
        })}
        ${rows.length === 0 ? html`<div class="kcf-goals-empty">검색 결과 없음</div>` : null}
      </div>
    </div>
  `
}

// ── 목표 browser (goals tab) ─────────────────────────────
// Live linkage: GoalTreeNode.linked_keeper_names. The design's toggle writes
// assignment; no keeper-goal assignment writer is exposed, so rows render
// read-only and the section desc says exactly what the check means.

export interface KcfGoalRow {
  readonly id: string
  readonly title: string
  readonly linkedKeepers: readonly string[]
}

export function flattenKcfGoalTree(nodes: readonly GoalTreeNode[]): KcfGoalRow[] {
  const out: KcfGoalRow[] = []
  const walk = (items: readonly GoalTreeNode[]) => {
    for (const node of items) {
      out.push({ id: node.id, title: node.title, linkedKeepers: node.linked_keeper_names ?? [] })
      if (node.children.length > 0) walk(node.children)
    }
  }
  walk(nodes)
  return out
}

export function KcfGoalsBrowser({ keeperName }: { keeperName: string }) {
  const tree = goalTreeData.value
  if (!tree) {
    return html`<div class="kcf-goals-empty">goal tree 미수집 — 목표 탭을 열면 자동으로 불러옵니다.</div>`
  }
  const rows = flattenKcfGoalTree(tree.tree)
  const q = goalsPickerQuery.value.trim().toLowerCase()
  const visible = q === ''
    ? rows
    : rows.filter(r => r.title.toLowerCase().includes(q) || r.id.toLowerCase().includes(q))
  const linkedCount = rows.filter(r => r.linkedKeepers.includes(keeperName)).length
  return html`
    <div class="kcf-goals">
      <div class="kcf-goals-bar">
        <div class="kcf-search">
          <span class="kcf-search-ic">◌</span>
          <input
            value=${goalsPickerQuery.value}
            onInput=${(e: Event) => { goalsPickerQuery.value = (e.target as HTMLInputElement).value }}
            placeholder="goal 제목·id 검색…"
            aria-label="goal 검색"
          />
        </div>
        <span class="kcf-goals-count mono">${linkedCount} 연결 · ${visible.length} 표시</span>
      </div>
      <div class="kcf-goals-list">
        ${visible.map(g => {
          const on = g.linkedKeepers.includes(keeperName)
          return html`
            <div key=${g.id} class=${`kcf-goal ${on ? 'on' : ''}`} title="읽기 전용 — keeper goal 배정 쓰기 API 미노출">
              <span class="kcf-goal-check">${on ? '✓' : ''}</span>
              <span class="kcf-goal-body">
                <span class="kcf-goal-title">${g.title}</span>
                <span class="kcf-goal-id mono">${g.id}</span>
              </span>
            </div>
          `
        })}
        ${visible.length === 0 ? html`<div class="kcf-goals-empty">검색 결과 없음</div>` : null}
      </div>
    </div>
  `
}

// ── 가드 · 개입 (hooks tab) ──────────────────────────────
// Guards come from the keeper's ACTIVE hook slots' gate tags (hooks.slots is
// keeper-agnostic global architecture, but it is the authoritative registered
// guard set). Korean labels/descriptions are static copy for the four guards
// the design names; unknown gates render with their id and slot provenance.

export interface KcfGuardRow {
  readonly id: string
  readonly slot: string
  readonly source: string
}

const KCF_GUARD_COPY: Readonly<Record<string, { lbl: string; desc: string }>> = {
  timing: { lbl: '타이밍', desc: '도구 호출 간 최소 간격 — 폭주 차단 (keeper-local pacing)' },
  streak_gate: { lbl: '스트릭 게이트', desc: '연속 실패·동일 호출 반복 차단' },
  destructive_pattern: { lbl: '경로·샌드박스 불변식', desc: '실행 경계의 typed input · path jail · sandbox 검증 (객관 불변식)' },
  governance_approval: { lbl: 'Gate 라우팅', desc: '외부 효과 요청을 Gate(HITL) 큐로 라우팅' },
}

export function collectKcfGuards(c: KeeperConfig): KcfGuardRow[] {
  const slots = c.hooks?.slots ?? {}
  const out: KcfGuardRow[] = []
  const seen = new Set<string>()
  for (const [slotName, slot] of Object.entries(slots)) {
    if (!slot.active) continue
    for (const gate of slot.gates ?? []) {
      if (seen.has(gate)) continue
      seen.add(gate)
      out.push({ id: gate, slot: slotName, source: slot.source })
    }
  }
  return out
}

export function KcfGuardList({
  config,
  gateInterventionCount,
}: {
  config: KeeperConfig
  gateInterventionCount: number
}) {
  const guards = collectKcfGuards(config)
  if (guards.length === 0) {
    return html`<div class="kcf-goals-empty">등록된 활성 가드 없음</div>`
  }
  return html`
    <div class="kcf-guards">
      ${guards.map(g => {
        const copy = KCF_GUARD_COPY[g.id]
        // 발동 횟수는 Gate 라우팅만 관측 가능 — approval queue + resolved feed
        // entries are Gate-routed by construction. Other guards get no count
        // rather than an invented zero.
        const fires = g.id === 'governance_approval' ? gateInterventionCount : null
        return html`
          <div key=${`${g.slot}:${g.id}`} class="kcf-guard">
            <span class="kcf-guard-dot"></span>
            <div class="kcf-guard-main">
              <div class="kcf-guard-lbl">${copy?.lbl ?? g.id}<span class="kcf-guard-id mono">${g.id}</span></div>
              <div class="kcf-guard-desc">${copy?.desc ?? `${g.slot} 슬롯 · source ${g.source}`}</div>
            </div>
            ${fires !== null ? html`
              <span class="kcf-guard-fires mono" title="Gate 큐 대기 + 최근 결재 건수 (관측 범위: Gate 라우팅)">${fires}<em>회</em></span>
            ` : null}
          </div>
        `
      })}
    </div>
  `
}

export type KcfInterventionAction = 'escalated' | 'blocked' | 'passed' | 'warned'

const KCF_IV_LABEL: Readonly<Record<KcfInterventionAction, string>> = {
  escalated: 'Gate',
  blocked: '차단',
  passed: '허용',
  warned: '경고',
}

export interface KcfIntervention {
  readonly action: KcfInterventionAction
  readonly guard: string
  readonly at: string
  readonly note: string
  readonly ref: string | null
}

// The design derives interventions from APPROVALS/APPROVAL_HISTORY; the live
// counterpart is /api/v1/dashboard/gate (approval_queue + recent_resolved),
// filtered to this keeper. Every approval is Gate-routed, so guard is always
// governance_approval — that is the real pipeline, not a placeholder.
export function buildKcfInterventions(
  gate: DashboardGateResponse | null | undefined,
  keeperName: string,
): KcfIntervention[] {
  if (!gate) return []
  const out: KcfIntervention[] = []
  for (const item of gate.approval_queue ?? []) {
    if (item.keeper_name !== keeperName) continue
    out.push({
      action: 'escalated',
      guard: 'governance_approval',
      at: relativeTime(item.requested_at),
      note: item.input_preview?.trim() || item.tool_name,
      ref: item.id,
    })
  }
  for (const item of gate.recent_resolved ?? []) {
    if (item.keeper_name !== keeperName) continue
    out.push({
      action: item.decision === 'reject' ? 'blocked' : 'passed',
      guard: 'governance_approval',
      at: relativeTime(item.resolved_at),
      note: item.decision_reason?.trim() || item.tool_name,
      ref: item.id,
    })
  }
  return out
}

export function KcfInterventionList({ keeperName }: { keeperName: string }) {
  const gate = gateData.value
  if (!gate) {
    return html`<div class="kcf-ivs-empty">개입 이력 미관측 — Gate 데이터가 아직 수집되지 않았습니다.</div>`
  }
  const items = buildKcfInterventions(gate, keeperName)
  if (items.length === 0) {
    return html`<div class="kcf-ivs-empty">최근 발동한 가드 없음 — 이 keeper는 모든 호출이 게이트를 통과했습니다.</div>`
  }
  return html`
    <div class="kcf-ivs">
      ${items.map((iv, i) => html`
        <div key=${i} class="kcf-iv" data-act=${iv.action}>
          <span class="kcf-iv-act">${KCF_IV_LABEL[iv.action]}</span>
          <div class="kcf-iv-main">
            <div class="kcf-iv-top"><span class="kcf-iv-guard mono">${iv.guard}</span><span class="kcf-iv-at">${iv.at}</span></div>
            <div class="kcf-iv-note">${iv.note}</div>
          </div>
          ${iv.ref ? html`<span class="kcf-iv-ref mono">${iv.ref}</span>` : null}
        </div>
      `)}
    </div>
  `
}

// ── 도구 카탈로그 (access tab) ───────────────────────────
// Rows are the server's tool inventory (live); the highlight + count come from
// this keeper's actual tool-stats. The design's per-keeper grant toggle has no
// writer, so there is no toggle — the section desc says so.
export function KcfToolCatalog() {
  const status = toolInventoryStatus.value
  if (status === 'error') {
    return html`<div class="kcf-goals-empty">도구 카탈로그를 불러오지 못했습니다.</div>`
  }
  if (status !== 'loaded') {
    return html`<div class="kcf-goals-empty">도구 카탈로그 불러오는 중…</div>`
  }
  if (toolInventory.value.length === 0) {
    return html`<div class="kcf-goals-empty">서버 노출 도구 없음</div>`
  }
  const stats = toolStatsByName.value
  return html`
    <div class="kcf-tools">
      ${toolInventory.value.map(t => {
        const stat = stats.get(t.name)
        return html`
          <div
            key=${t.name}
            class=${`kcf-tool ${stat ? 'on' : ''}`}
            title=${stat
              ? `최근 호출 ${stat.call_count}회 · 실패 ${stat.failure_count}회`
              : '최근 호출 관측 없음'}
          >
            <span class="mono" style="font-size:11px; color:var(--text-dim); text-align:right;">${stat ? stat.call_count : '—'}</span>
            <span class="kcf-tool-id mono">${t.name}</span>
            <span class="kcf-tool-risk">${t.category}</span>
            <span class="kcf-tool-desc">${t.description}</span>
          </div>
        `
      })}
    </div>
  `
}

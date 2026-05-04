// Roadmap — P0–P7 improvement priority visualization.
// Shows dependency graph, per-provider applicability, phase timeline, and resource allocation.

import { html } from 'htm/preact'
import {
  ROADMAP_ITEMS,
  PROVIDER_IDS,
  PROVIDER_LABELS,
  APPLICABILITY_MATRIX,
  PHASE_TIMELINE,
  PHASE_COLORS,
  RESOURCE_ALLOCATION,
  SUCCESS_METRICS,
  applicabilitySymbol,
  applicabilityCellClass,
  phaseColor,
  type RoadmapPhase,
} from './data'

function PhaseCard({ item }: { item: typeof ROADMAP_ITEMS[number] }) {
  const isIndependent = item.deps.length === 0
  return html`
    <div class="pm-card ${phaseColor(item.id)}">
      <div class="pm-card-head">
        <div class="flex items-center gap-2">
          <span class="t-label font-bold mono">${item.id}</span>
          <span class="t-label">${item.area}</span>
          ${isIndependent ? html`<span class="chip sm is-ghost">병렬</span>` : null}
        </div>
        <span class="t-micro mono t-dim">${item.timeline}</span>
      </div>
      <div class="px-3 py-2 bg-[var(--shell-rail-bg)]">
        <p class="t-caption mb-1.5">${item.goal}</p>
        <div class="flex flex-wrap gap-1 mb-1.5">
          ${item.targetAntiPatterns.map(ap => html`
            <span key=${ap} class="chip sm is-err">${ap}</span>
          `)}
        </div>
        <div class="flex items-center gap-2 t-micro">
          <span class="t-dim">참조:</span>
          <span class="t-meta">${item.reference}</span>
        </div>
        <div class="mt-1 t-micro t-ok font-semibold">${item.effect}</div>
        ${item.deps.length > 0 ? html`
          <div class="mt-1 flex items-center gap-1 t-micro t-dim">
            <span>선행:</span>
            ${item.deps.map(d => html`
              <span key=${d} class="chip sm is-ghost">${d}</span>
            `)}
          </div>
        ` : null}
      </div>
    </div>
  `
}

function computeDependencyTiers(): RoadmapPhase[][] {
  const itemMap = new Map(ROADMAP_ITEMS.map(r => [r.id, r]))
  const tierOf = new Map<RoadmapPhase, number>()

  function getTier(id: RoadmapPhase): number {
    if (tierOf.has(id)) return tierOf.get(id)!
    const item = itemMap.get(id)!
    if (item.deps.length === 0) {
      tierOf.set(id, 0)
      return 0
    }
    const tier = Math.max(...item.deps.map(d => getTier(d))) + 1
    tierOf.set(id, tier)
    return tier
  }

  ROADMAP_ITEMS.forEach(r => getTier(r.id))

  const maxTier = Math.max(0, ...tierOf.values())
  const tiers: RoadmapPhase[][] = Array.from({ length: maxTier + 1 }, () => [])
  for (const [id, tier] of tierOf) { const t = tiers[tier]; if (t) t.push(id) }
  return tiers
}

const TIER_LABELS = ['독립', '확장', '통합', '종합']

function DependencyGraph() {
  const tiers = computeDependencyTiers()

  return html`
    <div class="flex flex-col gap-2">
      ${tiers.map((tier, ti) => html`
        <div key=${ti} class="flex items-center gap-2">
          <span class="t-micro mono t-dim w-[36px] text-right">${TIER_LABELS[ti] ?? `T${ti}`}</span>
          <div class="flex gap-1 flex-wrap">
            ${tier.map(p => {
              const item = ROADMAP_ITEMS.find(r => r.id === p)!
              return html`
                <span key=${p} class="chip sm ${phaseColor(p)}" title=${item.goal}>
                  ${p} <span class="t-micro opacity-70">${item.area}</span>
                </span>
              `
            })}
          </div>
          ${ti < tiers.length - 1 ? html`<span class="t-dim t-micro px-1">↓</span>` : null}
        </div>
      `)}
    </div>
  `
}

function parsePercentRatio(value: string): number {
  const parsed = Number.parseFloat(value.replace('%', ''))
  return Number.isFinite(parsed) ? parsed / 100 : 0
}

function formatFte(value: number): string {
  return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)}인`
}

function heatClass(pct: string): string {
  const n = Number.parseFloat(pct.replace('%', ''))
  if (n >= 100) return 'bg-[var(--ok-soft)] text-[var(--color-status-ok)] font-semibold'
  if (n >= 80)  return 'bg-[var(--ok-6)] text-[var(--color-fg-default)]'
  if (n >= 50)  return 'bg-[var(--warn-8)] text-[var(--color-fg-default)]'
  if (n > 0)    return 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
  return 'text-[var(--color-fg-muted)]'
}

function Timeline() {
  return html`
    <div class="pm-scroll">
      <table class="pm-table">
        <thead class="pm-thead">
          <tr>
            <th class="pm-th pm-th--right-border min-w-[50px]">주차</th>
            <th class="pm-th pm-th--right-border min-w-[60px]">Phase</th>
            <th class="pm-th pm-th--right-border">작업</th>
            <th class="pm-th pm-th--right-border">산출물</th>
            <th class="pm-th min-w-[70px]">의존</th>
          </tr>
        </thead>
        <tbody>
          ${PHASE_TIMELINE.map((row, i) => {
            const phaseClass = PHASE_COLORS[row.phase] ?? ''
            return html`
              <tr key=${i} class="pm-row-alt">
                <td class="pm-td pm-td--right-border pm-td--mono t-dim">${row.week}</td>
                <td class="pm-td pm-td--right-border">
                  <span class="chip sm ${phaseClass}">${row.phase}</span>
                </td>
                <td class="pm-td pm-td--right-border t-caption">${row.work}</td>
                <td class="pm-td pm-td--right-border t-meta">${row.deliverable}</td>
                <td class="pm-td t-micro mono t-dim">${row.deps}</td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

function ResourceTable() {
  const totalHeadcount = RESOURCE_ALLOCATION.reduce((sum, row) => sum + row.headcount, 0)
  const phaseTotals = RESOURCE_ALLOCATION[0]?.pct.map((_, phaseIndex) =>
    RESOURCE_ALLOCATION.reduce(
      (sum, row) => sum + (row.headcount * parsePercentRatio(row.pct[phaseIndex] ?? '0%')),
      0,
    ),
  ) ?? []

  return html`
    <div class="pm-scroll">
      <table class="pm-table">
        <thead class="pm-thead">
          <tr>
            <th class="pm-th pm-th--right-border">트랙</th>
            <th class="pm-th pm-th--right-border">범위</th>
            <th class="pm-th pm-th--center pm-th--right-border min-w-[40px]">인력</th>
            <th class="pm-th pm-th--center pm-th--right-border min-w-[55px]">0–4주</th>
            <th class="pm-th pm-th--center pm-th--right-border min-w-[55px]">4–8주</th>
            <th class="pm-th pm-th--center pm-th--right-border min-w-[55px]">8–12주</th>
            <th class="pm-th pm-th--center min-w-[55px]">12–16주</th>
          </tr>
        </thead>
        <tbody>
          ${RESOURCE_ALLOCATION.map((row, i) => html`
            <tr key=${i} class="pm-row-alt">
              <td class="pm-td pm-td--right-border font-semibold">${row.track}</td>
              <td class="pm-td pm-td--right-border t-micro t-meta">${row.scope}</td>
              <td class="pm-td pm-td--right-border pm-td--center pm-td--mono">${row.headcount}인</td>
              ${row.pct.map((p, j) => html`
                <td key=${j} class="pm-td pm-td--right-border pm-td--center pm-td--mono t-micro ${heatClass(p)}">${p}</td>
              `)}
            </tr>
          `)}
          <tr class="pm-cat-row">
            <td class="pm-td" colSpan=${2}>합계 FTE</td>
            <td class="pm-td pm-td--center pm-td--mono">${totalHeadcount}인</td>
            ${phaseTotals.map((total, i) => html`
              <td key=${i} class="pm-td pm-td--center pm-td--mono t-micro">${formatFte(total)}</td>
            `)}
          </tr>
        </tbody>
      </table>
    </div>
  `
}

function ResourceAllocationBars() {
  const PHASE_LABELS = ['0–4주', '4–8주', '8–12주', '12–16주']
  const PHASE_BAR_COLORS = [
    'var(--color-status-ok)',
    'var(--color-accent-fg)',
    'var(--amber-bright)',
    'var(--color-status-warn)',
  ]
  const phaseTotals = RESOURCE_ALLOCATION[0]?.pct.map((_, pi) =>
    RESOURCE_ALLOCATION.reduce((s, r) => s + r.headcount * parsePercentRatio(r.pct[pi] ?? '0%'), 0),
  ) ?? []
  const maxFte = Math.max(0.1, ...phaseTotals)

  return html`
    <div class="flex flex-col gap-1.5">
      ${phaseTotals.map((fte, i) => html`
        <div class="flex items-center gap-2 py-0.5" key=${i}>
          <span class="w-14 flex-shrink-0 text-2xs font-medium text-[var(--color-fg-muted)]">${PHASE_LABELS[i]}</span>
          <div class="flex-1 h-2.5 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
            <div class="h-full rounded-[var(--r-0)]" style="width: ${(fte / maxFte * 100).toFixed(1)}%; background: ${PHASE_BAR_COLORS[i]}; opacity: 0.7"></div>
          </div>
          <span class="w-12 text-right text-2xs font-mono font-bold" style="color: ${PHASE_BAR_COLORS[i]}">${formatFte(fte)}</span>
        </div>
      `)}
    </div>
  `
}

function PhaseTimelineGantt() {
  const PHASE_BAR_COLORS: Record<string, string> = {
    P0: 'var(--color-status-err)',
    P1: 'var(--color-status-warn)',
    P2: 'var(--color-accent-fg)',
    P3: 'var(--color-status-ok)',
  }
  return html`
    <div class="flex flex-col gap-1">
      ${PHASE_TIMELINE.map((row, i) => {
        const fill = PHASE_BAR_COLORS[row.phase] ?? 'var(--color-fg-muted)'
        const weekNum = parseInt(row.week.replace(/\D/g, '')) || 1
        const pct = Math.min(100, (weekNum / 16) * 100)
        return html`
          <div class="flex items-center gap-2 py-0.5" key=${i}>
            <span class="chip sm" style="background: ${fill}20; color: ${fill}">${row.phase}</span>
            <div class="flex-1 h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
              <div class="h-full rounded-[var(--r-0)]" style="width: ${pct}%; background: ${fill}; opacity: 0.6"></div>
            </div>
            <span class="w-10 text-right text-2xs font-mono text-[var(--color-fg-muted)]">${row.week}</span>
          </div>
        `
      })}
    </div>
  `
}

function SuccessMetrics() {
  return html`
    <div class="grid grid-cols-1 gap-3">
      ${SUCCESS_METRICS.map(m => html`
        <div key=${m.id} class="pm-card">
          <div class="pm-card-head">
            <div class="flex items-center gap-2">
              <span class="t-label font-semibold">${m.title}</span>
              <span class="chip sm is-ok">Target: ${m.target}</span>
            </div>
          </div>
          <div class="px-3 py-2">
            <p class="t-caption t-meta mb-2">${m.description}</p>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
              ${Object.entries(m.phases).map(([phase, desc]) => {
                const phaseClass = PHASE_COLORS[phase] ?? ''
                return html`
                  <div key=${phase} class="pm-card px-2 py-1.5">
                    <span class="chip sm ${phaseClass} mb-1">${phase}</span>
                    <p class="t-micro t-dim">${desc}</p>
                  </div>
                `
              })}
            </div>
          </div>
        </div>
      `)}
    </div>
  `
}

export function Roadmap() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="t-micro mono t-dim px-1">
        <span>sec06–07 — P0–P7 순차-병렬 하이브리드 개선 계획 + 16주 구현 로드맵</span>
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">의존성 그래프</h4>
        <${DependencyGraph} />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
        ${ROADMAP_ITEMS.map(item => html`
          <${PhaseCard} key=${item.id} item=${item} />
        `)}
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">Per-Provider 적용 매트릭스</h4>
        <p class="t-micro t-dim mb-2">sec06 Table 6-2 — ✅ 직접 적용, ⚠️ 제한적, ❌ 불가, — 해당 없음</p>
        <div class="pm-scroll">
          <table class="pm-table">
            <thead class="pm-thead">
              <tr>
                <th class="pm-th pm-th--sticky min-w-[60px]">항목</th>
                ${PROVIDER_IDS.map(pid => html`
                  <th key=${pid} class="pm-th pm-th--center min-w-[50px]">${PROVIDER_LABELS[pid] ?? pid}</th>
                `)}
              </tr>
            </thead>
            <tbody>
              ${ROADMAP_ITEMS.map(item => html`
                <tr key=${item.id} class="pm-row-alt">
                  <td class="pm-td pm-td--sticky pm-td--mono font-bold">${item.id}</td>
                  ${PROVIDER_IDS.map(pid => {
                    const a = APPLICABILITY_MATRIX[item.id][pid] ?? 'na'
                    return html`
                      <td key=${pid} class="pm-td pm-td--center">
                        <span class="pm-cell-badge ${applicabilityCellClass(a)}">
                          ${applicabilitySymbol(a)}
                        </span>
                      </td>
                    `
                  })}
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">Phase별 구현 타임라인</h4>
        <p class="t-micro t-dim mb-2">sec07 Table 7-1 — 16주 4-Phase 순차-병렬 하이브리드 로드맵</p>
        <${PhaseTimelineGantt} />
        <${Timeline} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">리소스 할당</h4>
        <p class="t-micro t-dim mb-2">sec07 Table 7-2 — 3 트랙 × 4 Phase 병렬 진행</p>
        <${ResourceAllocationBars} />
        <${ResourceTable} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">성공 지표</h4>
        <p class="t-micro t-dim mb-2">sec07 §7.3 — 16주 로드맵 완료 판정 기준 (3개 교차 검증 지표)</p>
        <${SuccessMetrics} />
      </div>
    </div>
  `
}

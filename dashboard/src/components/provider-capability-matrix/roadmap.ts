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
} from './data'

function PhaseCard({ item }: { item: typeof ROADMAP_ITEMS[number] }) {
  return html`
    <div class="pm-card ${phaseColor(item.id)}">
      <div class="pm-card-head">
        <div class="flex items-center gap-2">
          <span class="t-label font-bold mono">${item.id}</span>
          <span class="t-label">${item.area}</span>
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

function DependencyGraph() {
  const phases = ROADMAP_ITEMS.map(r => r.id)
  return html`
    <div class="flex items-center gap-1 t-micro mono flex-wrap">
      ${phases.map((p, i) => html`
        <span key=${p} class="inline-flex items-center gap-0.5">
          ${i > 0 ? html`<span class="t-dim px-0.5">→</span>` : null}
          <span class="chip sm ${phaseColor(p)}">${p}</span>
        </span>
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
                <td key=${j} class="pm-td pm-td--right-border pm-td--center pm-td--mono t-micro t-dim">${p}</td>
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
              ${ROADMAP_ITEMS.map((item, i) => html`
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
        <${Timeline} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">리소스 할당</h4>
        <p class="t-micro t-dim mb-2">sec07 Table 7-2 — 3 트랙 × 4 Phase 병렬 진행</p>
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

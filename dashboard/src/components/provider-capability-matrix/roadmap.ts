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
  applicabilitySymbol,
  applicabilityCellClass,
  phaseColor,
} from './data'

function PhaseCard({ item }: { item: typeof ROADMAP_ITEMS[number] }) {
  return html`
    <div class="border rounded overflow-hidden ${phaseColor(item.id)}">
      <div class="flex items-center justify-between px-3 py-1.5 border-b border-[var(--color-border-default)]">
        <div class="flex items-center gap-2">
          <span class="text-xs font-bold font-mono">${item.id}</span>
          <span class="text-xs font-medium">${item.area}</span>
        </div>
        <span class="text-[10px] font-mono text-[var(--color-fg-muted)]">${item.timeline}</span>
      </div>
      <div class="px-3 py-2 bg-[var(--shell-rail-bg)] text-[var(--color-fg-primary)]">
        <p class="text-[11px] leading-snug mb-1.5">${item.goal}</p>
        <div class="flex flex-wrap gap-1 mb-1.5">
          ${item.targetAntiPatterns.map(ap => html`
            <span key=${ap} class="inline-block rounded px-1 py-px text-[9px] font-mono bg-[var(--bad-10)] text-[var(--bad-light)]">
              ${ap}
            </span>
          `)}
        </div>
        <div class="flex items-center gap-2 text-[10px]">
          <span class="text-[var(--color-fg-muted)]">참조:</span>
          <span class="text-[var(--color-fg-secondary)]">${item.reference}</span>
        </div>
        <div class="mt-1 text-[10px] font-medium text-[var(--color-status-ok)]">
          ${item.effect}
        </div>
        ${item.deps.length > 0 ? html`
          <div class="mt-1 flex items-center gap-1 text-[9px] text-[var(--color-fg-muted)]">
            <span>선행:</span>
            ${item.deps.map(d => html`
              <span key=${d} class="rounded px-1 py-px bg-[var(--white-4)] font-mono">${d}</span>
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
    <div class="flex items-center gap-1 text-[10px] font-mono flex-wrap">
      ${phases.map((p, i) => html`
        <span key=${p} class="inline-flex items-center gap-0.5">
          ${i > 0 ? html`<span class="text-[var(--color-fg-disabled)] px-0.5">→</span>` : null}
          <span class="rounded px-1.5 py-0.5 ${phaseColor(p)}">${p}</span>
        </span>
      `)}
    </div>
  `
}

function Timeline() {
  return html`
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[50px]">주차</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[60px]">Phase</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">작업</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">산출물</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[70px]">의존</th>
          </tr>
        </thead>
        <tbody>
          ${PHASE_TIMELINE.map((row, i) => {
            const phaseClass = PHASE_COLORS[row.phase] ?? ''
            return html`
              <tr key=${i} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[11px] text-[var(--color-fg-muted)]">${row.week}</td>
                <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1">
                  <span class="inline-block rounded px-1.5 py-0.5 text-[9px] font-bold ${phaseClass}">${row.phase}</span>
                </td>
                <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-[11px]">${row.work}</td>
                <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] text-[var(--color-fg-secondary)]">${row.deliverable}</td>
                <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[10px] text-[var(--color-fg-muted)]">${row.deps}</td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

function ResourceTable() {
  return html`
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">트랙</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">범위</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[40px]">인력</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-secondary)] min-w-[55px]">0–4주</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-secondary)] min-w-[55px]">4–8주</th>
            <th class="border-b border-r border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-secondary)] min-w-[55px]">8–12주</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-secondary)] min-w-[55px]">12–16주</th>
          </tr>
        </thead>
        <tbody>
          ${RESOURCE_ALLOCATION.map((row, i) => html`
            <tr key=${i} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 font-medium text-[var(--color-fg-primary)]">${row.track}</td>
              <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] text-[var(--color-fg-secondary)]">${row.scope}</td>
              <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px]">${row.headcount}인</td>
              ${row.pct.map((p, j) => html`
                <td key=${j} class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[10px] text-[var(--color-fg-muted)]">${p}</td>
              `)}
            </tr>
          `)}
          <tr class="bg-[var(--white-4)] font-medium">
            <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1" colSpan=${2}>합계</td>
            <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px]">4인</td>
            <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[10px]">330%</td>
            <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[10px]">340%</td>
            <td class="border-r border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[10px]">310%</td>
            <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[10px]">240%</td>
          </tr>
        </tbody>
      </table>
    </div>
  `
}

export function Roadmap() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-4 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
        <span>sec06–07 — P0–P7 순차-병렬 하이브리드 개선 계획 + 16주 구현 로드맵</span>
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">의존성 그래프</h4>
        <${DependencyGraph} />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
        ${ROADMAP_ITEMS.map(item => html`
          <${PhaseCard} key=${item.id} item=${item} />
        `)}
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">Per-Provider 적용 매트릭스</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">sec06 Table 6-2 — ✅ 직접 적용, ⚠️ 제한적, ❌ 불가, — 해당 없음</p>
        <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
          <table class="w-full text-xs border-collapse">
            <thead>
              <tr class="bg-[var(--white-4)]">
                <th class="sticky left-0 z-10 bg-[var(--shell-rail-bg)] border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[60px]">
                  항목
                </th>
                ${PROVIDER_IDS.map(pid => html`
                  <th key=${pid} class="border-b border-[var(--color-border-default)] px-1.5 py-1 text-center font-medium text-[var(--color-fg-secondary)] min-w-[50px]">
                    ${PROVIDER_LABELS[pid] ?? pid}
                  </th>
                `)}
              </tr>
            </thead>
            <tbody>
              ${ROADMAP_ITEMS.map((item, i) => html`
                <tr key=${item.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="sticky left-0 z-10 ${i % 2 === 0 ? 'bg-[var(--shell-rail-bg)]' : 'bg-[var(--white-2)]'} border-r border-b border-[var(--color-border-default)] px-2 py-1 font-mono font-bold text-[11px]">
                    ${item.id}
                  </td>
                  ${PROVIDER_IDS.map(pid => {
                    const a = APPLICABILITY_MATRIX[item.id][pid] ?? 'na'
                    return html`
                      <td key=${pid} class="border-b border-[var(--color-border-default)] px-1 py-0.5 text-center">
                        <span class="inline-block w-full rounded px-1 py-0.5 text-[10px] font-mono font-bold ${applicabilityCellClass(a)}">
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
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">Phase별 구현 타임라인</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">sec07 Table 7-1 — 16주 4-Phase 순차-병렬 하이브리드 로드맵</p>
        <${Timeline} />
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">리소스 할당</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">sec07 Table 7-2 — 3 트랙 × 4 Phase 병렬 진행</p>
        <${ResourceTable} />
      </div>
    </div>
  `
}

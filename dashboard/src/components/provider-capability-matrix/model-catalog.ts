// ModelCatalog — Per-provider model listings with pricing and context.
// Shows provider model tiers, GLM Coding Plan mapping, and CLI transport comparison.

import { html } from 'htm/preact'
import {
  PROVIDER_MODELS,
  PROVIDER_LABELS,
  PROVIDER_CATEGORY,
  CLI_TRANSPORTS,
  GLM_CODING_PLAN_MAP,
  GLM_WIRING_GAPS,
  modelTierStyle,
} from './data'

function tierLabel(tier: string): string {
  switch (tier) {
    case 'flagship': return 'Flagship'
    case 'standard': return 'Standard'
    case 'fast':     return 'Fast'
    case 'coding':   return 'Coding'
    case 'legacy':   return 'Legacy'
    default:         return tier
  }
}

function ModelTable({ group }: { group: typeof PROVIDER_MODELS[number] }) {
  const cat = PROVIDER_CATEGORY[group.providerId] ?? 'cloud'
  const catBadge = cat === 'cloud' ? 'Cloud' : cat === 'cli' ? 'CLI' : 'Local'

  return html`
    <div class="border border-[var(--color-border-default)] rounded overflow-hidden">
      <div class="flex items-center justify-between px-3 py-1.5 bg-[var(--white-4)] border-b border-[var(--color-border-default)]">
        <span class="text-xs font-semibold text-[var(--color-fg-primary)]">${PROVIDER_LABELS[group.providerId] ?? group.providerId}</span>
        <span class="text-[10px] font-mono text-[var(--color-fg-muted)]">${group.models.length} models · ${catBadge}</span>
      </div>
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-2)]">
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-muted)]">Model</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-muted)]">Tier</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-muted)]">Context</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-right font-medium text-[var(--color-fg-muted)]">In/1M</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-right font-medium text-[var(--color-fg-muted)]">Out/1M</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-muted)]">Notes</th>
          </tr>
        </thead>
        <tbody>
          ${group.models.map((m, i) => html`
            <tr key=${m.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[11px] font-medium text-[var(--color-fg-primary)]">${m.id}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center">
                <span class="inline-block rounded px-1 py-px text-[9px] font-bold ${modelTierStyle(m.tier)}">${tierLabel(m.tier)}</span>
              </td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px]">${m.context}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-right font-mono text-[11px]">${m.inputPrice ?? '—'}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-right font-mono text-[11px]">${m.outputPrice ?? '—'}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] text-[var(--color-fg-muted)]">${m.notes ?? ''}</td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function CliTransportTable() {
  return html`
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">Provider</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">Binary</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-right font-medium text-[var(--color-fg-secondary)]">LOC</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Prompt</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Stream</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Argv Thresh</th>
            <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">Notes</th>
          </tr>
        </thead>
        <tbody>
          ${CLI_TRANSPORTS.map((t, i) => html`
            <tr key=${t.providerId} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-medium text-[var(--color-fg-primary)]">${PROVIDER_LABELS[t.providerId] ?? t.providerId}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[11px]">${t.binary}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-right font-mono text-[11px]">${t.loc.toLocaleString()}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px]">${t.promptMode}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px]">${t.streamFormat}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px]">${t.argvThreshold}</td>
              <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] text-[var(--color-fg-muted)]">${t.notes}</td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function GlmCodingPlanSection() {
  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
      <div>
        <h5 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">Claude Code → GLM Coding Plan 매핑</h5>
        <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
          <table class="w-full text-xs border-collapse">
            <thead>
              <tr class="bg-[var(--white-4)]">
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-secondary)]">Claude Code 변수</th>
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-secondary)]">GLM 모델</th>
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-secondary)]">비고</th>
              </tr>
            </thead>
            <tbody>
              ${GLM_CODING_PLAN_MAP.map((m, i) => html`
                <tr key=${i} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[10px]">${m.envVar}</td>
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[11px] font-medium">${m.glmModel}</td>
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] text-[var(--color-fg-muted)]">${m.note}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
      <div>
        <h5 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">OAS vs 공식 문서 간격</h5>
        <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
          <table class="w-full text-xs border-collapse">
            <thead>
              <tr class="bg-[var(--white-4)]">
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-secondary)]">영역</th>
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-secondary)]">OAS 현재</th>
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-secondary)]">공식</th>
              </tr>
            </thead>
            <tbody>
              ${GLM_WIRING_GAPS.map((g, i) => html`
                <tr key=${i} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[11px] font-medium">${g.area}</td>
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] font-mono text-[var(--bad-light)]">${g.oasCurrent}</td>
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] font-mono text-[var(--color-status-ok)]">${g.official}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
        <div class="mt-2">
          <p class="text-[10px] text-[var(--color-fg-muted)]">Gap: ${GLM_WIRING_GAPS.map(g => g.gap).join(', ')}</p>
        </div>
      </div>
    </div>
  `
}

export function ModelCatalog() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-4 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
        <span>Provider별 공식 모델 카탈로그 + 가격 + Context 한계</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--ok-10)]"></span> Flagship</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--white-4)]"></span> Standard</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--warn-10)]"></span> Fast</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--bad-10)]"></span> Coding</span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        ${PROVIDER_MODELS.map(g => html`
          <${ModelTable} key=${g.providerId} group=${g} />
        `)}
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">CLI Transport 구현 비교</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">OAS CLI transport 계층의 구현 복잡도와 프로토콜 차이</p>
        <${CliTransportTable} />
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">GLM Coding Plan 특수 매핑</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">Claude Code 호환 엔드포인트를 통한 GLM 모델 매핑 + OAS wiring 간격</p>
        <${GlmCodingPlanSection} />
      </div>
    </div>
  `
}

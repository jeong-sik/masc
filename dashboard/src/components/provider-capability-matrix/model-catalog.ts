// ModelCatalog — Per-provider model listings with pricing and context.
// Shows provider model tiers, GLM Coding Plan mapping, and CLI transport comparison.

import { html } from 'htm/preact'
import {
  PROVIDER_IDS,
  PROVIDER_MODELS,
  PROVIDER_LABELS,
  PROVIDER_CATEGORY,
  CLI_TRANSPORTS,
  GLM_CODING_PLAN_MAP,
  GLM_WIRING_GAPS,
  modelTierStyle,
  type ProviderModelGroup,
} from './data'

const MODEL_GROUPS_BY_PROVIDER = new Map(PROVIDER_MODELS.map(group => [group.providerId, group]))
const MODEL_CATALOG_GROUPS: ProviderModelGroup[] = PROVIDER_IDS.map(providerId =>
  MODEL_GROUPS_BY_PROVIDER.get(providerId) ?? { providerId, models: [] },
)

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
    <div class="pm-card">
      <div class="pm-card-head">
        <span class="t-label t-semi">${PROVIDER_LABELS[group.providerId] ?? group.providerId}</span>
        <span class="t-micro t-mono t-dim">${group.models.length} models · ${catBadge}</span>
      </div>
      <table class="pm-table">
        <thead class="pm-thead">
          <tr>
            <th class="pm-th">Model</th>
            <th class="pm-th pm-th--center">Tier</th>
            <th class="pm-th pm-th--center">Context</th>
            <th class="pm-th pm-th--right">In/1M</th>
            <th class="pm-th pm-th--right">Out/1M</th>
            <th class="pm-th">Notes</th>
          </tr>
        </thead>
        <tbody>
          ${group.models.length === 0 ? html`
            <tr>
              <td class="pm-td t-micro t-dim" colSpan=${6}>
                공식 모델 카탈로그 미등록. Provider capability는 matrix/providers 탭에서 추적.
              </td>
            </tr>
          ` : group.models.map((m, i) => html`
              <tr key=${m.id} class="pm-row-alt">
                <td class="pm-td pm-td--mono t-semi">${m.id}</td>
                <td class="pm-td pm-td--center">
                  <span class="chip sm ${modelTierStyle(m.tier)}">${tierLabel(m.tier)}</span>
                </td>
                <td class="pm-td pm-td--center pm-td--mono">${m.context}</td>
                <td class="pm-td pm-td--right pm-td--mono">${m.inputPrice ?? '—'}</td>
                <td class="pm-td pm-td--right pm-td--mono">${m.outputPrice ?? '—'}</td>
                <td class="pm-td t-micro t-dim">${m.notes ?? ''}</td>
              </tr>
            `)}
        </tbody>
      </table>
    </div>
  `
}

function CliTransportTable() {
  return html`
    <div class="pm-scroll">
      <table class="pm-table">
        <thead class="pm-thead">
          <tr>
            <th class="pm-th">Provider</th>
            <th class="pm-th">Binary</th>
            <th class="pm-th pm-th--right">LOC</th>
            <th class="pm-th pm-th--center">Prompt</th>
            <th class="pm-th pm-th--center">Stream</th>
            <th class="pm-th pm-th--center">Argv Thresh</th>
            <th class="pm-th">Notes</th>
          </tr>
        </thead>
        <tbody>
          ${CLI_TRANSPORTS.map((t, i) => html`
            <tr key=${t.providerId} class="pm-row-alt">
              <td class="pm-td t-semi">${PROVIDER_LABELS[t.providerId] ?? t.providerId}</td>
              <td class="pm-td pm-td--mono">${t.binary}</td>
              <td class="pm-td pm-td--right pm-td--mono">${t.loc.toLocaleString()}</td>
              <td class="pm-td pm-td--center pm-td--mono">${t.promptMode}</td>
              <td class="pm-td pm-td--center pm-td--mono">${t.streamFormat}</td>
              <td class="pm-td pm-td--center pm-td--mono">${t.argvThreshold}</td>
              <td class="pm-td t-micro t-dim">${t.notes}</td>
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
        <h5 class="t-label t-semi mb-2">Claude Code → GLM Coding Plan 매핑</h5>
        <div class="pm-scroll">
          <table class="pm-table">
            <thead class="pm-thead">
              <tr>
                <th class="pm-th">Claude Code 변수</th>
                <th class="pm-th">GLM 모델</th>
                <th class="pm-th">비고</th>
              </tr>
            </thead>
            <tbody>
              ${GLM_CODING_PLAN_MAP.map((m, i) => html`
                <tr key=${i} class="pm-row-alt">
                  <td class="pm-td pm-td--mono t-micro">${m.envVar}</td>
                  <td class="pm-td pm-td--mono t-semi">${m.glmModel}</td>
                  <td class="pm-td t-micro t-dim">${m.note}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
      <div>
        <h5 class="t-label t-semi mb-2">OAS vs 공식 문서 간격</h5>
        <div class="pm-scroll">
          <table class="pm-table">
            <thead class="pm-thead">
              <tr>
                <th class="pm-th">영역</th>
                <th class="pm-th">OAS 현재</th>
                <th class="pm-th">공식</th>
              </tr>
            </thead>
            <tbody>
              ${GLM_WIRING_GAPS.map((g, i) => html`
                <tr key=${i} class="pm-row-alt">
                  <td class="pm-td t-caption t-semi">${g.area}</td>
                  <td class="pm-td pm-td--mono t-micro t-err">${g.oasCurrent}</td>
                  <td class="pm-td pm-td--mono t-micro t-ok">${g.official}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
        <div class="mt-2">
          <p class="t-micro t-dim">Gap: ${GLM_WIRING_GAPS.map(g => g.gap).join(', ')}</p>
        </div>
      </div>
    </div>
  `
}

export function ModelCatalog() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="t-micro t-mono t-dim px-1">
        <span>Provider별 공식 모델 카탈로그 + 가격 + Context 한계</span>
        <span class="text-[var(--color-border-default)] mx-2">|</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--ok-10)]"></span> Flagship</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--white-4)]"></span> Standard</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--warn-10)]"></span> Fast</span>
        <span class="flex items-center gap-1"><span class="inline-block w-3 h-2 rounded-sm bg-[var(--bad-10)]"></span> Coding</span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        ${MODEL_CATALOG_GROUPS.map(g => html`
          <${ModelTable} key=${g.providerId} group=${g} />
        `)}
      </div>

      <div>
        <h4 class="t-label t-semi mb-2">CLI Transport 구현 비교</h4>
        <p class="t-micro t-dim mb-2">OAS CLI transport 계층의 구현 복잡도와 프로토콜 차이</p>
        <${CliTransportTable} />
      </div>

      <div>
        <h4 class="t-label t-semi mb-2">GLM Coding Plan 특수 매핑</h4>
        <p class="t-micro t-dim mb-2">Claude Code 호환 엔드포인트를 통한 GLM 모델 매핑 + OAS wiring 간격</p>
        <${GlmCodingPlanSection} />
      </div>
    </div>
  `
}

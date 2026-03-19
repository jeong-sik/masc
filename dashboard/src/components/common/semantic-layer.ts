import { html } from 'htm/preact'
import type {
  DashboardSemanticMetric,
  DashboardSemanticPanel,
} from '../../types'
import {
  findDashboardSemanticPanel,
} from '../../store'

function SemanticMetricRow({ metric }: { metric: DashboardSemanticMetric }) {
  return html`
    <article class="semantic-metric-row">
      <div class="semantic-metric-head">
        <strong>${metric.label}</strong>
        <span class="semantic-code">${metric.id}</span>
      </div>
      <p>${metric.what_it_measures}</p>
      <div class="semantic-grid compact">
        <span>이유</span><span>${metric.why_it_exists}</span>
        <span>근거 경로</span><span>${metric.source_path}</span>
        <span>갱신 조건</span><span>${metric.update_trigger}</span>
        <span>에이전트 영향</span><span>${metric.agent_behavior_effect}</span>
        <span>생태계 영향</span><span>${metric.ecosystem_effect}</span>
        <span>해석</span><span>${metric.interpretation}</span>
        <span>나쁜 냄새</span><span>${metric.bad_smell}</span>
        <span>다음 액션</span><span>${metric.next_action}</span>
      </div>
    </article>
  `
}

function SemanticPanelBody({ panel }: { panel: DashboardSemanticPanel }) {
  return html`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>목적</span><span>${panel.purpose}</span>
        <span>무엇을 푸나</span><span>${panel.problem_solved}</span>
        <span>언제 보나</span><span>${panel.when_active}</span>
        <span>에이전트 역할</span><span>${panel.agent_role}</span>
        <span>생태계 기능</span><span>${panel.ecosystem_function}</span>
      </div>
      ${panel.related_tools.length > 0
        ? html`<div class="semantic-tag-row">
            ${panel.related_tools.map(tool => html`<span class="semantic-tag">${tool}</span>`)}
          </div>`
        : null}
      ${panel.metrics.length > 0
        ? html`<div class="semantic-metric-list">
            ${panel.metrics.map(metric => html`<${SemanticMetricRow} key=${metric.id} metric=${metric} />`)}
          </div>`
        : null}
    </div>
  `
}

export function PanelSemanticDetails({
  panelId,
  compact = false,
  label = '의미 계층',
}: {
  panelId: string
  compact?: boolean
  label?: string
}) {
  const panel = findDashboardSemanticPanel(panelId)
  if (!panel) return null
  return html`
    <details class="semantic-inline ${compact ? 'compact' : ''}">
      <summary class="semantic-summary">${label}</summary>
      <${SemanticPanelBody} panel=${panel} />
    </details>
  `
}


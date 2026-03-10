import { html } from 'htm/preact'
import type {
  DashboardSemanticMetric,
  DashboardSemanticPanel,
  DashboardSemanticSurfaceId,
} from '../../types'
import {
  dashboardSemanticsError,
  dashboardSemanticsLoading,
  findDashboardSemanticPanel,
  findDashboardSemanticSurface,
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
        <span>Why</span><span>${metric.why_it_exists}</span>
        <span>Source</span><span>${metric.source_path}</span>
        <span>Trigger</span><span>${metric.update_trigger}</span>
        <span>Agent Effect</span><span>${metric.agent_behavior_effect}</span>
        <span>Ecosystem</span><span>${metric.ecosystem_effect}</span>
        <span>Interpret</span><span>${metric.interpretation}</span>
        <span>Bad Smell</span><span>${metric.bad_smell}</span>
        <span>Next</span><span>${metric.next_action}</span>
      </div>
    </article>
  `
}

function SemanticPanelBody({ panel }: { panel: DashboardSemanticPanel }) {
  return html`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${panel.purpose}</span>
        <span>Solves</span><span>${panel.problem_solved}</span>
        <span>When</span><span>${panel.when_active}</span>
        <span>Agent Role</span><span>${panel.agent_role}</span>
        <span>Ecosystem</span><span>${panel.ecosystem_function}</span>
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
  label = 'Why',
}: {
  panelId: string
  compact?: boolean
  label?: string
}) {
  const panel = findDashboardSemanticPanel(panelId)
  if (!panel) {
    return dashboardSemanticsLoading.value
      ? html`<span class="semantic-inline-state">Loading semantics…</span>`
      : null
  }
  return html`
    <details class="semantic-inline ${compact ? 'compact' : ''}">
      <summary class="semantic-summary">${label}</summary>
      <${SemanticPanelBody} panel=${panel} />
    </details>
  `
}

export function SurfaceSemanticIntro({
  surfaceId,
  compact = false,
}: {
  surfaceId: DashboardSemanticSurfaceId
  compact?: boolean
}) {
  const surface = findDashboardSemanticSurface(surfaceId)
  if (!surface) {
    if (dashboardSemanticsLoading.value) {
      return html`<div class="semantic-surface-card ${compact ? 'compact' : ''}">Loading semantics…</div>`
    }
    if (dashboardSemanticsError.value) {
      return html`<div class="semantic-surface-card ${compact ? 'compact' : ''}">${dashboardSemanticsError.value}</div>`
    }
    return null
  }
  return html`
    <section class="semantic-surface-card ${compact ? 'compact' : ''}">
      <div class="semantic-surface-head">
        <strong>${surface.label}</strong>
        <span class="semantic-code">${surface.id}</span>
      </div>
      <p class="semantic-lead">${surface.purpose}</p>
      <div class="semantic-grid">
        <span>Solves</span><span>${surface.problem_solved}</span>
        <span>When</span><span>${surface.when_active}</span>
        <span>Agent Role</span><span>${surface.agent_role}</span>
        <span>Ecosystem</span><span>${surface.ecosystem_function}</span>
      </div>
      ${surface.panels.length > 0
        ? html`<div class="semantic-tag-row">
            ${surface.panels.map(panel => html`<span class="semantic-tag">${panel.title}</span>`)}
          </div>`
        : null}
    </section>
  `
}

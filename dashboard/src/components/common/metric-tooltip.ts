import { html } from 'htm/preact'
import { getMetricDef, type MetricKey } from './metric-defs'

interface MetricTooltipProps {
  metric: MetricKey
}

export function MetricTooltip({ metric }: MetricTooltipProps) {
  const def = getMetricDef(metric)
  return html`
    <span
      class="metric-tip"
      tabindex="0"
      role="button"
      aria-label="${def.label} 설명"
      title="${def.description} (source: ${def.sourcePath})"
    >
      i
      <span class="metric-tip-pop rounded-lg" role="tooltip">
        <strong>${def.label}</strong>
        <span>${def.description}</span>
        ${def.formula ? html`<span><code class="text-[#9ad9ff]">formula:</code> ${def.formula}</span>` : null}
        <span><code class="text-[#9ad9ff]">source:</code> ${def.sourcePath}</span>
        ${def.interpretation ? html`<span>${def.interpretation}</span>` : null}
      </span>
    </span>
  `
}

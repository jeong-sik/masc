// Keeper pipeline stage indicator — shows the current lifecycle stage
// as a horizontal bar with stage dots and labels.
// CSS classes: .pipeline-stage-bar, .pipeline-stage-node, etc. (pipeline-stage.css)

import { html } from 'htm/preact'
import type { PipelineStage } from '../types'

const STAGES: { key: PipelineStage; label: string }[] = [
  { key: 'idle', label: 'idle' },
  { key: 'thinking', label: 'think' },
  { key: 'tool_use', label: 'tool' },
  { key: 'compacting', label: 'compact' },
  { key: 'handoff', label: 'handoff' },
  { key: 'scheduled_autonomous', label: 'auto' },
]

const STAGE_ORDER: Record<string, number> = Object.fromEntries(
  STAGES.map((s, i) => [s.key, i]),
)

/**
 * Full horizontal pipeline stage indicator.
 * Shows all stages as dots connected by lines. The current stage is highlighted.
 */
export function PipelineStageBar({ stage }: { stage?: PipelineStage | null }) {
  const current = stage ?? 'offline'
  const currentIdx = STAGE_ORDER[current] ?? -1

  if (current === 'offline' || currentIdx === -1) {
    return html`
      <div class="flex items-center py-1.5">
        <div class="pipeline-stage-node active stage-${current}">
          <span class="pipeline-stage-dot transition-colors duration-[var(--t-slow)]"></span>
          <span class="pipeline-stage-label">${current}</span>
        </div>
      </div>
    `
  }

  return html`
    <div class="flex items-center py-1.5">
      ${STAGES.map((s, i) => {
        const isActive = s.key === current
        const isPassed = i < currentIdx
        const nodeClass = [
          'pipeline-stage-node',
          isActive ? 'active' : '',
          isPassed ? 'passed' : '',
          isActive ? `stage-${s.key}` : '',
        ]
          .filter(Boolean)
          .join(' ')

        return html`
          ${i > 0 ? html`<span class="pipeline-stage-connector"></span>` : null}
          <div class=${nodeClass}>
            <span class="pipeline-stage-dot transition-colors duration-[var(--t-slow)]"></span>
            ${isActive
              ? html`<span class="pipeline-stage-label">${s.label}</span>`
              : null}
          </div>
        `
      })}
    </div>
  `
}

/**
 * Compact badge variant for roster cards.
 * Shows only the current stage as a small pill.
 */
export function PipelineStageBadge({
  stage,
}: {
  stage?: PipelineStage | null
}) {
  const current = stage ?? 'offline'
  const label =
    STAGES.find((s) => s.key === current)?.label ?? current

  return html`
    <span class="pipeline-stage-badge rounded-[var(--r-0)] stage-${current}">
      ${label}
    </span>
  `
}

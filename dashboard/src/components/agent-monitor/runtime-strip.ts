// AgentRuntimeStrip — compact horizontal strip showing keeper live metrics.
// Renders pipeline stage badge, context ratio bar, generation, active model, last turn age.
// Only renders if the agent has a linked keeper.

import { html } from 'htm/preact'
import { PipelineStageBadge } from '../keeper-pipeline-stage'
import { keepers } from '../../store'
import { formatDuration } from '../mission-utils'
import type { Keeper } from '../../types'

function findKeeper(name: string): Keeper | null {
  return keepers.value.find(
    k => k.agent_name === name || k.name === name,
  ) ?? null
}

function ctxBarClass(ratio: number | null | undefined): string {
  if (ratio == null) return ''
  const pct = ratio * 100
  if (pct < 50) return ''
  if (pct < 70) return 'warn'
  return 'bad'
}

export function AgentRuntimeStrip({ name }: { name: string }) {
  const keeper = findKeeper(name)
  if (!keeper) return null

  // Derive stage: prefer explicit pipeline_stage, fallback to heartbeat-based inference
  const rawStage = keeper.pipeline_stage
  const stage = rawStage
    ?? (keeper.last_turn_ago_s != null && keeper.last_turn_ago_s < 600 ? 'idle' : rawStage)
  const ctxRatio = keeper.context_ratio
  const ctxPct = ctxRatio != null ? Math.round(ctxRatio * 100) : null
  const generation = keeper.generation
  const model = keeper.active_model ?? keeper.model ?? null
  const lastTurnAge = keeper.last_turn_ago_s

  return html`
    <div class="agent-runtime-strip">
      <div class="agent-runtime-metric">
        <${PipelineStageBadge} stage=${stage} />
      </div>

      ${ctxPct != null ? html`
        <div class="agent-runtime-metric">
          <span class="agent-runtime-label">CTX</span>
          <div class="agent-runtime-ctx-bar">
            <div
              class="agent-runtime-ctx-fill ${ctxBarClass(ctxRatio)}"
              style=${{ width: `${ctxPct}%` }}
            ></div>
          </div>
          <span class="agent-runtime-value">${ctxPct}%</span>
        </div>
      ` : null}

      ${generation != null ? html`
        <div class="agent-runtime-metric">
          <span class="agent-runtime-label">GEN</span>
          <span class="agent-runtime-value">${generation}</span>
        </div>
      ` : null}

      ${model ? html`
        <div class="agent-runtime-metric">
          <span class="agent-runtime-label">MODEL</span>
          <span class="agent-runtime-value agent-runtime-model">${model}</span>
        </div>
      ` : null}

      ${lastTurnAge != null ? html`
        <div class="agent-runtime-metric">
          <span class="agent-runtime-label">TURN</span>
          <span class="agent-runtime-value">${formatDuration(lastTurnAge)} ago</span>
        </div>
      ` : null}
    </div>
  `
}

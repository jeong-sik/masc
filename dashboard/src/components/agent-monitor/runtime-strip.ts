// AgentRuntimeStrip — compact horizontal strip showing keeper live metrics.
// Renders pipeline stage badge, context ratio bar, generation, active model, last turn age.
// Only renders if the agent has a linked keeper.

import { html } from 'htm/preact'
import { PipelineStageBadge } from '../keeper-pipeline-stage'
import { findKeeper } from '../../lib/keeper-utils'
import { formatDuration } from '../mission-utils'

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
      <div class="flex items-center gap-1.5 text-sm">
        <${PipelineStageBadge} stage=${stage} />
      </div>

      ${ctxPct != null ? html`
        <div class="flex items-center gap-1.5 text-sm">
          <span class="text-3xs text-[var(--text-muted)] uppercase tracking-wider">CTX</span>
          <div class="w-16 h-1.5 bg-[#1a1a2e] rounded-sm overflow-hidden">
            <div
              class="agent-runtime-ctx-fill rounded-sm ${ctxBarClass(ctxRatio)}"
              style=${{ width: `${ctxPct}%` }}
            ></div>
          </div>
          <span class="text-sm text-[var(--text-body)] tabular-nums">${ctxPct}%</span>
        </div>
      ` : null}

      ${generation != null ? html`
        <div class="flex items-center gap-1.5 text-sm">
          <span class="text-3xs text-[var(--text-muted)] uppercase tracking-wider">GEN</span>
          <span class="text-sm text-[var(--text-body)] tabular-nums">${generation}</span>
        </div>
      ` : null}

      ${model ? html`
        <div class="flex items-center gap-1.5 text-sm">
          <span class="text-3xs text-[var(--text-muted)] uppercase tracking-wider">MODEL</span>
          <span class="text-sm text-[var(--text-body)] font-mono truncate max-w-[200px]">${model}</span>
        </div>
      ` : null}

      ${lastTurnAge != null ? html`
        <div class="flex items-center gap-1.5 text-sm">
          <span class="text-3xs text-[var(--text-muted)] uppercase tracking-wider">TURN</span>
          <span class="text-sm text-[var(--text-body)] tabular-nums">${formatDuration(lastTurnAge)} ago</span>
        </div>
      ` : null}
    </div>
  `
}

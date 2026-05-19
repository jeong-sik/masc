// Keeper pipeline stage indicator — shows the current lifecycle stage
// as a horizontal bar with stage dots and labels.
// CSS classes: .pipeline-stage-bar, .pipeline-stage-node, etc. (pipeline-stage.css)

import { html } from 'htm/preact'
import type { PipelineStage } from '../types'

// 10 values emitted by `Keeper_exec_status.pipeline_stage_of_phase`
// (lib/keeper/keeper_exec_status.ml:537) post-RFC-0046 (#14707). The
// legacy 6-entry list had `thinking` / `tool_use` /
// `scheduled_autonomous` which the backend never emits as a
// pipeline_stage value (they live in trajectory content_type / turn
// channel respectively), and was missing `failing` / `overflowed` /
// `draining` / `paused` / `crashed` / `restarting` / `offline` — so
// 7 real backend values fell through to the raw-string fallback at
// line 33. Labels are short forms suitable for the roster badge.
const STAGES: { key: PipelineStage; label: string }[] = [
  { key: 'idle', label: 'idle' },
  { key: 'compacting', label: 'compact' },
  { key: 'handoff', label: 'handoff' },
  { key: 'offline', label: 'offline' },
  { key: 'failing', label: 'fail' },
  { key: 'overflowed', label: 'overflow' },
  { key: 'draining', label: 'drain' },
  { key: 'paused', label: 'pause' },
  { key: 'crashed', label: 'crash' },
  { key: 'restarting', label: 'restart' },
]

/**
 * Compact badge variant for roster cards.
 * Shows only the current stage as a small pill.
 *
 * Note: A wider `PipelineStageBar` once lived here. RFC-0046 removed
 * its sole caller (keeper detail) in favour of the FsmHub composite
 * snapshot; the badge survives because agent-monitor / fleet roster
 * still need a one-axis stage hint outside the FSM hub.
 */
export function PipelineStageBadge({
  stage,
}: {
  stage?: PipelineStage | null
}) {
  const current = stage ?? 'unknown'
  const label =
    STAGES.find((s) => s.key === current)?.label ?? current

  return html`
    <span class="pipeline-stage-badge rounded-[var(--r-0)] stage-${current}">
      ${label}
    </span>
  `
}

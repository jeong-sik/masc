import { html } from 'htm/preact'
import { PanelCard } from './common/panel-card'

function GoalHorizonRow({
  horizon,
  value,
}: {
  horizon: string
  value: string | null | undefined
}) {
  if (!value) return null
  return html`
    <div class="flex items-start gap-2 text-xs text-[var(--color-fg-muted)] v2-monitoring-row">
      <span class="flex-shrink-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide">${horizon}</span>
      <span class="font-medium leading-relaxed text-[var(--color-fg-secondary)]">${value}</span>
    </div>
  `
}

interface KeeperGoalHorizonsPanelProps {
  short_goal?: string | null
  mid_goal?: string | null
  long_goal?: string | null
  goal_horizons?: {
    short?: string | null
    mid?: string | null
    long?: string | null
  } | null
}

export function KeeperGoalHorizonsPanel({
  short_goal,
  mid_goal,
  long_goal,
  goal_horizons,
}: KeeperGoalHorizonsPanelProps) {
  const s = short_goal ?? goal_horizons?.short
  const m = mid_goal ?? goal_horizons?.mid
  const l = long_goal ?? goal_horizons?.long
  const hasGoals = s || m || l

  if (!hasGoals) return null

  return html`
    <${PanelCard} title="Goal Horizons">
      <div class="flex flex-col gap-1.5 v2-monitoring-panel">
        <${GoalHorizonRow} horizon="short" value=${s} />
        <${GoalHorizonRow} horizon="mid" value=${m} />
        <${GoalHorizonRow} horizon="long" value=${l} />
      </div>
    <//>
  `
}

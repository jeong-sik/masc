import { html } from 'htm/preact'
import { PanelCard } from './common/panel-card'

function ProfileField({ label, value, color }: { label: string; value: string; color: string }) {
  return html`
    <div class="flex items-start gap-2 text-xs text-[var(--color-fg-muted)]">
      <span class="flex-shrink-0">${label}:</span>
      <span class="font-medium leading-relaxed" style="color: ${color}">${value}</span>
    </div>
  `
}

function GoalHorizonRow({
  horizon,
  value,
}: {
  horizon: string
  value: string | null | undefined
}) {
  if (!value) return null
  return html`
    <div class="flex items-start gap-2 text-xs text-[var(--color-fg-muted)]">
      <span class="flex-shrink-0 rounded border border-[var(--white-10)] bg-[var(--white-6)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide">${horizon}</span>
      <span class="font-medium leading-relaxed text-[var(--color-fg-secondary)]">${value}</span>
    </div>
  `
}

export interface KeeperBDIPanelProps {
  will?: string | null
  needs?: string | null
  desires?: string | null
  short_goal?: string | null
  mid_goal?: string | null
  long_goal?: string | null
  goal_horizons?: {
    short?: string | null
    mid?: string | null
    long?: string | null
  } | null
}

export function KeeperBDIPanel({
  will,
  needs,
  desires,
  short_goal,
  mid_goal,
  long_goal,
  goal_horizons,
}: KeeperBDIPanelProps) {
  const hasBdi = will || needs || desires
  const s = short_goal ?? goal_horizons?.short
  const m = mid_goal ?? goal_horizons?.mid
  const l = long_goal ?? goal_horizons?.long
  const hasGoals = s || m || l

  if (!hasBdi && !hasGoals) return null

  return html`
    <${PanelCard} title="BDI & Horizons">
      <div class="flex flex-col gap-3">
        ${hasBdi
          ? html`
              <div class="flex flex-col gap-1.5">
                ${will ? html`<${ProfileField} label="의지" value=${will} color="var(--cyan)" />` : null}
                ${needs ? html`<${ProfileField} label="필요" value=${needs} color="var(--color-status-warn)" />` : null}
                ${desires ? html`<${ProfileField} label="염망" value=${desires} color="var(--purple)" />` : null}
              </div>
            `
          : null}
        ${hasGoals
          ? html`
              <div class="flex flex-col gap-1.5">
                <div class="text-2xs font-semibold uppercase tracking-wide text-[var(--color-fg-muted)] mb-0.5">goal horizons</div>
                <${GoalHorizonRow} horizon="short" value=${s} />
                <${GoalHorizonRow} horizon="mid" value=${m} />
                <${GoalHorizonRow} horizon="long" value=${l} />
              </div>
            `
          : null}
      </div>
    <//>
  `
}

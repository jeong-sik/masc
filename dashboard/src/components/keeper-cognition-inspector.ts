import { html } from 'htm/preact'
import type { Keeper } from '../types'
import { navigate, route } from '../router'
import { keepers } from '../store'
import { EmptyState } from './common/empty-state'
import { FilterChips } from './common/filter-chips'
import { PanelCard } from './common/panel-card'
import { KeeperBadge } from './keeper-badge'
import { KeeperBDIPanel } from './keeper-bdi-panel'
import { KeeperMemoryPanel } from './memory-subsystems'
import { formatDuration } from './mission-utils'

type KeeperInspectorFocus = 'bdi' | 'tool-access' | 'memory'

interface ToolAccessRow {
  label: string
  value: string
}

const FOCUS_CHIPS: Array<{ key: KeeperInspectorFocus; label: string; title: string }> = [
  { key: 'bdi', label: 'BDI', title: 'Will, needs, desires, and goal horizons' },
  { key: 'tool-access', label: 'Tool Access', title: 'Runtime tool and execution access snapshot' },
  { key: 'memory', label: 'Memory', title: 'Keeper memory bank entries (memory.jsonl)' },
]

function keeperKeys(keeper: Keeper): string[] {
  return [
    keeper.name,
    keeper.keeper_id ?? '',
    keeper.agent_name ?? '',
  ].map(key => key.trim()).filter(Boolean)
}

export function selectKeeperForInspector(
  keeperList: readonly Keeper[],
  requestedName: string | null | undefined,
): Keeper | null {
  if (keeperList.length === 0) return null
  const requested = requestedName?.trim()
  if (requested) {
    const exact = keeperList.find(keeper => keeperKeys(keeper).includes(requested))
    if (exact) return exact
  }
  const withBdi = keeperList.find(hasBdiSnapshot)
  return withBdi ?? keeperList[0] ?? null
}

export function hasBdiSnapshot(keeper: Keeper): boolean {
  return Boolean(
    keeper.will
    || keeper.needs
    || keeper.desires
    || keeper.short_goal
    || keeper.mid_goal
    || keeper.long_goal
    || keeper.goal_horizons?.short
    || keeper.goal_horizons?.mid
    || keeper.goal_horizons?.long,
  )
}

function displayValue(value: string | number | boolean | null | undefined): string {
  if (value === null || value === undefined || value === '') return '-'
  return String(value)
}

function secondsLabel(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return '-'
  return formatDuration(seconds)
}

function listLabel(values: readonly string[] | null | undefined): string {
  const clean = (values ?? []).map(value => value.trim()).filter(Boolean)
  return clean.length === 0 ? '-' : clean.join(' · ')
}

export function toolAccessRowsForKeeper(keeper: Keeper): ToolAccessRow[] {
  const policy = keeper.approval_policy_effective
  const recentTools = keeper.recent_tool_names?.length
    ? keeper.recent_tool_names
    : keeper.latest_tool_names
  return [
    {
      label: 'cascade',
      value: displayValue(keeper.cascade_name ?? keeper.cascade_canonical ?? keeper.selected_cascade_canonical),
    },
    {
      label: 'sandbox',
      value: displayValue(keeper.sandbox_target ?? keeper.sandbox_profile),
    },
    {
      label: 'proactive idle',
      value: keeper.proactive_enabled === false
        ? `off · ${secondsLabel(keeper.proactive_idle_sec)}`
        : secondsLabel(keeper.proactive_idle_sec),
    },
    {
      label: 'mention turns',
      value: displayValue(keeper.mention_reactive_turn_count),
    },
    {
      label: 'observed tools',
      value: listLabel(recentTools),
    },
    {
      label: 'approval policy',
      value: policy
        ? `${policy.allow_rules ?? 0} allow · ${policy.deny_rules ?? 0} deny · ${policy.persisted_rules ?? 0} persisted`
        : '-',
    },
    {
      label: 'social runtime',
      value: keeper.social_model_recognized === false ? 'needs attention' : 'runtime',
    },
  ]
}

function currentFocus(): KeeperInspectorFocus {
  const f = route.value.params.focus
  if (f === 'tool-access') return 'tool-access'
  if (f === 'memory') return 'memory'
  return 'bdi'
}

function navigateFocus(focus: KeeperInspectorFocus): void {
  navigate('monitoring', {
    ...route.value.params,
    section: 'cognition',
    view: 'keeper',
    focus,
  })
}

function navigateKeeper(keeper: Keeper): void {
  navigate('monitoring', {
    ...route.value.params,
    section: 'cognition',
    view: 'keeper',
    keeper: keeper.name,
  })
}

function openKeeperDetail(keeper: Keeper): void {
  navigate('monitoring', {
    section: 'agents',
    view: 'keepers',
    keeper: keeper.name,
  })
}

function KeeperPicker({
  keeperList,
  selected,
}: {
  keeperList: readonly Keeper[]
  selected: Keeper
}) {
  return html`
    <div class="flex flex-wrap gap-1.5" role="list" aria-label="Keeper inspector targets">
      ${keeperList.map(keeper => {
        const active = keeper.name === selected.name
        return html`
          <div role="listitem">
            <button
              type="button"
              class="${active
                ? 'border-[var(--accent-30)] bg-[var(--accent-12)] text-[var(--color-fg-primary)]'
                : 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]'} inline-flex items-center gap-2 rounded-[var(--r-1)] border px-2 py-1 text-2xs transition-colors"
              aria-label=${keeper.name}
              aria-pressed=${active}
              onClick=${() => navigateKeeper(keeper)}
            >
              <${KeeperBadge} id=${keeper.name} variant="sigil" size="sm" />
              <span class="font-mono">${keeper.name}</span>
            </button>
          </div>
        `
      })}
    </div>
  `
}

function ToolAccessSnapshot({ keeper }: { keeper: Keeper }) {
  const rows = toolAccessRowsForKeeper(keeper)
  return html`
    <${PanelCard} title="Tool Access Snapshot">
      <dl class="grid grid-cols-1 gap-x-6 md:grid-cols-2">
        ${rows.map(row => html`
          <div class="grid grid-cols-[112px_1fr] items-baseline gap-3 border-b border-[var(--color-border-divider)] py-2 last:border-b-0">
            <dt class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.label}</dt>
            <dd class="font-mono text-xs text-[var(--color-fg-secondary)]">${row.value}</dd>
          </div>
        `)}
      </dl>
    <//>
  `
}

function BdiSnapshot({ keeper }: { keeper: Keeper }) {
  if (hasBdiSnapshot(keeper)) {
    return html`
      <${KeeperBDIPanel}
        will=${keeper.will}
        needs=${keeper.needs}
        desires=${keeper.desires}
        short_goal=${keeper.short_goal}
        mid_goal=${keeper.mid_goal}
        long_goal=${keeper.long_goal}
        goal_horizons=${keeper.goal_horizons}
      />
    `
  }
  return html`
    <${PanelCard} title="BDI & Horizons">
      <${EmptyState} compact=${true} message="No BDI snapshot is available for this keeper." />
    <//>
  `
}

export function KeeperCognitionInspector() {
  const keeperList = keepers.value
  const selected = selectKeeperForInspector(
    keeperList,
    route.value.params.keeper ?? route.value.params.agent,
  )
  const focus = currentFocus()

  if (!selected) {
    return html`
      <${EmptyState}
        message="No keeper runtime snapshots are loaded."
        compact=${true}
      />
    `
  }

  return html`
    <section class="grid gap-4" aria-label="Keeper cognition inspector" data-testid="keeper-cognition-inspector">
      <div class="monitor-muted-panel flex flex-col gap-3 px-4 py-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <${KeeperBadge} id=${selected.name} variant="full" size="md" />
            <span class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              ${displayValue(selected.status)}
            </span>
          </div>
          <button
            type="button"
            class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-1.5 text-2xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)]"
            onClick=${() => openKeeperDetail(selected)}
          >
            Open detail
          </button>
        </div>

        <${KeeperPicker} keeperList=${keeperList} selected=${selected} />

        <${FilterChips}
          chips=${FOCUS_CHIPS}
          value=${focus}
          onChange=${navigateFocus}
          size="sm"
          tone="accent"
        />
      </div>

      ${focus === 'tool-access'
        ? html`<${ToolAccessSnapshot} keeper=${selected} />`
        : focus === 'memory'
          ? html`<${KeeperMemoryPanel} keeperName=${selected.name} />`
          : html`<${BdiSnapshot} keeper=${selected} />`}
    </section>
  `
}

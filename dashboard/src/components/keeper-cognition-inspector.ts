import { html } from 'htm/preact'
import type { Keeper } from '../types'
import { navigate, route } from '../router'
import { keepers } from '../store'
import { EmptyState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import { PanelCard } from './common/panel-card'
import { KeeperBadge } from './keeper-badge'
import { KeeperMemoryPanel } from './memory-subsystems'

type KeeperInspectorFocus = 'tool-access' | 'memory'

interface ToolAccessRow {
  label: string
  value: string
}

const FOCUS_CHIPS: Array<{ key: KeeperInspectorFocus; label: string; title: string }> = [
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
  return keeperList[0] ?? null
}

function displayValue(value: string | number | boolean | null | undefined): string {
  if (value === null || value === undefined || value === '') return '-'
  return String(value)
}

function listLabel(values: readonly string[] | null | undefined): string {
  const clean = (values ?? []).map(value => value.trim()).filter(Boolean)
  return clean.length === 0 ? '-' : clean.join(' · ')
}

export function toolAccessRowsForKeeper(keeper: Keeper): ToolAccessRow[] {
  const recentTools = keeper.recent_tool_names?.length
    ? keeper.recent_tool_names
    : keeper.latest_tool_names
  return [
    {
      label: 'runtime',
      value: displayValue(keeper.runtime_id ?? keeper.runtime_canonical ?? keeper.selected_runtime_canonical),
    },
    {
      label: 'sandbox',
      value: displayValue(keeper.sandbox_target ?? keeper.sandbox_profile),
    },
    {
      label: 'proactive',
      value: keeper.proactive_enabled === false ? 'off' : 'on',
    },
    {
      label: 'mention turns',
      value: displayValue(keeper.mention_reactive_turn_count),
    },
    {
      label: 'observed tools',
      value: listLabel(recentTools),
    },
  ]
}

function currentFocus(): KeeperInspectorFocus {
  const f = route.value.params.focus
  if (f === 'memory') return 'memory'
  return 'tool-access'
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
              class="v2-monitoring-action ${active
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
      <div class="v2-monitoring-panel monitor-muted-panel flex flex-col gap-3 px-4 py-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <${KeeperBadge} id=${selected.name} variant="full" size="md" />
            <span class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              ${displayValue(selected.status)}
            </span>
          </div>
          <button
            type="button"
            class="v2-monitoring-action rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-1.5 text-2xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)]"
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

      ${focus === 'memory'
        ? html`<${KeeperMemoryPanel} keeperName=${selected.name} />`
        : html`<${ToolAccessSnapshot} keeper=${selected} />`}
    </section>
  `
}

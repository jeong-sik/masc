// Keeper runtime signals, neighborhood, and tool audit panels.
// Redesigned: consistent signal row styling with inline Tailwind,
// clean tool chip badges, proper section spacing.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { formatPct1 } from '../lib/format-number'
import {
  compactToken,
  deriveKeeperRuntimeProjection,
  type KeeperRuntimeProjectionRuntimeInput,
} from '../lib/keeper-runtime-projection'
import { ActionButton } from './common/button'
import { CollapsibleSection } from './common/collapsible'
import { DistributionBars, type DistributionItem } from './common/distribution-bars'
import { TextInput } from './common/input'
import { TimeAgo } from './common/time-ago'
import { SectionHeader } from './common/section-header'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { toolCategory } from './tool-call-shared'
import { formatIndependentCounters, formatRatioPair } from './counter-format'
import type { Keeper } from '../types'
import type {
  KeeperCompositeSnapshot,
  KeeperSecretProjection,
  KeeperRuntimeLensClockEdge,
  KeeperRuntimeLensClockGroup,
  KeeperRuntimeLensLane,
  KeeperRuntimeLensPayloadRoleAxis,
  KeeperRuntimeLensSourceClockAxis,
  KeeperRuntimeTraceResponse,
} from '../api/keeper'
import { serverStatus, shellRuntimeResolution } from '../store'
import { operatorSnapshot } from '../operator-store'
import type { KeeperDetailEvidenceState } from './keeper-detail-hooks'
import {
  allowlistEmptyState,
  auditMetadataState,
  linkedRuntimeState,
  observedToolsEmptyState,
  openToolsInventory,
  toolAuditStateLabel,
} from './common/tool-audit'
import {
  resolveKeeperMissionBrief,
  resolveKeeperObservedToolAudit,
  resolveKeeperToolPolicy,
} from './keeper-detail-source'
import {
  loadKeeperConfig,
  peekKeeperConfigLoadStatus,
  peekLoadedKeeperConfig,
} from './keeper-config-panel'

const DEFAULT_ALLOWLIST_PREVIEW_LIMIT = 12

// ── Utility functions ────────────────────────────────────

export function resolveKeeperCurrentTaskLabel(
  keeper: Keeper | null | undefined,
): string {
  const runtimeState = linkedRuntimeState(keeper)
  if (!keeper) return 'unlinked'
  if (runtimeState === 'offline') return 'offline'
  if (!keeper.agent) return 'not_collected'
  if (typeof keeper.agent.current_task === 'string' && keeper.agent.current_task.trim() !== '') {
    return keeper.agent.current_task
  }
  return 'unassigned'
}

// ── Shared row component ─────────────────────────────────

function SignalRow({ label, value, title }: { label: string; value: string | number; title?: string }) {
  const valueText = String(value)
  return html`
    <div class="flex items-center justify-between gap-3 py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] min-w-0">
      <span class="text-xs text-[var(--color-fg-muted)] shrink-0">${label}</span>
      <span class="text-xs font-medium text-[var(--color-fg-secondary)] text-right truncate min-w-0" title=${title ?? valueText}>${valueText}</span>
    </div>
  `
}

type KeeperLiveTruthRuntimeInput = KeeperRuntimeProjectionRuntimeInput

export interface KeeperLiveTruthRow {
  label: string
  value: string
  detail: string
  tone: StatusChipTone
}

export interface KeeperLiveTruthSummary {
  headline: string
  tone: StatusChipTone
  rows: KeeperLiveTruthRow[]
  runtimeWarnings: string[]
  runtimeBuildLabel: string | null
  runtimeRepoLabel: string | null
}

export function deriveKeeperLiveTruth({
  keeper,
  compositeSnapshot,
  runtimeTrace,
  runtimeResolution,
}: {
  keeper: Keeper
  compositeSnapshot: KeeperCompositeSnapshot | null
  runtimeTrace: KeeperRuntimeTraceResponse | null
  runtimeResolution?: KeeperLiveTruthRuntimeInput | null
}): KeeperLiveTruthSummary {
  const projection = deriveKeeperRuntimeProjection({
    keeper,
    composite: compositeSnapshot,
    runtimeTrace,
    runtimeResolution,
    linkedState: linkedRuntimeState(keeper),
  })

  const opState = projection.opState
  const fiberAlive = projection.fiberAlive.alive
  const stuckByBlockerClass = opState.kind === 'stuck'
  const staleBlocker = opState.kind === 'running' ? opState.staleBlocker : null
  const attention = opState.attention
  const blocked = projection.blocked
  const traceEvidence = projection.traceEvidence
  // guardCount / invariantFailed have moved to FsmHub mode='detail' — they
  // are rendered on the dedicated FSM lane strip directly under this panel
  // and no longer need to be projected as a row here.
  // The dedicated `동기화` row is the coupled projection: heartbeat/context/
  // social/fiber/stop/trace/tool/FSM lanes move as one derived object while
  // FsmHub still renders raw lanes below this panel.
  const fiberLabel = fiberAlive ? 'fiber alive' : 'fiber not proven'
  const liveTurnLabel = projection.activeTurn ? `${projection.turnPhase} live` : 'no live turn'
  // A-PR-2 G2: surface the running turn's model + in-flight tool count when a
  // live turn is present. A pinned backend may omit these fields; render that
  // as unknown rather than inventing an idle-looking zero.
  const liveTurn = compositeSnapshot?.live_turn ?? null
  const liveTurnModelDetail = liveTurn
    ? ` · model ${liveTurn.selected_model ?? '—'} · tools ${liveTurn.active_tool_count ?? '—'}`
    : ''
  return {
    headline: projection.headline,
    tone: projection.tone,
    runtimeWarnings: projection.runtimeWarnings,
    runtimeBuildLabel: projection.runtimeBuildLabel,
    runtimeRepoLabel: projection.runtimeRepoLabel,
    rows: [
      {
        label: '동기화',
        value: projection.synchronizationLabel,
        detail: projection.synchronizationDetail,
        tone: projection.tone,
      },
      {
        label: '런타임',
        value: fiberLabel,
        detail: `roster ${keeper.status} · linked ${projection.linkedState} · ${projection.fiberAlive.source}`,
        tone: fiberAlive ? 'ok' : 'warn',
      },
      {
        label: '현재 턴',
        value: liveTurnLabel,
        detail: `${compositeSnapshot ? (compositeSnapshot.is_live === true ? 'is_live=true' : 'is_live=false') : 'is_live=unknown'} · ${projection.turnPhase} · ${projection.idleLabel}${liveTurnModelDetail}`,
        tone: projection.activeTurn ? 'ok' : 'neutral',
      },
      {
        label: '최신 증거',
        value: traceEvidence.value,
        detail: traceEvidence.detail,
        tone: traceEvidence.tone,
      },
      {
        label: '차단',
        // RFC-0135 PR-5: typed reason takes precedence so the row text
        // matches the roster card ("synthetic_stall" vs bare "blocked").
        // When the receipt is from a prior turn (`staleBlocker` set),
        // the row stays at 'none' (current execution is not blocked)
        // and the prior-turn class is shown in the detail line below.
        // This preserves the pre-RFC "차단 = none means clean now"
        // operator mental model.
        value: stuckByBlockerClass
          ? opState.reason
          : attention !== 'clean'
            ? compactToken(compositeSnapshot?.runtime_attention?.state, 'blocked')
            : 'none',
        detail: staleBlocker !== null
          ? `${projection.runtimeReason} · 이전 차단: ${staleBlocker}`
          : projection.runtimeReason,
        tone: blocked ? 'warn' : 'ok',
      },
    ],
  }
}

type EvidenceStampVisual = {
  tone: StatusChipTone
  label: string
  timestamp: number | null
  errorMessage: string | null
}

/** Project the typed evidence union onto the stamp display fields.
 *  Exhaustive `switch` — TypeScript's `noFallthroughCasesInSwitch` plus
 *  the absence of `default:` make a new union arm a compile error. */
function projectEvidenceStamp(state: KeeperDetailEvidenceState<unknown>): EvidenceStampVisual {
  switch (state.kind) {
    case 'fresh':
      return { tone: 'ok', label: 'fresh', timestamp: state.fetchedAt, errorMessage: null }
    case 'stale':
      // Stale = previously fresh, current fetch failed. Surface the
      // age via timestamp AND the failure message — the operator must
      // see both, not just the cached data underneath.
      return { tone: 'warn', label: 'stale', timestamp: state.fetchedAt, errorMessage: state.error }
    case 'error':
      return { tone: 'warn', label: 'error', timestamp: null, errorMessage: state.error }
    case 'loading':
      return { tone: 'neutral', label: 'loading', timestamp: null, errorMessage: null }
  }
}

function EvidenceStamp({
  label,
  evidence,
}: {
  label: string
  evidence: KeeperDetailEvidenceState<unknown>
}) {
  const visual = projectEvidenceStamp(evidence)
  return html`
    <span class="inline-flex min-w-0 items-center gap-1.5 text-3xs text-[var(--color-fg-muted)]">
      <${StatusChip} tone=${visual.tone} uppercase=${false}>${label}<//>
      ${visual.timestamp !== null
        ? html`<${TimeAgo} timestamp=${visual.timestamp} />`
        : html`<span>${visual.label}</span>`}
      ${visual.errorMessage !== null
        ? html`<span class="truncate text-[var(--color-status-warn)]">${visual.errorMessage}</span>`
        : null}
    </span>
  `
}

export function KeeperLiveTruthPanel({
  keeper,
  compositeSnapshot,
  runtimeTrace,
  compositeEvidence,
  runtimeTraceEvidence,
}: {
  keeper: Keeper
  compositeSnapshot: KeeperCompositeSnapshot | null
  runtimeTrace: KeeperRuntimeTraceResponse | null
  compositeEvidence: KeeperDetailEvidenceState<KeeperCompositeSnapshot>
  runtimeTraceEvidence: KeeperDetailEvidenceState<KeeperRuntimeTraceResponse>
}) {
  const runtimeResolution = shellRuntimeResolution.value
  const summary = deriveKeeperLiveTruth({
    keeper,
    compositeSnapshot,
    runtimeTrace,
    runtimeResolution,
  })
  // RFC-0046 §4.3 partial closure: the four inline detail badges that used
  // to live next to the headline (`phase X · turn Y · fiber ... · live ...`)
  // were a string-concat-then-split-back projection of the same fields the
  // row grid below already shows. Dropped — single representation per axis.
  const firstWarning = summary.runtimeWarnings[0] ?? null
  const extraWarningCount = Math.max(0, summary.runtimeWarnings.length - 1)

  return html`
    <div
      class="v2-monitoring-detail min-w-0 w-full max-w-full overflow-x-hidden rounded-[var(--r-5)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-4"
      data-testid="keeper-live-truth"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Live truth</div>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <${StatusChip} tone=${summary.tone} uppercase=${false}>${summary.headline}<//>
          </div>
        </div>
        <div class="flex min-w-0 flex-wrap justify-start gap-2 sm:justify-end">
          <${EvidenceStamp} label="composite" evidence=${compositeEvidence} />
          <${EvidenceStamp} label="trace" evidence=${runtimeTraceEvidence} />
        </div>
      </div>

      ${firstWarning ? html`
        <div class="mt-3 flex min-w-0 flex-wrap items-center gap-2 rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-xs text-[var(--color-fg-secondary)]">
          <${StatusChip} tone="warn" uppercase=${false}>runtime warning<//>
          <span class="min-w-0 flex-1 truncate">${firstWarning}</span>
          ${extraWarningCount > 0 ? html`<span class="text-3xs text-[var(--color-fg-muted)]">+${extraWarningCount}</span>` : null}
        </div>
      ` : null}

      <div class="mt-3 grid grid-cols-1 gap-2 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-5">
        ${summary.rows.map(row => html`
          <div class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
            <div class="flex items-center justify-between gap-2">
              <span class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.label}</span>
              <${StatusChip} tone=${row.tone} uppercase=${false}>${row.tone}<//>
            </div>
            <div class="mt-1 truncate text-sm font-medium text-[var(--color-fg-primary)]" title=${row.value}>${row.value}</div>
            <div class="mt-1 truncate text-3xs text-[var(--color-fg-muted)]" title=${row.detail}>${row.detail}</div>
          </div>
        `)}
      </div>

      ${(summary.runtimeBuildLabel || summary.runtimeRepoLabel) ? html`
        <div class="mt-3 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-muted)]">
          ${summary.runtimeBuildLabel ? html`<span class="font-mono">build ${summary.runtimeBuildLabel}</span>` : null}
          ${summary.runtimeRepoLabel ? html`<span class="font-mono">repo ${summary.runtimeRepoLabel}</span>` : null}
        </div>
      ` : null}
    </div>
  `
}

function secretProjectionTone(status: string | null | undefined): StatusChipTone {
  switch (status) {
    case 'ready':
      return 'ok'
    case 'error':
      return 'bad'
    case 'empty':
      return 'warn'
    case 'absent':
    default:
      return 'neutral'
  }
}

function secretProjectionLabel(status: string | null | undefined): string {
  switch (status) {
    case 'ready':
      return 'ready'
    case 'error':
      return 'error'
    case 'empty':
      return 'empty'
    case 'absent':
      return 'not configured'
    default:
      return 'unknown'
  }
}

function truncateSecretProjectionList(values: readonly string[], limit: number): string {
  if (values.length === 0) return 'none'
  const visible = values.slice(0, limit)
  const suffix = values.length > visible.length ? ` +${values.length - visible.length}` : ''
  return `${visible.join(', ')}${suffix}`
}

function secretRootScopeLabel(index: number, total: number): string {
  if (total <= 1) return 'keeper'
  if (index === 0) return 'shared'
  if (index === total - 1) return 'keeper'
  return `scope ${index + 1}`
}

function secretRootCounts(root: KeeperSecretProjection['effective_roots'][number]): string {
  return `${root.env_count} env · ${root.file_count} files`
}

export function KeeperSecretProjectionPanel({
  projection,
}: {
  projection: KeeperSecretProjection | null | undefined
}) {
  if (!projection) {
    return html`
      <div
        class="v2-monitoring-detail rounded-[var(--r-5)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-4"
        data-testid="keeper-secret-projection"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Secret projection</div>
            <div class="mt-1 text-sm font-medium text-[var(--color-fg-primary)]">backend not reporting</div>
          </div>
          <${StatusChip} tone="neutral" uppercase=${false}>unknown<//>
        </div>
      </div>
    `
  }

  const tone = secretProjectionTone(projection.status)
  const filePaths = projection.file_mounts.map(mount => mount.container_path)
  const envSummary = truncateSecretProjectionList(projection.env_names, 5)
  const fileSummary = truncateSecretProjectionList(filePaths, 4)
  const effectiveRoots = projection.effective_roots ?? []
  const rootRows = effectiveRoots.map((root, index) => ({
    ...root,
    label: secretRootScopeLabel(index, effectiveRoots.length),
  }))
  const scopeSummary = rootRows.length > 0 ? rootRows.map(row => row.label).join(' -> ') : 'keeper'
  const rootSummary = rootRows.length > 0
    ? truncateSecretProjectionList(rootRows.map(row => `${row.label}: ${row.status} · ${secretRootCounts(row)}`), 3)
    : projection.root
  const rootTitle = rootRows.length > 0
    ? rootRows.map(row => `${row.label}: ${row.root}`).join('\n')
    : projection.root
  const summary =
    projection.status === 'ready'
      ? `${projection.env_count} env · ${projection.file_count} files`
      : projection.status === 'error'
        ? projection.error ?? 'projection error'
        : projection.next_action

  return html`
    <div
      class="v2-monitoring-detail rounded-[var(--r-5)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-4"
      data-testid="keeper-secret-projection"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Secret projection</div>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <${StatusChip} tone=${tone} uppercase=${false}>${secretProjectionLabel(projection.status)}<//>
            <span class="text-sm font-medium text-[var(--color-fg-primary)]">${summary}</span>
          </div>
        </div>
        <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${projection.source}</span>
      </div>

      <div class="mt-3 grid grid-cols-1 gap-2 md:grid-cols-2">
        <${SignalRow} label="scope order" value=${scopeSummary} />
        <${SignalRow} label="effective roots" value=${rootSummary} title=${rootTitle} />
        <${SignalRow} label="keeper root" value=${projection.root} />
        <${SignalRow} label="env names" value=${envSummary} />
        <${SignalRow} label="file mounts" value=${fileSummary} />
        <${SignalRow} label="validation" value=${projection.values_validated ? 'values validated · values redacted' : 'structure only'} />
      </div>

      ${rootRows.length > 1
        ? html`
            <div class="mt-3 divide-y divide-[var(--color-border-subtle)] rounded-[var(--r-1)] border border-[var(--color-border-subtle)]">
              ${rootRows.map(row => html`
                <div class="grid grid-cols-[minmax(72px,0.5fr)_minmax(0,1.5fr)_auto] items-center gap-3 px-3 py-2 text-xs">
                  <span class="font-medium text-[var(--color-fg-secondary)]">${row.label}</span>
                  <span class="truncate font-mono text-[var(--color-fg-muted)]" title=${row.root}>${row.root}</span>
                  <span class="text-right text-[var(--color-fg-muted)]">${row.status} · ${secretRootCounts(row)}</span>
                </div>
              `)}
            </div>
          `
        : null}

      ${projection.error
        ? html`
            <div class="mt-3 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-xs text-[var(--bad-light)]">
              ${projection.error}
            </div>
          `
        : null}
    </div>
  `
}

// ── Tool chip badge ──────────────────────────────────────

function ToolChip({ name }: { name: string }) {
  const cat = toolCategory(name)
  return html`
    <${ActionButton}
      variant="primary"
      size="sm"
      class="!rounded-[var(--r-0)] !py-0.5 !text-3xs !text-[var(--color-accent-fg)] inline-flex items-center gap-1"
      title=${`${cat.label}: ${name}`}
      ariaLabel=${`${cat.label}: ${name}`}
      onClick=${() => openToolsInventory(name)}
    >
      <span class="font-mono font-bold ${cat.color}">${cat.icon}</span>
      <span>${name}</span>
    <//>
  `
}

export function resolveAllowlistPreview(
  tools: string[],
  previewLimit = DEFAULT_ALLOWLIST_PREVIEW_LIMIT,
): { visibleTools: string[]; hiddenCount: number } {
  const normalizedLimit = Math.max(0, previewLimit)
  const visibleTools = tools.slice(0, normalizedLimit)
  return {
    visibleTools,
    hiddenCount: Math.max(0, tools.length - visibleTools.length),
  }
}

export function AllowlistPreview({
  tools,
  emptyLabel,
  previewLimit = DEFAULT_ALLOWLIST_PREVIEW_LIMIT,
}: {
  tools: string[]
  emptyLabel: string
  previewLimit?: number
}) {
  const [expanded, setExpanded] = useState(false)
  const firstTool = tools[0] ?? null
  const lastTool = tools.length > 0 ? tools[tools.length - 1] : null

  useEffect(() => {
    setExpanded(false)
  }, [tools.length, firstTool, lastTool, previewLimit])

  if (tools.length === 0) {
    return html`<span class="text-2xs text-[var(--color-fg-muted)] italic">${emptyLabel}</span>`
  }

  const { visibleTools, hiddenCount } = expanded
    ? { visibleTools: tools, hiddenCount: 0 }
    : resolveAllowlistPreview(tools, previewLimit)

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1.5">
        ${visibleTools.map(tool => html`<${ToolChip} name=${tool} />`)}
        ${!expanded && hiddenCount > 0
          ? html`
              <span class="inline-flex items-center py-0.5 px-2 rounded-[var(--r-0)] text-3xs font-medium border border-dashed border-[var(--color-border-default)] text-[var(--color-fg-muted)]">
                +${hiddenCount}
              </span>
            `
          : null}
      </div>
      ${tools.length > previewLimit
        ? html`
            <button type="button"
              class="self-start text-3xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] cursor-pointer transition-colors"
              aria-expanded=${expanded}
              aria-label=${expanded ? '허용된 도구 접기' : `허용된 도구 나머지 ${hiddenCount}개 보기`}
              onClick=${() => setExpanded(value => !value)}
            >
              ${expanded ? '접기' : `나머지 ${hiddenCount}개 보기`}
            </button>
          `
        : null}
    </div>
  `
}

// ── Tool list section ────────────────────────────────────

function ToolSection({ title, description, tools, fallback }: { title: string; description?: string; tools: string[]; fallback: string }) {
  return html`
    <div class="flex flex-col gap-1.5 mt-3">
      <${SectionHeader} size="xs">${title}</${SectionHeader}>
      ${description ? html`<span class="text-2xs text-[var(--color-fg-muted)] leading-snug">${description}</span>` : null}
      <div class="flex flex-wrap gap-1.5">
        ${tools.length > 0
          ? tools.map(tool => html`<${ToolChip} name=${tool} />`)
          : html`<span class="text-2xs text-[var(--color-fg-muted)] italic">${fallback}</span>`}
      </div>
    </div>
  `
}

// ── Turn Budget ──────────────────────────────────────────

function hasTurnBudgetDivergence(keeper: Keeper): boolean {
  const b = keeper.turn_budget
  if (!b) return false
  return (
    b.reactive.source === 'override' ||
    b.reactive.source === 'override_invalid' ||
    b.scheduled_autonomous.source === 'override' ||
    b.scheduled_autonomous.source === 'override_invalid'
  )
}

export type BudgetSource = 'override' | 'env' | 'override_invalid'

interface BudgetSlot {
  value: number
  source: BudgetSource
  env_default: number
  env_var: string
  raw_override: number | null
}

export function budgetSourceTone(source: BudgetSource): StatusChipTone {
  switch (source) {
    case 'override_invalid':
      return 'bad'
    case 'override':
      return 'warn'
    case 'env':
    default:
      return 'neutral'
  }
}

export function budgetSourceLabel(source: BudgetSource): string {
  switch (source) {
    case 'override_invalid':
      return 'invalid'
    case 'override':
      return 'override'
    case 'env':
    default:
      return 'env'
  }
}

export function BudgetSourceBadge({ source, children }: { source: BudgetSource; children?: unknown }) {
  const weight = source === 'env' ? 'font-medium' : 'font-semibold'
  return html`<${StatusChip} tone=${budgetSourceTone(source)} uppercase=${true} class=${weight}>${children ?? budgetSourceLabel(source)}</${StatusChip}>`
}

function buildBudgetTooltip(slot: BudgetSlot, manifest: string | null, clamp: { min: number; max: number }): string {
  const lines: string[] = []
  if (slot.source === 'override') {
    lines.push(`Source: TOML override`)
    if (manifest) lines.push(`File:   ${manifest}`)
    lines.push(`Value:  ${slot.value}  (env default was ${slot.env_default})`)
  } else if (slot.source === 'override_invalid') {
    lines.push(`Source: env default (override REJECTED)`)
    if (manifest) lines.push(`File:   ${manifest}`)
    if (slot.raw_override != null) {
      lines.push(`Raw:    ${slot.raw_override}  — out of range [${clamp.min}, ${clamp.max}]`)
    }
    lines.push(`Value:  ${slot.value}  (fell back to env default)`)
  } else {
    lines.push(`Source: env default`)
    lines.push(`Env:    ${slot.env_var} = ${slot.value}`)
    lines.push(`Note:   no override in TOML`)
  }
  lines.push(`Range:  [${clamp.min}, ${clamp.max}]`)
  return lines.join('\n')
}

function BudgetRow({ label, slot, manifest, clamp }: {
  label: string
  slot: BudgetSlot
  manifest: string | null
  clamp: { min: number; max: number }
}) {
  const isOverride = slot.source === 'override'
  const isInvalid = slot.source === 'override_invalid'
  const delta = slot.value - slot.env_default
  const deltaText = delta === 0
    ? null
    : delta > 0
      ? `+${delta} (env 기준)`
      : `${delta} (env 기준)`

  let valueClass: string
  if (isInvalid) {
    valueClass = 'text-[var(--bad-light)] underline decoration-wavy decoration-red-400 underline-offset-4 cursor-help'
  } else if (isOverride) {
    valueClass = 'text-[var(--color-fg-secondary)] underline decoration-dotted decoration-amber-300/60 underline-offset-4 cursor-help'
  } else {
    valueClass = 'text-[var(--color-fg-muted)] cursor-help'
  }

  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
      <span class="text-xs text-[var(--color-fg-muted)]">${label}</span>
      <div class="flex items-center gap-2">
        ${isOverride && deltaText
          ? html`<span class="text-3xs text-[var(--color-fg-muted)] tabular-nums">${deltaText}</span>`
          : null}
        <span
          class="text-xs font-medium tabular-nums ${valueClass}"
          title=${buildBudgetTooltip(slot, manifest, clamp)}
        >${slot.value}</span>
        <${BudgetSourceBadge} source=${slot.source} />
      </div>
    </div>
  `
}

function TurnBudgetPanel({ keeper }: { keeper: Keeper }) {
  const budget = keeper.turn_budget
  if (!budget) {
    return html`
      <div class="text-2xs text-[var(--color-fg-muted)] italic">
        턴 예산 정보를 아직 수신하지 못했습니다. 서버 재시작 후 확인해주세요.
      </div>
    `
  }

  const hasOverride =
    budget.reactive.source === 'override' ||
    budget.scheduled_autonomous.source === 'override'
  const hasInvalid =
    budget.reactive.source === 'override_invalid' ||
    budget.scheduled_autonomous.source === 'override_invalid'
  const clamp = { min: budget.clamp_min, max: budget.clamp_max }

  return html`
    <div class="flex flex-col gap-1.5">
      <div class="flex items-center gap-2 mb-1">
        <${SectionHeader} size="xs">턴 예산 (OAS 호출당)</${SectionHeader}>
        ${hasInvalid
          ? html`<${StatusChip} tone="bad" uppercase=${true} class="font-semibold">invalid override</${StatusChip}>`
          : hasOverride
            ? html`<${StatusChip} tone="warn" uppercase=${true} class="font-semibold">override</${StatusChip}>`
            : html`<${StatusChip} tone="ok" uppercase=${true} class="font-medium">inherited</${StatusChip}>`}
      </div>
      <${BudgetRow}
        label="반응형"
        slot=${budget.reactive}
        manifest=${budget.manifest_path}
        clamp=${clamp}
      />
      <${BudgetRow}
        label="예약 자율"
        slot=${budget.scheduled_autonomous}
        manifest=${budget.manifest_path}
        clamp=${clamp}
      />
      <span class="text-2xs text-[var(--color-fg-muted)] leading-snug mt-1">
        반응형 = 보드/멘션 반응 턴 예산, 예약 자율 = 자율 주기 턴 예산.
        값에 마우스를 올리면 설정 출처와 기본값 비교를 확인할 수 있습니다.
      </span>
    </div>
  `
}

export function TurnBudgetSection({ keeper }: { keeper: Keeper }) {
  const diverges = hasTurnBudgetDivergence(keeper)
  return html`
    <${CollapsibleSection}
      title=${html`터 예산 ${diverges ? html`<span class="text-3xs text-[var(--color-status-warn)] font-normal normal-case tracking-normal">(재정의됨)</span>` : null}`}
      open=${diverges}
      dotClass=${diverges ? 'bg-[var(--warn-10)]' : 'bg-[var(--accent-50)]'}
    >
      <${TurnBudgetPanel} keeper=${keeper} />
    <//>
  `
}

// ── Runtime Signals ──────────────────────────────────────

// Helper: format a float with fixed decimals or '-'
function fmtFixed(v: number | undefined, digits = 3): string {
  return v != null ? v.toFixed(digits) : '-'
}

// Helper: format an integer count or '-'
function fmtCount(v: number | undefined): string | number {
  return v != null ? v : '-'
}

interface SignalGroup {
  title: string
  rows: Array<{ label: string; value: string | number }>
}

/**
 * Filter SignalGroups by a case-insensitive substring match on row labels.
 * Empty/whitespace query returns the input reference unchanged (no allocation).
 * Groups with no matching rows are dropped. Input is not mutated.
 */
export function filterSignalGroups(
  groups: readonly SignalGroup[],
  query: string,
): readonly SignalGroup[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return groups
  const out: SignalGroup[] = []
  for (const group of groups) {
    const matchedRows = group.rows.filter(r => r.label.toLowerCase().includes(needle))
    if (matchedRows.length > 0) {
      out.push({ title: group.title, rows: matchedRows })
    }
  }
  return out
}

function countSignalRows(groups: readonly SignalGroup[]): number {
  let total = 0
  for (const group of groups) total += group.rows.length
  return total
}

export function RuntimeSignals({ keeper }: { keeper: Keeper }) {
  const [signalQuery, setSignalQuery] = useState('')
  const mw = keeper.metrics_window

  // Quality/rate metrics only — raw counts (handoffs, compactions, turns)
  // are authoritative in KpiGrid to avoid duplication.
  const groups: SignalGroup[] = [
    {
      title: '폴백',
      rows: [
        { label: '전체 폴백', value: formatPct1(mw?.fallback_rate) },
        { label: '런타임 폴백', value: formatPct1(mw?.model_fallback_rate) },
        { label: '프로액티브 폴백', value: formatPct1(mw?.proactive_fallback_rate) },
      ],
    },
    {
      title: 'LLM 응답 정렬',
      rows: [
        { label: '목표 일치도', value: fmtFixed(mw?.goal_alignment_avg) },
        { label: '응답 일치도', value: fmtFixed(mw?.response_alignment_avg) },
        { label: '목표 이탈도', value: fmtFixed(mw?.goal_drift_avg) },
        { label: '반복 패턴 위험도', value: fmtFixed(mw?.repetition_risk_avg) },
      ],
    },
    {
      title: '자율 행동 & 반응',
      rows: [
        { label: '자동 성찰 비율', value: formatPct1(mw?.auto_reflect_rate) },
        { label: '자동 계획 비율', value: formatPct1(mw?.auto_plan_rate) },
        { label: '자동 컴팩션 비율', value: formatPct1(mw?.auto_compact_rate) },
        { label: '자동 핸드오프 비율', value: formatPct1(mw?.auto_handoff_rate) },
        { label: '가드레일 정지', value: fmtCount(mw?.guardrail_stop_count) },
        { label: '멘션 반응', value: fmtCount(keeper.mention_reactive_turn_count) },
        { label: '프리뷰 유사도', value: formatPct1(mw?.proactive_preview_similarity_avg) },
      ],
    },
    {
      title: '드리프트 보정',
      rows: [
        { label: '보정 횟수', value: fmtCount(mw?.drift_applied_count) },
        { label: '보정 비율', value: formatPct1(mw?.drift_applied_rate) },
        { label: '개입 비중', value: formatPct1(mw?.intervention_share) },
        { label: '턴당 개입', value: fmtFixed(mw?.intervention_per_turn, 2) },
      ],
    },
    {
      title: '메모리 & 컴팩션',
      rows: [
        { label: '메모리 통과율', value: formatPct1(mw?.memory_pass_rate) },
        { label: '메모리 평균 점수', value: fmtFixed(mw?.memory_avg_score) },
        { label: '메모리 교정', value: fmtCount(mw?.memory_corrections) },
        { label: '교정 성공', value: fmtCount(mw?.memory_correction_success) },
        { label: '컴팩션 드롭 비율', value: formatPct1(mw?.memory_compaction_drop_ratio) },
        { label: '컴팩션 절감', value: formatPct1(mw?.compaction_saved_ratio) },
        { label: '평균 절감 토큰', value: fmtFixed(mw?.avg_compaction_saved_tokens, 0) },
      ],
    },
  ]

  // Filter out groups where all rows are '-'
  const visibleGroups = groups
    .map(g => ({
      ...g,
      rows: g.rows.filter(r => r.value !== '-' && r.value !== '\u2014' && r.value !== ''),
    }))
    .filter(g => g.rows.length > 0)

  const topListSections = [
    topListDistribution(mw?.top_tools, 'tool', '주요 도구'),
    topListDistribution(mw?.top_work_kinds, 'kind', '주요 작업 종류'),
  ].filter((section): section is {
    title: string
    subtitle: string
    items: DistributionItem[]
  } => section !== null)

  if (visibleGroups.length === 0 && topListSections.length === 0) return null

  const filteredGroups = filterSignalGroups(visibleGroups, signalQuery)
  const totalRows = countSignalRows(visibleGroups)
  const matchedRows = countSignalRows(filteredGroups)
  const isFiltering = signalQuery.trim() !== ''
  const showEmptyState = isFiltering && matchedRows === 0

  return html`
    <div class="flex flex-col gap-3">
      ${totalRows > 0
        ? html`
            <div class="flex items-center gap-2">
              <${TextInput}
                type="search"
                class="flex-1 min-w-0 !py-1.5 !px-2 !text-2xs"
                placeholder="신호 지표 필터 (예: 폴백, 메모리, 컴팩션)"
                ariaLabel="런타임 신호 지표 필터"
                value=${signalQuery}
                onInput=${(event: Event) => {
                  const target = event.currentTarget as HTMLInputElement | null
                  setSignalQuery(target?.value ?? '')
                }}
              />
              ${isFiltering
                ? html`<span class="text-3xs text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap">${matchedRows}/${totalRows}</span>`
                : null}
            </div>
          `
        : null}
      ${showEmptyState
        ? html`
            <div class="py-3 px-3 rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] text-2xs text-[var(--color-fg-muted)] italic">
              필터 결과 없음 (${totalRows} items)
            </div>
          `
        : null}
      ${filteredGroups.map(g => html`
        <div class="flex flex-col gap-1">
          <${SectionHeader} size="xs" class="px-1">${g.title}</${SectionHeader}>
          <div class="flex flex-col gap-1">
            ${g.rows.map(r => html`<${SignalRow} label=${r.label} value=${r.value} />`)}
          </div>
        </div>
      `)}
      ${topListSections.length > 0
        ? html`
            <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
              ${topListSections.map(section => html`
                <${DistributionBars}
                  title=${section.title}
                  subtitle=${section.subtitle}
                  items=${section.items}
                  valueFormatter=${(value: number) => `${value}`}
                  emptyLabel="집계가 아직 없습니다."
                />
              `)}
            </div>
          `
        : null}
    </div>
  `
}

function topListDistribution(
  rawItems: unknown,
  key: 'tool' | 'model' | 'kind',
  title: string,
): {
  title: string
  subtitle: string
  items: DistributionItem[]
} | null {
  if (!Array.isArray(rawItems)) return null
  const items: DistributionItem[] = []
  for (const item of rawItems) {
    if (typeof item !== 'object' || item === null) continue
    const label = typeof item[key] === 'string' ? item[key] : null
    const count = typeof item.count === 'number' && Number.isFinite(item.count) ? item.count : null
    if (!label || count == null || count <= 0) continue
    items.push({
      label,
      value: count,
      detail: key === 'tool'
        ? '최근 sliding window 호출 빈도'
        : key === 'model'
          ? '최근 sliding window 사용 빈도'
          : '최근 sliding window 작업 빈도',
      tone: key === 'model' ? 'warn' : key === 'kind' ? 'ok' : 'accent',
    })
    if (items.length >= 5) break
  }
  if (items.length === 0) return null
  return {
    title,
    subtitle: 'metrics_window Top-N 집계를 막대 형태로 표시합니다.',
    items,
  }
}

// ── Runtime Lens ─────────────────────────────────────────

function formatLensList(values: string[], emptyLabel = 'none'): string {
  if (values.length === 0) return emptyLabel
  if (values.length <= 3) return values.join(', ')
  return `${values.slice(0, 3).join(', ')} +${values.length - 3}`
}

function formatPayloadRole(axis: KeeperRuntimeLensPayloadRoleAxis): string {
  const entries = Object.entries(axis.counts)
  if (entries.length === 0) return 'none'
  return entries.map(([role, count]) => `${role}:${count}`).join(' · ')
}

function formatSourceClock(axis: KeeperRuntimeLensSourceClockAxis): string {
  const entries = Object.entries(axis.counts)
  if (entries.length === 0) return 'none'
  return entries.map(([clock, count]) => `${clock}:${count}`).join(' · ')
}

function runtimeTraceProviderTerminal(trace: KeeperRuntimeTraceResponse): string {
  const provider = trace.provider_attempts
  const status = compactToken(provider.terminal_status, 'unknown')
  return provider.terminal_exception_kind
    ? `${status} / ${provider.terminal_exception_kind}`
    : status
}

function runtimeTraceEventIds(trace: KeeperRuntimeTraceResponse): string {
  const eventBus = trace.event_bus
  return [
    `corr ${formatLensList(eventBus.correlation_ids)}`,
    `run ${formatLensList(eventBus.run_ids)}`,
  ].join(' · ')
}

function runtimeTraceMemoryEvidence(trace: KeeperRuntimeTraceResponse): string {
  const memory = trace.memory
  // inj present/injected is a true ratio pair: scan increments
  // memory_injected_count unconditionally and memory_injected_present_count
  // only when content is present, so present ≤ injected always holds.
  // (see server_dashboard_http_keeper_runtime_manifest_scan.ml:152-154)
  //
  // flush success/error are independent monotonic counters; rendering as
  // "N/M" would falsely imply a ratio. Use formatIndependentCounters.
  //
  // ep/proc episodes_flushed/procedures_flushed are also independent.
  return [
    `inj ${formatRatioPair({
      numerator: memory.memory_injected_present_count,
      denominator: memory.memory_injected_count,
    })}`,
    `flush ${formatIndependentCounters({
      leftLabel: 'success',
      leftValue: memory.memory_flush_success_count,
      rightLabel: 'error',
      rightValue: memory.memory_flush_error_count,
    })}`,
    `ep/proc ${formatIndependentCounters({
      leftLabel: 'ep',
      leftValue: memory.episodes_flushed,
      rightLabel: 'proc',
      rightValue: memory.procedures_flushed,
    })}`,
  ].join(' · ')
}

function artifactEvidenceLabel(artifacts: readonly { present: boolean }[]): string {
  if (artifacts.length === 0) return '0/0'
  const present = artifacts.filter(item => item.present).length
  return `${present}/${artifacts.length}`
}

function artifactEvidenceTitle(artifacts: readonly { kind: string; path: string; present: boolean }[]): string {
  if (artifacts.length === 0) return 'no linked artifacts'
  return artifacts
    .map(item => `${item.present ? 'present' : 'missing'} ${item.kind}: ${item.path || '-'}`)
    .join('\n')
}

function lensGapTone(severity: string): StatusChipTone {
  switch (severity) {
    case 'bad':
    case 'error':
      return 'bad'
    case 'warn':
    case 'warning':
      return 'warn'
    default:
      return 'neutral'
  }
}

function lensLaneTone(lane: KeeperRuntimeLensLane): StatusChipTone {
  if (lane.gap_codes.length > 0) return 'warn'
  if (lane.terminal_status === 'empty' || lane.event_count === 0) return 'neutral'
  if (lane.terminal_status.includes('error') || lane.terminal_status.includes('missing')) return 'bad'
  return 'ok'
}

function clockEdgeTitle(edge: KeeperRuntimeLensClockEdge): string {
  return [
    `edge ${edge.edge_id}`,
    `trace ${edge.trace_id || '-'}`,
    `keeper ${edge.keeper_turn_id ?? '-'}`,
    `oas ${edge.oas_turn_count ?? '-'}`,
    edge.provider_attempt_id ? `provider ${edge.provider_attempt_id}` : null,
    edge.tool_batch_id ? `tool ${edge.tool_batch_id}` : null,
    edge.checkpoint_id ? `checkpoint ${edge.checkpoint_id}` : null,
    edge.event_bus_correlation_id ? `corr ${edge.event_bus_correlation_id}` : null,
    edge.event_bus_run_id ? `run ${edge.event_bus_run_id}` : null,
    edge.event_bus_event_count !== null ? `event-bus events ${edge.event_bus_event_count}` : null,
    edge.event_bus_payload_kinds.length > 0 ? `payloads ${edge.event_bus_payload_kinds.join(', ')}` : null,
    edge.parent_event_id ? `parent ${edge.parent_event_id}` : null,
    edge.caused_by ? `caused by ${edge.caused_by}` : null,
    edge.started_at ? `started ${edge.started_at}` : null,
    edge.finished_at ? `finished ${edge.finished_at}` : null,
  ].filter(Boolean).join('\n')
}

function clockGroupTitle(group: KeeperRuntimeLensClockGroup): string {
  return [
    `${group.group_type} ${group.group_id}`,
    `${group.edge_count} edges`,
    group.lanes.length > 0 ? `lanes ${group.lanes.join(', ')}` : null,
    group.events.length > 0 ? `events ${group.events.join(', ')}` : null,
    group.statuses.length > 0 ? `statuses ${group.statuses.join(', ')}` : null,
    group.terminal_events.length > 0 ? `terminal ${group.terminal_events.join(', ')}` : null,
    group.parent_event_ids.length > 0 ? `parents ${group.parent_event_ids.join(', ')}` : null,
    group.caused_by.length > 0 ? `caused by ${group.caused_by.join(', ')}` : null,
    group.event_bus_event_count > 0 ? `event-bus events ${group.event_bus_event_count}` : null,
    group.event_bus_payload_kinds.length > 0 ? `payloads ${group.event_bus_payload_kinds.join(', ')}` : null,
    group.first_observed_at ? `first ${group.first_observed_at}` : null,
    group.last_observed_at ? `last ${group.last_observed_at}` : null,
  ].filter(Boolean).join('\n')
}

function RuntimeLensClockGroupRow({ group }: { group: KeeperRuntimeLensClockGroup }) {
  const detail =
    group.event_bus_payload_kinds.length > 0
      ? group.event_bus_payload_kinds.join(' · ')
      : group.events.join(' · ') || 'no events'
  return html`
    <div
      class="grid grid-cols-[minmax(7rem,0.9fr)_minmax(9rem,1.5fr)_auto] gap-2 items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 min-w-0"
      title=${clockGroupTitle(group)}
    >
      <div class="min-w-0">
        <div class="text-xs font-medium text-[var(--color-fg-secondary)] truncate">${group.group_type}</div>
        <div class="text-3xs text-[var(--color-fg-muted)] font-mono truncate">${group.edge_count} edges</div>
      </div>
      <div class="min-w-0">
        <div class="text-xs text-[var(--color-fg-secondary)] truncate">${group.group_id}</div>
        <div class="text-3xs text-[var(--color-fg-muted)] font-mono truncate">${detail}</div>
      </div>
      <span class="text-3xs font-mono text-[var(--color-fg-muted)] tabular-nums justify-self-end truncate max-w-32">
        ${group.closed ? 'closed' : 'open'}
      </span>
    </div>
  `
}

function RuntimeLensClockEdgeRow({ edge }: { edge: KeeperRuntimeLensClockEdge }) {
  return html`
    <div
      class="grid grid-cols-[minmax(7rem,0.9fr)_minmax(9rem,1.5fr)_auto] gap-2 items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 min-w-0"
      title=${clockEdgeTitle(edge)}
    >
      <div class="min-w-0">
        <div class="text-xs font-medium text-[var(--color-fg-secondary)] truncate">${edge.lane}</div>
        <div class="text-3xs text-[var(--color-fg-muted)] font-mono truncate">${edge.source_clock}</div>
      </div>
      <div class="min-w-0">
        <div class="text-xs text-[var(--color-fg-secondary)] truncate">${edge.event}</div>
        <div class="text-3xs text-[var(--color-fg-muted)] font-mono truncate">${edge.edge_id}</div>
      </div>
      <span class="text-3xs font-mono text-[var(--color-fg-muted)] tabular-nums justify-self-end truncate max-w-32">
        ${edge.event_bus_event_count !== null ? `${edge.event_bus_event_count} evt` : edge.status}
      </span>
    </div>
  `
}

function RuntimeLensLaneRow({ lane }: { lane: KeeperRuntimeLensLane }) {
  return html`
    <div class="grid grid-cols-[minmax(8rem,1fr)_auto] md:grid-cols-[minmax(9rem,1fr)_auto_auto] gap-2 items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 min-w-0">
      <div class="min-w-0">
        <div class="text-xs font-medium text-[var(--color-fg-secondary)] truncate">${lane.label}</div>
        <div class="text-3xs text-[var(--color-fg-muted)] font-mono truncate">
          ${lane.events.length > 0
            ? lane.events.map(event => `${event.event}:${event.count}`).join(' · ')
            : 'no events'}
        </div>
      </div>
      <span class="text-3xs font-mono text-[var(--color-fg-muted)] tabular-nums justify-self-end">
        ${lane.event_count}
      </span>
      <div class="col-span-2 md:col-span-1 flex flex-wrap gap-1 justify-start md:justify-end min-w-0">
        <${StatusChip} tone=${lensLaneTone(lane)} uppercase=${false}>${lane.terminal_status}<//>
        ${lane.gap_codes.map(code => html`
          <${StatusChip} tone="warn" uppercase=${false}>${code}<//>
        `)}
      </div>
    </div>
  `
}

export function RuntimeLensSection({
  trace,
}: {
  trace: KeeperRuntimeTraceResponse | null
}) {
  if (!trace) {
    return html`
      <div class="text-2xs text-[var(--color-fg-muted)] italic">
        runtime_trace_unavailable
      </div>
    `
  }

  const lens = trace.runtime_lens
  const lane = lens.axes.provider_lane
  const claim = lens.axes.claim_scope
  const drift = lens.axes.config_drift
  const context = lens.axes.context
  const memory = lens.axes.memory
  const clock = lens.turn_clock
  const artifacts = trace.linked_artifacts
  const clockEdges = lens.clock_edges
  const clockGroups = lens.clock_groups
  const swimlanes = [
    lens.swimlanes.keeper,
    lens.swimlanes.masc_policy_runtime,
    lens.swimlanes.oas_agent,
    lens.swimlanes.provider,
    lens.swimlanes.tool_runtime,
    lens.swimlanes.memory_context,
  ]

  return html`
    <div class="flex flex-col gap-3" data-testid="runtime-lens">
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-1.5">
        <${SignalRow} label="keeper / agent turn" value=${`${clock.keeper_turn_id ?? '-'} / ${clock.max_oas_turn_count ?? '-'}`} />
        <${SignalRow} label="terminal event" value=${clock.terminal_event_present ? clock.terminal_event ?? 'present' : 'missing'} />
        <${SignalRow} label="runtime lane" value=${lane.resolved_lane ?? lane.status ?? 'unknown'} />
        <${SignalRow} label="payload role" value=${formatPayloadRole(lens.axes.payload_role)} />
        <${SignalRow} label="source clock" value=${formatSourceClock(lens.axes.source_clock)} />
        <${SignalRow} label="claim scope" value=${claim.present ? `${claim.mode ?? 'unknown'} / ${claim.status}` : 'not observed'} />
        <${SignalRow} label="claim excluded" value=${claim.excluded_count === null ? '-' : String(claim.excluded_count)} />
        <${SignalRow} label="claim goals" value=${formatLensList(claim.effective_goal_ids)} />
        <${SignalRow} label="runtime drift" value=${drift.runtime_override ? `${drift.default_runtime_id ?? '-'} -> ${drift.live_runtime_id ?? '-'}` : drift.status} />
        <${SignalRow} label="override fields" value=${formatLensList(drift.override_fields)} />
        <${SignalRow} label="context compaction" value=${formatRatioPair({ numerator: context.context_compacted_count, denominator: context.context_compact_started_count })} />
        <${SignalRow} label="working loops" value=${context.active_open_loop_count} />
        <${SignalRow} label="memory flush" value=${formatIndependentCounters({ leftLabel: 'success', leftValue: memory.memory_flush_success_count, rightLabel: 'error', rightValue: memory.memory_flush_error_count })} />
        <${SignalRow} label="trace id" value=${compactToken(trace.trace_id)} />
        <${SignalRow}
          label="manifest file"
          value=${trace.manifest_path_present ? 'present' : 'missing'}
          title=${trace.manifest_path}
        />
        <${SignalRow} label="manifest rows" value=${formatRatioPair({ numerator: trace.manifest_returned_rows, denominator: trace.manifest_total_rows })} />
        <${SignalRow} label="receipt rows" value=${trace.receipt_returned_rows} />
        <${SignalRow} label="manifest raw rows" value=${trace.manifest_rows.length} />
        <${SignalRow} label="receipt raw rows" value=${trace.receipts.length} />
        <${SignalRow}
          label="receipt artifacts"
          value=${artifactEvidenceLabel(artifacts.receipts)}
          title=${artifactEvidenceTitle(artifacts.receipts)}
        />
        <${SignalRow}
          label="checkpoint artifacts"
          value=${artifactEvidenceLabel(artifacts.checkpoints)}
          title=${artifactEvidenceTitle(artifacts.checkpoints)}
        />
        <${SignalRow}
          label="tool log artifacts"
          value=${artifactEvidenceLabel(artifacts.tool_call_logs)}
          title=${artifactEvidenceTitle(artifacts.tool_call_logs)}
        />
        <${SignalRow} label="provider attempts" value=${`${trace.provider_attempts.started_count}/${trace.provider_attempts.finished_count}`} />
        <${SignalRow} label="provider terminal" value=${runtimeTraceProviderTerminal(trace)} />
        <${SignalRow} label="clock edges" value=${clockEdges.length} />
        <${SignalRow} label="clock groups" value=${clockGroups.length} />
        <${SignalRow} label="event ids" value=${runtimeTraceEventIds(trace)} />
        <${SignalRow} label="memory evidence" value=${runtimeTraceMemoryEvidence(trace)} />
        <${SignalRow} label="stale reason" value=${compactToken(trace.stale_reason, 'none')} />
      </div>

      <div class="flex flex-wrap gap-1.5 min-w-0" data-testid="runtime-lens-gaps">
        ${lens.gaps.length > 0
          ? lens.gaps.map(gap => html`
              <${StatusChip}
                tone=${lensGapTone(gap.severity)}
                uppercase=${false}
              >
                ${gap.code}
              <//>
            `)
          : html`<${StatusChip} tone="ok" uppercase=${false}>no lens gaps<//>`}
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-2">
        ${swimlanes.map(lane => html`<${RuntimeLensLaneRow} lane=${lane} />`)}
      </div>

      ${clockGroups.length > 0
        ? html`
            <div class="grid grid-cols-1 xl:grid-cols-2 gap-2" data-testid="runtime-lens-clock-groups">
              ${clockGroups.slice(0, 8).map(group => html`<${RuntimeLensClockGroupRow} group=${group} />`)}
            </div>
          `
        : null}

      ${clockEdges.length > 0
        ? html`
            <div class="grid grid-cols-1 xl:grid-cols-2 gap-2" data-testid="runtime-lens-clock-edges">
              ${clockEdges.slice(0, 8).map(edge => html`<${RuntimeLensClockEdgeRow} edge=${edge} />`)}
            </div>
          `
        : null}
    </div>
  `
}

// ── Neighborhood & Tool Audit ────────────────────────────

export function KeeperNeighborhood({ keeper }: { keeper: Keeper }) {
  useEffect(() => {
    void loadKeeperConfig(keeper.name)
  }, [keeper.name])

  const keeperConfig = peekLoadedKeeperConfig(keeper.name)
  const configLoadStatus = peekKeeperConfigLoadStatus(keeper.name)
  const namespaceStatus = operatorSnapshot.value?.root ?? {}
  const missionBrief = resolveKeeperMissionBrief(keeper)
  const toolPolicy = resolveKeeperToolPolicy(keeperConfig, configLoadStatus)
  const observedAudit = resolveKeeperObservedToolAudit(keeper, missionBrief)
  const allowedTools = toolPolicy.resolvedAllowlist
  const observedTools = observedAudit.latestToolNames
  const toolCallCount = observedAudit.latestToolCallCount
  const auditSource = observedAudit.toolAuditSource
  const auditAt = observedAudit.toolAuditAt
  const namespaceName =
    namespaceStatus.project ?? serverStatus.value?.project ?? 'default'
  const project = namespaceStatus.project ?? serverStatus.value?.project ?? 'N/A'
  const clusterRaw = namespaceStatus.cluster ?? serverStatus.value?.cluster ?? null
  const clusterVisible = clusterRaw && clusterRaw !== 'unknown' && clusterRaw !== 'default' && clusterRaw !== 'N/A'
  const allowlistFallback = toolAuditStateLabel(allowlistEmptyState(keeper))
  const observedFallback = toolAuditStateLabel(observedToolsEmptyState(keeper, auditSource))
  const metadataFallback = toolAuditStateLabel(auditMetadataState(keeper, auditSource))
  const runtimeState = linkedRuntimeState(keeper)
  const currentTaskLabel = resolveKeeperCurrentTaskLabel(keeper)
  const skillRouteLabel =
    keeper.skill_primary
    ?? (runtimeState === 'offline' ? 'offline' : 'not_collected')
  const policyLoading = toolPolicy.source === 'loading'
  const policyError = toolPolicy.source === 'error'
  const policyLoaded = toolPolicy.source === 'keeper_config'
  const unavailablePolicyLabel = policyError ? 'config_error' : 'config_unavailable'
  const allowedToolCountLabel =
    allowedTools.length > 0
      ? String(allowedTools.length)
      : policyLoading
        ? 'loading'
        : policyLoaded
          ? allowlistFallback
          : unavailablePolicyLabel
  const openToolsQuery = allowedTools[0] ?? observedTools[0] ?? null

  return html`
    <div class="flex flex-col gap-1.5">
      <${SignalRow} label="프로젝트 범위" value=${namespaceName} />
      <${SignalRow} label="프로젝트" value=${project} />
      ${clusterVisible ? html`<${SignalRow} label="클러스터" value=${clusterRaw} />` : null}
      <${SignalRow} label="현재 태스크" value=${currentTaskLabel} />
      <${SignalRow} label="스킬 경로" value=${skillRouteLabel} />
      <${SignalRow} label="컨텍스트 출처" value=${keeper.context_source ?? keeper.context?.source ?? '-'} />
      <${SignalRow} label="허용 도구 수" value=${allowedToolCountLabel} />

      <div class="flex justify-end mt-1">
        <${ActionButton}
          variant="ghost"
          size="md"
          class="!bg-[var(--color-bg-surface)] !text-[var(--color-fg-muted)] hover:!text-[var(--color-fg-primary)] hover:!bg-[var(--color-bg-hover)]"
          disabled=${!openToolsQuery}
          onClick=${() => { openToolsInventory(openToolsQuery) }}
        >
          도구 패널 열기
        <//>
      </div>

      <div class="flex items-center justify-between mt-3">
        <${SectionHeader} size="xs">허용된 도구</${SectionHeader}>
        <span class="text-3xs text-[var(--color-fg-muted)]">${policyLoading ? '로딩 중' : policyError ? '설정 오류' : 'read-only'}</span>
      </div>

      <span class="text-2xs text-[var(--color-fg-muted)] leading-snug">
        ${policyLoading
          ? '허용 도구 목록을 불러오는 중입니다.'
          : policyLoaded
            ? '이 키퍼가 현재 사용할 수 있는 도구 목록입니다.'
            : policyError
              ? '허용 도구 목록 로드에 실패했습니다.'
              : '허용 도구 목록을 아직 확인할 수 없습니다.'}
      </span>
      <${AllowlistPreview}
        tools=${allowedTools}
        emptyLabel=${policyLoading ? 'loading' : policyLoaded ? allowlistFallback : unavailablePolicyLabel}
      />

      <${ToolSection}
        title="관측된 도구"
        description="최근 실행에서 감지된 도구"
        tools=${observedTools}
        fallback=${observedFallback}
      />

      <${SignalRow} label="도구 호출" value=${typeof toolCallCount === 'number' ? toolCallCount : observedFallback === 'none_recent' ? 0 : metadataFallback} />
      <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
        <span class="text-xs text-[var(--color-fg-muted)]">감사</span>
        <span class="text-xs font-medium text-[var(--color-fg-secondary)]">${auditSource ?? metadataFallback}${auditAt ? html` · <${TimeAgo} timestamp=${auditAt} />` : ''}</span>
      </div>

    </div>
  `
}

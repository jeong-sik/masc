// Keeper runtime signals, neighborhood, and tool audit panels.
// Redesigned: consistent signal row styling with inline Tailwind,
// clean tool chip badges, proper section spacing.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { Save, Trash2 } from 'lucide-preact'
import { formatPct1 } from '../lib/format-number'
import {
  compactToken,
  deriveKeeperRuntimeProjection,
  type KeeperRuntimeProjectionRuntimeInput,
} from '../lib/keeper-runtime-projection'
import {
  deleteKeeperSecretFile,
  deleteKeeperSecretEnv,
  setKeeperSecretFile,
  setKeeperSecretEnv,
  type KeeperSecretEnvMutation,
  type KeeperSecretEnvSetMutation,
  type KeeperSecretFileMutation,
  type KeeperSecretFileSetMutation,
  type KeeperSecretScope,
} from '../api/dashboard-keeper-secrets'
import { ActionButton } from './common/button'
import { DistributionBars, type DistributionItem } from './common/distribution-bars'
import { TextArea, TextInput } from './common/input'
import { TimeAgo } from './common/time-ago'
import { SectionHeader } from './common/section-header'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { toolCategory } from './tool-call-shared'
import { formatIndependentCounters, formatRatioPair } from './counter-format'
import type { Keeper } from '../types'
import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'
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
  auditMetadataState,
  linkedRuntimeState,
  observedToolsEmptyState,
  openToolsInventory,
  toolAuditStateLabel,
} from './common/tool-audit'
import {
  resolveKeeperMissionBrief,
  resolveKeeperObservedToolAudit,
} from './keeper-detail-source'
import {
  findRuntimeCatalogEntry,
  loadRuntimeCatalog,
  runtimeCatalogState,
} from '../lib/runtime-catalog-resource'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
  runtimeCatalogSnapshotFacts,
} from '../lib/runtime-provider-summary'


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

type KeeperSecretPendingAction = 'set_env' | 'delete_env' | 'set_file' | 'delete_file'

interface KeeperSecretProjectionPanelProps {
  projection: KeeperSecretProjection | null | undefined
  keeperName?: string
  onProjectionChange?: (projection: KeeperSecretProjection) => void
  setSecretEnv?: typeof setKeeperSecretEnv
  deleteSecretEnv?: typeof deleteKeeperSecretEnv
  setSecretFile?: typeof setKeeperSecretFile
  deleteSecretFile?: typeof deleteKeeperSecretFile
}

function secretMutationErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === 'string') return error
  return 'secret mutation failed'
}

export function KeeperSecretProjectionPanel({
  projection,
  keeperName,
  onProjectionChange,
  setSecretEnv = setKeeperSecretEnv,
  deleteSecretEnv = deleteKeeperSecretEnv,
  setSecretFile = setKeeperSecretFile,
  deleteSecretFile = deleteKeeperSecretFile,
}: KeeperSecretProjectionPanelProps) {
  const [localProjection, setLocalProjection] = useState<KeeperSecretProjection | null>(projection ?? null)
  const [envScope, setEnvScope] = useState<KeeperSecretScope>('keeper')
  const [envName, setEnvName] = useState('')
  const [secretValue, setSecretValue] = useState('')
  const [fileScope, setFileScope] = useState<KeeperSecretScope>('keeper')
  const [filePath, setFilePath] = useState('/home/keeper/.ssh/id_ed25519')
  const [fileValue, setFileValue] = useState('')
  const [pending, setPending] = useState<KeeperSecretPendingAction | null>(null)
  const [mutationMessage, setMutationMessage] = useState<string | null>(null)
  const [mutationError, setMutationError] = useState<string | null>(null)

  useEffect(() => {
    setLocalProjection(projection ?? null)
  }, [projection])

  const visibleProjection = localProjection ?? projection
  const trimmedEnvName = envName.trim()
  const trimmedFilePath = filePath.trim()
  const canMutateEnv = Boolean(keeperName) && pending === null && trimmedEnvName.length > 0
  const canMutateFile = Boolean(keeperName) && pending === null && trimmedFilePath.length > 0

  function adoptProjection(next: KeeperSecretProjection) {
    setLocalProjection(next)
    onProjectionChange?.(next)
  }

  async function handleSetEnv(event: Event) {
    event.preventDefault()
    if (!keeperName || trimmedEnvName.length === 0 || pending !== null) return
    setPending('set_env')
    setMutationMessage(null)
    setMutationError(null)
    const mutation: KeeperSecretEnvSetMutation = {
      scope: envScope,
      name: trimmedEnvName,
      value: secretValue,
    }
    try {
      const next = await setSecretEnv(keeperName, mutation)
      adoptProjection(next)
      setSecretValue('')
      setMutationMessage(`${trimmedEnvName} saved to ${envScope}`)
    } catch (error) {
      setMutationError(secretMutationErrorMessage(error))
    } finally {
      setPending(null)
    }
  }

  async function handleDeleteEnv() {
    if (!keeperName || trimmedEnvName.length === 0 || pending !== null) return
    setPending('delete_env')
    setMutationMessage(null)
    setMutationError(null)
    const mutation: KeeperSecretEnvMutation = {
      scope: envScope,
      name: trimmedEnvName,
    }
    try {
      const next = await deleteSecretEnv(keeperName, mutation)
      adoptProjection(next)
      setSecretValue('')
      setMutationMessage(`${trimmedEnvName} deleted from ${envScope}`)
    } catch (error) {
      setMutationError(secretMutationErrorMessage(error))
    } finally {
      setPending(null)
    }
  }

  async function handleSetFile(event: Event) {
    event.preventDefault()
    if (!keeperName || trimmedFilePath.length === 0 || pending !== null) return
    setPending('set_file')
    setMutationMessage(null)
    setMutationError(null)
    const mutation: KeeperSecretFileSetMutation = {
      scope: fileScope,
      path: trimmedFilePath,
      value: fileValue,
    }
    try {
      const next = await setSecretFile(keeperName, mutation)
      adoptProjection(next)
      setFileValue('')
      setMutationMessage(`${trimmedFilePath} saved to ${fileScope}`)
    } catch (error) {
      setMutationError(secretMutationErrorMessage(error))
    } finally {
      setPending(null)
    }
  }

  async function handleDeleteFile() {
    if (!keeperName || trimmedFilePath.length === 0 || pending !== null) return
    setPending('delete_file')
    setMutationMessage(null)
    setMutationError(null)
    const mutation: KeeperSecretFileMutation = {
      scope: fileScope,
      path: trimmedFilePath,
    }
    try {
      const next = await deleteSecretFile(keeperName, mutation)
      adoptProjection(next)
      setFileValue('')
      setMutationMessage(`${trimmedFilePath} deleted from ${fileScope}`)
    } catch (error) {
      setMutationError(secretMutationErrorMessage(error))
    } finally {
      setPending(null)
    }
  }

  if (!visibleProjection) {
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

  const projectionView = visibleProjection
  const tone = secretProjectionTone(projectionView.status)
  const filePaths = projectionView.file_mounts.map(mount => mount.container_path)
  const envSummary = truncateSecretProjectionList(projectionView.env_names, 5)
  const fileSummary = truncateSecretProjectionList(filePaths, 4)
  const effectiveRoots = projectionView.effective_roots ?? []
  const rootRows = effectiveRoots.map((root, index) => ({
    ...root,
    label: secretRootScopeLabel(index, effectiveRoots.length),
  }))
  const scopeSummary = rootRows.length > 0 ? rootRows.map(row => row.label).join(' -> ') : 'keeper'
  const rootSummary = rootRows.length > 0
    ? truncateSecretProjectionList(rootRows.map(row => `${row.label}: ${row.status} · ${secretRootCounts(row)}`), 3)
    : projectionView.root
  const rootTitle = rootRows.length > 0
    ? rootRows.map(row => `${row.label}: ${row.root}`).join('\n')
    : projectionView.root
  const summary =
    projectionView.status === 'ready'
      ? `${projectionView.env_count} env · ${projectionView.file_count} files`
      : projectionView.status === 'error'
        ? projectionView.error ?? 'projection error'
        : projectionView.next_action

  return html`
    <div
      class="v2-monitoring-detail rounded-[var(--r-5)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-4"
      data-testid="keeper-secret-projection"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Secret projection</div>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <${StatusChip} tone=${tone} uppercase=${false}>${secretProjectionLabel(projectionView.status)}<//>
            <span class="text-sm font-medium text-[var(--color-fg-primary)]">${summary}</span>
          </div>
        </div>
        <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${projectionView.source}</span>
      </div>

      <div class="mt-3 grid grid-cols-1 gap-2 md:grid-cols-2">
        <${SignalRow} label="scope order" value=${scopeSummary} />
        <${SignalRow} label="effective roots" value=${rootSummary} title=${rootTitle} />
        <${SignalRow} label="keeper root" value=${projectionView.root} />
        <${SignalRow} label="env names" value=${envSummary} />
        <${SignalRow} label="file mounts" value=${fileSummary} />
        <${SignalRow} label="validation" value=${projectionView.values_validated ? 'values validated · values redacted' : 'structure only'} />
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

      <form
        class="mt-3 grid grid-cols-1 gap-2 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] p-3 lg:grid-cols-[140px_minmax(140px,0.7fr)_minmax(180px,1fr)_auto]"
        data-testid="keeper-secret-projection-form"
        onSubmit=${handleSetEnv}
      >
        <label class="flex flex-col gap-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          scope
          <select
            class="w-full rounded-[var(--r-1)] border border-[var(--input-border)] bg-[var(--input-bg)] px-3 py-2 text-sm font-medium normal-case tracking-normal text-[var(--input-fg)]"
            value=${envScope}
            disabled=${pending !== null || !keeperName}
            data-testid="keeper-secret-scope"
            onChange=${(event: Event) => setEnvScope((event.currentTarget as HTMLSelectElement).value as KeeperSecretScope)}
          >
            <option value="keeper">keeper</option>
            <option value="shared">shared</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          env
          <${TextInput}
            value=${envName}
            disabled=${pending !== null || !keeperName}
            ariaLabel="Secret env name"
            autoComplete="off"
            testId="keeper-secret-env-name"
            onInput=${(event: Event) => setEnvName((event.currentTarget as HTMLInputElement).value)}
          />
        </label>
        <label class="flex flex-col gap-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          value
          <${TextInput}
            type="password"
            value=${secretValue}
            disabled=${pending !== null || !keeperName}
            ariaLabel="Secret env value"
            autoComplete="new-password"
            testId="keeper-secret-value"
            onInput=${(event: Event) => setSecretValue((event.currentTarget as HTMLInputElement).value)}
          />
        </label>
        <div class="flex flex-wrap items-end gap-2">
          <${ActionButton}
            type="submit"
            size="sm"
            disabled=${!canMutateEnv}
            ariaBusy=${pending === 'set_env'}
            testId="keeper-secret-save"
            class="inline-flex items-center gap-1.5"
          >
            <${Save} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>${pending === 'set_env' ? 'Saving' : 'Save'}</span>
          <//>
          <${ActionButton}
            type="button"
            variant="danger"
            size="sm"
            disabled=${!canMutateEnv}
            ariaBusy=${pending === 'delete_env'}
            testId="keeper-secret-delete"
            class="inline-flex items-center gap-1.5"
            onClick=${handleDeleteEnv}
          >
            <${Trash2} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>${pending === 'delete_env' ? 'Deleting' : 'Delete'}</span>
          <//>
        </div>
      </form>

      <form
        class="mt-3 grid grid-cols-1 gap-2 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] p-3 lg:grid-cols-[140px_minmax(180px,1fr)_minmax(220px,1.2fr)_auto]"
        data-testid="keeper-secret-file-form"
        onSubmit=${handleSetFile}
      >
        <label class="flex flex-col gap-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          scope
          <select
            class="w-full rounded-[var(--r-1)] border border-[var(--input-border)] bg-[var(--input-bg)] px-3 py-2 text-sm font-medium normal-case tracking-normal text-[var(--input-fg)]"
            value=${fileScope}
            disabled=${pending !== null || !keeperName}
            data-testid="keeper-secret-file-scope"
            onChange=${(event: Event) => setFileScope((event.currentTarget as HTMLSelectElement).value as KeeperSecretScope)}
          >
            <option value="keeper">keeper</option>
            <option value="shared">shared</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          file path
          <${TextInput}
            value=${filePath}
            disabled=${pending !== null || !keeperName}
            ariaLabel="Secret file path"
            autoComplete="off"
            testId="keeper-secret-file-path"
            onInput=${(event: Event) => setFilePath((event.currentTarget as HTMLInputElement).value)}
          />
        </label>
        <label class="flex flex-col gap-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          content
          <${TextArea}
            value=${fileValue}
            rows=${3}
            disabled=${pending !== null || !keeperName}
            ariaLabel="Secret file value"
            onInput=${(event: Event) => setFileValue((event.currentTarget as HTMLTextAreaElement).value)}
          />
        </label>
        <div class="flex flex-wrap items-end gap-2">
          <${ActionButton}
            type="submit"
            size="sm"
            disabled=${!canMutateFile}
            ariaBusy=${pending === 'set_file'}
            testId="keeper-secret-file-save"
            class="inline-flex items-center gap-1.5"
          >
            <${Save} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>${pending === 'set_file' ? 'Saving' : 'Save'}</span>
          <//>
          <${ActionButton}
            type="button"
            variant="danger"
            size="sm"
            disabled=${!canMutateFile}
            ariaBusy=${pending === 'delete_file'}
            testId="keeper-secret-file-delete"
            class="inline-flex items-center gap-1.5"
            onClick=${handleDeleteFile}
          >
            <${Trash2} size=${13} strokeWidth=${2.25} aria-hidden="true" />
            <span>${pending === 'delete_file' ? 'Deleting' : 'Delete'}</span>
          <//>
        </div>
      </form>

      ${mutationMessage
        ? html`
            <div class="mt-3 rounded-[var(--r-1)] border border-[var(--ok-20)] bg-[var(--ok-10)] px-3 py-2 text-xs text-[var(--ok-light)]">
              ${mutationMessage}
            </div>
          `
        : null}

      ${mutationError
        ? html`
            <div class="mt-3 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-xs text-[var(--bad-light)]">
              ${mutationError}
            </div>
          `
        : null}

      ${projectionView.error
        ? html`
            <div class="mt-3 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-xs text-[var(--bad-light)]">
              ${projectionView.error}
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
      title: '자율 행동 & 반응',
      rows: [
        { label: '멘션 반응', value: fmtCount(keeper.mention_reactive_turn_count) },
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

function runtimeManifestDiagnosticsValue(trace: KeeperRuntimeTraceResponse): string {
  const diagnostics = trace.manifest_scan_diagnostics
  if (diagnostics.state === 'unavailable') return 'unavailable'
  const invalid = diagnostics.invalid_manifest_row_count + diagnostics.invalid_json_row_count
  if (
    diagnostics.retired_event_count === 0
    && diagnostics.unsupported_event_count === 0
    && invalid === 0
  ) return 'clean'
  return [
    `retired ${diagnostics.retired_event_count}`,
    `unsupported ${diagnostics.unsupported_event_count}`,
    `invalid ${invalid}`,
  ].join(' · ')
}

function runtimeManifestDiagnosticsTitle(trace: KeeperRuntimeTraceResponse): string {
  const diagnostics = trace.manifest_scan_diagnostics
  if (diagnostics.state === 'unavailable') {
    return [diagnostics.error, diagnostics.schema].filter(Boolean).join('\n')
  }
  const eventCounts = [
    ...diagnostics.retired_event_counts.map(item => `retired:${item.event}=${item.count}`),
    ...diagnostics.unsupported_event_counts.map(item => `unsupported:${item.event}=${item.count}`),
  ]
  const sampleDetails = diagnostics.samples.map(sample =>
    [sample.kind, sample.event, sample.detail].filter(Boolean).join(':'))
  const overflow = diagnostics.unsupported_event_unattributed_count === 0
    ? []
    : [`unsupported rows outside identity detail bound=${diagnostics.unsupported_event_unattributed_count}`]
  return [...eventCounts, ...overflow, ...sampleDetails].join('\n') || 'no manifest scan diagnostics'
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

function runtimeLensCatalogId(trace: KeeperRuntimeTraceResponse): string | null {
  const drift = trace.runtime_lens.axes.config_drift
  const live = drift.live_runtime_id?.trim()
  if (live) return live
  const defaultRuntime = drift.default_runtime_id?.trim()
  return defaultRuntime || null
}

function RuntimeLensCatalogDetailRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] px-3 py-2">
      <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${label}</div>
      <div class="break-words font-mono text-3xs leading-relaxed text-[var(--color-fg-secondary)]" title=${value}>${value}</div>
    </div>
  `
}

function RuntimeLensCatalogSummary({
  runtimeId,
  entry,
  status,
  errorMessage,
}: {
  runtimeId: string | null
  entry: DashboardRuntimeProviderSnapshot | null
  status: 'idle' | 'loading' | 'loaded' | 'error'
  errorMessage?: string
}) {
  if (!runtimeId) {
    return html`
      <div
        class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs text-[var(--color-fg-muted)]"
        data-testid="runtime-lens-catalog-spec"
      >
        runtime catalog: no runtime id observed in config drift axis
      </div>
    `
  }

  if (status === 'idle' || status === 'loading') {
    return html`
      <div
        class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs text-[var(--color-fg-muted)]"
        data-testid="runtime-lens-catalog-spec"
      >
        runtime catalog loading: ${runtimeId}
      </div>
    `
  }

  if (status === 'error') {
    return html`
      <div
        class="rounded-[var(--r-1)] border border-[var(--color-status-bad)]/40 bg-[var(--color-bg-surface)] px-3 py-2 text-2xs text-[var(--color-status-bad)]"
        data-testid="runtime-lens-catalog-spec"
      >
        runtime catalog error for ${runtimeId}: ${errorMessage ?? 'unknown error'}
      </div>
    `
  }

  if (!entry) {
    return html`
      <div
        class="rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--color-bg-surface)] px-3 py-2 text-2xs text-[var(--color-status-warn)]"
        data-testid="runtime-lens-catalog-spec"
      >
        runtime catalog missing exact entry: ${runtimeId}
      </div>
    `
  }

  const provider = entry.provider_display_name ?? entry.provider_id ?? entry.provider
  const model = entry.model_api_name ?? entry.model_id ?? 'model unknown'
  const snapshotFacts = runtimeCatalogSnapshotFacts(entry)
  const effectiveCapabilities = runtimeCatalogEffectiveCapabilities(entry)
  const declaredSpec = runtimeCatalogDeclaredSpec(entry)
  const parameterPolicy = runtimeCatalogParameterPolicy(entry)
  const requestConfig = runtimeCatalogRequestConfig(entry)

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-testid="runtime-lens-catalog-spec"
    >
      <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
        <div class="min-w-0">
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">runtime catalog spec</div>
          <div class="truncate font-mono text-3xs text-[var(--color-fg-muted)]" title=${runtimeId}>${runtimeId}</div>
        </div>
        <div class="min-w-0 text-right">
          <div class="truncate text-xs font-medium text-[var(--color-fg-secondary)]" title=${provider}>${provider}</div>
          <div class="truncate font-mono text-3xs text-[var(--color-fg-muted)]" title=${model}>${model}</div>
        </div>
      </div>
      <div class="grid gap-1.5">
        ${snapshotFacts ? html`<${RuntimeLensCatalogDetailRow} label="snapshot" value=${snapshotFacts} />` : null}
        ${effectiveCapabilities ? html`<${RuntimeLensCatalogDetailRow} label="effective" value=${effectiveCapabilities} />` : null}
        ${declaredSpec ? html`<${RuntimeLensCatalogDetailRow} label="declared" value=${declaredSpec} />` : null}
        ${parameterPolicy ? html`<${RuntimeLensCatalogDetailRow} label="policy" value=${parameterPolicy} />` : null}
        ${requestConfig ? html`<${RuntimeLensCatalogDetailRow} label="request" value=${requestConfig} />` : null}
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
  const runtimeId = runtimeLensCatalogId(trace)
  if (runtimeId) loadRuntimeCatalog()
  const catalogState = runtimeCatalogState.value
  const runtimeCatalogEntry = catalogState.status === 'loaded'
    ? findRuntimeCatalogEntry(catalogState.data, runtimeId ?? '')
    : null
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
        <${SignalRow} label="context compaction events" value=${String(context.context_compacted_event_count)} />
        <${SignalRow} label="memory flush" value=${formatIndependentCounters({ leftLabel: 'success', leftValue: memory.memory_flush_success_count, rightLabel: 'error', rightValue: memory.memory_flush_error_count })} />
        <${SignalRow} label="trace id" value=${compactToken(trace.trace_id)} />
        <${SignalRow}
          label="manifest file"
          value=${trace.manifest_path_present ? 'present' : 'missing'}
          title=${trace.manifest_path}
        />
        <${SignalRow} label="manifest rows" value=${formatRatioPair({ numerator: trace.manifest_returned_rows, denominator: trace.manifest_total_rows })} />
        <${SignalRow}
          label="manifest diagnostics"
          value=${runtimeManifestDiagnosticsValue(trace)}
          title=${runtimeManifestDiagnosticsTitle(trace)}
        />
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

      <${RuntimeLensCatalogSummary}
        runtimeId=${runtimeId}
        entry=${runtimeCatalogEntry}
        status=${catalogState.status}
        errorMessage=${catalogState.status === 'error' ? catalogState.message : undefined}
      />

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
  const namespaceStatus = operatorSnapshot.value?.root ?? {}
  const missionBrief = resolveKeeperMissionBrief(keeper)
  const observedAudit = resolveKeeperObservedToolAudit(keeper, missionBrief)
  const observedTools = observedAudit.latestToolNames
  const toolCallCount = observedAudit.latestToolCallCount
  const auditSource = observedAudit.toolAuditSource
  const auditAt = observedAudit.toolAuditAt
  const namespaceName =
    namespaceStatus.project ?? serverStatus.value?.project ?? 'default'
  const project = namespaceStatus.project ?? serverStatus.value?.project ?? 'N/A'
  const clusterRaw = namespaceStatus.cluster ?? serverStatus.value?.cluster ?? null
  const clusterVisible = clusterRaw && clusterRaw !== 'unknown' && clusterRaw !== 'default' && clusterRaw !== 'N/A'
  const observedFallback = toolAuditStateLabel(observedToolsEmptyState(keeper, auditSource))
  const metadataFallback = toolAuditStateLabel(auditMetadataState(keeper, auditSource))
  const currentTaskLabel = resolveKeeperCurrentTaskLabel(keeper)
  const openToolsQuery = observedTools[0] ?? null

  return html`
    <div class="flex flex-col gap-1.5">
      <${SignalRow} label="프로젝트 범위" value=${namespaceName} />
      <${SignalRow} label="프로젝트" value=${project} />
      ${clusterVisible ? html`<${SignalRow} label="클러스터" value=${clusterRaw} />` : null}
      <${SignalRow} label="현재 태스크" value=${currentTaskLabel} />
      <${SignalRow} label="컨텍스트 출처" value=${keeper.context_source ?? keeper.context?.source ?? '-'} />
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

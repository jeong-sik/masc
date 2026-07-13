import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useMemo } from 'preact/hooks'
import type { GroundedVerdict, RouteState, TabId } from '../types'
import type { DashboardCdalHealth, DashboardFleetSafetyHealth, DashboardKeeperReactionLedgerHealth, DashboardRuntimeResolution, Keeper } from '../types'
import {
  fetchDashboardRuntimeProbe,
  type DashboardRuntimeProbePayload,
} from '../api/dashboard-tools-prompts'
import { hashForRoute, navigate, route } from '../router'
import { connected, reconnectCount, lastDisconnectedAt } from '../sse'
import { dashboardWsOnlyEnabled } from '../dashboard-ws-cutover'
import { dashboardWsConnected, dashboardWsLastError, dashboardWsReady, dashboardWsSseFallbackActive } from '../dashboard-ws-state'
import { isKeeperPaused } from '../lib/keeper-predicates'
import { dashboardLoading, executionError, keepers, serverStatus, shellCounts, shellRuntimeResolution, tasksByStatus } from '../store'
import { missionSnapshot, missionLoading } from '../mission-signals'
import { namespaceTruth, namespaceTruthInitializing } from '../namespace-truth-store'
import {
  configuredCountSourceLabel,
  formatKeeperCountBreakdown,
  keeperRowLooksRunning,
  resolveRuntimeCounts,
  runtimeCountSourceLabel,
} from '../runtime-counts'
import { ErrorBoundary } from './common/error-boundary'
import { TimeAgo } from './common/time-ago'
import { LoadingState } from './common/feedback-state'
import {
  DASHBOARD_SURFACES,
  DASHBOARD_NAV_ITEMS,
  PRIMARY_DASHBOARD_SURFACES,
  currentSectionForRoute,
  visibleSectionItemsForTab,
} from '../config/navigation'
import { ObservatoryFilterBar } from './common/observatory-filter-bar'
import { ChevronRight, ChevronLeft } from 'lucide-preact'
import { ExternalLink } from 'lucide-preact'
import { ScrollToTopButton } from './common/scroll-to-top'
import { CopyIdButton } from './common/copy-id-button'
import { formatElapsedCompact } from '../lib/format-time'
import { unacknowledgedCount } from './common/error-notification-state'
import { ErrorPanel } from './common/error-panel'
import { Bell } from 'lucide-preact'
import { ringFocusClasses } from './common/ring'
import { SurfaceIcon } from './surface-icon'
import { gateData } from './gate-signals'
import { Breadcrumb, type BreadcrumbItem } from './common/breadcrumb'
import { RouteLink } from './common/route-link'
import {
  isWidgetSoloRoute,
  WidgetSoloBar,
  widgetSoloUrlForRoute,
} from './widget-solo'

const buildIdentityOpen = signal(false)
const shellRuntimeProviderProbe = signal<DashboardRuntimeProbePayload | null>(null)
const shellRuntimeProviderProbeError = signal<string | null>(null)

function BuildInfoRow({ label, children }: { label: string; children: unknown }) {
  return html`
    <div class="v2-shell-row flex justify-between gap-3 text-xs text-[color:var(--color-fg-muted)]">
      <span>${label}</span>
      ${children}
    </div>
  `
}

const LazyOverview = lazy(async () => ({ default: (await import('./overview/overview')).Overview }))
const LazyStatus = lazy(async () => ({ default: (await import('./status')).Status }))
const LazyKeeperDetailPage = lazy(async () => ({ default: (await import('./keeper-detail-page')).KeeperDetailPage }))
const LazyBoardSurface = lazy(async () => ({ default: (await import('./board/board-surface')).BoardSurface }))
const LazyScheduleSurface = lazy(async () => ({ default: (await import('./schedule/schedule-surface')).ScheduleSurface }))
const LazyWork = lazy(async () => ({ default: (await import('./work')).Work }))
const LazyOperations = lazy(async () => ({ default: (await import('./operations-panel')).OperationsPanel }))
const LazyConnectors = lazy(async () => ({ default: (await import('./connector-status')).ConnectorStatusPanel }))
const LazyLabSurface = lazy(async () => ({ default: (await import('./lab')).Lab }))
const LazyLogViewer = lazy(async () => ({ default: (await import('./logs')).LogViewer }))
const LazyIdeShell = lazy(async () => ({ default: (await import('./ide/ide-shell')).IdeShell }))
const LazyCockpit = lazy(async () => ({ default: (await import('./cockpit/cockpit')).Cockpit }))
const LazySettingsSurface = lazy(async () => ({ default: (await import('./settings-surface')).SettingsSurface }))
const LazyApprovals = lazy(async () => ({ default: (await import('./approvals/approvals-surface')).ApprovalsSurface }))
const LazyFusionSurface = lazy(async () => ({ default: (await import('./fusion/fusion-surface')).FusionSurface }))

function lazyTabFallback(label: string) {
  return html`<${LoadingState}>Loading ${label}...<//>`
}

/** Pure: describe a "reconnecting" state as a user-facing label plus
    tooltip. Reference UIs: Discord shows "Reconnecting... (5s · try 3)";
    Slack shows "Trying to reconnect..." with timestamp on hover;
    Linear flashes a subtle red dot + tooltip. Goal here: operator can
    tell at a glance whether a flicker (sub-5s) is worth noticing and,
    on hover, see when the last successful session ended + cumulative
    reconnect count — so a reconnect loop is diagnosable without
    opening devtools.

    Inputs are all primitives so the helper is trivially testable. */
function describeReconnecting(args: {
  disconnectedAt: number
  now: number
  reconnects: number
}): { label: string; title: string } {
  const { disconnectedAt, now, reconnects } = args
  if (disconnectedAt === 0) {
    return { label: 'Reconnecting...', title: '' }
  }
  const sec = Math.max(0, Math.round((now - disconnectedAt) / 1000))
  const elapsed = sec < 5
    ? ''
    : sec < 60
      ? ` · ${sec}s`
      : ` · ${Math.round(sec / 60)}m`
  const label = `Reconnecting${elapsed}`
  const titleParts: string[] = []
  if (sec >= 5) {
    const d = new Date(disconnectedAt)
    const pad = (n: number) => String(n).padStart(2, '0')
    const when = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    titleParts.push(`Disconnected at ${when}`)
  }
  if (reconnects > 0) {
    titleParts.push(`Reconnect attempts ${reconnects}`)
  }
  return { label, title: titleParts.join(' · ') }
}

export function ConnectionStatus() {
  const wsOnly = dashboardWsOnlyEnabled()
  const reconn = reconnectCount.value
  const reconnecting = describeReconnecting({
    disconnectedAt: lastDisconnectedAt.value,
    now: Date.now(),
    reconnects: reconn,
  })
  const status = (() => {
    if (wsOnly) {
      if (dashboardWsReady.value) {
        return {
          tone: 'ok' as const,
          label: reconn > 0 ? 'Reconnected' : 'Connected',
          title: reconn > 0 ? `Reconnect attempts ${reconn}` : '',
        }
      }
      if (dashboardWsSseFallbackActive.value) {
        return {
          tone: 'warn' as const,
          label: 'SSE fallback',
          title: dashboardWsLastError.value
            ? `Client WS degraded: ${dashboardWsLastError.value}`
            : 'Client WS degraded; SSE fallback is carrying events.',
        }
      }
      if (dashboardWsConnected.value) {
        return {
          tone: 'warn' as const,
          label: 'Connecting WS',
          title: 'Client WS socket is open; waiting for dashboard/hello.',
        }
      }
    } else if (connected.value) {
      return {
        tone: 'ok' as const,
        label: reconn > 0 ? 'Reconnected' : 'Connected',
        title: reconn > 0 ? `Reconnect attempts ${reconn}` : '',
      }
    }
    return {
      tone: 'err' as const,
      label: reconnecting.label,
      title: reconnecting.title,
    }
  })()
  const isConnected = status.tone === 'ok'
  const textClass = status.tone === 'warn'
    ? 'text-[var(--color-status-warn)]'
    : isConnected
      ? 'text-[var(--color-status-ok)]'
      : 'text-[var(--color-status-err)]'
  const dotClass = status.tone === 'warn'
    ? 'bg-[var(--color-status-warn)]'
    : isConnected
      ? 'bg-[var(--color-status-ok)] shadow-[0_0_7px_rgb(var(--ok-glow)/0.75)]'
      : 'bg-[var(--color-status-err)]'

  return html`
    <div
      class="v2-shell-panel flex items-center gap-1.5 whitespace-nowrap text-xs ${textClass}"
      title=${status.title || undefined}
    >
      <span class="inline-block size-[8px] rounded-[var(--r-0)] ${dotClass}"></span>
      <span class="status-text">${status.label}</span>
    </div>
  `
}
// The attention count moved out of ConnectionStatus into the categorized
// top-bar AttentionIndicator (components/attention-indicator.ts).

type DashboardHealthChipTone = 'ok' | 'warn' | 'bad' | 'muted'

interface DashboardHealthChipRoute {
  tab: TabId
  params: Record<string, string>
}

interface DashboardHealthChip {
  key: string
  label: string
  detail: string
  tone: DashboardHealthChipTone
  // Optional drill-down route. When set, DashboardHealthStrip renders this
  // chip as a RouteLink so operators can jump from "Source mismatch" /
  // "일시정지 keeper N" / "Reaction ledger pending N" straight to the page
  // that explains the signal. Chips without a route render as static spans
  // (e.g. transport-offline — no view helps).
  route?: DashboardHealthChipRoute
}

interface DashboardHealthInput {
  connected: boolean
  counts: {
    agents?: number
    tasks?: number
    keepers: number
    total_runtimes?: number
    configured_keepers: number
  } | null
  namespaceTruthCounts?: {
    agents?: number
    tasks?: number
    keepers?: number
    total_runtimes?: number
  }
  namespaceTruthConfiguredKeepers?: number
  keepers: Keeper[]
  runtimeResolution: DashboardRuntimeResolution | null
  runtimeGeneratedAt?: string | null
  runtimeProviderProbe?: DashboardRuntimeProbePayload | null
  runtimeProviderProbeError?: string | null
  executionError: string | null
  loading: boolean
  pendingVerificationCount?: number
}

// RFC-0135 PR-3: the local `keeperLooksPaused` was one of four
// parallel paused-predicate chains. Canonical implementation now in
// `../lib/keeper-predicates.ts` covers exactly the same four axes
// (paused / phase / pipeline_stage / status).
//
// Note: the canonical predicate compares `phase === 'Paused'` (PascalCase
// per `KeeperPhase`) instead of the previous lowercased comparison —
// this matches the wire type and the three other former chains.

function fleetSafetyHealthChip(fleetSafety: DashboardFleetSafetyHealth | null): DashboardHealthChip | null {
  if (!fleetSafety) return null
  const fibers = fleetSafety.keeper_fibers
  const paused = fleetSafety.paused_keepers ?? 0
  const fleet = fleetSafety.keeper_fleet_safety
  const fleetStatus = fleet?.status
  const runningFibers = fleet?.running_keeper_fiber_count ?? fibers
  const healthyRunningFibers = fleet?.healthy_running_keeper_fiber_count ?? runningFibers
  const failingFibers = fleet?.failing_keeper_fiber_count ?? null
  const executableFibers = fleet?.executable_keeper_fiber_count
    ?? fleet?.executable_reaction_capacity_count
    ?? runningFibers
  const pausedKeepers = fleet?.paused_keeper_count ?? paused
  const pausedAutobootKeepers = fleet?.paused_autoboot_enabled_keeper_count ?? null
  const targetCapacity = fleet?.target_reaction_capacity_count ?? fleet?.autoboot_enabled_keeper_count ?? null
  const bootableKeepers = fleet?.bootable_keeper_count ?? null
  const minimumRunning = fleet?.minimum_running_fibers ?? null
  const noFibers = fleet?.no_running_fibers ?? fleetSafety.keeper_fleet_no_fibers
  const requiresAction = fleet?.operator_action_required === true
  const capacityBelowTarget = fleet?.reaction_capacity_below_target === true
  const capacityShortfall = fleet?.reaction_capacity_shortfall_count ?? (
    targetCapacity != null && runningFibers != null ? Math.max(0, targetCapacity - runningFibers) : null
  )
  const pausedOnlyNoExecutable =
    executableFibers === 0
    && pausedAutobootKeepers != null
    && pausedAutobootKeepers > 0
    && targetCapacity != null
    && pausedAutobootKeepers >= targetCapacity
  if (pausedOnlyNoExecutable) {
    const capacityDetail = [
      `status=${fleetStatus ?? 'paused'}`,
      `running_keeper_fiber_count=${runningFibers ?? 0}`,
      `executable_keeper_fiber_count=${executableFibers}`,
      `paused_keeper_count=${pausedKeepers}`,
      `paused_autoboot_enabled_keeper_count=${pausedAutobootKeepers}`,
      targetCapacity != null ? `target_reaction_capacity_count=${targetCapacity}` : null,
      minimumRunning != null ? `minimum_running_fibers=${minimumRunning}` : null,
    ].filter((item): item is string => item != null).join(', ')
    return {
      key: 'fleet-liveness-risk',
      label: 'Fleet paused',
      detail: `${capacityDetail}; paused is lifecycle state. Inspect row-level runtime blocker evidence before treating it as a blocker.`,
      tone: 'warn',
    }
  }
  if (fleetStatus === 'blocked' || (requiresAction && (runningFibers === 0 || noFibers === true))) {
    const capacityDetail = [
      `status=${fleetStatus ?? 'blocked'}`,
      `running_keeper_fiber_count=${runningFibers ?? 0}`,
      executableFibers != null ? `executable_keeper_fiber_count=${executableFibers}` : null,
      `paused_keeper_count=${pausedKeepers}`,
      pausedAutobootKeepers != null ? `paused_autoboot_enabled_keeper_count=${pausedAutobootKeepers}` : null,
      bootableKeepers != null ? `bootable_keeper_count=${bootableKeepers}` : null,
      targetCapacity != null ? `target_reaction_capacity_count=${targetCapacity}` : null,
      minimumRunning != null ? `minimum_running_fibers=${minimumRunning}` : null,
    ].filter((item): item is string => item != null).join(', ')
    return {
      key: 'fleet-liveness-risk',
      label: 'P0 fleet blocked',
      detail: `${capacityDetail}; resume selected paused keepers or confirm an intentional operator pause policy.`,
      tone: 'bad',
    }
  }
  if (fleetStatus === 'degraded' || (requiresAction && capacityBelowTarget)) {
    const capacityDetail = [
      `status=${fleetStatus ?? 'degraded'}`,
      `healthy_running_keeper_fiber_count=${healthyRunningFibers ?? 0}`,
      executableFibers != null ? `executable_keeper_fiber_count=${executableFibers}` : null,
      failingFibers != null ? `failing_keeper_fiber_count=${failingFibers}` : null,
      targetCapacity != null ? `target_reaction_capacity_count=${targetCapacity}` : null,
      capacityShortfall != null ? `reaction_capacity_shortfall_count=${capacityShortfall}` : null,
      fleet?.blocker ? `blocker=${fleet.blocker}` : null,
    ].filter((item): item is string => item != null).join(', ')
    return {
      key: 'fleet-liveness-risk',
      label: 'Fleet capacity degraded',
      detail: `${capacityDetail}; restore missing keeper fibers or confirm a reduced target capacity.`,
      tone: 'warn',
    }
  }
  if (fleetSafety.keeper_fleet_no_fibers === true || (fibers != null && fibers <= 1 && paused > 0)) {
    return {
      key: 'fleet-liveness-risk',
      label: 'Fleet liveness risk',
      detail: `keeper_fibers=${fibers ?? 0}, paused_keepers=${paused}; keeper fleet may be stalled.`,
      tone: 'bad',
    }
  }
  return null
}

function ledgerCount(value: number | null | undefined): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function reactionLedgerHealthChip(
  ledger: DashboardKeeperReactionLedgerHealth | null | undefined,
): DashboardHealthChip | null {
  if (!ledger) return null
  const pending = ledgerCount(ledger.pending_stimulus_count)
  const cursorSwept = ledgerCount(ledger.cursor_swept_stimulus_count)
  const legacySwept = ledgerCount(ledger.legacy_cursor_swept_stimulus_count)
  const readErrors = ledgerCount(ledger.read_error_count)
  const cursorAck = ledgerCount(ledger.cursor_ack_count)
  const status = ledger.status ?? 'unknown'
  const requiresAction = ledger.operator_action_required === true
  const totalSwept = cursorSwept + legacySwept
  if (!requiresAction && pending === 0 && readErrors === 0 && totalSwept === 0 && status !== 'degraded') {
    return null
  }
  const tone: DashboardHealthChipTone = readErrors > 0
    ? 'bad'
    : requiresAction || pending > 0 || status === 'degraded'
      ? 'warn'
      : 'ok'
  const label = pending > 0
    ? `Reaction ledger pending ${pending}`
    : totalSwept > 0
      ? `Reaction ledger swept ${totalSwept}`
      : `Reaction ledger ${status}`
  return {
    key: 'reaction-ledger',
    label,
    detail: [
      `status=${status}`,
      `pending=${pending}`,
      `cursor_swept=${cursorSwept}`,
      `legacy_swept=${legacySwept}`,
      `cursor_ack=${cursorAck}`,
      `read_errors=${readErrors}`,
    ].join(', '),
    tone,
    route: {
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'keeper-health' },
    },
  }
}

function contractHealthChip(cdal: DashboardCdalHealth | null | undefined): DashboardHealthChip | null {
  if (!cdal) return null
  const writerStatus = cdal.writer_status ?? 'unknown'
  const proofStatus = cdal.proof_store?.status ?? 'unknown'
  const taskStatus = cdal.task_scope?.status ?? 'unknown'
  const incomplete = cdal.proof_store?.completeness?.incomplete_run_dirs ?? 0
  const stale = cdal.proof_store?.completeness?.stale_incomplete_run_dirs ?? 0
  const terminal = cdal.proof_store?.completeness?.terminal_incomplete_run_dirs ?? 0
  const currentMissing = cdal.task_scope?.current_writer_missing_task_scope_rows ?? 0
  const requiresAction = cdal.operator_action_required === true
  if (!requiresAction && writerStatus === 'active' && incomplete === 0 && currentMissing === 0) {
    return null
  }
  const tone: DashboardHealthChipTone =
    requiresAction || stale > 0 || currentMissing > 0 ? 'bad' : terminal > 0 || incomplete > 0 ? 'warn' : 'ok'
  const label = stale > 0 || terminal > 0 || incomplete > 0
    ? `Contract proof incomplete ${incomplete}`
    : currentMissing > 0
      ? `Contract task scope ${currentMissing}`
      : `Contract verification ${writerStatus}`
  return {
    key: 'cdal-runtime-health',
    label,
    detail: [
      `writer_status=${writerStatus}`,
      `proof_store=${proofStatus}`,
      `task_scope=${taskStatus}`,
      `incomplete=${incomplete}`,
      `stale=${stale}`,
      `terminal=${terminal}`,
      `current_missing_task_scope=${currentMissing}`,
    ].join(', '),
    tone,
    route: {
      tab: 'monitoring',
      params: { section: 'fleet-health' },
    },
  }
}

// Drill-down routes for each chip key. Centralized so the builder stays
// readable and tests can audit the routing table separately. Returning
// undefined keeps the chip as a static span (transport-offline,
// execution-error: no view helps; hydrating/runtime-ok: nothing to drill).
function chipRouteFor(key: string): DashboardHealthChipRoute | undefined {
  switch (key) {
    case 'source-mismatch':
    case 'server-workspace-split':
    case 'runtime-warning':
      return { tab: 'monitoring', params: { section: 'runtime' } }
    case 'runtime-provider-health':
    case 'runtime-probe-unavailable':
      return { tab: 'monitoring', params: { section: 'runtime', view: 'providers' } }
    case 'paused-keepers':
    case 'fleet-liveness-risk':
    case 'no-keeper-rows':
      return { tab: 'monitoring', params: { section: 'fleet-health' } }
    case 'keeper-count-basis':
      return { tab: 'monitoring', params: { section: 'agents', view: 'keepers' } }
    default:
      return undefined
  }
}

function runtimeProviderFailureChip(probe: DashboardRuntimeProbePayload | null | undefined): DashboardHealthChip | null {
  if (!probe) return null
  const summary = probe.summary ?? null
  const providers = probe.providers ?? []
  const failedProviders = providers.filter(provider => provider.reachable === false)
  const failed = summary?.failed ?? failedProviders.length
  if (failed <= 0) return null

  const missingAuth = failedProviders.filter(provider => provider.status === 'missing_auth').length
  const reachable = summary?.reachable ?? providers.filter(provider => provider.reachable === true).length
  const probed = summary?.probed ?? providers.filter(provider => provider.reachable !== null && provider.reachable !== undefined).length
  const skipped = summary?.skipped ?? providers.filter(provider => provider.status === 'skipped_cli').length
  const label = missingAuth > 0
    ? `Runtime auth missing ${missingAuth}`
    : reachable > 0
      ? `Runtime providers degraded ${reachable}/${Math.max(probed, reachable + failed)}`
      : `Runtime providers unreachable ${failed}`
  const failedDetails = failedProviders.slice(0, 3).map(provider => {
    const runtimeId = provider.runtime_id ?? provider.provider_id ?? '(unknown runtime)'
    return `${runtimeId}: ${provider.status ?? 'failed'}`
  })
  const hiddenFailed = Math.max(0, failedProviders.length - failedDetails.length)
  if (hiddenFailed > 0) {
    failedDetails.push(`+${hiddenFailed} more`)
  }
  const detailParts = [
    `default=${summary?.default_runtime_id ?? '-'}`,
    `reachable=${reachable}`,
    `failed=${failed}`,
    `skipped=${skipped}`,
  ]
  if (failedDetails.length > 0) {
    detailParts.push(`providers=${failedDetails.join('; ')}`)
  }
  return {
    key: 'runtime-provider-health',
    label,
    detail: detailParts.join(', '),
    tone: reachable > 0 ? 'warn' : 'bad',
  }
}

function runtimeProbeErrorChip(error: string | null | undefined): DashboardHealthChip | null {
  if (!error) return null
  return {
    key: 'runtime-probe-unavailable',
    label: 'Runtime probe unavailable',
    detail: error,
    tone: 'warn',
  }
}

export function dashboardHealthChips(input: DashboardHealthInput): DashboardHealthChip[] {
  const chips: DashboardHealthChip[] = []
  if (!input.connected) {
    chips.push({
      key: 'transport-offline',
      label: 'Transport offline',
      detail: 'Dashboard stream is disconnected; live state can be stale.',
      tone: 'bad',
    })
  }

  const runtime = input.runtimeResolution
  if (runtime?.source_mismatch) {
    chips.push({
      key: 'source-mismatch',
      label: 'Source mismatch',
      detail: 'Server, workspace, or resolved base path source differs.',
      tone: 'warn',
    })
  } else if (runtime?.server_workspace_mismatch) {
    chips.push({
      key: 'server-workspace-split',
      label: 'Server/base split',
      detail: 'Server binary repo differs from the dashboard base path; data still resolves from the base path.',
      tone: 'muted',
    })
  } else if (runtime?.status && runtime.status !== 'ready') {
    chips.push({
      key: 'runtime-warning',
      label: 'Runtime warning',
      detail: runtime.warnings[0] ?? runtime.status,
      tone: 'warn',
    })
  }

  const rowPausedKeepers = input.keepers.filter(isKeeperPaused).length
  const fallbackRunningKeepers = input.keepers.filter(keeperRowLooksRunning).length
  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: input.keepers.length > 0,
    agentsCount: input.counts?.agents ?? 0,
    keepersCount: input.counts?.keepers ?? fallbackRunningKeepers,
    pausedKeepersCount: rowPausedKeepers,
    keeperRowsCount: input.keepers.length,
    namespaceTruthCounts: input.namespaceTruthCounts,
    namespaceTruthConfiguredKeepers: input.namespaceTruthConfiguredKeepers,
    shellCounts: input.counts,
    shellConfiguredKeepers: input.counts?.configured_keepers,
    runtimeFleetSafety: runtime?.fleet_safety ?? null,
    runtimeHealthGeneratedAt: input.runtimeGeneratedAt ?? runtime?.generated_at ?? null,
  })
  const configured = runtimeCounts.configured.keepers
  const liveKeepers = runtimeCounts.live.keepers
  const pausedKeepers = runtimeCounts.live.pausedKeepers
  // Scope note (#22110): the agent-roster surface dropped the count-source label
  // from its always-visible operational copy. Here the same label feeds the
  // keeper-count-basis chip's `detail` tooltip (hover-only, diagnostic) below —
  // an on-demand explanation of where the running count comes from, which is the
  // actionable detail that review kept. Retained intentionally, not an oversight.
  const runningCountSource = runtimeCounts.source === 'runtime-health'
    ? 'runtime health'
    : input.counts !== null
    ? 'shell'
    : input.keepers.length > 0
      ? '상세 행'
      : runtimeCountSourceLabel(runtimeCounts.source)
  const pausedCountSource = runtimeCounts.source === 'runtime-health'
    ? 'runtime health'
    : '재개 대기 lifecycle row'
  const offlineCountSource = runtimeCounts.source === 'runtime-health'
    ? 'runtime health only; execution offline rows not mixed'
    : '프로세스/하트비트 없음으로 기동 필요 row'
  if (configured > 0 && (configured !== liveKeepers || pausedKeepers > 0 || runtimeCounts.live.offlineKeepers > 0)) {
    chips.push({
      key: 'keeper-count-basis',
      label: formatKeeperCountBreakdown({
        liveKeepers,
        pausedKeepers,
        offlineKeepers: runtimeCounts.live.offlineKeepers,
        configuredKeepers: configured,
      }),
      detail: `keeper 실행 fiber=${runningCountSource}; 일시정지 keeper=${pausedCountSource}; 오프라인 keeper=${offlineCountSource}; configured keeper=${configuredCountSourceLabel(runtimeCounts.configured.source)} keeper 설정.`,
      tone: 'muted',
    })
  }

  if (pausedKeepers > 0) {
    chips.push({
      key: 'paused-keepers',
      label: `일시정지 keeper ${pausedKeepers}`,
      detail: '재개 대기 상태의 keeper가 있습니다. board/tool 활동은 조용해 보일 수 있습니다.',
      tone: 'warn',
    })
  }

  const fleetChip = fleetSafetyHealthChip(runtime?.fleet_safety ?? null)
  if (fleetChip) {
    chips.push(fleetChip)
  }

  const reactionLedgerChip = reactionLedgerHealthChip(runtime?.fleet_safety?.keeper_reaction_ledger)
  if (reactionLedgerChip) {
    chips.push(reactionLedgerChip)
  }

  const providerHealthChip = runtimeProviderFailureChip(input.runtimeProviderProbe)
  if (providerHealthChip) {
    chips.push(providerHealthChip)
  } else {
    const probeErrorChip = runtimeProbeErrorChip(input.runtimeProviderProbeError)
    if (probeErrorChip) {
      chips.push(probeErrorChip)
    }
  }

  const cdalChip = contractHealthChip(runtime?.cdal)
  if (cdalChip) {
    chips.push(cdalChip)
  }

  if (configured > 0 && input.keepers.length === 0 && liveKeepers === 0 && pausedKeepers === 0) {
    chips.push({
      key: 'no-keeper-rows',
      label: 'No keeper rows',
      detail: `${configured} keepers are configured but no live keeper rows are visible.`,
      tone: 'warn',
    })
  }

  if (input.executionError) {
    chips.push({
      key: 'execution-error',
      label: 'Execution refresh failed',
      detail: input.executionError,
      tone: 'bad',
    })
  }

  const vrfCount = input.pendingVerificationCount ?? 0
  if (vrfCount > 0) {
    chips.push({
      key: 'verification-backlog',
      label: `Verification ${vrfCount}`,
      detail:
        vrfCount >= 5
          ? `${vrfCount} tasks are awaiting verification. This is a high backlog that may delay task completion.`
          : `${vrfCount} task${vrfCount === 1 ? '' : 's'} awaiting verification.`,
      tone: vrfCount >= 5 ? 'bad' : 'warn',
    })
  }

  if (chips.length === 0) {
    chips.push({
      key: input.loading ? 'hydrating' : 'runtime-ok',
      label: input.loading ? 'Hydrating' : 'Runtime UI healthy',
      detail: input.loading
        ? 'Dashboard data is still loading.'
        : 'No transport, source, paused-keeper, or execution-refresh issue is currently visible.',
      tone: input.loading ? 'muted' : 'ok',
    })
  }

  // Attach drill-down routes via the central chipRouteFor() table. Chips
  // that already carry an inline `route` (reaction-ledger) keep theirs.
  return chips.map(chip => chip.route ? chip : { ...chip, route: chipRouteFor(chip.key) })
}

function healthChipClass(tone: DashboardHealthChipTone): string {
  switch (tone) {
    case 'ok':
      return 'border-[var(--ok-30)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]'
    case 'warn':
      return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn-bright)]'
    case 'bad':
      return 'border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)]'
    case 'muted':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
  }
}

export function DashboardHealthStrip({ hidden = false }: { hidden?: boolean }) {
  useEffect(() => {
    let disposed = false
    let inFlight = false
    let activeController: AbortController | null = null
    const refresh = async () => {
      if (inFlight) return
      inFlight = true
      activeController = new AbortController()
      try {
        const response = await fetchDashboardRuntimeProbe(false, { signal: activeController.signal })
        if (!disposed) {
          shellRuntimeProviderProbe.value = response.probe ?? null
          shellRuntimeProviderProbeError.value = null
        }
      } catch (error) {
        const name = typeof error === 'object' && error !== null && 'name' in error
          ? String((error as { name?: unknown }).name)
          : ''
        if (!disposed && name !== 'AbortError') {
          shellRuntimeProviderProbe.value = null
          shellRuntimeProviderProbeError.value = error instanceof Error ? error.message : String(error)
        }
      } finally {
        inFlight = false
      }
    }
    void refresh()
    const interval = window.setInterval(() => void refresh(), 30_000)
    return () => {
      disposed = true
      window.clearInterval(interval)
      activeController?.abort()
    }
  }, [])

  const wsOnly = dashboardWsOnlyEnabled()
  const live = wsOnly
    ? dashboardWsConnected.value || dashboardWsSseFallbackActive.value
    : connected.value
  // dashboardHealthChips does 2 keeper filter passes + resolveRuntimeCounts +
  // up to ~12 chip objects. The input object below is a fresh literal every
  // render, so memoizing on the object would always miss — instead list the
  // individual signal values as deps. DashboardHealthStrip re-renders on the
  // 30s runtime probe tick and ws event counts, which are unrelated to most
  // of these inputs; the chip rebuild is skipped when they are unchanged.
  const chips = useMemo(
    () => dashboardHealthChips({
      connected: live,
      counts: shellCounts.value,
      namespaceTruthCounts: namespaceTruth.value?.root.counts,
      namespaceTruthConfiguredKeepers: namespaceTruth.value?.root.configured_keepers,
      keepers: keepers.value,
      runtimeResolution: shellRuntimeResolution.value,
      runtimeGeneratedAt: shellRuntimeResolution.value?.generated_at ?? null,
      runtimeProviderProbe: shellRuntimeProviderProbe.value,
      runtimeProviderProbeError: shellRuntimeProviderProbeError.value,
      executionError: executionError.value,
      loading: dashboardLoading.value || namespaceTruthInitializing.value,
      pendingVerificationCount: tasksByStatus.value.awaitingVerification.length,
    }),
    [
      live,
      shellCounts.value,
      namespaceTruth.value?.root.counts,
      namespaceTruth.value?.root.configured_keepers,
      keepers.value,
      shellRuntimeResolution.value,
      shellRuntimeProviderProbe.value,
      shellRuntimeProviderProbeError.value,
      executionError.value,
      dashboardLoading.value || namespaceTruthInitializing.value,
      tasksByStatus.value.awaitingVerification.length,
    ],
  )

  return html`
    <div
      class="v2-health-strip flex shrink-0 flex-wrap items-center gap-2 border-b border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-3 py-1.5 text-xs"
      style=${hidden ? { display: 'none' } : undefined}
      aria-hidden=${hidden ? 'true' : undefined}
      role="status"
      aria-label="Dashboard runtime health"
      data-testid="dashboard-health-strip"
    >
      <span class="font-mono uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Health</span>
      ${chips.map(chip => chip.route ? html`
        <${RouteLink}
          key=${chip.key}
          tab=${chip.route.tab}
          params=${chip.route.params}
          class=${`dashboard-health-chip inline-flex min-h-6 items-center rounded-[var(--r-1)] border px-2 py-0.5 font-medium transition-opacity hover:opacity-80 ${healthChipClass(chip.tone)}`}
          title=${chip.detail}
          data-testid=${`dashboard-health-chip-${chip.key}`}
        >${chip.label}<//>
      ` : html`
        <span
          key=${chip.key}
          class=${`dashboard-health-chip inline-flex min-h-6 items-center rounded-[var(--r-1)] border px-2 py-0.5 font-medium ${healthChipClass(chip.tone)}`}
          title=${chip.detail}
          data-testid=${`dashboard-health-chip-${chip.key}`}
        >
          ${chip.label}
        </span>
      `)}
    </div>
  `
}

const errorPanelOpen = signal(false)

export function ErrorCounterBadge() {
  const count = unacknowledgedCount.value
  const open = errorPanelOpen.value
  const label = count > 0
    ? `${count} unacknowledged dashboard errors`
    : 'No dashboard errors'

  return html`
    <div class="v2-shell-panel relative" role="status">
      <button
        type="button"
        class="v2-shell-action flex items-center gap-1.5 cursor-pointer rounded-[var(--r-1)] px-1 py-0.5 transition-colors hover:bg-[var(--color-bg-elevated)] ${count > 0 ? 'text-[var(--color-status-err)]' : 'text-[var(--color-fg-muted)]'}"
        title=${label}
        aria-label=${label}
        onClick=${() => { errorPanelOpen.value = !errorPanelOpen.value }}
        aria-expanded=${open}
        aria-haspopup="true"
      >
        <${Bell} size=${14} />
        ${count > 0 ? html`
          <span class="inline-flex items-center justify-center min-w-4 h-4 px-1 rounded-full bg-[var(--color-status-err)] text-2xs font-semibold text-white tabular-nums">${count > 99 ? '99+' : count}</span>
        ` : null}
      </button>
      ${open ? html`<${ErrorPanel} onClose=${() => { errorPanelOpen.value = false }} />` : null}
    </div>
  `
}

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'dev'
  return value.length > 10 ? value.slice(0, 10) : value
}

/** Pure: render uptime seconds as a human-readable duration for the
    build-identity dropdown. Delegates to formatElapsedCompact ("3s",
    "5m 10s", "2h 30m"). Negative / NaN / non-number inputs return
    "Unknown" so the dropdown never prints "NaNs" or "-5s". */
function formatUptimeSecondsHuman(
  seconds: number | null | undefined,
): string {
  if (typeof seconds !== 'number' || Number.isNaN(seconds) || seconds < 0) {
    return 'Unknown'
  }
  return formatElapsedCompact(seconds)
}


/** Pure: compose a multi-line native-title tooltip for the build
    identity badge so hovering reveals version + commit + uptime
    without needing to open the dropdown. Reference UIs: Vercel
    deployment pill, Render build badge, Railway service chip — all
    surface the one-glance summary on hover and reserve the click for
    \"deep details\". \n renders verbatim in native tooltips. */
function composeBuildBadgeTitle(
  build: { release_version?: string | null; commit?: string | null; uptime_seconds?: number | null } | null | undefined,
  fallbackVersion: string | null | undefined,
): string {
  if (!build && !fallbackVersion) return 'Build unavailable'
  const lines: string[] = ['Server build']
  const version = build?.release_version ?? fallbackVersion
  if (version != null && version !== '') {
    const commit = build?.commit != null && build.commit !== ''
      ? ` · ${shortCommit(build.commit)}`
      : ' · dev'
    lines.push(`  · v${version}${commit}`)
  }
  const uptime = formatUptimeSecondsHuman(build?.uptime_seconds)
  if (uptime !== 'Unknown') {
    lines.push(`  · Uptime ${uptime}`)
  }
  lines.push('  · Click for details')
  return lines.join('\n')
}

export function BuildIdentityBadge() {
  const status = serverStatus.value
  const build = status?.build
  const label = build
    ? `v${build.release_version} · ${shortCommit(build.commit)}`
    : status?.version
      ? `v${status.version} · dev`
      : 'Build unavailable'
  const hoverTitle = composeBuildBadgeTitle(build, status?.version)

  return html`
    <div class="v2-shell-panel relative">
      <button type="button"
        class=${`v2-shell-action cursor-pointer rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-[5px] text-2xs text-[var(--color-fg-muted)] transition-colors duration-[var(--t-med)] hover:border-[var(--accent-20)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
        aria-expanded=${buildIdentityOpen.value}
        aria-label=${`Server build ${label}`}
        title=${hoverTitle}
        onClick=${() => {
          buildIdentityOpen.value = !buildIdentityOpen.value
        }}
      >
        ${label}
      </button>
      ${buildIdentityOpen.value
        ? html`
            <div class="v2-shell-panel absolute top-[calc(100%+8px)] right-0 min-w-70 rounded-[var(--r-1)] border border-solid border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2.5 shadow-[var(--shadow-panel)] grid gap-1.5">
              <${BuildInfoRow} label="Release">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.release_version ?? status?.version ?? 'unknown'}</strong>
              <//>
              <${BuildInfoRow} label="Commit">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.commit ?? 'git not detected (dev)'}</strong>
              <//>
              <${BuildInfoRow} label="Server started">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.started_at ? html`<${TimeAgo} timestamp=${build.started_at} />` : 'Unknown'}</strong>
              <//>
              <${BuildInfoRow} label="Uptime">
                <strong
                  class="text-[color:var(--color-fg-secondary)] text-right tabular-nums"
                  title=${typeof build?.uptime_seconds === 'number' ? `${build.uptime_seconds}s raw` : undefined}
                >${formatUptimeSecondsHuman(build?.uptime_seconds)}</strong>
              <//>
              <${BuildInfoRow} label="Shell snapshot">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${status?.generated_at ? html`<${TimeAgo} timestamp=${status.generated_at} />` : 'Unknown'}</strong>
              <//>
            </div>
          `
        : null}
    </div>
  `
}



/** Pure: gather the top-N attention-item summaries as tooltip lines so
    hovering the bottom-left health dot answers "what are the N
    things?" without a click. Reference UIs: Datadog monitor rollup
    tooltip, Vercel deployment status footer, Gmail "2 unread" with
    sender preview — all reveal the contributing items on hover so the
    operator decides whether to navigate. Exposed for tests. */
type AttentionPreviewInput = {
  summary?: string | null
  kind?: string | null
  evidence_preview?: readonly string[] | null
  grounded_verdict?: GroundedVerdict | null
}

function clipAttentionLine(raw: string, max: number): string {
  return raw.length > max ? `${raw.slice(0, Math.max(0, max - 3))}...` : raw
}

function firstGroundedEvidencePreview(verdict?: GroundedVerdict | null): string | null {
  const ref = verdict?.evidence.find(item => item.path.trim() !== '' && item.quote.trim() !== '')
  if (!ref) return null
  const location = typeof ref.line === 'number' ? `${ref.path}:${ref.line}` : ref.path
  return `${location} ${ref.quote.trim()}`
}

export function summarizeAttentionPreview(
  items: ReadonlyArray<AttentionPreviewInput>,
  max = 3,
): string[] {
  // Two-pass: first filter to valid (non-empty summary or kind), then
  // cap. This separates "skipped for noise" from "truncated for max"
  // so the tail count only reflects genuinely pending items that
  // didn't fit — never padding from null/empty rows.
  const valid: string[] = []
  for (const item of items) {
    if (!item) continue
    const summary = item.summary?.trim()
    const kind = item.kind?.trim()
    const base = (summary && summary !== '') ? summary : (kind && kind !== '' ? kind : '')
    if (base === '') continue
    const groundedEvidence = firstGroundedEvidencePreview(item.grounded_verdict)
    const previewEvidence =
      groundedEvidence
      ?? item.evidence_preview?.map(value => value.trim()).find(value => value !== '')
      ?? null
    const raw = previewEvidence
      ? `${clipAttentionLine(base, 45)} | ${clipAttentionLine(previewEvidence, 60)}`
      : base
    valid.push(clipAttentionLine(raw, previewEvidence ? 110 : 60))
  }
  if (valid.length <= max) return valid
  return [...valid.slice(0, max), `... +${valid.length - max} more`]
}

/** Pure: compose the full title-attribute string for the health
    indicator — label on the first line, attention previews indented
    under it. Newlines render in native title tooltips on all major
    browsers, so no HTML escaping or markup is needed. */
function composeHealthIndicatorTitle(
  label: string,
  attentionLines: ReadonlyArray<string>,
): string {
  if (attentionLines.length === 0) return label
  const indented = attentionLines.map(line => `  · ${line}`)
  return [label, ...indented].join('\n')
}

function dashboardRouteBoundaryKey(routeState: RouteState): string {
  const params = routeState.params
  const parts = [
    routeState.tab,
    params.section,
    params.view ? `view=${params.view}` : '',
    params.session_id ? `session=${params.session_id}` : '',
    params.operation_id ? `operation=${params.operation_id}` : '',
    params.worker_run_id ? `worker=${params.worker_run_id}` : '',
  ]

  if (routeState.tab === 'monitoring' && params.section === 'agents') {
    parts.push(
      params.agent ? `agent=${params.agent}` : '',
      params.keeper ? `keeper=${params.keeper}` : '',
    )
  }

  return parts.filter(Boolean).join(':')
}

function HealthIndicator({ collapsed }: { collapsed?: boolean }) {
  const wsOnly = dashboardWsOnlyEnabled()
  const live = wsOnly
    ? dashboardWsConnected.value || dashboardWsSseFallbackActive.value
    : connected.value
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? []
  let blockers = 0
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i]?.blocker_summary) blockers++
  }
  const attentionQueue = snap?.attention_queue ?? []
  const attentionCount = attentionQueue.length

  let dotClass: string
  let label: string

  if (!live) {
    dotClass = 'bg-[var(--color-status-err)]'
    label = 'Transport offline'
  } else if (!snap) {
    dotClass = 'bg-[var(--color-fg-muted)]'
    label = missionLoading.value ? 'Mission loading' : 'Mission idle'
  } else if (blockers > 0 || attentionCount > 0) {
    dotClass = 'bg-[var(--color-status-warn)]'
    const total = blockers + attentionCount
    label = `Mission attention ${total}`
  } else {
    dotClass = 'bg-[var(--color-status-ok)]'
    label = 'Mission healthy'
  }

  const attentionLines = attentionCount > 0 ? summarizeAttentionPreview(attentionQueue) : []
  const titleText = composeHealthIndicatorTitle(label, attentionLines)

  const dot = html`<span class="block size-2 shrink-0 rounded-[var(--r-0)] ${dotClass} shadow-1"></span>`

  if (collapsed) {
    return html`<div class="v2-shell-panel flex justify-center" title=${titleText} role="img" aria-label=${label}>${dot}</div>`
  }

  return html`
    <div class="v2-shell-panel flex items-center gap-2 px-1" role="status" aria-label=${label} title=${titleText}>
      ${dot}
      <span class="text-[var(--color-fg-muted)] truncate">${label}</span>
    </div>
  `
}

export function SideRail({
  collapsed,
  onToggle,
  primaryOnly = true,
}: {
  collapsed?: boolean
  onToggle?: () => void
  primaryOnly?: boolean
}) {
  const currentTab = route.value.tab
  const currentSection = currentSectionForRoute(route.value)
  // Open keeper-approval count for the Approvals nav badge. Same signal the
  // Approvals/Command surfaces read, so the badge tracks resolutions live.
  const openApprovals = gateData.value?.approval_queue?.length ?? 0
  const settingsSurface = DASHBOARD_SURFACES.find(surface => surface.id === 'settings')
  const visibleSurfaces = primaryOnly
    ? PRIMARY_DASHBOARD_SURFACES.filter(surface => surface.id !== 'settings')
    : DASHBOARD_SURFACES.filter(surface => surface.hidden !== true && surface.id !== 'settings')
  const settingsActive = currentTab === 'settings'

  return html`
    <nav class="v2-shell-surface flex flex-col h-full" aria-label="Dashboard navigation">
      <div class="nav-brand v2-shell-toolbar flex ${collapsed ? 'flex-col items-center gap-1.5' : 'items-center justify-between'} border-b border-[var(--color-border-default)] px-2 pt-2 pb-2">
        ${collapsed
          ? html`
            <!-- Collapsed brand = the keeper-v2 prototype's .nav-home logo box
                 (v2.css:242): 38x38 volt-filled square, "M" monogram, glow. -->
            <div class="nav-home" aria-hidden="true">M</div>
          `
          : html`
            <div class="px-1 leading-none">
              <div class="nb-title font-mono text-[var(--fs-9)] font-bold uppercase tracking-[var(--track-brand)] text-[var(--color-fg-disabled)]">MASC</div>
              <div class="nb-sub mt-1 font-mono text-[var(--fs-11)] font-semibold uppercase tracking-[0.14em] text-[var(--color-fg-secondary)]">Cockpit</div>
            </div>
          `}
        <button type="button"
          class=${`v2-shell-action nav-collapse flex size-6 items-center justify-center rounded-[var(--r-0)] border border-transparent text-[var(--color-fg-muted)] cursor-pointer transition-[background-color,border-color,color] duration-[var(--t-med)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })}`}
          aria-label=${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          onClick=${onToggle}
          title=${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
        >
          ${collapsed ? html`<${ChevronRight} size=${14} />` : html`<${ChevronLeft} size=${14} />`}
        </button>
      </div>

      <div class="flex-1 overflow-y-auto px-2 py-2">
        ${!collapsed ? html`
          <div class="nav-sec px-1 pb-1.5 font-mono text-[var(--fs-9)] font-bold uppercase tracking-[0.2em] text-[var(--color-fg-disabled)]">Surfaces</div>
        ` : null}
        <div class="flex flex-col gap-1">
          ${visibleSurfaces.map(surface => {
            const isSurfaceActive = surface.id === currentTab
            const sections = visibleSectionItemsForTab(surface.id)

            if (collapsed) {
              return html`
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="v2-shell-row nav-link-collapsed flex h-7 w-full items-center justify-center rounded-[var(--r-0)] border cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${isSurfaceActive ? 'active border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-secondary)]'}"
                  title=${surface.label}
                  aria-label=${surface.label}
                  ariaCurrent=${isSurfaceActive ? 'page' : undefined}
                >
                  <span class="nav-icon ${surface.id === 'approvals' && openApprovals > 0 ? 'relative' : ''}" aria-hidden="true">
                    <${SurfaceIcon} icon=${surface.icon} size=${15} />
                    ${surface.id === 'approvals' && openApprovals > 0 ? html`<span class="ap-nav-dot"></span>` : null}
                  </span>
                  <span class="sr-only">${surface.label}${surface.id === 'approvals' && openApprovals > 0 ? ` (${openApprovals} 대기)` : ''}</span>
                <//>
              `
            }

            return html`
              <div class="nav-group v2-shell-panel flex flex-col gap-0.5 border-t border-[var(--color-border-divider)] pt-1 first:border-t-0 first:pt-0">
                <${RouteLink}
                  tab=${surface.defaultTab}
                  params=${surface.defaultParams}
                  class="v2-shell-row nav-link flex min-h-7 w-full items-center gap-1.5 rounded-[var(--r-0)] border px-1.5 py-1 text-left cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${isSurfaceActive ? 'active border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--color-fg-secondary)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent bg-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-secondary)]'}"
                  ariaCurrent=${isSurfaceActive && sections.length === 0 ? 'page' : undefined}
                >
                  <span class="nav-icon flex size-5 shrink-0 items-center justify-center rounded-[var(--r-0)] ${isSurfaceActive ? 'bg-[var(--select-10)] text-[var(--select)]' : 'bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]'}" aria-hidden="true">
                    <${SurfaceIcon} icon=${surface.icon} size=${13} />
                  </span>
                  <div class="nav-label flex-1 min-w-0">
                    <div class="truncate font-mono text-[var(--fs-11)] font-semibold uppercase leading-4 tracking-[var(--track-caps)] ${isSurfaceActive ? 'text-[var(--select)]' : ''}">${surface.label}</div>
                  </div>
                  ${surface.id === 'approvals' && openApprovals > 0
                    ? html`<span class="ap-nav-badge" data-testid="approvals-nav-badge" title=${`${openApprovals}건 승인 대기`}>${openApprovals}</span>`
                    : null}
                <//>

                ${sections.length > 1 ? html`
                  <div class="nav-sublist v2-shell-detail ml-2.5 flex flex-col gap-px border-l border-[var(--color-border-divider)] pl-2.5" role="list">
                    ${sections.map(item => {
                      const isSectionActive = isSurfaceActive && currentSection?.id === item.id
                      return html`
                        <div role="listitem">
                          <${RouteLink}
                            tab=${surface.id}
                            params=${item.params}
                            class="v2-shell-row nav-sublink block w-full rounded-[var(--r-0)] border px-2 py-0.5 text-left font-mono text-[var(--fs-10)] uppercase leading-5 tracking-[var(--track-sub)] cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${isSectionActive ? 'active border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-primary)]'}"
                            ariaCurrent=${isSectionActive ? 'page' : undefined}
                          >
                            <div class="truncate">${item.label}</div>
                          <//>
                        </div>
                      `
                    })}
                  </div>
                ` : null}
              </div>
            `
          })}
        </div>
      </div>

      <div class="nav-footer v2-shell-panel flex shrink-0 flex-col gap-2 border-t border-[var(--color-border-default)] px-2 py-2">
        ${settingsSurface ? html`
          <${RouteLink}
            tab=${settingsSurface.defaultTab}
            params=${settingsSurface.defaultParams}
            class=${collapsed
              ? `v2-shell-row nav-link-collapsed nav-footer-settings flex h-7 w-full items-center justify-center rounded-[var(--r-0)] border cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${settingsActive ? 'active border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-secondary)]'}`
              : `v2-shell-row nav-link nav-footer-settings flex min-h-7 w-full items-center gap-1.5 rounded-[var(--r-0)] border px-1.5 py-1 text-left cursor-pointer transition-[background-color,border-color,color,box-shadow] duration-[var(--t-med)] ${settingsActive ? 'active border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--color-fg-secondary)] shadow-[inset_2px_0_0_var(--select)]' : 'border-transparent bg-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-secondary)]'}`}
            ariaCurrent=${settingsActive ? 'page' : undefined}
            title=${settingsSurface.label}
            aria-label=${settingsSurface.label}
          >
            <span class="nav-icon ${collapsed ? '' : 'flex size-5 shrink-0 items-center justify-center rounded-[var(--r-0)]'} ${settingsActive ? 'bg-[var(--select-10)] text-[var(--select)]' : collapsed ? '' : 'bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]'}" aria-hidden="true">
              <${SurfaceIcon} icon=${settingsSurface.icon} size=${collapsed ? 15 : 13} />
            </span>
            ${collapsed
              ? html`<span class="sr-only">${settingsSurface.label}</span>`
              : html`
                  <div class="nav-label flex-1 min-w-0">
                    <div class="truncate font-mono text-[var(--fs-11)] font-semibold uppercase leading-4 tracking-[var(--track-caps)] ${settingsActive ? 'text-[var(--select)]' : ''}">${settingsSurface.label}</div>
                  </div>
                `}
          <//>
        ` : null}
        <${HealthIndicator} collapsed=${collapsed} />
      </div>
    </nav>
  `
}

function TabContent() {
  const tab = route.value.tab

  switch (tab) {
    case 'overview':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Overview')}>
          <${LazyOverview} />
        <//>
      `
    case 'monitoring':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Monitor')}>
          <${LazyStatus} />
        <//>
      `
    case 'keepers':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Keepers')}>
          <${LazyKeeperDetailPage} />
        <//>
      `
    case 'board':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Board')}>
          <${LazyBoardSurface} />
        <//>
      `
    case 'schedule':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Schedule')}>
          <${LazyScheduleSurface} />
        <//>
      `
    case 'approvals':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Approvals')}>
          <${LazyApprovals} />
        <//>
      `
    case 'fusion':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Fusion')}>
          <${LazyFusionSurface} />
        <//>
      `
    case 'workspace':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Work')}>
          <${LazyWork} />
        <//>
      `
    case 'command':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Command')}>
          <${LazyOperations} />
        <//>
      `
    case 'connectors':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Connectors')}>
          <${LazyConnectors} />
        <//>
      `
    case 'lab':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Lab')}>
          <${LazyLabSurface} />
        <//>
      `
    case 'cockpit':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Cockpit')}>
          <${LazyCockpit} />
        <//>
      `
    case 'code':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Code IDE')}>
          <${LazyIdeShell} />
        <//>
      `
    case 'logs':
      return html`
        <${Suspense} fallback=${lazyTabFallback('System Logs')}>
          <${LazyLogViewer} />
        <//>
      `
    case 'settings':
      return html`
        <${Suspense} fallback=${lazyTabFallback('Settings')}>
          <${LazySettingsSurface} />
        <//>
      `
    default:
      return html`
        <${Suspense} fallback=${lazyTabFallback('Overview')}>
          <${LazyOverview} />
        <//>
      `
  }
}

/** Pure: build the shareable URL for the current section. Uses
    window.location as the truth source (the router writes to it
    already) so we never diverge from what the browser address bar
    shows. Returns empty string when window is unavailable
    (SSR/happy-dom without location) so the caller can hide the
    share affordance gracefully. */
function currentSectionShareUrl(): string {
  if (typeof window === 'undefined' || window.location === undefined) {
    return ''
  }
  return window.location.href
}

/** Pure: derive the navigation trail rendered above the section title.
    Each crumb is either a clickable ancestor (tab) or the terminal
    leaf (current section label, non-navigable). Returns a flat array:
    [] when both tab + section are absent (home / unknown),
    [tab] when only tab is active (no section drilldown),
    [tab, section] when the operator has drilled into a per-section view.

    Why this exists: SurfaceLead previously rendered only the leaf
    label ("Discord"). The parent tab ("Connectors") was implied by
    the left nav but not surfaced in the content area — a newcomer
    opening a deep link had to infer the hierarchy. Every modern web
    app (GitHub / Linear / Notion / Vercel) renders the trail above
    the page title for exactly this reason. */
interface BreadcrumbCrumb {
  label: string
  navigableTab: TabId | null
}

function deriveBreadcrumbTrail(
  tabLabel: string | null,
  sectionLabel: string | null,
  tabId: TabId | null,
): BreadcrumbCrumb[] {
  if (tabLabel === null && sectionLabel === null) return []
  if (sectionLabel === null) {
    return tabLabel !== null ? [{ label: tabLabel, navigableTab: null }] : []
  }
  if (tabLabel === null) {
    return [{ label: sectionLabel, navigableTab: null }]
  }
  return [
    { label: tabLabel, navigableTab: tabId },
    { label: sectionLabel, navigableTab: null },
  ]
}

function navigateCrumb(event: MouseEvent, tab: TabId): void {
  if (
    event.defaultPrevented
    || event.button !== 0
    || event.metaKey
    || event.ctrlKey
    || event.shiftKey
    || event.altKey
  ) {
    return
  }
  event.preventDefault()
  navigate(tab)
}

function breadcrumbItemsForTrail(trail: BreadcrumbCrumb[]): BreadcrumbItem[] {
  return trail.map((crumb, index) => {
    const current = index === trail.length - 1
    if (crumb.navigableTab !== null && !current) {
      return {
        label: crumb.label,
        href: hashForRoute(crumb.navigableTab),
        onClick: (event: MouseEvent) => navigateCrumb(event, crumb.navigableTab!),
      }
    }
    return { label: crumb.label, current }
  })
}

/** Pure: compose the browser tab title from the current surface +
    section. Reference: every polished SPA (GitHub / Linear / Notion /
    Vercel) sets document.title so operators with multiple tabs open
    can distinguish them from the browser's tab list. Without this,
    4 dashboard tabs all say \"MASC Dashboard\" — users lose track.

    Format: \"MASC · {section}\" when drilled into a section,
            \"MASC · {tab}\" when on a tab default,
            \"MASC Dashboard\" on home / unknown (original fallback). */
function composeDocumentTitle(
  tabLabel: string | null,
  sectionLabel: string | null,
): string {
  const leaf = sectionLabel ?? tabLabel
  if (leaf === null || leaf.trim() === '') return 'MASC Dashboard'
  return `MASC · ${leaf}`
}

function useSurfaceDocumentTitle(): void {
  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)

  useEffect(() => {
    document.title = composeDocumentTitle(currentView?.label ?? null, currentSection?.label ?? null)
  }, [currentView?.label, currentSection?.label])
}

export function isKeeperDetailDashboardRoute(routeState: RouteState): boolean {
  if (routeState.tab === 'keepers') return true
  return routeState.tab === 'monitoring'
    && routeState.params.section === 'agents'
    && typeof routeState.params.keeper === 'string'
    && routeState.params.keeper.trim() !== ''
}

// Surfaces that render their own primary header (a bespoke per-surface title
// block) and therefore must NOT get the generic dashboard SurfaceLead above
// them — otherwise the screen shows a duplicate title: the generic <h1> nav
// label stacked over the surface's own <h1>. When a surface component renders
// its own top-of-body header, add its TabId here (keep this in sync with the
// route registry). Verified against the v2 design audit (2026-06-20): the
// design gives every surface a single bespoke header plus a slim top-bar crumb,
// with no generic lead.
//
//   overview   → overview/overview.ts  <header class="ov-head">      <h1>지금, 전체</h1>
//   approvals  → approvals-surface.ts  <header class="ov-head">      <h1>승인 · HITL 큐</h1>
//   schedule   → schedule-surface.ts   <header class="ov-head">      <h1>예약 자동화</h1>
//   fusion     → fusion-surface.ts     <header class="ov-head fus-head"> <h1>Fusion</h1>
//   workspace  → work.ts               <header class="wk-head">      <h1>작업 · 목표</h1>
//   logs       → logs.ts               <header class="v2-logs-head">  <h1>이벤트 로그</h1>
//   cockpit    → cockpit/cockpit.ts    <header class="cp-head">      <h1>Cockpit</h1>
//   settings   → settings-surface.ts   <header class="set-content-h"> <h1>…</h1>
//   connectors → connector-status.ts   (prototype surface, own header)
//
// A second group renders their own primary header inside their body — the v2
// migration moved the header decision into each surface: monitoring/command/lab
// render the shared SurfaceHeader at their own call site (status.ts,
// operations-panel.ts, lab.ts), board renders its own header (#22021), and the
// reskinned prototype surfaces carry a bespoke header. They must be listed here
// too, otherwise the shell stacks SurfaceLead above that header and the title
// renders twice (the duplicate "Keeper Fleet" header observed on #monitoring,
// 2026-06-22):
//   monitoring → status.ts           <SurfaceHeader> <h1>Keeper Fleet</h1>
//   command    → operations-panel.ts <SurfaceHeader> <h1>Actions</h1>
//   lab        → lab.ts              <SurfaceHeader> <h1>Tools</h1>
// board is a third case: it renders NO header at all (#22086, prototype is
// headerless) but must still be in this set so the generic SurfaceLead does not
// reintroduce a title (board regressed that way in #22021).
//
// Surfaces that still rely on the generic SurfaceLead for their title: keepers, code.
//
// WORKAROUND: this allow-list is the exact N-of-M pattern surface-header.ts set
// out to delete (a list the compiler cannot keep in sync with reality). Root fix:
// drop SurfaceLead/SURFACE_OWN_LEAD_IDS entirely and give every surface its own
// header. Tracked as a follow-up; corrected here so live surfaces stop double-rendering.
const SURFACE_OWN_LEAD_IDS: ReadonlySet<TabId> = new Set([
  'overview',
  'approvals',
  'schedule',
  'fusion',
  'workspace',
  'logs',
  'cockpit',
  'settings',
  'connectors',
  // Each renders the shared SurfaceHeader in its own body; without these the generic
  // SurfaceLead stacked a duplicate title above each (monitoring/command/lab
  // carried that gap from their SurfaceHeader adoption).
  'monitoring',
  'command',
  'lab',
  // board renders no header of its own (#22086); listed here only to suppress
  // the generic SurfaceLead (which regressed a duplicate Board title in #22021).
  'board',
])

export function shouldRenderSurfaceLead(routeState: RouteState): boolean {
  if (isKeeperDetailDashboardRoute(routeState)) return false
  return !SURFACE_OWN_LEAD_IDS.has(routeState.tab)
}

function SurfaceLead() {
  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)
  const soloUrl = widgetSoloUrlForRoute(route.value)

  const description = currentSection?.description ?? currentView?.description ?? null
  const title = currentSection?.label ?? currentView?.label ?? 'Home'
  const shareUrl = currentSectionShareUrl()
  // Only surface a trail when the operator has drilled into a section —
  // otherwise the crumb would be \"Connectors\" right above a \"Connectors\"
  // title, pure duplication.
  const trail = currentSection !== null
    ? deriveBreadcrumbTrail(currentView?.label ?? null, currentSection.label, currentTab)
    : []

  return html`
    <div class="v2-shell-panel mb-3 flex flex-col gap-1.5">
      ${trail.length > 0
        ? html`<${Breadcrumb}
            items=${breadcrumbItemsForTrail(trail)}
            ariaLabel="Breadcrumb"
            testId="surface-breadcrumb"
            dataSurfaceBreadcrumb=${true}
          />`
        : null}
      <div class="flex items-center gap-2">
        <h1 class="text-lg font-semibold tracking-normal normal-case text-[var(--color-fg-secondary)] leading-tight" style="text-shadow: none;">
          ${title}
        </h1>
        ${shareUrl !== ''
          ? html`<${CopyIdButton}
              value=${shareUrl}
              label=${`Section link (${title})`}
              ariaLabel="Copy current section URL"
              size=${14}
            />`
          : null}
        <a
          href=${soloUrl}
          target="_blank"
          rel="noopener noreferrer"
          class=${`v2-shell-action v2-mobile-operator-target inline-flex size-7 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
          title="Open this surface in a solo view"
          aria-label="Open this surface in a solo view"
          data-testid="dashboard-widget-solo-link"
        >
          <${ExternalLink} size=${14} aria-hidden="true" />
        </a>
      </div>
      ${description ? html`<p class="m-0 max-w-[72rem] text-xs leading-[var(--lh-body)] text-[var(--color-fg-muted)]">${description}</p>` : null}
    </div>
  `
}

export function DashboardMain() {
  useSurfaceDocumentTitle()

  if (dashboardLoading.value && !connected.value && !namespaceTruthInitializing.value) {
    return html`<${LoadingState}>Loading dashboard...<//>`
  }

  const routeLabel = dashboardRouteBoundaryKey(route.value)
  const soloMode = isWidgetSoloRoute(route.value)
  const immersiveSurface =
    route.value.tab === 'code' || route.value.tab === 'keepers' || route.value.tab === 'schedule'
  const keeperDetailRoute = isKeeperDetailDashboardRoute(route.value)
  const renderSurfaceLead = shouldRenderSurfaceLead(route.value)
  const warmingBanner = namespaceTruthInitializing.value ? html`
    <div class=${`v2-shell-panel ${immersiveSurface
      ? 'shrink-0 border-b border-solid border-[var(--warn-20)] bg-[var(--warn-10)] px-4 py-1.5 text-center text-xs text-[var(--color-status-warn)]'
      : 'mb-3 shrink-0 rounded-[var(--r-2)] border border-solid border-[var(--warn-20)] bg-[var(--warn-10)] px-4 py-1.5 text-center text-xs text-[var(--color-status-warn)]'}`}>
      Server data warming; this view will refresh automatically.
    </div>
  ` : null

  if (soloMode) {
    const soloBodyClass = route.value.tab === 'code'
      ? 'min-h-0 flex-1 overflow-hidden'
      : 'min-h-0 flex-1 overflow-y-auto p-3 max-[520px]:p-2'

    return html`
      <div class="v2-shell-surface grid h-full min-h-0 grid-rows-[auto_auto_minmax(0,1fr)] bg-[var(--color-bg-page)]">
        <${WidgetSoloBar} routeState=${route.value} />
        <${ObservatoryFilterBar} />
        <div class=${soloBodyClass}>
          ${warmingBanner}
          <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
            <div class=${route.value.tab === 'code' ? 'h-full min-h-0 overflow-hidden' : 'animate-in fade-in slide-in-from-bottom-2 duration-[var(--t-slow)] fill-mode-both'}>
              <${TabContent} />
            </div>
          <//>
        </div>
      </div>
    `
  }

  if (immersiveSurface || keeperDetailRoute) {
    return html`
      <div class=${`v2-shell-surface animate-in fade-in slide-in-from-bottom-2 duration-[var(--t-slow)] fill-mode-both h-full min-h-0 overflow-hidden ${namespaceTruthInitializing.value ? 'grid grid-rows-[auto_minmax(0,1fr)]' : ''}`}>
        ${warmingBanner}
        <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
          <div class="h-full min-h-0 overflow-hidden">
            <${TabContent} />
          </div>
        <//>
      </div>
    `
  }

  return html`
    ${warmingBanner}
    ${renderSurfaceLead ? html`<${SurfaceLead} />` : null}
    ${keeperDetailRoute ? null : html`<${ObservatoryFilterBar} />`}
    <${ErrorBoundary} key=${routeLabel} label=${routeLabel || 'dashboard'}>
      <div class="animate-in fade-in slide-in-from-bottom-2 duration-[var(--t-slow)] fill-mode-both">
        <${TabContent} />
      </div>
    <//>
    <${ScrollToTopButton} />
  `
}

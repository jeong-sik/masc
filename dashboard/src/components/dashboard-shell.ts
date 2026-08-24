import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { lazy, Suspense } from 'preact/compat'
import type { ComponentType } from 'preact'
import { useEffect, useMemo } from 'preact/hooks'
import type { RouteState, TabId } from '../types'
import type { DashboardFleetSafetyHealth, DashboardKeeperReactionLedgerHealth, DashboardRuntimeResolution, Keeper } from '../types'
import {
  fetchDashboardRuntimeProbe,
  type DashboardRuntimeProbePayload,
} from '../api/dashboard-tools-prompts'
import { hashForRoute, navigate, route } from '../router'
import {
  dashboardWsConnected,
  dashboardWsLastDisconnectedAt,
  dashboardWsReady,
  dashboardWsReconnectCount,
} from '../dashboard-ws-state'
import { isKeeperPaused } from '../lib/keeper-predicates'
import { KEEPER_STATUS_LABEL_KO } from '../lib/keeper-operational-state'
import { dashboardLoading, executionError, keepers, serverStatus, shellCounts, shellRuntimeResolution, tasksByStatus } from '../store'
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
  DASHBOARD_NAV_ITEMS,
  currentSectionForRoute,
} from '../config/navigation'
import { ObservatoryFilterBar } from './common/observatory-filter-bar'
import type { LucideIcon } from 'lucide-preact'
import { ExternalLink } from 'lucide-preact'
import { ScrollToTopButton } from './common/scroll-to-top'
import { CopyIdButton } from './common/copy-id-button'
import { formatElapsedCompact } from '../lib/format-time'
import { unacknowledgedCount } from './common/error-notification-state'
import { ErrorPanel } from './common/error-panel'
import { Bell } from 'lucide-preact'
import { ringFocusClasses } from './common/ring'
import { Breadcrumb, type BreadcrumbItem } from './common/breadcrumb'
import { RouteLink } from './common/route-link'
import {
  isWidgetSoloRoute,
  WidgetSoloBar,
  widgetSoloUrlForRoute,
} from './widget-solo'
import { keepersNotRunning } from './fleet-health-panel'
import { ShieldAlert } from 'lucide-preact'

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
const LazyRegistrySurface = lazy(async () => ({ default: (await import('./registry/registry-surface')).RegistrySurface }))
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
  const reconn = dashboardWsReconnectCount.value
  const reconnecting = describeReconnecting({
    disconnectedAt: dashboardWsLastDisconnectedAt.value,
    now: Date.now(),
    reconnects: reconn,
  })
  const status = (() => {
    if (dashboardWsReady.value) {
      return {
        tone: 'ok' as const,
        label: reconn > 0 ? 'Reconnected' : 'Connected',
        title: reconn > 0 ? `Reconnect attempts ${reconn}` : '',
      }
    }
    if (dashboardWsConnected.value) {
      return {
        tone: 'warn' as const,
        label: 'Connecting WS',
        title: 'Client WS socket is open; waiting for dashboard/hello.',
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
  Icon?: LucideIcon
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
    keepers?: number
    total_runtimes?: number
    configured_keepers?: number
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
  const fleet = fleetSafety.keeper_fleet_safety
  if (fleet?.status === 'ok') return null
  const notRunning = keepersNotRunning(fleet)
  return {
    key: 'fleet-liveness-risk',
    label: 'Keeper fleet degraded',
    detail: [
      `status=${fleet?.status ?? 'current_fact_invalid'}`,
      fleet?.reason ? `reason=${fleet.reason}` : null,
      fleet?.executable_keeper_fiber_count != null
        ? `executable_keeper_fiber_count=${fleet.executable_keeper_fiber_count}`
        : null,
      fleet?.paused_keeper_count != null
        ? `paused_keeper_count=${fleet.paused_keeper_count}`
        : null,
      fleet?.failing_keeper_fiber_count != null
        ? `failing_keeper_fiber_count=${fleet.failing_keeper_fiber_count}`
        : null,
      fleet?.recovering_keeper_fiber_count != null
        ? `recovering_keeper_fiber_count=${fleet.recovering_keeper_fiber_count}`
        : null,
      fleet?.paused_autoboot_enabled_keeper_count != null
        ? `paused_autoboot_enabled_keeper_count=${fleet.paused_autoboot_enabled_keeper_count}`
        : null,
      fleet?.bootable_keeper_count != null
        ? `bootable_keeper_count=${fleet.bootable_keeper_count}`
        : null,
      fleet?.target_reaction_capacity_count != null
        ? `target_reaction_capacity_count=${fleet.target_reaction_capacity_count}`
        : null,
      fleet?.reaction_capacity_shortfall_count != null
        ? `reaction_capacity_shortfall_count=${fleet.reaction_capacity_shortfall_count}`
        : null,
      fleet?.blocker ? `blocker=${fleet.blocker}` : null,
      // One chip speaks for the whole fleet, so it names every keeper that is
      // not running rather than picking one to stand for the rest.
      notRunning.length > 0 ? `not_running=${notRunning.join(' ')}` : null,
    ].filter((item): item is string => item != null).join(', '),
    // Only a degraded fleet is a warning. Blocked, and a payload this
    // normalizer could not read, are both bad.
    tone: fleet?.status === 'degraded' ? 'warn' : 'bad',
    Icon: ShieldAlert,
  }
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
  const quarantined = ledgerCount(ledger.quarantined_row_count)
  const readErrors = ledgerCount(ledger.read_error_count)
  const status = ledger.status ?? 'unknown'
  const requiresAction = ledger.operator_action_required === true
  if (!requiresAction && pending === 0 && quarantined === 0 && readErrors === 0 && cursorSwept === 0 && status !== 'degraded') {
    return null
  }
  const tone: DashboardHealthChipTone = readErrors > 0
    ? 'bad'
    : requiresAction || pending > 0 || quarantined > 0 || status === 'degraded'
      ? 'warn'
      : 'ok'
  const label = pending > 0
    ? `Reaction ledger pending ${pending}`
    : quarantined > 0
      ? `Reaction ledger quarantined ${quarantined}`
      : cursorSwept > 0
        ? `Reaction ledger swept ${cursorSwept}`
      : `Reaction ledger ${status}`
  return {
    key: 'reaction-ledger',
    label,
    detail: [
      `status=${status}`,
      `pending=${pending}`,
      `cursor_swept=${cursorSwept}`,
      `quarantined=${quarantined}`,
      `read_errors=${readErrors}`,
    ].join(', '),
    tone,
    route: {
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'keeper-health' },
    },
  }
}

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
  const summary = probe.summary
  const providers = probe.providers
  const failedProviders = providers.filter(provider => provider.reachable === false)
  const failed = summary.failed
  if (failed <= 0) return null

  const missingAuth = failedProviders.filter(provider => provider.status === 'missing_auth').length
  const reachable = summary.reachable
  const probed = summary.probed
  const skipped = summary.skipped
  const label = missingAuth > 0
    ? `Runtime auth missing ${missingAuth}`
    : reachable > 0
      ? `Runtime providers degraded ${reachable}/${Math.max(probed, reachable + failed)}`
      : `Runtime providers unreachable ${failed}`
  const failedDetails = failedProviders.slice(0, 3).map(provider => {
    return `${provider.runtime_id}: ${provider.status}`
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
    : `${KEEPER_STATUS_LABEL_KO.paused} lifecycle row`
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
      detail: `keeper 실행 fiber=${runningCountSource}; ${KEEPER_STATUS_LABEL_KO.paused} keeper=${pausedCountSource}; ${KEEPER_STATUS_LABEL_KO.offline} keeper=${offlineCountSource}; configured keeper=${configuredCountSourceLabel(runtimeCounts.configured.source)} keeper 설정.`,
      tone: 'muted',
    })
  }

  if (pausedKeepers > 0) {
    chips.push({
      key: 'paused-keepers',
      label: `${KEEPER_STATUS_LABEL_KO.paused} keeper ${pausedKeepers}`,
      detail: `${KEEPER_STATUS_LABEL_KO.paused} 상태의 keeper가 있습니다. board/tool 활동은 조용해 보일 수 있습니다.`,
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
          shellRuntimeProviderProbe.value = response.probe
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

  const live = dashboardWsReady.value
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
          class=${`dashboard-health-chip inline-flex min-h-6 items-center gap-1.5 rounded-[var(--r-1)] border px-2 py-0.5 font-medium transition-opacity hover:opacity-80 ${healthChipClass(chip.tone)}`}
          title=${chip.detail}
          data-testid=${`dashboard-health-chip-${chip.key}`}
        >${chip.Icon ? html`<${chip.Icon} size=${13} aria-hidden="true" />` : null}${chip.label}<//>
      ` : html`
        <span
          key=${chip.key}
          class=${`dashboard-health-chip inline-flex min-h-6 items-center gap-1.5 rounded-[var(--r-1)] border px-2 py-0.5 font-medium ${healthChipClass(chip.tone)}`}
          title=${chip.detail}
          data-testid=${`dashboard-health-chip-${chip.key}`}
        >
          ${chip.Icon ? html`<${chip.Icon} size=${13} aria-hidden="true" />` : null}${chip.label}
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
  build: {
    release_version?: string | null
    binary_commit?: string | null
    repo_head_commit?: string | null
    uptime_seconds?: number | null
  } | null | undefined,
  fallbackVersion: string | null | undefined,
): string {
  if (!build && !fallbackVersion) return 'Build unavailable'
  const lines: string[] = ['Server build']
  const version = build?.release_version ?? fallbackVersion
  if (version != null && version !== '') {
    const binary = build?.binary_commit != null && build.binary_commit !== ''
      ? shortCommit(build.binary_commit)
      : 'binary commit unknown'
    lines.push(`  · v${version} · ${binary}`)
  }
  if (build?.repo_head_commit != null && build.repo_head_commit !== '') {
    lines.push(`  · Checkout ${shortCommit(build.repo_head_commit)}`)
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
    ? `v${build.release_version} · ${build.binary_commit ? shortCommit(build.binary_commit) : 'binary unknown'}`
    : status?.version
      ? `v${status.version} · binary unknown`
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
              <${BuildInfoRow} label="Binary commit">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.binary_commit ?? 'Unknown (build identity absent)'}</strong>
              <//>
              <${BuildInfoRow} label="Checkout head">
                <strong class="text-[color:var(--color-fg-secondary)] text-right">${build?.repo_head_commit ?? 'Unknown'}</strong>
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

export const TAB_SURFACE: Readonly<
  Record<TabId, { readonly label: string; readonly Component: ComponentType }>
> = {
  cockpit: { label: 'Cockpit', Component: LazyCockpit },
  overview: { label: 'Overview', Component: LazyOverview },
  monitoring: { label: 'Monitor', Component: LazyStatus },
  keepers: { label: 'Keepers', Component: LazyKeeperDetailPage },
  registry: { label: 'Registry', Component: LazyRegistrySurface },
  board: { label: 'Board', Component: LazyBoardSurface },
  schedule: { label: 'Schedule', Component: LazyScheduleSurface },
  fusion: { label: 'Fusion', Component: LazyFusionSurface },
  command: { label: 'Command', Component: LazyOperations },
  connectors: { label: 'Connectors', Component: LazyConnectors },
  workspace: { label: 'Work', Component: LazyWork },
  lab: { label: 'Lab', Component: LazyLabSurface },
  code: { label: 'Code IDE', Component: LazyIdeShell },
  logs: { label: 'System Logs', Component: LazyLogViewer },
  settings: { label: 'Settings', Component: LazySettingsSurface },
  approvals: { label: 'Approvals', Component: LazyApprovals },
}

function TabContent() {
  const { label, Component } = TAB_SURFACE[route.value.tab]
  return html`
    <${Suspense} fallback=${lazyTabFallback(label)}>
      <${Component} />
    <//>
  `
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

  if (dashboardLoading.value && !dashboardWsConnected.value && !namespaceTruthInitializing.value) {
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

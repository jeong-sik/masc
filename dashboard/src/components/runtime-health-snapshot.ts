import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import {
  fetchDashboardRuntimeProbe,
  fetchRuntimeProviders,
  type DashboardRuntimeProbeResponse,
  type DashboardRuntimeAssignmentStatus,
  type DashboardRuntimeProviderProbe,
  type DashboardRuntimeProviderSnapshot,
  type DashboardRuntimeProvidersResponse,
  type DashboardRuntimeStartupDegradation,
} from '../api/dashboard'
import { errorToString, MISSING_DATA_DASH } from '../lib/format-string'
import { formatNumber } from '../lib/format-number'
import { formatRelativeAgeMs } from '../lib/format-time'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
} from '../lib/runtime-provider-summary'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { ErrorState, LoadingState } from './common/feedback-state'
import { RouteLink } from './common/route-link'
import { StatTile } from './common/stat-tile'
import { StatusChip } from './common/status-chip'

interface RuntimeHealthSnapshotData {
  providers: DashboardRuntimeProvidersResponse | null
  probe: DashboardRuntimeProbeResponse | null
  probeError: string | null
}

async function loadSnapshot(forceProbe = false, signal?: AbortSignal): Promise<RuntimeHealthSnapshotData> {
  const probeResult = fetchDashboardRuntimeProbe(forceProbe, { signal })
    .then(probe => ({ probe, probeError: null }))
    .catch(error => ({ probe: null, probeError: errorToString(error) }))
  const [providers, probe] = await Promise.all([
    fetchRuntimeProviders({ signal }),
    probeResult,
  ])
  return {
    providers,
    probe: probe.probe,
    probeError: probe.probeError,
  }
}

function runtimeKey(provider: DashboardRuntimeProviderSnapshot): string {
  return provider.runtime_id ?? provider.provider
}

function providerProbeMap(probe: DashboardRuntimeProbeResponse | null): Map<string, DashboardRuntimeProviderProbe> {
  const map = new Map<string, DashboardRuntimeProviderProbe>()
  for (const item of probe?.probe?.providers ?? []) {
    const key = item.runtime_id ?? null
    if (key) map.set(key, item)
  }
  return map
}

function configuredDefaultRuntime(providers: DashboardRuntimeProvidersResponse | null): string | null {
  return providers?.summary?.default_runtime_id
    ?? providers?.providers.find(provider => provider.is_default_runtime === true)?.runtime_id
    ?? providers?.providers.find(provider => provider.is_default_runtime === true)?.provider
    ?? null
}

function probeDefaultRuntime(probe: DashboardRuntimeProbeResponse | null): string | null {
  return probe?.probe?.summary?.default_runtime_id
    ?? probe?.probe?.configured_default_model
    ?? probe?.probe?.effective_model
    ?? null
}

function countProviderStatus(
  providers: DashboardRuntimeProvidersResponse | null,
  probe: DashboardRuntimeProbeResponse | null,
) {
  const probeItems = probe?.probe?.providers ?? []
  const reachable = probe?.probe?.summary?.reachable
    ?? probeItems.filter(item => item.reachable === true).length
  const failed = probe?.probe?.summary?.failed
    ?? probeItems.filter(item => item.reachable === false).length
  const skipped = probe?.probe?.summary?.skipped
    ?? probeItems.filter(item => item.status === 'skipped_cli').length
  const missingAuth =
    probeItems.filter(item => item.status === 'missing_auth' || item.status === 'auth_failed').length
    + (providers?.providers ?? []).filter(provider => provider.status === 'missing_auth').length
  return {
    reachable,
    failed,
    skipped,
    missingAuth,
    total: providers?.summary?.runtimes ?? providers?.providers.length ?? probe?.probe?.summary?.runtimes ?? 0,
  }
}

function assignmentStatusNeedsAttention(assignmentStatus: DashboardRuntimeAssignmentStatus | null | undefined): boolean {
  return assignmentStatus?.degraded === true || assignmentStatus?.operator_action_required === true
}

function startupNeedsAttention(startup: DashboardRuntimeStartupDegradation | null | undefined): boolean {
  return startup?.degraded === true || startup?.operator_action_required === true
}

function snapshotStatus(
  counts: ReturnType<typeof countProviderStatus>,
  probeError: string | null,
  assignmentStatus: DashboardRuntimeAssignmentStatus | null | undefined,
  startup: DashboardRuntimeStartupDegradation | null | undefined,
): 'ok' | 'warn' | 'crit' {
  if (probeError || counts.failed > 0 || counts.missingAuth > 0) return 'crit'
  if (startupNeedsAttention(startup)) return 'warn'
  if (assignmentStatusNeedsAttention(assignmentStatus)) return 'warn'
  if (counts.skipped > 0 || counts.reachable === 0) return 'warn'
  return 'ok'
}

function snapshotTone(status: 'ok' | 'warn' | 'crit'): 'ok' | 'warn' | 'bad' {
  return status === 'crit' ? 'bad' : status
}

function snapshotStatusText(
  status: 'ok' | 'warn' | 'crit',
  startupAttention: boolean,
  assignmentAttention: boolean,
): string {
  if (status === 'crit') return 'needs attention'
  if (startupAttention) return 'runtime startup degraded'
  if (assignmentAttention) return 'runtime assignment review'
  return status === 'ok' ? 'runtime reachable' : 'probe incomplete'
}

function startupDegradationValue(startup: DashboardRuntimeStartupDegradation | null | undefined): string {
  if (!startup) return MISSING_DATA_DASH
  if (startupNeedsAttention(startup)) return 'degraded'
  return startup.status ?? 'ok'
}

function startupDegradationDetail(startup: DashboardRuntimeStartupDegradation | null | undefined): string {
  if (!startup) return 'startup state'
  if (startup.missing_catalog_model_count > 0) {
    return `${formatNumber(startup.missing_catalog_model_count)} catalog gaps`
  }
  return startup.terminal_reason ?? startup.status ?? 'ok'
}

function startupDegradationAlertDetail(startup: DashboardRuntimeStartupDegradation): string | null {
  const missing = startup.missing_catalog_models
    .slice(0, 3)
    .map(model => model.runtime_id)
  if (missing.length > 0) return `missing catalog: ${missing.join(', ')}`
  if (startup.disabled_runtime_ids.length > 0) {
    return `disabled runtimes: ${startup.disabled_runtime_ids.slice(0, 3).join(', ')}`
  }
  return startup.message ?? startup.next_action ?? null
}

function shortUrl(value: string | null | undefined): string {
  if (!value) return MISSING_DATA_DASH
  if (value.length <= 52) return value
  return `${value.slice(0, 32)}...${value.slice(-16)}`
}

function formatCheckedAt(probe: DashboardRuntimeProbeResponse | null): string {
  const ts = probe?.probe?.checked_at ?? probe?.generated_at
  if (!ts) return 'probe time unknown'
  const ms = Date.parse(ts)
  if (!Number.isFinite(ms)) return ts
  return formatRelativeAgeMs(Date.now() - ms)
}

function runtimeProbeFreshnessLabel(probe: DashboardRuntimeProbeResponse | null): string {
  // Reflect the server's non-blocking refresh_state so a force=1 ("Live probe")
  // response is not mislabelled "fresh probe" when it is actually a stale value
  // returned with a background refresh scheduled. Falls back to the cache_hit
  // flag for older servers that do not emit refresh_state.
  switch (probe?.refresh_state) {
    case 'served_stale':
      return 'refreshing'
    case 'warming_up':
      return 'warming up'
    case 'fresh':
    case 'recent':
      return 'cache hit'
    default:
      return probe?.cache_hit ? 'cache hit' : 'fresh probe'
  }
}

function firstProblem(
  providers: DashboardRuntimeProvidersResponse | null,
  probe: DashboardRuntimeProbeResponse | null,
): { id: string; message: string; detail: string | null } | null {
  const probeProblem = (probe?.probe?.providers ?? []).find(item =>
    item.reachable === false
    || item.status === 'missing_auth'
    || item.status === 'auth_failed'
    || item.status === 'network_error'
    || item.status === 'server_error'
  )
  if (probeProblem) {
    return {
      id: probeProblem.runtime_id ?? probeProblem.provider_id ?? 'runtime',
      message: probeProblem.status ?? 'probe failed',
      detail: probeProblem.error ?? probeProblem.probe_url ?? probeProblem.endpoint_url ?? null,
    }
  }
  const providerProblem = (providers?.providers ?? []).find(provider =>
    provider.available === false
    || provider.status === 'missing_auth'
    || provider.status === 'unsupported'
    || provider.status === 'offline'
  )
  if (!providerProblem) return null
  return {
    id: runtimeKey(providerProblem),
    message: providerProblem.status ?? 'unavailable',
    detail: providerProblem.note ?? providerProblem.endpoint_url ?? null,
  }
}

function assignmentStatusValue(assignmentStatus: DashboardRuntimeAssignmentStatus | null | undefined): string {
  if (!assignmentStatus) return MISSING_DATA_DASH
  const count = assignmentStatus.assignment_count
  return count === 0 ? 'default only' : `${formatNumber(count)} explicit`
}

function assignmentStatusDetail(assignmentStatus: DashboardRuntimeAssignmentStatus | null | undefined): string {
  if (!assignmentStatus) return 'runtime.toml'
  if (assignmentStatus.warnings.length > 0) return assignmentStatus.warnings.slice(0, 2).join(', ')
  return assignmentStatus.status ?? 'ok'
}

function endpointRows(probe: DashboardRuntimeProbeResponse | null): Array<{ label: string; value: string | null | undefined }> {
  return [
    { label: 'server', value: probe?.probe?.server_url },
    { label: 'models', value: probe?.probe?.ps_endpoint },
    { label: 'generate', value: probe?.probe?.generate_endpoint },
  ].filter(row => Boolean(row.value))
}

function defaultRuntimeSpecRows(provider: DashboardRuntimeProviderSnapshot | null): Array<{ label: string; value: string }> {
  if (!provider) return []
  return [
    { label: 'effective', value: runtimeCatalogEffectiveCapabilities(provider) },
    { label: 'declared', value: runtimeCatalogDeclaredSpec(provider) },
    { label: 'request', value: runtimeCatalogRequestConfig(provider) },
    { label: 'policy', value: runtimeCatalogParameterPolicy(provider) },
  ].filter((row): row is { label: string; value: string } => Boolean(row.value))
}

export function RuntimeHealthSnapshot() {
  const resource = useManagedAsyncResource<RuntimeHealthSnapshotData>()

  const load = (forceProbe = false) => {
    void resource.load(signal => loadSnapshot(forceProbe, signal))
  }

  useEffect(() => {
    load(false)
    return () => {
      resource.cancel()
    }
  }, [resource])

  const state = resource.state.value
  const data = state.data
  const providers = data?.providers ?? null
  const probe = data?.probe ?? null
  const probeError = data?.probeError ?? null
  const assignmentStatus = providers?.assignment_status ?? null
  const startup = providers?.startup_degradation ?? null
  const counts = countProviderStatus(providers, probe)
  const status = snapshotStatus(counts, probeError, assignmentStatus, startup)
  const assignmentAttention = assignmentStatusNeedsAttention(assignmentStatus)
  const startupAttention = startupNeedsAttention(startup)
  const startupAlertDetail = startupAttention && startup ? startupDegradationAlertDetail(startup) : null
  const problem = firstProblem(providers, probe)
  const providerProbes = providerProbeMap(probe)
  const defaultRuntime = configuredDefaultRuntime(providers) ?? probeDefaultRuntime(probe)
  const defaultProbe = defaultRuntime ? providerProbes.get(defaultRuntime) ?? null : null
  const defaultProvider = defaultRuntime
    ? providers?.providers.find(provider => runtimeKey(provider) === defaultRuntime) ?? null
    : null
  const endpoints = endpointRows(probe)
  const defaultSpecRows = defaultRuntimeSpecRows(defaultProvider)

  return html`
    <${SectionCard}
      class="v2-monitoring-panel"
      label="런타임 상태 체크"
      status=${status}
      right=${html`
        <${ActionButton}
          variant="ghost"
          size="sm"
          ariaLabel="runtime live probe 강제 새로고침"
          ariaBusy=${state.loading}
          disabled=${state.loading}
          onClick=${() => load(true)}
        >
          ${state.loading ? '확인 중' : 'Live probe'}
        <//>
      `}
    >
      ${state.loading && !data ? html`
        <${LoadingState}>runtime 상태 확인 중...<//>
      ` : null}
      ${state.error ? html`<${ErrorState} message=${state.error} />` : null}

      <div class="grid grid-cols-1 gap-3 md:grid-cols-3 xl:grid-cols-6" data-testid="runtime-health-snapshot">
        <${StatTile}
          label="live probe"
          value=${counts.failed > 0 ? `${counts.failed} failing` : `${counts.reachable} reachable`}
          status=${status}
          delta=${{
            direction: status === 'crit' ? 'down' : status === 'ok' ? 'up' : 'flat',
            text: `total ${formatNumber(counts.total)} · skipped ${formatNumber(counts.skipped)}`,
          }}
        />
        <${StatTile}
          label="default runtime"
          value=${defaultRuntime ?? MISSING_DATA_DASH}
          status=${defaultProbe?.reachable === false || defaultProvider?.available === false ? 'crit' : defaultRuntime ? 'ok' : 'warn'}
          delta=${{
            direction: defaultProbe?.reachable === false || defaultProvider?.available === false ? 'down' : 'flat',
            text: defaultProbe?.status ?? defaultProvider?.status ?? 'configured',
          }}
        />
        <${StatTile}
          label="auth"
          value=${counts.missingAuth > 0 ? `${counts.missingAuth} missing` : 'ready'}
          status=${counts.missingAuth > 0 ? 'crit' : 'ok'}
          delta=${{ direction: counts.missingAuth > 0 ? 'down' : 'flat', text: 'runtime credentials' }}
        />
        <${StatTile}
          label="checked"
          value=${formatCheckedAt(probe)}
          status=${probeError ? 'crit' : probe ? 'ok' : 'warn'}
          delta=${{ direction: probeError ? 'down' : 'flat', text: runtimeProbeFreshnessLabel(probe) }}
        />
        <${StatTile}
          label="startup"
          value=${startupDegradationValue(startup)}
          status=${startupAttention ? 'warn' : startup ? 'ok' : 'warn'}
          delta=${{
            direction: startupAttention ? 'down' : 'flat',
            text: startupDegradationDetail(startup),
          }}
        />
        <${StatTile}
          label="assignments"
          value=${assignmentStatusValue(assignmentStatus)}
          status=${assignmentAttention ? 'warn' : assignmentStatus ? 'ok' : 'warn'}
          delta=${{
            direction: assignmentAttention ? 'down' : 'flat',
            text: assignmentStatusDetail(assignmentStatus),
          }}
        />
      </div>

      ${probeError ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--status-bad)] bg-[var(--status-bad)]/5 px-3 py-2 text-xs text-[var(--status-bad)]" role="alert">
          live probe request failed · ${probeError}
        </div>
      ` : null}

      ${problem ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--status-bad)] bg-[var(--status-bad)]/5 px-3 py-2 text-xs text-[var(--status-bad)]" role="alert">
          <span class="font-mono">${problem.id}</span>
          <span class="mx-1">·</span>
          <span>${problem.message}</span>
          ${problem.detail ? html`<div class="mt-1 truncate text-2xs" title=${problem.detail}>${problem.detail}</div>` : null}
        </div>
      ` : null}

      ${startupAttention && startup ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--status-warn)]/5 px-3 py-2 text-xs text-[var(--status-warn)]" role="alert">
          runtime startup degraded · ${startup.terminal_reason ?? startup.status ?? 'catalog gate'}
          ${startup.effective_default_runtime_id ? html`
            <div class="mt-1 truncate text-2xs" title=${startup.effective_default_runtime_id}>
              effective default: ${startup.effective_default_runtime_id}
            </div>
          ` : null}
          ${startup.disabled_runtime_ids.length ? html`
            <div class="mt-1 truncate text-2xs" title=${startup.disabled_runtime_ids.join(', ')}>
              disabled runtimes: ${startup.disabled_runtime_ids.join(', ')}
            </div>
          ` : null}
          ${startupAlertDetail ? html`
            <div class="mt-1 truncate text-2xs" title=${startupAlertDetail}>
              ${startupAlertDetail}
            </div>
          ` : null}
          ${startup.next_action ? html`
            <div class="mt-1 truncate text-2xs" title=${startup.next_action}>
              next: ${startup.next_action}
            </div>
          ` : null}
        </div>
      ` : null}

      ${assignmentAttention ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--status-warn)]/5 px-3 py-2 text-xs text-[var(--status-warn)]" role="alert">
          runtime assignment status · ${assignmentStatus?.status ?? 'watch'} · ${formatNumber(assignmentStatus?.assignment_count ?? 0)} explicit assignments
          ${assignmentStatus?.assigned_runtimes.length ? html`
            <div class="mt-1 truncate text-2xs" title=${assignmentStatus.assigned_runtimes.join(', ')}>
              assigned runtimes: ${assignmentStatus.assigned_runtimes.join(', ')}
            </div>
          ` : null}
          ${assignmentStatus?.warnings.length ? html`
            <div class="mt-1 truncate text-2xs" title=${assignmentStatus.warnings.join(', ')}>
              warnings: ${assignmentStatus.warnings.join(', ')}
            </div>
          ` : null}
        </div>
      ` : null}

      ${defaultSpecRows.length > 0 ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-xs" data-testid="runtime-health-default-spec">
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">default runtime spec</span>
            <span class="font-mono text-2xs text-[var(--color-fg-secondary)]">${defaultRuntime ?? MISSING_DATA_DASH}</span>
          </div>
          <div class="mt-2 grid gap-1.5">
            ${defaultSpecRows.map(row => html`
              <div class="grid gap-1 md:grid-cols-[6.5rem_minmax(0,1fr)]" data-runtime-health-default-spec-row=${row.label}>
                <span class="font-mono text-3xs uppercase text-[var(--color-fg-muted)]">${row.label}</span>
                <span class="min-w-0 truncate font-mono text-2xs text-[var(--color-fg-secondary)]" title=${row.value}>
                  ${row.value}
                </span>
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${endpoints.length > 0 ? html`
        <div class="mt-3 grid gap-2 md:grid-cols-3" data-testid="runtime-health-endpoints">
          ${endpoints.map(row => html`
            <div class="v2-monitoring-card min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
              <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.label}</div>
              <div class="mt-1 truncate font-mono text-2xs text-[var(--color-fg-secondary)]" title=${row.value ?? ''}>
                ${shortUrl(row.value)}
              </div>
            </div>
          `)}
        </div>
      ` : null}

      <div class="mt-3 flex flex-wrap items-center gap-2 text-2xs">
        <${StatusChip} tone=${snapshotTone(status)} uppercase=${false}>
          ${snapshotStatusText(status, startupAttention, assignmentAttention)}
        <//>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'runtime', view: 'providers' }}
          class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
        >
          provider details
        <//>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'runtime', view: 'config' }}
          class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
        >
          runtime.toml
        <//>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'transport-health' }}
          class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
        >
          transport health
        <//>
      </div>
    <//>
  `
}

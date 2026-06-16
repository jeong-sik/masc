import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import {
  fetchDashboardRuntimeProbe,
  fetchRuntimeProviders,
  type DashboardRuntimeProbeResponse,
  type DashboardRuntimeProviderProbe,
  type DashboardRuntimeProviderSnapshot,
  type DashboardRuntimeProvidersResponse,
} from '../api/dashboard'
import { errorToString, MISSING_DATA_DASH } from '../lib/format-string'
import { formatNumber } from '../lib/format-number'
import { formatRelativeAgeMs } from '../lib/format-time'
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

function snapshotStatus(counts: ReturnType<typeof countProviderStatus>, probeError: string | null): 'ok' | 'warn' | 'crit' {
  if (probeError || counts.failed > 0 || counts.missingAuth > 0) return 'crit'
  if (counts.skipped > 0 || counts.reachable === 0) return 'warn'
  return 'ok'
}

function snapshotTone(status: 'ok' | 'warn' | 'crit'): 'ok' | 'warn' | 'bad' {
  return status === 'crit' ? 'bad' : status
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

function endpointRows(probe: DashboardRuntimeProbeResponse | null): Array<{ label: string; value: string | null | undefined }> {
  return [
    { label: 'server', value: probe?.probe?.server_url },
    { label: 'models', value: probe?.probe?.ps_endpoint },
    { label: 'generate', value: probe?.probe?.generate_endpoint },
  ].filter(row => Boolean(row.value))
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
  const counts = countProviderStatus(providers, probe)
  const status = snapshotStatus(counts, probeError)
  const problem = firstProblem(providers, probe)
  const providerProbes = providerProbeMap(probe)
  const defaultRuntime = configuredDefaultRuntime(providers) ?? probeDefaultRuntime(probe)
  const defaultProbe = defaultRuntime ? providerProbes.get(defaultRuntime) ?? null : null
  const defaultProvider = defaultRuntime
    ? providers?.providers.find(provider => runtimeKey(provider) === defaultRuntime) ?? null
    : null
  const endpoints = endpointRows(probe)

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

      <div class="grid grid-cols-1 gap-3 md:grid-cols-4" data-testid="runtime-health-snapshot">
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
          delta=${{ direction: probeError ? 'down' : 'flat', text: probe?.cache_hit ? 'cache hit' : 'fresh probe' }}
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
          ${status === 'crit' ? 'needs attention' : status === 'ok' ? 'runtime reachable' : 'probe incomplete'}
        <//>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'runtime', view: 'providers' }}
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
        >
          provider details
        <//>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'runtime', view: 'config' }}
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
        >
          runtime.toml
        <//>
        <${RouteLink}
          tab="monitoring"
          params=${{ section: 'transport-health' }}
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
        >
          transport health
        <//>
      </div>
    <//>
  `
}

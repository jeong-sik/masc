import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeProbeResponse,
  DashboardRuntimeProviderProbe,
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeResolution,
  KeeperRuntimeResolved,
  KeeperRuntimeField,
} from '../../api/dashboard'
import { fetchDashboardRuntimeProbe } from '../../api/dashboard'
import type { AsyncState } from '../../lib/async-state'
import { MISSING_DATA_DASH, errorToString } from '../../lib/format-string'
import { Btn } from '../btn'
import { SectionCard } from '../common/card'
import { StatusChip } from '../common/status-chip'
import { CopyIdButton } from '../common/copy-id-button'
import { TextInput } from '../common/input'
import { formatNumber } from '../../lib/format-number'
import {
  findRuntimeCatalogEntry,
  loadRuntimeCatalog,
  runtimeCatalogState,
} from '../../lib/runtime-catalog-resource'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
  runtimeCatalogSnapshotFacts,
} from '../../lib/runtime-provider-summary'

function ConfigCard({
  class: cx,
  title,
  children,
}: {
  class?: string
  title?: string
  children: unknown
}) {
  return html`
    <div class="v2-lab-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] ${cx ?? ''}" title=${title}>
      ${children}
    </div>
  `
}

/** Pure: what string goes into the clipboard when the operator taps the
    copy icon next to a path row? Always the absolute path — not the
    ~-collapsed display string — because the dominant use case (copy →
    paste into terminal `cd`, copy → paste into a Slack message for a
    teammate on a different machine) requires the unambiguous form.
    Reference UIs: GitHub file-breadcrumb copy, Vercel deployment path,
    Datadog host path — all copy the canonical absolute form even when
    the display is shortened. Exposed for tests. */
export function copyablePath(item: Pick<DashboardConfigResolutionItem, 'path'>): string {
  return item.path ?? ''
}

/**
 * Pure filter for runtime diagnostics entries.
 *
 * Case-insensitive substring match on `kind`, `signal`, and `message` in
 * that order (first match wins). Operators can isolate a single class of
 * runtime warning (e.g. `external_signal`), a specific POSIX signal
 * (`SIGTERM`), or search free text in the message body.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * useMemo keeps referential identity for the non-filtering path.
 * Input is never mutated; `readonly` is preserved.
 */
export function filterDiagnostics(
  diagnostics: readonly DashboardRuntimeDiagnostic[],
  query: string,
): readonly DashboardRuntimeDiagnostic[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return diagnostics
  return diagnostics.filter(item => {
    if (item.kind.toLowerCase().includes(needle)) return true
    if (item.signal && item.signal.toLowerCase().includes(needle)) return true
    if (item.message.toLowerCase().includes(needle)) return true
    return false
  })
}

function toneClass(status: string): string {
  switch (status) {
    case 'ready':
      return 'border-[var(--emerald-28)] bg-[var(--emerald-10)] text-[var(--emerald-fg)]'
    case 'warn':
      return 'border-[var(--yellow-bright-28)] bg-[var(--yellow-bright-10)] text-[var(--yellow-100)]'
    case 'invalid_env':
      return 'border-[var(--rose-28)] bg-[var(--rose-10)] text-[var(--rose-fg)]'
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]'
  }
}

function sourceLabel(source: string): string {
  switch (source) {
    case 'env':
      return 'env override'
    case 'local_masc':
      return 'local .masc'
    case 'invalid_env':
      return 'invalid env'
    case 'exe_relative':
      return 'exe fallback'
    case 'cwd':
      return 'cwd fallback'
    case 'input':
      return 'input'
    case 'workspace':
      return 'workspace'
    case 'resolved_base':
      return 'resolved base'
    case 'runtime_data':
      return 'runtime data'
    case 'prompt_registry':
      return 'prompt registry'
    case 'derived':
      return 'default'
    default:
      return 'missing'
  }
}

function normalizePath(path: string): string {
  if (path === '/') return path
  return path.replace(/\/+$/, '')
}

function describePath(path: string, rootPath: string, isRoot: boolean): {
  primary: string
  context: string | null
  kind: string | null
} {
  const normalizedPath = normalizePath(path)
  const normalizedRoot = normalizePath(rootPath)

  if (isRoot || normalizedRoot === '') {
    return {
      primary: normalizedPath,
      context: null,
      kind: null,
    }
  }

  if (normalizedPath === normalizedRoot) {
    return {
      primary: '.',
      context: 'same as config root',
      kind: 'root-relative',
    }
  }

  const rootPrefix = normalizedRoot === '/' ? '/' : `${normalizedRoot}/`
  if (normalizedPath.startsWith(rootPrefix)) {
    return {
      primary: normalizedPath.slice(rootPrefix.length),
      context: 'under config root',
      kind: 'root-relative',
    }
  }

  return {
    primary: normalizedPath,
    context: 'outside config root',
    kind: 'external',
  }
}

function ConfigRow({
  label,
  item,
  rootPath = '',
  rootSource = '',
  isRoot = false,
}: {
  label: string
  item: DashboardConfigResolutionItem
  rootPath?: string
  rootSource?: string
  isRoot?: boolean
}) {
  const pathInfo = describePath(item.path, rootPath, isRoot)
  const showSourceBadge = !isRoot && (rootSource === '' || item.source !== rootSource)

  return html`
    <${ConfigCard} class="px-3 py-3" title=${item.path}>
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${label}</div>
        <${StatusChip} tone=${toneClass(item.exists ? 'ready' : item.source === 'invalid_env' ? 'invalid_env' : 'warn')}>${item.exists ? 'present' : 'missing'}<//>
        ${showSourceBadge
          ? html`
              <${StatusChip} tone="neutral" uppercase=${false}>${sourceLabel(item.source)}<//>
            `
          : null}
        ${pathInfo.kind
          ? html`
              <${StatusChip} tone="neutral" uppercase=${false}>${pathInfo.kind}<//>
            `
          : null}
      </div>
      <div class="flex items-start gap-1.5">
        <div class="min-w-0 flex-1 break-all font-mono text-xs leading-relaxed text-[var(--color-fg-primary)]">${pathInfo.primary}</div>
        ${item.path
          ? html`<${CopyIdButton} value=${copyablePath(item)} label=${label} ariaLabel=${`${label} 경로 복사`} />`
          : null}
      </div>
      ${pathInfo.context
        ? html`
            <div class="mt-2 text-2xs text-[var(--color-fg-muted)]">${pathInfo.context}</div>
          `
        : null}
    <//>
  `
}

function isRepoFallbackSource(source: string): boolean {
  return source === 'cwd' || source === 'exe_relative'
}

function ConfigTopologySummary({
  resolution,
}: {
  resolution: DashboardConfigResolution
}) {
  const repoFallbackActive = isRepoFallbackSource(resolution.config_root.source)

  return html`
    <div class="v2-lab-panel mb-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-3 py-2">
      <div class="flex flex-wrap items-center gap-2">
        <${StatusChip} tone="neutral" uppercase=${false}>TOML-only<//>
        <${StatusChip} tone=${repoFallbackActive ? 'warn' : 'neutral'} uppercase=${false}>
          ${repoFallbackActive ? 'repo config active' : 'repo seed not active'}
        <//>
        <span class="text-xs text-[var(--color-fg-muted)]">runtime config follows the resolved config root</span>
      </div>
    </div>
  `
}

function WarningBlock({
  title,
  warnings,
}: {
  title: string
  warnings: string[]
}) {
  if (warnings.length === 0) return null

  return html`
    <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--yellow-bright-28)] bg-[var(--warn-10)] px-3 py-3">
      <div class="mb-2 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--yellow-100)]">${title}</div>
      <div class="flex flex-col gap-2">
        ${warnings.map(warning => html`
          <div class="text-xs leading-relaxed text-[var(--color-fg-primary)]">${warning}</div>
        `)}
      </div>
    </div>
  `
}

function RuntimeMetaRow({
  label,
  value,
}: {
  label: string
  value: string
}) {
  return html`
    <${ConfigCard} class="flex items-center justify-between gap-3 px-3 py-2">
      <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${label}</div>
      <div class="break-all text-right font-mono text-xs text-[var(--color-fg-primary)]">${value}</div>
    <//>
  `
}

function DiagnosticRow({ item }: { item: DashboardRuntimeDiagnostic }) {
  return html`
    <${ConfigCard} class="px-3 py-3">
      <div class="mb-1 flex flex-wrap items-center gap-2">
        <${StatusChip} tone="neutral">${item.kind}<//>
        ${item.signal
          ? html`
              <${StatusChip} tone="warn">${item.signal}<//>
            `
          : null}
        <span class="text-2xs text-[var(--color-fg-muted)]">${item.ts}</span>
      </div>
      <div class="text-xs leading-relaxed text-[var(--color-fg-primary)]">${item.message}</div>
    <//>
  `
}


function fmtBoolean(value: boolean | null | undefined): string {
  if (value === true) return 'yes'
  if (value === false) return 'no'
  return MISSING_DATA_DASH
}

function probeTone(signal: string | null | undefined, probeOk: boolean | null | undefined): string {
  if (probeOk === false) return 'border-[var(--rose-28)] bg-[var(--rose-10)] text-[var(--rose-fg)]'
  switch (signal) {
    case 'likely_reused':
      return 'border-[var(--emerald-28)] bg-[var(--emerald-10)] text-[var(--emerald-fg)]'
    case 'possible_reuse':
      return 'border-[var(--yellow-bright-28)] bg-[var(--yellow-bright-10)] text-[var(--yellow-100)]'
    case 'no_visible_reuse':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]'
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]'
  }
}

function probeSignalLabel(signal: string | null | undefined): string {
  switch (signal) {
    case 'likely_reused':
      return 'kv likely reused'
    case 'possible_reuse':
      return 'kv possible reuse'
    case 'no_visible_reuse':
      return 'no visible reuse'
    case 'insufficient_data':
      return 'insufficient data'
    default:
      return 'probe pending'
  }
}

function providerProbeTone(status: string | null | undefined, reachable: boolean | null | undefined): string {
  if (reachable === true) return 'ok'
  if (status === 'skipped_cli') return 'neutral'
  if (reachable === false) return 'bad'
  return 'neutral'
}

function providerProbeLabel(status: string | null | undefined, reachable: boolean | null | undefined): string {
  if (reachable === true) return 'reachable'
  switch (status) {
    case 'missing_auth':
      return 'missing auth'
    case 'auth_failed':
      return 'auth failed'
    case 'network_error':
      return 'network error'
    case 'server_error':
      return 'server error'
    case 'endpoint_not_found':
      return 'not found'
    case 'skipped_cli':
      return 'cli skipped'
    default:
      return status ?? 'unknown'
  }
}

function runtimeProbeCatalogEntry(
  catalog: readonly DashboardRuntimeProviderSnapshot[],
  probe: DashboardRuntimeProviderProbe,
): DashboardRuntimeProviderSnapshot | null {
  if (probe.runtime_id) {
    const entry = findRuntimeCatalogEntry(catalog, probe.runtime_id)
    if (entry) return entry
  }
  const providerId = probe.provider_id?.trim()
  if (!providerId) return null
  return catalog.find(entry => {
    const ids = [entry.provider_id, entry.provider]
    return ids.some(id => id?.trim() === providerId)
  }) ?? null
}

function runtimeProbeCatalogStatus(
  state: AsyncState<DashboardRuntimeProviderSnapshot[]>,
  probe: DashboardRuntimeProviderProbe,
): string {
  if (state.status === 'idle' || state.status === 'loading') return `catalog ${state.status}`
  if (state.status === 'error') return `catalog error: ${state.message}`
  return `catalog missing for ${probe.runtime_id ?? probe.provider_id ?? '(unknown runtime)'}`
}

function runtimeProbeCatalogRows(entry: DashboardRuntimeProviderSnapshot): readonly (readonly [string, string])[] {
  const rows: Array<readonly [string, string | null]> = [
    ['snapshot', runtimeCatalogSnapshotFacts(entry)],
    ['effective', runtimeCatalogEffectiveCapabilities(entry)],
    ['request', runtimeCatalogRequestConfig(entry)],
    ['declared', runtimeCatalogDeclaredSpec(entry)],
    ['policy', runtimeCatalogParameterPolicy(entry)],
  ]
  return rows.filter((row): row is readonly [string, string] => typeof row[1] === 'string' && row[1].trim() !== '')
}

const KEEPER_RUNTIME_ROWS: Array<{
  key: keyof KeeperRuntimeResolved
  label: string
  fmt: 'int' | 'float' | 'duration'
}> = [
  { key: 'bootstrap_max_active_keepers', label: 'bootstrap max active keepers', fmt: 'int' },
  { key: 'reactive_max_idle_turns', label: 'reactive max idle turns', fmt: 'int' },
  { key: 'autonomous_max_idle_turns', label: 'autonomous max idle turns', fmt: 'int' },
  { key: 'turn_timeout_sec', label: 'turn timeout', fmt: 'duration' },
  { key: 'admission_wait_timeout_sec', label: 'admission wait timeout', fmt: 'duration' },
  { key: 'oas_timeout_override_sec', label: 'OAS timeout override', fmt: 'duration' },
  { key: 'oas_timeout_per_1k', label: 'OAS timeout per 1k est input', fmt: 'float' },
  { key: 'oas_timeout_per_turn', label: 'OAS timeout per turn', fmt: 'duration' },
]

function sourceTone(source: string): string {
  switch (source) {
    case 'env': return 'border-[var(--color-accent-fg)]/30 bg-[var(--color-accent-fg)]/10 text-[var(--color-accent-fg)]'
    case 'toml': return 'border-[var(--emerald-28)] bg-[var(--emerald-10)] text-[var(--emerald-fg)]'
    case 'derived': return 'border-[var(--yellow-bright-28)] bg-[var(--yellow-bright-10)] text-[var(--yellow-100)]'
    default: return 'border-[var(--color-border-default)] bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]'
  }
}

function fmtKeeperValue(value: number | null, fmt: 'int' | 'float' | 'duration'): string {
  if (value === null || value === undefined) return MISSING_DATA_DASH
  switch (fmt) {
    case 'int': return String(Math.round(value))
    case 'float': return value.toFixed(1)
    case 'duration': return value >= 60 ? `${formatNumber(value / 60, 1)}m` : `${formatNumber(value, 0)}s`
  }
}

function KeeperRuntimePanel({ runtime }: { runtime: KeeperRuntimeResolved | null }) {
  if (!runtime) return null
  const tomlCount = KEEPER_RUNTIME_ROWS.filter(r => runtime[r.key]?.source === 'toml').length
  const envCount = KEEPER_RUNTIME_ROWS.filter(r => runtime[r.key]?.source === 'env').length

  return html`
    <${ConfigCard} class="mt-4 px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">keeper runtime limits</div>
        ${tomlCount > 0 ? html`
          <${StatusChip} tone=${sourceTone('toml')}>${tomlCount} TOML<//>
        ` : null}
        ${envCount > 0 ? html`
          <${StatusChip} tone=${sourceTone('env')}>${envCount} env<//>
        ` : null}
      </div>
      <div class="mb-3 text-xs text-[var(--color-fg-muted)]">
        Per-keeper runtime caps and timeouts. These values are not the live keeper count.
      </div>
      <div class="grid gap-2 md:grid-cols-2">
        ${KEEPER_RUNTIME_ROWS.map(row => {
          const field: KeeperRuntimeField<number | null> | undefined = runtime[row.key]
          if (!field) return null
          return html`
            <div class="v2-lab-row flex items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-3 py-2">
              <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.label}</div>
              <div class="flex items-center gap-2">
                <span class="font-mono text-xs text-[var(--color-fg-primary)]">${fmtKeeperValue(field.value, row.fmt)}</span>
                <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] ${sourceTone(field.source)}">${sourceLabel(field.source)}</span>
              </div>
            </div>
          `
        })}
      </div>
    <//>
  `
}

function formatShellIrApproval(
  approval: DashboardRuntimeResolution['shell_ir_approval'],
): string {
  if (!approval) return MISSING_DATA_DASH
  const trust = approval.trust === null
    ? 'unknown'
    : `${approval.trust.safe}/${approval.trust.audited}/${approval.trust.privileged}`
  return `${approval.enabled ? 'enabled' : 'disabled'} (trust: ${trust})`
}

function RuntimeTruthPanel({ runtimeResolution }: { runtimeResolution: DashboardRuntimeResolution }) {
  const fd = runtimeResolution.fd_accountant
  const fleet = runtimeResolution.fleet_safety
  const shellIr = runtimeResolution.shell_ir_approval
  const fdValue = fd
    ? `${fd.fd_open ?? MISSING_DATA_DASH} / ${fd.fd_limit ?? MISSING_DATA_DASH}`
    : MISSING_DATA_DASH
  const fdTone = fd?.pressure_active ? 'bad' : 'neutral'

  return html`
    <${ConfigCard} class="mb-4 px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">live runtime truth</div>
        <${StatusChip} tone=${toneClass(runtimeResolution.status)}>${runtimeResolution.status}<//>
        <${StatusChip} tone=${fdTone} uppercase=${false}>fd ${fdValue}<//>
      </div>
      <div class="grid gap-3 md:grid-cols-2">
        <${RuntimeMetaRow} label="effective base" value=${runtimeResolution.resolved_base_path.path ?? MISSING_DATA_DASH} />
        <${RuntimeMetaRow} label="effective .masc" value=${runtimeResolution.data_root.path ?? MISSING_DATA_DASH} />
        <${RuntimeMetaRow} label="server repo" value=${runtimeResolution.server_repo_path?.path ?? MISSING_DATA_DASH} />
        <${RuntimeMetaRow} label="executable commit" value=${runtimeResolution.build.commit ?? MISSING_DATA_DASH} />
        <${RuntimeMetaRow} label="shell IR approval" value=${formatShellIrApproval(shellIr)} />
        <${RuntimeMetaRow} label="shell IR raw" value=${shellIr?.raw_overlay ?? MISSING_DATA_DASH} />
        <${RuntimeMetaRow} label="keeper fibers" value=${String(fleet?.keeper_fibers ?? MISSING_DATA_DASH)} />
        <${RuntimeMetaRow} label="fd pressure" value=${fd?.pressure_active == null ? MISSING_DATA_DASH : fd.pressure_active ? 'active' : 'clear'} />
      </div>
    <//>
  `
}

function RuntimeProbePanel() {
  const state = useSignal<{
    data: DashboardRuntimeProbeResponse | null
    loading: boolean
    error: string | null
  }>({
    data: null,
    loading: true,
    error: null,
  })

  async function load(force = false) {
    state.value = { ...state.value, loading: true, error: null }
    try {
      const data = await fetchDashboardRuntimeProbe(force)
      state.value = { data, loading: false, error: null }
    } catch (error) {
      state.value = {
        ...state.value,
        loading: false,
        error: errorToString(error),
      }
    }
  }

  useEffect(() => {
    void load(false)
    loadRuntimeCatalog()
  }, [])

  const probe = state.value.data?.probe
  const firstRun = probe?.runs?.[0] ?? null
  const assessment = probe?.kv_cache_assessment ?? null
  const signal = assessment?.signal ?? null
  const providerProbes = probe?.providers ?? []
  const providerSummary = probe?.summary ?? null
  const isProviderProbe = providerProbes.length > 0
  const catalog = runtimeCatalogState.value
  const catalogEntries = catalog.status === 'loaded' ? catalog.data : []
  const catalogSummary = catalog.status === 'loaded'
    ? `${catalogEntries.length} runtime specs`
    : catalog.status

  return html`
    <${ConfigCard} class="mt-4 px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          ${isProviderProbe ? 'provider reachability' : 'ollama warm / kv probe'}
        </div>
        <${StatusChip} tone=${isProviderProbe ? (probe?.probe_ok === false ? 'bad' : 'ok') : probeTone(signal, probe?.probe_ok)}>
          ${isProviderProbe ? (probe?.status ?? 'provider probe') : probeSignalLabel(signal)}
        <//>
        ${state.value.data?.cache_hit !== undefined
          ? html`
              <${StatusChip} tone="neutral" uppercase=${false}>${state.value.data.cache_hit ? 'cached' : 'fresh'} · age ${formatNumber(state.value.data.cache_age_sec, 1)}s<//>
            `
          : null}
        <${Btn}
          size="sm"
          class="v2-lab-action ml-auto"
          onClick=${() => void load(true)}
        >
          ${state.value.loading ? 'probing...' : 'refresh probe'}
        <//>
      </div>

      ${state.value.error
        ? html`
            <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--rose-28)] bg-[var(--rose-10)] px-3 py-3 text-xs text-[var(--rose-fg)]">
              ${state.value.error}
            </div>
          `
        : null}

      ${!state.value.error && !probe
        ? html`
            <div class="text-xs text-[var(--color-fg-muted)]">
              ${state.value.loading ? 'runtime probe를 불러오는 중입니다.' : 'probe result가 아직 없습니다.'}
            </div>
          `
        : null}

      ${probe
        ? html`
            ${isProviderProbe
              ? html`
                  <div class="grid gap-3 md:grid-cols-2">
                    <${RuntimeMetaRow} label="status" value=${probe.status ?? MISSING_DATA_DASH} />
                    <${RuntimeMetaRow} label="checked at" value=${probe.checked_at ?? MISSING_DATA_DASH} />
                    <${RuntimeMetaRow} label="reachable" value=${String(providerSummary?.reachable ?? 0)} />
                    <${RuntimeMetaRow} label="failed" value=${String(providerSummary?.failed ?? 0)} />
                    <${RuntimeMetaRow} label="skipped" value=${String(providerSummary?.skipped ?? 0)} />
                    <${RuntimeMetaRow} label="default runtime" value=${providerSummary?.default_runtime_id ?? MISSING_DATA_DASH} />
                    <${RuntimeMetaRow} label="provider catalog" value=${catalogSummary} />
                  </div>
                  <div class="mt-3 flex flex-col gap-2">
                    ${providerProbes.map(item => {
                      const catalogEntry = runtimeProbeCatalogEntry(catalogEntries, item)
                      const catalogRows = catalogEntry ? runtimeProbeCatalogRows(catalogEntry) : []
                      return html`
                      <div class="v2-lab-row rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-3 py-2">
                        <div class="flex flex-wrap items-center justify-between gap-2">
                          <div class="min-w-0">
                            <div class="truncate text-xs font-medium text-[var(--color-fg-primary)]">${item.runtime_id ?? item.provider_id ?? '(unknown runtime)'}</div>
                            <div class="truncate text-2xs text-[var(--color-fg-muted)]">${item.probe_url ?? item.endpoint_url ?? MISSING_DATA_DASH}</div>
                          </div>
                          <div class="flex items-center gap-2">
                            <${StatusChip} tone=${providerProbeTone(item.status, item.reachable)} uppercase=${false}>${providerProbeLabel(item.status, item.reachable)}<//>
                            <span class="font-mono text-2xs text-[var(--color-fg-muted)]">${item.http_status ?? MISSING_DATA_DASH} · ${item.latency_ms == null ? MISSING_DATA_DASH : `${formatNumber(item.latency_ms, 1)}ms`}</span>
                          </div>
                        </div>
                        ${item.error
                          ? html`<div class="mt-2 text-2xs text-[var(--rose-fg)]">${item.error}</div>`
                          : null}
                        ${catalogRows.length > 0
                          ? html`
                            <div
                              class="mt-2 grid gap-1 border-t border-[var(--color-border-default)]/60 pt-2 text-2xs"
                              data-testid="runtime-probe-catalog-spec"
                            >
                              ${catalogRows.map(([label, value]) => html`
                                <div class="grid grid-cols-[5.5rem_minmax(0,1fr)] gap-2">
                                  <span class="text-[var(--color-fg-muted)]">${label}</span>
                                  <span class="min-w-0 break-words font-mono text-[var(--color-fg-secondary)]" title=${value}>${value}</span>
                                </div>
                              `)}
                            </div>
                          `
                          : html`
                            <div class="mt-2 text-2xs text-[var(--color-fg-muted)]" data-testid="runtime-probe-catalog-status">
                              ${runtimeProbeCatalogStatus(catalog, item)}
                            </div>
                          `}
                      </div>
                    `})}
                  </div>
                `
              : html`
                  <div class="grid gap-3 md:grid-cols-2">
                    <${RuntimeMetaRow} label="effective model" value=${probe.effective_model ?? MISSING_DATA_DASH} />
                    <${RuntimeMetaRow} label="server" value=${probe.server_url ?? MISSING_DATA_DASH} />
                    <${RuntimeMetaRow} label="loaded before/after" value=${`${fmtBoolean(probe.model_loaded_before_probe)} / ${fmtBoolean(probe.model_loaded_after_probe)}`} />
                    <${RuntimeMetaRow}
                      label="first run load"
                      value=${`${formatNumber(firstRun?.load_duration_ms, 1)} ms`}
                    />
                    <${RuntimeMetaRow}
                      label="prompt tok/s"
                      value=${`${formatNumber(firstRun?.prompt_tokens_per_second, 1)} tok/s`}
                    />
                    <${RuntimeMetaRow}
                      label="generation tok/s"
                      value=${`${formatNumber(firstRun?.generation_tokens_per_second, 1)} tok/s`}
                    />
                    <${RuntimeMetaRow}
                      label="prompt eval delta"
                      value=${assessment?.prompt_eval_duration_reduction_ratio != null
                        ? `${formatNumber(assessment.prompt_eval_duration_reduction_ratio * 100, 1)}%`
                        : MISSING_DATA_DASH}
                    />
                    <${RuntimeMetaRow}
                      label="loaded models"
                      value=${String(probe.loaded_models_after?.length ?? probe.loaded_models_before?.length ?? 0)}
                    />
                  </div>
                `}

            ${assessment?.note
              ? html`
                  <div class="mt-3 text-xs leading-relaxed text-[var(--color-fg-muted)]">
                    ${assessment.note}
                  </div>
                `
              : null}

            ${(probe.observations?.length ?? 0) > 0
              ? html`
                  <div class="mt-3 flex flex-col gap-2">
                    ${probe.observations?.map(item => html`
                      <div class="v2-lab-row rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-3 py-2 text-xs text-[var(--color-fg-primary)]">
                        ${item}
                      </div>
                    `)}
                  </div>
                `
              : null}

            ${(probe.errors?.length ?? 0) > 0
              ? html`
                  <div class="mt-3 flex flex-col gap-2">
                    ${probe.errors?.map(item => html`
                      <div class="v2-lab-panel rounded-[var(--r-1)] border border-[var(--rose-28)] bg-[var(--rose-10)] px-3 py-2 text-xs text-[var(--rose-fg)]">
                        ${item}
                      </div>
                    `)}
                  </div>
                `
              : null}
          `
        : null}
    <//>
  `
}

export function ConfigResolutionPanel({
  resolution,
  runtimeResolution,
}: {
  resolution: DashboardConfigResolution | undefined
  runtimeResolution?: DashboardRuntimeResolution
}) {
  const diagnosticsQuery = useSignal('')
  const allDiagnostics = runtimeResolution?.diagnostics ?? []
  const visibleDiagnostics = useMemo(
    () => filterDiagnostics(allDiagnostics, diagnosticsQuery.value),
    [allDiagnostics, diagnosticsQuery.value],
  )
  const isFilteringDiagnostics = diagnosticsQuery.value.trim() !== ''

  if (!resolution && !runtimeResolution) return null

  const rootPath = resolution?.config_root.path ?? ''
  const rootSource = resolution?.config_root.source ?? ''

  return html`
    <${SectionCard} label="설정 경로" class="section mb-4">
      ${resolution
        ? html`
            <div class="mb-6">
              <div class="mb-3 flex flex-wrap items-center gap-2">
                <${StatusChip} tone=${toneClass(resolution.status)}>${resolution.status}<//>
                <${StatusChip} tone="neutral" uppercase=${false}>${sourceLabel(resolution.config_root.source)}<//>
                <span class="text-xs text-[var(--color-fg-muted)]">resolved config root</span>
              </div>

              <${ConfigTopologySummary} resolution=${resolution} />

              <div class="mb-4">
                <${WarningBlock} title="config warnings" warnings=${resolution.warnings} />
              </div>

              <div class="grid gap-3 md:grid-cols-2">
                <${ConfigRow}
                  label="config root"
                  item=${resolution.config_root}
                  rootPath=${rootPath}
                  rootSource=${rootSource}
                  isRoot=${true}
                />
                <${ConfigRow}
                  label="prompts"
                  item=${resolution.prompts}
                  rootPath=${rootPath}
                  rootSource=${rootSource}
                />
                <${ConfigRow}
                  label="keepers"
                  item=${resolution.keepers}
                  rootPath=${rootPath}
                  rootSource=${rootSource}
                />
                <${ConfigRow}
                  label="personas"
                  item=${resolution.personas}
                  rootPath=${rootPath}
                  rootSource=${rootSource}
                />
              </div>
            </div>
          `
        : null}

      ${runtimeResolution
        ? html`
            <div>
              <div class="mb-3 flex flex-wrap items-center gap-2">
                <${StatusChip} tone=${toneClass(runtimeResolution.status)}>${runtimeResolution.status}<//>
                <span class="text-xs text-[var(--color-fg-muted)]">runtime path resolution</span>
                ${runtimeResolution.source_mismatch
                  ? html`
                      <${StatusChip} tone="bad">source mismatch<//>
                    `
                  : null}
                ${runtimeResolution.server_workspace_mismatch
                  ? html`
                      <${StatusChip} tone="warn">server/workspace mismatch<//>
                    `
                  : null}
              </div>

              <div class="mb-4">
                <${WarningBlock} title="runtime warnings" warnings=${runtimeResolution.warnings} />
              </div>

              <${RuntimeTruthPanel} runtimeResolution=${runtimeResolution} />

              <div class="grid gap-3 md:grid-cols-2">
                <${ConfigRow} label="base path" item=${runtimeResolution.base_path} />
                <${ConfigRow} label="workspace path" item=${runtimeResolution.workspace_path} />
                <${ConfigRow} label="resolved base path" item=${runtimeResolution.resolved_base_path} />
                <${ConfigRow} label="data root" item=${runtimeResolution.data_root} />
                <${ConfigRow} label="prompt markdown dir" item=${runtimeResolution.prompt_markdown_dir} />
                ${runtimeResolution.server_repo_path
                  ? html`<${ConfigRow} label="server repo" item=${runtimeResolution.server_repo_path} />`
                  : null}
              </div>

              <div class="mt-4 grid gap-3 md:grid-cols-2">
                <${RuntimeMetaRow} label="server repo head" value=${runtimeResolution.server_repo_git_commit ?? MISSING_DATA_DASH} />
                <${RuntimeMetaRow} label="workspace head" value=${runtimeResolution.workspace_git_commit ?? MISSING_DATA_DASH} />
                <${RuntimeMetaRow} label="resolved base head" value=${runtimeResolution.resolved_base_git_commit ?? MISSING_DATA_DASH} />
                <${RuntimeMetaRow} label="runtime build" value=${runtimeResolution.build.commit ?? runtimeResolution.build.release_version} />
                <${RuntimeMetaRow} label="started at" value=${runtimeResolution.build.started_at} />
              </div>

              <div class="mt-4">
                <div class="mb-2 flex items-center justify-between gap-2">
                  <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
                    recent diagnostics
                  </div>
                  ${runtimeResolution.diagnostics.length > 0
                    ? html`
                        <${TextInput}
                          type="search"
                          value=${diagnosticsQuery.value}
                          placeholder="kind / signal / message 필터"
                          ariaLabel="Diagnostics 필터"
                          onInput=${(e: Event) => { diagnosticsQuery.value = (e.target as HTMLInputElement).value }}
                          class="min-w-40 max-w-60 flex-1 !px-2 !py-1 !text-2xs"
                        />
                      `
                    : null}
                </div>
                <div class="flex flex-col gap-3">
                  ${runtimeResolution.diagnostics.length === 0
                    ? html`
                        <${ConfigCard} class="px-3 py-3 text-xs text-[var(--color-fg-muted)]">
                          최근 runtime warning이 없습니다.
                        <//>
                      `
                    : isFilteringDiagnostics && visibleDiagnostics.length === 0
                      ? html`
                          <${ConfigCard} class="px-3 py-3 text-center text-xs text-[var(--color-fg-muted)]">
                            필터 결과 없음 (${runtimeResolution.diagnostics.length} diagnostics)
                          <//>
                        `
                      : visibleDiagnostics.map(item => html`<${DiagnosticRow} item=${item} />`)}
                </div>
              </div>

              <${KeeperRuntimePanel} runtime=${runtimeResolution.keeper_runtime} />

              <${RuntimeProbePanel} />
            </div>
          `
        : null}
    <//>
  `
}

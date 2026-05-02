import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeProbeResponse,
  DashboardRuntimeResolution,
  KeeperRuntimeResolved,
  KeeperRuntimeField,
} from '../../api/dashboard'
import { fetchDashboardRuntimeProbe } from '../../api/dashboard'
import { Btn } from '../btn'
import { Card } from '../common/card'
import { StatusChip } from '../common/status-chip'
import { CopyIdButton } from '../common/copy-id-button'
import { TextInput } from '../common/input'

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
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-3)] ${cx ?? ''}" title=${title}>
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
      return 'border-[var(--color-border-default)] bg-[var(--white-6)] text-[var(--color-fg-muted)]'
  }
}

function sourceLabel(source: string): string {
  switch (source) {
    case 'env':
      return 'env override'
    case 'home_masc':
      return 'home config'
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
        <div class="text-2xs uppercase tracking-1 text-[var(--color-fg-muted)]">${label}</div>
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

function WarningBlock({
  title,
  warnings,
}: {
  title: string
  warnings: string[]
}) {
  if (warnings.length === 0) return null

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--yellow-bright-28)] bg-[var(--warn-10)] px-3 py-3">
      <div class="mb-2 text-2xs uppercase tracking-1 text-[var(--yellow-100)]">${title}</div>
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
      <div class="text-2xs uppercase tracking-1 text-[var(--color-fg-muted)]">${label}</div>
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

function fmtNumber(value: number | null | undefined, digits = 1): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '--'
  return value.toLocaleString('ko-KR', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })
}

function fmtBoolean(value: boolean | null | undefined): string {
  if (value === true) return 'yes'
  if (value === false) return 'no'
  return '--'
}

function probeTone(signal: string | null | undefined, probeOk: boolean | null | undefined): string {
  if (probeOk === false) return 'border-[var(--rose-28)] bg-[var(--rose-10)] text-[var(--rose-fg)]'
  switch (signal) {
    case 'likely_reused':
      return 'border-[var(--emerald-28)] bg-[var(--emerald-10)] text-[var(--emerald-fg)]'
    case 'possible_reuse':
      return 'border-[var(--yellow-bright-28)] bg-[var(--yellow-bright-10)] text-[var(--yellow-100)]'
    case 'no_visible_reuse':
      return 'border-[var(--color-border-default)] bg-[var(--white-6)] text-[var(--color-fg-muted)]'
    default:
      return 'border-[var(--color-border-default)] bg-[var(--white-6)] text-[var(--color-fg-muted)]'
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

const KEEPER_RUNTIME_ROWS: Array<{
  key: keyof KeeperRuntimeResolved
  label: string
  fmt: 'int' | 'float' | 'duration'
}> = [
  { key: 'bootstrap_max_active_keepers', label: 'bootstrap max active keepers', fmt: 'int' },
  { key: 'reactive_max_turns_per_call', label: 'reactive max turns/call', fmt: 'int' },
  { key: 'autonomous_max_turns_per_call', label: 'autonomous max turns/call', fmt: 'int' },
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
    default: return 'border-[var(--color-border-default)] bg-[var(--white-6)] text-[var(--color-fg-muted)]'
  }
}

function fmtKeeperValue(value: number | null, fmt: 'int' | 'float' | 'duration'): string {
  if (value === null || value === undefined) return '--'
  switch (fmt) {
    case 'int': return String(Math.round(value))
    case 'float': return value.toFixed(1)
    case 'duration': return value >= 60 ? `${fmtNumber(value / 60, 1)}m` : `${fmtNumber(value, 0)}s`
  }
}

function KeeperRuntimePanel({ runtime }: { runtime: KeeperRuntimeResolved | null }) {
  if (!runtime) return null
  const tomlCount = KEEPER_RUNTIME_ROWS.filter(r => runtime[r.key]?.source === 'toml').length
  const envCount = KEEPER_RUNTIME_ROWS.filter(r => runtime[r.key]?.source === 'env').length

  return html`
    <${ConfigCard} class="mt-4 px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div class="text-2xs uppercase tracking-1 text-[var(--color-fg-muted)]">keeper runtime limits</div>
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
            <div class="flex items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-6)] px-3 py-2">
              <div class="text-2xs uppercase tracking-1 text-[var(--color-fg-muted)]">${row.label}</div>
              <div class="flex items-center gap-2">
                <span class="font-mono text-xs text-[var(--color-fg-primary)]">${fmtKeeperValue(field.value, row.fmt)}</span>
                <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] ${sourceTone(field.source)}">${field.source}</span>
              </div>
            </div>
          `
        })}
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
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }

  useEffect(() => {
    void load(false)
  }, [])

  const probe = state.value.data?.probe
  const firstRun = probe?.runs?.[0] ?? null
  const assessment = probe?.kv_cache_assessment ?? null
  const signal = assessment?.signal ?? null

  return html`
    <${ConfigCard} class="mt-4 px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div class="text-2xs uppercase tracking-1 text-[var(--color-fg-muted)]">ollama warm / kv probe</div>
        <${StatusChip} tone=${probeTone(signal, probe?.probe_ok)}>${probeSignalLabel(signal)}<//>
        ${state.value.data?.cache_hit !== undefined
          ? html`
              <${StatusChip} tone="neutral" uppercase=${false}>${state.value.data.cache_hit ? 'cached' : 'fresh'} · age ${fmtNumber(state.value.data.cache_age_sec, 1)}s<//>
            `
          : null}
        <${Btn}
          size="sm"
          class="ml-auto"
          onClick=${() => void load(true)}
        >
          ${state.value.loading ? 'probing...' : 'refresh probe'}
        <//>
      </div>

      ${state.value.error
        ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--rose-28)] bg-[var(--rose-10)] px-3 py-3 text-xs text-[var(--rose-fg)]">
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
            <div class="grid gap-3 md:grid-cols-2">
              <${RuntimeMetaRow} label="effective model" value=${probe.effective_model ?? '--'} />
              <${RuntimeMetaRow} label="server" value=${probe.server_url ?? '--'} />
              <${RuntimeMetaRow} label="loaded before/after" value=${`${fmtBoolean(probe.model_loaded_before_probe)} / ${fmtBoolean(probe.model_loaded_after_probe)}`} />
              <${RuntimeMetaRow}
                label="first run load"
                value=${`${fmtNumber(firstRun?.load_duration_ms, 1)} ms`}
              />
              <${RuntimeMetaRow}
                label="prompt tok/s"
                value=${`${fmtNumber(firstRun?.prompt_tokens_per_second, 1)} tok/s`}
              />
              <${RuntimeMetaRow}
                label="generation tok/s"
                value=${`${fmtNumber(firstRun?.generation_tokens_per_second, 1)} tok/s`}
              />
              <${RuntimeMetaRow}
                label="prompt eval delta"
                value=${assessment?.prompt_eval_duration_reduction_ratio != null
                  ? `${fmtNumber(assessment.prompt_eval_duration_reduction_ratio * 100, 1)}%`
                  : '--'}
              />
              <${RuntimeMetaRow}
                label="loaded models"
                value=${String(probe.loaded_models_after?.length ?? probe.loaded_models_before?.length ?? 0)}
              />
            </div>

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
                      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-6)] px-3 py-2 text-xs text-[var(--color-fg-primary)]">
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
                      <div class="rounded-[var(--r-1)] border border-[var(--rose-28)] bg-[var(--rose-10)] px-3 py-2 text-xs text-[var(--rose-fg)]">
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
    <${Card} title="설정 경로" class="section mb-4">
      <div class="mb-4 text-xs leading-relaxed text-[var(--color-fg-muted)]">
        서버가 실제로 해석한 config root와 runtime/data root를 함께 보여줍니다. cascade는 human-authored cascade.toml과 runtime cascade.json을 분리해 보여주며, 현재 실행이 바라보는 경로와 체크인된 seed config는 다를 수 있습니다.
      </div>

      ${resolution
        ? html`
            <div class="mb-6">
              <div class="mb-3 flex flex-wrap items-center gap-2">
                <${StatusChip} tone=${toneClass(resolution.status)}>${resolution.status}<//>
                <${StatusChip} tone="neutral" uppercase=${false}>${sourceLabel(resolution.config_root.source)}<//>
                <span class="text-xs text-[var(--color-fg-muted)]">resolved config root</span>
              </div>

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
                  label="cascade authoring"
                  item=${resolution.cascade_authoring}
                  rootPath=${rootPath}
                  rootSource=${rootSource}
                />
                <${ConfigRow}
                  label="cascade runtime"
                  item=${resolution.cascade}
                  rootPath=${rootPath}
                  rootSource=${rootSource}
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
              </div>

              <div class="mb-4">
                <${WarningBlock} title="runtime warnings" warnings=${runtimeResolution.warnings} />
              </div>

              <div class="grid gap-3 md:grid-cols-2">
                <${ConfigRow} label="base path" item=${runtimeResolution.base_path} />
                <${ConfigRow} label="workspace path" item=${runtimeResolution.workspace_path} />
                <${ConfigRow} label="resolved base path" item=${runtimeResolution.resolved_base_path} />
                <${ConfigRow} label="data root" item=${runtimeResolution.data_root} />
                <${ConfigRow} label="prompt markdown dir" item=${runtimeResolution.prompt_markdown_dir} />
              </div>

              <div class="mt-4 grid gap-3 md:grid-cols-2">
                <${RuntimeMetaRow} label="workspace head" value=${runtimeResolution.workspace_git_commit ?? '--'} />
                <${RuntimeMetaRow} label="resolved base head" value=${runtimeResolution.resolved_base_git_commit ?? '--'} />
                <${RuntimeMetaRow} label="runtime build" value=${runtimeResolution.build.commit ?? runtimeResolution.build.release_version} />
                <${RuntimeMetaRow} label="started at" value=${runtimeResolution.build.started_at} />
              </div>

              <div class="mt-4">
                <div class="mb-2 flex items-center justify-between gap-2">
                  <div class="text-2xs uppercase tracking-1 text-[var(--color-fg-muted)]">
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

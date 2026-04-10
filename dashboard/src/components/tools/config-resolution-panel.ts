import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeProbeResponse,
  DashboardRuntimeResolution,
} from '../../api/dashboard'
import { fetchDashboardRuntimeProbe } from '../../api/dashboard'
import { Card } from '../common/card'

function toneClass(status: string): string {
  switch (status) {
    case 'ready':
      return 'border-[rgba(34,197,94,0.28)] bg-[rgba(34,197,94,0.10)] text-[#bbf7d0]'
    case 'warn':
      return 'border-[rgba(250,204,21,0.28)] bg-[rgba(250,204,21,0.10)] text-[#fde68a]'
    case 'invalid_env':
      return 'border-[rgba(244,63,94,0.28)] bg-[rgba(244,63,94,0.10)] text-[#fecdd3]'
    default:
      return 'border-[var(--card-border)] bg-[var(--white-6)] text-[var(--text-muted)]'
  }
}

function sourceLabel(source: string): string {
  switch (source) {
    case 'env':
      return 'env override'
    case 'home_masc':
      return 'home config'
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
    <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-3" title=${item.path}>
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">${label}</div>
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${toneClass(item.exists ? 'ready' : item.source === 'invalid_env' ? 'invalid_env' : 'warn')}">
          ${item.exists ? 'present' : 'missing'}
        </span>
        ${showSourceBadge
          ? html`
              <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] tracking-[0.08em] text-[var(--text-muted)]">
                ${sourceLabel(item.source)}
              </span>
            `
          : null}
        ${pathInfo.kind
          ? html`
              <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] tracking-[0.08em] text-[var(--text-muted)]">
                ${pathInfo.kind}
              </span>
            `
          : null}
      </div>
      <div class="break-all font-mono text-[12px] leading-relaxed text-[var(--text-body)]">${pathInfo.primary}</div>
      ${pathInfo.context
        ? html`
            <div class="mt-2 text-[11px] text-[var(--text-muted)]">${pathInfo.context}</div>
          `
        : null}
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
    <div class="rounded-lg border border-[rgba(250,204,21,0.28)] bg-[var(--warn-10)] px-3 py-3">
      <div class="mb-2 text-[11px] uppercase tracking-[0.08em] text-[#fde68a]">${title}</div>
      <div class="flex flex-col gap-2">
        ${warnings.map(warning => html`
          <div class="text-[12px] leading-relaxed text-[var(--text-body)]">${warning}</div>
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
    <div class="flex items-center justify-between gap-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-2">
      <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">${label}</div>
      <div class="break-all text-right font-mono text-[12px] text-[var(--text-body)]">${value}</div>
    </div>
  `
}

function DiagnosticRow({ item }: { item: DashboardRuntimeDiagnostic }) {
  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-3">
      <div class="mb-1 flex flex-wrap items-center gap-2">
        <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] text-[var(--text-muted)]">
          ${item.kind}
        </span>
        ${item.signal
          ? html`
              <span class="rounded-full border border-[rgba(250,204,21,0.28)] bg-[rgba(250,204,21,0.10)] px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] text-[#fde68a]">
                ${item.signal}
              </span>
            `
          : null}
        <span class="text-[11px] text-[var(--text-muted)]">${item.ts}</span>
      </div>
      <div class="text-[12px] leading-relaxed text-[var(--text-body)]">${item.message}</div>
    </div>
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
  if (probeOk === false) return 'border-[rgba(244,63,94,0.28)] bg-[rgba(244,63,94,0.10)] text-[#fecdd3]'
  switch (signal) {
    case 'likely_reused':
      return 'border-[rgba(34,197,94,0.28)] bg-[rgba(34,197,94,0.10)] text-[#bbf7d0]'
    case 'possible_reuse':
      return 'border-[rgba(250,204,21,0.28)] bg-[rgba(250,204,21,0.10)] text-[#fde68a]'
    case 'no_visible_reuse':
      return 'border-[var(--card-border)] bg-[var(--white-6)] text-[var(--text-muted)]'
    default:
      return 'border-[var(--card-border)] bg-[var(--white-6)] text-[var(--text-muted)]'
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
    <div class="mt-4 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">ollama warm / kv probe</div>
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${probeTone(signal, probe?.probe_ok)}">
          ${probeSignalLabel(signal)}
        </span>
        ${state.value.data?.cache_hit !== undefined
          ? html`
              <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] tracking-[0.08em] text-[var(--text-muted)]">
                ${state.value.data.cache_hit ? 'cached' : 'fresh'} · age ${fmtNumber(state.value.data.cache_age_sec, 1)}s
              </span>
            `
          : null}
        <button
          class="ml-auto rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-[11px] text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void load(true)}
        >
          ${state.value.loading ? 'probing...' : 'refresh probe'}
        </button>
      </div>

      ${state.value.error
        ? html`
            <div class="rounded-lg border border-[rgba(244,63,94,0.28)] bg-[rgba(244,63,94,0.10)] px-3 py-3 text-[12px] text-[#fecdd3]">
              ${state.value.error}
            </div>
          `
        : null}

      ${!state.value.error && !probe
        ? html`
            <div class="text-[12px] text-[var(--text-muted)]">
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
                  <div class="mt-3 text-[12px] leading-relaxed text-[var(--text-muted)]">
                    ${assessment.note}
                  </div>
                `
              : null}

            ${(probe.observations?.length ?? 0) > 0
              ? html`
                  <div class="mt-3 flex flex-col gap-2">
                    ${probe.observations?.map(item => html`
                      <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-6)] px-3 py-2 text-[12px] text-[var(--text-body)]">
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
                      <div class="rounded-lg border border-[rgba(244,63,94,0.28)] bg-[rgba(244,63,94,0.10)] px-3 py-2 text-[12px] text-[#fecdd3]">
                        ${item}
                      </div>
                    `)}
                  </div>
                `
              : null}
          `
        : null}
    </div>
  `
}

export function ConfigResolutionPanel({
  resolution,
  runtimeResolution,
}: {
  resolution: DashboardConfigResolution | undefined
  runtimeResolution?: DashboardRuntimeResolution
}) {
  if (!resolution && !runtimeResolution) return null

  const rootPath = resolution?.config_root.path ?? ''
  const rootSource = resolution?.config_root.source ?? ''

  return html`
    <${Card} title="설정 경로" class="section mb-4">
      <div class="mb-4 text-[12px] leading-relaxed text-[var(--text-muted)]">
        repo-managed config root와 실제 runtime/data root를 함께 보여줍니다. 실행 중인 서버가 어떤 worktree와 경로를 보고 있는지 바로 비교할 수 있습니다.
      </div>

      ${resolution
        ? html`
            <div class="mb-6">
              <div class="mb-3 flex flex-wrap items-center gap-2">
                <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${toneClass(resolution.status)}">
                  ${resolution.status}
                </span>
                <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">
                  ${sourceLabel(resolution.config_root.source)}
                </span>
                <span class="text-[12px] text-[var(--text-muted)]">repo-managed config root</span>
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
                  label="cascade"
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
                <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${toneClass(runtimeResolution.status)}">
                  ${runtimeResolution.status}
                </span>
                <span class="text-[12px] text-[var(--text-muted)]">runtime path resolution</span>
                ${runtimeResolution.source_mismatch
                  ? html`
                      <span class="rounded-full border border-[rgba(244,63,94,0.28)] bg-[rgba(244,63,94,0.10)] px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] text-[#fecdd3]">
                        source mismatch
                      </span>
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
                <div class="mb-2 text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">
                  recent diagnostics
                </div>
                <div class="flex flex-col gap-3">
                  ${runtimeResolution.diagnostics.length > 0
                    ? runtimeResolution.diagnostics.map(item => html`<${DiagnosticRow} item=${item} />`)
                    : html`
                        <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-3 text-[12px] text-[var(--text-muted)]">
                          최근 runtime warning이 없습니다.
                        </div>
                      `}
                </div>
              </div>

              <${RuntimeProbePanel} />
            </div>
          `
        : null}
    <//>
  `
}

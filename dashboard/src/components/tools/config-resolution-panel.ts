import { html } from 'htm/preact'
import type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeResolution,
} from '../../api/dashboard'
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
            </div>
          `
        : null}
    <//>
  `
}

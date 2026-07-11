import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'

import { fetchKeeperSandboxStatus } from '../api/dashboard-keeper-sandbox'
import type {
  KeeperSandboxEffectiveMode,
  KeeperSandboxStatus,
  KeeperSandboxStatusResponse,
} from '../api/schemas/keeper-sandbox-status'
import { ActionButton } from './common/button'
import { ErrorState, LoadingState } from './common/feedback-state'
import { PanelCard } from './common/panel-card'
import { StatusChip, type StatusChipTone } from './common/status-chip'

type SandboxLoadState =
  | { status: 'loading' }
  | { status: 'ready'; sandbox: KeeperSandboxStatus; observedAt: string }
  | { status: 'error'; message: string }

interface EffectiveModeView {
  label: string
  tone: StatusChipTone
  description: string
}

function unreachable(value: never): never {
  throw new Error(`unhandled keeper sandbox mode: ${String(value)}`)
}

export function effectiveModeView(mode: KeeperSandboxEffectiveMode): EffectiveModeView {
  switch (mode) {
    case 'local':
      return {
        label: 'local host',
        tone: 'warn',
        description: 'Host process execution. Command/path gates apply, but this is not OS namespace isolation.',
      }
    case 'docker_idle':
      return {
        label: 'docker idle',
        tone: 'ok',
        description: 'Healthy on-demand mode. No container exists until a sandboxed turn or tool call starts.',
      }
    case 'docker_active':
      return {
        label: 'docker active',
        tone: 'info',
        description: 'One or more on-demand turn/oneshot containers are currently observable.',
      }
    case 'docker_listing_failed':
      return {
        label: 'docker check failed',
        tone: 'bad',
        description: 'Container state could not be read. This is not an idle state.',
      }
    default:
      return unreachable(mode)
  }
}

function networkDescription(mode: KeeperSandboxStatus['configured_network_mode']): string {
  switch (mode) {
    case 'none':
      return 'none · Docker network disabled'
    case 'host':
      return 'host · Docker --network host'
    default:
      return unreachable(mode)
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'keeper sandbox status failed'
}

function formatObservedAt(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString()
}

function formatOptionalNumber(value: number | null, suffix = ''): string {
  return value == null ? 'not reported' : `${value}${suffix}`
}

function credentialBoundaryDescription(boundary: KeeperSandboxStatus['security_boundary']['credential_boundary']): string {
  switch (boundary) {
    case 'managed_home_projection':
      return 'default-deny env · BasePath-owned HOME/XDG · explicit projection'
    case 'ephemeral_container_projection':
      return 'ephemeral env-file · explicit read-only mounts'
    default:
      return unreachable(boundary)
  }
}

function filesystemBoundaryDescription(boundary: KeeperSandboxStatus['security_boundary']['filesystem_boundary']): string {
  switch (boundary) {
    case 'host_filesystem_tool_policy':
      return 'host filesystem · tool/path policy only (no namespace isolation)'
    case 'explicit_container_mounts':
      return 'container namespace · explicit host mounts only'
    default:
      return unreachable(boundary)
  }
}

function dockerHardeningDescription(boundary: KeeperSandboxStatus['security_boundary']): string {
  if (boundary.execution_boundary === 'host_process') return 'not applicable to host process'
  return [
    `read-only rootfs=${String(boundary.rootfs_read_only)}`,
    `cap-drop-all=${String(boundary.cap_drop_all)}`,
    `no-new-privileges=${String(boundary.no_new_privileges)}`,
  ].join(' · ')
}

function networkBoundaryDescription(boundary: KeeperSandboxStatus['security_boundary']['network_boundary']): string {
  switch (boundary) {
    case 'host_network_namespace':
      return 'host network namespace'
    case 'isolated_network_namespace':
      return 'isolated · loopback only'
    default:
      return unreachable(boundary)
  }
}

function SandboxFact({ label, value }: { label: string; value: string }) {
  return html`
    <div class="flex min-w-0 items-start justify-between gap-3 border-b border-[var(--color-border-subtle)] py-2 last:border-b-0">
      <span class="text-xs text-[var(--color-fg-muted)]">${label}</span>
      <span class="min-w-0 break-all text-right font-mono text-xs text-[var(--color-fg-secondary)]">${value}</span>
    </div>
  `
}

function SandboxReadyView({ sandbox, observedAt }: { sandbox: KeeperSandboxStatus; observedAt: string }) {
  const mode = effectiveModeView(sandbox.effective_mode)
  const preflight = sandbox.preflight
  const security = sandbox.security_boundary

  return html`
    <div data-testid="keeper-sandbox-status" class="flex flex-col gap-3">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <${StatusChip} tone=${mode.tone} uppercase=${false}>${mode.label}<//>
            <span class="text-xs text-[var(--color-fg-muted)]">관측 ${formatObservedAt(observedAt)}</span>
          </div>
          <p class="mt-2 text-xs leading-relaxed text-[var(--color-fg-secondary)]">${mode.description}</p>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-x-5 md:grid-cols-2">
        <div>
          <${SandboxFact} label="configured profile" value=${sandbox.sandbox_profile} />
          <${SandboxFact} label="configured network" value=${networkDescription(sandbox.configured_network_mode)} />
          <${SandboxFact} label="effective network boundary" value=${networkBoundaryDescription(security.network_boundary)} />
        </div>
        <div>
          <${SandboxFact} label="active containers" value=${String(sandbox.container_count)} />
          <${SandboxFact} label="filesystem boundary" value=${filesystemBoundaryDescription(security.filesystem_boundary)} />
          <${SandboxFact} label="credential boundary" value=${credentialBoundaryDescription(security.credential_boundary)} />
          <${SandboxFact} label="Docker hardening" value=${dockerHardeningDescription(security)} />
        </div>
      </div>

      ${sandbox.container_error ? html`<${ErrorState} message=${sandbox.container_error} />` : null}

      ${sandbox.containers.length > 0 ? html`
        <div class="overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-subtle)]">
          <table class="w-full min-w-[760px] text-left text-xs">
            <thead class="bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]">
              <tr>
                <th class="px-3 py-2 font-medium">kind</th>
                <th class="px-3 py-2 font-medium">container</th>
                <th class="px-3 py-2 font-medium">image</th>
                <th class="px-3 py-2 font-medium">network</th>
                <th class="px-3 py-2 font-medium">running</th>
                <th class="px-3 py-2 font-medium">owner / TTL</th>
              </tr>
            </thead>
            <tbody>
              ${sandbox.containers.map(container => html`
                <tr class="border-t border-[var(--color-border-subtle)] text-[var(--color-fg-secondary)]">
                  <td class="px-3 py-2 font-mono">${container.container_kind ?? 'not reported'}</td>
                  <td class="px-3 py-2 font-mono" title=${container.id}>${container.name}</td>
                  <td class="px-3 py-2 font-mono">${container.image}</td>
                  <td class="px-3 py-2 font-mono">${container.network_label ?? 'not reported'}</td>
                  <td class="px-3 py-2">${container.running == null ? 'not reported' : String(container.running)}</td>
                  <td class="px-3 py-2 font-mono">pid ${formatOptionalNumber(container.owner_pid)} · ${formatOptionalNumber(container.ttl_sec, 's')}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      ` : null}

      <div class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)]">
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--color-border-subtle)] px-3 py-2">
          <span class="text-xs font-semibold text-[var(--color-fg-primary)]">Playground repositories</span>
          <span class="font-mono text-3xs text-[var(--color-fg-muted)]">
            ${sandbox.playground_repos_source} · ${sandbox.playground_repos.length}
          </span>
        </div>
        ${sandbox.playground_repos_error ? html`
          <div class="p-3">
            <${ErrorState} message=${sandbox.playground_repos_error} />
          </div>
        ` : null}
        ${sandbox.playground_repos.length === 0 && sandbox.playground_repos_error == null ? html`
          <div class="px-3 py-3 text-xs text-[var(--color-fg-muted)]">관측된 repository가 없습니다.</div>
        ` : null}
        ${sandbox.playground_repos.length > 0 ? html`
          <div class="overflow-x-auto">
            <table class="w-full min-w-[840px] text-left text-xs">
              <thead class="bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]">
                <tr>
                  <th class="px-3 py-2 font-medium">repository / path</th>
                  <th class="px-3 py-2 font-medium">observation</th>
                  <th class="px-3 py-2 font-medium">policy</th>
                  <th class="px-3 py-2 font-medium">policy source</th>
                  <th class="px-3 py-2 font-medium">reason / error</th>
                </tr>
              </thead>
              <tbody>
                ${sandbox.playground_repos.map(repo => html`
                  <tr class="border-t border-[var(--color-border-subtle)] text-[var(--color-fg-secondary)]">
                    <td class="px-3 py-2">
                      <div class="font-medium">${repo.name}</div>
                      <div class="font-mono text-3xs text-[var(--color-fg-muted)]">${repo.path}</div>
                    </td>
                    <td class="px-3 py-2 font-mono">${repo.source}</td>
                    <td class="px-3 py-2">
                      <${StatusChip} tone=${repo.policy_allowed ? 'ok' : 'bad'} uppercase=${false}>
                        ${repo.policy_status}
                      <//>
                    </td>
                    <td class="px-3 py-2 font-mono">${repo.policy_source}</td>
                    <td class="px-3 py-2 text-[var(--color-fg-muted)]">
                      ${repo.error ?? repo.policy_reason ?? 'none'}
                    </td>
                  </tr>
                `)}
              </tbody>
            </table>
          </div>
        ` : null}
      </div>

      ${preflight ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] p-3">
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="text-xs font-semibold text-[var(--color-fg-primary)]">Docker preflight</span>
            <${StatusChip} tone=${preflight.ok ? 'ok' : 'bad'} uppercase=${false}>
              ${preflight.ok ? 'ready' : 'failed'}
            <//>
          </div>
          <div class="grid grid-cols-1 gap-x-5 md:grid-cols-2">
            <div>
              <${SandboxFact} label="image" value=${preflight.image} />
              <${SandboxFact} label="daemon" value=${preflight.docker_runtime_ok ? 'ok' : (preflight.docker_runtime_error ?? 'failed')} />
            </div>
            <div>
              <${SandboxFact} label="hardening" value=${preflight.hardening_ok ? 'ok' : (preflight.hardening_error ?? 'failed')} />
              <${SandboxFact} label="missing commands" value=${preflight.missing_commands.join(', ') || 'none'} />
            </div>
          </div>
          ${preflight.next_actions.length > 0 ? html`
            <ul class="mt-3 list-disc space-y-1 pl-5 text-xs text-[var(--color-status-warn)]">
              ${preflight.next_actions.map(action => html`<li>${action}</li>`)}
            </ul>
          ` : null}
        </div>
      ` : null}

      ${sandbox.recommendation ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-subtle)] px-3 py-2 text-xs text-[var(--color-fg-muted)]">
          ${sandbox.recommendation}
        </div>
      ` : null}
    </div>
  `
}

export interface KeeperSandboxPanelProps {
  keeperName: string
  fetchStatus?: (keeperName: string) => Promise<KeeperSandboxStatusResponse>
}

export function KeeperSandboxPanel({
  keeperName,
  fetchStatus = fetchKeeperSandboxStatus,
}: KeeperSandboxPanelProps) {
  const [state, setState] = useState<SandboxLoadState>({ status: 'loading' })

  async function load(active: () => boolean = () => true) {
    setState({ status: 'loading' })
    try {
      const response = await fetchStatus(keeperName)
      if (!active()) return
      setState({
        status: 'ready',
        sandbox: response.sandbox,
        observedAt: new Date().toISOString(),
      })
    } catch (error) {
      if (!active()) return
      setState({ status: 'error', message: errorMessage(error) })
    }
  }

  useEffect(() => {
    let mounted = true
    void load(() => mounted)
    return () => {
      mounted = false
    }
  }, [keeperName, fetchStatus])

  return html`
    <${PanelCard} title="실행 격리 · 샌드박스">
      <div class="mb-3 flex justify-end">
        <${ActionButton}
          variant="ghost"
          size="sm"
          disabled=${state.status === 'loading'}
          ariaBusy=${state.status === 'loading'}
          testId="keeper-sandbox-refresh"
          onClick=${() => { void load() }}
        >
          ${state.status === 'loading' ? '조회 중' : '새로고침'}
        <//>
      </div>
      ${state.status === 'loading' ? html`<${LoadingState}>샌드박스 실측 상태 조회 중<//>` : null}
      ${state.status === 'error' ? html`
        <div class="flex flex-col gap-3" data-testid="keeper-sandbox-error">
          <${ErrorState} message=${state.message} />
          <p class="text-xs text-[var(--color-fg-muted)]">설정값을 idle 상태로 대체하지 않았습니다. 명시적으로 다시 조회하세요.</p>
        </div>
      ` : null}
      ${state.status === 'ready' ? html`
        <${SandboxReadyView} sandbox=${state.sandbox} observedAt=${state.observedAt} />
      ` : null}
    <//>
  `
}

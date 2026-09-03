import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchKeeperSandboxLiveStatus,
  type KeeperSandboxLiveStatus,
} from '../api/keeper'
import { DEFAULT_PANEL_REFRESH_MS, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { errorMessageOr } from '../lib/format-string'
import { sandboxContainerCli } from '../types'
import { DetailCard, DetailRow, MutedSpan } from './keeper-detail-kpi'

type LoadState =
  | { kind: 'loading' }
  | { kind: 'ready'; value: KeeperSandboxLiveStatus }
  | { kind: 'error'; detail: string }

const notReported = '(not reported)'

function valueOf(value: string | null): string {
  return value ?? notReported
}

function ContainerRows({ status }: { status: KeeperSandboxLiveStatus }) {
  if (status.containers === null) {
    return html`<${MutedSpan}>컨테이너 관측값을 받지 못했습니다.</${MutedSpan}>`
  }
  if (status.containers.length === 0) {
    return html`<${MutedSpan}>실행 중인 관리 컨테이너가 없습니다.</${MutedSpan}>`
  }
  // The CLI comes from the profile table, not from a two-way test. Asking
  // "is it microvm?" and answering "docker" otherwise handed a remote_ssh
  // keeper a `docker logs -f` line for a container docker does not hold.
  // remote_ssh maps to null here, and so does a profile this bundle cannot
  // name — in both cases the row shows the id and no command to copy.
  const logCli = sandboxContainerCli(status.sandbox_profile)
  return html`
    <div class="flex flex-col gap-2">
      ${status.containers.map(container => html`
        <div key=${container.id} class="rounded-[var(--r-1)] border border-[var(--color-border-divider)] p-2 text-2xs">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class=${container.running === true ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-warn)]'}>
              ${container.running === true ? '● running' : '● stopped'}
            </span>
            <code class="font-mono">${container.name}</code>
            ${container.container_kind ? html`<span class="text-[var(--color-fg-muted)]">${container.container_kind}</span>` : null}
          </div>
          <div class="mt-1 break-all font-mono text-3xs text-[var(--color-fg-muted)]">
            ${container.id} · ${container.image}
          </div>
          <div class="mt-1 text-3xs text-[var(--color-fg-muted)]">${container.status}</div>
          ${logCli === null ? null : html`
            <div class="mt-2 rounded bg-[var(--color-bg-raised)] px-2 py-1 font-mono text-3xs" aria-label="container log command">
              ${logCli} logs -f ${container.id}
            </div>
          `}
        </div>
      `)}
    </div>
  `
}

export function KeeperSandboxLivePanel({ keeperName }: { keeperName: string }) {
  const [state, setState] = useState<LoadState>({ kind: 'loading' })

  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    const refresh = async () => {
      try {
        const value = await fetchKeeperSandboxLiveStatus(keeperName, { signal: controller.signal })
        if (!cancelled && !controller.signal.aborted) setState({ kind: 'ready', value })
      } catch (error) {
        if (!cancelled && !controller.signal.aborted) {
          setState({ kind: 'error', detail: errorMessageOr(error, 'sandbox status load failed') })
        }
      }
    }
    void refresh()
    const cleanup = setupVisibleAutoRefresh(refresh, DEFAULT_PANEL_REFRESH_MS)
    return () => {
      cancelled = true
      controller.abort()
      cleanup()
    }
  }, [keeperName])

  if (state.kind === 'loading') {
    return html`<${DetailCard}><${MutedSpan}>Sandbox 관측값을 불러오는 중입니다…</${MutedSpan}><//>`
  }
  if (state.kind === 'error') {
    return html`<${DetailCard}><span class="text-2xs text-[var(--color-status-err)]">Sandbox 관측 실패: ${state.detail}</span><//>`
  }
  const status = state.value
  return html`
    <${DetailCard}>
      <div class="mb-2 text-2xs font-semibold">Sandbox / Container</div>
      <div class="mb-3 grid grid-cols-1 gap-x-4 gap-y-1 sm:grid-cols-2">
        <${DetailRow}><span>프로필</span><code>${valueOf(status.sandbox_profile)}</code><//>
        <${DetailRow}><span>실행 모드</span><code>${valueOf(status.effective_mode)}</code><//>
        <${DetailRow}><span>네트워크</span><code>${valueOf(status.configured_network_mode)}</code><//>
        <${DetailRow}><span>관리 kind</span><code>${valueOf(status.managed_container_kind)}</code><//>
      </div>
      <${ContainerRows} status=${status} />
      ${status.why_no_container ? html`<div class="mt-2 text-3xs text-[var(--color-fg-muted)]">${status.why_no_container}</div>` : null}
      ${status.container_error ? html`<div class="mt-2 text-3xs text-[var(--color-status-err)]">Container 오류: ${status.container_error}</div>` : null}
      ${status.keeper_last_error ? html`<div class="mt-2 text-3xs text-[var(--color-status-err)]">Keeper 최근 오류: ${status.keeper_last_error}</div>` : null}
    <//>
  `
}

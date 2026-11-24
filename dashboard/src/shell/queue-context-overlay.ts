/**
 * `⌘T` Queue & Context Read-Only Quick-Peek Content.
 *
 * Rendered inside the single shell-hosted `QuickPeekDrawer` (`[⤢]` wide expand).
 * Strictly read-only — links to `/work/inbox` or `/keepers` for actions.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect } from 'preact/hooks'
import { isAuthenticated } from '../core/auth'
import { formatObserved, resourceCache } from '../core/resource-cache'
import { apiGet } from '../core/transport'
import { navigate } from '../routes/router'
import {
  closeActiveOverlay,
  pendingApprovals,
  pendingAsks,
  refreshPendingHitl,
} from './shell-state'

interface ShellQueueSummary {
  readonly keepers: number | null
  readonly tasks: number | null
  readonly agents: number | null
  readonly pendingApprovals: number
  readonly pendingAsks: number
}

const SHELL_CACHE_KEY = 'shell:queue-context'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asNumberOrNull(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function decodeShellSummary(raw: unknown): ShellQueueSummary {
  const counts = isRecord(raw) && isRecord(raw.counts) ? raw.counts : null
  return {
    keepers: asNumberOrNull(counts?.keepers),
    tasks: asNumberOrNull(counts?.tasks),
    agents: asNumberOrNull(counts?.agents),
    pendingApprovals: pendingApprovals.peek().length,
    pendingAsks: pendingAsks.peek().length,
  }
}

export function QueueContextOverlayBody(): VNode {
  const authed = isAuthenticated.value
  const approvals = pendingApprovals.value
  const asks = pendingAsks.value
  const observed = resourceCache.observe<ShellQueueSummary>(SHELL_CACHE_KEY).value

  useEffect(() => {
    if (!authed) return
    void resourceCache.fetch(
      SHELL_CACHE_KEY,
      (signal) => apiGet<ShellQueueSummary>('/api/v1/dashboard/shell', {
        signal,
        decode: decodeShellSummary,
      }),
      { ttlMs: 10_000, topics: ['workspace_dataset_changed', 'keeper_heartbeat'], reason: 'mount' },
    )
    void refreshPendingHitl()
  }, [authed])

  const formatMetric = (value: number | null | undefined): string => {
    if (observed.kind !== 'value') return formatObserved(observed)
    return value === null || value === undefined ? '미보고' : String(value)
  }

  return html`
    <div class="ap-qpeek-stack" data-testid="queue-context-overlay">
      <div class="ap-qpeek-banner">
        Read-Only Queue & Context Quick-Peek — mutations live in Unified Inbox & Keepers.
      </div>

      ${!authed
        ? html`<p class="ap-muted">인증 후 활성 큐와 컨텍스트 요약을 표시합니다.</p>`
        : html`
            <div class="ap-mini-kpis">
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Keepers</span>
                <strong class="ap-mini-kpi-v tnum">${formatMetric(observed.kind === 'value' ? observed.data.keepers : null)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Tasks</span>
                <strong class="ap-mini-kpi-v tnum">${formatMetric(observed.kind === 'value' ? observed.data.tasks : null)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Approvals</span>
                <strong class="ap-mini-kpi-v tnum">${String(approvals.length)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Asks</span>
                <strong class="ap-mini-kpi-v tnum">${String(asks.length)}</strong>
              </div>
            </div>

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Pending Tool Approvals (${approvals.length})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => { closeActiveOverlay(); navigate('/work/inbox') }}
                >
                  Open Inbox →
                </button>
              </header>
              ${approvals.length === 0
                ? html`<p class="ap-muted">대기 중인 도구 승인 요청이 없습니다.</p>`
                : html`
                    <ul class="ap-qpeek-list">
                      ${approvals.map((item) => html`
                        <li key=${item.approvalId} class="ap-qpeek-card">
                          <div class="ap-qpeek-card-top">
                            <strong>${item.keeper}</strong>
                            <code class="mono">${item.tool || item.toolCallId}</code>
                          </div>
                          ${item.question && html`<p class="ap-qpeek-card-text">${item.question}</p>`}
                          <div class="ap-qpeek-card-meta mono">
                            req=${item.approvalId} · rev=${item.revision}
                          </div>
                        </li>
                      `)}
                    </ul>
                  `}
            </section>

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Open Keeper Asks (${asks.length})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => { closeActiveOverlay(); navigate('/keepers') }}
                >
                  Open Keepers →
                </button>
              </header>
              ${asks.length === 0
                ? html`<p class="ap-muted">대기 중인 Keeper 질문이 없습니다.</p>`
                : html`
                    <ul class="ap-qpeek-list">
                      ${asks.map((ask) => html`
                        <li key=${ask.askId} class="ap-qpeek-card">
                          <div class="ap-qpeek-card-top">
                            <strong>${ask.keeper}</strong>
                            <span class="mono ap-muted">${ask.askId}</span>
                          </div>
                          <p class="ap-qpeek-card-text">${ask.prompt}</p>
                        </li>
                      `)}
                    </ul>
                  `}
            </section>
          `}
    </div>
  `
}

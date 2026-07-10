import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { AlertTriangle } from 'lucide-preact'
import { useEffect, useMemo } from 'preact/hooks'
import type { GovernanceJudgeSummary, KeeperApprovalQueueItem, KeeperApprovalRule } from '../types'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { SECONDS_PER_DAY } from '../lib/format-time'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { SectionCard } from './common/card'
import type { KpiCellKind } from './kpi-shared'
import { KpiStripView, type KpiStripViewData } from './kpi-strip-view'
import { EmptyState } from './common/feedback-state'
import { StatusDot } from './common/status-dot'
import { JsonViewerCard } from './common/json-viewer'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { TimeAgo } from './common/time-ago'
import {
  isHighOrCriticalKeeperApprovalRisk,
  keeperApprovalRiskVisualBand,
  maxKeeperApprovalRiskLevel,
} from '../lib/governance-risk-level'
import {
  governanceData,
  governanceError,
  governanceLoading,
  governanceApprovalActing,
  deleteKeeperApprovalRule,
  refreshGovernance,
  respondToKeeperApproval,
} from './governance-store'
import { formatAgeSummary } from './governance-utils'

function MetaTag({ children, mono = false }: { children: unknown; mono?: boolean }) {
  const cls = `rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-text-muted${mono ? ' font-mono' : ''}`
  return html`<span class=${cls}>${children}</span>`
}

function judgeRuntimeStatus(
  judge?: GovernanceJudgeSummary,
  summary?: { judge_online?: boolean },
): string {
  const status = judge?.status?.trim()
  if (status) return status
  if (judge?.refreshing) return 'refreshing'
  const online = judge?.judge_online ?? summary?.judge_online
  return online === true ? 'online' : 'offline'
}

function judgeStatusLabel(status: string, judge?: GovernanceJudgeSummary): string {
  switch (status) {
    case 'online':
      return 'Online'
    case 'refreshing':
      return 'Refreshing'
    case 'stale_visible':
      return 'Using cache'
    case 'backoff':
      return 'backoff'
    case 'offline':
      return judge?.last_error ? 'Error' : 'Offline'
    default:
      return status
  }
}

function degradedReasonLabel(reason?: string | null): string {
  switch (reason) {
    case 'timeout':
      return 'timeout'
    case 'error':
      return 'error'
    case 'backoff':
      return 'backoff'
    default:
      return reason?.trim() || '(unknown reason)'
  }
}

function GovernanceSummaryStrip() {
  const data = governanceData.value
  const summary = data?.summary
  const judge = data?.judge
  const oldestAge = summary?.oldest_open_case_age_s
  const lastActivityAge = summary?.last_activity_age_s
  const isStale = (oldestAge != null && oldestAge > SECONDS_PER_DAY) || (lastActivityAge != null && lastActivityAge > SECONDS_PER_DAY)
  const judgmentCount = data?.judgments?.length ?? 0
  const approvalCount = data?.approval_queue?.length ?? summary?.needs_human_gate ?? 0
  const judgeOnlyLabel =
    approvalCount > 0
      ? `judge-only / ${judgmentCount} recent judgments / ${approvalCount} approvals`
      : `judge-only / ${judgmentCount} recent judgments`
  const status = judgeRuntimeStatus(judge, summary)
  const liveJudgeState = judgeStatusLabel(status, judge)
  const liveJudgeRuntime = judge?.keeper_name?.trim() || '-'
  const judgeHealthy = status === 'online' || status === 'refreshing'
  const judgeUnhealthy = status === 'offline' || status === 'stale_visible' || status === 'backoff'

  return html`
    ${isStale ? html`
      <div class="v2-command-panel mb-3.5 flex items-center gap-3 rounded-[var(--r-1)] border border-warn/30 bg-warn/10 p-3.5 text-sm font-medium text-warn shadow-[var(--shadow-1)]">
        <div class="shrink-0"><${AlertTriangle} size=${18} aria-hidden="true" /></div>
        <div>
          All open cases are older than ${formatAgeSummary(oldestAge)}.
          ${lastActivityAge != null ? html` Last activity: ${formatAgeSummary(lastActivityAge)} ago.` : null}
          <span class="opacity-80 ml-1">Likely leftover test data.</span>
        </div>
      </div>
    ` : null}
    <div class="v2-command-toolbar mb-2.5 flex items-center justify-between gap-3 px-0.5">
      <div class="flex items-center gap-3 min-w-0">
        <h2 class="text-lg font-bold text-text-strong tracking-wide">Live Judgment</h2>
        <span class="rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs font-medium text-text-muted">
          ${judgeOnlyLabel}
        </span>
      </div>
      <div class="flex items-center gap-3 shrink-0">
        ${data?.generated_at ? html`<span class="text-2xs text-text-dim font-mono">${data.generated_at}</span>` : null}
        <span class="text-2xs text-text-dim">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        <${ActionButton}
          variant="ghost"
          size="sm"
          class="v2-command-action rounded-[var(--r-1)] border-transparent bg-[var(--color-bg-surface)] px-2.5 py-1 text-xs font-semibold text-text-muted hover:bg-[var(--color-bg-hover)] hover:text-text-strong"
          onClick=${refreshGovernance}
          disabled=${governanceLoading.value}
        >
          ${governanceLoading.value ? 'Refreshing...' : 'Refresh'}
        <//>
      </div>
    </div>
    <div class="v2-command-panel mb-5">
      <${KpiStripView}
        ariaLabel="Governance summary"
        cols=${4}
        cells=${[
          {
            variant: 'stacked',
            label: 'Judge Status',
            value: liveJudgeState,
            caption: judge?.keeper_name?.trim() || 'live judge',
            kind: (judgeUnhealthy ? 'warn' : (judgeHealthy ? 'ok' : undefined)) as KpiCellKind | undefined,
          },
          {
            variant: 'stacked',
            label: 'Judge Runtime',
            value: liveJudgeRuntime,
            caption: 'keeper',
          },
          {
            variant: 'stacked',
            label: 'Recent Judgments',
            value: judgmentCount,
            caption: 'live',
          },
          {
            variant: 'stacked',
            label: 'Admin Queue',
            value: approvalCount,
            caption: approvalCount > 0 ? 'review needed' : (judgeHealthy ? 'healthy' : 'live'),
            kind: (approvalCount > 0 ? 'warn' : (judgeHealthy ? 'ok' : undefined)) as KpiCellKind | undefined,
          },
        ] satisfies KpiStripViewData['cells']}
      />
    </div>
    <${JudgeStatusBar} />
    ${governanceError.value ? html`<div class="v2-command-panel mb-5 rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-8)] p-2.5 text-xs text-[var(--rose-light)]">${governanceError.value}</div>` : null}
  `
}

function JudgeStatusBar() {
  const judge = governanceData.value?.judge
  if (!judge) return null
  const status = judgeRuntimeStatus(judge, governanceData.value?.summary)
  const dotClass =
    status === 'online' || status === 'refreshing'
      ? 'bg-ok'
      : status === 'stale_visible' || status === 'backoff'
        ? 'bg-warn'
        : 'bg-text-dim'
  const label = judgeStatusLabel(status, judge)
  const errorTone = status === 'stale_visible' || status === 'backoff'
    ? 'text-warn'
    : 'text-bad/80'
  return html`
    <div class="v2-command-panel mb-4 flex items-center gap-3 rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-surface)] px-3.5 py-2 text-xs" data-testid="judge-status">
      <span class="flex items-center gap-1.5">
        <${StatusDot} size="sm" class=${dotClass} />
        <span class="font-medium text-text-muted">Judge runtime ${label}</span>
      </span>
      ${judge.generated_at || judge.last_error
        ? html`
            <span class="ml-auto flex items-center gap-3 min-w-0">
              ${judge.generated_at
                ? html`<span class="text-text-dim"><${TimeAgo} timestamp=${judge.generated_at} /></span>`
                : null}
              ${judge.last_error
                ? html`<span class="${errorTone} truncate max-w-75">${judge.last_error}</span>`
                : null}
            </span>
          `
        : null}
    </div>
  `
}

function judgmentsEmptyStateMessage(): { message: string; tone: 'warn' | 'default' } {
  const judge = governanceData.value?.judge
  const summary = governanceData.value?.summary
  const status = judgeRuntimeStatus(judge, summary)
  if (status === 'stale_visible') {
    return {
      message: `AI Judge is holding the fresh-judgment cache after ${degradedReasonLabel(judge?.degraded_reason)}. New judgments refresh after recovery.`,
      tone: 'warn',
    }
  }
  if (status === 'backoff') {
    return { message: 'AI Judge backoff: local slots are saturated. New judgments resume after a local slot opens.', tone: 'warn' }
  }
  const lastError = judge?.last_error?.trim()
  if (lastError) {
    return { message: `AI Judge error: ${lastError}`, tone: 'warn' }
  }
  if (status === 'offline') {
    return { message: 'AI Judge is offline. Check whether the keeper is running.', tone: 'warn' }
  }
  const lastSeen = judge?.generated_at ?? summary?.judge_last_seen_at
  if (lastSeen) {
    return { message: 'Waiting for new input after the latest judgment. New keeper judgments appear here.', tone: 'default' }
  }
  return { message: 'AI Judge judgments appear here automatically. No judgments have been collected yet.', tone: 'default' }
}

function JudgmentsSection() {
  const judgments = governanceData.value?.judgments ?? []
  const title = 'AI Judge Judgments'

  if (judgments.length === 0) {
    const { message, tone } = judgmentsEmptyStateMessage()
    const judge = governanceData.value?.judge
    const lastSeen = judge?.generated_at ?? governanceData.value?.summary?.judge_last_seen_at
    const meta = [judge?.keeper_name].filter((value): value is string => typeof value === 'string' && value.length > 0).join(' · ')
    const chipClass = tone === 'warn'
      ? 'border-warn/30 bg-warn/10 text-warn'
      : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-text-muted'
    return html`
      <div class="v2-command-panel" data-testid="live-judge-empty">
        <${SectionCard} label=${title} class="section mb-5 v2-command-panel" variant="compact">
          <${EmptyState} message=${message} compact />
          ${lastSeen || meta ? html`
            <div class="mt-1 flex flex-wrap items-center justify-center gap-2 text-2xs ${tone === 'warn' ? 'text-warn' : 'text-text-dim'}">
              ${lastSeen ? html`<span class="inline-flex items-center rounded-[var(--r-1)] border ${chipClass} px-2 py-0.5 font-medium">
                Last judgment <${TimeAgo} timestamp=${lastSeen} />
              </span>` : null}
              ${meta ? html`<span class="font-mono opacity-75">${meta}</span>` : null}
            </div>
          ` : null}
        <//>
      </div>
    `
  }

  return html`
    <${SectionCard} label=${title} class="section mb-5 v2-command-panel" variant="compact">
      <div class="v2-command-panel flex flex-col gap-2.5">
        ${judgments.map(j => html`
          <div class="v2-command-row rounded-[var(--r-1)] border border-card-border bg-card/34 p-3.5 text-sm" data-testid="judgment-item">
            <div class="flex items-center gap-2 mb-1.5">
              <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-1.5 py-0.5 text-3xs font-bold text-accent-fg">${j.target_kind ?? 'unknown'}</span>
              <span class="font-medium text-text-strong">${j.target_id ?? ''}</span>
              ${j.confidence != null ? html`<span class="ml-auto text-2xs text-text-muted">Confidence ${Math.round(j.confidence * 100)}%</span>` : null}
            </div>
            <div class="text-text-muted/90 leading-relaxed">${j.summary ?? ''}</div>
            ${j.recommended_action ? html`
              <div class="mt-2 flex items-center gap-1.5 text-2xs">
                <span class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-8)] px-1.5 py-0.5 font-medium text-accent-fg">${j.recommended_action.action_kind ?? '(unknown action_kind)'}</span>
                ${j.recommended_action.resolved_tool ? html`<span class="text-text-dim font-mono">${j.recommended_action.resolved_tool}</span>` : null}
                ${j.recommended_action.reason ? html`<span class="text-text-muted/80 truncate max-w-[250px]">${j.recommended_action.reason}</span>` : null}
              </div>
            ` : null}
            ${j.guardrail_state?.requires_human_gate ? html`
              <div class="mt-1.5 inline-flex items-center rounded-[var(--r-1)] border border-warn/30 bg-warn/10 px-2 py-0.5 text-3xs font-bold text-warn">Approval required</div>
            ` : null}
            ${j.generated_at ? html`<div class="mt-1.5 text-2xs text-text-dim"><${TimeAgo} timestamp=${j.generated_at} /></div>` : null}
          </div>
        `)}
      </div>
    <//>
  `
}

/**
 * Pure filter for keeper HITL approval queue rows.
 *
 * Case-insensitive substring match on `keeper_name`, `tool_name`, and
 * `risk_level` so operators can isolate one keeper, every pending call
 * for a specific tool, or all rows at a given risk level (e.g. all
 * `critical` approvals) from a long queue.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * `useMemo` keeps referential equality on the non-filtering path.
 *
 * Input is never mutated; `KeeperApprovalQueueItem` is treated as readonly.
 */
function filterApprovalQueue(
  items: readonly KeeperApprovalQueueItem[],
  query: string,
): readonly KeeperApprovalQueueItem[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return items
  return items.filter(item => {
    if (item.keeper_name && item.keeper_name.toLowerCase().includes(needle)) return true
    if (item.tool_name && item.tool_name.toLowerCase().includes(needle)) return true
    if (item.risk_level && item.risk_level.toLowerCase().includes(needle)) return true
    return false
  })
}

export function approvalRiskToneClass(riskLevel: string): string {
  switch (keeperApprovalRiskVisualBand(riskLevel)) {
    case 'bad':
      return 'border-bad/30 bg-bad/10 text-bad'
    case 'warn':
      return 'border-warn/30 bg-warn/10 text-warn'
    case 'accent':
      return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-accent-fg'
    case 'info':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-text-muted'
  }
}

function approvalDispositionToneClass(disposition?: string | null): string {
  const normalized = disposition?.trim().toLowerCase()
  if (normalized === 'alert') return 'border-bad/30 bg-bad/10 text-bad'
  if (normalized === 'pause') return 'border-warn/30 bg-warn/10 text-warn'
  if (normalized === 'pass') return 'border-ok/30 bg-ok/10 text-ok'
  return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-text-muted'
}

export function maxApprovalRisk(items: readonly { risk_level?: string | null }[]): string | null {
  return maxKeeperApprovalRiskLevel(items)
}

function scrollToKeeperApprovalSection(): void {
  const el = document.getElementById('keeper-hitl-approval')
  if (!el) return
  el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function KeeperApprovalAlertBanner() {
  const items = governanceData.value?.approval_queue ?? []
  if (items.length === 0) return null

  const maxRisk = maxApprovalRisk(items)
  const isCritical = isHighOrCriticalKeeperApprovalRisk(maxRisk)
  const tone = isCritical
    ? 'border-bad/40 bg-bad/10 text-bad'
    : 'border-warn/40 bg-warn/10 text-warn'
  const ringTone = isCritical ? 'ring-bad/25' : 'ring-warn/25'

  return html`
    <div
      class="v2-command-panel mb-3.5 flex items-center gap-4 rounded-[var(--r-1)] border ${tone} p-4 shadow-[var(--shadow-1)] ring-2 ${ringTone}"
      data-testid="keeper-hitl-alert-banner"
      role="status"
      aria-live="polite"
    >
      <div class="shrink-0 flex items-center justify-center w-11 h-11 rounded-[var(--r-1)] border border-current/30 bg-current/10">
        <${AlertTriangle} size=${22} aria-hidden="true" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2 flex-wrap">
          <span class="text-2xl font-extrabold leading-none">${items.length}</span>
          <span class="text-sm font-semibold">Keeper HITL approvals pending</span>
          ${maxRisk ? html`<span class="text-2xs font-bold uppercase tracking-wider opacity-80">max ${maxRisk}</span>` : null}
        </div>
        <div class="mt-1 text-xs opacity-85">
          Keeper tool calls above the risk threshold are waiting for operator judgment.
        </div>
      </div>
      <${ActionButton}
        variant=${isCritical ? 'danger' : 'primary'}
        size="md"
        class="v2-command-action shrink-0"
        onClick=${scrollToKeeperApprovalSection}
      >
        Review now
      <//>
    </div>
  `
}

function KeeperApprovalEmptyState() {
  const ctx = keeperHitlEmptyContext()
  const judge = governanceData.value?.judge
  const meta = [judge?.keeper_name]
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .join(' · ')
  const chipClass = ctx.tone === 'warn'
    ? 'border-warn/30 bg-warn/10 text-warn'
    : ctx.tone === 'ok'
      ? 'border-[var(--accent-20)] bg-[var(--accent-10)] text-accent-fg'
      : 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-text-muted'
  return html`
    <div class="v2-command-panel" data-testid="keeper-hitl-empty">
      <${EmptyState} message=${ctx.primary} compact />
      ${ctx.secondary ? html`<div class="mt-0.5 text-center text-2xs text-text-dim">${ctx.secondary}</div>` : null}
      ${ctx.lastActivity || meta ? html`
        <div class="mt-1.5 flex flex-wrap items-center justify-center gap-2 text-2xs ${ctx.tone === 'warn' ? 'text-warn' : 'text-text-dim'}">
          ${ctx.lastActivity ? html`<span class="inline-flex items-center rounded-[var(--r-1)] border ${chipClass} px-2 py-0.5 font-medium">
            Last judge activity <${TimeAgo} timestamp=${ctx.lastActivity} />
          </span>` : null}
          ${meta ? html`<span class="font-mono opacity-75">${meta}</span>` : null}
        </div>
      ` : null}
    </div>
  `
}

function keeperHitlEmptyContext(): {
  primary: string
  secondary: string | null
  lastActivity: string | null
  tone: 'ok' | 'warn' | 'default'
} {
  const judge = governanceData.value?.judge
  const summary = governanceData.value?.summary
  const status = judgeRuntimeStatus(judge, summary)
  if (status === 'stale_visible') {
    return {
      primary: `AI Judge is holding the fresh-judgment cache after ${degradedReasonLabel(judge?.degraded_reason)}.`,
      secondary: 'New HITL judgments refresh after the judge recovers.',
      lastActivity: judge?.generated_at ?? summary?.judge_last_seen_at ?? null,
      tone: 'warn',
    }
  }
  if (status === 'backoff') {
    return {
      primary: 'AI Judge backoff: local slots saturated.',
      secondary: 'HITL judgment generation resumes after a local slot opens.',
      lastActivity: judge?.generated_at ?? summary?.judge_last_seen_at ?? null,
      tone: 'warn',
    }
  }
  const lastError = judge?.last_error?.trim()
  if (lastError) {
    return {
      primary: `AI Judge error may be blocking HITL evaluation: ${lastError}`,
      secondary: 'Reject/approve queues fill after the judge recovers.',
      lastActivity: judge?.generated_at ?? summary?.judge_last_seen_at ?? null,
      tone: 'warn',
    }
  }
  if (status === 'offline') {
    return {
      primary: 'AI Judge is offline; HITL judgment generation is stopped.',
      secondary: 'Check whether the keeper is running first.',
      lastActivity: judge?.generated_at ?? summary?.judge_last_seen_at ?? null,
      tone: 'warn',
    }
  }
  const lastActivity = judge?.generated_at ?? summary?.judge_last_seen_at ?? null
  if (lastActivity) {
    return {
      primary: 'No tool calls exceed the risk threshold; the system is operating normally.',
      secondary: 'New HITL requests appear here automatically.',
      lastActivity,
      tone: 'ok',
    }
  }
  return {
    primary: 'No keeper approval requests are ready for this dashboard.',
    secondary: 'This list fills when AI Judge starts HITL evaluation.',
    lastActivity: null,
    tone: 'default',
  }
}

function KeeperApprovalQueueSection() {
  const items = governanceData.value?.approval_queue ?? []
  const actingId = governanceApprovalActing.value
  const maxRisk = maxApprovalRisk(items)
  const hasItems = items.length > 0
  const query = useSignal('')
  const visibleItems = useMemo(
    () => filterApprovalQueue(items, query.value),
    [items, query.value],
  )
  const isFiltering = query.value.trim() !== ''
  const countBadgeClass = hasItems
    ? (maxRisk === 'critical' || maxRisk === 'high'
        ? 'border-bad/40 bg-bad/15 text-bad text-sm px-3 py-1 font-extrabold'
        : 'border-warn/40 bg-warn/15 text-warn text-sm px-3 py-1 font-extrabold')
    : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-text-muted text-2xs px-2 py-0.5 font-bold'
  return html`
    <div class="v2-command-panel" id="keeper-hitl-approval" data-testid="keeper-hitl-approval">
    <${SectionCard} label="Keeper HITL Approval Queue" class="section mb-5 v2-command-panel" variant="compact">
      <div class="v2-command-toolbar mb-3 flex items-center justify-between gap-3">
        <div class="text-xs text-text-muted">
          Keeper tool calls above the risk threshold wait here.
        </div>
        <span class="rounded-[var(--r-1)] border ${countBadgeClass}">
          ${items.length} pending
        </span>
      </div>
      ${hasItems ? html`
        <div class="v2-command-toolbar mb-3 flex items-center gap-2">
          <${TextInput}
            type="search"
            value=${query.value}
            placeholder="keeper / tool / risk filter"
            ariaLabel="Keeper HITL approval filter"
            testId="keeper-hitl-approval-filter"
            onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-70 flex-1 !px-2 !py-1 !text-2xs"
          />
        </div>
      ` : null}
      ${items.length === 0
        ? html`<${KeeperApprovalEmptyState} />`
        : isFiltering && visibleItems.length === 0
          ? html`
              <div class="v2-command-row py-4 text-center text-2xs text-[var(--color-fg-disabled)]" data-testid="keeper-hitl-approval-empty-filter">
                No filter results (${items.length} items)
              </div>
            `
          : html`
            <div class="v2-command-panel flex flex-col gap-3.5" data-testid="governance-approval-queue">
              ${visibleItems.map(item => {
                const disabled = actingId === item.id
                return html`
                  <div class="v2-command-row rounded-[var(--r-1)] border border-card-border bg-card/34 p-4 shadow-[var(--shadow-1)]" data-testid="governance-approval-item">
                    <div class="flex flex-wrap items-start gap-2.5">
                      <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs font-bold text-text-muted">
                        keeper ${item.keeper_name}
                      </span>
                      <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-bold text-accent-fg">
                        ${item.tool_name}
                      </span>
                      <span class="inline-flex items-center rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-bold ${approvalRiskToneClass(item.risk_level)}">
                        ${item.risk_level}
                      </span>
                      <span class="ml-auto text-2xs text-text-dim">
                        ${item.requested_at ? html`Requested <${TimeAgo} timestamp=${item.requested_at} />` : null}
                        ${item.waiting_s != null ? ` · waiting ${Math.max(0, Math.round(item.waiting_s))}s` : ''}
                      </span>
                    </div>
                    ${item.input_preview
                      ? html`<div class="mt-2 text-xs leading-relaxed text-text-muted break-words">${item.input_preview}</div>`
                      : null}
                    <div class="mt-2 flex flex-wrap gap-1.5 text-2xs">
                      ${item.task_id ? html`<${MetaTag}>task ${item.task_id}</${MetaTag}>` : null}
                      ${item.goal_id ? html`<${MetaTag}>goal ${item.goal_id}</${MetaTag}>` : null}
                      ${item.runtime_contract?.sandbox_profile
                        ? html`<${MetaTag}>sandbox ${item.runtime_contract.sandbox_profile}${item.runtime_contract.backend ? ` / ${item.runtime_contract.backend}` : ''}</${MetaTag}>`
                        : null}
                      ${item.disposition
                        ? html`<span class="rounded-[var(--r-1)] border px-1.5 py-0.5 font-bold ${approvalDispositionToneClass(item.disposition)}">
                          ${item.disposition}${item.disposition_reason ? ` · ${item.disposition_reason}` : ''}
                        </span>`
                        : null}
                    </div>
                    <div class="mt-3 grid gap-3 min-[1100px]:grid-cols-[minmax(0,1fr)_auto]">
                      <${JsonViewerCard} data=${item.input ?? {}} title="Approval Input" />
                      <div class="flex min-[1100px]:flex-col gap-2 min-[1100px]:justify-start">
                        <${ActionButton}
                          variant="primary"
                          size="md"
                          class="v2-command-action min-w-[110px]"
                          onClick=${() => void respondToKeeperApproval(item.id, 'approve')}
                          disabled=${Boolean(actingId)}
                        >
                          ${disabled ? 'Processing...' : 'Approve'}
                        <//>
                        <${ActionButton}
                          variant="ghost"
                          size="md"
                          class="v2-command-action min-w-[110px]"
                          onClick=${() => void respondToKeeperApproval(item.id, 'approve', true)}
                          disabled=${Boolean(actingId)}
                        >
                          ${disabled ? 'Processing...' : 'Approve + Always'}
                        <//>
                        <${ActionButton}
                          variant="danger"
                          size="md"
                          class="v2-command-action min-w-[110px]"
                          onClick=${() => void respondToKeeperApproval(item.id, 'reject')}
                          disabled=${Boolean(actingId)}
                        >
                          ${disabled ? 'Processing...' : 'Reject'}
                        <//>
                      </div>
                    </div>
                  </div>
                `
              })}
            </div>
          `}
    <//>
    </div>
  `
}

function ApprovalRulesSection() {
  const rules = governanceData.value?.approval_rules ?? []
  const actingId = governanceApprovalActing.value
  return html`
    <${SectionCard} label="Always Rules" class="section mb-5 v2-command-panel" variant="compact">
      <div class="mb-3 text-xs text-text-muted">
        Auto-approval rules derived from approved requests. Critical, destructive shell/git, and manual-decision states are never auto-approved even when a rule exists.
      </div>
      ${rules.length === 0
        ? html`<${EmptyState} message="No stored Always rules." compact />`
        : html`
            <div class="v2-command-panel flex flex-col gap-3" data-testid="governance-approval-rules">
              ${rules.map((rule: KeeperApprovalRule) => {
                const deleting = actingId === `rule:${rule.id}`
                return html`
                  <div class="v2-command-row rounded-[var(--r-1)] border border-card-border bg-card/34 p-4 shadow-[var(--shadow-1)]" data-testid="governance-approval-rule">
                    <div class="flex flex-wrap items-start gap-2.5">
                      <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs font-bold text-text-muted">
                        keeper ${rule.keeper_name}
                      </span>
                      <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-bold text-accent-fg">
                        ${rule.tool_name}
                      </span>
                      ${rule.max_risk ? html`<span class="inline-flex items-center rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-bold ${approvalRiskToneClass(rule.max_risk)}">${rule.max_risk}</span>` : null}
                      <span class="ml-auto text-2xs text-text-dim">
                        ${rule.created_at ? html`Created <${TimeAgo} timestamp=${rule.created_at} />` : null}
                        ${rule.last_matched_at ? html` · last matched <${TimeAgo} timestamp=${rule.last_matched_at} />` : null}
                      </span>
                    </div>
                    <div class="mt-2 flex flex-wrap gap-1.5 text-2xs">
                      ${rule.sandbox_profile ? html`<${MetaTag}>sandbox ${rule.sandbox_profile}${rule.backend ? ` / ${rule.backend}` : ''}<//>` : null}
                      ${rule.request_fingerprint_preview ? html`<${MetaTag} mono>fp ${rule.request_fingerprint_preview}<//>` : null}
                      ${typeof rule.match_count === 'number' ? html`<${MetaTag}>match ${rule.match_count}<//>` : null}
                      ${rule.source_approval_id ? html`<${MetaTag}>from ${rule.source_approval_id}<//>` : null}
                    </div>
                    <div class="mt-3 flex justify-end">
                      <${ActionButton}
                        variant="danger"
                        size="sm"
                        class="v2-command-action"
                        onClick=${() => void deleteKeeperApprovalRule(rule.id)}
                        disabled=${Boolean(actingId)}
                      >
                        ${deleting ? 'Deleting...' : 'Delete'}
                      <//>
                    </div>
                  </div>
                `
              })}
            </div>
          `}
    <//>
  `
}

export function Governance() {
  useEffect(() => {
    void refreshGovernance()
    const disposeAutoRefresh = setupVisibleAutoRefresh(refreshGovernance, TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
    }
  }, [])

  return html`
    <div class="v2-command-surface flex flex-col gap-0.5">
      <${KeeperApprovalAlertBanner} />
      <${GovernanceSummaryStrip} />
      <${KeeperApprovalQueueSection} />
      <${ApprovalRulesSection} />
      <${JudgmentsSection} />
    </div>
  `
}

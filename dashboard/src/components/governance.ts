import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { AlertTriangle } from 'lucide-preact'
import { useEffect, useMemo } from 'preact/hooks'
import type { KeeperApprovalQueueItem } from '../types'
import { Card } from './common/card'
import { KpiCard } from './common/stat-row'
import { TimeAgo } from './common/time-ago'
import { EmptyState } from './common/empty-state'
import { StatusDot } from './common/status-dot'
import { JsonViewerCard } from './common/json-viewer'
import { ActionButton } from './common/button'
import {
  governanceData,
  governanceError,
  governanceLoading,
  governanceApprovalActing,
  refreshGovernance,
  respondToKeeperApproval,
} from './governance-store'
import { formatAgeSummary } from './governance-utils'

// Re-export for consumers that import from './governance'
export { refreshGovernance } from './governance-store'

function GovernanceSummaryStrip() {
  const data = governanceData.value
  const summary = data?.summary
  const judge = data?.judge
  const oldestAge = summary?.oldest_open_case_age_s
  const lastActivityAge = summary?.last_activity_age_s
  const isStale = (oldestAge != null && oldestAge > 86400) || (lastActivityAge != null && lastActivityAge > 86400)
  const judgmentCount = data?.judgments?.length ?? 0
  const approvalCount = data?.approval_queue?.length ?? summary?.needs_human_gate ?? 0
  const judgeOnlyLabel =
    approvalCount > 0
      ? `judge-only / 최근 판단 ${judgmentCount}건 / 승인 ${approvalCount}건`
      : `judge-only / 최근 판단 ${judgmentCount}건`
  const liveJudgeState =
    judge?.judge_online === true
      ? (judge.refreshing ? '갱신 중' : '온라인')
      : (judge?.last_error ? '오류' : '오프라인')
  const liveJudgeModel = judge?.model_used?.trim() || judge?.keeper_name?.trim() || '-'
  const judgeHealthy = judge?.judge_online === true && !judge?.last_error?.trim()
  const judgeUnhealthy = judge?.judge_online === false || Boolean(judge?.last_error?.trim())

  return html`
    ${isStale ? html`
      <div class="mb-3.5 flex items-center gap-3 rounded border border-warn/30 bg-warn/10 p-3.5 text-[13px] font-medium text-warn shadow-sm">
        <div class="shrink-0"><${AlertTriangle} size=${18} aria-hidden="true" /></div>
        <div>
          모든 열린 케이스가 ${formatAgeSummary(oldestAge)} 이상 경과됨.
          ${lastActivityAge != null ? html` 마지막 활동: ${formatAgeSummary(lastActivityAge)} 전.` : null}
          <span class="opacity-80 ml-1">테스트 잔재일 가능성이 높습니다.</span>
        </div>
      </div>
    ` : null}
    <div class="mb-2.5 flex items-center justify-between gap-3 px-0.5">
      <div class="flex items-center gap-3 min-w-0">
        <h2 class="text-lg font-bold text-text-strong tracking-wide">Live Judge</h2>
        <span class="rounded border border-white/5 bg-[var(--white-3)] px-2 py-0.5 text-[11px] font-medium text-text-muted">
          ${judgeOnlyLabel}
        </span>
      </div>
      <div class="flex items-center gap-3 shrink-0">
        ${data?.generated_at ? html`<span class="text-[11px] text-text-dim font-mono">${data.generated_at}</span>` : null}
        <${ActionButton}
          variant="ghost"
          size="sm"
          class="rounded border-transparent bg-[var(--white-3)] px-2.5 py-1 text-[12px] font-semibold text-text-muted hover:bg-white/10 hover:text-text-strong"
          onClick=${refreshGovernance}
          disabled=${governanceLoading.value}
        >
          ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
        <//>
      </div>
    </div>
    <div class="mb-5 grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-3">
      <${KpiCard}
        label="Judge 상태"
        value=${liveJudgeState}
        hint=${judge?.keeper_name?.trim() || 'live judge'}
        tone=${judgeUnhealthy ? 'text-warn' : (judgeHealthy ? 'text-ok' : undefined)}
        class=${judgeUnhealthy ? 'border-warn/40 bg-warn/5 ring-1 ring-warn/25' : (judgeHealthy ? 'border-ok/30 bg-ok/5' : '')}
      />
      <${KpiCard} label="Judge 모델" value=${liveJudgeModel} hint=${judge?.model_used?.trim() ? 'runtime reported' : 'unknown'} />
      <${KpiCard} label="최근 판단" value=${judgmentCount} hint="live" />
      <${KpiCard}
        label="관리자 승인 대기"
        value=${approvalCount}
        hint=${approvalCount > 0 ? '검토 필요' : (judgeHealthy ? '정상' : 'live')}
        tone=${approvalCount > 0 ? 'text-warn' : (judgeHealthy ? 'text-ok' : undefined)}
        class=${approvalCount > 0 ? 'border-warn/40 bg-warn/5 ring-1 ring-warn/25' : (judgeHealthy ? 'border-ok/30 bg-ok/5' : '')}
      />
    </div>
    <${JudgeStatusBar} />
    ${governanceError.value ? html`<div class="mb-5 rounded border border-[var(--bad-30)] bg-[var(--bad-8)] p-2.5 text-[12px] text-[#f7b6b6]">${governanceError.value}</div>` : null}
  `
}

function JudgeStatusBar() {
  const judge = governanceData.value?.judge
  if (!judge) return null
  const online = judge.judge_online === true
  const dotClass = online ? 'bg-ok' : 'bg-text-dim'
  const label = online
    ? (judge.refreshing ? '갱신 중' : '온라인')
    : (judge.last_error ? '오류' : '오프라인')
  return html`
    <div class="mb-4 flex items-center gap-3 rounded border border-white/5 bg-white/3 px-3.5 py-2 text-[12px]" data-testid="judge-status">
      <span class="flex items-center gap-1.5">
        <${StatusDot} size="sm" class=${dotClass} />
        <span class="font-medium text-text-muted">평가 모델 ${label}</span>
      </span>
      ${judge.model_used ? html`<span class="text-text-dim">${judge.model_used}</span>` : null}
      ${judge.generated_at || judge.last_error
        ? html`
            <span class="ml-auto flex items-center gap-3 min-w-0">
              ${judge.generated_at
                ? html`<span class="text-text-dim"><${TimeAgo} timestamp=${judge.generated_at} /></span>`
                : null}
              ${judge.last_error
                ? html`<span class="text-bad/80 truncate max-w-[300px]">${judge.last_error}</span>`
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
  const lastError = judge?.last_error?.trim()
  if (lastError) {
    return { message: `AI Judge 오류: ${lastError}`, tone: 'warn' }
  }
  const judgeOnline = judge?.judge_online ?? summary?.judge_online
  if (judgeOnline === false) {
    return { message: 'AI Judge 오프라인 — keeper 기동 여부를 확인하세요.', tone: 'warn' }
  }
  const lastSeen = judge?.generated_at ?? summary?.judge_last_seen_at
  if (lastSeen) {
    return { message: '최근 판단 이후 새 입력 대기 중입니다. keeper가 새 판단을 올리면 여기 표시됩니다.', tone: 'default' }
  }
  return { message: 'AI Judge가 판단을 생성하면 자동으로 여기 표시됩니다. 현재 수집된 판단이 없습니다.', tone: 'default' }
}

function JudgmentsSection() {
  const judgments = governanceData.value?.judgments ?? []
  const title = 'AI Judge 판단'

  if (judgments.length === 0) {
    const { message, tone } = judgmentsEmptyStateMessage()
    const judge = governanceData.value?.judge
    const lastSeen = judge?.generated_at ?? governanceData.value?.summary?.judge_last_seen_at
    const meta = [judge?.keeper_name, judge?.model_used].filter((value): value is string => typeof value === 'string' && value.length > 0).join(' · ')
    const chipClass = tone === 'warn'
      ? 'border-warn/30 bg-warn/10 text-warn'
      : 'border-[var(--card-border)] bg-[var(--white-3)] text-text-muted'
    return html`
      <div data-testid="live-judge-empty">
        <${Card} title=${title} class="section mb-5" variant="compact">
          <${EmptyState} message=${message} compact />
          ${lastSeen || meta ? html`
            <div class="mt-1 flex flex-wrap items-center justify-center gap-2 text-[11px] ${tone === 'warn' ? 'text-warn' : 'text-text-dim'}">
              ${lastSeen ? html`<span class="inline-flex items-center rounded border ${chipClass} px-2 py-0.5 font-medium">
                마지막 판단 <${TimeAgo} timestamp=${lastSeen} />
              </span>` : null}
              ${meta ? html`<span class="font-mono opacity-75">${meta}</span>` : null}
            </div>
          ` : null}
        <//>
      </div>
    `
  }

  return html`
    <${Card} title=${title} class="section mb-5" variant="compact">
      <div class="flex flex-col gap-2.5">
        ${judgments.map(j => html`
          <div class="rounded border border-card-border bg-card/34 p-3.5 text-[13px]" data-testid="judgment-item">
            <div class="flex items-center gap-2 mb-1.5">
              <span class="inline-flex items-center rounded border border-accent/20 bg-[var(--accent-10)] px-1.5 py-0.5 text-[10px] font-bold text-accent">${j.target_kind ?? 'unknown'}</span>
              <span class="font-medium text-text-strong">${j.target_id ?? ''}</span>
              ${j.confidence != null ? html`<span class="ml-auto text-[11px] text-text-muted">신뢰도 ${Math.round(j.confidence * 100)}%</span>` : null}
            </div>
            <div class="text-text-muted/90 leading-relaxed">${j.summary ?? ''}</div>
            ${j.recommended_action ? html`
              <div class="mt-2 flex items-center gap-1.5 text-[11px]">
                <span class="rounded border border-accent/20 bg-accent/8 px-1.5 py-0.5 font-medium text-accent">${j.recommended_action.action_kind ?? 'action'}</span>
                ${j.recommended_action.resolved_tool ? html`<span class="text-text-dim font-mono">${j.recommended_action.resolved_tool}</span>` : null}
                ${j.recommended_action.reason ? html`<span class="text-text-muted/80 truncate max-w-[250px]">${j.recommended_action.reason}</span>` : null}
              </div>
            ` : null}
            ${j.guardrail_state?.requires_human_gate ? html`
              <div class="mt-1.5 inline-flex items-center rounded border border-warn/30 bg-warn/10 px-2 py-0.5 text-[10px] font-bold text-warn">승인 필요</div>
            ` : null}
            ${j.generated_at ? html`<div class="mt-1.5 text-[11px] text-text-dim"><${TimeAgo} timestamp=${j.generated_at} /></div>` : null}
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
export function filterApprovalQueue(
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
  const normalized = riskLevel.trim().toLowerCase()
  if (normalized === 'critical') return 'border-bad/30 bg-bad/10 text-bad'
  if (normalized === 'high') return 'border-warn/30 bg-warn/10 text-warn'
  if (normalized === 'medium') return 'border-accent/30 bg-[var(--accent-10)] text-accent'
  return 'border-white/10 bg-[var(--white-3)] text-text-muted'
}

const RISK_RANK: Record<string, number> = {
  critical: 4,
  high: 3,
  medium: 2,
  low: 1,
}

export function maxApprovalRisk(items: readonly { risk_level?: string | null }[]): string | null {
  let topRank = 0
  let topLabel: string | null = null
  for (const item of items) {
    const raw = item.risk_level?.trim().toLowerCase()
    const rank = raw ? (RISK_RANK[raw] ?? 0) : 0
    if (rank > topRank) {
      topRank = rank
      topLabel = raw ?? null
    }
  }
  return topLabel
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
  const isCritical = maxRisk === 'critical' || maxRisk === 'high'
  const tone = isCritical
    ? 'border-bad/40 bg-bad/10 text-bad'
    : 'border-warn/40 bg-warn/10 text-warn'
  const ringTone = isCritical ? 'ring-bad/25' : 'ring-warn/25'

  return html`
    <div
      class="mb-3.5 flex items-center gap-4 rounded border ${tone} p-4 shadow-sm ring-2 ${ringTone}"
      data-testid="keeper-hitl-alert-banner"
      role="status"
      aria-live="polite"
    >
      <div class="shrink-0 flex items-center justify-center w-11 h-11 rounded-sm border border-current/30 bg-current/10">
        <${AlertTriangle} size=${22} aria-hidden="true" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2 flex-wrap">
          <span class="text-[20px] font-extrabold leading-none">${items.length}건</span>
          <span class="text-[13px] font-semibold">Keeper HITL 승인 대기</span>
          ${maxRisk ? html`<span class="text-[11px] font-bold uppercase tracking-wider opacity-80">최고 ${maxRisk}</span>` : null}
        </div>
        <div class="mt-1 text-[12px] opacity-85">
          위험도 threshold를 넘은 keeper tool call이 사용자 판단을 기다리고 있습니다.
        </div>
      </div>
      <${ActionButton}
        variant=${isCritical ? 'danger' : 'primary'}
        size="md"
        class="shrink-0"
        onClick=${scrollToKeeperApprovalSection}
      >
        지금 검토 →
      <//>
    </div>
  `
}

function KeeperApprovalEmptyState() {
  const ctx = keeperHitlEmptyContext()
  const judge = governanceData.value?.judge
  const meta = [judge?.keeper_name, judge?.model_used]
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .join(' · ')
  const chipClass = ctx.tone === 'warn'
    ? 'border-warn/30 bg-warn/10 text-warn'
    : ctx.tone === 'ok'
      ? 'border-accent/20 bg-[var(--accent-10)] text-accent'
      : 'border-white/10 bg-white/5 text-text-muted'
  return html`
    <div data-testid="keeper-hitl-empty">
      <${EmptyState} message=${ctx.primary} compact />
      ${ctx.secondary ? html`<div class="mt-0.5 text-center text-[11px] text-text-dim">${ctx.secondary}</div>` : null}
      ${ctx.lastActivity || meta ? html`
        <div class="mt-1.5 flex flex-wrap items-center justify-center gap-2 text-[11px] ${ctx.tone === 'warn' ? 'text-warn' : 'text-text-dim'}">
          ${ctx.lastActivity ? html`<span class="inline-flex items-center rounded border ${chipClass} px-2 py-0.5 font-medium">
            마지막 judge 활동 <${TimeAgo} timestamp=${ctx.lastActivity} />
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
  const lastError = judge?.last_error?.trim()
  if (lastError) {
    return {
      primary: `AI Judge 오류로 HITL 평가가 멈춰 있을 수 있습니다: ${lastError}`,
      secondary: '거부/승인 대기열은 judge가 복구된 뒤에 채워집니다.',
      lastActivity: judge?.generated_at ?? summary?.judge_last_seen_at ?? null,
      tone: 'warn',
    }
  }
  const judgeOnline = judge?.judge_online ?? summary?.judge_online
  if (judgeOnline === false) {
    return {
      primary: 'AI Judge 오프라인 — HITL 판정 생성이 중단되었습니다.',
      secondary: 'keeper 기동 여부를 먼저 확인하세요.',
      lastActivity: judge?.generated_at ?? summary?.judge_last_seen_at ?? null,
      tone: 'warn',
    }
  }
  const lastActivity = judge?.generated_at ?? summary?.judge_last_seen_at ?? null
  if (lastActivity) {
    return {
      primary: '위험도 threshold를 넘는 tool call이 없습니다 — 시스템이 정상 작동 중입니다.',
      secondary: '새 HITL 요청이 들어오면 여기에 자동 표시됩니다.',
      lastActivity,
      tone: 'ok',
    }
  }
  return {
    primary: '현재 대시보드에서 처리할 keeper 승인 요청이 없습니다.',
    secondary: 'AI Judge가 HITL 평가를 시작하면 이 목록이 채워집니다.',
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
        ? 'border-bad/40 bg-bad/15 text-bad text-[13px] px-3 py-1 font-extrabold'
        : 'border-warn/40 bg-warn/15 text-warn text-[13px] px-3 py-1 font-extrabold')
    : 'border-white/10 bg-[var(--white-3)] text-text-muted text-[11px] px-2 py-0.5 font-bold'
  return html`
    <div id="keeper-hitl-approval" data-testid="keeper-hitl-approval">
    <${Card} title="Keeper HITL 승인 대기" class="section mb-5" variant="compact">
      <div class="mb-3 flex items-center justify-between gap-3">
        <div class="text-[12px] text-text-muted">
          위험도가 threshold를 넘은 keeper tool call이 여기서 대기합니다.
        </div>
        <span class="rounded border ${countBadgeClass}">
          ${items.length}건 대기
        </span>
      </div>
      ${hasItems ? html`
        <div class="mb-3 flex items-center gap-2">
          <input
            type="search"
            value=${query.value}
            placeholder="keeper / tool / 위험도 필터"
            aria-label="Keeper HITL 승인 필터"
            data-testid="keeper-hitl-approval-filter"
            onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
            class="min-w-[160px] max-w-[280px] flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
          />
        </div>
      ` : null}
      ${items.length === 0
        ? html`<${KeeperApprovalEmptyState} />`
        : isFiltering && visibleItems.length === 0
          ? html`
              <div class="py-4 text-center text-[11px] text-[var(--text-dim)]" data-testid="keeper-hitl-approval-empty-filter">
                필터 결과 없음 (${items.length} items)
              </div>
            `
          : html`
            <div class="flex flex-col gap-3.5" data-testid="governance-approval-queue">
              ${visibleItems.map(item => {
                const disabled = actingId === item.id
                return html`
                  <div class="rounded border border-card-border bg-card/34 p-4 shadow-sm" data-testid="governance-approval-item">
                    <div class="flex flex-wrap items-start gap-2.5">
                      <span class="inline-flex items-center rounded border border-white/10 bg-[var(--white-3)] px-2 py-0.5 text-[10px] font-bold text-text-muted">
                        keeper ${item.keeper_name}
                      </span>
                      <span class="inline-flex items-center rounded border border-accent/20 bg-[var(--accent-10)] px-2 py-0.5 text-[10px] font-bold text-accent">
                        ${item.tool_name}
                      </span>
                      <span class="inline-flex items-center rounded border px-2 py-0.5 text-[10px] font-bold ${approvalRiskToneClass(item.risk_level)}">
                        ${item.risk_level}
                      </span>
                      <span class="ml-auto text-[11px] text-text-dim">
                        ${item.requested_at ? html`요청 <${TimeAgo} timestamp=${item.requested_at} />` : null}
                        ${item.waiting_s != null ? ` · 대기 ${Math.max(0, Math.round(item.waiting_s))}s` : ''}
                      </span>
                    </div>
                    ${item.input_preview
                      ? html`<div class="mt-2 text-[12px] leading-relaxed text-text-muted break-words">${item.input_preview}</div>`
                      : null}
                    <div class="mt-3 grid gap-3 min-[1100px]:grid-cols-[minmax(0,1fr)_auto]">
                      <${JsonViewerCard} data=${item.input ?? {}} title="Approval Input" />
                      <div class="flex min-[1100px]:flex-col gap-2 min-[1100px]:justify-start">
                        <${ActionButton}
                          variant="primary"
                          size="md"
                          class="min-w-[110px]"
                          onClick=${() => void respondToKeeperApproval(item.id, 'approve')}
                          disabled=${Boolean(actingId)}
                        >
                          ${disabled ? '처리 중...' : '승인'}
                        <//>
                        <${ActionButton}
                          variant="danger"
                          size="md"
                          class="min-w-[110px]"
                          onClick=${() => void respondToKeeperApproval(item.id, 'reject')}
                          disabled=${Boolean(actingId)}
                        >
                          ${disabled ? '처리 중...' : '거부'}
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

export function Governance() {
  useEffect(() => {
    void refreshGovernance()
  }, [])

  return html`
    <div class="flex flex-col gap-0.5">
      <${KeeperApprovalAlertBanner} />
      <${GovernanceSummaryStrip} />
      <${KeeperApprovalQueueSection} />
      <${JudgmentsSection} />
    </div>
  `
}

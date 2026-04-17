import { html } from 'htm/preact'
import { AlertTriangle } from 'lucide-preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { KpiCard } from './common/stat-row'
import { TimeAgo } from './common/time-ago'
import { EmptyState } from './common/empty-state'
import { JsonViewerCard } from './common/json-viewer'
import { FilterChips } from './common/filter-chips'
import { ActionButton } from './common/button'
import { DistributionBars, SegmentedBar, type DistributionItem } from './common/distribution-bars'
import { TextInput } from './common/input'
import { governanceToneClass } from '../lib/tone'
import {
  governanceData,
  governanceError,
  governanceFilter,
  governanceLoading,
  governanceStarting,
  governanceApprovalActing,
  governanceTopicInput,
  refreshGovernance,
  respondToExecutionOrder,
  respondToKeeperApproval,
  selectDecision,
  selectedDecisionKey,
  submitBrief,
  submitPetition,
  loadParamAudit,
} from './governance-store'
import {
  caseStatusLabel,
  filteredItemsByFilter,
  formatAgeSummary,
  itemKey,
  kindLabel,
} from './governance-utils'
import {
  DecisionDetail,
  GuardrailPane,
} from './governance-panels'

// Re-export for consumers that import from './governance'
export { refreshGovernance, loadRuntimeParams, loadParamAudit } from './governance-store'

function governanceCaseTrackingRetired(): boolean {
  return governanceData.value?.case_tracking_available === false
}

function governanceRetiredMessage(): string {
  const note = governanceData.value?.note?.trim()
  if (note) return note
  return '거버넌스 케이스 추적은 중단되었고, 이 화면은 live judge 상태와 최근 판단만 표시합니다.'
}

function GovernanceSummaryStrip() {
  const data = governanceData.value
  const summary = data?.summary
  const judge = data?.judge
  const oldestAge = summary?.oldest_open_case_age_s
  const lastActivityAge = summary?.last_activity_age_s
  const caseTrackingRetired = governanceCaseTrackingRetired()
  const isStale = (oldestAge != null && oldestAge > 86400) || (lastActivityAge != null && lastActivityAge > 86400)
  const itemCount = data?.items?.length ?? 0
  const activityCount = data?.activity?.length ?? 0
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

  return html`
    ${caseTrackingRetired ? html`
      <div class="mb-3.5 flex items-center gap-3 rounded-xl border border-accent/25 bg-[var(--accent-10)] p-3.5 text-[13px] font-medium text-text-strong shadow-sm" data-testid="governance-retired-banner">
        <div class="shrink-0"><${AlertTriangle} size=${18} aria-hidden="true" /></div>
        <div>${governanceRetiredMessage()}</div>
      </div>
    ` : null}
    ${isStale ? html`
      <div class="mb-3.5 flex items-center gap-3 rounded-xl border border-warn/30 bg-warn/10 p-3.5 text-[13px] font-medium text-warn shadow-sm">
        <div class="shrink-0"><${AlertTriangle} size=${18} aria-hidden="true" /></div>
        <div>
          모든 열린 케이스가 ${formatAgeSummary(oldestAge)} 이상 경과됨.
          ${lastActivityAge != null ? html` 마지막 활동: ${formatAgeSummary(lastActivityAge)} 전.` : null}
          <span class="opacity-80 ml-1">테스트 잔재일 가능성이 높습니다.</span>
        </div>
      </div>
    ` : null}
    <div class="mb-2.5 flex items-center justify-between px-0.5">
      <div class="flex items-center gap-3">
        <h2 class="text-lg font-bold text-text-strong tracking-wide">거버넌스</h2>
        <span class="rounded-md border border-white/5 bg-white/5 px-2 py-0.5 text-[11px] font-medium text-text-muted">
          ${caseTrackingRetired ? judgeOnlyLabel : `진행 중 ${itemCount}건 / 활동 ${activityCount}건`}
        </span>
      </div>
      ${data?.generated_at ? html`<span class="text-[11px] text-text-dim font-mono">${data.generated_at}</span>` : null}
    </div>
    ${caseTrackingRetired
      ? html`
          <div class="mb-5 grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-3">
            <${KpiCard} label="Judge 상태" value=${liveJudgeState} hint=${judge?.keeper_name?.trim() || 'live judge'} />
            <${KpiCard} label="Judge 모델" value=${liveJudgeModel} hint=${judge?.model_used?.trim() ? 'runtime reported' : 'unknown'} />
            <${KpiCard} label="최근 판단" value=${judgmentCount} hint="live" />
            <${KpiCard} label="관리자 승인 대기" value=${approvalCount} hint="live" />
          </div>
        `
      : html`
          <div class="mb-5 grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-3">
            <${KpiCard} label="열린 케이스" value=${summary?.cases_open ?? itemCount} />
            <${KpiCard} label="판정 대기" value=${summary?.pending_ruling ?? 0} />
            <${KpiCard} label="자동집행 준비" value=${summary?.ready_auto_execute ?? 0} />
            <${KpiCard} label="관리자 승인 대기" value=${summary?.needs_human_gate ?? approvalCount} />
            <${KpiCard} label="집행 완료" value=${summary?.executed ?? 0} />
          </div>
        `}
    <${JudgeStatusBar} />
  `
}

function governanceCaseDistribution(): DistributionItem[] {
  const summary = governanceData.value?.summary
  return [
    { label: '열린 케이스', value: summary?.cases_open ?? 0, tone: 'accent' },
    { label: '판정 대기', value: summary?.pending_ruling ?? 0, tone: 'warn' },
    { label: '자동집행 준비', value: summary?.ready_auto_execute ?? 0, tone: 'ok' },
    { label: '관리자 승인 대기', value: summary?.needs_human_gate ?? 0, tone: 'warn' },
    { label: '집행 완료', value: summary?.executed ?? 0, tone: 'ok' },
    { label: '보류/종결', value: summary?.blocked ?? 0, tone: 'bad' },
  ]
}

function governanceStatusSegments(): DistributionItem[] {
  const items = governanceData.value?.items ?? []
  const counts = new Map<string, number>()
  for (const item of items) {
    const key = item.status?.trim() || 'unknown'
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  return [...counts.entries()].map(([label, value]) => ({
    label,
    value,
    tone:
      label === 'executed'
        ? 'ok'
        : label === 'blocked'
          ? 'bad'
          : label === 'pending_ruling' || label === 'needs_human_gate'
            ? 'warn'
            : 'accent',
  }))
}

function judgmentSignalDistribution(): DistributionItem[] {
  const judgments = governanceData.value?.judgments ?? []
  const actionRequired = judgments.filter(j => j.guardrail_state?.requires_human_gate).length
  const executedRoute = judgments.filter(j => Boolean(j.executed_route?.tool_name || j.executed_route?.action_type)).length
  const confident = judgments.filter(j => (j.confidence ?? 0) >= 0.8).length
  return [
    { label: '판단 생성', value: judgments.length, tone: 'accent' },
    { label: '승인 필요', value: actionRequired, tone: 'warn' },
    { label: '집행 경로 기록', value: executedRoute, tone: 'ok' },
    { label: '고신뢰', value: confident, tone: 'ok' },
  ]
}

function GovernanceVisualSummary() {
  const caseTrackingRetired = governanceCaseTrackingRetired()
  return html`
    <div class="mb-5 grid grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)] gap-3 max-[960px]:grid-cols-1">
      <${DistributionBars}
        title="Case Load Visualized"
        subtitle=${caseTrackingRetired ? 'retired 상태에서는 judge/live 신호만 유지됩니다.' : '요약 카운트를 막대로 압축해서 보여줍니다.'}
        items=${governanceCaseDistribution()}
        valueFormatter=${(value: number) => `${value}건`}
        emptyLabel="시각화할 케이스 요약이 없습니다."
      />
      <div class="grid gap-3">
        <${SegmentedBar}
          title="Case Status Mix"
          subtitle="현재 사건 inbox 상태 비중"
          items=${governanceStatusSegments()}
          valueFormatter=${(value: number) => `${value}`}
        />
        <${SegmentedBar}
          title="Judge Signal Mix"
          subtitle="AI Judge 결과에서 바로 읽을 수 있는 운영 신호"
          items=${judgmentSignalDistribution()}
          valueFormatter=${(value: number) => `${value}`}
        />
      </div>
    </div>
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
    <div class="mb-4 flex items-center gap-3 rounded-lg border border-white/5 bg-white/3 px-3.5 py-2 text-[12px]" data-testid="judge-status">
      <span class="flex items-center gap-1.5">
        <span class="inline-block w-2 h-2 rounded-full ${dotClass}"></span>
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

function GovernanceToolbar() {
  return html`
    <div class="mb-5">
      <${Card} title="청원 콘솔" variant="compact">
        <div class="mt-1.5 flex flex-col gap-3.5">
          <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-3 items-center">
            <${TextInput}
              class="rounded-xl bg-card/48 px-3.5 py-2 text-[13px] font-sans text-text-strong placeholder:text-text-dim shadow-inner"
              name="petition_topic"
              ariaLabel="청원 제목"
              autoComplete="off"
              placeholder="청원 제목을 입력하세요..."
              value=${governanceTopicInput.value}
              onInput=${(event: Event) => {
                governanceTopicInput.value = (event.target as HTMLInputElement).value
              }}
              onKeyDown=${(event: KeyboardEvent) => {
                if (event.key === 'Enter') submitPetition()
              }}
              disabled=${governanceStarting.value}
            />
            <${ActionButton}
              variant="primary"
              size="lg"
              class="rounded-xl border-transparent bg-accent/12 text-accent hover:bg-accent/20 disabled:bg-card/40 disabled:border-card-border disabled:text-text-muted"
              onClick=${submitPetition}
              disabled=${governanceStarting.value || governanceTopicInput.value.trim() === ''}
            >
              ${governanceStarting.value ? '접수 중...' : '청원 접수'}
            <//>
            <${ActionButton}
              variant="ghost"
              size="lg"
              class="rounded-xl border-transparent bg-white/5 px-3.5 py-2 text-[13px] font-semibold text-text-muted hover:bg-white/10 hover:text-text-strong"
              onClick=${refreshGovernance}
              disabled=${governanceLoading.value}
            >
              ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
            <//>
        </div>
        <${FilterChips}
          chips=${[
            { key: 'open', label: '진행 중' },
            { key: 'pending_ruling', label: '판정 대기' },
            { key: 'needs_human_gate', label: '승인 대기' },
            { key: 'executed', label: '집행 완료' },
            { key: 'blocked', label: '보류/종결' },
          ]}
          active=${governanceFilter}
          onChange=${() => { void refreshGovernance() }}
        />
        ${governanceError.value ? html`<div class="mt-2 rounded-lg border border-[var(--bad-30)] bg-[var(--bad-8)] p-2.5 text-[12px] text-[#f7b6b6]">${governanceError.value}</div>` : null}
      </div>
      <//>
    </div>
  `
}

function LiveGovernanceToolbar() {
  return html`
    <div class="mb-5">
      <${Card} title="Live Judge" variant="compact">
        <div class="flex flex-col gap-3">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="text-[12px] text-text-muted">
              retired된 case tracking 대신 live judge 판단과 keeper HITL 승인만 표시합니다.
            </div>
            <${ActionButton}
              variant="ghost"
              size="lg"
              class="rounded-xl border-transparent bg-white/5 px-3.5 py-2 text-[13px] font-semibold text-text-muted hover:bg-white/10 hover:text-text-strong"
              onClick=${refreshGovernance}
              disabled=${governanceLoading.value}
            >
              ${governanceLoading.value ? '새로고침 중...' : '새로고침'}
            <//>
          </div>
          ${governanceError.value ? html`<div class="rounded-lg border border-[var(--bad-30)] bg-[var(--bad-8)] p-2.5 text-[12px] text-[#f7b6b6]">${governanceError.value}</div>` : null}
        </div>
      <//>
    </div>
  `
}

function governanceEmptyMessage(): string {
  const data = governanceData.value
  const allItems = data?.items ?? []
  const judgments = data?.judgments ?? []
  const lastActivityAge = data?.summary?.last_activity_age_s

  if (governanceCaseTrackingRetired()) {
    if (judgments.length > 0) {
      return '거버넌스 케이스 추적은 중단되었고, 아래 AI Judge 판단만 유지됩니다.'
    }
    return governanceRetiredMessage()
  }

  // All items and judgments empty — show guidance
  if (allItems.length === 0 && judgments.length === 0) {
    const ageText = formatAgeSummary(lastActivityAge)
    if (ageText != null) {
      return `거버넌스 사건이 없습니다. 마지막 활동: ${ageText} 전. keeper가 활동 중일 때 자동 생성됩니다.`
    }
    return '거버넌스 사건은 keeper가 활동 중일 때 자동 생성됩니다.'
  }

  // Items exist but filtered results are empty
  return '이 필터에 해당하는 사건이 없습니다. 청원을 접수하거나 필터를 변경해 보세요.'
}

function DecisionInbox() {
  const items = filteredItemsByFilter(governanceFilter.value, governanceData.value?.items ?? [])
  const caseTrackingRetired = governanceCaseTrackingRetired()
  return html`
    <${Card} title=${caseTrackingRetired ? '사건 수신함 (retired)' : '사건 수신함'} class="section mb-5" variant="compact">
      <div class="flex flex-col gap-3 governance-inbox">
        ${items.length === 0
          ? html`<${EmptyState} message=${governanceEmptyMessage()} />`
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button type="button"
                  class="group flex w-full gap-3 rounded-xl border p-4 text-left cursor-pointer transition-[transform,background-color,border-color,box-shadow] duration-200 shadow-sm shadow-black/8 hover:-translate-y-0.5 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]
                    ${selected
                      ? 'border-accent/40 bg-[var(--accent-10)] shadow-[0_0_12px_rgba(71,184,255,0.12)]'
                      : 'border-card-border bg-card/34 hover:border-accent/30 hover:bg-card/52'
                    }"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="min-w-0 flex-1">
                    <div class="mb-1.5 flex min-w-0 items-center gap-2.5">
                      <span class="inline-flex items-center rounded-lg border border-accent/20 bg-[var(--accent-10)] px-2 py-0.5 text-[10px] font-bold text-accent">${kindLabel(item.kind)}</span>
                      <span class="text-[15px] font-bold text-text-strong break-words group-hover:text-accent transition-colors leading-tight tracking-wide">${item.topic}</span>
                    </div>
                    <div class="mt-1.5 flex flex-wrap gap-2.5 text-[12px] text-text-muted/90 font-medium">
                      <span class="leading-relaxed opacity-90">${item.truth_summary || '사실 요약이 아직 없습니다'}</span>
                      ${item.last_activity_at
                        ? html`<span class="text-text-dim flex items-center gap-1.5"><span class="w-1 h-1 rounded-full bg-text-dim/50"></span><${TimeAgo} timestamp=${item.last_activity_at} /></span>`
                        : null}
                    </div>
                    <div class="mt-3 flex flex-wrap gap-1.5">
                      ${item.origin ? html`<span class="inline-flex items-center rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-medium text-text-muted">${item.origin}</span>` : null}
                      ${item.risk_class ? html`<span class="inline-flex items-center rounded-md border border-bad/20 bg-bad/10 px-2 py-0.5 text-[10px] font-medium text-bad">${item.risk_class}</span>` : null}
                      ${item.provenance ? html`<span class="inline-flex items-center rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-medium text-text-muted">${item.provenance}</span>` : null}
                      ${item.status === 'needs_human_gate'
                        ? html`<span class="inline-flex items-center rounded-md border border-warn/30 bg-warn/20 px-2 py-0.5 text-[10px] font-bold text-warn animate-pulse">승인 대기</span>`
                        : null}
                      ${item.status === 'executed'
                        ? html`<span class="inline-flex items-center rounded-md border border-ok/30 bg-ok/10 px-2 py-0.5 text-[10px] font-bold text-ok">집행 완료</span>`
                        : null}
                    </div>
                  </div>
                  <div class="flex flex-col items-end justify-between flex-shrink-0 pt-0.5">
                    <span class="inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-bold ${governanceToneClass(item.status)}">${caseStatusLabel(item.status)}</span>
                    <span class="mt-auto rounded-md border border-white/5 bg-white/5 px-2 py-0.5 text-[11px] font-medium text-text-dim">의견 ${item.brief_count ?? 0}</span>
                  </div>
                </button>
              `
            })}
      </div>
    <//>
  `
}

export function judgmentsEmptyStateMessage(): { message: string; tone: 'warn' | 'default' } {
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
  const isRetired = governanceCaseTrackingRetired()
  const title = isRetired ? 'AI Judge 판단 (live)' : 'AI Judge 판단'

  if (judgments.length === 0) {
    if (!isRetired) return null
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
              ${lastSeen ? html`<span class="inline-flex items-center rounded-md border ${chipClass} px-2 py-0.5 font-medium">
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
          <div class="rounded-lg border border-card-border bg-card/34 p-3.5 text-[13px]" data-testid="judgment-item">
            <div class="flex items-center gap-2 mb-1.5">
              <span class="inline-flex items-center rounded-md border border-accent/20 bg-[var(--accent-10)] px-1.5 py-0.5 text-[10px] font-bold text-accent">${j.target_kind ?? 'unknown'}</span>
              <span class="font-medium text-text-strong">${j.target_id ?? ''}</span>
              ${j.confidence != null ? html`<span class="ml-auto text-[11px] text-text-muted">신뢰도 ${Math.round(j.confidence * 100)}%</span>` : null}
            </div>
            <div class="text-text-muted/90 leading-relaxed">${j.summary ?? ''}</div>
            ${j.recommended_action ? html`
              <div class="mt-2 flex items-center gap-1.5 text-[11px]">
                <span class="rounded-md border border-accent/20 bg-accent/8 px-1.5 py-0.5 font-medium text-accent">${j.recommended_action.action_kind ?? 'action'}</span>
                ${j.recommended_action.resolved_tool ? html`<span class="text-text-dim font-mono">${j.recommended_action.resolved_tool}</span>` : null}
                ${j.recommended_action.reason ? html`<span class="text-text-muted/80 truncate max-w-[250px]">${j.recommended_action.reason}</span>` : null}
              </div>
            ` : null}
            ${j.guardrail_state?.requires_human_gate ? html`
              <div class="mt-1.5 inline-flex items-center rounded-md border border-warn/30 bg-warn/10 px-2 py-0.5 text-[10px] font-bold text-warn">승인 필요</div>
            ` : null}
            ${j.generated_at ? html`<div class="mt-1.5 text-[11px] text-text-dim"><${TimeAgo} timestamp=${j.generated_at} /></div>` : null}
          </div>
        `)}
      </div>
    <//>
  `
}

export function approvalRiskToneClass(riskLevel: string): string {
  const normalized = riskLevel.trim().toLowerCase()
  if (normalized === 'critical') return 'border-bad/30 bg-bad/10 text-bad'
  if (normalized === 'high') return 'border-warn/30 bg-warn/10 text-warn'
  if (normalized === 'medium') return 'border-accent/30 bg-[var(--accent-10)] text-accent'
  return 'border-white/10 bg-white/5 text-text-muted'
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
      class="mb-3.5 flex items-center gap-4 rounded-xl border ${tone} p-4 shadow-sm ring-2 ${ringTone}"
      data-testid="keeper-hitl-alert-banner"
      role="status"
      aria-live="polite"
    >
      <div class="shrink-0 flex items-center justify-center w-11 h-11 rounded-full border border-current/30 bg-current/10">
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
          ${ctx.lastActivity ? html`<span class="inline-flex items-center rounded-md border ${chipClass} px-2 py-0.5 font-medium">
            마지막 judge 활동 <${TimeAgo} timestamp=${ctx.lastActivity} />
          </span>` : null}
          ${meta ? html`<span class="font-mono opacity-75">${meta}</span>` : null}
        </div>
      ` : null}
    </div>
  `
}

export function keeperHitlEmptyContext(): {
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
  const countBadgeClass = hasItems
    ? (maxRisk === 'critical' || maxRisk === 'high'
        ? 'border-bad/40 bg-bad/15 text-bad text-[13px] px-3 py-1 font-extrabold'
        : 'border-warn/40 bg-warn/15 text-warn text-[13px] px-3 py-1 font-extrabold')
    : 'border-white/10 bg-white/5 text-text-muted text-[11px] px-2 py-0.5 font-bold'
  return html`
    <div id="keeper-hitl-approval" data-testid="keeper-hitl-approval">
    <${Card} title="Keeper HITL 승인 대기" class="section mb-5" variant="compact">
      <div class="mb-3 flex items-center justify-between gap-3">
        <div class="text-[12px] text-text-muted">
          위험도가 threshold를 넘은 keeper tool call이 여기서 대기합니다.
        </div>
        <span class="rounded-md border ${countBadgeClass}">
          ${items.length}건 대기
        </span>
      </div>
      ${items.length === 0
        ? html`<${KeeperApprovalEmptyState} />`
        : html`
            <div class="flex flex-col gap-3.5" data-testid="governance-approval-queue">
              ${items.map(item => {
                const disabled = actingId === item.id
                return html`
                  <div class="rounded-xl border border-card-border bg-card/34 p-4 shadow-sm" data-testid="governance-approval-item">
                    <div class="flex flex-wrap items-start gap-2.5">
                      <span class="inline-flex items-center rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-bold text-text-muted">
                        keeper ${item.keeper_name}
                      </span>
                      <span class="inline-flex items-center rounded-md border border-accent/20 bg-[var(--accent-10)] px-2 py-0.5 text-[10px] font-bold text-accent">
                        ${item.tool_name}
                      </span>
                      <span class="inline-flex items-center rounded-md border px-2 py-0.5 text-[10px] font-bold ${approvalRiskToneClass(item.risk_level)}">
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
    void loadParamAudit()
  }, [])

  const caseTrackingRetired = governanceCaseTrackingRetired()

  return html`
    <div class="flex flex-col gap-0.5">
      <${KeeperApprovalAlertBanner} />
      <${GovernanceSummaryStrip} />
      ${caseTrackingRetired
        ? html`
            <${LiveGovernanceToolbar} />
            <${KeeperApprovalQueueSection} />
            <${JudgmentsSection} />
          `
        : html`
            <${GovernanceVisualSummary} />
            <${GovernanceToolbar} />
            <${KeeperApprovalQueueSection} />
            <${JudgmentsSection} />
            <div class="governance-layout">
              <${DecisionInbox} />
              <${DecisionDetail} />
              <${GuardrailPane}
                submitBrief=${submitBrief}
                respondToExecutionOrder=${respondToExecutionOrder}
              />
            </div>
          `}
    </div>
  `
}

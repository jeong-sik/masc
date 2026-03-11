import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import {
  confirmOperatorAction,
  fetchConsensusSessionSummary,
  fetchDashboardGovernance,
  fetchDebateStatus,
  startDebate,
} from '../api'
import { registerCouncilRefresh } from '../sse-store'
import type {
  CouncilDebateArgument,
  CouncilDebateSummary,
  CouncilSessionSummary,
  DashboardGovernanceResponse,
  GovernanceDecisionItem,
  GovernanceExecutedRoute,
  GovernanceResolvedAction,
  GovernanceTimelineEvent,
} from '../types'

type GovernanceFilter =
  | 'open'
  | 'needs_quorum'
  | 'ready'
  | 'needs_approval'
  | 'judge_offline'

const governanceLoading = signal(false)
const governanceStarting = signal(false)
const governanceActing = signal(false)
const governanceError = signal('')
const governanceTopicInput = signal('')
const governanceFilter = signal<GovernanceFilter>('open')
const governanceData = signal<DashboardGovernanceResponse | null>(null)
const selectedDecisionKey = signal<string | null>(null)
const selectedDebateDetail = signal<CouncilDebateSummary | null>(null)
const selectedConsensusDetail = signal<CouncilSessionSummary | null>(null)
const detailLoading = signal(false)

function itemKey(item: GovernanceDecisionItem): string {
  return `${item.kind}:${item.id}`
}

function getSelectedDecision(): GovernanceDecisionItem | null {
  const key = selectedDecisionKey.value
  const items = governanceData.value?.items ?? []
  if (!key) return null
  return items.find(item => itemKey(item) === key) ?? null
}

function dashboardActor(): string {
  const params = new URLSearchParams(window.location.search)
  const actor = params.get('agent') ?? params.get('agent_name')
  return actor?.trim() || 'dashboard'
}

function isOpenStatus(status: string): boolean {
  const normalized = status.trim().toLowerCase()
  return normalized === 'open' || normalized === 'pending'
}

function hasJudgeSummary(item: GovernanceDecisionItem): boolean {
  return Boolean(item.judgment_summary && item.judgment_summary.trim())
}

function filteredItems(items: GovernanceDecisionItem[]): GovernanceDecisionItem[] {
  switch (governanceFilter.value) {
    case 'needs_quorum':
      return items.filter(item => item.kind === 'consensus' && (item.votes ?? 0) < (item.quorum ?? 0))
    case 'ready':
      return items.filter(item => item.guardrail_state?.ready_to_execute)
    case 'needs_approval':
      return items.filter(
        item => item.guardrail_state?.requires_human_gate || Boolean(item.guardrail_state?.pending_confirm),
      )
    case 'judge_offline':
      return items.filter(item => !hasJudgeSummary(item))
    case 'open':
    default:
      return items.filter(item => isOpenStatus(item.status))
  }
}

function serializePreview(value: unknown): string {
  if (value == null) return 'none'
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function toneClass(raw: string | null | undefined): string {
  const value = (raw || '').toLowerCase()
  if (value.includes('reject') || value.includes('deny') || value.includes('closed') || value.includes('cancel')) {
    return 'negative'
  }
  if (value.includes('approve') || value.includes('support') || value.includes('open') || value.includes('ready')) {
    return 'positive'
  }
  return 'neutral'
}

function confidenceText(confidence: number | null | undefined): string {
  if (typeof confidence !== 'number' || Number.isNaN(confidence)) return 'n/a'
  return `${Math.round(confidence * 100)}%`
}

function isResolvedActionRoute(
  route: GovernanceResolvedAction | GovernanceExecutedRoute,
): route is GovernanceResolvedAction {
  return 'resolved_tool' in route || 'payload_preview' in route || 'reason' in route
}

async function loadDecisionDetail(item: GovernanceDecisionItem | null) {
  selectedDebateDetail.value = null
  selectedConsensusDetail.value = null
  if (!item) return
  detailLoading.value = true
  governanceError.value = ''
  try {
    if (item.kind === 'debate') {
      selectedDebateDetail.value = await fetchDebateStatus(item.id)
    } else {
      selectedConsensusDetail.value = await fetchConsensusSessionSummary(item.id)
    }
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : 'Failed to load governance detail'
  } finally {
    detailLoading.value = false
  }
}

async function selectDecision(item: GovernanceDecisionItem) {
  selectedDecisionKey.value = itemKey(item)
  await loadDecisionDetail(item)
}

export async function refreshGovernance() {
  governanceLoading.value = true
  governanceError.value = ''
  try {
    const data = await fetchDashboardGovernance()
    governanceData.value = data
    const items = filteredItems(data.items ?? [])
    const current = selectedDecisionKey.value
    const next = items.find(item => itemKey(item) === current) ?? items[0] ?? data.items?.[0] ?? null
    selectedDecisionKey.value = next ? itemKey(next) : null
    await loadDecisionDetail(next)
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : 'Failed to load governance state'
  } finally {
    governanceLoading.value = false
  }
}

registerCouncilRefresh(refreshGovernance)

async function submitDebate() {
  const topic = governanceTopicInput.value.trim()
  if (!topic) return
  governanceStarting.value = true
  try {
    const created = await startDebate(topic)
    governanceTopicInput.value = ''
    showToast(created?.id ? `Debate started: ${created.id}` : 'Debate started', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to start debate'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceStarting.value = false
  }
}

async function respondToPendingConfirm(decision: 'confirm' | 'deny') {
  const item = getSelectedDecision()
  const confirmToken = item?.guardrail_state?.pending_confirm?.confirm_token
  if (!confirmToken) return
  governanceActing.value = true
  try {
    await confirmOperatorAction(dashboardActor(), confirmToken, decision)
    showToast(decision === 'confirm' ? 'Action approved' : 'Action denied', 'success')
    await refreshGovernance()
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to update pending action'
    governanceError.value = message
    showToast(message, 'error')
  } finally {
    governanceActing.value = false
  }
}

function GovernanceSummaryStrip() {
  const summary = governanceData.value?.summary
  const judge = governanceData.value?.judge
  return html`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${summary?.debates_open ?? governanceData.value?.debates?.length ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Consensus sessions</span>
        <strong>${summary?.sessions_active ?? governanceData.value?.sessions?.length ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Needs quorum</span>
        <strong>${summary?.sessions_without_quorum ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Ready to execute</span>
        <strong>${summary?.ready_to_execute ?? 0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Judge</span>
        <strong>${judge?.judge_online ?? summary?.judge_online ? 'Online' : 'Offline'}</strong>
      </div>
    </div>
  `
}

function GovernanceToolbar() {
  return html`
    <${Card} title="Governance Console" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${governanceTopicInput.value}
            onInput=${(event: Event) => {
              governanceTopicInput.value = (event.target as HTMLInputElement).value
            }}
            onKeyDown=${(event: KeyboardEvent) => {
              if (event.key === 'Enter') submitDebate()
            }}
            disabled=${governanceStarting.value}
          />
          <button
            class="control-btn secondary"
            onClick=${submitDebate}
            disabled=${governanceStarting.value || governanceTopicInput.value.trim() === ''}
          >
            ${governanceStarting.value ? 'Starting...' : 'Start Debate'}
          </button>
          <button class="control-btn ghost" onClick=${refreshGovernance} disabled=${governanceLoading.value}>
            ${governanceLoading.value ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
        <div class="governance-filter-row">
          ${(
            [
              ['open', 'Open'],
              ['needs_quorum', 'Needs Quorum'],
              ['ready', 'Ready'],
              ['needs_approval', 'Needs Approval'],
              ['judge_offline', 'Judge Offline'],
            ] as Array<[GovernanceFilter, string]>
          ).map(([key, label]) => html`
            <button
              class="control-btn ${governanceFilter.value === key ? 'is-active' : 'ghost'}"
              onClick=${async () => {
                governanceFilter.value = key
                await refreshGovernance()
              }}
            >
              ${label}
            </button>
          `)}
        </div>
        ${governanceError.value ? html`<div class="council-error">${governanceError.value}</div>` : null}
      </div>
    <//>
  `
}

function DecisionInbox() {
  const items = filteredItems(governanceData.value?.items ?? [])
  return html`
    <${Card} title="Decision Inbox" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${items.length === 0
          ? html`
              <div class="empty-state">
                Governance is quiet. No debates or consensus sessions match the current filter.
              </div>
            `
          : items.map(item => {
              const selected = selectedDecisionKey.value === itemKey(item)
              return html`
                <button
                  class="council-row governance-decision-row ${selected ? 'selected' : ''}"
                  onClick=${() => selectDecision(item)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${item.kind}</span>
                      <span class="council-topic">${item.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${item.truth_summary || 'No fact summary'}</span>
                      ${item.last_activity_at
                        ? html`<span><${TimeAgo} timestamp=${item.last_activity_at} /></span>`
                        : null}
                    </div>
                    <div class="governance-chip-row">
                      ${item.guardrail_state?.requires_human_gate
                        ? html`<span class="governance-chip warn">needs approval</span>`
                        : null}
                      ${item.guardrail_state?.ready_to_execute
                        ? html`<span class="governance-chip ok">ready</span>`
                        : null}
                      ${item.kind === 'consensus' && (item.votes ?? 0) < (item.quorum ?? 0)
                        ? html`<span class="governance-chip warn">quorum debt</span>`
                        : null}
                      ${!hasJudgeSummary(item)
                        ? html`<span class="governance-chip dim">judge offline</span>`
                        : null}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${toneClass(item.status)}">${item.status}</span>
                    ${item.kind === 'consensus'
                      ? html`<span class="governance-vote-meter">${item.votes ?? 0}/${item.quorum ?? 0}</span>`
                      : html`<span class="governance-vote-meter">${item.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `
            })}
      </div>
    <//>
  `
}

function ArgumentEntry({ argument }: { argument: CouncilDebateArgument }) {
  return html`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${toneClass(argument.position)}">${argument.position}</span>
        <strong>${argument.agent}</strong>
        ${argument.created_at ? html`<span><${TimeAgo} timestamp=${argument.created_at} /></span>` : null}
      </div>
      <div class="governance-ledger-body">${argument.content}</div>
      <div class="governance-chip-row">
        ${argument.evidence.map(ref => html`<span class="governance-chip">${ref}</span>`)}
        ${argument.reply_to != null ? html`<span class="governance-chip">reply #${argument.reply_to}</span>` : null}
        ${argument.mentions.map(name => html`<span class="governance-chip">@${name}</span>`)}
        ${argument.archetype ? html`<span class="governance-chip dim">${argument.archetype}</span>` : null}
      </div>
    </div>
  `
}

function VoteEntry({ vote }: { vote: CouncilSessionSummary['votes'][number] }) {
  return html`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${toneClass(vote.decision)}">${vote.decision}</span>
        <strong>${vote.agent}</strong>
        ${vote.timestamp ? html`<span><${TimeAgo} timestamp=${vote.timestamp} /></span>` : null}
      </div>
      <div class="governance-ledger-body">${vote.reason || 'No reason recorded.'}</div>
      <div class="governance-chip-row">
        ${vote.weight != null ? html`<span class="governance-chip">weight ${vote.weight}</span>` : null}
        ${vote.archetype ? html`<span class="governance-chip dim">${vote.archetype}</span>` : null}
      </div>
    </div>
  `
}

function DecisionDetail() {
  const item = getSelectedDecision()
  const debate = selectedDebateDetail.value
  const session = selectedConsensusDetail.value
  return html`
    <${Card}
      title=${item ? `${item.kind === 'debate' ? 'Debate' : 'Consensus'} Detail` : 'Decision Detail'}
      class="section"
      semanticId="governance.detail"
    >
      ${detailLoading.value
        ? html`<div class="loading-indicator">Loading governance detail...</div>`
        : !item
          ? html`<div class="empty-state">Select a decision item to inspect truth and judgment.</div>`
          : item.kind === 'debate' && debate
            ? html`
                <div class="governance-detail-head">
                  <div>
                    <h3>${debate.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${debate.debate.id}</span>
                      <span>${debate.debate.status}</span>
                      ${debate.debate.created_at
                        ? html`<span><${TimeAgo} timestamp=${debate.debate.created_at} /></span>`
                        : null}
                    </div>
                  </div>
                  <div class="governance-balance-grid">
                    <span class="governance-balance"><strong>${debate.summary.support_count}</strong> support</span>
                    <span class="governance-balance"><strong>${debate.summary.oppose_count}</strong> oppose</span>
                    <span class="governance-balance"><strong>${debate.summary.neutral_count}</strong> neutral</span>
                    <span class="governance-balance"><strong>${debate.summary.total_arguments}</strong> total</span>
                  </div>
                </div>
                ${debate.summary.summary_text
                  ? html`<div class="governance-summary-callout">${debate.summary.summary_text}</div>`
                  : null}
                <div class="governance-ledger">
                  ${debate.arguments.length === 0
                    ? html`<div class="empty-state">No arguments recorded yet.</div>`
                    : debate.arguments.map(argument => html`<${ArgumentEntry} key=${argument.index} argument=${argument} />`)}
                </div>
              `
            : item.kind === 'consensus' && session
              ? html`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${session.session.topic}</h3>
                      <div class="council-sub">
                        <span>${session.session.id}</span>
                        <span>${session.session.state}</span>
                        <span>initiator ${session.session.initiator}</span>
                        ${session.session.created_at
                          ? html`<span><${TimeAgo} timestamp=${session.session.created_at} /></span>`
                          : null}
                      </div>
                    </div>
                    <div class="governance-balance-grid">
                      <span class="governance-balance"><strong>${session.summary.approve_count}</strong> approve</span>
                      <span class="governance-balance"><strong>${session.summary.reject_count}</strong> reject</span>
                      <span class="governance-balance"><strong>${session.summary.abstain_count}</strong> abstain</span>
                      <span class="governance-balance"><strong>${session.session.quorum}</strong> quorum</span>
                    </div>
                  </div>
                  ${session.summary.result
                    ? html`<div class="governance-summary-callout">${session.summary.result}</div>`
                    : null}
                  <div class="governance-ledger">
                    ${session.votes.length === 0
                      ? html`<div class="empty-state">No votes recorded yet.</div>`
                      : session.votes.map(vote => html`<${VoteEntry} key=${vote.agent + vote.timestamp} vote=${vote} />`)}
                  </div>
                `
              : html`<div class="empty-state">Detail is unavailable for this decision.</div>`}
    <//>
  `
}

function RouteCard({
  title,
  route,
}: {
  title: string
  route: GovernanceResolvedAction | GovernanceExecutedRoute | null | undefined
}) {
  if (!route) return null
  const toolName = isResolvedActionRoute(route) ? route.resolved_tool : route.delegated_tool
  const targetType = isResolvedActionRoute(route) ? route.target_type : null
  const targetId = isResolvedActionRoute(route) ? route.target_id : null
  const reason = isResolvedActionRoute(route) ? route.reason : null
  const preview = isResolvedActionRoute(route) ? route.payload_preview : null
  return html`
    <div class="governance-side-block">
      <h4>${title}</h4>
      <div class="council-sub">
        ${toolName ? html`<span>tool ${toolName}</span>` : null}
        ${'action_type' in route && route.action_type ? html`<span>action ${route.action_type}</span>` : null}
        ${'confirmation_state' in route && route.confirmation_state ? html`<span>${route.confirmation_state}</span>` : null}
        ${'created_at' in route && route.created_at ? html`<span><${TimeAgo} timestamp=${route.created_at} /></span>` : null}
      </div>
      ${targetType ? html`<div class="governance-side-line">target ${targetType}${targetId ? `:${targetId}` : ''}</div>` : null}
      ${reason ? html`<div class="governance-side-line">${reason}</div>` : null}
      ${preview ? html`<pre class="council-detail governance-preview">${serializePreview(preview)}</pre>` : null}
    </div>
  `
}

function GuardrailPane() {
  const item = getSelectedDecision()
  const debate = selectedDebateDetail.value
  const session = selectedConsensusDetail.value
  const context = debate?.context ?? session?.context ?? item?.context
  const judgment = debate?.judgment ?? session?.judgment
  const guardrail = item?.guardrail_state
  const judge = governanceData.value?.judge
  return html`
    <div class="governance-side-column">
      <${Card} title="Why / Guardrail" class="section" semanticId="governance.guardrail">
        ${!item
          ? html`<div class="empty-state">Select a decision to inspect judgment and route.</div>`
          : html`
              <div class="governance-side-block">
                <h4>Judge</h4>
                <div class="council-sub">
                  <span>${judge?.judge_online ? 'online' : 'offline'}</span>
                  ${judge?.model_used ? html`<span>${judge.model_used}</span>` : null}
                  ${judge?.generated_at ? html`<span><${TimeAgo} timestamp=${judge.generated_at} /></span>` : null}
                </div>
                ${item.judgment_summary
                  ? html`<div class="governance-summary-callout">${item.judgment_summary}</div>`
                  : html`<div class="governance-side-line">No current LLM judgment. Showing truth layer only.</div>`}
                <div class="council-sub">
                  <span>confidence ${confidenceText(item.confidence)}</span>
                  ${judgment?.keeper_name ? html`<span>${judgment.keeper_name}</span>` : null}
                </div>
              </div>

              <${RouteCard} title="Recommended Route" route=${item.recommended_action} />
              <${RouteCard} title="Executed Route" route=${item.executed_route} />

              <div class="governance-side-block">
                <h4>Guardrail State</h4>
                <div class="council-sub">
                  <span>${guardrail?.requires_human_gate ? 'human gate required' : 'no human gate'}</span>
                  ${guardrail?.ready_to_execute ? html`<span>ready to execute</span>` : null}
                </div>
                ${guardrail?.pending_confirm
                  ? html`
                      <div class="governance-side-line">
                        pending ${guardrail.pending_confirm.action_type || 'action'}
                        ${guardrail.pending_confirm.target_type ? ` on ${guardrail.pending_confirm.target_type}` : ''}
                      </div>
                      <div class="governance-action-row">
                        <button
                          class="control-btn secondary"
                          onClick=${() => respondToPendingConfirm('confirm')}
                          disabled=${governanceActing.value}
                        >
                          ${governanceActing.value ? 'Working...' : 'Approve'}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${() => respondToPendingConfirm('deny')}
                          disabled=${governanceActing.value}
                        >
                          ${governanceActing.value ? 'Working...' : 'Deny'}
                        </button>
                      </div>
                    `
                  : html`<div class="governance-side-line">No pending human gate for this decision.</div>`}
              </div>
            `}
      <//>

      <${Card} title="Context" class="section" semanticId="governance.context">
        ${!item
          ? html`<div class="empty-state">No context selected.</div>`
          : html`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${context?.board_post_id ? html`<span class="governance-chip">board ${context.board_post_id}</span>` : null}
                  ${context?.task_id ? html`<span class="governance-chip">task ${context.task_id}</span>` : null}
                  ${context?.operation_id ? html`<span class="governance-chip">operation ${context.operation_id}</span>` : null}
                  ${context?.team_session_id ? html`<span class="governance-chip">session ${context.team_session_id}</span>` : null}
                </div>
                ${item.related_agents.length > 0
                  ? html`
                      <div class="governance-side-line">related agents</div>
                      <div class="governance-chip-row">
                        ${item.related_agents.map(name => html`<span class="governance-chip dim">${name}</span>`)}
                      </div>
                    `
                  : html`<div class="governance-side-line">No explicit linked context recorded.</div>`}
                ${item.evidence_refs.length > 0
                  ? html`
                      <div class="governance-side-line">evidence refs</div>
                      <div class="governance-chip-row">
                        ${item.evidence_refs.map(ref => html`<span class="governance-chip">${ref}</span>`)}
                      </div>
                    `
                  : null}
              </div>
          `}
      <//>

      <${Card} title="Recent Activity" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(governanceData.value?.activity ?? []).slice(0, 8).map((event: GovernanceTimelineEvent) => html`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${toneClass(event.kind)}">${event.kind}</span>
                ${event.actor ? html`<strong>${event.actor}</strong>` : null}
                ${event.created_at ? html`<span><${TimeAgo} timestamp=${event.created_at} /></span>` : null}
              </div>
              <div class="governance-ledger-body">${event.summary || event.topic || 'Activity recorded.'}</div>
            </div>
          `)}
          ${(governanceData.value?.activity ?? []).length === 0
            ? html`<div class="empty-state">No governance activity recorded.</div>`
            : null}
        </div>
      <//>
    </div>
  `
}

export function Governance() {
  useEffect(() => {
    void refreshGovernance()
  }, [])

  return html`
    <div>
      <${SurfaceSemanticIntro} surfaceId="governance" />
      <${GovernanceSummaryStrip} />
      <${GovernanceToolbar} />
      <div class="governance-layout">
        <${DecisionInbox} />
        <${DecisionDetail} />
        <${GuardrailPane} />
      </div>
    </div>
  `
}

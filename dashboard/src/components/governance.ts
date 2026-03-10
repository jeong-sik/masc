import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import {
  fetchDashboardGovernance,
  fetchDebateStatus,
  startDebate,
} from '../api'
import { registerCouncilRefresh } from '../store'
import type {
  CouncilDebate,
  CouncilDebateSummary,
  CouncilSession,
} from '../types'

type GovernanceSubView = 'debates' | 'voting'

const governanceSubView = signal<GovernanceSubView>('debates')
const governanceDebates = signal<CouncilDebate[]>([])
const governanceSessions = signal<CouncilSession[]>([])
const governanceLoading = signal(false)
const governanceStarting = signal(false)
const governanceError = signal('')
const governanceTopicInput = signal('')
const selectedDebateId = signal<string | null>(null)
const selectedDebateDetail = signal<CouncilDebateSummary | null>(null)
const detailLoading = signal(false)

export async function refreshGovernance() {
  governanceLoading.value = true
  governanceError.value = ''
  try {
    const data = await fetchDashboardGovernance()
    governanceDebates.value = Array.isArray(data.debates) ? data.debates as CouncilDebate[] : []
    governanceSessions.value = Array.isArray(data.sessions) ? data.sessions as CouncilSession[] : []
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
    showToast(message, 'error')
  } finally {
    governanceStarting.value = false
  }
}

async function loadDebateDetail(debateId: string) {
  selectedDebateId.value = debateId
  selectedDebateDetail.value = null
  detailLoading.value = true
  try {
    selectedDebateDetail.value = await fetchDebateStatus(debateId)
  } catch (err) {
    governanceError.value = err instanceof Error ? err.message : 'Failed to load debate detail'
  } finally {
    detailLoading.value = false
  }
}

function GovernanceSummary() {
  return html`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${governanceDebates.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${governanceSessions.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${governanceSubView.value === 'debates' ? 'Debates' : 'Voting'}</strong>
      </div>
    </div>
  `
}

function DebateRow({ debate }: { debate: CouncilDebate }) {
  const selected = selectedDebateId.value === debate.id
  return html`
    <button class="council-row ${selected ? 'selected' : ''}" onClick=${() => loadDebateDetail(debate.id)}>
      <div class="council-row-main">
        <div class="council-topic">${debate.topic}</div>
        <div class="council-sub">
          <span>ID: ${debate.id.slice(0, 10)}</span>
          <span>Arguments: ${debate.argument_count}</span>
          ${debate.created_at ? html`<span><${TimeAgo} timestamp=${debate.created_at} /></span>` : null}
        </div>
      </div>
      <span class="council-state ${debate.status}">${debate.status}</span>
    </button>
  `
}

function SessionRow({ session }: { session: CouncilSession }) {
  return html`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${session.topic}</div>
        <div class="council-sub">
          <span>ID: ${session.id.slice(0, 10)}</span>
          <span>Initiator: ${session.initiator}</span>
          ${session.created_at ? html`<span><${TimeAgo} timestamp=${session.created_at} /></span>` : null}
        </div>
      </div>
      <span class="council-state vote">${session.votes}/${session.quorum}</span>
    </div>
  `
}

function GovernanceTabs() {
  const current = governanceSubView.value
  return html`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${current === 'debates' ? 'active' : ''}" onClick=${() => { governanceSubView.value = 'debates' }}>Debates</button>
      <button class="sub-tab-btn ${current === 'voting' ? 'active' : ''}" onClick=${() => { governanceSubView.value = 'voting' }}>Voting</button>
    </div>
  `
}

function DebateView() {
  return html`
    <div>
      <${Card} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${governanceTopicInput.value}
            onInput=${(event: Event) => { governanceTopicInput.value = (event.target as HTMLInputElement).value }}
            onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') submitDebate() }}
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
        ${governanceError.value ? html`<div class="council-error">${governanceError.value}</div>` : null}
      <//>

      <${Card} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${governanceDebates.value.length === 0
            ? html`<div class="empty-state">No debates yet</div>`
            : governanceDebates.value.map(debate => html`<${DebateRow} key=${debate.id} debate=${debate} />`)}
        </div>
      <//>

      <${Card} title=${selectedDebateId.value ? `Debate Detail (${selectedDebateId.value})` : 'Debate Detail'} class="section" semanticId="governance.debates">
        ${detailLoading.value
          ? html`<div class="loading-indicator">Loading debate detail...</div>`
          : selectedDebateDetail.value
            ? html`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${selectedDebateDetail.value.status}</span>
                  <span>Total arguments: ${selectedDebateDetail.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${selectedDebateDetail.value.support_count}</span>
                  <span>Oppose: ${selectedDebateDetail.value.oppose_count}</span>
                  <span>Neutral: ${selectedDebateDetail.value.neutral_count}</span>
                </div>
                ${selectedDebateDetail.value.summary_text
                  ? html`<pre class="council-detail">${selectedDebateDetail.value.summary_text}</pre>`
                  : null}
              `
            : html`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `
}

function VotingView() {
  return html`
    <${Card} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${governanceSessions.value.length === 0
          ? html`<div class="empty-state">No active sessions</div>`
          : governanceSessions.value.map(session => html`<${SessionRow} key=${session.id} session=${session} />`)}
      </div>
    <//>
  `
}

export function Governance() {
  useEffect(() => {
    void refreshGovernance()
  }, [])

  return html`
    <div>
      <${SurfaceSemanticIntro} surfaceId="governance" />
      <${GovernanceSummary} />
      <${GovernanceTabs} />
      ${governanceSubView.value === 'debates'
        ? html`<${DebateView} />`
        : html`<${VotingView} />`}
    </div>
  `
}

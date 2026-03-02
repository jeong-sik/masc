// Council tab — debate/session visibility + quick debate start

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import {
  fetchCouncilSessions,
  fetchDebates,
  fetchDebateStatus,
  startDebate,
} from '../api'
import { serverStatus } from '../store'
import type { CouncilDebate, CouncilDebateSummary, CouncilSession } from '../types'

const debates = signal<CouncilDebate[]>([])
const sessions = signal<CouncilSession[]>([])
const topicInput = signal('')
const loading = signal(false)
const starting = signal(false)
const errorText = signal('')
const selectedDebateId = signal<string | null>(null)
const selectedDebateDetail = signal<CouncilDebateSummary | null>(null)
const detailLoading = signal(false)

async function refreshCouncil() {
  loading.value = true
  errorText.value = ''
  try {
    const [d, s] = await Promise.all([
      fetchDebates(),
      fetchCouncilSessions(),
    ])
    debates.value = d
    sessions.value = s
  } catch (err) {
    errorText.value = err instanceof Error ? err.message : 'Failed to load council data'
  } finally {
    loading.value = false
  }
}

async function submitDebate() {
  const topic = topicInput.value.trim()
  if (!topic) return
  starting.value = true
  try {
    const created = await startDebate(topic)
    topicInput.value = ''
    showToast(created?.id ? `Debate started: ${created.id}` : 'Debate started', 'success')
    await refreshCouncil()
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to start debate'
    showToast(msg, 'error')
  } finally {
    starting.value = false
  }
}

async function loadDebateDetail(debateId: string) {
  selectedDebateId.value = debateId
  detailLoading.value = true
  selectedDebateDetail.value = null
  try {
    selectedDebateDetail.value = await fetchDebateStatus(debateId)
  } catch (err) {
    errorText.value = err instanceof Error ? err.message : 'Failed to load debate status'
    selectedDebateDetail.value = null
  } finally {
    detailLoading.value = false
  }
}

function DebateRow({ debate }: { debate: CouncilDebate }) {
  const selected = selectedDebateId.value === debate.id
  return html`
    <button
      class="council-row ${selected ? 'selected' : ''}"
      onClick=${() => loadDebateDetail(debate.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${debate.topic}</div>
        <div class="council-sub">
          <span>ID: ${debate.id.slice(0, 10)}</span>
          <span>Args: ${debate.argument_count}</span>
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
          ${session.state ? html`<span>State: ${session.state}</span>` : null}
        </div>
      </div>
      <span class="council-state vote">${session.votes}/${session.quorum}</span>
    </div>
  `
}

function CouncilFeedNotice() {
  const quality = serverStatus.value?.data_quality
  if (!quality) return null
  if (quality.council_feed_ok !== false && !quality.last_sync_at) return null

  return html`
    <div class="feed-health-banner ${quality.council_feed_ok === false ? 'degraded' : 'ok'}">
      <span class="feed-health-title">
        ${quality.council_feed_ok === false ? 'Council feed degraded' : 'Council feed synced'}
      </span>
      ${quality.last_sync_at
        ? html`<span class="feed-health-meta">Last sync: <${TimeAgo} timestamp=${quality.last_sync_at} /></span>`
        : html`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `
}

export function Council() {
  useEffect(() => {
    refreshCouncil()
  }, [])
  const councilFeedDegraded = serverStatus.value?.data_quality?.council_feed_ok === false

  return html`
    <div>
      <${CouncilFeedNotice} />
      <${Card} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${topicInput.value}
            onInput=${(e: Event) => { topicInput.value = (e.target as HTMLInputElement).value }}
            onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') submitDebate() }}
            disabled=${starting.value}
          />
          <button
            class="control-btn secondary"
            onClick=${submitDebate}
            disabled=${starting.value || topicInput.value.trim() === ''}
          >
            ${starting.value ? 'Starting...' : 'Start Debate'}
          </button>
          <button class="control-btn ghost" onClick=${refreshCouncil} disabled=${loading.value}>
            ${loading.value ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
        ${errorText.value ? html`<div class="council-error">${errorText.value}</div>` : null}
      <//>

      <div class="council-grid">
        <${Card} title="Debates" class="section">
          <div class="council-list">
            ${debates.value.length === 0
              ? html`
                  <div class="empty-state">
                    ${councilFeedDegraded
                      ? 'No debates loaded (council feed degraded).'
                      : 'No debates yet'}
                  </div>
                `
              : debates.value.map(d => html`<${DebateRow} key=${d.id} debate=${d} />`)}
          </div>
        <//>

        <${Card} title="Voting Sessions" class="section">
          <div class="council-list">
            ${sessions.value.length === 0
              ? html`
                  <div class="empty-state">
                    ${councilFeedDegraded
                      ? 'No sessions loaded (council feed degraded).'
                      : 'No active sessions'}
                  </div>
                `
              : sessions.value.map(s => html`<${SessionRow} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${Card} title=${selectedDebateId.value ? `Debate Detail (${selectedDebateId.value})` : 'Debate Detail'} class="section">
        ${detailLoading.value
          ? html`<div class="loading-indicator">Loading debate detail...</div>`
          : selectedDebateDetail.value
            ? html`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${selectedDebateDetail.value.status}</span>
                  <span>Total arguments: ${selectedDebateDetail.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
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

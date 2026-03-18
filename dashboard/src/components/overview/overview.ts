// MASC Dashboard — Home Command Center
// "What's happening right now?" — answer in 1 second, no scroll.
// Quiet when healthy, loud when something needs attention.

import { html } from 'htm/preact'
import { missionSnapshot } from '../../mission-store'
import { topActiveAgents } from '../../observatory-store'
import { journal } from '../../sse'
import { navigate } from '../../router'
import { formatDuration } from '../mission-utils'
import { SituationBanner } from './situation-banner'
import { AttentionSpotlight } from './attention-spotlight'
import { NarrativeTimeline } from './narrative-timeline'
import { OasPipeline } from './oas-pipeline'
import { AgentAvatar } from './agent-avatar'
import type { ObservatoryAgent } from '../../observatory-store'

// --- Hot Sessions: top 3 active sessions (critical/watch first) ---

function HotSessions() {
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? snap?.session_briefs ?? []
  if (sessions.length === 0) return null

  // Sort: blocker/attention first, then by elapsed time desc
  const sorted = [...sessions].sort((a, b) => {
    const aCrit = a.blocker_summary ? 2 : (a.related_attention_count > 0 ? 1 : 0)
    const bCrit = b.blocker_summary ? 2 : (b.related_attention_count > 0 ? 1 : 0)
    if (aCrit !== bCrit) return bCrit - aCrit
    return (b.elapsed_sec ?? 0) - (a.elapsed_sec ?? 0)
  })
  const top = sorted.slice(0, 3)

  return html`
    <div class="hot-sessions">
      <div class="home-section-header">
        <span class="home-section-label">활성 세션</span>
        <a class="home-section-link" onClick=${() => navigate('situation')}>전체 보기</a>
      </div>
      <div class="hot-sessions__grid">
        ${top.map(s => html`
          <div
            class="hot-session-card ${s.blocker_summary ? 'hot-session-card--critical' : ''}"
            key=${s.session_id}
            onClick=${() => navigate('situation', { session_id: s.session_id })}
          >
            <div class="hot-session-card__goal">${s.goal ?? s.session_id}</div>
            <div class="hot-session-card__meta">
              ${s.member_names?.length ? html`
                <span>${s.member_names.slice(0, 3).join(', ')}${s.member_names.length > 3 ? ` +${s.member_names.length - 3}` : ''}</span>
              ` : null}
              ${s.elapsed_sec ? html`<span>${formatDuration(s.elapsed_sec)}</span>` : null}
            </div>
            ${s.blocker_summary ? html`
              <div class="hot-session-card__blocker">${s.blocker_summary}</div>
            ` : null}
          </div>
        `)}
      </div>
    </div>
  `
}

// --- Agent Pulse: top 8 active agents ---

function stateIcon(state: string): string {
  if (state === 'working') return '\u26A1'
  if (state === 'watching') return '\uD83D\uDC41\uFE0F'
  if (state === 'quiet') return '\uD83D\uDCA4'
  return '\u26AB'
}

function AgentPulse() {
  const agents = topActiveAgents.value
  if (agents.length === 0) return null

  return html`
    <div class="agent-pulse">
      <div class="home-section-header">
        <span class="home-section-label">에이전트</span>
        <a class="home-section-link" onClick=${() => navigate('agents')}>전체 보기</a>
      </div>
      <div class="agent-pulse__grid">
        ${agents.map((a: ObservatoryAgent) => html`
          <div
            class="agent-pulse-card agent-pulse-card--${a.state}"
            key=${a.name}
            onClick=${() => navigate('agents', { agent: a.name })}
          >
            <${AgentAvatar} name=${a.name} emoji=${a.emoji} size=${28} />
            <div class="agent-pulse-card__info">
              <span class="agent-pulse-card__name">${a.koreanName ?? a.name}</span>
              <span class="agent-pulse-card__status">
                ${stateIcon(a.state)} ${a.focus ?? a.currentTask ?? a.status}
              </span>
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}

// --- Overview (Home) ---

export function Overview() {
  const snap = missionSnapshot.value
  const roomHealth = snap?.summary?.room_health ?? null

  return html`
    <div class="overview-surface overview-surface--home">
      <${SituationBanner} snap=${snap} roomHealth=${roomHealth} />
      <${AttentionSpotlight} snap=${snap} />

      <div class="home-body">
        <${HotSessions} />
        <${AgentPulse} />

        <${OasPipeline} />

        <div class="home-section-header">
          <span class="home-section-label">최근 활동</span>
        </div>
        <${NarrativeTimeline} entries=${journal} maxItems=${8} />
      </div>
    </div>
  `
}

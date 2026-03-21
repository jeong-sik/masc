// MASC Dashboard — Home Command Center
// "What's happening right now?" — answer in 1 second, no scroll.
// Quiet when healthy, loud when something needs attention.

import { html } from 'htm/preact'
import { missionSnapshot } from '../../mission-store'
import { topActiveAgents } from '../../observatory-store'
import { journal } from '../../sse'
import { navigate } from '../../router'
import { formatDuration, statusLabel } from '../mission-utils'
import { SituationBanner } from './situation-banner'
import { AttentionSpotlight } from './attention-spotlight'
import { NarrativeTimeline } from './narrative-timeline'
import { OasPipeline } from './oas-pipeline'
import { AgentAvatar } from './agent-avatar'
import type { ObservatoryAgent } from '../../observatory-store'
import type { DashboardMissionSessionBrief } from '../../types'

// --- Hot Sessions: top 3 active sessions (critical/watch first) ---

function sessionStatusRank(status?: string | null): number {
  switch ((status ?? '').trim().toLowerCase()) {
    case 'running':
      return 0
    case 'paused':
      return 1
    case 'pending':
      return 2
    case 'interrupted':
      return 3
    case 'completed':
    case 'done':
      return 4
    default:
      return 5
  }
}

function splitSessionGoal(goal?: string | null, fallback?: string): { primary: string; secondary: string | null } {
  const raw = (goal ?? fallback ?? '').trim()
  if (!raw) return { primary: fallback ?? 'session', secondary: null }
  const parts = raw.split('·').map(part => part.trim()).filter(Boolean)
  return {
    primary: parts[0] ?? raw,
    secondary: parts.length > 1 ? parts.slice(1).join(' · ') : null,
  }
}

function isSystemSession(session: DashboardMissionSessionBrief): boolean {
  return session.origin_kind === 'system'
}

function HomeSectionHeader({
  label,
  copy,
  linkLabel,
  onLink,
}: {
  label: string
  copy?: string
  linkLabel?: string
  onLink?: () => void
}) {
  return html`
    <div class="home-section-header">
      <div>
        <span class="home-section-label">${label}</span>
        ${copy ? html`<div class="home-section-copy">${copy}</div>` : null}
      </div>
      <div class="home-section-actions">
        ${linkLabel && onLink
          ? html`<a class="home-section-link" onClick=${onLink}>${linkLabel}</a>`
          : null}
      </div>
    </div>
  `
}

function renderSessionCard(s: DashboardMissionSessionBrief) {
  const { primary, secondary } = splitSessionGoal(s.goal, s.session_id)
  const creator = (s.created_by ?? '').trim()
  const systemSession = isSystemSession(s)

  return html`
    <div
      class="hot-session-card ${s.blocker_summary ? 'hot-session-card--critical' : ''}"
      key=${s.session_id}
      onClick=${() => navigate('status', { section: 'sessions', session_id: s.session_id })}
    >
      <div class="hot-session-card__goal">${primary}</div>
      ${secondary ? html`<div class="hot-session-card__context">${secondary}</div>` : null}
      <div class="hot-session-card__chips">
        ${creator
          ? html`<span class="hot-session-card__chip ${systemSession ? 'hot-session-card__chip--system' : ''}">
              ${systemSession ? '시스템' : '주체'} · ${creator}
            </span>`
          : null}
        ${s.status ? html`<span class="hot-session-card__chip">${statusLabel(s.status)}</span>` : null}
      </div>
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
  `
}

type SessionLaneProps = {
  title: string
  description: string
  tone: 'human' | 'system'
  sessions: DashboardMissionSessionBrief[]
  emptyCopy: string
}

function SessionLane({ title, description, tone, sessions, emptyCopy }: SessionLaneProps) {
  return html`
    <section class="hot-session-lane hot-session-lane--${tone}">
      <div class="hot-session-lane__header">
        <div>
          <div class="hot-session-lane__title-row">
            <h3 class="hot-session-lane__title">${title}</h3>
            <span class="hot-session-lane__count">${sessions.length}</span>
          </div>
          <p class="hot-session-lane__description">${description}</p>
        </div>
      </div>
      ${sessions.length > 0
        ? html`<div class="hot-sessions__grid">${sessions.map(renderSessionCard)}</div>`
        : html`<div class="hot-session-lane__empty">${emptyCopy}</div>`}
    </section>
  `
}

function HotSessions() {
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? snap?.session_briefs ?? []
  if (sessions.length === 0) return null

  // Sort: blocker/attention first, then by elapsed time desc
  const sorted = [...sessions].sort((a, b) => {
    const aCrit = a.blocker_summary ? 2 : (a.related_attention_count > 0 ? 1 : 0)
    const bCrit = b.blocker_summary ? 2 : (b.related_attention_count > 0 ? 1 : 0)
    if (aCrit !== bCrit) return bCrit - aCrit
    const aStatus = sessionStatusRank(a.status)
    const bStatus = sessionStatusRank(b.status)
    if (aStatus !== bStatus) return aStatus - bStatus
    return (b.elapsed_sec ?? 0) - (a.elapsed_sec ?? 0)
  })
  const userSessions = sorted.filter(s => !isSystemSession(s)).slice(0, 3)
  const systemSessions = sorted.filter(s => isSystemSession(s)).slice(0, 3)

  return html`
    <div class="hot-sessions">
      <${HomeSectionHeader}
        label="팀 세션"
        copy="홈에서는 사람 중심 작업과 자동 런타임을 나눠 보여줍니다."
       
        linkLabel="전체 보기"
        onLink=${() => navigate('status', { section: 'sessions' })}
      />
      <div class="hot-sessions__lanes">
        <${SessionLane}
          title="사용자 작업"
          description="사람이 직접 연 협업 세션과 지금 손대고 있는 일입니다."
          tone="human"
          sessions=${userSessions}
          emptyCopy="지금 보이는 사용자 작업 세션이 없습니다."
        />
        <${SessionLane}
          title="시스템 루프"
          description="Gardener, keeper, operator가 자동으로 유지하거나 정리하는 런타임입니다."
          tone="system"
          sessions=${systemSessions}
          emptyCopy="지금 보이는 시스템 루프 세션이 없습니다."
        />
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
      <${HomeSectionHeader}
        label="에이전트"
       
        linkLabel="전체 보기"
        onLink=${() => navigate('status', { section: 'agents' })}
      />
      <div class="agent-pulse__grid">
        ${agents.map((a: ObservatoryAgent) => html`
          <div
            class="agent-pulse-card agent-pulse-card--${a.state}"
            key=${a.name}
            onClick=${() => navigate('status', { section: 'agents', agent: a.name })}
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

        <${HomeSectionHeader}
          label="최근 활동"
         
        />
        <${NarrativeTimeline} entries=${journal} maxItems=${8} />
      </div>
    </div>
  `
}

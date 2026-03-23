// MASC Dashboard — Home Command Center
// "What's happening right now?" — answer in 1 second, no scroll.

import { html } from 'htm/preact'
import { CountBadge } from '../common/badge'
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

function statusDotColor(status?: string | null): string {
  const s = (status ?? '').trim().toLowerCase()
  if (s === 'running') return 'bg-[var(--ok)]'
  if (s === 'paused' || s === 'interrupted') return 'bg-[var(--warn)]'
  if (s === 'completed' || s === 'done') return 'bg-[var(--text-muted)]'
  return 'bg-[var(--accent)]'
}

function HomeSectionHeader({
  label,
  count,
  linkLabel,
  onLink,
}: {
  label: string
  count?: number
  linkLabel?: string
  onLink?: () => void
}) {
  return html`
    <div class="flex items-center justify-between mb-3">
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">${label}</span>
        ${count != null ? html`<${CountBadge}>${count}<//>` : null}
      </div>
      ${linkLabel && onLink
        ? html`<button type="button" class="text-[10px] text-[var(--accent)] cursor-pointer bg-transparent border-0 p-0 hover:underline" onClick=${onLink}>${linkLabel}</button>`
        : null}
    </div>
  `
}

function renderSessionCard(s: DashboardMissionSessionBrief) {
  const { primary, secondary } = splitSessionGoal(s.goal, s.session_id)
  const creator = (s.created_by ?? '').trim()
  const systemSession = isSystemSession(s)
  const hasBlocker = Boolean(s.blocker_summary)

  return html`
    <div
      class="p-5 rounded-2xl border bg-card/60 backdrop-blur-md cursor-pointer transition-all duration-200 shadow-sm shadow-black/10 hover:shadow-md hover:bg-card hover:-translate-y-0.5 group ${hasBlocker ? 'border-bad/50' : 'border-card-border hover:border-accent/40'}"
      key=${s.session_id}
      onClick=${() => navigate('status', { section: 'sessions', session_id: s.session_id })}
    >
      <div class="flex items-start gap-3 mb-3">
        <span class="w-2.5 h-2.5 rounded-full shrink-0 mt-1 shadow-[0_0_8px_rgba(0,0,0,0.5)] ${statusDotColor(s.status)}"></span>
        <div class="min-w-0 flex-1">
          <div class="text-[14px] font-bold text-text-strong leading-snug truncate group-hover:text-accent transition-colors">${primary}</div>
          ${secondary ? html`<div class="text-[12px] text-text-muted mt-1 truncate">${secondary}</div>` : null}
        </div>
      </div>
      <div class="flex items-center gap-4 text-[11px] text-text-muted/90 pl-6 font-medium">
        ${creator ? html`<span>${systemSession ? '시스템' : creator}</span>` : null}
        ${s.status ? html`<span>${statusLabel(s.status)}</span>` : null}
        ${s.elapsed_sec ? html`<span>${formatDuration(s.elapsed_sec)}</span>` : null}
        ${s.member_names?.length ? html`<span>${s.member_names.length}명</span>` : null}
      </div>
      ${hasBlocker ? html`
        <div class="text-[11px] font-medium text-bad-light mt-4 pl-6 truncate bg-bad/10 py-1.5 px-3 rounded-lg border border-bad/20">${s.blocker_summary}</div>
      ` : null}
    </div>
  `
}

type SessionLaneProps = {
  title: string
  icon: string
  sessions: DashboardMissionSessionBrief[]
  emptyCopy: string
}

function SessionLane({ title, icon, sessions, emptyCopy }: SessionLaneProps) {
  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="text-xs text-[var(--text-muted)]">${icon}</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${title}</span>
        <span class="text-[10px] px-1.5 py-px rounded bg-[var(--white-6)] text-[var(--text-muted)] tabular-nums">${sessions.length}</span>
      </div>
      ${sessions.length > 0
        ? html`<div class="flex flex-col gap-2">${sessions.map(renderSessionCard)}</div>`
        : html`<div class="text-xs text-[var(--text-muted)] py-3 text-center">${emptyCopy}</div>`}
    </div>
  `
}

function HotSessions() {
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? snap?.session_briefs ?? []
  if (sessions.length === 0) return null

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
    <div>
      <${HomeSectionHeader}
        label="세션"
        count=${sessions.length}
        linkLabel="전체 보기 ->"
        onLink=${() => navigate('status', { section: 'sessions' })}
      />
      <div class="grid grid-cols-2 max-[960px]:grid-cols-1 gap-4">
        <${SessionLane}
          title="사용자 작업"
          icon="\u{1F464}"
          sessions=${userSessions}
          emptyCopy="사용자 세션 없음"
        />
        <${SessionLane}
          title="시스템 루프"
          icon="\u{2699}\u{FE0F}"
          sessions=${systemSessions}
          emptyCopy="시스템 세션 없음"
        />
      </div>
    </div>
  `
}

// --- Agent Pulse: top active agents ---

function agentStateDot(state: string): string {
  if (state === 'working') return 'bg-[var(--ok)]'
  if (state === 'watching') return 'bg-[var(--accent)]'
  if (state === 'quiet') return 'bg-[var(--text-muted)]'
  return 'bg-[#555]'
}

function AgentPulse() {
  const agents = topActiveAgents.value
  if (agents.length === 0) return null

  return html`
    <div>
      <${HomeSectionHeader}
        label="에이전트"
        count=${agents.length}
        linkLabel="전체 보기 ->"
        onLink=${() => navigate('status', { section: 'agents' })}
      />
      <div class="grid grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-4">
        ${agents.map((a: ObservatoryAgent) => html`
          <div
            class="flex items-start gap-4 p-5 rounded-2xl border border-card-border bg-card/60 backdrop-blur-md cursor-pointer transition-all duration-200 shadow-sm shadow-black/10 hover:shadow-md hover:bg-card hover:-translate-y-0.5 hover:border-accent/40 group"
            key=${a.name}
            onClick=${() => navigate('status', { section: 'agents', agent: a.name })}
          >
            <${AgentAvatar} name=${a.name} emoji=${a.emoji} size=${40} />
            <div class="flex flex-col min-w-0 flex-1 gap-1.5">
              <div class="flex items-center gap-2">
                <span class="w-2.5 h-2.5 rounded-full shrink-0 shadow-[0_0_8px_rgba(0,0,0,0.5)] ${agentStateDot(a.state)}"></span>
                <span class="text-[14px] font-bold text-text-strong group-hover:text-accent transition-colors">${a.koreanName ?? a.name}</span>
              </div>
              ${a.koreanName && a.koreanName !== a.name ? html`
                <span class="text-[11px] text-text-dim font-mono leading-none tracking-wide">${a.name}</span>
              ` : null}
              <span class="text-[12px] text-text-muted/90 leading-relaxed font-medium mt-0.5" style="display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">
                ${a.focus ?? a.currentTask ?? a.status}
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
    <div class="flex flex-col gap-6">
      <${SituationBanner} snap=${snap} roomHealth=${roomHealth} />
      <${AttentionSpotlight} snap=${snap} />

      <div class="p-6 rounded-xl border border-card-border/50 bg-card/30 backdrop-blur-xl shadow-lg shadow-black/10">
        <${HotSessions} />
      </div>

      <div class="p-6 rounded-xl border border-card-border/50 bg-card/30 backdrop-blur-xl shadow-lg shadow-black/10">
        <${AgentPulse} />
      </div>

      <div class="opacity-90 hover:opacity-100 transition-opacity">
        <${OasPipeline} />
      </div>

      <div class="p-6 rounded-xl border border-card-border/50 bg-card/30 backdrop-blur-xl shadow-lg shadow-black/10">
        <${HomeSectionHeader} label="최근 활동" />
        <${NarrativeTimeline} entries=${journal} maxItems=${8} />
      </div>
    </div>
  `
}

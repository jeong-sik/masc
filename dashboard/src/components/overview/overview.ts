// MASC Dashboard — Home Command Center
// "What's happening right now?" — answer in 1 second, no scroll.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useMemo } from 'preact/hooks'
import { ChevronRight, Users, Zap, Target } from 'lucide-preact'
import { CountBadge } from '../common/badge'
import { ActionButton } from '../common/button'
import { TimeAgo } from '../common/time-ago'
import { StatusDot } from '../common/status-dot'
import { missionLoading, missionSnapshot, refreshMissionSnapshot } from '../../mission-store'
import { topActiveAgents } from '../../observatory-store'
import { namespaceTruth, namespaceTruthLoading, refreshNamespaceTruth } from '../../namespace-truth-store'
import { journal } from '../../sse'
import { formatDuration, statusLabel } from '../mission-utils'
import { SituationBanner } from './situation-banner'
import { AttentionSpotlight } from './attention-spotlight'
import { NarrativeTimeline } from './narrative-timeline'
import { AgentAvatar } from './agent-avatar'
import { TransportHealthPanel } from '../transport-health'
import { PerfSnapshotPanel } from '../perf-snapshot'
import { RouteLink } from '../common/route-link'
import {
  serverStatus,
  shellMetaCognition,
  shellConfigResolution,
  shellRuntimeResolution,
  tasks,
  keepers,
} from '../../store'
import type { ObservatoryAgent } from '../../observatory-store'
import type {
  DashboardConfigResolutionItem,
  DashboardMissionSessionBrief,
  DashboardShellMetaCognitionSummary,
} from '../../types'
import type { ReadonlySignal } from '@preact/signals'

const OVERVIEW_STALE_MS = 300_000
/** Warn tier threshold: 1 minute. Matches Vercel deployment row "Last
    updated" turn-amber gate. Picked by convention — most observability
    dashboards use a ~60s boundary between "fresh" and "getting old". */
const OVERVIEW_WARN_MS = 60_000

type FreshnessTier = 'unknown' | 'fresh' | 'warn' | 'stale'

/** Pure: classify snapshot age into a 4-tier health reading that maps
    1:1 to StatusDot tones (unknown=muted, fresh=ok, warn=amber, stale=bad).
    Reference UIs: Vercel / Uptime Kuma / Linear cycle row dots all
    use this same 4-tier pattern so operators can scan a grid of rows
    for \"one of these is not like the others\" in sub-second time. */
export function classifyFreshness(ageMs: number | null | undefined): FreshnessTier {
  if (ageMs == null || Number.isNaN(ageMs)) return 'unknown'
  if (ageMs < 0) return 'fresh' // clock-skew guard: treat future timestamps as fresh
  if (ageMs < OVERVIEW_WARN_MS) return 'fresh'
  if (ageMs < OVERVIEW_STALE_MS) return 'warn'
  return 'stale'
}

/** Pure: Tailwind tone class for a freshness tier. Shared with any
    caller that wants to render a consistent indicator (future dashboard
    surfaces, log viewer header, etc.). */
export function freshnessTierToneClass(tier: FreshnessTier): string {
  switch (tier) {
    case 'unknown': return 'bg-[var(--text-muted)]'
    case 'fresh':   return 'bg-ok shadow-[0_0_6px_rgba(74,222,128,0.55)]'
    case 'warn':    return 'bg-warn shadow-[0_0_6px_rgba(255,176,32,0.5)]'
    case 'stale':   return 'bg-bad shadow-[0_0_6px_rgba(248,113,113,0.55)]'
  }
}

/** Pure: aria-label for screen readers. The StatusDot itself is
    aria-hidden by default, but we expose this so the caller can wrap
    it in role=\"img\" when the dot appears standalone (no adjacent
    text like the \"마지막 갱신\" line that already narrates the state). */
export function freshnessTierAriaLabel(tier: FreshnessTier): string {
  switch (tier) {
    case 'unknown': return '상태 알 수 없음'
    case 'fresh':   return '신선함'
    case 'warn':    return '오래됨 (1분 이상)'
    case 'stale':   return 'stale (5분 이상)'
  }
}

/** Pure: is an Op Hub tile "active" (non-zero count, draws the eye)?
    Single-seam helper so the tile style decisions below — number
    color, border, footnote mute — share one truth source. Reference
    UIs (Stripe dashboard "$0" customer cards, Linear backlog zero
    counters, GitHub PR-review counters): when the count is zero the
    whole tile dims; when non-zero it snaps back to full contrast.
    The operator's eye then skips the quiet tiles without consciously
    parsing them. */
export function opHubTileIsActive(count: number): boolean {
  return Number.isFinite(count) && count > 0
}

/** Pure: Tailwind class for the giant count number.
    Active tile → full strong text; zero/idle → muted so three zero
    tiles don't collectively shout. */
export function opHubTileNumberClass(count: number): string {
  return opHubTileIsActive(count)
    ? 'mt-1 text-[24px] font-bold text-[var(--text-strong)]'
    : 'mt-1 text-[24px] font-bold text-[var(--text-dim)]'
}

/** Pure: Tailwind class for the tile border + background. Active tile
    gets a gentle accent ring so the eye catches the \"not like the
    others\" without the tile screaming. Zero tile falls back to the
    existing subdued card style. */
export function opHubTileBorderClass(count: number): string {
  return opHubTileIsActive(count)
    ? 'rounded-lg border border-accent/30 bg-accent/5 p-3'
    : 'rounded-lg border border-card-border/35 bg-card/55 p-3'
}

function timestampToMs(timestamp?: string | null): number | null {
  if (!timestamp) return null
  const value = Date.parse(timestamp)
  return Number.isNaN(value) ? null : value
}

function oldestTimestamp(...timestamps: Array<string | null | undefined>): string | null {
  const candidates = timestamps
    .flatMap(timestamp => {
      const value = timestampToMs(timestamp)
      return value == null || !timestamp ? [] : [{ timestamp, value }]
    })
    .sort((a, b) => a.value - b.value)
  return candidates[0]?.timestamp ?? null
}

function OverviewFreshnessStrip() {
  const generatedAt = oldestTimestamp(
    missionSnapshot.value?.generated_at ?? null,
    namespaceTruth.value?.generated_at ?? null,
  )
  const generatedMs = timestampToMs(generatedAt)
  const ageMs = generatedMs != null ? Date.now() - generatedMs : null
  const tier = classifyFreshness(ageMs)
  const isStale = tier === 'stale'
  const refreshing = missionLoading.value || namespaceTruthLoading.value

  return html`
    <div class="rounded border px-4 py-3 shadow-sm shadow-black/8 ${isStale ? 'border-warn/35 bg-warn/10' : 'border-card-border/40 bg-card/24'}">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <${StatusDot}
              size="sm"
              class=${freshnessTierToneClass(tier)}
              ariaLabel=${freshnessTierAriaLabel(tier)}
              testId="overview-freshness-dot"
            />
            <span class="text-[11px] font-semibold uppercase tracking-[0.18em] text-[var(--text-muted)]">Overview Freshness</span>
            ${tier === 'warn'
              ? html`<span class="rounded-full border border-warn/25 bg-warn/10 px-2 py-0.5 text-[11px] font-medium text-warn">1분 이상 경과</span>`
              : null}
            ${isStale
              ? html`<span class="rounded-full border border-warn/30 bg-warn/15 px-2 py-0.5 text-[11px] font-semibold text-warn">5분 이상 stale</span>`
              : null}
          </div>
          <div class="mt-1 text-[13px] text-[var(--text-body)]">
            마지막 갱신:
            ${generatedAt
              ? html` <strong class="text-[var(--text-strong)]"><${TimeAgo} timestamp=${generatedAt} /></strong>`
              : html` <strong class="text-[var(--text-strong)]">아직 불러오지 않음</strong>`}
          </div>
          <div class="mt-1 text-[11px] text-[var(--text-muted)]">
            기준: project truth와 mission snapshot 중 더 오래된 시각
          </div>
        </div>
        <${ActionButton}
          variant="ghost"
          size="md"
          disabled=${refreshing}
          onClick=${() => {
            void Promise.all([
              refreshNamespaceTruth({ force: true }),
              refreshMissionSnapshot({ force: true }),
            ])
          }}
        >
          ${refreshing ? '새로고침 중...' : '새로고침'}
        <//>
      </div>
    </div>
  `
}

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
  linkTab,
  linkParams,
}: {
  label: string
  count?: number
  linkLabel?: string
  linkTab?: 'monitoring' | 'workspace' | 'command' | 'lab' | 'overview' | 'logs'
  linkParams?: Record<string, string>
}) {
  return html`
    <div class="mb-2.5 flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">${label}</span>
        ${count != null ? html`<${CountBadge}>${count}<//>` : null}
      </div>
      ${linkLabel && linkTab
        ? html`<${RouteLink} tab=${linkTab} params=${linkParams} class="text-[10px] text-[var(--accent)] hover:underline">${linkLabel}<//>`
        : null}
    </div>
  `
}

function metaCognitionTone(summary: DashboardShellMetaCognitionSummary): {
  label: string
  className: string
} {
  if (summary.contested_belief_count > 0 || summary.stagnation_score >= 0.7) {
    return {
      label: '긴장 높음',
      className: 'border-bad/35 bg-bad/10 text-bad-light',
    }
  }
  if (summary.stagnation_score >= 0.45) {
    return {
      label: '정체 감지',
      className: 'border-warn/35 bg-warn/12 text-warn',
    }
  }
  return {
    label: '안정',
    className: 'border-ok/30 bg-ok/10 text-ok',
  }
}

function beliefStatusLabel(status?: string | null): string {
  switch ((status ?? '').trim().toLowerCase()) {
    case 'contested':
      return '이견 있음'
    case 'corroborated':
      return '공감대 강함'
    case 'emerging':
      return '형성 중'
    default:
      return '신호 약함'
  }
}

function tensionSeverityLabel(severity?: string | null): string {
  switch ((severity ?? '').trim().toLowerCase()) {
    case 'high':
      return '긴장 높음'
    case 'medium':
      return '긴장 중간'
    case 'low':
      return '긴장 낮음'
    default:
      return '긴장 관찰'
  }
}

function desireActionabilityLabel(actionability?: string | null): string {
  switch ((actionability ?? '').trim().toLowerCase()) {
    case 'operator':
      return '운영자 액션'
    case 'operator_or_platform':
      return '운영자/플랫폼 액션'
    case 'operator_or_scheduler':
      return '운영자/스케줄러 액션'
    case 'room_or_operator':
      return '프로젝트/운영자 액션'
    default:
      return '추가 판독 필요'
  }
}

function MetaCognitionCard() {
  const summary = shellMetaCognition.value
  const focus = namespaceTruth.value?.focus?.source === 'meta_cognition'
    ? namespaceTruth.value.focus
    : null
  if (!summary || !focus) return null

  const tone = metaCognitionTone(summary)
  const stagnationPct = Math.round(summary.stagnation_score * 100)
  const belief = summary.dominant_belief
  const tension = summary.top_tension
  const desire = summary.top_desire
  const hasNarrative = Boolean(belief || tension || desire)

  return html`
    <div class="rounded border border-card-border/40 bg-card/18 p-4 shadow-sm shadow-black/8">
      <div class="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <${HomeSectionHeader} label="집단 메타인지" />
          <div class="text-[12px] leading-relaxed text-[var(--text-muted)]">
            게시물, 코멘트, 태스크, 거버넌스에서 읽은 현재 공감대와 긴장.
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="rounded-full border px-2.5 py-1 text-[11px] font-semibold ${tone.className}">
            ${tone.label}
          </span>
          <span class="rounded-full border border-card-border/60 bg-card/55 px-2.5 py-1 text-[11px] font-semibold text-[var(--text-strong)]">
            정체 ${stagnationPct}%
          </span>
          ${summary.contested_belief_count > 0
            ? html`
                <span class="rounded-full border border-[var(--warn-20)] bg-[var(--warn-10)] px-2.5 py-1 text-[11px] font-semibold text-[var(--warn-bright)]">
                  이견 ${summary.contested_belief_count}
                </span>
              `
            : null}
        </div>
      </div>

      ${focus
        ? html`
            <div class="mb-3 rounded border border-accent/20 bg-accent/8 px-3 py-2 text-[12px] text-[var(--text-body)]">
              <span class="font-semibold text-[var(--text-strong)]">namespace-truth focus</span>
              <span class="ml-2">${focus.reason}</span>
            </div>
          `
        : null}

      ${hasNarrative
        ? html`
            <div class="grid grid-cols-3 gap-3 max-[960px]:grid-cols-1">
              <div class="rounded border border-card-border/50 bg-card/48 p-3">
                <div class="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">
                  <${Users} size=${12} class="shrink-0" aria-hidden="true" />
                  공감대
                </div>
                <div class="mt-2 text-[13px] font-medium leading-relaxed text-[var(--text-strong)]" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">
                  ${belief?.claim ?? '아직 강한 belief가 드러나지 않았습니다.'}
                </div>
                <div class="mt-2 text-[11px] text-[var(--text-muted)]">
                  ${belief ? `${beliefStatusLabel(belief.status)}${belief.support_agent_count != null ? ` · ${belief.support_agent_count}명 지지` : ''}` : '공감대 형성 전'}
                </div>
              </div>

              <div class="rounded border border-card-border/50 bg-card/48 p-3">
                <div class="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">
                  <${Zap} size=${12} class="shrink-0" aria-hidden="true" />
                  긴장
                </div>
                <div class="mt-2 text-[13px] font-medium leading-relaxed text-[var(--text-strong)]" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">
                  ${tension?.topic ?? '아직 우세한 tension이 없습니다.'}
                </div>
                <div class="mt-2 text-[11px] text-[var(--text-muted)]">
                  ${tension
                    ? `${tensionSeverityLabel(tension.severity)}${tension.needs_operator ? ' · 운영자 개입 필요' : ''}`
                    : '긴장 신호 약함'}
                </div>
              </div>

              <div class="rounded border border-card-border/50 bg-card/48 p-3">
                <div class="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">
                  <${Target} size=${12} class="shrink-0" aria-hidden="true" />
                  욕구
                </div>
                <div class="mt-2 text-[13px] font-medium leading-relaxed text-[var(--text-strong)]" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">
                  ${desire?.desired_state ?? '아직 뚜렷한 collective desire가 없습니다.'}
                </div>
                <div class="mt-2 text-[11px] text-[var(--text-muted)]">
                  ${desire ? desireActionabilityLabel(desire.actionability) : '욕구 신호 약함'}
                </div>
              </div>
            </div>
          `
        : html`
            <div class="rounded border border-dashed border-card-border/50 bg-card/40 px-4 py-5 text-[12px] text-[var(--text-muted)]">
              아직 namespace-level 서사를 만들 만큼 강한 social signal이 쌓이지 않았습니다.
            </div>
          `}
    </div>
  `
}

function renderSessionCard(s: DashboardMissionSessionBrief) {
  const { primary, secondary } = splitSessionGoal(s.goal, s.session_id)
  const creator = (s.created_by ?? '').trim()
  const systemSession = isSystemSession(s)
  const hasBlocker = Boolean(s.blocker_summary)

  return html`
    <${RouteLink}
      tab="monitoring"
      params=${{ section: 'agents', session_id: s.session_id }}
      class="rounded border bg-card/55 p-4 cursor-pointer transition-[transform,background-color,border-color,box-shadow] duration-200 shadow-sm shadow-black/8 hover:shadow-md hover:bg-card hover:-translate-y-0.5 group ${hasBlocker ? 'border-bad/45' : 'border-card-border hover:border-accent/32'}"
      title=${primary}
    >
      <div class="mb-2.5 flex items-start gap-3">
        <span class="w-2.5 h-2.5 rounded-full shrink-0 mt-1 shadow-[0_0_8px_rgba(0,0,0,0.5)] ${statusDotColor(s.status)}"></span>
        <div class="min-w-0 flex-1">
          <div class="text-[14px] font-bold text-text-strong leading-snug truncate group-hover:text-accent transition-colors">${primary}</div>
          ${secondary ? html`<div class="text-[12px] text-text-muted mt-1 truncate">${secondary}</div>` : null}
        </div>
      </div>
      <div class="flex items-center gap-3 text-[11px] text-text-muted/90 pl-5 font-medium">
        ${creator ? html`<span>${systemSession ? '시스템' : creator}</span>` : null}
        ${s.status ? html`<span>${statusLabel(s.status)}</span>` : null}
        ${s.elapsed_sec ? html`<span>${formatDuration(s.elapsed_sec)}</span>` : null}
        ${s.member_names?.length ? html`<span>${s.member_names.length}명</span>` : null}
      </div>
      ${hasBlocker ? html`
        <div class="mt-3 truncate rounded-lg border border-bad/20 bg-bad/10 px-3 py-1.5 pl-5 text-[11px] font-medium text-bad-light">${s.blocker_summary}</div>
      ` : null}
    <//>
  `
}

function HotSessions() {
  const snap = missionSnapshot.value
  const sessions = snap?.sessions ?? []
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
  const userSessions = sorted.filter(s => !isSystemSession(s)).slice(0, 5)

  return html`
    <div>
      <${HomeSectionHeader}
        label="세션"
        count=${userSessions.length}
        linkLabel="전체 보기 ->"
        linkTab="monitoring"
        linkParams=${{ section: 'agents' }}
      />
      ${userSessions.length > 0
        ? html`<div class="grid grid-cols-2 gap-3 max-[960px]:grid-cols-1">${userSessions.map(renderSessionCard)}</div>`
        : html`<div class="text-xs text-[var(--text-muted)] py-6 text-center">활성 세션 없음. 과거 에이전트는 에이전트 탭에서 확인하세요.</div>`}
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

/**
 * Pure filter for the Agent Pulse roster.
 *
 * Case-insensitive substring match on `name`, `koreanName`, `state`, and
 * `focus` (in that order; first match wins) so operators can locate one
 * agent by partial name, switch to everyone in a given state
 * (e.g. `working`), or find agents whose current focus mentions a
 * particular topic.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * useMemo preserves referential equality for the non-filtering path.
 *
 * Input is never mutated; ObservatoryAgent is treated as readonly.
 */
export function filterAgentPulseRows(
  agents: readonly ObservatoryAgent[],
  query: string,
): readonly ObservatoryAgent[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return agents
  return agents.filter(a => {
    if (a.name && a.name.toLowerCase().includes(needle)) return true
    if (a.koreanName && a.koreanName.toLowerCase().includes(needle)) return true
    if (a.state && a.state.toLowerCase().includes(needle)) return true
    if (a.focus && a.focus.toLowerCase().includes(needle)) return true
    return false
  })
}

function AgentPulse() {
  const agents = topActiveAgents.value
  const query = useSignal('')
  const visibleAgents = useMemo(
    () => filterAgentPulseRows(agents, query.value),
    [agents, query.value],
  )
  const isFiltering = query.value.trim() !== ''
  if (agents.length === 0) return null

  return html`
    <div>
      <${HomeSectionHeader}
        label="에이전트"
        count=${agents.length}
        linkLabel="전체 보기 ->"
        linkTab="monitoring"
        linkParams=${{ section: 'agents' }}
      />
      <div class="mb-3 flex items-center justify-between gap-2">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-dim)]">
          ${isFiltering ? `${visibleAgents.length}/${agents.length}명` : `${agents.length}명`}
        </div>
        <input
          type="search"
          value=${query.value}
          placeholder="이름 / 상태 / focus 필터"
          aria-label="에이전트 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="min-w-[160px] max-w-[240px] flex-1 rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
      </div>
      ${isFiltering && visibleAgents.length === 0
        ? html`<div class="py-4 text-center text-[11px] text-[var(--text-dim)]">필터 결과 없음 (${agents.length}명)</div>`
        : null}
      <div class="grid grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-3">
        ${visibleAgents.map((a: ObservatoryAgent) => html`
          <${RouteLink}
            tab="monitoring"
            params=${{ section: 'agents', agent: a.name }}
            class="flex items-start gap-3 p-4 rounded border border-card-border bg-card/55 cursor-pointer transition-[transform,background-color,border-color,box-shadow] duration-200 shadow-sm shadow-black/8 hover:shadow-md hover:bg-card hover:-translate-y-0.5 hover:border-accent/32 group"
            title=${a.koreanName ?? a.name}
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
              <span class="mt-0.5 text-[12px] font-medium leading-relaxed text-text-muted/90" style="display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">
                ${a.focus ?? a.currentTask ?? a.status}
              </span>
            </div>
          <//>
        `)}
      </div>
    </div>
  `
}

// --- Tool Call Health ---

interface CompactKpiProps {
  value: string | number
  valueClass?: string
  label: string
}

function CompactKpi({ value, valueClass, label }: CompactKpiProps) {
  return html`
    <div class="rounded-lg border border-card-border/30 bg-card/40 p-3 text-center">
      <div class="text-[22px] font-bold ${valueClass ?? 'text-text-strong'}">${value}</div>
      <div class="text-[11px] text-text-muted mt-1">${label}</div>
    </div>
  `
}

function ToolCallHealthPanel() {
  const status = serverStatus.value
  const health = status?.tool_call_health
  if (!health || health.tool_calls === 0) return null

  const rate = health.failure_rate
  const hasRate = rate != null
  const rateColor = hasRate ? (rate > 0.1 ? 'text-bad-light' : rate > 0.03 ? 'text-warn' : 'text-ok') : 'text-text-dim'
  const ratePct = hasRate ? `${(rate * 100).toFixed(1)}%` : '-'

  const successRate = hasRate ? ((1 - rate) * 100) : null
  const successColor = successRate != null
    ? (successRate >= 95 ? 'text-ok' : successRate >= 90 ? 'text-warn' : 'text-bad-light')
    : 'text-text-dim'
  const barColor = successRate != null
    ? (successRate >= 95 ? 'bg-[var(--ok-10)]' : successRate >= 90 ? 'bg-[var(--warn-10)]' : 'bg-[var(--bad-10)]')
    : 'bg-[var(--white-5)]0'

  return html`
    <div>
      <${HomeSectionHeader}
        label="도구 호출"
        linkLabel="품질 분석 ->"
        linkTab="monitoring"
        linkParams=${{ section: 'fleet-health', view: 'tool-quality' }}
      />
      <div class="grid grid-cols-4 gap-3 max-[640px]:grid-cols-2">
        <${CompactKpi} value=${health.tool_calls.toLocaleString()} label=${`호출 (${health.window_hours}h)`} />
        <${CompactKpi} value=${successRate != null ? `${successRate.toFixed(1)}%` : '-'} valueClass=${successColor} label="성공률" />
        <${CompactKpi} value=${health.failures} label="실패" />
        <${CompactKpi} value=${ratePct} valueClass=${rateColor} label="실패율" />
      </div>
      ${successRate != null ? html`
        <div class="mt-2 h-1.5 rounded-full overflow-hidden bg-[var(--white-6)]">
          <div class="${barColor} h-full rounded-full transition-all" style="width:${Math.min(successRate, 100)}%" />
        </div>
      ` : null}
    </div>
  `
}

function OperationsHubCard() {
  const truth = namespaceTruth.value
  const pendingApprovals = truth?.command?.pending_approvals ?? 0
  const pendingConfirms =
    truth?.operator?.pending_confirm_summary?.visible_count
    ?? truth?.operator?.pending_confirm_summary?.total_count
    ?? 0
  const attentionCount = truth?.operator?.attention_summary?.count ?? 0
  const focus =
    truth?.focus?.suggested_tab === 'command'
      ? truth.focus
      : null

  return html`
    <div>
      <${HomeSectionHeader}
        label="운영 허브"
        linkLabel="거버넌스 열기 ->"
        linkTab="command"
        linkParams=${{ section: 'operations' }}
      />
      <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-4 max-[900px]:grid-cols-1">
        <div class="rounded border border-card-border/40 bg-card/40 p-4">
          <div class="text-[13px] leading-[1.7] text-[var(--text-body)]">
            판단 검토, 승인 대기, 운영자 개입을 한 화면군으로 묶었습니다.
            위험한 행동은 <strong class="text-[var(--text-strong)]">거버넌스</strong>에서 검토하고,
            즉시 조작은 <strong class="text-[var(--text-strong)]">실시간 개입</strong>에서 처리합니다.
          </div>
          ${focus
            ? html`
                <div class="mt-3 rounded border border-accent/20 bg-accent/8 px-3 py-2 text-[12px] text-[var(--text-body)]">
                  <span class="font-semibold text-[var(--text-strong)]">${focus.label}</span>
                  <span class="ml-2">${focus.reason}</span>
                </div>
              `
            : null}
          <div class="mt-4 grid grid-cols-3 gap-3 max-[720px]:grid-cols-1">
            <div class=${opHubTileBorderClass(pendingApprovals)}>
              <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">정책 승인</div>
              <div class=${opHubTileNumberClass(pendingApprovals)}>${pendingApprovals}</div>
              <div class="mt-1 text-[11px] text-[var(--text-muted)]">pending approvals</div>
            </div>
            <div class=${opHubTileBorderClass(pendingConfirms)}>
              <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">운영 확인</div>
              <div class=${opHubTileNumberClass(pendingConfirms)}>${pendingConfirms}</div>
              <div class="mt-1 text-[11px] text-[var(--text-muted)]">operator confirm queue</div>
            </div>
            <div class=${opHubTileBorderClass(attentionCount)}>
              <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">주의 신호</div>
              <div class=${opHubTileNumberClass(attentionCount)}>${attentionCount}</div>
              <div class="mt-1 text-[11px] text-[var(--text-muted)]">operator attention summary</div>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-2">
          <${RouteLink}
            tab="command"
            params=${{ section: 'operations' }}
            class="rounded border border-accent/25 bg-[var(--accent-10)] px-4 py-3 text-[13px] font-semibold text-accent transition-colors hover:bg-accent/18"
            title="거버넌스 열기"
          >
            거버넌스 열기
          <//>
          <${RouteLink}
            tab="command"
            params=${{ section: 'operations' }}
            class="rounded border border-card-border/45 bg-card/45 px-4 py-3 text-[13px] font-semibold text-[var(--text-strong)] transition-colors hover:bg-card"
            title="실시간 개입 열기"
          >
            실시간 개입
          <//>
        </div>
      </div>
    </div>
  `
}

function JourneyEntryCard() {
  const activeTasks = tasks.value.filter(task => {
    const status = (task.status ?? 'todo').trim()
    return status === 'todo' || status === 'claimed' || status === 'in_progress' || status === 'awaiting_verification'
  }).length
  const liveKeepers = keepers.value.filter(keeper => {
    const status = (keeper.status ?? '').trim().toLowerCase()
    if (keeper.keepalive_running === true) return true
    return !['offline', 'inactive', 'stopped', 'dead'].includes(status)
  }).length
  const blockedJourneys = keepers.value.filter(keeper => keeper.runtime_blocker_class != null).length

  return html`
    <div>
      <${HomeSectionHeader}
        label="여정 맵"
        linkLabel="모니터링에서 열기 ->"
        linkTab="monitoring"
        linkParams=${{ section: 'journey' }}
      />
      <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-4 max-[920px]:grid-cols-1">
        <div class="rounded border border-card-border/40 bg-card/40 p-4">
          <div class="text-[13px] leading-[1.7] text-[var(--text-body)]">
            새 통합 화면입니다. <strong class="text-[var(--text-strong)]">Task → Run → Contract → Keeper → Thinking → Memory → Turn → Life → Cascade</strong>
            를 같은 카드 안에서 읽습니다. task에 묶인 실행 흐름과 task 밖 keeper continuity를 한 화면에서 바로 파악할 때 이쪽이 첫 진입점입니다.
          </div>
          <div class="mt-4 grid grid-cols-3 gap-3 max-[720px]:grid-cols-1">
            <div class=${opHubTileBorderClass(activeTasks)}>
              <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">활성 태스크</div>
              <div class=${opHubTileNumberClass(activeTasks)}>${activeTasks}</div>
              <div class="mt-1 text-[11px] text-[var(--text-muted)]">task journeys</div>
            </div>
            <div class=${opHubTileBorderClass(liveKeepers)}>
              <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">라이브 키퍼</div>
              <div class=${opHubTileNumberClass(liveKeepers)}>${liveKeepers}</div>
              <div class="mt-1 text-[11px] text-[var(--text-muted)]">keeper journeys</div>
            </div>
            <div class=${opHubTileBorderClass(blockedJourneys)}>
              <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">런타임 차단</div>
              <div class=${opHubTileNumberClass(blockedJourneys)}>${blockedJourneys}</div>
              <div class="mt-1 text-[11px] text-[var(--text-muted)]">blocked journeys</div>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-2">
          <${RouteLink}
            tab="monitoring"
            params=${{ section: 'journey' }}
            class="rounded border border-accent/25 bg-[var(--accent-10)] px-4 py-3 text-[13px] font-semibold text-accent transition-colors hover:bg-accent/18"
            title="여정 맵 열기"
          >
            여정 맵 열기
          <//>
          <${RouteLink}
            tab="monitoring"
            params=${{ section: 'observatory' }}
            class="rounded border border-card-border/45 bg-card/45 px-4 py-3 text-[13px] font-semibold text-[var(--text-strong)] transition-colors hover:bg-card"
            title="관찰소 열기"
          >
            관찰소 비교 보기
          <//>
        </div>
      </div>
    </div>
  `
}

function resolutionTone(status?: string | null): string {
  switch ((status ?? '').trim().toLowerCase()) {
    case 'ready':
      return 'border-ok/30 bg-ok/10 text-ok'
    case 'warn':
      return 'border-warn/30 bg-warn/12 text-warn'
    case 'invalid_env':
      return 'border-bad/30 bg-bad/10 text-bad-light'
    default:
      return 'border-card-border/50 bg-card/45 text-[var(--text-muted)]'
  }
}

function sourceSummaryLabel(source?: string | null): string {
  switch ((source ?? '').trim()) {
    case 'env':
      return 'env'
    case 'home_masc':
      return 'home'
    case 'cwd':
      return 'cwd'
    case 'exe_relative':
      return 'exe'
    case 'resolved_base':
      return 'resolved'
    case 'runtime_data':
      return 'runtime'
    case 'prompt_registry':
      return 'prompt'
    default:
      return source && source.length > 0 ? source : 'missing'
  }
}

function PathTruthBlock({
  label,
  item,
}: {
  label: string
  item: DashboardConfigResolutionItem | null | undefined
}) {
  if (!item) return null

  return html`
    <div class="rounded-lg border border-card-border/35 bg-card/45 p-3">
      <div class="flex flex-wrap items-center gap-2">
        <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">${label}</div>
        <span class="rounded-full border px-2 py-0.5 text-[10px] font-semibold ${item.exists ? 'border-ok/25 bg-ok/10 text-ok' : 'border-bad/25 bg-bad/10 text-bad-light'}">
          ${item.exists ? 'present' : 'missing'}
        </span>
        <span class="rounded-full border border-card-border/50 bg-card/55 px-2 py-0.5 text-[10px] text-[var(--text-muted)]">
          ${sourceSummaryLabel(item.source)}
        </span>
      </div>
      <div class="mt-2 break-all font-mono text-[12px] leading-relaxed text-[var(--text-body)]">${item.path}</div>
    </div>
  `
}

function ConfigTruthCard() {
  const configResolution = shellConfigResolution.value
  const runtimeResolution = shellRuntimeResolution.value
  if (!configResolution && !runtimeResolution) return null

  const warningCount =
    (configResolution?.warnings.length ?? 0)
    + (runtimeResolution?.warnings.length ?? 0)
    + (runtimeResolution?.source_mismatch ? 1 : 0)

  return html`
    <div>
      <${HomeSectionHeader}
        label="설정 Truth"
        linkLabel="도구 상세 ->"
        linkTab="lab"
        linkParams=${{ section: 'tools' }}
      />
      <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-4 max-[920px]:grid-cols-1">
        <div class="rounded border border-card-border/40 bg-card/40 p-4">
          <div class="flex flex-wrap items-center gap-2">
            ${configResolution
              ? html`
                  <span class="rounded-full border px-2.5 py-1 text-[11px] font-semibold ${resolutionTone(configResolution.status)}">
                    config ${configResolution.status}
                  </span>
                `
              : null}
            ${runtimeResolution
              ? html`
                  <span class="rounded-full border px-2.5 py-1 text-[11px] font-semibold ${resolutionTone(runtimeResolution.status)}">
                    runtime ${runtimeResolution.status}
                  </span>
                `
              : null}
            ${warningCount > 0
              ? html`
                  <span class="rounded-full border border-warn/25 bg-warn/12 px-2.5 py-1 text-[11px] font-semibold text-warn">
                    warning ${warningCount}
                  </span>
                `
              : html`
                  <span class="rounded-full border border-ok/25 bg-ok/10 px-2.5 py-1 text-[11px] font-semibold text-ok">
                    drift 없음
                  </span>
                `}
          </div>

          <div class="mt-3 text-[13px] leading-[1.7] text-[var(--text-body)]">
            현재 서버가 어떤 config root와 runtime root를 보고 있는지 바로 확인합니다.
            env override, passive copy, nested <code class="font-mono">.masc</code> drift를 여기서 먼저 드러냅니다.
          </div>

          <div class="mt-4 grid grid-cols-3 gap-3 max-[980px]:grid-cols-1">
            <${PathTruthBlock} label="config root" item=${configResolution?.config_root} />
            <${PathTruthBlock} label="runtime root" item=${runtimeResolution?.data_root} />
            <${PathTruthBlock} label="personas" item=${configResolution?.personas} />
          </div>

          ${warningCount > 0
            ? html`
                <div class="mt-4 flex flex-col gap-2">
                  ${configResolution?.warnings.slice(0, 2).map(warning => html`
                    <div class="rounded-lg border border-warn/25 bg-warn/10 px-3 py-2 text-[12px] text-[var(--text-body)]">${warning}</div>
                  `)}
                  ${runtimeResolution?.warnings.slice(0, 2).map(warning => html`
                    <div class="rounded-lg border border-warn/25 bg-warn/10 px-3 py-2 text-[12px] text-[var(--text-body)]">${warning}</div>
                  `)}
                  ${runtimeResolution?.source_mismatch
                    ? html`
                        <div class="rounded-lg border border-bad/25 bg-bad/10 px-3 py-2 text-[12px] text-[var(--text-body)]">
                          workspace와 runtime build source가 다릅니다.
                        </div>
                      `
                    : null}
                </div>
              `
            : null}
        </div>

        <div class="flex flex-col gap-2">
          <${RouteLink}
            tab="command"
            params=${{ section: 'operations', view: 'inspector' }}
            class="rounded border border-accent/25 bg-[var(--accent-10)] px-4 py-3 text-[13px] font-semibold text-accent transition-colors hover:bg-accent/18"
            title="운영 인스펙터 열기"
          >
            운영 인스펙터
          <//>
          <${RouteLink}
            tab="lab"
            params=${{ section: 'tools' }}
            class="rounded border border-card-border/45 bg-card/45 px-4 py-3 text-[13px] font-semibold text-[var(--text-strong)] transition-colors hover:bg-card"
            title="설정 경로 상세"
          >
            설정 경로 상세
          <//>
        </div>
      </div>
    </div>
  `
}

// --- Overview (Home) ---

const OVERVIEW_CARD = 'rounded border border-card-border/40 bg-card/18 p-4 shadow-sm shadow-black/8'

export function Overview() {
  const snap = missionSnapshot.value
  const roomHealth = snap?.summary?.room_health ?? null
  const metaCognitionCard = MetaCognitionCard()
  const configTruthCard = ConfigTruthCard()
  const hotSessions = HotSessions()
  const agentPulse = AgentPulse()
  const toolHealth = ToolCallHealthPanel()
  const journalEntries = (
    Array.isArray(journal as unknown)
      ? { value: journal as unknown as unknown[] }
      : journal
  ) as ReadonlySignal<unknown[]>
  const hasJournal = journalEntries.value.length > 0

  return html`
    <div class="flex flex-col gap-5">
      <${OverviewFreshnessStrip} />
      <${SituationBanner} snap=${snap} roomHealth=${roomHealth} />
      <${AttentionSpotlight} snap=${snap} />

      <div class=${OVERVIEW_CARD}>
        <${JourneyEntryCard} />
      </div>

      <div class=${OVERVIEW_CARD}>
        <${OperationsHubCard} />
      </div>

      ${configTruthCard ? html`<div class=${OVERVIEW_CARD}>${configTruthCard}</div>` : null}

      ${metaCognitionCard}

      ${hotSessions ? html`<div class=${OVERVIEW_CARD}>${hotSessions}</div>` : null}

      ${agentPulse ? html`<div class=${OVERVIEW_CARD}>${agentPulse}</div>` : null}

      ${toolHealth ? html`<div class=${OVERVIEW_CARD}>${toolHealth}</div>` : null}

      <details class=${`group ${OVERVIEW_CARD}`}>
        <summary
          class="cursor-pointer text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider select-none list-none flex items-center gap-2"
          data-testid="infra-status-disclosure"
        >
          <${ChevronRight}
            size=${14}
            class="shrink-0 text-[var(--text-muted)] transition-transform duration-150 group-open:rotate-90"
          />
          인프라 상태
          <span class="text-[10px] font-normal normal-case tracking-normal text-[var(--text-muted)]">Transport · 성능</span>
        </summary>
        <div class="mt-4 flex flex-col gap-4">
          <div class="grid grid-cols-2 gap-4 max-[1100px]:grid-cols-1">
            <${TransportHealthPanel} />
            <${PerfSnapshotPanel} />
          </div>
        </div>
      </details>

      ${hasJournal
        ? html`
            <div class=${OVERVIEW_CARD}>
              <${HomeSectionHeader} label="최근 활동" />
              <${NarrativeTimeline} entries=${journalEntries} maxItems=${8} />
            </div>
          `
        : null}
    </div>
  `
}

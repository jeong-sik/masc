// MASC Dashboard — Overview (slim home)
//
// "What's the party doing today?" in one glance, no scroll.
// 4 sections, top-to-bottom:
//   1. Highlight       — mission.summary.top_attention 1줄
//   2. Funnel          — 5칸 task 카운트 (신규/진행/검증 대기/완료/목표)
//   3. Mission party   — active session 1건 (goal, members, progress bar, blocker)
//   4. Keeper strip    — 상위 3명 (hb 최신순)

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { TimeAgo } from '../common/time-ago'
import { StatusDot } from '../common/status-dot'
import { RouteLink } from '../common/route-link'
import type { KpiCellKind } from '../kpi-cell'
import { KpiStripIsland } from '../kpi-strip-island'
import { AgentAvatar } from './agent-avatar'
import { missionSnapshot } from '../../mission-store'
import { tasks, keepers } from '../../store'
import type { Task, Keeper } from '../../types/core'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionCard,
  OperatorAttentionItem,
} from '../../types/dashboard-mission'

const CARD = 'rounded border border-card-border/40 bg-card/18 p-4 shadow-sm shadow-black/8'

// ─── Funnel ──────────────────────────────────────────────────────────────────

export interface FunnelCounts {
  created: number
  inProgress: number
  awaiting: number
  completed: number
  target: number | null
}

function startOfTodayMs(now: number): number {
  const d = new Date(now)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function parseIsoMs(iso: string | null | undefined): number | null {
  if (iso === null || iso === undefined || iso === '') return null
  const ms = Date.parse(iso)
  return Number.isNaN(ms) ? null : ms
}

export function computeFunnelCounts(
  allTasks: readonly Task[],
  active: DashboardMissionSessionCard | null,
  now: number = Date.now(),
): FunnelCounts {
  const todayMs = startOfTodayMs(now)
  let created = 0
  let inProgress = 0
  let awaiting = 0
  let completed = 0
  for (const t of allTasks) {
    const createdMs = parseIsoMs(t.created_at)
    if (createdMs !== null && createdMs >= todayMs) created++
    switch (t.status) {
      case 'claimed':
      case 'in_progress':
        inProgress++
        break
      case 'awaiting_verification':
        awaiting++
        break
      case 'done': {
        const doneMs = parseIsoMs(t.completed_at)
        if (doneMs !== null && doneMs >= todayMs) completed++
        break
      }
      default:
        break
    }
  }
  const rawTarget = active?.required_count
  const target = typeof rawTarget === 'number' && rawTarget > 0 ? rawTarget : null
  return { created, inProgress, awaiting, completed, target }
}

export function formatTargetRatio(counts: FunnelCounts): string {
  if (counts.target === null) return String(counts.completed)
  const pct = Math.min(100, Math.round((counts.completed / counts.target) * 100))
  return `${counts.completed}/${counts.target} (${pct}%)`
}

function FunnelCard({ counts }: { counts: FunnelCounts }) {
  const awaitingKind: KpiCellKind | undefined = counts.awaiting > 0 ? 'warn' : undefined
  return html`
    <section class=${CARD} aria-label="오늘 상황" data-testid="overview-funnel">
      <header class="flex items-center justify-between mb-3">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]">오늘 상황</h2>
        <span class="text-2xs text-[var(--color-fg-muted)]">task 기준</span>
      </header>
      <${KpiStripIsland}
        ariaLabel="오늘 funnel"
        cols=${5}
        cells=${[
          { variant: 'stacked', label: '신규', value: String(counts.created), testId: 'funnel-created' },
          { variant: 'stacked', label: '진행', value: String(counts.inProgress), testId: 'funnel-in-progress' },
          { variant: 'stacked', label: '검증 대기', value: String(counts.awaiting), kind: awaitingKind, testId: 'funnel-awaiting' },
          { variant: 'stacked', label: '완료', value: String(counts.completed), kind: 'ok', testId: 'funnel-completed' },
          { variant: 'stacked', label: '목표', value: formatTargetRatio(counts), testId: 'funnel-target' },
        ]}
      />
    </section>
  `
}

// ─── Highlight ───────────────────────────────────────────────────────────────

export function severityToneClass(severity?: string | null): string {
  switch ((severity ?? '').toLowerCase()) {
    case 'critical':
    case 'high':
      return 'text-[var(--color-status-err)]'
    case 'warn':
    case 'medium':
      return 'text-[var(--color-status-warn)]'
    default:
      return 'text-[var(--color-fg-muted)]'
  }
}

function Highlight({ attention }: { attention: OperatorAttentionItem | null }) {
  if (attention === null) {
    return html`
      <section class=${CARD} aria-label="오늘의 하이라이트" data-testid="overview-highlight-empty">
        <p class="text-sm text-[var(--color-fg-muted)]">특별한 신호 없음</p>
      </section>
    `
  }
  const severity = attention.severity === '' ? 'info' : attention.severity
  return html`
    <section class=${CARD} aria-label="오늘의 하이라이트" data-testid="overview-highlight">
      <div class="flex items-center gap-2 min-w-0">
        <span class=${`text-2xs font-semibold uppercase tracking-wider shrink-0 ${severityToneClass(severity)}`}>
          ${severity.toUpperCase()}
        </span>
        <span class="truncate text-sm text-[var(--color-fg-secondary)]">${attention.summary}</span>
      </div>
    </section>
  `
}

// ─── Mission Party ───────────────────────────────────────────────────────────

export function pickActiveSession(
  snap: DashboardMissionResponse | null,
): DashboardMissionSessionCard | null {
  if (snap === null) return null
  if (snap.sessions.length === 0) return null
  for (const s of snap.sessions) {
    const status = (s.status ?? '').toLowerCase()
    if (status === 'active' || status === 'running' || status === 'busy') return s
  }
  return snap.sessions[0] ?? null
}

export function progressPct(active: DashboardMissionSessionCard | null): number | null {
  if (active === null) return null
  const req = active.required_count ?? 0
  if (req <= 0) return null
  const seen = active.seen_count ?? active.active_count ?? 0
  return Math.min(100, Math.max(0, Math.round((seen / req) * 100)))
}

function MissionPartyCard({ active }: { active: DashboardMissionSessionCard | null }) {
  if (active === null) {
    return html`
      <section class=${CARD} aria-label="진행 중 파티" data-testid="overview-party-empty">
        <header class="text-xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)] mb-2">진행 중 파티</header>
        <p class="text-sm text-[var(--color-fg-muted)]">활성 미션 없음</p>
      </section>
    `
  }
  const pct = progressPct(active)
  const members = active.member_names.slice(0, 5)
  const extra = Math.max(0, active.member_names.length - members.length)
  const startedAt = active.started_at
  const blocker = active.blocker_summary
  return html`
    <section class=${CARD} aria-label="진행 중 파티" data-testid="overview-party">
      <header class="flex items-center justify-between gap-3 mb-3">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]">진행 중 파티</h2>
        ${startedAt !== null && startedAt !== undefined && startedAt !== ''
          ? html`<${TimeAgo} timestamp=${startedAt} class="text-2xs text-[var(--color-fg-muted)]" />`
          : null}
      </header>
      <p class="text-sm text-[var(--color-fg-secondary)] mb-3 line-clamp-2" data-testid="overview-party-goal">
        🎯 ${active.goal !== '' ? active.goal : '(목표 없음)'}
      </p>
      ${members.length > 0
        ? html`
            <div class="flex items-center gap-2 mb-3 flex-wrap">
              ${members.map(
                name => html`<${AgentAvatar} name=${name} status=${active.health ?? 'idle'} size="sm" />`,
              )}
              ${extra > 0
                ? html`<span class="text-2xs text-[var(--color-fg-muted)]">+${extra}</span>`
                : null}
            </div>
          `
        : null}
      ${pct !== null
        ? html`
            <div class="flex items-center gap-2" data-testid="overview-party-progress">
              <div class="flex-1 h-2 rounded bg-card-border/40 overflow-hidden">
                <div class="h-full bg-[var(--color-status-ok)]" style=${`width: ${pct}%`}></div>
              </div>
              <span class="text-2xs tabular-nums text-[var(--color-fg-muted)]">${pct}%</span>
            </div>
          `
        : null}
      ${blocker !== null && blocker !== undefined && blocker !== ''
        ? html`
            <div
              class="mt-3 rounded border border-[var(--color-status-warn)]/40 bg-[var(--color-status-warn)]/10 px-2 py-1 text-2xs text-[var(--color-status-warn)]"
              data-testid="overview-party-blocker"
            >
              blocker: ${blocker}
            </div>
          `
        : null}
    </section>
  `
}

// ─── Keeper Strip ────────────────────────────────────────────────────────────

function keeperStatusToneClass(status: string): string {
  switch (status.toLowerCase()) {
    case 'active':
    case 'busy':
      return 'bg-[var(--color-status-ok)]'
    case 'offline':
    case 'inactive':
    case 'paused':
      return 'bg-[var(--color-status-err)]'
    default:
      return 'bg-[var(--color-fg-muted)]'
  }
}

export function pickActiveKeepers(all: readonly Keeper[], max: number = 3): Keeper[] {
  const scored: { k: Keeper; score: number }[] = []
  for (const k of all) {
    const hbIso = k.last_heartbeat
    const hb = hbIso !== undefined ? Date.parse(hbIso) : Number.NaN
    const hbScore = Number.isNaN(hb) ? 0 : hb
    const pausedPenalty = k.paused === true ? -1e15 : 0
    scored.push({ k, score: pausedPenalty + hbScore })
  }
  scored.sort((a, b) => b.score - a.score)
  return scored.slice(0, max).map(s => s.k)
}

function KeeperStrip({ keeperList }: { keeperList: readonly Keeper[] }) {
  const top = pickActiveKeepers(keeperList, 3)
  if (top.length === 0) {
    return html`
      <section class=${CARD} aria-label="활성 keeper" data-testid="overview-keepers-empty">
        <p class="text-sm text-[var(--color-fg-muted)]">활성 keeper 없음</p>
      </section>
    `
  }
  return html`
    <section class=${CARD} aria-label="활성 keeper" data-testid="overview-keepers">
      <header class="text-xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)] mb-2">활성 keeper</header>
      <ul class="flex flex-col gap-2">
        ${top.map(
          k => html`
            <li class="flex items-center gap-2 min-w-0">
              <${StatusDot} size="sm" class=${keeperStatusToneClass(k.status)} />
              <${RouteLink}
                tab="monitoring"
                params=${{ section: 'keepers', keeper: k.name }}
                class="text-sm text-[var(--color-fg-secondary)] truncate hover:underline"
              >
                ${k.koreanName !== undefined && k.koreanName !== '' ? k.koreanName : k.name}
              <//>
              ${k.last_heartbeat !== undefined
                ? html`
                    <${TimeAgo}
                      timestamp=${k.last_heartbeat}
                      class="text-2xs text-[var(--color-fg-muted)] ml-auto shrink-0"
                    />
                  `
                : null}
            </li>
          `,
        )}
      </ul>
    </section>
  `
}

// ─── Root ────────────────────────────────────────────────────────────────────

export function Overview() {
  const snap = missionSnapshot.value
  const taskList = tasks.value
  const keeperList = keepers.value
  const active = useMemo(() => pickActiveSession(snap), [snap])
  const counts = useMemo(() => computeFunnelCounts(taskList, active), [taskList, active])
  const attention = snap?.summary?.top_attention ?? null
  return html`
    <div class="flex flex-col gap-5">
      <${Highlight} attention=${attention} />
      <${FunnelCard} counts=${counts} />
      <${MissionPartyCard} active=${active} />
      <${KeeperStrip} keeperList=${keeperList} />
    </div>
  `
}

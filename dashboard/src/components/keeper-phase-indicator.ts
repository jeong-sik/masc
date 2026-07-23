// Keeper phase indicator — shows the lifecycle phase
// as a color-coded badge with Korean label.
// Phase = lifecycle health (생명주기), complementary to pipeline_stage (활동).
//
// Color mapping follows the Anyang Sleepers design system (#8177,
// #8235): the 13 phases collapse into 6 visual groups so that across
// a row of 40 keepers the palette reads as 6 semantic categories
// rather than 13 similar-but-subtly-different hues. Individual phase
// is still distinguished by its icon and Korean label — the color
// carries the health meaning, the icon carries the identity.
//
// Values use CSS custom properties so the same palette swaps under
// [data-theme="paper"] without a branch in this file.

import { html } from 'htm/preact'
import type { KeeperPhase } from '../types'
import { toKeeperPhase } from '../keeper-store-normalize'
import { BUFFER_PHASES } from '../lib/keeper-predicates'
import { formatDuration } from '../lib/format-time'

interface PhaseStyle {
  label: string
  /** `var(--token)` string for the text + icon hue. */
  color: string
  /** `var(--token)` for the badge fill (10% alpha variant). */
  bg: string
  /** `var(--token)` for the border (20% alpha variant). */
  border: string
  /** `none` or a `0 0 Xpx color-mix(...)` string. Static by design —
      the token resolves at paint time, so a single literal works for
      both dark and paper palettes. */
  glow: string
  icon: string
}

// 6 visual groups per design system README:
//   ok      running                                          → --ok
//   working compacting · handing_off · draining · restarting → --accent (slate)
//   warn    failing · overflowed                             → --warn
//   paused  paused                                           → --paused
//   inactive offline · stopped · dead                        → --text-muted / --bad-light
//
// Restarting sits with "working" — operators read a restart as
// recovery-in-progress, not a fresh failure. Dead keeps the bad-light
// hue (brick) because it indicates a terminated agent, distinct from
// Stopped (intentional) and Offline (never connected).
const SOFT_GLOW = '0 0 8px color-mix(in srgb, currentColor 25%, transparent)'
const STRONG_GLOW = '0 0 10px color-mix(in srgb, currentColor 32%, transparent)'

export const PHASE_STYLES: Record<KeeperPhase, PhaseStyle> = {
  Offline:    { label: '오프라인',     color: 'var(--color-fg-muted)', bg: 'var(--color-bg-elevated)',   border: 'var(--color-border-default)',   glow: 'none',        icon: '○' },
  Running:    { label: '실행중',       color: 'var(--color-status-ok)',         bg: 'var(--ok-10)',     border: 'var(--ok-20)',      glow: SOFT_GLOW,     icon: '●' },
  Failing:    { label: '오류중',       color: 'var(--color-status-warn)',       bg: 'var(--warn-10)',   border: 'var(--warn-20)',    glow: SOFT_GLOW,     icon: '▲' },
  Overflowed: { label: '컨텍스트초과', color: 'var(--color-status-warn)',       bg: 'var(--warn-10)',   border: 'var(--warn-20)',    glow: SOFT_GLOW,     icon: '⚠' },
  Compacting: { label: '압축중',       color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '◆' },
  HandingOff: { label: '승계중',       color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '⟳' },
  Draining:   { label: '종료중',       color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '▽' },
  Paused:     { label: '일시정지',     color: 'var(--paused)',     bg: 'var(--paused-10)', border: 'var(--paused-20)',  glow: 'none',        icon: '⏸' },
  Stopped:    { label: '정지',         color: 'var(--color-fg-muted)', bg: 'var(--color-bg-elevated)',   border: 'var(--color-border-default)',   glow: 'none',        icon: '■' },
  Crashed:    { label: '비정상종료',   color: 'var(--bad-light)',  bg: 'var(--bad-10)',    border: 'var(--bad-20)',     glow: STRONG_GLOW,   icon: '✕' },
  Restarting: { label: '재시작중',     color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '↺' },
  Dead:       { label: '종료',         color: 'var(--bad-light)',  bg: 'var(--bad-10)',    border: 'var(--bad-20)',     glow: 'none',        icon: '✦' },
}

const PIPELINE_STAGE_DETAIL_LABELS: Record<string, string> = {
  registry_absent: '레지스트리 없음',
  launch_pending_no_fiber: '기동 대기',
  phase_running_idle: '대기',
  health_or_turn_failure_probe: '복구 확인',
  context_overflow_pending_compaction: '압축 대기',
  context_compaction_in_progress: '압축 진행',
  generation_handoff_in_progress: '승계 진행',
  graceful_shutdown_draining: '종료 정리',
  operator_or_policy_paused: '일시정지',
  clean_stop_terminal: '정상 정지',
  crashed_restart_candidate: '재시작 후보',
  dead_tombstone_terminal: 'Dead tombstone',
  structural_failure_terminal: '구조 실패',
}

export function pipelineStageDetailLabel(detail: string | null | undefined): string | null {
  if (!detail) return null
  const trimmed = detail.trim()
  if (!trimmed) return null
  return PIPELINE_STAGE_DETAIL_LABELS[trimmed] ?? trimmed.replaceAll('_', ' ')
}

export function getPhaseStyle(phase: KeeperPhase | string | null | undefined): PhaseStyle {
  if (!phase) return PHASE_STYLES.Offline
  // Use the SSOT boundary parser (`toKeeperPhase`) instead of the raw
  // `as KeeperPhase` assertion. `toKeeperPhase` accepts both PascalCase
  // (canonical `Keeper.phase`) and lowercase backend tokens (the same
  // shape `phase_to_string` emits in
  // `lib/keeper/keeper_state_machine.ml:21-34`) and returns `null` on
  // unknown input. This matches `software-development.md` §"Parse,
  // don't validate": arbitrary strings should be narrowed through a
  // total parser, not coerced through an unchecked cast that silently
  // accesses an undefined record key.
  const typed = toKeeperPhase(phase)
  return typed != null ? PHASE_STYLES[typed] : PHASE_STYLES.Offline
}

/** Phase badge — color-coded pill showing the keeper lifecycle phase. */
export function KeeperPhaseBadge({ phase, compact }: { phase?: KeeperPhase | string | null; compact?: boolean }) {
  const style = getPhaseStyle(phase)
  const isBuffer = BUFFER_PHASES.has(phase ?? '')
  const size = compact ? 'px-1.5 py-px text-3xs' : 'px-2 py-0.5 text-2xs'

  return html`
    <span
      class="inline-flex items-center gap-1 rounded-[var(--r-1)] font-semibold tracking-wide select-none transition-[background-color,border-color,box-shadow] duration-[var(--t-slow)] ${size}"
      style="color: ${style.color}; background: ${style.bg}; border: 1px solid ${style.border}; box-shadow: ${style.glow}; ${isBuffer ? 'animation: loadingPulse 2.5s var(--ease-inout) infinite;' : ''}"
      title="단계: ${phase ?? 'unknown'} — ${style.label}"
      role="status"
      aria-label="${style.label}"
    >
      <span class="text-4xs leading-none" aria-hidden="true">${style.icon}</span>
      ${style.label}
    </span>
  `
}

/** Dual indicator showing both phase (lifecycle) and pipeline_stage (activity).
 *
 * When [phaseEnteredAtSec] is provided (unix seconds, e.g. the
 * [wall_clock_at_decision] of the latest KeeperTransition), a dwell-time
 * chip is rendered between the phase badge and the stage label — e.g.
 * "● 실행중  · 2시간  executing".  The caller is responsible for fetching
 * transitions; the indicator stays dumb and pure.  Dwell is recomputed on
 * every render, so it refreshes along with the enclosing signal updates.
 */
export function KeeperPhaseAndStage({
  phase,
  pipelineStage,
  pipelineStageDetail,
  phaseEnteredAtSec,
}: {
  phase?: KeeperPhase | string | null
  pipelineStage?: string | null
  pipelineStageDetail?: string | null
  phaseEnteredAtSec?: number | null
}) {
  const stageLabel = pipelineStage && pipelineStage !== 'idle' && pipelineStage !== 'offline'
    ? pipelineStage.replace('_', ' ')
    : null
  const detailLabel = pipelineStage === 'offline' || pipelineStage === 'unknown'
    ? pipelineStageDetailLabel(pipelineStageDetail)
    : null
  const title = [
    phase ? `phase=${phase}` : null,
    pipelineStage ? `stage=${pipelineStage}` : null,
    detailLabel ? `reason=${detailLabel}` : null,
    pipelineStageDetail ? `detail=${pipelineStageDetail}` : null,
  ].filter((part): part is string => part !== null).join(' · ')

  const dwellText = (typeof phaseEnteredAtSec === 'number' && Number.isFinite(phaseEnteredAtSec))
    ? formatDuration(Math.max(0, Date.now() / 1000 - phaseEnteredAtSec))
    : null

  return html`
    <div class="flex items-center gap-2 v2-monitoring-row" title=${title || undefined}>
      <${KeeperPhaseBadge} phase=${phase} />
      ${dwellText ? html`
        <span class="text-3xs text-[var(--color-fg-muted)] font-mono tracking-tight" title="현재 phase에 머문 시간"><span aria-hidden="true">· </span>${dwellText}</span>
      ` : null}
      ${stageLabel ? html`
        <span class="text-3xs text-[var(--color-fg-disabled)] font-mono tracking-tight opacity-80">${stageLabel}</span>
      ` : null}
      ${detailLabel ? html`
        <span class="text-3xs text-[var(--color-fg-disabled)] font-mono tracking-tight opacity-80">${detailLabel}</span>
      ` : null}
    </div>
  `
}

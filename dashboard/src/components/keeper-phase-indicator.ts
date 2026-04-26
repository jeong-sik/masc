// Keeper phase indicator — shows the 12-state lifecycle phase
// as a color-coded badge with Korean label.
// Phase = lifecycle health (생명주기), complementary to pipeline_stage (활동).
//
// Color mapping follows the Anyang Sleepers design system (#8177,
// #8235): the 12 phases collapse into 6 visual groups so that across
// a row of 40 keepers the palette reads as 6 semantic categories
// rather than 12 similar-but-subtly-different hues. Individual phase
// is still distinguished by its icon and Korean label — the color
// carries the health meaning, the icon carries the identity.
//
// Values use CSS custom properties so the same palette swaps under
// [data-theme="paper"] without a branch in this file.

import { html } from 'htm/preact'
import type { KeeperPhase } from '../types'
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

const PHASE_STYLES: Record<KeeperPhase, PhaseStyle> = {
  Offline:    { label: '오프라인',     color: 'var(--color-fg-muted)', bg: 'var(--white-5)',   border: 'var(--white-10)',   glow: 'none',        icon: '○' },
  Running:    { label: '실행중',       color: 'var(--color-status-ok)',         bg: 'var(--ok-10)',     border: 'var(--ok-20)',      glow: SOFT_GLOW,     icon: '●' },
  Failing:    { label: '오류중',       color: 'var(--color-status-warn)',       bg: 'var(--warn-10)',   border: 'var(--warn-20)',    glow: SOFT_GLOW,     icon: '▲' },
  Overflowed: { label: '컨텍스트초과', color: 'var(--color-status-warn)',       bg: 'var(--warn-10)',   border: 'var(--warn-20)',    glow: SOFT_GLOW,     icon: '⚠' },
  Compacting: { label: '압축중',       color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '◆' },
  HandingOff: { label: '승계중',       color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '⟳' },
  Draining:   { label: '종료중',       color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '▽' },
  Paused:     { label: '일시정지',     color: 'var(--paused)',     bg: 'var(--paused-10)', border: 'var(--paused-20)',  glow: 'none',        icon: '⏸' },
  Stopped:    { label: '정지',         color: 'var(--color-fg-muted)', bg: 'var(--white-5)',   border: 'var(--white-10)',   glow: 'none',        icon: '■' },
  Crashed:    { label: '비정상종료',   color: 'var(--bad-light)',  bg: 'var(--bad-10)',    border: 'var(--bad-20)',     glow: STRONG_GLOW,   icon: '✕' },
  Restarting: { label: '재시작중',     color: 'var(--color-accent-fg)',     bg: 'var(--accent-10)', border: 'var(--accent-20)',  glow: SOFT_GLOW,     icon: '↺' },
  Dead:       { label: '종료',         color: 'var(--bad-light)',  bg: 'var(--bad-10)',    border: 'var(--bad-20)',     glow: 'none',        icon: '✦' },
}

const BUFFER_PHASES = new Set<string>(['Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Restarting'])

function getPhaseStyle(phase: KeeperPhase | string | null | undefined): PhaseStyle {
  if (!phase) return PHASE_STYLES.Offline
  return PHASE_STYLES[phase as KeeperPhase] ?? PHASE_STYLES.Offline
}

/** Phase badge — color-coded pill showing 12-state lifecycle phase. */
export function KeeperPhaseBadge({ phase, compact }: { phase?: KeeperPhase | string | null; compact?: boolean }) {
  const style = getPhaseStyle(phase)
  const isBuffer = BUFFER_PHASES.has(phase ?? '')
  const size = compact ? 'px-1.5 py-px text-3xs' : 'px-2 py-0.5 text-2xs'

  return html`
    <span
      class="inline-flex items-center gap-1 rounded font-semibold tracking-wide select-none transition-all duration-300 ${size}"
      style="color: ${style.color}; background: ${style.bg}; border: 1px solid ${style.border}; box-shadow: ${style.glow}; ${isBuffer ? 'animation: loadingPulse 2.5s ease-in-out infinite;' : ''}"
      title="Phase: ${phase ?? 'unknown'} — ${style.label}"
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
  phaseEnteredAtSec,
}: {
  phase?: KeeperPhase | string | null
  pipelineStage?: string | null
  phaseEnteredAtSec?: number | null
}) {
  const stageLabel = pipelineStage && pipelineStage !== 'idle' && pipelineStage !== 'offline'
    ? pipelineStage.replace('_', ' ')
    : null

  const dwellText = (typeof phaseEnteredAtSec === 'number' && Number.isFinite(phaseEnteredAtSec))
    ? formatDuration(Math.max(0, Date.now() / 1000 - phaseEnteredAtSec))
    : null

  return html`
    <div class="flex items-center gap-2">
      <${KeeperPhaseBadge} phase=${phase} />
      ${dwellText ? html`
        <span class="text-3xs text-[var(--color-fg-muted)] font-mono tracking-tight" title="현재 phase에 머문 시간">· ${dwellText}</span>
      ` : null}
      ${stageLabel ? html`
        <span class="text-3xs text-[var(--color-fg-disabled)] font-mono tracking-tight opacity-80">${stageLabel}</span>
      ` : null}
    </div>
  `
}

export { PHASE_STYLES, getPhaseStyle }

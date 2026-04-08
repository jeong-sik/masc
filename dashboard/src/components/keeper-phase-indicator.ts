// Keeper phase indicator — shows the 11-state lifecycle phase
// as a color-coded badge with Korean label.
// Phase = lifecycle health (생명주기), complementary to pipeline_stage (활동).

import { html } from 'htm/preact'
import type { KeeperPhase } from '../types'

interface PhaseStyle {
  label: string
  color: string
  bg: string
  border: string
  glow: string
  icon: string
}

const PHASE_STYLES: Record<KeeperPhase, PhaseStyle> = {
  Offline:    { label: '오프라인',   color: '#6b7280', bg: 'rgba(107,114,128,0.08)', border: 'rgba(107,114,128,0.18)', glow: 'none',                             icon: '○' },
  Running:    { label: '실행중',     color: '#34d399', bg: 'rgba(52,211,153,0.08)',  border: 'rgba(52,211,153,0.22)',  glow: '0 0 8px rgba(52,211,153,0.25)',    icon: '●' },
  Failing:    { label: '오류중',     color: '#f97316', bg: 'rgba(249,115,22,0.08)',  border: 'rgba(249,115,22,0.22)',  glow: '0 0 8px rgba(249,115,22,0.25)',    icon: '▲' },
  Compacting: { label: '압축중',     color: '#a855f7', bg: 'rgba(168,85,247,0.08)',  border: 'rgba(168,85,247,0.22)',  glow: '0 0 8px rgba(168,85,247,0.20)',    icon: '◆' },
  HandingOff: { label: '승계중',     color: '#f472b6', bg: 'rgba(244,114,182,0.08)', border: 'rgba(244,114,182,0.22)', glow: '0 0 8px rgba(244,114,182,0.20)',   icon: '⟳' },
  Draining:   { label: '종료중',     color: '#fb923c', bg: 'rgba(251,146,60,0.08)',  border: 'rgba(251,146,60,0.22)',  glow: '0 0 8px rgba(251,146,60,0.20)',    icon: '▽' },
  Paused:     { label: '일시정지',   color: '#a78bfa', bg: 'rgba(167,139,250,0.08)', border: 'rgba(167,139,250,0.22)', glow: 'none',                             icon: '⏸' },
  Stopped:    { label: '정지',       color: '#6b7280', bg: 'rgba(107,114,128,0.08)', border: 'rgba(107,114,128,0.22)', glow: 'none',                             icon: '■' },
  Crashed:    { label: '비정상종료', color: '#ef4444', bg: 'rgba(239,68,68,0.10)',   border: 'rgba(239,68,68,0.28)',   glow: '0 0 10px rgba(239,68,68,0.30)',    icon: '✕' },
  Restarting: { label: '재시작중',   color: '#38bdf8', bg: 'rgba(56,189,248,0.08)',  border: 'rgba(56,189,248,0.22)',  glow: '0 0 8px rgba(56,189,248,0.20)',    icon: '↺' },
  Dead:       { label: '종료',       color: '#4b5563', bg: 'rgba(75,85,99,0.06)',    border: 'rgba(75,85,99,0.18)',    glow: 'none',                             icon: '✦' },
}

const BUFFER_PHASES = new Set<string>(['Failing', 'Compacting', 'HandingOff', 'Draining', 'Restarting'])

function getPhaseStyle(phase: KeeperPhase | string | null | undefined): PhaseStyle {
  if (!phase) return PHASE_STYLES.Offline
  return PHASE_STYLES[phase as KeeperPhase] ?? PHASE_STYLES.Offline
}

/** Phase badge — color-coded pill showing 11-state lifecycle phase. */
export function KeeperPhaseBadge({ phase, compact }: { phase?: KeeperPhase | string | null; compact?: boolean }) {
  const style = getPhaseStyle(phase)
  const isBuffer = BUFFER_PHASES.has(phase ?? '')
  const size = compact ? 'px-1.5 py-px text-[9px]' : 'px-2 py-0.5 text-[10px]'

  return html`
    <span
      class="inline-flex items-center gap-1 rounded-md font-semibold tracking-wide select-none transition-all duration-300 ${size}"
      style="color: ${style.color}; background: ${style.bg}; border: 1px solid ${style.border}; box-shadow: ${style.glow}; ${isBuffer ? 'animation: loadingPulse 2.5s ease-in-out infinite;' : ''}"
      title="Phase: ${phase ?? 'unknown'} — ${style.label}"
      role="status"
      aria-label="${style.label}"
    >
      <span class="text-[8px] leading-none" aria-hidden="true">${style.icon}</span>
      ${style.label}
    </span>
  `
}

/** Dual indicator showing both phase (lifecycle) and pipeline_stage (activity). */
export function KeeperPhaseAndStage({
  phase,
  pipelineStage,
}: {
  phase?: KeeperPhase | string | null
  pipelineStage?: string | null
}) {
  const stageLabel = pipelineStage && pipelineStage !== 'idle' && pipelineStage !== 'offline'
    ? pipelineStage.replace('_', ' ')
    : null

  return html`
    <div class="flex items-center gap-2">
      <${KeeperPhaseBadge} phase=${phase} />
      ${stageLabel ? html`
        <span class="text-[9px] text-[var(--text-dim)] font-mono tracking-tight opacity-70">${stageLabel}</span>
      ` : null}
    </div>
  `
}

export { PHASE_STYLES, getPhaseStyle }

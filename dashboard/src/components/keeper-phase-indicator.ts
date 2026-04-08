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
  icon: string
}

const PHASE_STYLES: Record<KeeperPhase, PhaseStyle> = {
  Offline:    { label: '오프라인',  color: '#6b7280', bg: 'rgba(107,114,128,0.10)', border: 'rgba(107,114,128,0.20)', icon: '⭘' },
  Running:    { label: '실행중',    color: '#34d399', bg: 'rgba(52,211,153,0.10)',  border: 'rgba(52,211,153,0.25)',  icon: '●' },
  Failing:    { label: '오류중',    color: '#f97316', bg: 'rgba(249,115,22,0.10)',  border: 'rgba(249,115,22,0.25)',  icon: '▲' },
  Compacting: { label: '압축중',    color: '#a855f7', bg: 'rgba(168,85,247,0.10)',  border: 'rgba(168,85,247,0.25)',  icon: '◆' },
  HandingOff: { label: '승계중',    color: '#f472b6', bg: 'rgba(244,114,182,0.10)', border: 'rgba(244,114,182,0.25)', icon: '↻' },
  Draining:   { label: '종료중',    color: '#fb923c', bg: 'rgba(251,146,60,0.10)',  border: 'rgba(251,146,60,0.25)',  icon: '▽' },
  Paused:     { label: '일시정지',  color: '#a78bfa', bg: 'rgba(167,139,250,0.10)', border: 'rgba(167,139,250,0.25)', icon: '❚❚' },
  Stopped:    { label: '정지',      color: '#6b7280', bg: 'rgba(107,114,128,0.10)', border: 'rgba(107,114,128,0.25)', icon: '■' },
  Crashed:    { label: '비정상종료', color: '#ef4444', bg: 'rgba(239,68,68,0.10)',  border: 'rgba(239,68,68,0.30)',   icon: '✕' },
  Restarting: { label: '재시작중',  color: '#38bdf8', bg: 'rgba(56,189,248,0.10)',  border: 'rgba(56,189,248,0.25)',  icon: '↺' },
  Dead:       { label: '종료',      color: '#4b5563', bg: 'rgba(75,85,99,0.08)',    border: 'rgba(75,85,99,0.20)',    icon: '✦' },
}

function getPhaseStyle(phase: KeeperPhase | string | null | undefined): PhaseStyle {
  if (!phase) return PHASE_STYLES.Offline
  return PHASE_STYLES[phase as KeeperPhase] ?? PHASE_STYLES.Offline
}

/** Phase badge — color-coded pill showing 11-state lifecycle phase. */
export function KeeperPhaseBadge({ phase }: { phase?: KeeperPhase | string | null }) {
  const style = getPhaseStyle(phase)
  const isBuffer = phase === 'Failing' || phase === 'Compacting' || phase === 'HandingOff'
    || phase === 'Draining' || phase === 'Restarting'

  return html`
    <span
      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[10px] font-semibold tracking-wide select-none"
      style="color: ${style.color}; background: ${style.bg}; border: 1px solid ${style.border}; ${isBuffer ? 'animation: loadingPulse 2.5s ease-in-out infinite;' : ''}"
      title="Phase: ${phase ?? 'unknown'} — ${style.label}"
    >
      <span class="text-[8px] leading-none">${style.icon}</span>
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
    ? pipelineStage
    : null

  return html`
    <div class="flex items-center gap-2">
      <${KeeperPhaseBadge} phase=${phase} />
      ${stageLabel ? html`
        <span class="text-[9px] text-[var(--text-dim)] font-mono">[${stageLabel}]</span>
      ` : null}
    </div>
  `
}

export { PHASE_STYLES, getPhaseStyle }

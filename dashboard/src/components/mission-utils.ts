import { relativeTime as relativeTimeBase, formatDuration } from '../lib/format-time'
import { trimText } from '../lib/truncate'
import { toneClass } from '../lib/tone'
import { statusLabel } from '../lib/status-label'

export { formatDuration, trimText, toneClass, statusLabel }

export function relativeTime(iso?: string | null): string {
  return relativeTimeBase(iso, '방금')
}

export function missionTargetTypeLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'namespace':
      return '프로젝트'
    case 'room':
      return '프로젝트'
    case 'session':
      return '세션'
    case 'operation':
      return '작전'
    case 'keeper':
      return '키퍼'
    case 'agent':
      return '에이전트'
    default:
      return value?.trim() || '대상'
  }
}

export function signalClassLabel(value?: string | null): string | null {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'metadata_gap':
      return '메타데이터 부족'
    case 'mixed':
      return '신호 혼재'
    case '':
      return null
    default:
      return value?.trim() || null
  }
}

export function liveStateClass(status?: string | null, health?: string | null): string {
  const s = (status ?? health ?? '').trim().toLowerCase()
  if (s === 'offline' || s === 'inactive' || s === 'archived') return 'mission-state-offline'
  if (s === 'idle' || s === 'quiet' || s === 'stale' || s === 'paused' || s === 'blocked') return 'mission-state-idle'
  if (s === 'active' || s === 'running' || s === 'ok' || s === 'healthy') return 'mission-state-alive'
  return ''
}

/** Tailwind bg override for the status dot based on live state */
export function dotStateBg(stateClass: string): string {
  if (stateClass === 'mission-state-idle') return 'bg-[var(--warn)]'
  if (stateClass === 'mission-state-offline') return 'bg-[#555]'
  return ''
}

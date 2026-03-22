// Status indicator badge — reusable across agent/task/connection displays

import { html } from 'htm/preact'

interface StatusBadgeProps {
  status: string
  label?: string
}

function statusLabel(status: string): string {
  switch (status.trim().toLowerCase()) {
    case 'active':
    case 'running':
      return '가동 중'
    case 'working':
      return '작업 중'
    case 'watching':
      return '관찰 중'
    case 'quiet':
      return '조용함'
    case 'idle':
      return '유휴'
    case 'ok':
    case 'healthy':
      return '정상'
    case 'warn':
    case 'warning':
    case 'degraded':
      return '주의'
    case 'bad':
    case 'critical':
    case 'error':
    case 'failed':
      return '위험'
    case 'blocked':
      return '막힘'
    case 'paused':
      return '일시정지'
    case 'pending':
      return '대기'
    case 'offline':
    case 'inactive':
      return '오프라인'
    case 'connected':
      return '연결됨'
    case 'disconnected':
      return '끊김'
    case 'ready':
      return '준비됨'
    case 'done':
    case 'completed':
      return '완료'
    case 'unknown':
      return '알 수 없음'
    default:
      return status
  }
}

function statusDotColor(status: string): string {
  switch (status) {
    case 'in_progress':
    case 'running':
      return 'bg-[var(--warn)]'
    case 'interrupted':
    case 'listening':
      return 'bg-[#38bdf8]'
    case 'inactive':
    case 'offline':
      return 'bg-[#5f7199]'
    case 'active':
      return 'bg-[var(--ok)]'
    case 'busy':
    case 'stopped':
      return 'bg-[var(--text-slate)]'
    case 'error':
      return 'bg-[#fb7185]'
    default:
      return 'bg-[var(--text-muted)]'
  }
}

export function StatusBadge({ status, label }: StatusBadgeProps) {
  return html`
    <span class="border border-solid border-[var(--card-border)] ${status} ${status === 'offline' ? 'text-[#8da4cc]' : ''}">
      <span class="size-1.5 rounded-full inline-block ${statusDotColor(status)}"></span>
      ${label ?? statusLabel(status)}
    </span>
  `
}

import { html } from 'htm/preact'
import type { BoardModerationStatus } from '../../types'

type ModerationTone = 'muted' | 'warn' | 'bad' | 'ok'

function normalizeStatus(status: BoardModerationStatus | string | null | undefined): BoardModerationStatus | null {
  const normalized = (status ?? '').trim().toLowerCase()
  if (
    normalized === 'flagged'
    || normalized === 'approved'
    || normalized === 'removed'
    || normalized === 'hidden'
    || normalized === 'warned'
  ) {
    return normalized
  }
  return null
}

function statusLabel(status: BoardModerationStatus | null): string {
  switch (status) {
    case 'flagged':
      return '신고됨'
    case 'approved':
      return '승인됨'
    case 'removed':
      return '삭제됨'
    case 'hidden':
      return '숨김'
    case 'warned':
      return '경고됨'
    default:
      return '신고'
  }
}

function statusTone(status: BoardModerationStatus | null): ModerationTone {
  switch (status) {
    case 'flagged':
    case 'warned':
      return 'warn'
    case 'removed':
    case 'hidden':
      return 'bad'
    case 'approved':
      return 'ok'
    default:
      return 'muted'
  }
}

function toneClass(tone: ModerationTone): string {
  switch (tone) {
    case 'warn':
      return 'bg-[var(--warn-15)] text-[var(--color-status-warn)] border-[var(--warn-30)]'
    case 'bad':
      return 'bg-[var(--bad-10)] text-[var(--color-status-err)] border-[var(--bad-30)]'
    case 'ok':
      return 'bg-[var(--ok-soft)] text-[var(--color-status-ok)] border-[var(--ok-30)]'
    default:
      return 'bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)] border-[var(--color-border-divider)]'
  }
}

export function ModerationBadge({
  status,
  reportCount = 0,
  targetLabel = '콘텐츠',
}: {
  status?: BoardModerationStatus | string | null
  reportCount?: number | null
  targetLabel?: string
}) {
  const normalizedStatus = normalizeStatus(status)
  const normalizedCount = Math.max(0, Math.trunc(reportCount ?? 0))
  if (normalizedStatus === null && normalizedCount === 0) return null
  const label = statusLabel(normalizedStatus)
  const countLabel = normalizedCount > 0 ? ` ${normalizedCount}` : ''
  return html`
    <span
      class=${`inline-flex items-center px-1.5 py-0.5 rounded-[var(--r-1)] text-3xs font-medium border ${toneClass(statusTone(normalizedStatus))}`}
      aria-label=${`${targetLabel} moderation ${label}${normalizedCount > 0 ? ` ${normalizedCount}건` : ''}`}
      title=${
        normalizedCount > 0
          ? (label === '신고'
              ? `신고 ${normalizedCount}건`
              : `${label} · 신고 ${normalizedCount}건`)
          : label
      }
    >
      ${label}${countLabel}
    </span>
  `
}

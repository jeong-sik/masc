// Board display utilities — shared between memory.ts and memory-post-detail.ts

import { navigate } from '../router'
import { findKeeper } from './keeper-utils'
import { openKeeperDetail } from '../components/keeper-detail'
import type { BoardActorIdentity, BoardContributorQuality } from '../types'

/** Strip inline markdown formatting from title text (bold, italic, code). */
export function stripInlineMarkdown(text: string): string {
  return text
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/_(.+?)_/g, '$1')
    .replace(/`(.+?)`/g, '$1')
}

export function boardActorDisplayName(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string {
  const displayName = identity?.display_name?.trim()
  return displayName || authorName
}

export function boardActorRuntimeName(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string | null {
  const runtime = identity?.runtime_agent_name?.trim()
  if (runtime) return runtime
  const raw = identity?.raw?.trim()
  if (raw && raw !== authorName) return raw
  return null
}

export function boardActorAvatarKey(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string {
  return identity?.key?.trim() || boardActorDisplayName(authorName, identity)
}

export function boardActorTitle(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string | undefined {
  const runtime = boardActorRuntimeName(authorName, identity)
  const display = boardActorDisplayName(authorName, identity)
  return runtime && runtime !== display ? `런타임 ${runtime}` : undefined
}

export function contributorQualityPercent(quality?: BoardContributorQuality | null): number | null {
  if (!quality || !Number.isFinite(quality.score)) return null
  return Math.max(0, Math.min(100, Math.round(quality.score * 100)))
}

export function contributorQualityBandLabel(quality?: BoardContributorQuality | null): string {
  switch (quality?.band) {
    case 'excellent':
      return '우수'
    case 'strong':
      return '강함'
    case 'watch':
      return '관찰'
    case 'low':
      return '낮음'
    default:
      return '품질'
  }
}

export function contributorQualityBadgeClass(quality?: BoardContributorQuality | null): string {
  switch (quality?.band) {
    case 'excellent':
    case 'strong':
      return 'bg-[var(--ok-10)] text-[var(--ok-fg)] border-[var(--ok-20)]'
    case 'watch':
      return 'bg-[var(--warn-10)] text-[var(--warn-bright)] border-[var(--warn-20)]'
    case 'low':
      return 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]'
    default:
      return 'bg-[var(--color-bg-muted)] text-[var(--color-fg-muted)] border-[var(--color-border-divider)]'
  }
}

/** Navigate to keeper detail if author is a keeper, otherwise agent profile. */
export function navigateToAuthor(
  authorName: string,
  event?: Event,
  identity?: BoardActorIdentity | null,
) {
  event?.stopPropagation()
  const keeper =
    identity?.kind === 'keeper'
      ? findKeeper(identity.id) ?? findKeeper(identity.raw) ?? findKeeper(authorName)
      : findKeeper(authorName)
  if (keeper) {
    openKeeperDetail(keeper)
  } else {
    navigate('monitoring', { section: 'agents', agent: identity?.raw ?? authorName })
  }
}

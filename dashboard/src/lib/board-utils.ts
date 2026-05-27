// Board display utilities — shared between memory.ts and memory-post-detail.ts

/**
 * User-visible fallback shown when a board message arrives without a
 * `from` field — three board panels (state-block-messages,
 * mention-inbox, message-room-timeline) used to inline the literal
 * `'system'` in `row.message.from ?? 'system'`. Captured here so a
 * future relabel (e.g. localising to `'시스템'` or distinguishing
 * automation from system) updates every panel in one place.
 */
export const SYSTEM_MESSAGE_FROM = 'system'

/**
 * Stable list-item key for a board `Message` row at position `index`.
 *
 * Prefers the message's own id (set by the backend on durable posts).
 * Falls back to `<seq>-<index>` for unposted/draft rows where `id`
 * hasn't been assigned yet, with `'message'` as the seq placeholder.
 *
 * Two board panels (`mention-inbox`, `message-room-timeline`) shipped
 * this exact body file-internal as `rowKey`. A third (`state-block-messages`)
 * uses a different base (`id ?? seq ?? index` single chain) plus a
 * `state-block.slice(0, 24)` suffix and is left on its own helper —
 * a future change to its base policy can adopt this helper once the
 * suffix is parameterised.
 */
export function boardMessageRowKey(message: Message, index: number): string {
  return message.id ?? `${message.seq ?? 'message'}-${index}`
}

/**
 * One-line preview text for a board `Message`.
 *
 * Prefers the state-stripped content (so a message that's *only* a
 * state block falls through to either raw content or `'(empty)'`).
 * The state-only case is what differentiates this fallback chain from
 * the `state-block-messages` panel's variant, which intentionally
 * surfaces `'(state-only message)'` instead because that view is
 * specifically for state-block traffic.
 *
 * Two board panels (`mention-inbox`, `message-room-timeline`) shipped
 * this exact body file-internal as `previewContent`. The third panel
 * (`state-block-messages`) stays on its own variant — its empty branch
 * is `'(state-only message)'` rather than `'(empty)'`, and the fallback
 * chain skips the raw content step.
 */
export function previewBoardMessage(message: Message): string {
  return stripStateBlocks(message.content).trim() || message.content.trim() || '(empty)'
}

import { navigate } from '../router'
import type { Message } from '../types'
import { findKeeper } from './keeper-utils'
import { openKeeperDetail } from '../components/keeper-detail'
import { stripStateBlocks } from '../keeper-message'
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

// Board display utilities — shared between memory.ts and memory-post-detail.ts

import { navigate } from '../router'
import { findKeeper } from './keeper-utils'
import { openKeeperDetail } from '../components/keeper-detail'
import type { BoardActorIdentity } from '../types'

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

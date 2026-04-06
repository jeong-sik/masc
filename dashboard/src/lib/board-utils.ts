// Board display utilities — shared between memory.ts and memory-post-detail.ts

import { navigate } from '../router'
import { findKeeper } from './keeper-utils'
import { openKeeperDetail } from '../components/keeper-detail'

/** Strip inline markdown formatting from title text (bold, italic, code). */
export function stripInlineMarkdown(text: string): string {
  return text
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/_(.+?)_/g, '$1')
    .replace(/`(.+?)`/g, '$1')
}

/** Navigate to keeper detail if author is a keeper, otherwise agent profile. */
export function navigateToAuthor(authorName: string, event?: Event) {
  event?.stopPropagation()
  const keeper = findKeeper(authorName)
  if (keeper) {
    openKeeperDetail(keeper)
  } else {
    navigate('monitoring', { section: 'agents', agent: authorName })
  }
}

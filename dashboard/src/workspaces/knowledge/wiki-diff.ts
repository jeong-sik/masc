import { diffLines } from 'diff'
import type { LineDiffChunk } from './types'

/**
 * Computes line-by-line diff between server's latest Wiki markdown and operator's
 * local draft for explicit `409 conflict_cas` reload-and-diff recovery.
 */
export function computeMarkdownLineDiff(serverText: string, localText: string): readonly LineDiffChunk[] {
  return diffLines(serverText, localText).map((part) => ({
    kind: part.added ? 'added' : part.removed ? 'removed' : 'equal',
    text: part.value,
  }))
}

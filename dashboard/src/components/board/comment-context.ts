import type { BoardComment } from '../../types'

export function focusedCommentNeedsAncestors(comments: readonly BoardComment[], focusedCommentId: string): boolean {
  const byId = new Map(comments.map(comment => [comment.id, comment]))
  const visited = new Set<string>()
  let id: string | null | undefined = focusedCommentId
  while (id && !visited.has(id)) {
    visited.add(id)
    const comment = byId.get(id)
    if (!comment) return true
    id = comment.parent_id
  }
  return false
}


/** Keep the retained page authoritative when paging offsets overlap. */
export function mergeCommentPages(older: readonly BoardComment[], retained: readonly BoardComment[]): BoardComment[] {
  const seen = new Set(retained.map(comment => comment.id))
  const missing = older.filter(comment => {
    if (seen.has(comment.id)) return false
    seen.add(comment.id)
    return true
  })
  return [...missing, ...retained]
}

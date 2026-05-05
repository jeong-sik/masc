import { pushTrace } from './keeper-trace-store'

/**
 * RFC-0028 PR-δ producer: anchored-thread → keeper-trace bridge.
 *
 * Pure mapper — given a snapshot of anchored-thread posts and a set of
 * post ids that have already been emitted, push trace events for the
 * new ones and return the updated set.
 *
 * Why a pure function (not a stateful subscription):
 *   - The owning component (`IdeConversationRailMock`) already has the
 *     fetched `posts` array as a useState value. A pure mapper called
 *     from a `useEffect([posts])` is sufficient and trivially testable.
 *   - Avoids storing per-component state inside the trace store, which
 *     would couple the store to producer lifecycle.
 *   - Module-level mutable state would leak across components and break
 *     the deduplication guarantee on remount.
 *
 * Mapping (BoardPost → KeeperTraceEvent):
 *   id         ← post.id
 *   tsMs       ← Date.parse(post.created_at_iso) (NaN-guarded)
 *   keeperName ← post.author_identity
 *   threadId   ← post.id (BoardPost is the thread itself for now)
 *   line       ← null (BoardPost carries no line anchor; consumers fall
 *                back to the keeper-level no-line bucket per RFC §5)
 *
 * NaN-guard rationale: a malformed `created_at_iso` would otherwise
 * propagate `NaN` into the store and break binary-search insertion. We
 * silently skip such posts — they cannot participate in replay either.
 */

export interface AnchoredThreadProducerInput {
  readonly id: string
  readonly created_at_iso: string
  readonly author_identity: string
}

/**
 * Push trace events for every post not already in `alreadyEmitted` and
 * return the updated set. The caller (typically a component effect)
 * owns the set and re-passes it on each call.
 */
export function bridgePostsToTrace(
  posts: ReadonlyArray<AnchoredThreadProducerInput>,
  alreadyEmitted: ReadonlySet<string>,
): ReadonlySet<string> {
  if (posts.length === 0) return alreadyEmitted
  const next = new Set(alreadyEmitted)
  for (const post of posts) {
    if (next.has(post.id)) continue
    const tsMs = Date.parse(post.created_at_iso)
    if (!Number.isFinite(tsMs)) continue
    pushTrace({
      id: post.id,
      tsMs,
      keeperName: post.author_identity,
      source: 'anchored-thread',
      threadId: post.id,
      line: null,
    })
    next.add(post.id)
  }
  return next
}

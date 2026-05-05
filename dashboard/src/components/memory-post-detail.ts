import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { ActionButton } from './common/button'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { RichComposer } from './common/rich-composer'
import { RichContent } from './common/rich-content'
import { TextInput } from './common/input'
import { stripStateBlocks } from '../keeper-message'
import { navigate } from '../router'
import {
  boardActorAvatarKey,
  boardActorDisplayName,
  boardActorTitle,
  navigateToAuthor,
} from '../lib/board-utils'
import {
  detailComments,
  detailLoading,
  detailPostId,
  commentText,
  commentSubmitting,
  replyingTo,
  loadPostDetail,
  submitComment,
  authorAvatar,
  kindBadgeColor,
  kindLabel,
  visibilityLabel,
  visibilityBadgeColor,
  boardPostKind,
  votePost,
  voteComment,
  refreshBoard,
} from './memory-state'
import type { BoardComment, BoardPost } from './memory-state'

const MAX_INLINE_COMMENT_DEPTH = 5

// ── Expiry chip (returns html, kept in UI layer) ───────────────────
function expiryChip(post: BoardPost) {
  if (!post.expires_at) return null
  const expiresAtMs = Date.parse(post.expires_at)
  if (!Number.isFinite(expiresAtMs)) return null
  if (expiresAtMs <= Date.now()) return html`<span class="inline-flex items-center px-2 py-0.5 rounded-[var(--r-0)] text-3xs tracking-wide uppercase bg-[var(--bad-15)] text-[var(--bad-light)] border border-[var(--bad-30)]">만료됨</span>`
  return html`<span class="inline-flex items-center px-2 py-0.5 rounded-[var(--r-0)] text-3xs tracking-wide uppercase bg-[var(--warn-15)] text-[var(--color-status-warn)] border border-[var(--warn-30)]">만료까지 <${TimeAgo} timestamp=${post.expires_at} /></span>`
}

// ── Comment tree building ──────────────────────────────────────────
function buildCommentTree(comments: BoardComment[]): { roots: BoardComment[]; childrenMap: Map<string, BoardComment[]> } {
  const childrenMap = new Map<string, BoardComment[]>()
  const commentIds = new Set(comments.map((comment) => comment.id))
  const roots: BoardComment[] = []
  for (const c of comments) {
    if (c.parent_id && commentIds.has(c.parent_id)) {
      const siblings = childrenMap.get(c.parent_id) ?? []
      siblings.push(c)
      childrenMap.set(c.parent_id, siblings)
    } else {
      roots.push(c)
    }
  }
  return { roots, childrenMap }
}

export function countCommentDescendants(
  commentId: string,
  childrenMap: ReadonlyMap<string, readonly BoardComment[]>,
  seen: ReadonlySet<string> = new Set(),
): number {
  if (seen.has(commentId)) return 0
  const nextSeen = new Set(seen)
  nextSeen.add(commentId)
  const children = childrenMap.get(commentId) ?? []
  return children.reduce(
    (sum, child) => sum + 1 + countCommentDescendants(child.id, childrenMap, nextSeen),
    0,
  )
}

/**
 * Pure tree-aware text filter on a comment forest.
 *
 * Case-insensitive substring match on `comment.content`.
 *
 * A comment is kept if it matches OR any descendant matches. The ancestor
 * chain is preserved so matches retain their reply context. The returned
 * `childrenMap` contains only entries whose child list survived filtering.
 *
 * Empty/whitespace query returns the original `{ roots, childrenMap }` by
 * reference (no new allocations, preserves referential equality for memo).
 *
 * Input collections are never mutated.
 */
export function filterCommentTree(
  roots: readonly BoardComment[],
  childrenMap: ReadonlyMap<string, readonly BoardComment[]>,
  query: string,
): { roots: readonly BoardComment[]; childrenMap: ReadonlyMap<string, readonly BoardComment[]> } {
  const needle = query.trim().toLowerCase()
  if (needle === '') return { roots, childrenMap }

  const matches = (c: BoardComment): boolean =>
    (c.content ?? '').toLowerCase().includes(needle)

  const nextChildren = new Map<string, readonly BoardComment[]>()

  // Recursively returns a filtered child list if any descendant (or self) matches.
  // Side effect: populates `nextChildren` for any parent whose filtered child list
  // is non-empty.
  const walk = (c: BoardComment): boolean => {
    const children = childrenMap.get(c.id) ?? []
    const keptChildren: BoardComment[] = []
    for (const child of children) {
      if (walk(child)) keptChildren.push(child)
    }
    const selfMatches = matches(c)
    if (keptChildren.length > 0) {
      nextChildren.set(c.id, keptChildren)
      return true
    }
    return selfMatches
  }

  const nextRoots: BoardComment[] = []
  for (const r of roots) {
    if (walk(r)) nextRoots.push(r)
  }
  return { roots: nextRoots, childrenMap: nextChildren }
}

// ── Comment item ───────────────────────────────────────────────────
function CommentItem({
  comment,
  postId,
  depth = 0,
  childrenMap,
  forceThreadExpanded = false,
}: {
  comment: BoardComment
  postId: string
  depth?: number
  childrenMap: ReadonlyMap<string, readonly BoardComment[]>
  forceThreadExpanded?: boolean
}) {
  const contentChars = Array.from(comment.content ?? '')
  const needsTruncation = contentChars.length > 300
  const [expanded, setExpanded] = useState(false)
  const [collapsed, setCollapsed] = useState(false)
  const [deepExpanded, setDeepExpanded] = useState(false)
  const displayText = needsTruncation && !expanded
    ? `${contentChars.slice(0, 297).join('')}...`
    : comment.content
  const isReplying = replyingTo.value === comment.id
  const visualDepth = Math.min(depth, MAX_INLINE_COMMENT_DEPTH)
  const indentStyle = visualDepth > 0 ? { marginLeft: `${visualDepth * 16}px` } : undefined
  const replies = childrenMap.get(comment.id) ?? []
  const replyCount = countCommentDescendants(comment.id, childrenMap)
  const cappedByDepth = !forceThreadExpanded && !deepExpanded && depth >= MAX_INLINE_COMMENT_DEPTH && replies.length > 0
  const showReplies = replies.length > 0 && !collapsed && !cappedByDepth
  const childForceExpanded = forceThreadExpanded || deepExpanded
  const score = comment.vote_balance ?? comment.votes ?? ((comment.votes_up ?? 0) - (comment.votes_down ?? 0))
  const authorLabel = boardActorDisplayName(comment.author, comment.author_identity)
  const authorAvatarKey = boardActorAvatarKey(comment.author, comment.author_identity)
  const authorTitle = boardActorTitle(comment.author, comment.author_identity)

  const handleCommentVote = async (dir: 'up' | 'down') => {
    try {
      await voteComment(comment.id, dir)
      await loadPostDetail(postId)
      refreshBoard()
    } catch (err) {
      console.warn(`[board] comment vote failed (comment=${comment.id}, dir=${dir})`, err instanceof Error ? err.message : err)
      showToast('댓글 투표에 실패했습니다', 'error')
    }
  }

  return html`
    <div style=${indentStyle}>
      <div class="board-comment rounded-[var(--r-1)] p-3 bg-[var(--color-bg-surface)] border border-[var(--color-border-divider)] ${depth > 0 ? 'border-l-2 border-l-[var(--accent-20)]' : ''}">
        <div class="flex items-center gap-2 mb-1.5">
          ${replies.length > 0 && !cappedByDepth ? html`
            <button
              type="button"
              class="flex h-5 w-5 shrink-0 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] text-2xs text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
              aria-expanded=${!collapsed}
              aria-label=${collapsed ? `답글 ${replyCount}개 펼치기` : `답글 ${replyCount}개 접기`}
              onClick=${() => setCollapsed(!collapsed)}
            >${collapsed ? '+' : '−'}</button>
          ` : null}
          <span class="text-xs">${authorAvatar(authorAvatarKey)}</span>
          <${ActionButton} variant="subtle" size="sm" class="text-xs font-medium text-[var(--color-fg-primary)] hover:text-[var(--color-accent-fg)] bg-transparent border-none p-0" title=${authorTitle} ariaLabel=${`작성자 ${authorLabel} 프로필로 이동`} onClick=${() => navigateToAuthor(comment.author, undefined, comment.author_identity)}>${authorLabel}<//>
          <span class="text-2xs text-[var(--color-fg-muted)] opacity-60"><${TimeAgo} timestamp=${comment.created_at} /></span>
          <div class="ml-auto flex items-center gap-1">
            <button
              type="button"
              class="h-5 w-6 rounded-[var(--r-1)] border-0 bg-transparent text-2xs text-[var(--color-fg-muted)] hover:bg-[var(--warn-10)] hover:text-[var(--warn-bright)]"
              aria-label="댓글 추천"
              onClick=${() => handleCommentVote('up')}
            >▲</button>
            <span class="min-w-5 text-center text-2xs font-semibold tabular-nums text-[var(--color-fg-secondary)]">${score}</span>
            <button
              type="button"
              class="h-5 w-6 rounded-[var(--r-1)] border-0 bg-transparent text-2xs text-[var(--color-fg-muted)] hover:bg-[var(--accent-10)] hover:text-[var(--color-accent-fg)]"
              aria-label="댓글 비추천"
              onClick=${() => handleCommentVote('down')}
            >▼</button>
          </div>
          <${ActionButton}
            variant="subtle"
            size="sm"
            class="text-2xs hover:text-[var(--color-accent-fg)] bg-transparent border-0"
            onClick=${() => { replyingTo.value = isReplying ? null : comment.id; commentText.value = '' }}
          >${isReplying ? '취소' : '답글'}<//>
        </div>
        <div class="text-sm text-[var(--color-fg-primary)] leading-paragraph"><${RichContent} text=${displayText} previewLimit=${1} /></div>
        ${needsTruncation ? html`
          <${ActionButton}
            variant="subtle"
            size="sm"
            class="mt-1 text-2xs text-[var(--color-accent-fg)] hover:underline bg-transparent border-0"
            onClick=${() => setExpanded(!expanded)}
          >${expanded ? '접기' : '더 보기...'}<//>
        ` : null}
        ${isReplying ? html`
          <div class="mt-2">
            <${RichComposer}
              value=${commentText.value}
              placeholder="답글 작성..."
              rows=${4}
              disabled=${commentSubmitting.value}
              onValueChange=${(next: string) => { commentText.value = next }}
              helpText="Markdown과 코드 스니펫을 그대로 붙일 수 있습니다."
              previewLimit=${1}
            />
            <div class="mt-2 flex justify-end">
              <${ActionButton}
                variant="ghost"
                size="md"
                class="text-xs bg-[var(--ok-soft)] text-[var(--color-status-ok)] border-[var(--ok-30)] hover:bg-[var(--ok-22)]"
                disabled=${commentSubmitting.value || commentText.value.trim() === ''}
                ariaBusy=${commentSubmitting.value}
                onClick=${() => submitComment(postId, comment.id)}
              >
                ${commentSubmitting.value ? '...' : '등록'}
              <//>
            </div>
          </div>
        ` : null}
        ${collapsed && replyCount > 0 ? html`
          <div class="mt-2 text-2xs text-[var(--color-fg-muted)]">답글 ${replyCount}개 접힘</div>
        ` : null}
        ${cappedByDepth ? html`
          <button
            type="button"
            class="mt-2 rounded-[var(--r-1)] border border-dashed border-[var(--accent-20)] bg-transparent px-2 py-1 text-left text-2xs text-[var(--color-accent-fg)] hover:bg-[var(--accent-10)]"
            onClick=${() => setDeepExpanded(true)}
          >스레드 계속 펼치기 · 답글 ${replyCount}개</button>
        ` : null}
      </div>
      ${showReplies ? html`
        <div class="flex flex-col gap-1.5 mt-1.5">
          ${replies.map(reply => html`<${CommentItem} key=${reply.id} comment=${reply} postId=${postId} depth=${depth + 1} childrenMap=${childrenMap} forceThreadExpanded=${childForceExpanded} />`)}
        </div>
      ` : null}
    </div>
  `
}

// ── Comment thread ─────────────────────────────────────────────────
export function CommentThread({ comments, postId }: { comments: BoardComment[]; postId: string }) {
  const query = useSignal('')
  const [expanded, setExpanded] = useState(false)
  const INITIAL_SHOW = 5

  const { roots, childrenMap } = useMemo(() => buildCommentTree(comments), [comments])
  const { roots: filteredRoots, childrenMap: filteredChildrenMap } = useMemo(
    () => filterCommentTree(roots, childrenMap, query.value),
    [roots, childrenMap, query.value],
  )

  if (comments.length === 0) return html`<${EmptyState} message="아직 댓글이 없습니다" compact />`

  const isFiltering = query.value.trim() !== ''
  const hiddenCount = filteredRoots.length - INITIAL_SHOW
  const visible = expanded || filteredRoots.length <= INITIAL_SHOW
    ? filteredRoots
    : filteredRoots.slice(-INITIAL_SHOW)

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-2 mb-1">
        <div class="text-2xs text-[var(--color-fg-muted)]">댓글 ${comments.length}개${isFiltering ? ` · 일치 ${filteredRoots.length}` : ''}</div>
        <${TextInput}
          type="search"
          value=${query.value}
          placeholder="댓글 내용 검색"
          ariaLabel="댓글 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="ml-auto min-w-35 max-w-55 flex-1 !px-2 !py-1 !text-2xs"
        />
      </div>
      ${isFiltering && filteredRoots.length === 0 ? html`
        <${EmptyState} message=${`"${query.value.trim()}" 일치하는 댓글 없음`} compact />
      ` : null}
      ${!expanded && hiddenCount > 0 ? html`
        <${ActionButton}
          variant="subtle"
          size="sm"
          class="text-xs text-[var(--color-accent-fg)] hover:underline bg-transparent border-0 text-left py-1"
          onClick=${() => setExpanded(true)}
        >이전 댓글 ${hiddenCount}개 더 보기<//>
      ` : null}
      ${visible.map(comment => html`<${CommentItem} key=${comment.id} comment=${comment} postId=${postId} depth=${0} childrenMap=${filteredChildrenMap} />`)}
      ${expanded && hiddenCount > 0 ? html`
        <${ActionButton}
          variant="subtle"
          size="sm"
          class="text-xs hover:text-[var(--color-accent-fg)] bg-transparent border-0 text-left py-1"
          onClick=${() => setExpanded(false)}
        >접기<//>
      ` : null}
    </div>
  `
}

// ── Comment form ───────────────────────────────────────────────────
function CommentForm({ postId }: { postId: string }) {
  return html`
    <div class="mt-4">
      <${RichComposer}
        value=${commentText.value}
        placeholder="댓글 추가..."
        rows=${5}
        disabled=${commentSubmitting.value}
        onValueChange=${(next: string) => { commentText.value = next }}
        helpText="Markdown, 코드 스니펫, URL 링크 카드를 지원합니다."
        previewLimit=${1}
      />
      <div class="mt-2 flex justify-end">
        <${ActionButton}
          variant="ghost"
          size="lg"
          class="text-sm bg-[var(--ok-soft)] text-[var(--color-status-ok)] border-[var(--ok-30)] hover:bg-[var(--ok-22)]"
          disabled=${commentSubmitting.value || commentText.value.trim() === ''}
          ariaBusy=${commentSubmitting.value}
          onClick=${() => submitComment(postId)}
        >
          ${commentSubmitting.value ? '...' : '등록'}
        <//>
      </div>
    </div>
  `
}

// ── Post detail view ───────────────────────────────────────────────
export function PostDetail({ post }: { post: BoardPost }) {
  useEffect(() => {
    if (detailPostId.value !== post.id) {
      loadPostDetail(post.id)
    }
  }, [post.id])

  const handleVote = async (dir: 'up' | 'down') => {
    try {
      await votePost(post.id, dir)
      refreshBoard()
    } catch (err) {
      console.warn(`[board] vote failed (post=${post.id}, dir=${dir})`, err instanceof Error ? err.message : err)
      showToast('투표에 실패했습니다', 'error')
    }
  }
  const authorLabel = boardActorDisplayName(post.author, post.author_identity)
  const authorAvatarKey = boardActorAvatarKey(post.author, post.author_identity)
  const authorTitle = boardActorTitle(post.author, post.author_identity)

  return html`
    <div>
      <${ActionButton}
        variant="ghost"
        size="sm"
        class="mb-4 text-xs"
        onClick=${() => navigate('workspace', { section: 'board' })}
      >← 게시판으로 돌아가기<//>

      <${Card}>
        <div class="flex flex-col gap-4">
          <div>
            <h1 class="m-0 text-2xl font-semibold leading-tight text-[var(--color-fg-secondary)]">${post.title}</h1>
          </div>

          <div class="text-sm text-[var(--color-fg-primary)] leading-loose">
            <${RichContent} text=${stripStateBlocks(post.body)} previewLimit=${4} />
          </div>

          <!-- Author and meta -->
          <div class="flex gap-2.5 items-center flex-wrap pt-3 border-t border-[var(--color-border-divider)]">
            <span class="text-sm">${authorAvatar(authorAvatarKey)}</span>
            <${ActionButton} variant="subtle" size="sm" class="text-xs text-[var(--color-fg-primary)] hover:text-[var(--color-accent-fg)] bg-transparent border-none p-0" title=${authorTitle} ariaLabel=${`작성자 ${authorLabel} 프로필로 이동`} onClick=${() => navigateToAuthor(post.author, undefined, post.author_identity)}>${authorLabel}<//>
            <span class="text-2xs text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${post.created_at} /></span>
            <span class="text-2xs text-[var(--color-fg-muted)]">${post.votes ?? 0} votes</span>
          </div>

          <!-- Badges -->
          ${(post.hearth || post.visibility || post.expires_at || post.classification_reason)
            ? html`
                <div class="flex flex-col gap-2">
                  <div class="flex gap-1.5 flex-wrap">
                    ${post.hearth ? html`<span class="inline-flex items-center px-2 py-0.5 rounded-[var(--r-1)] text-3xs font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${post.hearth}</span>` : null}
                    ${post.visibility && visibilityLabel(post.visibility) ? html`<span class="inline-flex items-center px-2 py-0.5 rounded-[var(--r-1)] text-3xs font-medium border ${visibilityBadgeColor(post.visibility)}">${visibilityLabel(post.visibility)}</span>` : null}
                    <span class="inline-flex items-center px-2 py-0.5 rounded-[var(--r-1)] text-3xs font-medium border ${kindBadgeColor(boardPostKind(post))}">${kindLabel(boardPostKind(post))}</span>
                    ${expiryChip(post)}
                  </div>
                  ${post.classification_reason
                    ? html`<div class="text-2xs text-[var(--color-fg-muted)]">분류 근거: ${post.classification_reason}</div>`
                    : null}
                </div>
              `
            : null}

          <!-- Meta details -->
          ${post.meta
            ? html`
                <details class="mt-1">
                  <summary class="cursor-pointer text-xs text-[var(--color-fg-muted)] py-1.5 hover:text-[var(--color-fg-primary)] transition-colors">운영 메타</summary>
                  <div class="mt-2 p-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] border border-[var(--color-border-divider)]">
                    ${post.meta.source ? html`<div class="text-xs text-[var(--color-fg-primary)]"><span class="text-[var(--color-fg-muted)]">출처:</span> ${post.meta.source}</div>` : null}
                    ${post.meta.state_block
                      ? html`<pre class="whitespace-pre-wrap mt-2 text-2xs text-[var(--color-fg-muted)] leading-relaxed">${post.meta.state_block}</pre>`
                      : null}
                  </div>
                </details>
              `
            : null}

          <!-- Vote buttons -->
          <div class="flex gap-2">
            <${ActionButton}
              variant="ghost"
              size="sm"
              class="vote-btn upvote text-xs hover:text-[var(--warn-bright)] hover:border-[var(--warn-30)] hover:bg-[var(--warn-10)]"
              onClick=${() => handleVote('up')}
            >▲ 추천<//>
            <${ActionButton}
              variant="ghost"
              size="sm"
              class="vote-btn downvote text-xs hover:text-[var(--color-accent-fg)] hover:border-[var(--accent-30)] hover:bg-[var(--accent-10)]"
              onClick=${() => handleVote('down')}
            >▼ 비추천<//>
          </div>
        </div>
      <//>

      <div class="mt-4">
        <${Card} title="댓글">
          ${detailLoading.value
            ? html`<${LoadingState}>댓글 불러오는 중...<//>`
            : html`<${CommentThread} comments=${detailComments.value} postId=${post.id} />`}
          <${CommentForm} postId=${post.id} />
        <//>
      </div>
    </div>
  `
}

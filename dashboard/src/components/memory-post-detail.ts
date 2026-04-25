import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { RichComposer } from './common/rich-composer'
import { RichContent } from './common/rich-content'
import { stripStateBlocks } from '../keeper-message'
import { navigate } from '../router'
import { navigateToAuthor } from '../lib/board-utils'
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
  refreshBoard,
} from './memory-state'
import type { BoardComment, BoardPost } from './memory-state'

// ── Expiry chip (returns html, kept in UI layer) ───────────────────
function expiryChip(post: BoardPost) {
  if (!post.expires_at) return null
  const expiresAtMs = Date.parse(post.expires_at)
  if (!Number.isFinite(expiresAtMs)) return null
  if (expiresAtMs <= Date.now()) return html`<span class="inline-flex items-center px-2 py-0.5 rounded-sm text-3xs tracking-wide uppercase bg-[var(--bad-15)] text-[var(--bad-light)] border border-[var(--bad-30)]">만료됨</span>`
  return html`<span class="inline-flex items-center px-2 py-0.5 rounded-sm text-3xs tracking-wide uppercase bg-[var(--warn-15)] text-[var(--warn)] border border-[var(--warn-30)]">만료까지 <${TimeAgo} timestamp=${post.expires_at} /></span>`
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
}: {
  comment: BoardComment
  postId: string
  depth?: number
  childrenMap: ReadonlyMap<string, readonly BoardComment[]>
}) {
  const contentChars = Array.from(comment.content ?? '')
  const needsTruncation = contentChars.length > 300
  const [expanded, setExpanded] = useState(false)
  const displayText = needsTruncation && !expanded
    ? `${contentChars.slice(0, 297).join('')}...`
    : comment.content
  const isReplying = replyingTo.value === comment.id
  const indent = depth > 0 ? `ml-${Math.min(depth * 4, 12)}` : ''
  const replies = childrenMap.get(comment.id) ?? []

  return html`
    <div class="${indent}">
      <div class="board-comment rounded p-3 bg-[var(--white-3)] border border-[var(--border-slate-12)] ${depth > 0 ? 'border-l-2 border-l-[var(--accent-20)]' : ''}">
        <div class="flex items-center gap-2 mb-1.5">
          <span class="text-xs">${authorAvatar(comment.author)}</span>
          <button type="button" class="text-xs font-medium text-[var(--text-body)] hover:text-[var(--accent)] transition-colors cursor-pointer bg-transparent border-none p-0" onClick=${() => navigateToAuthor(comment.author)}>${comment.author}</button>
          <span class="text-2xs text-[var(--text-muted)] opacity-60"><${TimeAgo} timestamp=${comment.created_at} /></span>
          <button type="button"
            class="text-2xs text-[var(--text-muted)] hover:text-[var(--accent)] cursor-pointer bg-transparent border-0 ml-auto"
            onClick=${() => { replyingTo.value = isReplying ? null : comment.id; commentText.value = '' }}
          >${isReplying ? '취소' : '답글'}</button>
        </div>
        <div class="text-sm text-[var(--text-body)] leading-paragraph"><${RichContent} text=${displayText} previewLimit=${1} /></div>
        ${needsTruncation ? html`
          <button type="button"
            class="mt-1 text-2xs text-[var(--accent)] hover:underline cursor-pointer bg-transparent border-0"
            onClick=${() => setExpanded(!expanded)}
            aria-expanded=${expanded}
          >${expanded ? '접기' : '더 보기...'}</button>
        ` : null}
        ${isReplying ? html`
          <div class="mt-2">
            <${RichComposer}
              value=${commentText.value}
              ariaLabel="답글 작성"
              placeholder="답글 작성..."
              rows=${4}
              disabled=${commentSubmitting.value}
              onValueChange=${(next: string) => { commentText.value = next }}
              helpText="Markdown과 코드 스니펫을 그대로 붙일 수 있습니다."
              previewLimit=${1}
            />
            <div class="mt-2 flex justify-end">
              <button type="button"
                class="py-1.5 px-3 rounded text-xs font-medium font-[inherit] cursor-pointer transition-all duration-150 border
                  ${commentSubmitting.value || commentText.value.trim() === ''
                    ? 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-12)] opacity-50 cursor-not-allowed'
                    : 'bg-[var(--ok-soft)] text-[var(--ok)] border-[var(--ok-30)] hover:bg-[var(--ok-22)]'
                  }"
                onClick=${() => submitComment(postId, comment.id)}
                disabled=${commentSubmitting.value || commentText.value.trim() === ''}
              >
                ${commentSubmitting.value ? '...' : '등록'}
              </button>
            </div>
          </div>
        ` : null}
      </div>
      ${replies.length > 0 ? html`
        <div class="flex flex-col gap-1.5 mt-1.5">
          ${replies.map(reply => html`<${CommentItem} key=${reply.id} comment=${reply} postId=${postId} depth=${depth + 1} childrenMap=${childrenMap} />`)}
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
        <div class="text-2xs text-[var(--text-muted)]" aria-live="polite">댓글 ${comments.length}개${isFiltering ? ` · 일치 ${filteredRoots.length}` : ''}</div>
        <input
          type="search"
          value=${query.value}
          placeholder="댓글 내용 검색"
          aria-label="댓글 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="ml-auto min-w-35 max-w-55 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
        />
      </div>
      ${isFiltering && filteredRoots.length === 0 ? html`
        <${EmptyState} message=${`"${query.value.trim()}" 일치하는 댓글 없음`} compact />
      ` : null}
      ${!expanded && hiddenCount > 0 ? html`
        <button type="button"
          class="text-xs text-[var(--accent)] hover:underline cursor-pointer bg-transparent border-0 text-left py-1"
          onClick=${() => setExpanded(true)}
        >이전 댓글 ${hiddenCount}개 더 보기</button>
      ` : null}
      ${visible.map(comment => html`<${CommentItem} key=${comment.id} comment=${comment} postId=${postId} depth=${0} childrenMap=${filteredChildrenMap} />`)}
      ${expanded && hiddenCount > 0 ? html`
        <button type="button"
          class="text-xs text-[var(--text-muted)] hover:text-[var(--accent)] cursor-pointer bg-transparent border-0 text-left py-1"
          onClick=${() => setExpanded(false)}
        >접기</button>
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
        ariaLabel="댓글 추가"
        placeholder="댓글 추가..."
        rows=${5}
        disabled=${commentSubmitting.value}
        onValueChange=${(next: string) => { commentText.value = next }}
        helpText="Markdown, 코드 스니펫, URL 링크 카드를 지원합니다."
        previewLimit=${1}
      />
      <div class="mt-2 flex justify-end">
        <button type="button"
          class="py-2 px-4 rounded text-sm font-medium font-[inherit] cursor-pointer transition-all duration-150 border
            ${commentSubmitting.value || commentText.value.trim() === ''
              ? 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-12)] opacity-50 cursor-not-allowed'
              : 'bg-[var(--ok-soft)] text-[var(--ok)] border-[var(--ok-30)] hover:bg-[var(--ok-22)]'
            }"
          onClick=${() => submitComment(postId)}
          disabled=${commentSubmitting.value || commentText.value.trim() === ''}
        >
          ${commentSubmitting.value ? '...' : '등록'}
        </button>
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

  return html`
    <div role="region" aria-label="게시글 상세">
      <button type="button"
        class="mb-4 px-3 py-1.5 rounded text-xs font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
        onClick=${() => navigate('workspace', { section: 'board' })}
        aria-label="게시판으로 돌아가기"
      >← 게시판으로 돌아가기</button>

      <${Card}>
        <div class="flex flex-col gap-4">
          <div>
            <h2 class="m-0 text-2xl font-semibold leading-tight text-[var(--text-strong)]">${post.title}</h2>
          </div>

          <div class="text-sm text-[var(--text-body)] leading-loose">
            <${RichContent} text=${stripStateBlocks(post.body)} previewLimit=${4} />
          </div>

          <!-- Author and meta -->
          <div class="flex gap-2.5 items-center flex-wrap pt-3 border-t border-[var(--border-slate-12)]">
            <span class="text-sm">${authorAvatar(post.author)}</span>
            <button type="button" class="text-xs text-[var(--text-body)] hover:text-[var(--accent)] transition-colors cursor-pointer bg-transparent border-none p-0" onClick=${() => navigateToAuthor(post.author)}>${post.author}</button>
            <span class="text-2xs text-[var(--text-muted)]"><${TimeAgo} timestamp=${post.created_at} /></span>
            <span class="text-2xs text-[var(--text-muted)]">${post.votes ?? 0} votes</span>
          </div>

          <!-- Badges -->
          ${(post.hearth || post.visibility || post.expires_at || post.classification_reason)
            ? html`
                <div class="flex flex-col gap-2">
                  <div class="flex gap-1.5 flex-wrap">
                    ${post.hearth ? html`<span class="inline-flex items-center px-2 py-0.5 rounded text-3xs font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${post.hearth}</span>` : null}
                    ${post.visibility && visibilityLabel(post.visibility) ? html`<span class="inline-flex items-center px-2 py-0.5 rounded text-3xs font-medium border ${visibilityBadgeColor(post.visibility)}">${visibilityLabel(post.visibility)}</span>` : null}
                    <span class="inline-flex items-center px-2 py-0.5 rounded text-3xs font-medium border ${kindBadgeColor(boardPostKind(post))}">${kindLabel(boardPostKind(post))}</span>
                    ${expiryChip(post)}
                  </div>
                  ${post.classification_reason
                    ? html`<div class="text-2xs text-[var(--text-muted)]">분류 근거: ${post.classification_reason}</div>`
                    : null}
                </div>
              `
            : null}

          <!-- Meta details -->
          ${post.meta
            ? html`
                <details class="mt-1">
                  <summary class="cursor-pointer text-xs text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">운영 메타</summary>
                  <div class="mt-2 p-3 rounded bg-[var(--white-3)] border border-[var(--border-slate-12)]">
                    ${post.meta.source ? html`<div class="text-xs text-[var(--text-body)]"><span class="text-[var(--text-muted)]">출처:</span> ${post.meta.source}</div>` : null}
                    ${post.meta.state_block
                      ? html`<pre class="whitespace-pre-wrap mt-2 text-2xs text-[var(--text-muted)] leading-relaxed max-h-40 overflow-y-auto custom-scrollbar">${post.meta.state_block}</pre>`
                      : null}
                  </div>
                </details>
              `
            : null}

          <!-- Vote buttons -->
          <div class="flex gap-2">
            <button type="button"
              class="vote-btn upvote px-3 py-1.5 rounded text-xs font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[var(--warn-bright)] hover:border-[var(--warn-30)] hover:bg-[var(--warn-10)] transition-all cursor-pointer"
              onClick=${() => handleVote('up')}
            ><span aria-hidden="true">▲</span> 추천</button>
            <button type="button"
              class="vote-btn downvote px-3 py-1.5 rounded text-xs font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[var(--accent)] hover:border-[var(--accent-30)] hover:bg-[var(--accent-10)] transition-all cursor-pointer"
              onClick=${() => handleVote('down')}
            ><span aria-hidden="true">▼</span> 비추천</button>
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

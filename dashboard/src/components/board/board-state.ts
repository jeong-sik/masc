import { signal } from '@preact/signals'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import {
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardExcludeAutomation,
  boardHiddenCategories,
  boardAuthorFilter,
  boardLoading,
  boardLoadingMore,
  boardHasMore,
  boardOffset,
  boardTotal,
  boardHearthFilter,
  lastBoardRefreshAt,
  refreshBoard,
  loadMoreBoardPosts,
} from '../../store'
import {
  fetchBoardHearths,
  fetchBoardFlairs,
  fetchSubBoards,
  fetchBoardPost,
  commentPost,
  createPost,
  type BoardHearth,
  type BoardFlair,
} from '../../api'
import { deleteBoardPost } from '../../api/actions'
import type { BoardComment, BoardPost, BoardSortMode } from '../../types'

// ── Re-exports (used by sibling UI files) ──────────────────────────
export {
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardExcludeAutomation,
  boardHiddenCategories,
  boardAuthorFilter,
  boardLoading,
  boardLoadingMore,
  boardHasMore,
  boardOffset,
  boardTotal,
  boardHearthFilter,
  lastBoardRefreshAt,
  refreshBoard,
  loadMoreBoardPosts,
}
export type { BoardComment, BoardPost, BoardSortMode }

// ── Sort modes ─────────────────────────────────────────────────────
export const SORT_MODES: { id: BoardSortMode; label: string }[] = [
  { id: 'recent', label: '최신순' },
  { id: 'hot', label: '인기순' },
  { id: 'best', label: '베스트' },
  { id: 'updated', label: '최근 갱신' },
  { id: 'discussed', label: '댓글 많은 순' },
]

// ── Signals: detail view ───────────────────────────────────────────
export const detailPost = signal<BoardPost | null>(null)
export const detailComments = signal<BoardComment[]>([])
export const detailLoading = signal(false)
export const detailPostId = signal<string | null>(null)

// ── Signals: hearth filters ───────────────────────────────────────
export const boardHearths = signal<BoardHearth[]>([])
export const boardHearthsLoading = signal(false)
export const boardHearthsError = signal(false)
export const boardFlairs = signal<BoardFlair[]>([])
export const boardFlairsLoading = signal(false)
export const boardFlairsError = signal(false)

// SubBoard options for post creation dropdown
export const subBoardOptions = signal<Array<{ slug: string; name: string }>>([])
export const subBoardOptionsLoading = signal(false)
export const subBoardOptionsError = signal(false)
let boardHearthsRequestId = 0

// ── Signals: comments ──────────────────────────────────────────────
export const commentText = signal('')
export const commentSubmitting = signal(false)
export const replyingTo = signal<string | null>(null)

// ── Signals: new post form ─────────────────────────────────────────
export const showNewPostForm = signal(false)
export const newPostTitle = signal('')
export const newPostContent = signal('')
export const newPostHearth = signal('')
export const newPostFlair = signal('')
export const newPostSubmitting = signal(false)

// ── Signals: v2 board surface chrome ───────────────────────────────
export const selectedBoardPostId = signal<string | null>(null)
export const boardFilterMode = signal<'all' | 'mod'>('all')
export const boardComposerMode = signal<'post' | 'mention'>('post')
export const boardComposerDraft = signal('')

// ── Pagination ─────────────────────────────────────────────────────
export const PAGE_SIZE = 20
export const visibleLimit = signal(PAGE_SIZE)
export const automationVisibleLimit = signal(PAGE_SIZE)
export const systemVisibleLimit = signal(PAGE_SIZE)
/** Per-category pagination limits */
export const categoryVisibleLimits = signal<Record<string, number>>({
  article: PAGE_SIZE,
  review: PAGE_SIZE,
  notice: PAGE_SIZE,
  system: PAGE_SIZE,
})

// ── Selection / bulk delete ────────────────────────────────────────
export const deletingPostId = signal<string | null>(null)
export const selectedPostIds = signal<Set<string>>(new Set())
export const bulkDeleting = signal(false)

export async function loadSubBoardOptionsForPost(): Promise<void> {
  subBoardOptionsLoading.value = true
  subBoardOptionsError.value = false
  try {
    const boards = await fetchSubBoards()
    subBoardOptions.value = boards.map(b => ({ slug: b.slug, name: b.name || b.slug }))
  } catch (err) {
    console.warn('[Board] failed to load sub-board options:', err)
    subBoardOptionsError.value = true
  } finally {
    subBoardOptionsLoading.value = false
  }
}

export async function refreshBoardHearths(): Promise<void> {
  const requestId = ++boardHearthsRequestId
  boardHearthsLoading.value = true
  try {
    const hearths = await fetchBoardHearths()
    if (requestId !== boardHearthsRequestId) return
    boardHearths.value = hearths
    boardHearthsError.value = false
  } catch (err) {
    if (requestId !== boardHearthsRequestId) return
    console.warn('[Board] failed to load hearth filters:', err)
    boardHearthsError.value = true
    showToast('Hearth 목록을 불러오지 못했습니다', 'error')
  } finally {
    if (requestId === boardHearthsRequestId) {
      boardHearthsLoading.value = false
    }
  }
}

export async function refreshBoardFlairs(): Promise<void> {
  boardFlairsLoading.value = true
  try {
    boardFlairs.value = await fetchBoardFlairs()
    boardFlairsError.value = false
  } catch (err) {
    console.warn('[Board] failed to load flair options:', err)
    boardFlairsError.value = true
    showToast('Flair 목록을 불러오지 못했습니다', 'error')
  } finally {
    boardFlairsLoading.value = false
  }
}

// ── Helper: default comment author ─────────────────────────────────
function defaultCommentAuthor(): string {
  const params = new URLSearchParams(window.location.search)
  return params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || 'dashboard-user'
}

const commentAuthor = signal(defaultCommentAuthor())

// ── Utility functions ──────────────────────────────────────────────
export function isUpdated(post: BoardPost): boolean {
  return post.updated_at !== post.created_at
}

export function boardPostKind(post: BoardPost): 'direct' | 'automation' | 'system' {
  return post.post_kind ?? 'direct'
}

// ── Content-based category (replaces post_kind for filtering) ─────
export type ContentCategory = 'article' | 'review' | 'notice' | 'system'

function contentCategoryFromValue(value: unknown): ContentCategory | null {
  const normalized = typeof value === 'string' ? value.trim().toLowerCase() : ''
  switch (normalized) {
    case 'article':
      return 'article'
    case 'review':
      return 'review'
    case 'notice':
      return 'notice'
    case 'system':
      return 'system'
    default:
      return null
  }
}

export function contentCategory(post: BoardPost): ContentCategory {
  if (boardPostKind(post) === 'system') return 'system'

  const metaCategory = contentCategoryFromValue(post.meta?.content_category)
    ?? contentCategoryFromValue(post.meta?.category)
    ?? contentCategoryFromValue(post.meta?.board_category)
  if (metaCategory) return metaCategory

  return boardPostKind(post) === 'automation' ? 'notice' : 'article'
}

export const CONTENT_CATEGORIES: { id: ContentCategory; label: string; icon: string }[] = [
  { id: 'article', label: '글/분석', icon: '📝' },
  { id: 'review', label: '리뷰/판정', icon: '⚖️' },
  { id: 'notice', label: '알림/상태', icon: '📢' },
  { id: 'system', label: '시스템', icon: '⚙️' },
]

export function categoryLabel(cat: ContentCategory): string {
  return CONTENT_CATEGORIES.find(c => c.id === cat)?.label ?? cat
}

export function categoryBadgeColor(cat: ContentCategory): string {
  switch (cat) {
    case 'article': return 'bg-[var(--ok-soft)] text-[var(--color-status-ok)] border-[var(--ok-30)]'
    case 'review': return 'bg-[var(--purple-10)] text-[var(--purple)] border-[var(--purple-20)]'
    case 'notice': return 'bg-[var(--warn-10)] text-[var(--warn-bright)] border-[var(--warn-20)]'
    case 'system': return 'bg-[var(--color-bg-panel-alt)] text-[var(--color-fg-muted)] border-[var(--color-border-default)]'
    default: return 'bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)] border-[var(--color-border-default)]'
  }
}

// ── Grouped posts by content category ─────────────────────────────
type CategoryGroup = { category: ContentCategory; posts: BoardPost[]; total: number; hidden: number }

export type VisibleBoardGroups = {
  groups: CategoryGroup[]
  // Legacy compat fields
  direct: BoardPost[]
  automation: BoardPost[]
  system: BoardPost[]
  totalDirect: number
  totalAutomation: number
  totalSystem: number
  hiddenAutomation: number
  hiddenSystem: number
}

export function splitVisiblePosts(posts: readonly BoardPost[]): VisibleBoardGroups {
  const hidden = boardHiddenCategories.value
  const buckets: Record<ContentCategory, { posts: BoardPost[]; total: number; hidden: number }> = {
    article: { posts: [], total: 0, hidden: 0 },
    review: { posts: [], total: 0, hidden: 0 },
    notice: { posts: [], total: 0, hidden: 0 },
    system: { posts: [], total: 0, hidden: 0 },
  }

  // Legacy counters
  let totalDirect = 0, totalAutomation = 0, totalSystem = 0
  let hiddenAutomation = 0, hiddenSystem = 0

  posts.forEach(post => {
    const cat = contentCategory(post)
    const bucket = buckets[cat]
    bucket.total += 1
    if (hidden.has(cat)) {
      bucket.hidden += 1
    } else {
      bucket.posts.push(post)
    }

    // Legacy compat
    const kind = boardPostKind(post)
    if (kind === 'system') { totalSystem += 1; if (hidden.has('system')) hiddenSystem += 1 }
    else if (kind === 'automation') { totalAutomation += 1; if (boardExcludeAutomation.value) hiddenAutomation += 1 }
    else { totalDirect += 1 }
  })

  // Operator-pinned posts float to the top of their category. Array.sort is
  // stable, so the existing order within the pinned / unpinned subsets is kept.
  const pinnedFirst = (a: BoardPost, b: BoardPost): number =>
    Number(b.pinned ?? false) - Number(a.pinned ?? false)
  buckets.article.posts.sort(pinnedFirst)
  buckets.review.posts.sort(pinnedFirst)
  buckets.notice.posts.sort(pinnedFirst)
  buckets.system.posts.sort(pinnedFirst)

  const groups = (Object.entries(buckets) as [ContentCategory, typeof buckets.article][])
    .map(([category, b]) => ({ category, posts: b.posts, total: b.total, hidden: b.hidden }))
    .filter(g => g.total > 0)

  return {
    groups,
    direct: buckets.article.posts,
    automation: buckets.review.posts,
    system: buckets.system.posts,
    totalDirect, totalAutomation, totalSystem,
    hiddenAutomation, hiddenSystem,
  }
}

export function filterHint(grouped: VisibleBoardGroups): string | null {
  const totalHidden = grouped.groups.reduce((sum, g) => sum + g.hidden, 0)
  if (totalHidden > 0) {
    const names = grouped.groups
      .filter(g => g.hidden > 0)
      .map(g => `${categoryLabel(g.category)} ${g.hidden}건`)
      .join(', ')
    return `${names} 숨겨져 있습니다.`
  }
  return null
}

export function authorAvatar(name: string): string {
  const avatars = ['🤖', '🧑‍💻', '🦊', '🐙', '🔮', '🧪', '⚡', '🎯', '🛸', '🧠', '🦉', '🐺', '🎲', '🌊', '🔥']
  let hash = 0
  for (let i = 0; i < name.length; i++) {
    hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0
  }
  return avatars[Math.abs(hash) % avatars.length] ?? '🤖'
}

export function kindLabel(kind: string): string {
  switch (kind) {
    case 'direct': return '직접'
    case 'automation': return '자동화'
    case 'system': return '시스템'
    default: return kind
  }
}

export function kindBadgeColor(kind: string): string {
  switch (kind) {
    case 'direct': return 'bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] border-[var(--color-border-divider)]'
    case 'automation': return 'bg-[var(--cyan-16)] text-[var(--color-accent-fg)] border-[var(--cyan-16)]'
    case 'system': return 'bg-[var(--color-bg-panel-alt)] text-[var(--color-fg-muted)] border-[var(--color-border-default)]'
    default: return 'bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)] border-[var(--color-border-default)]'
  }
}

export function visibilityLabel(vis: string): string | null {
  switch (vis) {
    case 'internal': return '내부'
    case 'unlisted': return '비공개'
    case 'direct': return 'DM'
    case 'public': return null
    default: return vis
  }
}

function visibilityAuditLabel(vis: string | null | undefined): string {
  if (!vis || vis === 'public') return '공개'
  return visibilityLabel(vis) ?? vis
}

export function postVisibilityAuditDetails(post: BoardPost): string {
  const scoreLabel = post.vote_blind ? '점수 투표 후 공개' : `점수 ${post.votes ?? 0}`
  const updatedLabel = isUpdated(post) ? '최근 갱신됨' : '원본 작성 시각 기준'
  return [
    visibilityAuditLabel(post.visibility),
    `댓글 ${post.comment_count ?? 0}개`,
    scoreLabel,
    updatedLabel,
  ].join(' · ')
}

export function postVisibilityAuditLabel(post: BoardPost): string {
  return `표시 중 · ${postVisibilityAuditDetails(post)}`
}

export function visibilityBadgeColor(vis: string): string {
  if (vis === 'internal') return 'bg-[var(--color-bg-hover)] text-[var(--purple)] border-[var(--color-border-strong)]'
  return 'bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] border-[var(--color-border-default)]'
}

// ── Data operations ────────────────────────────────────────────────
export async function loadPostDetail(postId: string) {
  detailPostId.value = postId
  detailPost.value = null
  detailComments.value = []
  detailLoading.value = true
  try {
    const data = await fetchBoardPost(postId)
    if (detailPostId.value !== postId) return
    detailPost.value = {
      id: data.id,
      author: data.author,
      author_identity: data.author_identity,
      title: data.title,
      body: data.body,
      content: data.content,
      meta: data.meta,
      tags: data.tags,
      votes: data.votes,
      vote_balance: data.vote_balance,
      comment_count: data.comment_count,
      created_at: data.created_at,
      updated_at: data.updated_at,
      post_kind: data.post_kind,
      pinned: data.pinned,
      classification_reason: data.classification_reason,
      flair: data.flair,
      hearth: data.hearth,
      visibility: data.visibility,
      expires_at: data.expires_at,
      hearth_count: data.hearth_count,
    }
    detailComments.value = data.comments ?? []
  } catch (err) {
    console.warn('[Board] failed to load post detail:', postId, err)
    if (detailPostId.value === postId) {
      detailPost.value = null
      detailComments.value = []
      showToast('글을 불러오는 데 실패했습니다', 'error')
    }
  } finally {
    if (detailPostId.value === postId) {
      detailLoading.value = false
    }
  }
}

export async function submitComment(postId: string, parentId?: string) {
  const text = commentText.value.trim()
  if (!text) return
  commentSubmitting.value = true
  try {
    await commentPost(postId, commentAuthor.value, text, parentId)
    commentText.value = ''
    replyingTo.value = null
    showToast('댓글을 등록했습니다', 'success')
    await loadPostDetail(postId)
    refreshBoard()
  } catch (err) {
    console.warn('[board] comment submit failed', err instanceof Error ? err.message : err)
    showToast('댓글 등록에 실패했습니다', 'error')
  } finally {
    commentSubmitting.value = false
  }
}

export async function submitNewPost() {
  const title = newPostTitle.value.trim()
  const content = newPostContent.value.trim()
  const hearth = newPostHearth.value.trim()
  const flair = newPostFlair.value.trim()
  if (!title || !content) return
  newPostSubmitting.value = true
  try {
    const contentWithFlair = flair
      ? `[flair:${flair}]\n${content.replace(/^\[flair:[a-z]+\]\s*/i, '')}`
      : content
    await createPost(title, contentWithFlair, commentAuthor.value, { hearth: hearth || undefined })
    newPostTitle.value = ''
    newPostContent.value = ''
    newPostHearth.value = ''
    newPostFlair.value = ''
    showNewPostForm.value = false
    showToast('글을 등록했습니다', 'success')
    refreshBoard()
    void refreshBoardHearths()
  } catch (err) {
    console.warn('[board] post submit failed', err instanceof Error ? err.message : err)
    showToast('글 등록에 실패했습니다', 'error')
  } finally {
    newPostSubmitting.value = false
  }
}

export function togglePostSelection(postId: string, event: Event) {
  event.stopPropagation()
  const next = new Set(selectedPostIds.value)
  if (next.has(postId)) next.delete(postId)
  else next.add(postId)
  selectedPostIds.value = next
}

export async function bulkDeleteSelected() {
  const ids = Array.from(selectedPostIds.value)
  if (ids.length === 0) return
  const confirmed = await requestConfirm({
    title: '선택 삭제',
    message: `${ids.length}개의 글을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.`,
    tone: 'danger'
  })
  if (!confirmed) return
  bulkDeleting.value = true
  const results = await Promise.allSettled(ids.map(id => deleteBoardPost(id)))
  const deleted = results.filter(r => r.status === 'fulfilled').length
  results.forEach((r, i) => {
    if (r.status === 'rejected') console.warn('[board] bulk delete failed for', ids[i], r.reason)
  })
  bulkDeleting.value = false
  selectedPostIds.value = new Set()
  showToast(`${deleted}/${ids.length}개 게시글을 삭제했습니다`, deleted === ids.length ? 'success' : 'error')
  refreshBoard()
}

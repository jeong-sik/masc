import { signal } from '@preact/signals'
import { showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'
import {
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardExcludeAutomation,
  boardAuthorFilter,
  boardLoading,
  lastBoardRefreshAt,
  refreshBoard,
} from '../store'
import {
  votePost,
  fetchBoardPost,
  commentPost,
  createPost,
} from '../api'
import { deleteBoardPost } from '../api/actions'
import type { BoardComment, BoardPost, BoardSortMode } from '../types'

// ── Re-exports (used by sibling UI files) ──────────────────────────
export {
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardExcludeAutomation,
  boardAuthorFilter,
  boardLoading,
  lastBoardRefreshAt,
  refreshBoard,
}
export { votePost }
export { deleteBoardPost }
export type { BoardComment, BoardPost, BoardSortMode }

// ── Sort modes ─────────────────────────────────────────────────────
export const SORT_MODES: { id: BoardSortMode; label: string }[] = [
  { id: 'recent', label: '최신순' },
  { id: 'hot', label: '인기순' },
  { id: 'trending', label: '급상승' },
  { id: 'updated', label: '최근 갱신' },
  { id: 'discussed', label: '토론 많은 순' },
]

// ── Signals: detail view ───────────────────────────────────────────
export const detailPost = signal<BoardPost | null>(null)
export const detailComments = signal<BoardComment[]>([])
export const detailLoading = signal(false)
export const detailPostId = signal<string | null>(null)

// ── Signals: comments ──────────────────────────────────────────────
export const commentText = signal('')
export const commentSubmitting = signal(false)
export const replyingTo = signal<string | null>(null)

// ── Signals: new post form ─────────────────────────────────────────
export const showNewPostForm = signal(false)
export const newPostTitle = signal('')
export const newPostContent = signal('')
export const newPostSubmitting = signal(false)

// ── Pagination ─────────────────────────────────────────────────────
export const PAGE_SIZE = 20
export const visibleLimit = signal(PAGE_SIZE)
export const automationVisibleLimit = signal(PAGE_SIZE)
export const systemVisibleLimit = signal(PAGE_SIZE)

// ── Selection / bulk delete ────────────────────────────────────────
export const deletingPostId = signal<string | null>(null)
export const selectedPostIds = signal<Set<string>>(new Set())
export const bulkDeleting = signal(false)

// ── Helper: default comment author ─────────────────────────────────
export function defaultCommentAuthor(): string {
  const params = new URLSearchParams(window.location.search)
  return params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || 'dashboard-user'
}

export const commentAuthor = signal(defaultCommentAuthor())

// ── Utility functions ──────────────────────────────────────────────
export function isUpdated(post: BoardPost): boolean {
  return post.updated_at !== post.created_at
}

export function boardPostKind(post: BoardPost): 'direct' | 'automation' | 'system' {
  return post.post_kind ?? 'direct'
}

export type VisibleBoardGroups = {
  direct: BoardPost[]
  automation: BoardPost[]
  system: BoardPost[]
  totalDirect: number
  totalAutomation: number
  totalSystem: number
  hiddenAutomation: number
  hiddenSystem: number
}

export function splitVisiblePosts(posts: BoardPost[]): VisibleBoardGroups {
  const direct: BoardPost[] = []
  const automation: BoardPost[] = []
  const system: BoardPost[] = []
  let totalDirect = 0
  let totalAutomation = 0
  let totalSystem = 0
  let hiddenAutomation = 0
  let hiddenSystem = 0
  posts.forEach(post => {
    const kind = boardPostKind(post)
    if (kind === 'direct') {
      totalDirect += 1
      direct.push(post)
      return
    }
    if (kind === 'automation') {
      totalAutomation += 1
      if (boardExcludeAutomation.value) {
        hiddenAutomation += 1
        return
      }
      automation.push(post)
      return
    }
    totalSystem += 1
    if (boardExcludeSystem.value) {
      hiddenSystem += 1
      return
    }
    system.push(post)
  })
  return {
    direct,
    automation,
    system,
    totalDirect,
    totalAutomation,
    totalSystem,
    hiddenAutomation,
    hiddenSystem,
  }
}

export function filterHint(grouped: VisibleBoardGroups): string | null {
  if (grouped.totalAutomation === 0 && grouped.totalSystem === 0 && grouped.totalDirect > 0) {
    return '현재 목록은 직접 작성 글만 있어서 자동화·시스템 필터를 눌러도 보이는 글 수가 그대로일 수 있습니다.'
  }
  if (boardExcludeAutomation.value && grouped.hiddenAutomation > 0) {
    return `자동화 글 ${grouped.hiddenAutomation}건이 숨겨져 있습니다.`
  }
  if (boardExcludeSystem.value && grouped.hiddenSystem > 0) {
    return `시스템 글 ${grouped.hiddenSystem}건이 숨겨져 있습니다.`
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
    case 'direct': return 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-12)]'
    case 'automation': return 'bg-[var(--cyan-16)] text-[var(--accent)] border-[var(--cyan-16)]'
    case 'system': return 'bg-[var(--slate-gray-15)] text-[var(--text-slate)] border-[var(--border-slate-22)]'
    default: return 'bg-[var(--white-8)] text-[var(--text-muted)] border-[var(--border-slate-16)]'
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

export function visibilityBadgeColor(vis: string): string {
  if (vis === 'internal') return 'bg-[var(--white-10)] text-[var(--purple)] border-[var(--white-20)]'
  return 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-16)]'
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
  if (!title || !content) return
  newPostSubmitting.value = true
  try {
    await createPost(title, content, commentAuthor.value)
    newPostTitle.value = ''
    newPostContent.value = ''
    showNewPostForm.value = false
    showToast('글을 등록했습니다', 'success')
    refreshBoard()
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

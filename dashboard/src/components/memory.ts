import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { TimeAgo } from './common/time-ago'
import { Markdown } from './common/markdown'
import { showToast } from './common/toast'
import {
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardLoading,
  lastBoardRefreshAt,
  refreshBoard,
} from '../store'
import {
  votePost,
  fetchBoardPost,
  commentPost,
} from '../api'
import { navigate, navigateToPost, route } from '../router'
import type { BoardComment, BoardPost, BoardSortMode } from '../types'

const SORT_MODES: { id: BoardSortMode; label: string }[] = [
  { id: 'recent', label: 'Latest' },
  { id: 'hot', label: 'Hot' },
  { id: 'trending', label: 'Trending' },
  { id: 'updated', label: 'Updated' },
  { id: 'discussed', label: 'Discussed' },
]

const detailPost = signal<BoardPost | null>(null)
const detailComments = signal<BoardComment[]>([])
const detailLoading = signal(false)
const detailPostId = signal<string | null>(null)
const commentText = signal('')
const commentSubmitting = signal(false)
const hideAutomationPosts = signal(true)
const PAGE_SIZE = 20
const visibleLimit = signal(PAGE_SIZE)

function defaultCommentAuthor(): string {
  const params = new URLSearchParams(window.location.search)
  return params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || 'dashboard-user'
}

const commentAuthor = signal(defaultCommentAuthor())

function previewText(content: string): string {
  const flattened = content
    .replace(/!\[[^\]]*\]\([^)]+\)/g, ' ')
    .replace(/\[[^\]]+\]\([^)]+\)/g, '$1')
    .replace(/[`#>*_~-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (!flattened) return 'No preview available'
  return flattened.length > 180 ? `${flattened.slice(0, 177)}...` : flattened
}

function isUpdated(post: BoardPost): boolean {
  return post.updated_at !== post.created_at
}

function isLikelyTestPost(post: BoardPost): boolean {
  const haystack = `${post.title} ${post.author} ${post.tags.join(' ')} ${post.flair ?? ''}`.toLowerCase()
  return /\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(haystack)
    || haystack.includes('테스트')
    || haystack.includes('실험')
}

function isAutomationBoardPost(post: BoardPost): boolean {
  if (post.post_kind) return post.post_kind === 'automation'
  const hearth = (post.hearth ?? '').toLowerCase()
  if (post.visibility !== 'internal' || !post.expires_at || !hearth) return false
  if (hearth.startsWith('mdal')) return true
  if (hearth.includes('harness')) return true
  return false
}

function visiblePosts(posts: BoardPost[]): BoardPost[] {
  if (!hideAutomationPosts.value) return posts
  return posts.filter(post => {
    if (isAutomationBoardPost(post)) return false
    if (post.post_kind) return true
    if (post.hearth || post.visibility || post.expires_at) return true
    return !isLikelyTestPost(post)
  })
}

async function loadPostDetail(postId: string) {
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
      content: data.content,
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
  } catch {
    if (detailPostId.value === postId) {
      detailPost.value = null
      detailComments.value = []
    }
  } finally {
    if (detailPostId.value === postId) {
      detailLoading.value = false
    }
  }
}

async function submitComment(postId: string) {
  const text = commentText.value.trim()
  if (!text) return
  commentSubmitting.value = true
  try {
    await commentPost(postId, commentAuthor.value, text)
    commentText.value = ''
    showToast('Comment posted', 'success')
    await loadPostDetail(postId)
    refreshBoard()
  } catch {
    showToast('Failed to post comment', 'error')
  } finally {
    commentSubmitting.value = false
  }
}

function SortBar() {
  const current = boardSortMode.value
  const hideLabel = hideAutomationPosts.value ? 'Hiding automation posts' : 'Show automation posts'
  return html`
    <div class="board-toolbar">
      <div class="board-controls">
        ${SORT_MODES.map(mode => html`
          <button
            class="board-sort-btn ${current === mode.id ? 'active' : ''}"
            onClick=${() => {
              boardSortMode.value = mode.id
              visibleLimit.value = PAGE_SIZE
              refreshBoard()
            }}
          >
            ${mode.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${hideAutomationPosts.value ? 'is-active' : ''}"
          onClick=${() => {
            hideAutomationPosts.value = !hideAutomationPosts.value
          }}
        >
          ${hideLabel}
        </button>
        <button
          class="control-btn ghost ${boardExcludeSystem.value ? 'is-active' : ''}"
          onClick=${() => {
            boardExcludeSystem.value = !boardExcludeSystem.value
            refreshBoard()
          }}
        >
          ${boardExcludeSystem.value ? 'Hiding auto reports' : 'Show auto reports'}
        </button>
        <button class="control-btn ghost" onClick=${refreshBoard} disabled=${boardLoading.value}>
          ${boardLoading.value ? 'Refreshing...' : 'Refresh'}
        </button>
      </div>
    </div>
  `
}

function MemorySummary() {
  const sortLabel = SORT_MODES.find(mode => mode.id === boardSortMode.value)?.label ?? boardSortMode.value
  const filtered = visiblePosts(boardPosts.value)
  const hiddenCount = boardPosts.value.length - filtered.length
  return html`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${filtered.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${sortLabel}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise filter</span>
        <strong>${hideAutomationPosts.value ? `automation ${hiddenCount} hidden` : 'full feed'}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${boardExcludeSystem.value ? 'Auto reports hidden' : 'Full memory feed'}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${lastBoardRefreshAt.value ? html`<${TimeAgo} timestamp=${lastBoardRefreshAt.value} />` : 'Not loaded'}</strong>
      </div>
    </div>
  `
}

function PostCard({ post }: { post: BoardPost }) {
  const handleVote = async (dir: 'up' | 'down', event: Event) => {
    event.stopPropagation()
    try {
      await votePost(post.id, dir)
      refreshBoard()
    } catch {
      showToast('Failed to vote', 'error')
    }
  }

  return html`
    <div class="board-post" onClick=${() => navigateToPost(post.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${(event: Event) => handleVote('up', event)}>▲</button>
        <span class="vote-count">${post.votes ?? 0}</span>
        <button class="vote-btn downvote" onClick=${(event: Event) => handleVote('down', event)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
            <div class="post-title-row">
              <div class="post-title">${post.title}</div>
              <div class="post-chip-row">
                ${isUpdated(post) ? html`<span class="board-meta-chip">Updated</span>` : null}
                ${post.hearth ? html`<span class="board-meta-chip">${post.hearth}</span>` : null}
                ${post.visibility ? html`<span class="board-meta-chip">${post.visibility}</span>` : null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${post.author}</span>
            <span><${TimeAgo} timestamp=${post.created_at} /></span>
            ${isUpdated(post) ? html`<span>Updated <${TimeAgo} timestamp=${post.updated_at} /></span>` : null}
            <span>${post.comment_count} comments</span>
            <span>${post.votes ?? 0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${previewText(post.content)}</div>
      </div>
    </div>
  `
}

function CommentThread({ comments }: { comments: BoardComment[] }) {
  if (comments.length === 0) return html`<div class="empty-state" style="font-size:13px">No comments yet</div>`

  return html`
    <div class="comment-thread">
      ${comments.map(comment => html`
        <div key=${comment.id} class="board-comment">
          <span class="comment-author">${comment.author}</span>
          <span class="comment-time"><${TimeAgo} timestamp=${comment.created_at} /></span>
          <div class="comment-text">${comment.content}</div>
        </div>
      `)}
    </div>
  `
}

function CommentForm({ postId }: { postId: string }) {
  return html`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${commentText.value}
        onInput=${(event: Event) => { commentText.value = (event.target as HTMLInputElement).value }}
        onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') submitComment(postId) }}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${commentSubmitting.value}
      />
      <button
        onClick=${() => submitComment(postId)}
        disabled=${commentSubmitting.value || commentText.value.trim() === ''}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${commentSubmitting.value ? '...' : 'Post'}
      </button>
    </div>
  `
}

function PostDetail({ post }: { post: BoardPost }) {
  if (detailPostId.value !== post.id && !detailLoading.value) {
    loadPostDetail(post.id)
  }

  const handleVote = async (dir: 'up' | 'down') => {
    try {
      await votePost(post.id, dir)
      refreshBoard()
    } catch {
      showToast('Failed to vote', 'error')
    }
  }

  return html`
    <div>
      <button class="back-btn" onClick=${() => navigate('memory')}>← Back to Memory</button>
      <${Card} title=${post.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Markdown} text=${post.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${post.author}</span>
            <${TimeAgo} timestamp=${post.created_at} />
            <span>${post.votes ?? 0} votes</span>
          </div>
          ${(post.hearth || post.visibility || post.expires_at)
            ? html`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${post.hearth ? html`<span class="board-meta-chip">${post.hearth}</span>` : null}
                  ${post.visibility ? html`<span class="board-meta-chip">${post.visibility}</span>` : null}
                  ${post.expires_at ? html`<span class="board-meta-chip">expires <${TimeAgo} timestamp=${post.expires_at} /></span>` : null}
                </div>
              `
            : null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${() => handleVote('up')}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${() => handleVote('down')}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${Card} title="Comments" semanticId="memory.feed">
        ${detailLoading.value
          ? html`<div class="loading-indicator">Loading comments...</div>`
          : html`<${CommentThread} comments=${detailComments.value} />`}
        <${CommentForm} postId=${post.id} />
      <//>
    </div>
  `
}

export function Memory() {
  const posts = visiblePosts(boardPosts.value)
  const postId = route.value.params.post ?? null
  const post = postId
    ? posts.find(row => row.id === postId) ?? (detailPostId.value === postId ? detailPost.value : null)
    : null

  if (postId && !post && detailPostId.value !== postId && !detailLoading.value) {
    void loadPostDetail(postId)
  }

  if (postId) {
    return post
      ? html`
          <${SurfaceSemanticIntro} surfaceId="memory" />
          <${MemorySummary} />
          <${PostDetail} post=${post} />
        `
      : html`
          <div>
            <${SurfaceSemanticIntro} surfaceId="memory" />
            <${MemorySummary} />
            <button class="back-btn" onClick=${() => navigate('memory')}>← Back to Memory</button>
            ${detailLoading.value
              ? html`<div class="loading-indicator">Loading post...</div>`
              : html`<div class="empty-state">Post not found</div>`}
          </div>
        `
  }

  return html`
    <div>
      <${SurfaceSemanticIntro} surfaceId="memory" />
      <${MemorySummary} />
      <${SortBar} />
      ${boardLoading.value
        ? html`<div class="loading-indicator">Loading memory feed...</div>`
        : posts.length === 0
          ? html`<div class="empty-state">No posts in durable memory right now</div>`
          : html`
              <${Card} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${posts.slice(0, visibleLimit.value).map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
                </div>
                ${posts.length > visibleLimit.value ? html`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${() => { visibleLimit.value = visibleLimit.value + PAGE_SIZE }}
                    >
                      Show more (${posts.length - visibleLimit.value} remaining)
                    </button>
                  </div>
                ` : null}
              <//>
            `}
    </div>
  `
}

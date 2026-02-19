// Board tab — Posts list with sort modes, vote, comment, flair badges, hearths
// Detail view: full post + comment thread + comment form

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { Markdown } from './common/markdown'
import { showToast } from './common/toast'
import { boardPosts, boardSortMode, boardLoading, refreshBoard } from '../store'
import { votePost, fetchBoardPost, commentPost } from '../api'
import { navigate, navigateToPost, route } from '../router'
import type { BoardPost, BoardComment, BoardSortMode } from '../types'

const SORT_MODES: { id: BoardSortMode; label: string }[] = [
  { id: 'hot', label: 'Hot' },
  { id: 'trending', label: 'Trending' },
  { id: 'recent', label: 'Recent' },
  { id: 'updated', label: 'Updated' },
  { id: 'discussed', label: 'Discussed' },
]

// ── Local state for detail view ────────────────────────────

const detailComments = signal<BoardComment[]>([])
const detailLoading = signal(false)
const commentText = signal('')
const commentAuthor = signal('dashboard-user')
const commentSubmitting = signal(false)

async function loadPostDetail(postId: string) {
  detailLoading.value = true
  detailComments.value = []
  try {
    const data = await fetchBoardPost(postId)
    detailComments.value = data.comments ?? []
  } catch {
    // Post detail may not be available; comments remain empty
  } finally {
    detailLoading.value = false
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

// ── Components ─────────────────────────────────────────────

function SortBar() {
  const current = boardSortMode.value
  return html`
    <div class="board-controls">
      ${SORT_MODES.map(m => html`
        <button
          class="board-sort-btn ${current === m.id ? 'active' : ''}"
          onClick=${() => {
            boardSortMode.value = m.id
            refreshBoard()
          }}
        >
          ${m.label}
        </button>
      `)}
    </div>
  `
}

function FlairBadge({ flair }: { flair?: string }) {
  if (!flair) return null
  return html`<span class="post-flair ${flair}">${flair}</span>`
}

function PostCard({ post }: { post: BoardPost }) {
  const handleVote = async (dir: 'up' | 'down', e: Event) => {
    e.stopPropagation()
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
        <button class="vote-btn upvote" onClick=${(e: Event) => handleVote('up', e)}>▲</button>
        <span class="vote-count">${post.votes ?? 0}</span>
        <button class="vote-btn downvote" onClick=${(e: Event) => handleVote('down', e)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${post.title}
          ${' '}
          <${FlairBadge} flair=${post.flair} />
        </div>
        <div class="post-meta">
          <span>${post.author}</span>
          <${TimeAgo} timestamp=${post.created_at} />
          ${post.comment_count > 0
            ? html`<span>${post.comment_count} comments</span>`
            : null}
          ${(post.hearth_count ?? 0) > 0
            ? html`<span>♥ ${post.hearth_count}</span>`
            : null}
        </div>
      </div>
    </div>
  `
}

function CommentThread({ comments }: { comments: BoardComment[] }) {
  if (comments.length === 0) return html`<div class="empty-state" style="font-size:13px">No comments yet</div>`

  return html`
    <div class="comment-thread">
      ${comments.map(c => html`
        <div key=${c.id} class="board-comment">
          <span class="comment-author">${c.author}</span>
          <span class="comment-time"><${TimeAgo} timestamp=${c.created_at} /></span>
          <div class="comment-text">${c.content}</div>
        </div>
      `)}
    </div>
  `
}

function CommentForm({ postId }: { postId: string }) {
  return html`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${commentText.value}
        onInput=${(e: Event) => { commentText.value = (e.target as HTMLInputElement).value }}
        onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') submitComment(postId) }}
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
  // Load comments on first render
  if (detailComments.value.length === 0 && !detailLoading.value) {
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
      <button class="back-btn" onClick=${() => navigate('board')}>← Back to Board</button>
      <${Card} title=${html`${post.title} <${FlairBadge} flair=${post.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Markdown} text=${post.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${post.author}</span>
            <${TimeAgo} timestamp=${post.created_at} />
            <span>${post.votes ?? 0} votes</span>
            ${(post.hearth_count ?? 0) > 0 ? html`<span>♥ ${post.hearth_count}</span>` : null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${() => handleVote('up')}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${() => handleVote('down')}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${Card} title="Comments (${detailLoading.value ? '...' : detailComments.value.length})">
        ${detailLoading.value
          ? html`<div class="loading-indicator">Loading comments...</div>`
          : html`<${CommentThread} comments=${detailComments.value} />`}
        <${CommentForm} postId=${post.id} />
      <//>
    </div>
  `
}

// ── Main Board component ───────────────────────────────────

export function Board() {
  const posts = boardPosts.value
  const loading = boardLoading.value
  const postId = route.value.postId

  // Detail view: single post
  if (postId) {
    const post = posts.find(p => p.id === postId)
    return post
      ? html`<${PostDetail} post=${post} />`
      : html`
          <div>
            <button class="back-btn" onClick=${() => navigate('board')}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `
  }

  // List view
  return html`
    <${SortBar} />
    ${loading
      ? html`<div class="loading-indicator">Loading board...</div>`
      : posts.length === 0
        ? html`<div class="empty-state">No posts yet</div>`
        : html`<div class="board-post-list">
            ${posts.map(p => html`<${PostCard} key=${p.id} post=${p} />`)}
          </div>`}
  `
}

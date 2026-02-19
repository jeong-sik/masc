// Board tab — Posts list with sort modes, vote, comment

import { html } from 'htm/preact'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { boardPosts, boardSortMode, boardLoading, refreshBoard } from '../store'
import { votePost } from '../api'
import { navigate, navigateToPost, route } from '../router'
import type { BoardPost, BoardSortMode } from '../types'

const SORT_MODES: { id: BoardSortMode; label: string }[] = [
  { id: 'hot', label: 'Hot' },
  { id: 'trending', label: 'Trending' },
  { id: 'recent', label: 'Recent' },
  { id: 'updated', label: 'Updated' },
  { id: 'discussed', label: 'Discussed' },
]

function SortBar() {
  const current = boardSortMode.value
  return html`
    <div class="board-sort-bar">
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

function PostCard({ post }: { post: BoardPost }) {
  const handleVote = async (dir: 'up' | 'down') => {
    await votePost(post.id, dir)
    refreshBoard()
  }

  return html`
    <div class="board-post" onClick=${() => navigateToPost(post.id)}>
      <div class="board-post-votes">
        <button class="vote-btn up" onClick=${(e: Event) => { e.stopPropagation(); handleVote('up') }}>+</button>
        <span class="vote-count">${post.votes ?? 0}</span>
        <button class="vote-btn down" onClick=${(e: Event) => { e.stopPropagation(); handleVote('down') }}>-</button>
      </div>
      <div class="board-post-content">
        <div class="board-post-title">${post.title}</div>
        <div class="board-post-meta">
          <span class="board-post-author">${post.author}</span>
          <${TimeAgo} timestamp=${post.created_at} />
          ${post.comment_count > 0
            ? html`<span class="board-post-comments">${post.comment_count} comments</span>`
            : null}
        </div>
      </div>
    </div>
  `
}

export function Board() {
  const posts = boardPosts.value
  const loading = boardLoading.value
  const postId = route.value.postId

  // If viewing a single post, show detail
  if (postId) {
    const post = posts.find(p => p.id === postId)
    return html`
      <div>
        <button class="back-btn" onClick=${() => navigate('board')}>Back to Board</button>
        ${post
          ? html`
            <${Card} title=${post.title}>
              <div class="board-post-detail">
                <div class="board-post-body">${post.content}</div>
                <div class="board-post-meta">
                  <span>${post.author}</span>
                  <${TimeAgo} timestamp=${post.created_at} />
                  <span>${post.votes ?? 0} votes</span>
                </div>
              </div>
            <//>
          `
          : html`<div class="empty-state">Post not found</div>`}
      </div>
    `
  }

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

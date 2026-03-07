// Board tab — discussion feed + debates/voting (merged from Council)

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from './common/card'
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
  serverStatus,
  registerCouncilRefresh,
} from '../store'
import {
  votePost,
  fetchBoardPost,
  commentPost,
  fetchCouncilSessions,
  fetchDebates,
  fetchDebateStatus,
  startDebate,
} from '../api'
import { navigate, navigateToPost, route } from '../router'
import type { BoardPost, BoardComment, BoardSortMode, CouncilDebate, CouncilDebateSummary, CouncilSession } from '../types'

// ── Sub-tab state ──────────────────────────────────────────
type BoardSubView = 'posts' | 'debates' | 'voting'
const boardSubView = signal<BoardSubView>('posts')

// ── Council signals (merged from council.ts) ───────────────
const councilDebates = signal<CouncilDebate[]>([])
const councilSessions = signal<CouncilSession[]>([])
const councilTopicInput = signal('')
const councilLoading = signal(false)
const councilStarting = signal(false)
const councilErrorText = signal('')
const selectedDebateId = signal<string | null>(null)
const selectedDebateDetail = signal<CouncilDebateSummary | null>(null)
const councilDetailLoading = signal(false)
const councilFeedOk = signal<boolean | null>(null)
const lastCouncilRefreshAt = signal<number | null>(null)

export async function refreshCouncil() {
  councilLoading.value = true
  councilErrorText.value = ''
  try {
    const [d, s] = await Promise.all([
      fetchDebates(),
      fetchCouncilSessions(),
    ])
    councilDebates.value = d
    councilSessions.value = s
    councilFeedOk.value = true
    lastCouncilRefreshAt.value = Date.now()
  } catch (err) {
    councilErrorText.value = err instanceof Error ? err.message : 'Failed to load council data'
    councilFeedOk.value = false
  } finally {
    councilLoading.value = false
  }
}

// Register for SSE-driven refresh (replaces council.ts registration)
registerCouncilRefresh(refreshCouncil)

async function submitDebate() {
  const topic = councilTopicInput.value.trim()
  if (!topic) return
  councilStarting.value = true
  try {
    const created = await startDebate(topic)
    councilTopicInput.value = ''
    showToast(created?.id ? `Debate started: ${created.id}` : 'Debate started', 'success')
    await refreshCouncil()
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to start debate'
    showToast(msg, 'error')
  } finally {
    councilStarting.value = false
  }
}

async function loadDebateDetail(debateId: string) {
  selectedDebateId.value = debateId
  councilDetailLoading.value = true
  selectedDebateDetail.value = null
  try {
    selectedDebateDetail.value = await fetchDebateStatus(debateId)
  } catch (err) {
    councilErrorText.value = err instanceof Error ? err.message : 'Failed to load debate status'
    selectedDebateDetail.value = null
  } finally {
    councilDetailLoading.value = false
  }
}

const SORT_MODES: { id: BoardSortMode; label: string }[] = [
  { id: 'hot', label: 'Hot' },
  { id: 'trending', label: 'Trending' },
  { id: 'recent', label: 'Recent' },
  { id: 'updated', label: 'Updated' },
  { id: 'discussed', label: 'Discussed' },
]
// ── Local state for detail view ────────────────────────────

const detailPost = signal<BoardPost | null>(null)
const detailComments = signal<BoardComment[]>([])
const detailLoading = signal(false)
const detailPostId = signal<string | null>(null)
const commentText = signal('')
function defaultCommentAuthor(): string {
  const params = new URLSearchParams(window.location.search)
  return params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || 'dashboard-user'
}
const commentAuthor = signal(defaultCommentAuthor())
const commentSubmitting = signal(false)

async function loadPostDetail(postId: string) {
  detailPostId.value = postId
  detailPost.value = null
  detailComments.value = []
  detailLoading.value = true
  try {
    const data = await fetchBoardPost(postId)
    // Guard: discard stale response if user navigated to a different post
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
      flair: data.flair,
      hearth_count: data.hearth_count,
    }
    detailComments.value = data.comments ?? []
  } catch {
    if (detailPostId.value === postId) {
      detailPost.value = null
      detailComments.value = []
    }
    // Post detail may not be available; comments remain empty
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

// ── Components ─────────────────────────────────────────────

function SortBar() {
  const current = boardSortMode.value
  return html`
    <div class="board-toolbar">
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
      <div class="board-toolbar-actions">
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

function BoardFeedNotice() {
  const quality = serverStatus.value?.data_quality
  if (!quality) return null
  if (quality.board_contract_ok !== false && !quality.last_sync_at) return null

  return html`
    <div class="feed-health-banner ${quality.board_contract_ok === false ? 'degraded' : 'ok'}">
      <span class="feed-health-title">
        ${quality.board_contract_ok === false ? 'Board feed degraded' : 'Board feed synced'}
      </span>
      ${quality.last_sync_at
        ? html`<span class="feed-health-meta">Last sync: <${TimeAgo} timestamp=${quality.last_sync_at} /></span>`
        : html`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `
}

function FlairBadge({ flair }: { flair?: string }) {
  if (!flair) return null
  return html`<span class="post-flair ${flair}">${flair}</span>`
}

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

function BoardSummary() {
  const sortLabel = SORT_MODES.find(mode => mode.id === boardSortMode.value)?.label ?? boardSortMode.value
  const visibleCount = boardPosts.value.length

  return html`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${visibleCount}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${sortLabel}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${boardExcludeSystem.value ? 'Auto reports hidden by default' : 'All posts visible'}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${lastBoardRefreshAt.value ? html`<${TimeAgo} timestamp=${lastBoardRefreshAt.value} />` : 'Not loaded'}</strong>
      </div>
    </div>
  `
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
        <div class="post-head">
          <div class="post-title-row">
            <div class="post-title">${post.title}</div>
            <div class="post-chip-row">
              <${FlairBadge} flair=${post.flair} />
              ${isUpdated(post) ? html`<span class="board-meta-chip">Updated</span>` : null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${post.author}</span>
            <span><${TimeAgo} timestamp=${post.created_at} /></span>
            ${isUpdated(post)
              ? html`<span>Updated <${TimeAgo} timestamp=${post.updated_at} /></span>`
              : null}
            <span>${post.comment_count} comments</span>
            <span>${post.votes ?? 0} votes</span>
            ${(post.hearth_count ?? 0) > 0
              ? html`<span>♥ ${post.hearth_count}</span>`
              : null}
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

// ── Council sub-components ─────────────────────────────────

function DebateRow({ debate }: { debate: CouncilDebate }) {
  const selected = selectedDebateId.value === debate.id
  return html`
    <button
      class="council-row ${selected ? 'selected' : ''}"
      onClick=${() => loadDebateDetail(debate.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${debate.topic}</div>
        <div class="council-sub">
          <span>ID: ${debate.id.slice(0, 10)}</span>
          <span>Args: ${debate.argument_count}</span>
        </div>
      </div>
      <span class="council-state ${debate.status}">${debate.status}</span>
    </button>
  `
}

function SessionRow({ session }: { session: CouncilSession }) {
  return html`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${session.topic}</div>
        <div class="council-sub">
          <span>ID: ${session.id.slice(0, 10)}</span>
          <span>Initiator: ${session.initiator}</span>
          ${session.state ? html`<span>State: ${session.state}</span>` : null}
        </div>
      </div>
      <span class="council-state vote">${session.votes}/${session.quorum}</span>
    </div>
  `
}

function CouncilFeedNotice() {
  if (councilFeedOk.value === null) return null
  if (councilFeedOk.value && !lastCouncilRefreshAt.value) return null

  return html`
    <div class="feed-health-banner ${councilFeedOk.value === false ? 'degraded' : 'ok'}">
      <span class="feed-health-title">
        ${councilFeedOk.value === false ? 'Council feed degraded' : 'Council feed synced'}
      </span>
      ${lastCouncilRefreshAt.value
        ? html`<span class="feed-health-meta">Last sync: <${TimeAgo} timestamp=${lastCouncilRefreshAt.value} /></span>`
        : html`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `
}

function DebatesView() {
  const councilFeedDegraded = councilFeedOk.value === false

  return html`
    <div>
      <${CouncilFeedNotice} />
      <${Card} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${councilTopicInput.value}
            onInput=${(e: Event) => { councilTopicInput.value = (e.target as HTMLInputElement).value }}
            onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') submitDebate() }}
            disabled=${councilStarting.value}
          />
          <button
            class="control-btn secondary"
            onClick=${submitDebate}
            disabled=${councilStarting.value || councilTopicInput.value.trim() === ''}
          >
            ${councilStarting.value ? 'Starting...' : 'Start Debate'}
          </button>
          <button class="control-btn ghost" onClick=${refreshCouncil} disabled=${councilLoading.value}>
            ${councilLoading.value ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
        ${councilErrorText.value ? html`<div class="council-error">${councilErrorText.value}</div>` : null}
      <//>

      <${Card} title="Debates" class="section">
        <div class="council-list">
          ${councilDebates.value.length === 0
            ? html`<div class="empty-state">${councilFeedDegraded ? 'No debates loaded (council feed degraded).' : 'No debates yet'}</div>`
            : councilDebates.value.map(d => html`<${DebateRow} key=${d.id} debate=${d} />`)}
        </div>
      <//>

      <${Card} title=${selectedDebateId.value ? `Debate Detail (${selectedDebateId.value})` : 'Debate Detail'} class="section">
        ${councilDetailLoading.value
          ? html`<div class="loading-indicator">Loading debate detail...</div>`
          : selectedDebateDetail.value
            ? html`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${selectedDebateDetail.value.status}</span>
                  <span>Total arguments: ${selectedDebateDetail.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${selectedDebateDetail.value.support_count}</span>
                  <span>Oppose: ${selectedDebateDetail.value.oppose_count}</span>
                  <span>Neutral: ${selectedDebateDetail.value.neutral_count}</span>
                </div>
                ${selectedDebateDetail.value.summary_text
                  ? html`<pre class="council-detail">${selectedDebateDetail.value.summary_text}</pre>`
                  : null}
              `
            : html`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `
}

function VotingView() {
  const councilFeedDegraded = councilFeedOk.value === false

  return html`
    <div>
      <${CouncilFeedNotice} />
      <${Card} title="Voting Sessions" class="section">
        <div class="council-list">
          ${councilSessions.value.length === 0
            ? html`<div class="empty-state">${councilFeedDegraded ? 'No sessions loaded (council feed degraded).' : 'No active sessions'}</div>`
            : councilSessions.value.map(s => html`<${SessionRow} key=${s.id} session=${s} />`)}
        </div>
      <//>
    </div>
  `
}

// ── Sub-tab bar ────────────────────────────────────────────

function BoardSubTabs() {
  const current = boardSubView.value
  return html`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${current === 'posts' ? 'active' : ''}" onClick=${() => { boardSubView.value = 'posts' }}>Posts</button>
      <button class="sub-tab-btn ${current === 'debates' ? 'active' : ''}" onClick=${() => { boardSubView.value = 'debates' }}>Debates</button>
      <button class="sub-tab-btn ${current === 'voting' ? 'active' : ''}" onClick=${() => { boardSubView.value = 'voting' }}>Voting</button>
    </div>
  `
}

// ── Posts list view ────────────────────────────────────────

function PostsView() {
  const posts = boardPosts.value
  const loading = boardLoading.value
  const boardFeedDegraded = serverStatus.value?.data_quality?.board_contract_ok === false

  return html`
    <div>
      <${BoardFeedNotice} />
      <${BoardSummary} />
      <${SortBar} />
      ${loading
        ? html`<div class="loading-indicator">Loading board...</div>`
        : posts.length === 0
            ? html`
              <div class="empty-state">
                ${boardFeedDegraded
                  ? 'No posts loaded (board feed degraded). Check board contract sync.'
                  : boardExcludeSystem.value
                    ? 'No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.'
                    : 'No posts yet'}
              </div>
            `
          : html`<div class="board-post-list">
              ${posts.map(p => html`<${PostCard} key=${p.id} post=${p} />`)}
            </div>`}
    </div>
  `
}

// ── Main Board component ───────────────────────────────────

export function Board() {
  const posts = boardPosts.value
  const postId = route.value.postId
  const boardFeedDegraded = serverStatus.value?.data_quality?.board_contract_ok === false
  const subView = boardSubView.value

  // Load council data when switching to debates/voting sub-tab
  useEffect(() => {
    if (subView === 'debates' || subView === 'voting') {
      refreshCouncil()
    }
  }, [subView])

  // Detail view: single post (overrides sub-tabs)
  if (postId) {
    const post = posts.find(p => p.id === postId) ?? (detailPostId.value === postId ? detailPost.value : null)
    if (!post && detailPostId.value !== postId && !detailLoading.value) {
      loadPostDetail(postId)
    }
    return post
      ? html`
          <${BoardFeedNotice} />
          <${BoardSummary} />
          <${PostDetail} post=${post} />
        `
      : html`
          <div>
            <${BoardFeedNotice} />
            <${BoardSummary} />
            <button class="back-btn" onClick=${() => navigate('board')}>← Back to Board</button>
            ${detailLoading.value
              ? html`<div class="loading-indicator">Loading post...</div>`
              : html`
                  <div class="empty-state">
                    ${boardFeedDegraded ? 'Post not available while board feed is degraded' : 'Post not found'}
                  </div>
                `}
          </div>
        `
  }

  // List view with sub-tabs
  return html`
    <${BoardSubTabs} />
    ${subView === 'debates'
      ? html`<${DebatesView} />`
      : subView === 'voting'
        ? html`<${VotingView} />`
        : html`<${PostsView} />`}
  `
}

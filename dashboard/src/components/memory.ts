import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { Markdown } from './common/markdown'
import { showToast } from './common/toast'
import { stripStateBlocks } from '../keeper-message'
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
  { id: 'recent', label: '최신순' },
  { id: 'hot', label: '인기순' },
  { id: 'trending', label: '급상승' },
  { id: 'updated', label: '최근 갱신' },
  { id: 'discussed', label: '토론 많은 순' },
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
  if (!flattened) return '미리보기 없음'
  return flattened.length > 180 ? `${flattened.slice(0, 177)}...` : flattened
}

function isUpdated(post: BoardPost): boolean {
  return post.updated_at !== post.created_at
}

function isAutomationBoardPost(post: BoardPost): boolean {
  if (post.post_kind) return post.post_kind === 'automation'
  const hearth = (post.hearth ?? '').toLowerCase()
  if (post.visibility !== 'internal' || !post.expires_at || !hearth) return false
  if (hearth.startsWith('mdal')) return true
  if (hearth.includes('harness')) return true
  return false
}

function isSystemBoardAuthor(author: string): boolean {
  return author === 'team-session'
}

function boardPostKind(post: BoardPost): 'human' | 'automation' | 'system' {
  if (post.post_kind) return post.post_kind
  if (isSystemBoardAuthor(post.author)) return 'system'
  if (isAutomationBoardPost(post)) return 'automation'
  return 'human'
}

function splitVisiblePosts(posts: BoardPost[]): { human: BoardPost[]; operations: BoardPost[]; hiddenAutomation: number } {
  const human: BoardPost[] = []
  const operations: BoardPost[] = []
  let hiddenAutomation = 0
  posts.forEach(post => {
    const kind = boardPostKind(post)
    if (kind === 'system' && boardExcludeSystem.value) return
    if (kind === 'automation' && hideAutomationPosts.value) {
      hiddenAutomation += 1
      return
    }
    if (kind === 'human') {
      human.push(post)
      return
    }
    operations.push(post)
  })
  return { human, operations, hiddenAutomation }
}

function expiryChip(post: BoardPost) {
  if (!post.expires_at) return null
  const expiresAtMs = Date.parse(post.expires_at)
  if (!Number.isFinite(expiresAtMs)) return null
  if (expiresAtMs <= Date.now()) return html`<span class="board-meta-chip">만료됨</span>`
  return html`<span class="board-meta-chip">만료까지 <${TimeAgo} timestamp=${post.expires_at} /></span>`
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
    showToast('댓글을 등록했습니다', 'success')
    await loadPostDetail(postId)
    refreshBoard()
  } catch {
    showToast('댓글 등록에 실패했습니다', 'error')
  } finally {
    commentSubmitting.value = false
  }
}

function SortBar() {
  const current = boardSortMode.value
  const hideLabel = hideAutomationPosts.value ? '자동화 글 숨김' : '자동화 글 표시 중'
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
          ${boardExcludeSystem.value ? '시스템 글 숨김' : '시스템 글 표시 중'}
        </button>
        <button class="control-btn ghost" onClick=${refreshBoard} disabled=${boardLoading.value}>
          ${boardLoading.value ? '새로고침 중...' : '새로고침'}
        </button>
      </div>
    </div>
  `
}

function MemorySummary() {
  const sortLabel = SORT_MODES.find(mode => mode.id === boardSortMode.value)?.label ?? boardSortMode.value
  const grouped = splitVisiblePosts(boardPosts.value)
  const visibleCount = grouped.human.length + grouped.operations.length
  return html`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">보이는 글</span>
        <strong>${visibleCount}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">정렬</span>
        <strong>${sortLabel}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">잡음 필터</span>
        <strong>${hideAutomationPosts.value ? `자동화 ${grouped.hiddenAutomation}건 숨김` : '분리된 레인 표시'}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${boardExcludeSystem.value ? '시스템 글 숨김' : '시스템 레인 표시'}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${lastBoardRefreshAt.value ? html`<${TimeAgo} timestamp=${lastBoardRefreshAt.value} />` : '아직 불러오지 않음'}</strong>
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
      showToast('투표에 실패했습니다', 'error')
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
              <div class="text-[#e8f0ff]">${post.title}</div>
              <div class="post-chip-row">
                ${isUpdated(post) ? html`<span class="board-meta-chip">수정됨</span>` : null}
                ${boardPostKind(post) !== 'human' ? html`<span class="board-meta-chip">${boardPostKind(post)}</span>` : null}
                ${post.hearth ? html`<span class="board-meta-chip">${post.hearth}</span>` : null}
                ${post.visibility ? html`<span class="board-meta-chip">${post.visibility}</span>` : null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 <a class="author-link" class="cursor-pointer underline" onClick=${(e: Event) => { e.stopPropagation(); navigate('status', { section: 'agents', agent: post.author }) }}>${post.author}</a></span>
            <span><${TimeAgo} timestamp=${post.created_at} /></span>
            ${isUpdated(post) ? html`<span>수정 <${TimeAgo} timestamp=${post.updated_at} /></span>` : null}
            <span>댓글 ${post.comment_count}</span>
            <span>투표 ${post.votes ?? 0}</span>
          </div>
        </div>
        <div class="post-snippet">${previewText(stripStateBlocks(post.body))}</div>
      </div>
    </div>
  `
}

function CommentThread({ comments }: { comments: BoardComment[] }) {
  if (comments.length === 0) return html`<div class="empty-state" class="text-[13px]">아직 댓글이 없습니다</div>`

  return html`
    <div class="comment-thread">
      ${comments.map(comment => html`
        <div key=${comment.id} class="board-comment">
          <span class="comment-author"><a class="author-link" class="cursor-pointer underline" onClick=${() => navigate('status', { section: 'agents', agent: comment.author })}>${comment.author}</a></span>
          <span class="comment-time"><${TimeAgo} timestamp=${comment.created_at} /></span>
          <div class="comment-text">${comment.content}</div>
        </div>
      `)}
    </div>
  `
}

function CommentForm({ postId }: { postId: string }) {
  return html`
    <div class="comment-form" class="mt-3 flex gap-2">
      <input
        type="text"
        class="font-[inherit]"
        placeholder="댓글 추가..."
        value=${commentText.value}
        onInput=${(event: Event) => { commentText.value = (event.target as HTMLInputElement).value }}
        onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') submitComment(postId) }}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${commentSubmitting.value}
      />
      <button
        class="font-[inherit]"
        onClick=${() => submitComment(postId)}
        disabled=${commentSubmitting.value || commentText.value.trim() === ''}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${commentSubmitting.value ? '...' : '등록'}
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
      showToast('투표에 실패했습니다', 'error')
    }
  }

  return html`
    <div>
      <button class="back-btn" onClick=${() => navigate('work', { section: 'board' })}>← 게시판으로 돌아가기</button>
      <${Card} title=${post.title}>
        <div class="board-detail p-5">
          <div class="post-body">
            <${Markdown} text=${stripStateBlocks(post.body)} />
          </div>
          <div class="post-meta" class="mt-3">
            <span><a class="author-link" class="cursor-pointer underline" onClick=${() => navigate('status', { section: 'agents', agent: post.author })}>${post.author}</a></span>
            <${TimeAgo} timestamp=${post.created_at} />
            <span>${post.votes ?? 0} votes</span>
          </div>
          ${(post.hearth || post.visibility || post.expires_at)
            ? html`
                <div class="post-chip-row" class="mt-2">
                  ${post.hearth ? html`<span class="board-meta-chip">${post.hearth}</span>` : null}
                  ${post.visibility ? html`<span class="board-meta-chip">${post.visibility}</span>` : null}
                  ${boardPostKind(post) !== 'human' ? html`<span class="board-meta-chip">${boardPostKind(post)}</span>` : null}
                  ${expiryChip(post)}
                </div>
              `
            : null}
          ${post.meta
            ? html`
                <details class="mt-3">
                  <summary>운영 메타</summary>
                  <div class="post-body" class="mt-2">
                    ${post.meta.source ? html`<div><strong>출처</strong>: ${post.meta.source}</div>` : null}
                    ${post.meta.state_block
                      ? html`<pre class="whitespace-pre-wrap mt-2">${post.meta.state_block}</pre>`
                      : null}
                  </div>
                </details>
              `
            : null}
          <div class="mt-2 flex gap-1.5">
            <button class="vote-btn upvote" onClick=${() => handleVote('up')}>▲ 추천</button>
            <button class="vote-btn downvote" onClick=${() => handleVote('down')}>▼ 비추천</button>
          </div>
        </div>
      <//>

      <${Card} title="댓글">
        ${detailLoading.value
          ? html`<div class="loading-indicator">댓글 불러오는 중...</div>`
          : html`<${CommentThread} comments=${detailComments.value} />`}
        <${CommentForm} postId=${post.id} />
      <//>
    </div>
  `
}

export function Memory() {
  const grouped = splitVisiblePosts(boardPosts.value)
  const posts = [...grouped.human, ...grouped.operations]
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
          <${MemorySummary} />
          <${PostDetail} post=${post} />
        `
      : html`
          <div>
            <${MemorySummary} />
            <button class="back-btn" onClick=${() => navigate('work', { section: 'board' })}>← 게시판으로 돌아가기</button>
            ${detailLoading.value
              ? html`<div class="loading-indicator">글 불러오는 중...</div>`
              : html`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `
  }

  return html`
    <div>
      <${MemorySummary} />
      <${SortBar} />
      ${boardLoading.value
        ? html`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`
        : posts.length === 0
          ? html`<div class="empty-state">아직 게시글이 없습니다. 에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다.</div>`
          : html`
              <${Card} title="사람이 쓴 글" class="section">
                <div class="board-post-list">
                  ${grouped.human.slice(0, visibleLimit.value).map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
                </div>
                ${grouped.human.length > visibleLimit.value ? html`
                  <div class="text-center py-3">
                    <button
                      class="control-btn ghost"
                      onClick=${() => { visibleLimit.value = visibleLimit.value + PAGE_SIZE }}
                    >
                      더 보기 (${grouped.human.length - visibleLimit.value}개 남음)
                    </button>
                  </div>
                ` : null}
              <//>
              ${grouped.operations.length > 0
                ? html`
                    <${Card} title="자동화 · 시스템" class="section">
                      <div class="board-post-list">
                        ${grouped.operations.map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
                      </div>
                    <//>
                  `
                : null}
            `}
    </div>
  `
}

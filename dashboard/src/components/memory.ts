import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { KpiCard } from './common/stat-row'
import { TimeAgo } from './common/time-ago'
import { Markdown } from './common/markdown'
import { showToast } from './common/toast'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
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
  createPost,
} from '../api'
import { navigate, navigateToPost, route } from '../router'
import { findKeeper } from './execution/shared'
import { openKeeperDetail } from './keeper-detail'
import type { BoardComment, BoardPost, BoardSortMode } from '../types'

function openAuthorDetail(name: string) {
  const keeper = findKeeper(name)
  if (keeper) openKeeperDetail(keeper)
  else navigate('status', { section: 'agents', agent: name })
}

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
const showNewPostForm = signal(false)
const newPostTitle = signal('')
const newPostContent = signal('')
const newPostSubmitting = signal(false)
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
  if (expiresAtMs <= Date.now()) return html`<span class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] tracking-wide uppercase bg-[var(--bad-15)] text-[var(--bad-light)] border border-[var(--bad-30)]">만료됨</span>`
  return html`<span class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] tracking-wide uppercase bg-[var(--warn-15)] text-[var(--warn)] border border-[var(--warn-30)]">만료까지 <${TimeAgo} timestamp=${post.expires_at} /></span>`
}

/** Author avatar: deterministic emoji from name hash */
function authorAvatar(name: string): string {
  const avatars = ['🤖', '🧑‍💻', '🦊', '🐙', '🔮', '🧪', '⚡', '🎯', '🛸', '🧠', '🦉', '🐺', '🎲', '🌊', '🔥']
  let hash = 0
  for (let i = 0; i < name.length; i++) {
    hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0
  }
  return avatars[Math.abs(hash) % avatars.length] || '🤖'
}

function kindBadgeColor(kind: string): string {
  switch (kind) {
    case 'automation': return 'bg-[var(--cyan-16)] text-[#38bdf8] border-[rgba(34,211,238,0.3)]'
    case 'system': return 'bg-[var(--slate-gray-15)] text-[var(--text-slate)] border-[var(--border-slate-22)]'
    default: return 'bg-[var(--white-8)] text-[var(--text-muted)] border-[var(--border-slate-16)]'
  }
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

async function submitNewPost() {
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
  } catch {
    showToast('글 등록에 실패했습니다', 'error')
  } finally {
    newPostSubmitting.value = false
  }
}

function NewPostForm() {
  if (!showNewPostForm.value) {
    return html`
      <button
        class="w-full py-2.5 rounded-lg border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-4)] hover:text-[var(--text-body)] transition-colors bg-transparent"
        onClick=${() => { showNewPostForm.value = true }}
      >+ 새 글 작성</button>
    `
  }

  return html`
    <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-3">
      <input
        class="w-full px-3 py-2 rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-[14px] font-medium focus:border-[rgba(71,184,255,0.5)] outline-none placeholder:text-[var(--text-muted)]"
        type="text"
        placeholder="제목"
        value=${newPostTitle.value}
        onInput=${(e: Event) => { newPostTitle.value = (e.target as HTMLInputElement).value }}
      />
      <textarea
        class="w-full px-3 py-2 rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] min-h-[80px] resize-y focus:border-[rgba(71,184,255,0.5)] outline-none placeholder:text-[var(--text-muted)]"
        placeholder="내용을 입력하세요..."
        value=${newPostContent.value}
        onInput=${(e: Event) => { newPostContent.value = (e.target as HTMLTextAreaElement).value }}
      ></textarea>
      <div class="flex gap-2 justify-end">
        <button
          class="px-3 py-1.5 rounded-lg text-[13px] border border-[var(--card-border)] bg-transparent text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]"
          onClick=${() => { showNewPostForm.value = false; newPostTitle.value = ''; newPostContent.value = '' }}
        >취소</button>
        <button
          class="px-4 py-1.5 rounded-lg text-[13px] font-medium border border-[rgba(71,184,255,0.4)] bg-[var(--accent-soft)] text-[var(--accent)] cursor-pointer hover:bg-[rgba(71,184,255,0.2)] disabled:opacity-50"
          disabled=${newPostSubmitting.value || !newPostTitle.value.trim() || !newPostContent.value.trim()}
          onClick=${() => { void submitNewPost() }}
        >${newPostSubmitting.value ? '등록 중...' : '등록'}</button>
      </div>
    </div>
  `
}

function SortBar() {
  const current = boardSortMode.value
  const hideLabel = hideAutomationPosts.value ? '자동화 글 숨김' : '자동화 글 표시 중'
  return html`
    <div class="flex flex-col gap-3 mb-6 p-4 rounded-2xl border border-card-border/50 bg-card/30 backdrop-blur-md shadow-inner">
      <div class="flex items-center gap-2 flex-wrap">
        ${SORT_MODES.map(mode => html`
          <button
            class="px-4 py-2 rounded-xl text-[12px] font-bold transition-all duration-200 border cursor-pointer shadow-sm
              ${current === mode.id
                ? 'bg-ok/10 text-ok border-ok/30 shadow-[0_0_10px_rgba(74,222,128,0.1)]'
                : 'bg-white/5 text-text-muted border-transparent hover:bg-white/10 hover:text-text-body hover:border-white/10'
              }"
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
      <div class="flex items-center gap-3 flex-wrap">
        <button
          class="px-3 py-1.5 rounded-lg text-[11px] font-semibold transition-all duration-200 border cursor-pointer
            ${hideAutomationPosts.value
              ? 'bg-accent/10 text-accent border-accent/20 shadow-sm'
              : 'bg-transparent text-text-muted border-white/10 hover:bg-white/5 hover:text-text-body'
            }"
          onClick=${() => {
            hideAutomationPosts.value = !hideAutomationPosts.value
          }}
        >
          ${hideLabel}
        </button>
        <button
          class="px-3 py-1.5 rounded-lg text-[11px] font-semibold transition-all duration-200 border cursor-pointer
            ${boardExcludeSystem.value
              ? 'bg-accent/10 text-accent border-accent/20 shadow-sm'
              : 'bg-transparent text-text-muted border-white/10 hover:bg-white/5 hover:text-text-body'
            }"
          onClick=${() => {
            boardExcludeSystem.value = !boardExcludeSystem.value
            refreshBoard()
          }}
        >
          ${boardExcludeSystem.value ? '시스템 글 숨김' : '시스템 글 표시 중'}
        </button>
        <div class="ml-auto">
          <button
            class="px-4 py-1.5 rounded-lg text-[11px] font-bold transition-all duration-200 border cursor-pointer bg-white/5 text-text-muted border-white/10 hover:bg-white/10 hover:text-text-strong shadow-sm disabled:opacity-50 disabled:cursor-not-allowed"
            onClick=${refreshBoard}
            disabled=${boardLoading.value}
          >
            ${boardLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
      </div>
    </div>
  `
}

function MemorySummary() {
  const sortLabel = SORT_MODES.find(mode => mode.id === boardSortMode.value)?.label ?? boardSortMode.value
  const grouped = splitVisiblePosts(boardPosts.value)
  const visibleCount = grouped.human.length + grouped.operations.length
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-4 mb-6">
      <${KpiCard} label="보이는 글" value=${visibleCount} />
      <${KpiCard} label="정렬" value=${sortLabel} />
      <${KpiCard} label="잡음 필터" value=${hideAutomationPosts.value ? `자동화 ${grouped.hiddenAutomation}건 숨김` : '분리된 레인 표시'} />
      <${KpiCard} label="시스템 글 정책" value=${boardExcludeSystem.value ? '시스템 글 숨김' : '시스템 레인 표시'} />
      <${KpiCard} label="최근 갱신" value=${lastBoardRefreshAt.value ? html`<${TimeAgo} timestamp=${lastBoardRefreshAt.value} />` : '아직 불러오지 않음'} />
    </div>
  `
}

function PostCard({ post }: { post: BoardPost }) {
  const kind = boardPostKind(post)

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
    <div
      class="group flex gap-4 rounded-2xl p-5 border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:shadow-md hover:bg-card/60 hover:-translate-y-0.5 hover:border-accent/30 transition-all duration-200 cursor-pointer"
      onClick=${() => navigateToPost(post.id)}
    >
      <!-- Vote column -->
      <div class="flex flex-col items-center gap-1.5 pt-1 min-w-[40px]">
        <button
          class="w-8 h-6 flex items-center justify-center rounded-md text-[13px] font-bold text-text-muted hover:text-[#ff4500] hover:bg-[#ff4500]/10 transition-colors cursor-pointer border border-transparent hover:border-[#ff4500]/20"
          onClick=${(event: Event) => handleVote('up', event)}
        >▲</button>
        <span class="text-[14px] font-bold tabular-nums text-text-strong bg-white/5 w-full text-center py-1 rounded-md shadow-inner">${post.votes ?? 0}</span>
        <button
          class="w-8 h-6 flex items-center justify-center rounded-md text-[13px] font-bold text-text-muted hover:text-accent hover:bg-accent/10 transition-colors cursor-pointer border border-transparent hover:border-accent/20"
          onClick=${(event: Event) => handleVote('down', event)}
        >▼</button>
      </div>

      <!-- Post body -->
      <div class="flex-1 min-w-0 flex flex-col">
        <!-- Title -->
        <div class="text-[15px] font-bold text-text-strong leading-snug mb-2.5 group-hover:text-accent transition-colors tracking-wide">${post.title}</div>

        <!-- Content preview: max 3 lines -->
        <div class="text-[13px] text-text-body/90 leading-relaxed mb-4 overflow-hidden font-medium" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical">${previewText(stripStateBlocks(post.body))}</div>

        <!-- Footer: author + meta + badges -->
        <div class="flex items-center gap-3 flex-wrap mt-auto pt-3 border-t border-card-border/50">
          <!-- Author line -->
          <div class="flex items-center gap-1.5 bg-white/5 pl-1 pr-2 py-0.5 rounded-lg border border-white/5 shadow-sm">
            <span class="text-[13px]">${authorAvatar(post.author)}</span>
            <a
              class="text-[11px] font-bold text-text-muted hover:text-accent transition-colors cursor-pointer tracking-wider"
              onClick=${(e: Event) => { e.stopPropagation(); openAuthorDetail(post.author) }}
            >${post.author}</a>
          </div>
          <span class="text-[11px] font-mono text-text-muted/60"><${TimeAgo} timestamp=${post.created_at} /></span>
          ${isUpdated(post) ? html`<span class="text-[10px] font-semibold text-text-dim/50">(수정됨)</span>` : null}

          <!-- Separator -->
          <span class="text-white/10">|</span>

          <!-- Counts -->
          <span class="text-[11px] font-semibold text-text-muted flex items-center gap-1"><span class="text-[13px]">💬</span> ${post.comment_count}</span>

          <!-- Category badges -->
          ${kind !== 'human' ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border ${kindBadgeColor(kind)}">${kind}</span>` : null}
          ${post.hearth ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${post.hearth}</span>` : null}
          ${post.visibility && post.visibility !== 'public' ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-16)]">${post.visibility}</span>` : null}
        </div>
      </div>
    </div>
  `
}

function toggleCommentExpand(e: Event) {
  const btn = e.currentTarget as HTMLButtonElement
  const comment = btn.parentElement
  if (!comment) return
  const textEl = comment.querySelector('.comment-text')
  if (!textEl) return
  const isExpanded = textEl.classList.toggle('expanded')
  btn.textContent = isExpanded ? '접기' : '더 보기...'
}

function CommentItem({ comment }: { comment: BoardComment }) {
  const needsTruncation = (comment.content?.length ?? 0) > 300

  return html`
    <div class="board-comment rounded-2xl p-5 bg-card/60 backdrop-blur-md border border-card-border/50 shadow-sm hover:shadow-md transition-shadow">
      <div class="flex items-center gap-3 mb-3">
        <span class="text-[14px] bg-white/5 size-6 flex items-center justify-center rounded-lg shadow-inner border border-white/5">${authorAvatar(comment.author)}</span>
        <a class="text-[12px] font-bold text-text-strong hover:text-accent transition-colors cursor-pointer tracking-wide" onClick=${() => openAuthorDetail(comment.author)}>${comment.author}</a>
        <span class="text-[10px] text-text-dim/80 font-mono"><${TimeAgo} timestamp=${comment.created_at} /></span>
      </div>
      <div class="comment-text text-[13px] text-text-body/90 leading-relaxed font-medium">${comment.content}</div>
      ${needsTruncation ? html`
        <button
          class="comment-expand-btn mt-2 text-[11px] font-bold text-accent hover:text-accent/80 transition-colors cursor-pointer bg-accent/10 px-2 py-0.5 rounded-md border border-accent/20"
          style="display: inline"
          onClick=${toggleCommentExpand}
        >더 보기...</button>
      ` : null}
    </div>
  `
}

function CommentThread({ comments }: { comments: BoardComment[] }) {
  if (comments.length === 0) return html`<${EmptyState} message="아직 댓글이 없습니다" compact />`

  const INITIAL_SHOW = 3
  const [expanded, setExpanded] = useState(false)
  const hiddenCount = comments.length - INITIAL_SHOW
  const visible = expanded || comments.length <= INITIAL_SHOW ? comments : comments.slice(-INITIAL_SHOW)

  return html`
    <div class="flex flex-col gap-3">
      ${!expanded && hiddenCount > 0 ? html`
        <button
          class="text-[12px] text-[var(--accent)] hover:underline cursor-pointer bg-transparent border-0 text-left py-1"
          onClick=${() => setExpanded(true)}
        >이전 댓글 ${hiddenCount}개 더 보기</button>
      ` : null}
      ${visible.map(comment => html`<${CommentItem} key=${comment.id} comment=${comment} />`)}
      ${expanded && hiddenCount > 0 ? html`
        <button
          class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] cursor-pointer bg-transparent border-0 text-left py-1"
          onClick=${() => setExpanded(false)}
        >접기</button>
      ` : null}
    </div>
  `
}

function CommentForm({ postId }: { postId: string }) {
  return html`
    <div class="mt-5 flex gap-3">
      <input
        type="text"
        class="flex-1 py-2 px-3 bg-[var(--white-5)] border border-[var(--border-slate-18)] rounded-lg text-[var(--text-body)] text-[13px] font-[inherit] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[rgba(71,184,255,0.55)] transition-colors"
        placeholder="댓글 추가..."
        value=${commentText.value}
        onInput=${(event: Event) => { commentText.value = (event.target as HTMLInputElement).value }}
        onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') submitComment(postId) }}
        disabled=${commentSubmitting.value}
      />
      <button
        class="py-2 px-4 rounded-lg text-[13px] font-medium font-[inherit] cursor-pointer transition-all duration-150 border
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
      <button
        class="mb-4 px-3 py-1.5 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
        onClick=${() => navigate('work', { section: 'board' })}
      >← 게시판으로 돌아가기</button>

      <${Card} title=${post.title}>
        <div class="flex flex-col gap-5">
          <div class="text-[13px] text-[var(--text-body)] leading-[1.65]">
            <${Markdown} text=${stripStateBlocks(post.body)} />
          </div>

          <!-- Author and meta -->
          <div class="flex gap-3 items-center flex-wrap pt-3 border-t border-[var(--border-slate-12)]">
            <span class="text-[13px]">${authorAvatar(post.author)}</span>
            <a class="text-[12px] text-[var(--text-body)] hover:text-[var(--accent)] transition-colors cursor-pointer" onClick=${() => navigate('status', { section: 'agents', agent: post.author })}>${post.author}</a>
            <span class="text-[11px] text-[var(--text-muted)]"><${TimeAgo} timestamp=${post.created_at} /></span>
            <span class="text-[11px] text-[var(--text-muted)]">${post.votes ?? 0} votes</span>
          </div>

          <!-- Badges -->
          ${(post.hearth || post.visibility || post.expires_at)
            ? html`
                <div class="flex gap-1.5 flex-wrap">
                  ${post.hearth ? html`<span class="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${post.hearth}</span>` : null}
                  ${post.visibility ? html`<span class="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium border bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-16)]">${post.visibility}</span>` : null}
                  ${boardPostKind(post) !== 'human' ? html`<span class="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium border ${kindBadgeColor(boardPostKind(post))}">${boardPostKind(post)}</span>` : null}
                  ${expiryChip(post)}
                </div>
              `
            : null}

          <!-- Meta details -->
          ${post.meta
            ? html`
                <details class="mt-1">
                  <summary class="cursor-pointer text-[12px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">운영 메타</summary>
                  <div class="mt-2 p-3 rounded-lg bg-[var(--white-3)] border border-[var(--border-slate-12)]">
                    ${post.meta.source ? html`<div class="text-[12px] text-[var(--text-body)]"><span class="text-[var(--text-muted)]">출처:</span> ${post.meta.source}</div>` : null}
                    ${post.meta.state_block
                      ? html`<pre class="whitespace-pre-wrap mt-2 text-[11px] text-[var(--text-muted)] leading-relaxed">${post.meta.state_block}</pre>`
                      : null}
                  </div>
                </details>
              `
            : null}

          <!-- Vote buttons -->
          <div class="flex gap-2">
            <button
              class="vote-btn upvote px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[#ff4500] hover:border-[rgba(255,69,0,0.3)] hover:bg-[rgba(255,69,0,0.08)] transition-all cursor-pointer"
              onClick=${() => handleVote('up')}
            >▲ 추천</button>
            <button
              class="vote-btn downvote px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[#7193ff] hover:border-[rgba(113,147,255,0.3)] hover:bg-[rgba(113,147,255,0.08)] transition-all cursor-pointer"
              onClick=${() => handleVote('down')}
            >▼ 비추천</button>
          </div>
        </div>
      <//>

      <div class="mt-6">
        <${Card} title="댓글">
          ${detailLoading.value
            ? html`<${LoadingState}>댓글 불러오는 중...<//>`
            : html`<${CommentThread} comments=${detailComments.value} />`}
          <${CommentForm} postId=${post.id} />
        <//>
      </div>
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
            <button
              class="mb-4 px-3 py-1.5 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
              onClick=${() => navigate('work', { section: 'board' })}
            >← 게시판으로 돌아가기</button>
            ${detailLoading.value
              ? html`<${LoadingState}>글 불러오는 중...<//>`
              : html`<${EmptyState} message="글을 찾지 못했습니다" compact />`}
          </div>
        `
  }

  return html`
    <div>
      <${MemorySummary} />
      <${SortBar} />
      <div class="mb-4">
        <${NewPostForm} />
      </div>
      ${boardLoading.value
        ? html`<${LoadingState}>메모리 피드 불러오는 중...<//>`
        : posts.length === 0
          ? html`<${EmptyState} message="아직 게시글이 없습니다. 에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다." compact />`
          : html`
              <${Card} title="사람이 쓴 글" class="mb-4">
                <div class="flex flex-col gap-2">
                  ${grouped.human.slice(0, visibleLimit.value).map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
                </div>
                ${grouped.human.length > visibleLimit.value ? html`
                  <div class="text-center py-4">
                    <button
                      class="px-4 py-2 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
                      onClick=${() => { visibleLimit.value = visibleLimit.value + PAGE_SIZE }}
                    >
                      더 보기 (${grouped.human.length - visibleLimit.value}개 남음)
                    </button>
                  </div>
                ` : null}
              <//>
              ${grouped.operations.length > 0
                ? html`
                    <${Card} title="자동화 · 시스템" class="mb-4">
                      <div class="flex flex-col gap-2">
                        ${grouped.operations.map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
                      </div>
                    <//>
                  `
                : null}
            `}
    </div>
  `
}

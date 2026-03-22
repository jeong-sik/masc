import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TextInput, TextArea } from './common/input'
import { Card, SurfaceCard, SectionCard } from './common/card'
import { EmptyState, LoadingState } from './common/feedback-state'
import { KpiCard } from './common/stat-row'
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
  createPost,
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
  return avatars[Math.abs(hash) % avatars.length] ?? '🤖'
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
    <${SurfaceCard} variant="light" class="grid gap-3">
      <${TextInput}
        class="text-[14px] font-medium"
        placeholder="제목"
        value=${newPostTitle.value}
        onInput=${(e: Event) => { newPostTitle.value = (e.target as HTMLInputElement).value }}
      />
      <${TextArea}
        placeholder="내용을 입력하세요..."
        value=${newPostContent.value}
        onInput=${(e: Event) => { newPostContent.value = (e.target as HTMLTextAreaElement).value }}
      />
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
    <//>
  `
}

function SortBar() {
  const current = boardSortMode.value
  const hideLabel = hideAutomationPosts.value ? '자동화 글 숨김' : '자동화 글 표시 중'
  return html`
    <${SurfaceCard} class="flex flex-col gap-3 mb-4 !p-3">
      <div class="flex items-center gap-1.5 flex-wrap">
        ${SORT_MODES.map(mode => html`
          <button
            class="px-3 py-1.5 rounded-lg text-[12px] font-medium transition-all duration-150 border cursor-pointer
              ${current === mode.id
                ? 'bg-[var(--ok-soft)] text-[var(--ok)] border-[var(--ok-30)]'
                : 'bg-transparent text-[var(--text-muted)] border-transparent hover:bg-[var(--white-8)] hover:text-[var(--text-body)]'
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
      <div class="flex items-center gap-2 flex-wrap">
        <button
          class="px-2.5 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer
            ${hideAutomationPosts.value
              ? 'bg-[var(--accent-12)] text-[var(--accent)] border-[var(--accent-18)]'
              : 'bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]'
            }"
          onClick=${() => {
            hideAutomationPosts.value = !hideAutomationPosts.value
          }}
        >
          ${hideLabel}
        </button>
        <button
          class="px-2.5 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer
            ${boardExcludeSystem.value
              ? 'bg-[var(--accent-12)] text-[var(--accent)] border-[var(--accent-18)]'
              : 'bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]'
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
            class="px-3 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] disabled:opacity-50 disabled:cursor-not-allowed"
            onClick=${refreshBoard}
            disabled=${boardLoading.value}
          >
            ${boardLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
      </div>
    <//>
  `
}

function MemorySummary() {
  const sortLabel = SORT_MODES.find(mode => mode.id === boardSortMode.value)?.label ?? boardSortMode.value
  const grouped = splitVisiblePosts(boardPosts.value)
  const visibleCount = grouped.human.length + grouped.operations.length
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-3 mb-4">
      <${SurfaceCard} class="flex flex-col gap-1.5">
        <${KpiCard} label="보이는 글" value=${visibleCount} />
      <//>
      <${SurfaceCard} class="flex flex-col gap-1.5">
        <${KpiCard} label="정렬" value=${sortLabel} />
      <//>
      <${SurfaceCard} class="flex flex-col gap-1.5">
        <${KpiCard} label="잡음 필터" value=${hideAutomationPosts.value ? `자동화 ${grouped.hiddenAutomation}건 숨김` : '분리된 레인 표시'} />
      <//>
      <${SurfaceCard} class="flex flex-col gap-1.5">
        <${KpiCard} label="시스템 글 정책" value=${boardExcludeSystem.value ? '시스템 글 숨김' : '시스템 레인 표시'} />
      <//>
      <${SurfaceCard} class="flex flex-col gap-1.5">
        <${KpiCard} label="최근 갱신" value=${lastBoardRefreshAt.value ? html`<${TimeAgo} timestamp=${lastBoardRefreshAt.value} />` : '아직 불러오지 않음'} />
      <//>
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
      class="group flex gap-3 rounded-xl p-4 border border-[var(--card-border)] bg-[var(--card)] hover:bg-[var(--white-6)] hover:border-[rgba(71,184,255,0.26)] transition-all duration-200 cursor-pointer"
      onClick=${() => navigateToPost(post.id)}
    >
      <!-- Vote column -->
      <div class="flex flex-col items-center gap-0.5 pt-0.5 min-w-[36px]">
        <button
          class="w-7 h-5 flex items-center justify-center rounded text-[11px] text-[var(--text-muted)] hover:text-[#ff4500] hover:bg-[rgba(255,69,0,0.1)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${(event: Event) => handleVote('up', event)}
        >▲</button>
        <span class="text-[13px] font-semibold tabular-nums text-[var(--text-strong)]">${post.votes ?? 0}</span>
        <button
          class="w-7 h-5 flex items-center justify-center rounded text-[11px] text-[var(--text-muted)] hover:text-[#7193ff] hover:bg-[rgba(113,147,255,0.1)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${(event: Event) => handleVote('down', event)}
        >▼</button>
      </div>

      <!-- Post body -->
      <div class="flex-1 min-w-0">
        <!-- Title -->
        <div class="text-[14px] font-medium text-[var(--text-strong)] leading-snug mb-1.5 group-hover:text-[var(--accent)] transition-colors">${post.title}</div>

        <!-- Content preview: max 3 lines -->
        <div class="text-[13px] text-[var(--text-body)] leading-[1.55] mb-2.5 overflow-hidden" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical">${previewText(stripStateBlocks(post.body))}</div>

        <!-- Footer: author + meta + badges -->
        <div class="flex items-center gap-2 flex-wrap">
          <!-- Author line -->
          <span class="text-[12px] text-[var(--text-muted)]">${authorAvatar(post.author)}</span>
          <a
            class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] transition-colors cursor-pointer"
            onClick=${(e: Event) => { e.stopPropagation(); navigate('status', { section: 'agents', agent: post.author }) }}
          >${post.author}</a>
          <span class="text-[11px] text-[var(--text-muted)] opacity-60"><${TimeAgo} timestamp=${post.created_at} /></span>
          ${isUpdated(post) ? html`<span class="text-[10px] text-[var(--text-muted)] opacity-50">(수정됨)</span>` : null}

          <!-- Separator -->
          <span class="text-[var(--text-muted)] opacity-30">|</span>

          <!-- Counts -->
          <span class="text-[11px] text-[var(--text-muted)]">댓글 ${post.comment_count}</span>

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
    <div class="rounded-lg p-3 bg-[var(--white-3)] border border-[var(--border-slate-12)]">
      <div class="flex items-center gap-2 mb-1.5">
        <span class="text-[12px]">${authorAvatar(comment.author)}</span>
        <a class="text-[12px] font-medium text-[var(--text-body)] hover:text-[var(--accent)] transition-colors cursor-pointer" onClick=${() => navigate('status', { section: 'agents', agent: comment.author })}>${comment.author}</a>
        <span class="text-[11px] text-[var(--text-muted)] opacity-60"><${TimeAgo} timestamp=${comment.created_at} /></span>
      </div>
      <div class="comment-text text-[13px] text-[var(--text-body)] leading-[1.55]">${comment.content}</div>
      ${needsTruncation ? html`
        <button
          class="comment-expand-btn mt-1 text-[11px] text-[var(--accent)] hover:underline cursor-pointer bg-transparent border-0"
          style="display: inline"
          onClick=${toggleCommentExpand}
        >더 보기...</button>
      ` : null}
    </div>
  `
}

function CommentThread({ comments }: { comments: BoardComment[] }) {
  if (comments.length === 0) return html`<${EmptyState}>아직 댓글이 없습니다<//>`

  return html`
    <div class="flex flex-col gap-2">
      ${comments.map(comment => html`<${CommentItem} key=${comment.id} comment=${comment} />`)}
    </div>
  `
}

function CommentForm({ postId }: { postId: string }) {
  return html`
    <div class="mt-4 flex gap-2">
      <${TextInput}
        class="flex-1"
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

      <${SectionCard} label=${post.title}>
        <div class="flex flex-col gap-4">
          <div class="text-[13px] text-[var(--text-body)] leading-[1.65]">
            <${Markdown} text=${stripStateBlocks(post.body)} />
          </div>

          <!-- Author and meta -->
          <div class="flex gap-2.5 items-center flex-wrap pt-3 border-t border-[var(--border-slate-12)]">
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
              class="px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[#ff4500] hover:border-[rgba(255,69,0,0.3)] hover:bg-[rgba(255,69,0,0.08)] transition-all cursor-pointer"
              onClick=${() => handleVote('up')}
            >▲ 추천</button>
            <button
              class="px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[#7193ff] hover:border-[rgba(113,147,255,0.3)] hover:bg-[rgba(113,147,255,0.08)] transition-all cursor-pointer"
              onClick=${() => handleVote('down')}
            >▼ 비추천</button>
          </div>
        </div>
      <//>

      <div class="mt-4">
        <${SectionCard} label="댓글">
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
              : html`<${EmptyState}>글을 찾지 못했습니다<//>`}
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
          ? html`<${EmptyState}>아직 게시글이 없습니다. 에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다.<//>`
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

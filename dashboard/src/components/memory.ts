import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { Markdown } from './common/markdown'
import { TextInput, TextArea } from './common/input'
import { stripStateBlocks } from '../keeper-message'
import { navigate, navigateToPost, route } from '../router'
import { PostDetail } from './memory-post-detail'
import { stripInlineMarkdown, navigateToAuthor } from '../lib/board-utils'
import {
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardExcludeAutomation,
  boardAuthorFilter,
  boardLoading,
  lastBoardRefreshAt,
  refreshBoard,
  SORT_MODES,
  detailPost,
  detailLoading,
  detailPostId,
  showNewPostForm,
  newPostTitle,
  newPostContent,
  newPostSubmitting,
  PAGE_SIZE,
  visibleLimit,
  automationVisibleLimit,
  systemVisibleLimit,
  deletingPostId,
  selectedPostIds,
  bulkDeleting,
  loadPostDetail,
  submitNewPost,
  togglePostSelection,
  bulkDeleteSelected,
  splitVisiblePosts,
  filterHint,
  isUpdated,
  boardPostKind,
  authorAvatar,
  kindLabel,
  kindBadgeColor,
  visibilityLabel,
  visibilityBadgeColor,
  votePost,
  deleteBoardPost,
} from './memory-state'
import type { BoardPost } from './memory-state'

function hasRichMarkdownPreview(text: string): boolean {
  return /(^|\n)(`{3,}|~{3,}|#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s+)/m.test(text)
}

// ── Render section (paginated group) ───────────────────────────────
function renderSection(
  title: string,
  posts: BoardPost[],
  visible: typeof visibleLimit,
) {
  if (posts.length === 0) return null
  return html`
    <${Card} title=${`${title} (${posts.length})`} class="mb-4">
      <div class="flex flex-col gap-2">
        ${posts.slice(0, visible.value).map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
      </div>
      ${posts.length > visible.value ? html`
        <div class="text-center py-4">
          <button type="button"
            class="px-4 py-2 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
            onClick=${() => { visible.value = visible.value + PAGE_SIZE }}
          >
            더 보기 (${posts.length - visible.value}개 남음)
          </button>
        </div>
      ` : null}
    <//>
  `
}

// ── New post form ──────────────────────────────────────────────────
function NewPostForm() {
  if (!showNewPostForm.value) {
    return html`
      <button type="button"
        class="w-full py-2.5 rounded-lg border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-4)] hover:text-[var(--text-body)] transition-colors bg-transparent"
        onClick=${() => { showNewPostForm.value = true }}
      >+ 새 글 작성</button>
    `
  }

  return html`
    <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-3">
      <${TextInput}
        name="board_post_title"
        ariaLabel="새 글 제목"
        autoComplete="off"
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
        <button type="button"
          class="px-3 py-1.5 rounded-lg text-[13px] border border-[var(--card-border)] bg-transparent text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]"
          onClick=${() => { showNewPostForm.value = false; newPostTitle.value = ''; newPostContent.value = '' }}
        >취소</button>
        <button type="button"
          class="px-4 py-1.5 rounded-lg text-[13px] font-medium border border-[rgba(71,184,255,0.4)] bg-[var(--accent-soft)] text-[var(--accent)] cursor-pointer hover:bg-[rgba(71,184,255,0.2)] disabled:opacity-50"
          disabled=${newPostSubmitting.value || !newPostTitle.value.trim() || !newPostContent.value.trim()}
          onClick=${() => { void submitNewPost() }}
        >${newPostSubmitting.value ? '등록 중...' : '등록'}</button>
      </div>
    </div>
  `
}

// ── Sort bar ───────────────────────────────────────────────────────
function SortBar() {
  const current = boardSortMode.value
  const grouped = splitVisiblePosts(boardPosts.value)
  const automationLabel = boardExcludeAutomation.value ? '자동화 제외' : '자동화 포함'
  const systemLabel = boardExcludeSystem.value ? '시스템 제외' : '시스템 포함'
  return html`
    <div class="flex flex-col gap-3 mb-4 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
      <div class="flex items-center gap-1.5 flex-wrap">
        ${SORT_MODES.map(mode => html`
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-[12px] font-medium transition-all duration-150 border cursor-pointer
              ${current === mode.id
                ? 'bg-[var(--ok-soft)] text-[var(--ok)] border-[var(--ok-30)]'
                : 'bg-transparent text-[var(--text-muted)] border-transparent hover:bg-[var(--white-8)] hover:text-[var(--text-body)]'
              }"
            onClick=${() => {
              boardSortMode.value = mode.id
              visibleLimit.value = PAGE_SIZE
              automationVisibleLimit.value = PAGE_SIZE
              systemVisibleLimit.value = PAGE_SIZE
              refreshBoard()
            }}
          >
            ${mode.label}
          </button>
        `)}
      </div>
      <div class="flex items-center gap-2 flex-wrap">
        <button type="button"
          class="px-2.5 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer
            ${boardExcludeAutomation.value
              ? 'bg-[var(--accent-12)] text-[var(--accent)] border-[var(--accent-18)]'
              : 'bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]'
            }"
          onClick=${() => {
            boardExcludeAutomation.value = !boardExcludeAutomation.value
            refreshBoard()
          }}
        >
          ${automationLabel} (${grouped.totalAutomation})
        </button>
        <button type="button"
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
          ${systemLabel} (${grouped.totalSystem})
        </button>
        <input
          type="text"
          placeholder="작성자"
          aria-label="작성자 필터"
          value=${boardAuthorFilter.value}
          class="px-2.5 py-1 rounded-lg text-[11px] font-medium border bg-transparent text-[var(--text)] border-[var(--border-slate-16)] placeholder:text-[var(--text-muted)] w-28 focus:outline-none focus:border-[var(--accent)]"
          onKeyDown=${(e: KeyboardEvent) => {
            if (e.key === 'Enter') {
              boardAuthorFilter.value = (e.target as HTMLInputElement).value.trim()
              refreshBoard()
            }
          }}
          onBlur=${(e: FocusEvent) => {
            const val = (e.target as HTMLInputElement).value.trim()
            if (val !== boardAuthorFilter.value) {
              boardAuthorFilter.value = val
              refreshBoard()
            }
          }}
        />
        <div class="ml-auto flex items-center gap-2">
          ${selectedPostIds.value.size > 0 ? html`
            <button type="button"
              class="px-3 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-30)] hover:bg-[rgba(239,68,68,0.2)] disabled:opacity-50 disabled:cursor-not-allowed"
              onClick=${bulkDeleteSelected}
              disabled=${bulkDeleting.value}
            >
              ${bulkDeleting.value ? '삭제 중...' : `선택 삭제 (${selectedPostIds.value.size})`}
            </button>
            <button type="button"
              class="px-2 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]"
              onClick=${() => { selectedPostIds.value = new Set() }}
            >선택 해제</button>
          ` : null}
          <button type="button"
            class="px-3 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] disabled:opacity-50 disabled:cursor-not-allowed"
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

// ── Memory summary stats (compact inline) ────────────────────────
function MemorySummary() {
  const grouped = splitVisiblePosts(boardPosts.value)
  const visibleCount = grouped.direct.length + grouped.automation.length + grouped.system.length
  return html`
    <div class="flex flex-wrap items-center gap-2 mb-4 px-3 py-2.5 rounded-xl border border-[var(--card-border)] bg-[var(--card)] text-[12px] text-[var(--text-muted)]">
      <span class="font-semibold text-[var(--text-strong)] tabular-nums text-[15px]">${visibleCount}</span>
      <span>개 표시 중</span>
      <span class="text-[var(--text-muted)]">·</span>
      <span>직접 작성 ${grouped.direct.length}</span>
      <span class="text-[var(--text-muted)]">·</span>
      <span>자동화 ${grouped.automation.length}</span>
      <span class="text-[var(--text-muted)]">·</span>
      <span>시스템 ${grouped.system.length}</span>
      ${lastBoardRefreshAt.value ? html`
        <span class="ml-auto text-[11px]">갱신 <${TimeAgo} timestamp=${lastBoardRefreshAt.value} /></span>
      ` : null}
    </div>
  `
}

// ── Post card (list item) ──────────────────────────────────────────
function PostCard({ post }: { post: BoardPost }) {
  const kind = boardPostKind(post)
  const isDeleting = deletingPostId.value === post.id
  const previewBody = stripStateBlocks(post.body)
  const richPreview = hasRichMarkdownPreview(previewBody)

  const handleVote = async (dir: 'up' | 'down', event: Event) => {
    event.stopPropagation()
    try {
      await votePost(post.id, dir)
      refreshBoard()
    } catch (err) {
      console.warn(`[board] vote failed (post=${post.id}, dir=${dir})`, err instanceof Error ? err.message : err)
      showToast('투표에 실패했습니다', 'error')
    }
  }

  const handleDelete = async (event: Event) => {
    event.stopPropagation()
    const confirmed = await requestConfirm({
      title: '게시글 삭제',
      message: `"${post.title}" 게시글을 삭제하시겠습니까?`,
      tone: 'danger'
    })
    if (!confirmed) return
    deletingPostId.value = post.id
    try {
      await deleteBoardPost(post.id)
      showToast('게시글을 삭제했습니다', 'success')
      refreshBoard()
    } catch (err) {
      console.warn('[board] post delete failed', err instanceof Error ? err.message : err)
      showToast('게시글 삭제에 실패했습니다', 'error')
    } finally {
      deletingPostId.value = null
    }
  }

  return html`
    <div
      class="board-post group flex gap-3 rounded-xl p-4 border border-[var(--card-border)] bg-[var(--card)] hover:bg-[var(--white-6)] hover:border-[var(--accent-20)] transition-all duration-200 cursor-pointer"
      onClick=${() => navigateToPost(post.id)}
    >
      <!-- Select checkbox -->
      <div class="flex items-start pt-1">
        <input type="checkbox"
          aria-label=${`게시글 선택: ${post.id}`}
          class="w-3.5 h-3.5 rounded cursor-pointer accent-[var(--accent)]"
          checked=${selectedPostIds.value.has(post.id)}
          onClick=${(e: Event) => togglePostSelection(post.id, e)}
        />
      </div>

      <!-- Vote column -->
      <div class="flex flex-col items-center gap-0.5 pt-0.5 min-w-[36px]">
        <button type="button"
          class="vote-btn upvote w-7 h-5 flex items-center justify-center rounded text-[11px] text-[var(--text-muted)] hover:text-[var(--warn-bright)] hover:bg-[var(--warn-10)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${(event: Event) => handleVote('up', event)}
        >▲</button>
        <span class="text-[13px] font-semibold tabular-nums text-[var(--text-strong)]">${post.votes ?? 0}</span>
        <button type="button"
          class="vote-btn downvote w-7 h-5 flex items-center justify-center rounded text-[11px] text-[var(--text-muted)] hover:text-[var(--accent)] hover:bg-[var(--accent-10)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${(event: Event) => handleVote('down', event)}
        >▼</button>
      </div>

      <!-- Post body -->
      <div class="flex-1 min-w-0">
        <!-- Title -->
        <div class="text-[15px] font-semibold text-[var(--text-strong)] leading-snug mb-1.5 group-hover:text-[var(--accent)] transition-colors">${stripInlineMarkdown(post.title)}</div>

        <!-- Content preview: rendered markdown, height-capped -->
        <div class="board-post-preview text-[13px] text-[var(--text-body)] leading-[1.55] mb-2.5 overflow-hidden relative ${richPreview ? 'max-h-[12rem]' : 'max-h-[4.8em]'}">
          <${Markdown} text=${previewBody} class="board-post-preview__content" />
          <div class="absolute bottom-0 left-0 right-0 ${richPreview ? 'h-10' : 'h-6'} bg-gradient-to-t from-[var(--card)] to-transparent pointer-events-none" />
        </div>

        <!-- Footer: author + meta + badges -->
        <div class="flex items-center gap-2 flex-wrap">
          <!-- Author line -->
          <span class="text-[12px] text-[var(--text-muted)]">${authorAvatar(post.author)}</span>
          <a
            class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] transition-colors cursor-pointer"
            onClick=${(e: Event) => navigateToAuthor(post.author, e)}
          >${post.author}</a>
          <span class="text-[11px] text-[var(--text-muted)] opacity-60"><${TimeAgo} timestamp=${post.created_at} /></span>
          ${isUpdated(post) ? html`<span class="text-[10px] text-[var(--text-muted)] opacity-50">(수정됨)</span>` : null}

          <!-- Separator -->
          <span class="text-[var(--text-muted)] opacity-30">|</span>

          <!-- Counts -->
          <span class="text-[11px] text-[var(--text-muted)]">댓글 ${post.comment_count}</span>

          <!-- Category badges -->
          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border ${kindBadgeColor(kind)}">${kindLabel(kind)}</span>
          ${post.hearth ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${post.hearth}</span>` : null}
          ${post.visibility && visibilityLabel(post.visibility) ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border ${visibilityBadgeColor(post.visibility)}">${visibilityLabel(post.visibility)}</span>` : null}

          <!-- Delete button -->
          <button type="button"
            class="ml-auto px-2 py-0.5 rounded text-[10px] font-semibold border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--bad-light)] hover:bg-[rgba(239,68,68,0.2)] transition-all cursor-pointer opacity-0 group-hover:opacity-100 disabled:opacity-50 disabled:cursor-not-allowed"
            onClick=${handleDelete}
            disabled=${isDeleting}
          >
            ${isDeleting ? '삭제 중...' : '삭제'}
          </button>
        </div>
      </div>
    </div>
  `
}

// ── Main Memory component (public API) ─────────────────────────────
export function Memory() {
  useEffect(() => () => { selectedPostIds.value = new Set() }, [])
  const grouped = splitVisiblePosts(boardPosts.value)
  const posts = [...grouped.direct, ...grouped.automation, ...grouped.system]
  const hint = filterHint(grouped)
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
            <button type="button"
              class="mb-4 px-3 py-1.5 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
              onClick=${() => navigate('workspace', { section: 'board' })}
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
      ${hint ? html`
        <div class="mb-4 px-3 py-2 rounded-xl border border-[var(--border-slate-16)] bg-[var(--white-3)] text-[12px] text-[var(--text-muted)]">
          ${hint}
        </div>
      ` : null}
      <div class="mb-4">
        <${NewPostForm} />
      </div>
      ${posts.length === 0 && boardLoading.value
        ? html`<${LoadingState}>메모리 피드 불러오는 중...<//>`
        : posts.length === 0
          ? html`<${EmptyState} message="아직 게시글이 없습니다. 에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다." compact />`
          : html`
              ${boardLoading.value ? html`<div class="mb-2 text-[11px] text-[var(--text-muted)] animate-pulse">업데이트 중...</div>` : null}
              ${renderSection('직접 작성 글', grouped.direct, visibleLimit)}
              ${renderSection('자동화 글', grouped.automation, automationVisibleLimit)}
              ${renderSection('시스템 글', grouped.system, systemVisibleLimit)}
            `}
    </div>
  `
}

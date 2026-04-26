import { html } from 'htm/preact'
import { useEffect, useRef, useCallback, useMemo, useState } from 'preact/hooks'
import { ActionButton } from './common/button'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { Checkbox } from './common/checkbox'
import { RichComposer } from './common/rich-composer'
import { RichContent } from './common/rich-content'
import { stripStateBlocks } from '../keeper-message'
import { navigate, navigateToPost, route } from '../router'
import { PostDetail } from './memory-post-detail'
import {
  boardActorAvatarKey,
  boardActorDisplayName,
  boardActorTitle,
  navigateToAuthor,
  stripInlineMarkdown,
} from '../lib/board-utils'
import { hasRichMarkdownSignals } from './common/rich-content-utils'
import {
  boardPosts,
  boardSortMode,
  boardHiddenCategories,
  boardAuthorFilter,
  boardLoading,
  boardLoadingMore,
  boardHasMore,
  lastBoardRefreshAt,
  refreshBoard,
  loadMoreBoardPosts,
  SORT_MODES,
  CONTENT_CATEGORIES,
  detailPost,
  detailLoading,
  detailPostId,
  showNewPostForm,
  newPostTitle,
  newPostContent,
  newPostSubmitting,
  PAGE_SIZE,
  categoryVisibleLimits,
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
  contentCategory,
  categoryLabel,
  categoryBadgeColor,
  authorAvatar,
  visibilityLabel,
  visibilityBadgeColor,
  votePost,
  deleteBoardPost,
} from './memory-state'
import type { BoardPost, ContentCategory } from './memory-state'

/**
 * Pure filter for board posts.
 *
 * Case-insensitive substring match on `post.title` and `post.body` so the
 * operator can locate a post by a keyword in the headline or anywhere in
 * the content. Title is checked first (cheapest, strongest signal), then
 * body. Existing server-side `boardAuthorFilter` handles the author axis,
 * so this client-side filter is intentionally scoped to textual content.
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated; BoardPost is treated as readonly.
 */
export function filterBoardPosts(
  posts: readonly BoardPost[],
  query: string,
): readonly BoardPost[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return posts
  return posts.filter(post => {
    if (post.title && post.title.toLowerCase().includes(needle)) return true
    if (post.body && post.body.toLowerCase().includes(needle)) return true
    return false
  })
}

// ── Scroll sentinel (IntersectionObserver auto-load) ──────────────
function ScrollSentinel({ onVisible }: { onVisible: () => void }) {
  const ref = useRef<HTMLDivElement>(null)
  const cb = useCallback(onVisible, [onVisible])
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const obs = new IntersectionObserver(
      (entries) => { if (entries[0]?.isIntersecting) cb() },
      { rootMargin: '200px' },
    )
    obs.observe(el)
    return () => obs.disconnect()
  }, [cb])
  return html`<div ref=${ref} class="h-1" />`
}

// ── Render section (paginated group by category) ──────────────────
/** Expand the visible slice for this category by PAGE_SIZE.
 *  If the category has run out of locally-loaded posts AND the server
 *  still has more, also trigger a server-side page fetch. */
function expandCategory(
  category: ContentCategory,
  limits: Record<string, number>,
  currentLimit: number,
  localPostCount: number,
) {
  const nextLimit = currentLimit + PAGE_SIZE
  categoryVisibleLimits.value = { ...limits, [category]: nextLimit }
  // Exhausted the locally-loaded slice for this category — ask the server
  // for more. loadMoreBoardPosts is a noop if already loading or has_more=false.
  if (nextLimit >= localPostCount && boardHasMore.value) {
    void loadMoreBoardPosts()
  }
}

function renderCategorySection(
  category: ContentCategory,
  posts: BoardPost[],
  total: number,
  hidden: number,
) {
  const meta = CONTENT_CATEGORIES.find(c => c.id === category)
  const label = meta ? `${meta.icon} ${meta.label}` : category
  const limits = categoryVisibleLimits.value
  const limit = limits[category] ?? PAGE_SIZE
  // "has more" considers both the locally-loaded posts and the server's
  // signal. Without boardHasMore, once the category's slice catches up to
  // the loaded window the button disappears and the next server page is
  // never requested — that was the #7118 regression.
  const hasMoreLocal = posts.length > limit
  const hasMoreRemote = boardHasMore.value
  const hasMore = hasMoreLocal || hasMoreRemote
  const loadingMore = boardLoadingMore.value
  const remainingLabel = hasMoreLocal
    ? `${posts.length - limit}개 남음`
    : '다음 페이지 불러오기'

  if (posts.length === 0 && hidden === 0) return null
  if (posts.length === 0 && hidden > 0) {
    return html`
      <div class="mb-3 px-3 py-2 rounded border border-dashed border-[var(--border-slate-16)] text-xs text-[var(--color-fg-muted)]">
        ${label} — ${hidden}건 숨김
      </div>
    `
  }

  return html`
    <${Card} title=${`${label} (${total})`} class="mb-4">
      <div class="flex flex-col gap-2">
        ${posts.slice(0, limit).map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
      </div>
      ${hasMore ? html`
        <${ScrollSentinel} onVisible=${() => {
          if (loadingMore) return
          expandCategory(category, limits, limit, posts.length)
        }} />
        <div class="text-center py-3">
          <button type="button"
            class="px-4 py-2 rounded text-xs font-medium text-[var(--color-fg-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--color-fg-primary)] transition-all cursor-pointer disabled:opacity-50"
            disabled=${loadingMore}
            onClick=${() => {
              expandCategory(category, limits, limit, posts.length)
            }}
          >
            ${loadingMore ? '불러오는 중...' : `더 보기 (${remainingLabel})`}
          </button>
        </div>
      ` : null}
    <//>
  `
}

function CategorySection({ group }: { group: { category: ContentCategory; posts: BoardPost[]; total: number; hidden: number } }) {
  return renderCategorySection(group.category, group.posts, group.total, group.hidden)
}

// ── New post form ──────────────────────────────────────────────────
function NewPostForm() {
  if (!showNewPostForm.value) {
    return html`
      <button type="button"
        class="w-full py-2.5 rounded border border-dashed border-[var(--color-border-default)] text-sm text-[var(--color-fg-muted)] cursor-pointer hover:bg-[var(--white-4)] hover:text-[var(--color-fg-primary)] transition-colors bg-transparent"
        onClick=${() => { showNewPostForm.value = true }}
      >+ 새 글 작성</button>
    `
  }

  return html`
    <div class="p-4 rounded border border-[var(--color-border-default)] bg-[var(--white-3)] grid gap-3">
      <${TextInput}
        name="board_post_title"
        ariaLabel="새 글 제목"
        autoComplete="off"
        placeholder="제목"
        value=${newPostTitle.value}
        onInput=${(e: Event) => { newPostTitle.value = (e.target as HTMLInputElement).value }}
      />
      <${RichComposer}
        value=${newPostContent.value}
        onValueChange=${(next: string) => { newPostContent.value = next }}
        rows=${8}
        placeholder="내용을 입력하세요. Markdown, 코드 스니펫, URL, 이미지 링크를 그대로 붙일 수 있습니다."
        helpText="예: ts 코드펜스, 일반 URL 링크 카드, 단독 이미지 URL 자동 인라인"
        previewLimit=${2}
      />
      <div class="flex gap-2 justify-end">
        <button type="button"
          class="px-3 py-1.5 rounded text-sm border border-[var(--color-border-default)] bg-transparent text-[var(--color-fg-muted)] cursor-pointer hover:bg-[var(--white-6)]"
          onClick=${() => { showNewPostForm.value = false; newPostTitle.value = ''; newPostContent.value = '' }}
        >취소</button>
        <button type="button"
          class="px-4 py-1.5 rounded text-sm font-medium border border-[rgba(71,184,255,0.4)] bg-[var(--accent-soft)] text-[var(--color-accent-fg)] cursor-pointer hover:bg-[var(--accent-20)] disabled:opacity-50"
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
  return html`
    <div class="flex flex-col gap-3 mb-4 p-3 rounded border border-[var(--color-border-default)] bg-[var(--card)]">
      <div class="flex items-center gap-1.5 flex-wrap">
        ${SORT_MODES.map(mode => html`
          <button type="button"
            class="px-3 py-1.5 rounded text-xs font-medium transition-all duration-150 border cursor-pointer
              ${current === mode.id
                ? 'bg-[var(--ok-soft)] text-[var(--color-status-ok)] border-[var(--ok-30)]'
                : 'bg-transparent text-[var(--color-fg-muted)] border-transparent hover:bg-[var(--white-8)] hover:text-[var(--color-fg-primary)]'
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
        ${grouped.groups.map(g => {
          const meta = CONTENT_CATEGORIES.find(c => c.id === g.category)
          const isHidden = boardHiddenCategories.value.has(g.category)
          return html`
            <button type="button"
              class="px-2.5 py-1 rounded text-2xs font-medium transition-all duration-150 border cursor-pointer
                ${isHidden
                  ? 'bg-[var(--accent-12)] text-[var(--color-accent-fg)] border-[var(--accent-18)] line-through opacity-60'
                  : 'bg-transparent text-[var(--color-fg-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]'
                }"
              onClick=${() => {
                const next = new Set(boardHiddenCategories.value)
                if (next.has(g.category)) next.delete(g.category)
                else next.add(g.category)
                boardHiddenCategories.value = next
              }}
            >
              ${meta?.icon ?? ''} ${meta?.label ?? g.category} (${g.total})
            </button>
          `
        })}
        <${TextInput}
          type="text"
          placeholder="작성자"
          ariaLabel="작성자 필터"
          value=${boardAuthorFilter.value}
          class="!bg-transparent !px-2.5 !py-1 !text-2xs !font-medium w-28"
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
            <${ActionButton}
              variant="danger"
              size="md"
              class="!px-3"
              onClick=${bulkDeleteSelected}
              disabled=${bulkDeleting.value}
              ariaBusy=${bulkDeleting.value}
              ariaLabel="선택한 게시글 일괄 삭제"
            >
              ${bulkDeleting.value ? '삭제 중...' : `선택 삭제 (${selectedPostIds.value.size})`}
            <//>
            <button type="button"
              class="px-2 py-1 rounded text-2xs font-medium transition-all duration-150 border cursor-pointer bg-transparent text-[var(--color-fg-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]"
              onClick=${() => { selectedPostIds.value = new Set() }}
            >선택 해제</button>
          ` : null}
          <button type="button"
            class="px-3 py-1 rounded text-2xs font-medium transition-all duration-150 border cursor-pointer bg-transparent text-[var(--color-fg-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--color-fg-primary)] disabled:opacity-50 disabled:cursor-not-allowed"
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
  const visibleCount = grouped.groups.reduce((sum, g) => sum + g.posts.length, 0)
  return html`
    <div class="flex flex-wrap items-center gap-2 mb-4 px-3 py-2.5 rounded border border-[var(--color-border-default)] bg-[var(--card)] text-xs text-[var(--color-fg-muted)]">
      <span class="font-semibold text-[var(--color-fg-secondary)] tabular-nums text-md">${visibleCount}</span>
      <span>개 표시 중</span>
      ${grouped.groups.map(g => {
        const meta = CONTENT_CATEGORIES.find(c => c.id === g.category)
        return html`
          <span class="text-[var(--color-fg-muted)]">·</span>
          <span>${meta?.icon ?? ''} ${g.posts.length}</span>
        `
      })}
      ${lastBoardRefreshAt.value ? html`
        <span class="ml-auto text-2xs">갱신 <${TimeAgo} timestamp=${lastBoardRefreshAt.value} /></span>
      ` : null}
    </div>
  `
}

// ── Post card (list item) ──────────────────────────────────────────
function PostCard({ post }: { post: BoardPost }) {
  const cat = contentCategory(post)
  const isDeleting = deletingPostId.value === post.id
  const previewBody = stripStateBlocks(post.body)
  const richPreview = hasRichMarkdownSignals(previewBody)
  const authorLabel = boardActorDisplayName(post.author, post.author_identity)
  const authorAvatarKey = boardActorAvatarKey(post.author, post.author_identity)
  const authorTitle = boardActorTitle(post.author, post.author_identity)

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
    <button
      type="button"
      class="board-post group w-full flex gap-3 rounded p-4 border border-[var(--color-border-default)] bg-[var(--card)] hover:bg-[var(--white-6)] hover:border-[var(--accent-20)] transition-all duration-200 cursor-pointer text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent"
      onClick=${() => navigateToPost(post.id)}
    >
      <!-- Select checkbox -->
      <div class="flex items-start pt-1">
        <${Checkbox}
          ariaLabel=${`게시글 선택: ${post.id}`}
          class="!w-3.5 !h-3.5"
          checked=${selectedPostIds.value.has(post.id)}
          onClick=${(e: Event) => togglePostSelection(post.id, e)}
        />
      </div>

      <!-- Vote column -->
      <div class="flex flex-col items-center gap-0.5 pt-0.5 min-w-9">
        <button type="button"
          class="vote-btn upvote w-7 h-5 flex items-center justify-center rounded text-2xs text-[var(--color-fg-muted)] hover:text-[var(--warn-bright)] hover:bg-[var(--warn-10)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${(event: Event) => handleVote('up', event)}
        >▲</button>
        <span class="text-sm font-semibold tabular-nums text-[var(--color-fg-secondary)]">${post.votes ?? 0}</span>
        <button type="button"
          class="vote-btn downvote w-7 h-5 flex items-center justify-center rounded text-2xs text-[var(--color-fg-muted)] hover:text-[var(--color-accent-fg)] hover:bg-[var(--accent-10)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${(event: Event) => handleVote('down', event)}
        >▼</button>
      </div>

      <!-- Post body -->
      <div class="flex-1 min-w-0">
        <!-- Title -->
        <div class="text-md font-semibold text-[var(--color-fg-secondary)] leading-snug mb-1.5 group-hover:text-[var(--color-accent-fg)] transition-colors">${stripInlineMarkdown(post.title)}</div>

        <!-- Content preview: rendered markdown, height-capped -->
        <div class="board-post-preview text-sm text-[var(--color-fg-primary)] leading-paragraph mb-2.5 overflow-hidden relative ${richPreview ? 'max-h-[12rem]' : 'max-h-[4.8em]'}">
          <${RichContent} text=${previewBody} class="board-post-preview__content" previewLimit=${1} />
          <div class="absolute bottom-0 left-0 right-0 ${richPreview ? 'h-10' : 'h-6'} bg-gradient-to-t from-[var(--card)] to-transparent pointer-events-none" />
        </div>

        <!-- Footer: author + meta + badges -->
        <div class="flex items-center gap-2 flex-wrap">
          <!-- Author line -->
          <span class="text-xs text-[var(--color-fg-muted)]">${authorAvatar(authorAvatarKey)}</span>
          <a
            class="text-xs text-[var(--color-fg-muted)] hover:text-[var(--color-accent-fg)] transition-colors cursor-pointer"
            title=${authorTitle}
            onClick=${(e: Event) => navigateToAuthor(post.author, e, post.author_identity)}
          >${authorLabel}</a>
          <span class="text-2xs text-[var(--color-fg-muted)] opacity-60"><${TimeAgo} timestamp=${post.created_at} /></span>
          ${isUpdated(post) ? html`<span class="text-3xs text-[var(--color-fg-muted)] opacity-50">(수정됨)</span>` : null}

          <!-- Separator -->
          <span class="text-[var(--color-fg-muted)] opacity-30">|</span>

          <!-- Counts -->
          <span class="text-2xs text-[var(--color-fg-muted)]">댓글 ${post.comment_count}</span>

          <!-- Category badges -->
          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-3xs font-medium border ${categoryBadgeColor(cat)}">${categoryLabel(cat)}</span>
          ${post.hearth ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-3xs font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${post.hearth}</span>` : null}
          ${post.visibility && visibilityLabel(post.visibility) ? html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-3xs font-medium border ${visibilityBadgeColor(post.visibility)}">${visibilityLabel(post.visibility)}</span>` : null}

          <!-- Delete button — reveal on row hover via opacity utilities -->
          <${ActionButton}
            variant="danger"
            size="sm"
            class="ml-auto !py-0.5 opacity-0 group-hover:opacity-100"
            onClick=${handleDelete}
            disabled=${isDeleting}
            ariaBusy=${isDeleting}
            ariaLabel=${`게시글 삭제: ${post.id}`}
          >
            ${isDeleting ? '삭제 중...' : '삭제'}
          <//>
        </div>
      </div>
    </button>
  `
}

// ── Main Memory component (public API) ─────────────────────────────
export function Memory() {
  useEffect(() => () => { selectedPostIds.value = new Set() }, [])
  const [contentQuery, setContentQuery] = useState('')
  const rawPosts = boardPosts.value
  const filteredPosts = useMemo(
    () => filterBoardPosts(rawPosts, contentQuery),
    [rawPosts, contentQuery],
  )
  const isFiltering = contentQuery.trim() !== ''
  const grouped = splitVisiblePosts(filteredPosts as BoardPost[])
  const posts = grouped.groups.flatMap(g => g.posts)
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
              class="mb-4 px-3 py-1.5 rounded text-xs font-medium text-[var(--color-fg-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--color-fg-primary)] transition-all cursor-pointer"
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
        <div class="mb-4 px-3 py-2 rounded border border-[var(--border-slate-16)] bg-[var(--white-3)] text-xs text-[var(--color-fg-muted)]">
          ${hint}
        </div>
      ` : null}
      <div class="mb-4">
        <${NewPostForm} />
      </div>
      <div class="mb-3 flex items-center gap-2">
        <${TextInput}
          type="search"
          value=${contentQuery}
          placeholder="제목/본문에서 검색"
          ariaLabel="게시글 본문 필터"
          onInput=${(e: Event) => setContentQuery((e.target as HTMLInputElement).value)}
          class="min-w-45 max-w-80 flex-1 !px-2 !py-1 !text-xs"
        />
      </div>
      ${isFiltering && posts.length === 0 && rawPosts.length > 0
        ? html`<div class="py-4 text-center text-xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${rawPosts.length} items)</div>`
        : posts.length === 0 && boardLoading.value
          ? html`<${LoadingState}>메모리 피드 불러오는 중...<//>`
          : posts.length === 0
            ? html`<${EmptyState} message="아직 게시글이 없습니다. 에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다." compact />`
            : html`
                ${boardLoading.value ? html`<div class="mb-2 text-2xs text-[var(--color-fg-muted)] animate-pulse">업데이트 중...</div>` : null}
                ${grouped.groups.map(g => html`
                  <${CategorySection} key=${g.category} group=${g} />
                `)}
              `}
    </div>
  `
}

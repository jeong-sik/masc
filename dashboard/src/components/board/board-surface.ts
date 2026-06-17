import { html } from 'htm/preact'
import { useEffect, useRef, useCallback, useMemo, useState } from 'preact/hooks'
import { Sparkles, Trophy } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { SectionCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { EmptyState, LoadingState } from '../state-surfaces'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { Checkbox } from '../common/checkbox'
import { RichContent } from '../common/rich-content'
import { CursorPagination } from '../common/pagination'
import { stripStateBlocks } from '../../keeper-message'
import { navigate, route } from '../../router'
import { votePost } from '../../api/board'
import { createPost } from '../../api'
import { deleteBoardPost, setBoardPostPinned } from '../../api/actions'
import { registerBoardHearthsRefresh } from '../../sse-store'
import { boardLatencyMetrics, type BoardLatencyMetric } from '../../board-metrics'
import { MessageWorkspaceTimeline } from './message-workspace-timeline'
import { BoardCurationPanel } from './board-curation-panel'
import { BoardKarmaPanel } from './board-karma-panel'
import { MentionInbox, MentionInboxPanel } from './mention-inbox'
import { PostDetail, CommentThread, CommentForm } from './post-detail'
import { ReactionBar } from './reaction-bar'
import { StateBlockMessages } from './state-block-messages'
import { ComposerV2 } from './composer-v2'
import type { ComposerV2Mode } from './composer-v2'
import {
  boardActorAvatarKey,
  boardActorDisplayName,
  boardActorTitle,
  contributorQualityBadgeClass,
  contributorQualityPercent,
  navigateToAuthor,
  stripInlineMarkdown,
} from '../../lib/board-utils'
import { ringFocusClasses } from '../common/ring'
import {
  boardPosts,
  boardHearthFilter,
  boardHearths,
  boardFlairs,
  boardLoading,
  boardLoadingMore,
  boardHasMore,
  lastBoardRefreshAt,
  refreshBoard,
  loadMoreBoardPosts,
  PAGE_SIZE,
  CONTENT_CATEGORIES,
  categoryVisibleLimits,
  detailPost,
  detailLoading,
  detailPostId,
  detailComments,
  deletingPostId,
  selectedPostIds,
  loadPostDetail,
  togglePostSelection,
  splitVisiblePosts,
  categoryLabel,
  refreshBoardHearths,
  refreshBoardFlairs,
  selectedBoardPostId,
  boardFilterMode,
  boardComposerMode,
  postHasStateBlock,
  getPostStateBlock,
} from './board-state'
import type { BoardPost, ContentCategory, ParsedStateBlock } from './board-state'

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
function filterBoardPosts(
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

// ── Scroll marker (IntersectionObserver auto-load) ──────────────
function ScrollMarker({ onVisible }: { onVisible: () => void }) {
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

function collapseCategory(
  category: ContentCategory,
  limits: Record<string, number>,
  currentLimit: number,
) {
  const nextLimit = Math.max(PAGE_SIZE, currentLimit - PAGE_SIZE)
  categoryVisibleLimits.value = { ...limits, [category]: nextLimit }
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
  const visibleCount = Math.min(limit, posts.length)
  const cursorLabel = hasMoreRemote && !hasMoreLocal
    ? `${visibleCount} / ${total}+`
    : `${visibleCount} / ${total}`

  if (posts.length === 0 && hidden === 0) return null
  if (posts.length === 0 && hidden > 0) {
    return html`
      <div class="v2-workspace-panel mb-3 px-3 py-2 rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] text-xs text-[var(--color-fg-muted)]">
        ${label} — ${hidden}건 숨김
      </div>
    `
  }

  return html`
    <${SectionCard} label=${`${label} (${total})`} class="mb-4 v2-workspace-panel" variant="standard">
      <div class="flex flex-col gap-2">
        ${posts.slice(0, limit).map(post => html`<${PostCard} key=${post.id} post=${post} />`)}
      </div>
      ${hasMore ? html`
        <${ScrollMarker} onVisible=${() => {
          if (loadingMore) return
          expandCategory(category, limits, limit, posts.length)
        }} />
        <div class="flex justify-center py-3">
          <${CursorPagination}
            cursor=${cursorLabel}
            cursorLabel="표시"
            hasPrevious=${limit > PAGE_SIZE}
            hasNext=${hasMore}
            previousLabel="줄이기"
            nextLabel=${loadingMore ? '불러오는 중...' : `더 보기 (${remainingLabel})`}
            ariaLabel=${`${categoryLabel(category)} 게시글 페이지`}
            disabled=${loadingMore}
            testId=${`board-category-pagination-${category}`}
            onPrevious=${() => {
              collapseCategory(category, limits, limit)
            }}
            onNext=${() => {
              expandCategory(category, limits, limit, posts.length)
            }}
          />
        </div>
      ` : null}
    <//>
  `
}

function CategorySection({ group }: { group: { category: ContentCategory; posts: BoardPost[]; total: number; hidden: number } }) {
  return renderCategorySection(group.category, group.posts, group.total, group.hidden)
}

// ── Board summary stats (compact inline) ─────────────────────────
function renderLatencyChip(label: string, metric: BoardLatencyMetric) {
  if (metric.last_latency_ms === null) return null
  const failed = metric.last_ok === false
  return html`
    <span
      class=${`text-2xs tabular-nums px-1.5 py-0.5 rounded-[var(--r-0)] border ${
        failed
          ? 'text-[var(--color-status-err)] border-[var(--bad-30)] bg-[var(--bad-10)]'
          : 'text-[var(--color-fg-muted)] border-[var(--color-border-divider)] bg-[var(--color-bg-hover)]'
      }`}
      title=${failed && metric.last_error ? metric.last_error : `${label} latency`}
      aria-label=${failed ? `${label} 지연 ${metric.last_latency_ms}밀리초 실패` : `${label} 지연 ${metric.last_latency_ms}밀리초`}
    >
      ${label} ${metric.last_latency_ms}ms${failed ? ' 실패' : ''}
    </span>
  `
}

function BoardSummary() {
  const grouped = splitVisiblePosts(boardPosts.value)
  const visibleCount = grouped.groups.reduce((sum, g) => sum + g.posts.length, 0)
  const metrics = boardLatencyMetrics.value
  return html`
    <div class="v2-workspace-panel flex flex-wrap items-center gap-2 mb-4 px-3 py-2.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-xs text-[var(--color-fg-muted)]">
      <span class="font-semibold text-[var(--color-fg-secondary)] tabular-nums text-md">${visibleCount}</span>
      <span>개 표시 중</span>
      ${grouped.groups.map(g => {
        const meta = CONTENT_CATEGORIES.find(c => c.id === g.category)
        return html`
          <span class="text-[var(--color-fg-muted)]" aria-hidden="true">·</span>
          <span>${meta?.icon ?? ''} ${g.posts.length}</span>
        `
      })}
      ${renderLatencyChip('목록', metrics.list)}
      ${renderLatencyChip('리액션', metrics.reaction_toggle)}
      ${lastBoardRefreshAt.value ? html`
        <span class="ml-auto text-2xs">갱신 <${TimeAgo} timestamp=${lastBoardRefreshAt.value} /></span>
      ` : null}
      <${ActionButton}
        variant="ghost"
        size="sm"
        class="v2-workspace-action ${lastBoardRefreshAt.value ? '' : 'ml-auto'} !px-2"
        onClick=${() => navigate('workspace', { section: 'board', focus: 'curation' })}
        ariaLabel="보드 큐레이션 열기"
      >
        <span class="inline-flex items-center gap-1">
          <${Sparkles} size=${12} aria-hidden="true" />
          큐레이션
        </span>
      <//>
      <${ActionButton}
        variant="ghost"
        size="sm"
        class="v2-workspace-action !px-2"
        onClick=${() => navigate('workspace', { section: 'board', focus: 'karma' })}
        ariaLabel="보드 카르마 열기"
      >
        <span class="inline-flex items-center gap-1">
          <${Trophy} size=${12} aria-hidden="true" />
          Karma
        </span>
      <//>
    </div>
  `
}

// ── Author sigil (v2) ──────────────────────────────────────────────
function BdAuthor({ name, size = 24 }: { name: string; size?: number }) {
  const label = name.slice(0, 2).toUpperCase()
  const isOperator = name.toLowerCase() === 'operator' || name.toLowerCase() === 'dashboard'
  return html`<span class=${`bd-sigil ${isOperator ? 'op' : ''}`} style=${{ width: size, height: size }}>${label}</span>`
}

// ── State block chip (v2) ──────────────────────────────────────────
function BdStateBlock({ block }: { block: ParsedStateBlock }) {
  return html`
    <div class="bd-stateblock" data-testid="bd-stateblock">
      ${block.from ? html`<span class="sk">상태 전이</span><span class="sv">${block.from} → <span class="hl">${block.to}</span></span>` : null}
      ${!block.from && block.to ? html`<span class="sk">다음 상태</span><span class="sv"><span class="hl">${block.to}</span></span>` : null}
      ${block.ctx ? html`<span class="sk">컨텍스트</span><span class="sv">${block.ctx}</span>` : null}
      ${block.action ? html`<span class="sk">조치</span><span class="sv">${block.action}</span>` : null}
    </div>
  `
}

// ── Post card (v2 list item) ───────────────────────────────────────
function PostCard({ post }: { post: BoardPost }) {
  const isDeleting = deletingPostId.value === post.id
  const previewBody = stripStateBlocks(post.body)
  const authorLabel = boardActorDisplayName(post.author, post.author_identity)
  const authorAvatarKey = boardActorAvatarKey(post.author, post.author_identity)
  const authorTitle = boardActorTitle(post.author, post.author_identity)
  const upvoteActive = post.current_vote === 'up'
  const downvoteActive = post.current_vote === 'down'
  const voteScoreLabel = post.vote_blind ? '투표 후 공개' : String(post.votes ?? 0)
  const voteScoreAria = post.vote_blind ? '점수 투표 후 공개' : `점수 ${post.votes ?? 0}`
  const stateBlock = getPostStateBlock(post)
  const hasState = stateBlock !== null
  const isMod = post.moderation_status && post.moderation_status !== 'none' && post.moderation_status !== 'approved'
  const qualityPercent = contributorQualityPercent(post.contributor_quality)
  const qualityTitle = qualityPercent === null
    ? undefined
    : `기여자 품질 ${qualityPercent}점`
  const selected = selectedBoardPostId.value === post.id

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

  const handlePin = async (event: Event) => {
    event.stopPropagation()
    const next = !post.pinned
    try {
      await setBoardPostPinned(post.id, next)
      showToast(next ? '게시글을 고정했습니다' : '고정을 해제했습니다', 'success')
      refreshBoard()
    } catch (err) {
      console.warn(`[board] pin toggle failed (post=${post.id})`, err instanceof Error ? err.message : err)
      showToast('고정 변경에 실패했습니다', 'error')
    }
  }

  const openPost = () => {
    selectedBoardPostId.value = post.id
    void loadPostDetail(post.id)
  }
  const handlePostKeyDown = (event: KeyboardEvent) => {
    if (event.key !== 'Enter' && event.key !== ' ') return
    event.preventDefault()
    openPost()
  }

  return html`
    <article
      role="button"
      tabIndex=${0}
      aria-label=${`게시글 열기: ${stripInlineMarkdown(post.title)}`}
      class=${`bd-post group ${selected ? 'sel' : ''} ${ringFocusClasses()}`}
      data-testid=${`bd-post-${post.id}`}
      onClick=${openPost}
      onKeyDown=${handlePostKeyDown}
    >
      <div class="bd-post-h">
        <${BdAuthor} name=${authorAvatarKey} />
        <a
          class="who"
          href=${`#monitoring/agents/${encodeURIComponent(post.author_identity?.raw ?? post.author)}`}
          title=${authorTitle}
          onClick=${(e: Event) => {
            e.stopPropagation()
            navigateToAuthor(post.author, e, post.author_identity)
          }}
        >${authorLabel}</a>
        ${post.pinned ? html`<span class="bd-badge pin" title="고정된 게시글">고정</span>` : null}
        ${hasState ? html`<span class="bd-badge state">상태 블록</span>` : null}
        ${isMod ? html`<span class="bd-badge mod">모더레이션 대기</span>` : null}
        ${post.flair ? html`<span class="bd-badge">flair:${post.flair}</span>` : null}
        ${qualityPercent !== null ? html`<span class="bd-badge ${contributorQualityBadgeClass(post.contributor_quality)}" aria-label=${qualityTitle} title=${qualityTitle}>품질 ${qualityPercent}</span>` : null}
        ${boardHearthFilter.value === '' && post.hearth ? html`<span class="bd-badge">${post.hearth}</span>` : null}
        <span class="ts"><${TimeAgo} timestamp=${post.created_at} /></span>
        <${Checkbox}
          ariaLabel=${`게시글 선택: ${post.id}`}
          class="!w-3.5 !h-3.5 ml-1"
          checked=${selectedPostIds.value.has(post.id)}
          onClick=${(e: Event) => togglePostSelection(post.id, e)}
        />
      </div>
      <div class="bd-post-title">${stripInlineMarkdown(post.title)}</div>
      ${stateBlock ? html`<${BdStateBlock} block=${stateBlock} />` : null}
      <div class="bd-post-body">
        <${RichContent} text=${previewBody} previewLimit=${1} />
      </div>
      <div class="bd-post-foot">
        <div onClick=${(event: Event) => event.stopPropagation()} onKeyDown=${(event: KeyboardEvent) => event.stopPropagation()}>
          <${ReactionBar}
            targetType="post"
            targetId=${post.id}
            compact
            initialSummaries=${post.reactions ?? []}
          />
        </div>
        <span class="karma" aria-label=${voteScoreAria} title=${voteScoreLabel}>karma <b>${voteScoreLabel}</b></span>
        <button type="button"
          aria-label="추천"
          aria-pressed=${upvoteActive ? 'true' : 'false'}
          disabled=${upvoteActive}
          class="bd-react ${upvoteActive ? 'mine' : ''}"
          onClick=${(event: Event) => handleVote('up', event)}
        >▲</button>
        <button type="button"
          aria-label="비추천"
          aria-pressed=${downvoteActive ? 'true' : 'false'}
          disabled=${downvoteActive}
          class="bd-react ${downvoteActive ? 'mine' : ''}"
          onClick=${(event: Event) => handleVote('down', event)}
        >▼</button>
        <span class="replies">답글 ${post.comment_count}</span>
        <span class="ml-auto hidden group-hover:inline-flex items-center gap-1">
          <${ActionButton}
            variant="ghost"
            size="sm"
            class="v2-workspace-action !py-0.5"
            onClick=${handlePin}
            pressed=${post.pinned ?? false}
            ariaLabel=${post.pinned ? `고정 해제: ${post.id}` : `고정: ${post.id}`}
          >${post.pinned ? '고정 해제' : '고정'}<//>
          <${ActionButton}
            variant="danger"
            size="sm"
            class="v2-workspace-action !py-0.5"
            onClick=${handleDelete}
            disabled=${isDeleting}
            ariaBusy=${isDeleting}
            ariaLabel=${`게시글 삭제: ${post.id}`}
          >${isDeleting ? '삭제 중...' : '삭제'}<//>
        </span>
      </div>
    </article>
  `
}

// ── v2 board chrome ────────────────────────────────────────────────
const SUB_BOARD_GLYPHS: Record<string, string> = {
  all: '＃',
  ops: '⚙',
  review: '⚖',
  notice: '▣',
  default: '＃',
}

function BdRail({ activeSub, onSub, onMentions }: {
  activeSub: string
  onSub: (sub: string) => void
  onMentions: () => void
}) {
  const hearths = boardHearths.value
  const allCount = boardPosts.value.length
  const modCount = boardPosts.value.filter(p => p.moderation_status && p.moderation_status !== 'none' && p.moderation_status !== 'approved').length

  return html`
    <nav class="bd-rail" aria-label="서브보드">
      <h4>서브보드</h4>
      <button
        type="button"
        class=${`bd-sub ${activeSub === '' ? 'on' : ''}`}
        onClick=${() => onSub('')}
        data-testid="bd-sub-all"
      >
        <span class="glyph">${SUB_BOARD_GLYPHS.all}</span>
        <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>전체</span>
        <span class="n">${allCount}</span>
      </button>
      ${hearths.map(hearth => html`
        <button
          key=${hearth.name}
          type="button"
          class=${`bd-sub ${activeSub === hearth.name ? 'on' : ''}`}
          onClick=${() => onSub(hearth.name)}
          data-testid=${`bd-sub-${hearth.name}`}
        >
          <span class="glyph">${SUB_BOARD_GLYPHS[hearth.name] ?? SUB_BOARD_GLYPHS.default}</span>
          <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>${hearth.name}</span>
          <span class="n">${hearth.count}</span>
        </button>
      `)}
      <div class="div"></div>
      <h4>큐</h4>
      <button type="button" class="bd-sub" onClick=${() => { boardFilterMode.value = 'mod'; onMentions() }} data-testid="bd-queue-mod">
        <span class="glyph">⚑</span>
        모더레이션
        <span class="n">${modCount}</span>
      </button>
      <button type="button" class="bd-sub" onClick=${onMentions} data-testid="bd-queue-mentions">
        <span class="glyph">＠</span>
        멘션 인박스
        <span class="n">${boardPosts.value.length}</span>
      </button>
    </nav>
  `
}

function BdFeedHead({ activeFilter, onFilter, count }: {
  activeFilter: 'all' | 'state' | 'mod'
  onFilter: (filter: 'all' | 'state' | 'mod') => void
  count: number
}) {
  const activeHearth = boardHearthFilter.value
  const title = activeHearth === '' ? '전체 피드' : `#${activeHearth}`
  const filters: Array<{ key: 'all' | 'state' | 'mod'; label: string }> = [
    { key: 'all', label: '전체' },
    { key: 'state', label: '상태 블록' },
    { key: 'mod', label: '모더레이션' },
  ]

  return html`
    <div class="bd-feed-head">
      <h2>${title}</h2>
      <span class="ns">${count}개 포스트</span>
      <span class="spacer"></span>
      ${filters.map(f => html`
        <button
          key=${f.key}
          type="button"
          class=${`bd-filter ${activeFilter === f.key ? 'on' : ''}`}
          onClick=${() => onFilter(f.key)}
          data-testid=${`bd-filter-${f.key}`}
        >${f.label}</button>
      `)}
    </div>
  `
}

function BdThreadDetail({ post, onClose }: { post: BoardPost; onClose: () => void }) {
  useEffect(() => {
    if (detailPostId.value !== post.id) {
      void loadPostDetail(post.id)
    }
  }, [post.id])

  const authorLabel = boardActorDisplayName(post.author, post.author_identity)
  const authorAvatarKey = boardActorAvatarKey(post.author, post.author_identity)

  return html`
    <aside class="bd-detail" data-testid="bd-thread-detail">
      <div class="bd-detail-h">
        <h3>스레드</h3>
        <button type="button" class="bd-detail-x" onClick=${onClose} aria-label="닫기">✕</button>
      </div>
      <div class="bd-detail-scroll">
        <div class="bd-th">
          <${BdAuthor} name=${authorAvatarKey} size=${26} />
          <div>
            <div class="bd-th-hd"><span class="who">${authorLabel}</span><span class="ts"><${TimeAgo} timestamp=${post.created_at} /></span></div>
            <div class="bd-th-body">
              <div class="text-sm font-semibold mb-1">${stripInlineMarkdown(post.title)}</div>
              <${RichContent} text=${stripStateBlocks(post.body)} previewLimit=${4} />
            </div>
          </div>
        </div>
        ${detailLoading.value
          ? html`<${LoadingState} title="댓글 불러오는 중…" />`
          : html`<${CommentThread} comments=${detailComments.value} postId=${post.id} />`}
        <${CommentForm} postId=${post.id} />
      </div>
    </aside>
  `
}

function BdDetail({ post, onClose }: { post: BoardPost | null; onClose: () => void }) {
  if (post) return html`<${BdThreadDetail} post=${post} onClose=${onClose} />`
  return html`
    <aside class="bd-detail" data-testid="bd-mention-detail">
      <div class="bd-detail-h"><h3>멘션 인박스</h3></div>
      <div class="bd-detail-scroll">
        <${MentionInboxPanel} />
      </div>
    </aside>
  `
}

function BdComposer() {
  const mode = boardComposerMode.value
  const [localTitle, setLocalTitle] = useState('')
  const [localBody, setLocalBody] = useState('')
  const [localHearth, setLocalHearth] = useState(boardHearthFilter.value)
  const [localFlair, setLocalFlair] = useState('')
  const [submitting, setSubmitting] = useState(false)

  useEffect(() => {
    if (boardHearthFilter.value !== localHearth) {
      setLocalHearth(boardHearthFilter.value)
    }
  }, [boardHearthFilter.value])

  const tabs: Array<{ key: 'post' | 'mention' | 'state'; label: string }> = [
    { key: 'post', label: '게시' },
    { key: 'mention', label: '멘션' },
    { key: 'state', label: '상태 블록' },
  ]

  const placeholder = mode === 'post'
    ? `${boardHearthFilter.value ? `#${boardHearthFilter.value}` : '보드'}에 게시…`
    : mode === 'mention'
      ? '@keeper 를 멘션해 직접 지시…'
      : '상태 블록 발행 — 상태 키:값 형식'

  const composerMode: ComposerV2Mode = mode === 'post' ? 'broadcast' : mode === 'mention' ? 'dm' : 'state-block'

  async function submitPost(event?: Event): Promise<void> {
    event?.stopPropagation()
    const title = localTitle.trim()
    const body = localBody.trim()
    if (!title || !body) return
    setSubmitting(true)
    try {
      const contentWithFlair = localFlair
        ? `[flair:${localFlair}]\n${body.replace(/^\[flair:[a-z]+\]\s*/i, '')}`
        : body
      await createPost(title, contentWithFlair, 'dashboard-user', { hearth: localHearth || undefined })
      setLocalTitle('')
      setLocalBody('')
      setLocalFlair('')
      showToast('글을 등록했습니다', 'success')
      refreshBoard()
    } catch (err) {
      console.warn('[board] post submit failed', err instanceof Error ? err.message : err)
      showToast('글 등록에 실패했습니다', 'error')
    } finally {
      setSubmitting(false)
    }
  }

  return html`
    <div class="bd-composer" data-testid="bd-composer">
      <div class="bd-comp-tabs" role="tablist" aria-label="Composer mode">
        ${tabs.map(tab => html`
          <button
            key=${tab.key}
            type="button"
            role="tab"
            aria-selected=${mode === tab.key ? 'true' : 'false'}
            class=${`bd-comp-tab ${mode === tab.key ? 'on' : ''}`}
            onClick=${() => { boardComposerMode.value = tab.key }}
            data-testid=${`bd-comp-tab-${tab.key}`}
          >${tab.label}</button>
        `)}
      </div>
      ${mode === 'post' ? html`
        <div class="bd-comp-box grid gap-2">
          <input
            type="text"
            class="bg-transparent border-0 outline-0 text-[var(--text-bright)] text-sm placeholder:text-[var(--text-dim)]"
            placeholder="제목"
            value=${localTitle}
            onInput=${(e: Event) => setLocalTitle((e.target as HTMLInputElement).value)}
            data-testid="bd-composer-title"
          />
          <textarea
            rows=${2}
            class="bg-transparent border-0 outline-0 text-[var(--text-bright)] text-sm placeholder:text-[var(--text-dim)] resize-none"
            placeholder=${placeholder}
            value=${localBody}
            onInput=${(e: Event) => setLocalBody((e.target as HTMLTextAreaElement).value)}
            data-testid="bd-composer-body"
          />
          <div class="flex gap-2">
            <${Select}
              value=${localHearth}
              options=${[{ value: '', label: 'No category' }, ...boardHearths.value.map(h => ({ value: h.name, label: h.name }))]}
              ariaLabel="게시 category"
              onInput=${(value: string) => setLocalHearth(value)}
            />
            <${Select}
              value=${localFlair}
              options=${[{ value: '', label: 'No flair' }, ...boardFlairs.value.map(f => ({ value: f.name, label: `${f.emoji ? `${f.emoji} ` : ''}${f.label}` }))]}
              ariaLabel="게시 flair"
              onInput=${(value: string) => setLocalFlair(value)}
            />
            <button
              type="button"
              class="send ml-auto"
              disabled=${!localTitle.trim() || !localBody.trim() || submitting}
              onClick=${(e: Event) => { void submitPost(e) }}
              data-testid="bd-composer-send"
            >${submitting ? '등록 중...' : '게시 ↑'}</button>
          </div>
        </div>
      ` : html`
        <div class="bd-comp-box">
          <${ComposerV2}
            workspaceId=${localHearth || 'default'}
            mode=${composerMode}
            showModeSelector=${false}
            modeLabels=${{ broadcast: '게시', dm: '멘션', 'state-block': '상태 블록' }}
          />
        </div>
      `}
    </div>
  `
}

function BdFeed({ posts }: { posts: BoardPost[] }) {
  const [contentQuery, setContentQuery] = useState('')
  const filteredPosts = useMemo(
    () => filterBoardPosts(posts, contentQuery),
    [posts, contentQuery],
  )
  const isFiltering = contentQuery.trim() !== ''
  const visibleGroups = splitVisiblePosts(filteredPosts)

  const modeFilteredGroups = visibleGroups.groups.map(g => ({
    ...g,
    posts: g.posts.filter(post => {
      if (boardFilterMode.value === 'state') return postHasStateBlock(post)
      if (boardFilterMode.value === 'mod') return post.moderation_status && post.moderation_status !== 'none' && post.moderation_status !== 'approved'
      return true
    }),
  }))
  const filteredByMode = modeFilteredGroups.flatMap(g => g.posts)

  return html`
    <section class="bd-feed">
      <${BdFeedHead}
        activeFilter=${boardFilterMode.value}
        onFilter=${(filter: 'all' | 'state' | 'mod') => { boardFilterMode.value = filter }}
        count=${filteredByMode.length}
      />
      <div class="bd-list">
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
        ${isFiltering && filteredByMode.length === 0 && posts.length > 0
          ? html`<div class="bd-empty">필터 결과 없음 (${posts.length} items)</div>`
          : filteredByMode.length === 0 && boardLoading.value
            ? html`<${LoadingState} title="게시판 불러오는 중…" />`
            : filteredByMode.length === 0
              ? html`<${EmptyState} title="아직 게시글이 없습니다" hint="에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다." compact />`
              : modeFilteredGroups.map(g =>
                  g.posts.length > 0
                    ? html`<${CategorySection} key=${g.category} group=${{ category: g.category, posts: g.posts, total: g.total, hidden: g.hidden }} />`
                    : null,
                )}
      </div>
      <${BdComposer} />
    </section>
  `
}

// ── Main Board component (public API) ──────────────────────────────
export function BoardSurface() {
  useEffect(() => () => { selectedPostIds.value = new Set() }, [])
  useEffect(() => registerBoardHearthsRefresh(() => {
    void refreshBoardHearths()
  }), [])
  useEffect(() => {
    if (boardHearths.value.length === 0) void refreshBoardHearths()
  }, [])
  useEffect(() => {
    if (boardFlairs.value.length === 0) void refreshBoardFlairs()
  }, [])
  const grouped = splitVisiblePosts(boardPosts.value)
  const posts = grouped.groups.flatMap(g => g.posts)
  const focus = route.value.params.focus ?? null
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
          <div class="v2-workspace-surface">
            <${BoardSummary} />
            <${PostDetail} post=${post} />
          </div>
        `
      : html`
          <div class="v2-workspace-surface">
            <${BoardSummary} />
            <button type="button"
              class="v2-workspace-action mb-4 px-3 py-1.5 rounded-[var(--r-1)] text-xs font-medium text-[var(--color-fg-muted)] bg-transparent border border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] transition-colors cursor-pointer"
              onClick=${() => navigate('workspace', { section: 'board' })}
            >← 게시판으로 돌아가기</button>
            ${detailLoading.value
              ? html`<${LoadingState} title="글 불러오는 중…" />`
              : html`<${EmptyState} title="글을 찾지 못했습니다" compact />`}
          </div>
        `
  }

  if (focus === 'mention-inbox') {
    return html`
      <div class="v2-workspace-surface">
        <${BoardSummary} />
        <${MentionInbox} />
      </div>
    `
  }

  if (focus === 'messages-workspace') {
    return html`
      <div class="v2-workspace-surface">
        <${BoardSummary} />
        <${MessageWorkspaceTimeline} />
      </div>
    `
  }

  if (focus === 'state-block') {
    return html`
      <div class="v2-workspace-surface">
        <${BoardSummary} />
        <${StateBlockMessages} />
      </div>
    `
  }

  if (focus === 'curation') {
    return html`
      <div class="v2-workspace-surface">
        <${BoardSummary} />
        <${BoardCurationPanel} />
      </div>
    `
  }

  if (focus === 'karma') {
    return html`
      <div class="v2-workspace-surface">
        <${BoardSummary} />
        <${BoardKarmaPanel} />
      </div>
    `
  }

  const activeSub = boardHearthFilter.value
  const selectedPost = selectedBoardPostId.value
    ? posts.find(p => p.id === selectedBoardPostId.value) ?? null
    : null

  return html`
    <div class="v2-board-surface">
      <div class=${`bd-body ${selectedPost ? '' : 'no-detail'}`}>
        <${BdRail}
          activeSub=${activeSub}
          onSub=${(sub: string) => {
            boardHearthFilter.value = sub
            selectedBoardPostId.value = null
            refreshBoard()
          }}
          onMentions=${() => { selectedBoardPostId.value = null }}
        />
        <${BdFeed} posts=${boardPosts.value} />
        ${selectedPost ? html`<${BdDetail} post=${selectedPost} onClose=${() => { selectedBoardPostId.value = null }} />` : null}
      </div>
    </div>
  `
}

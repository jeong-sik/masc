import { html } from 'htm/preact'
import { useEffect, useRef, useCallback, useMemo, useState } from 'preact/hooks'
import { AtSign, Braces, Mic, Paperclip, Sparkles, Square, Trophy, X } from 'lucide-preact'
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
import { route } from '../../router'
import { keepers as dashboardKeepers, messages, refreshExecution } from '../../store'
import { votePost } from '../../api/board'
import { createPost, currentDashboardActor, sendBroadcast } from '../../api'
import { deleteBoardPost, setBoardPostPinned } from '../../api/actions'
import { dispatchOperatorAction, operatorActionBusy } from '../../operator-store'
import { registerBoardHearthsRefresh } from '../../sse-store'
import { boardLatencyMetrics, type BoardLatencyMetric } from '../../board-metrics'
import { MessageWorkspaceTimeline } from './message-workspace-timeline'
import { BoardCurationPanel } from './board-curation-panel'
import { BoardKarmaPanel } from './board-karma-panel'
import { extractMentionTargets, MentionInbox, MentionInboxPanel } from './mention-inbox'
import { PostDetail, CommentThread, CommentForm } from './post-detail'
import { FusionBoardEvidence } from './fusion-evidence'
import { ReactionBar } from './reaction-bar'
import { PostShareActions } from './post-share-actions'
import { StateBlockMessages } from './state-block-messages'
import {
  ComposerV2,
  createComposerVoiceDraft,
  formatClock,
  formatFileSize,
  serializeComposerBody,
} from './composer-v2'
import type { ComposerAttachmentDraft, ComposerV2Mode, ComposerVoiceDraft } from './composer-v2'
import { ensureStateBlockDraft, stateBlockKeys } from '../ops/ops-state'
import { navigateBoard } from './board-route'
import {
  boardActorDisplayName,
  boardActorSigilLabel,
  boardActorTitle,
  boardClaimEvidenceBadgeClass,
  boardClaimEvidenceLabel,
  boardClaimEvidenceTitle,
  contributorQualityBadgeClass,
  contributorQualityPercent,
  navigateToAuthor,
  stripInlineMarkdown,
  dedupeLeadingHeading,
} from '../../lib/board-utils'
import {
  firstMentionNameFromMessage,
  keeperNameFromTarget,
  mentionQueryFromMessage,
  replaceTrailingMentionDraft,
} from '../../lib/mention-utils'
import { useOperatorMentionContext } from '../common/use-operator-mention-context'
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
  boardSortMode,
  boardComposerMode,
  SORT_MODES,
  postHasStateBlock,
  getPostStateBlock,
} from './board-state'
import type { BoardPost, BoardSortMode, ContentCategory, ParsedStateBlock } from './board-state'

export const BOARD_DETAIL_WIDTH_STORAGE_KEY = 'dashboard:board-detail-width'
export const BOARD_DETAIL_WIDTH_DEFAULT = 360
export const BOARD_DETAIL_WIDTH_MIN = 290
// Raised 520 → 760: threads carry root-cause analyses with code blocks that
// read poorly at 520px. The feed column is minmax(0, 1fr) so the user drives
// the trade-off via the resize handle; the cap just lets it go wider.
export const BOARD_DETAIL_WIDTH_MAX = 760

export function normalizeBoardDetailWidth(value: unknown): number {
  const numeric = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(numeric)) return BOARD_DETAIL_WIDTH_DEFAULT
  return Math.min(BOARD_DETAIL_WIDTH_MAX, Math.max(BOARD_DETAIL_WIDTH_MIN, Math.round(numeric)))
}

function readStoredBoardDetailWidth(): number {
  if (typeof window === 'undefined' || window.localStorage === undefined) {
    return BOARD_DETAIL_WIDTH_DEFAULT
  }
  try {
    const raw = window.localStorage.getItem(BOARD_DETAIL_WIDTH_STORAGE_KEY)
    if (!raw) return BOARD_DETAIL_WIDTH_DEFAULT
    try {
      return normalizeBoardDetailWidth(JSON.parse(raw))
    } catch {
      return normalizeBoardDetailWidth(raw)
    }
  } catch {
    return BOARD_DETAIL_WIDTH_DEFAULT
  }
}

function writeStoredBoardDetailWidth(width: number): void {
  if (typeof window === 'undefined' || window.localStorage === undefined) return
  try {
    window.localStorage.setItem(BOARD_DETAIL_WIDTH_STORAGE_KEY, JSON.stringify(width))
  } catch {
    // localStorage can be unavailable; keep the in-memory rail width.
  }
}

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
    <${SectionCard} label=${`${label} (${total})`} class="mb-4 v2-workspace-panel ss-card" variant="standard">
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
    <div class="bd-summary v2-workspace-panel ss-card mx-6 flex flex-wrap items-center gap-2 mb-4 px-3 py-2.5 text-xs text-text-secondary" data-testid="bd-summary">
      <span class="font-semibold text-text-primary tabular-nums text-md">${visibleCount}</span>
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
        onClick=${() => navigateBoard({ focus: 'curation' })}
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
        onClick=${() => navigateBoard({ focus: 'karma' })}
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
function BdAuthor({ label, size = 24 }: { label: string; size?: number }) {
  const isOperator = label.toLowerCase() === 'operator' || label.toLowerCase() === 'dashboard'
  // Prototype board.jsx:8 renders the operator avatar as the literal "OP"
  // glyph; keepers use a 2-letter monogram (SigilBadge style, fleet.jsx:8).
  const sigil = isOperator ? 'OP' : label.slice(0, 2).toUpperCase()
  return html`<span class=${`bd-sigil ${isOperator ? 'op' : ''}`} style=${{ width: size, height: size }}>${sigil}</span>`
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
  const previewBody = dedupeLeadingHeading(post.title, stripStateBlocks(post.body))
  const authorLabel = boardActorDisplayName(post.author, post.author_identity)
  const authorSigilLabel = boardActorSigilLabel(post.author, post.author_identity)
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
  const claimEvidenceLabel = boardClaimEvidenceLabel(post.claim_evidence)
  const claimEvidenceTitle = boardClaimEvidenceTitle(post.claim_evidence)
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
        <${BdAuthor} label=${authorSigilLabel} />
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
        ${claimEvidenceLabel !== null ? html`
          <span
            class=${`bd-badge ${boardClaimEvidenceBadgeClass(post.claim_evidence)}`}
            aria-label=${claimEvidenceTitle}
            title=${claimEvidenceTitle}
          >${claimEvidenceLabel}</span>
        ` : null}
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
        <${PostShareActions} post=${post} compact />
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
// Glyph vocabulary mirrors the keeper-v2 prototype (data-surfaces.jsx:7-12):
// all→◈, incidents→⚠, watercooler→◌, every other hearth→⌗. Live hearth
// names are data-driven, so the generic ⌗ default matches the prototype's
// per-hearth glyph while the two named specials keep their prototype glyphs.
const SUB_BOARD_GLYPHS: Record<string, string> = {
  all: '◈',
  incidents: '⚠',
  watercooler: '◌',
  default: '⌗',
}

function countMentionMessages(): number {
  return messages.value.filter(message => extractMentionTargets(message.content).length > 0).length
}

function BdRail({ activeSub, onSub, onMentions }: {
  activeSub: string
  onSub: (sub: string) => void
  onMentions: () => void
}) {
  const hearths = boardHearths.value
  const allCount = boardPosts.value.length
  const modCount = useMemo(() => boardPosts.value.filter(p => p.moderation_status && p.moderation_status !== 'none' && p.moderation_status !== 'approved').length, [boardPosts.value])
  const mentionCount = useMemo(() => countMentionMessages(), [messages.value])

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
        <span class="n">${mentionCount}</span>
      </button>
    </nav>
  `
}

function BdFeedHead({ activeFilter, onFilter, count, contentQuery, onContentQuery, sortMode, onSort }: {
  activeFilter: 'all' | 'state' | 'mod'
  onFilter: (filter: 'all' | 'state' | 'mod') => void
  count: number
  contentQuery: string
  onContentQuery: (value: string) => void
  sortMode: BoardSortMode
  onSort: (sortMode: BoardSortMode) => void
}) {
  const activeHearth = boardHearthFilter.value
  // Prototype board.jsx:158 renders the bare hearth label (e.g. "core/scheduler")
  // with no "#" prefix; the hearth name already carries its namespace path.
  const title = activeHearth === '' ? '전체 피드' : activeHearth
  const filters: Array<{ key: 'all' | 'state' | 'mod'; label: string }> = [
    { key: 'all', label: '전체' },
    { key: 'state', label: '상태 블록' },
    { key: 'mod', label: '모더레이션' },
  ]

  return html`
    <div class="bd-feed-head">
      <h2>${title}</h2>
      <span class="ns">${count}개 포스트</span>
      <${TextInput}
        type="search"
        value=${contentQuery}
        placeholder="제목/본문에서 검색"
        ariaLabel="게시글 본문 필터"
        onInput=${(e: Event) => onContentQuery((e.target as HTMLInputElement).value)}
        class="min-w-40 max-w-64 !px-2 !py-1 !text-xs"
      />
      <${Select}
        value=${sortMode}
        options=${SORT_MODES.map(mode => ({ value: mode.id, label: mode.label }))}
        ariaLabel="게시글 정렬"
        testId="bd-sort-mode"
        class="!w-auto min-w-32 !px-2 !py-1 !text-xs"
        onInput=${(value: string) => onSort(value as BoardSortMode)}
      />
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

function BdDetailResizeHandle({
  width,
  onWidthChange,
}: {
  width: number
  onWidthChange: (width: number) => void
}) {
  const handlePointerDown = (event: PointerEvent) => {
    if (event.button !== 0) return
    event.preventDefault()
    const startX = event.clientX
    const startWidth = width

    const handlePointerMove = (moveEvent: PointerEvent) => {
      onWidthChange(startWidth + startX - moveEvent.clientX)
    }
    const stopTracking = () => {
      window.removeEventListener('pointermove', handlePointerMove)
      window.removeEventListener('pointerup', stopTracking)
      window.removeEventListener('pointercancel', stopTracking)
    }

    window.addEventListener('pointermove', handlePointerMove)
    window.addEventListener('pointerup', stopTracking, { once: true })
    window.addEventListener('pointercancel', stopTracking, { once: true })
  }

  const handleKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'ArrowLeft') {
      event.preventDefault()
      onWidthChange(width + 10)
    } else if (event.key === 'ArrowRight') {
      event.preventDefault()
      onWidthChange(width - 10)
    } else if (event.key === 'Home') {
      event.preventDefault()
      onWidthChange(BOARD_DETAIL_WIDTH_MIN)
    } else if (event.key === 'End') {
      event.preventDefault()
      onWidthChange(BOARD_DETAIL_WIDTH_MAX)
    }
  }

  return html`
    <button
      type="button"
      class="bd-detail-resize"
      aria-label="Resize board detail rail"
      aria-orientation="vertical"
      aria-valuemin=${BOARD_DETAIL_WIDTH_MIN}
      aria-valuemax=${BOARD_DETAIL_WIDTH_MAX}
      aria-valuenow=${width}
      data-testid="bd-detail-resize"
      onPointerDown=${handlePointerDown}
      onKeyDown=${handleKeyDown}
    />
  `
}

function BdThreadDetail({
  post,
  detailWidth,
  onDetailWidthChange,
  onClose,
}: {
  post: BoardPost
  detailWidth: number
  onDetailWidthChange: (width: number) => void
  onClose: () => void
}) {
  useEffect(() => {
    if (detailPostId.value !== post.id) {
      void loadPostDetail(post.id)
    }
  }, [post.id])

  const authorLabel = boardActorDisplayName(post.author, post.author_identity)
  const authorSigilLabel = boardActorSigilLabel(post.author, post.author_identity)
  const evidencePost = detailPostId.value === post.id && detailPost.value ? detailPost.value : post

  return html`
    <aside class="bd-detail has-post" data-testid="bd-thread-detail">
      <${BdDetailResizeHandle} width=${detailWidth} onWidthChange=${onDetailWidthChange} />
      <div class="bd-detail-h">
        <h3>스레드</h3>
        <button type="button" class="bd-detail-x" onClick=${onClose} aria-label="닫기">✕</button>
      </div>
      <div class="bd-detail-scroll">
        <div class="bd-th">
          <${BdAuthor} label=${authorSigilLabel} size=${26} />
          <div>
            <div class="bd-th-hd"><span class="who">${authorLabel}</span><span class="ts mono"><${TimeAgo} timestamp=${post.created_at} /></span></div>
            <div class="bd-th-body">
              <div class="text-sm font-semibold mb-1">${stripInlineMarkdown(post.title)}</div>
              <div class="mb-2"><${PostShareActions} post=${post} /></div>
              <${RichContent} text=${stripStateBlocks(post.body)} previewLimit=${4} />
              <${FusionBoardEvidence} post=${evidencePost} class="mt-3" />
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

function BdDetail({
  post,
  detailWidth,
  mentionsOpen,
  onDetailWidthChange,
  onClose,
  onCloseMentions,
}: {
  post: BoardPost | null
  detailWidth: number
  mentionsOpen: boolean
  onDetailWidthChange: (width: number) => void
  onClose: () => void
  onCloseMentions: () => void
}) {
  if (post) return html`
    <${BdThreadDetail}
      post=${post}
      detailWidth=${detailWidth}
      onDetailWidthChange=${onDetailWidthChange}
      onClose=${onClose}
    />
  `
  // No post selected and the mention inbox is closed: render nothing so the
  // detail grid track collapses to 0 (two-column rail + feed). The mention
  // inbox is reachable from the rail (bd-queue-mentions). Matches the v2
  // prototype, which only expands the detail column on demand.
  if (!mentionsOpen) return null
  return html`
    <aside class="bd-detail is-mentions is-mobile-open" data-testid="bd-mention-detail">
      <${BdDetailResizeHandle} width=${detailWidth} onWidthChange=${onDetailWidthChange} />
      <div class="bd-detail-h">
        <h3>멘션 인박스</h3>
        <button type="button" class="bd-detail-x bd-detail-mobile-close" onClick=${onCloseMentions} aria-label="멘션 인박스 닫기">✕</button>
      </div>
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
  const [mobileKeeperTarget, setMobileKeeperTarget] = useState('')
  const [mobileOpen, setMobileOpen] = useState(false)
  const [mobileAttachments, setMobileAttachments] = useState<ComposerAttachmentDraft[]>([])
  const [mobileVoiceDraft, setMobileVoiceDraft] = useState<ComposerVoiceDraft | null>(null)
  const [mobileRecording, setMobileRecording] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const mobileFileInputRef = useRef<HTMLInputElement>(null)

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
  const activeModeLabel = tabs.find(tab => tab.key === mode)?.label ?? '게시'

  const placeholder = mode === 'post'
    ? `${boardHearthFilter.value ? `#${boardHearthFilter.value}` : '보드'}에 게시…`
    : mode === 'mention'
      ? '@keeper 를 멘션해 직접 지시…'
      : '상태 블록 발행 — 상태 키:값 형식'

  const composerMode: ComposerV2Mode = mode === 'post' ? 'broadcast' : mode === 'mention' ? 'dm' : 'state-block'
  const mobileMention = useOperatorMentionContext({
    message: localBody,
    target: mobileKeeperTarget,
    dmActive: mode === 'mention',
    listboxId: 'bd-mobile-mention-listbox',
    fallbackKeepers: dashboardKeepers.value,
  })
  const mobileMentionOptions = mobileMention.onlineKeepers
  const mobileMentionOptionNames = mobileMentionOptions.map(keeper => keeper.name).join('\0')
  const selectedMobileKeeper = keeperNameFromTarget(mobileKeeperTarget)
  const selectedMobileKeeperAvailable =
    !!selectedMobileKeeper && mobileMentionOptions.some(keeper => keeper.name === selectedMobileKeeper)
  const typedMobileMention = mode === 'mention' ? firstMentionNameFromMessage(localBody) : null
  const matchedTypedMobileMention = typedMobileMention
    ? mobileMentionOptions.find(keeper => keeper.name.toLowerCase() === typedMobileMention.toLowerCase())?.name ?? null
    : null
  const mobileMentionTarget = mode === 'mention'
    ? mobileMention.trailingMentionTarget
      ?? matchedTypedMobileMention
      ?? (selectedMobileKeeperAvailable ? selectedMobileKeeper : null)
      ?? (mobileMentionOptions.length === 0 ? typedMobileMention : null)
    : null
  const mobileMentionUnresolved =
    mode === 'mention'
    && !!typedMobileMention
    && !mobileMentionTarget
    && mobileMentionOptions.length > 0
  const mobileStateKeys = mode === 'state' ? stateBlockKeys(localBody) : []
  const mobileQuickBusy = submitting || operatorActionBusy.value
  const mobileMentionHasDraft = mode === 'mention'
    && (localBody.trim() !== '' || mobileAttachments.length > 0 || mobileVoiceDraft !== null)
  const mobileQuickHasDraft = mode === 'mention' ? mobileMentionHasDraft : localBody.trim() !== ''
  const mobileQuickDisabled = mobileQuickBusy
    || !mobileQuickHasDraft
    || (mode === 'mention' && (!mobileMentionTarget || mobileMentionUnresolved))
    || (mode === 'state' && mobileStateKeys.length === 0)

  useEffect(() => {
    if (mode !== 'mention') return
    if (selectedMobileKeeperAvailable) return
    const firstKeeper = mobileMentionOptions[0]?.name
    setMobileKeeperTarget(firstKeeper ? `keeper:${firstKeeper}` : '')
  }, [mode, mobileMentionOptionNames, selectedMobileKeeperAvailable])

  useEffect(() => {
    if (mode !== 'mention') return
    if (mobileMentionOptions.length > 0) return
    void refreshExecution()
  }, [mode, mobileMentionOptions.length])

  function mobilePostTitle(body: string): string {
    const firstLine = body
      .split(/\r?\n/)
      .map(line => line.trim())
      .find(Boolean)
    if (!firstLine) return 'Board post'
    return firstLine.replace(/\s+/g, ' ').slice(0, 72)
  }

  function chooseMobileMentionTarget(value: string): void {
    const keeperName = keeperNameFromTarget(value)
    setMobileKeeperTarget(value)
    if (!keeperName) return
    setLocalBody(current => mentionQueryFromMessage(current) !== null ? replaceTrailingMentionDraft(current, keeperName) : current)
  }

  function chooseMobileMentionCandidate(keeperName: string): void {
    setMobileKeeperTarget(`keeper:${keeperName}`)
    setLocalBody(current => replaceTrailingMentionDraft(current, keeperName))
  }

  function attachMobileMentionFiles(files: FileList | File[]): void {
    const nextFiles = Array.from(files).slice(0, 6)
    if (nextFiles.length === 0) return
    setMobileAttachments(current => [
      ...current,
      ...nextFiles.map((file, index): ComposerAttachmentDraft => ({
        id: `mobile-${Date.now()}-${index}-${file.name}`,
        kind: file.type.startsWith('image/') ? 'image' : 'file',
        name: file.name,
        size: formatFileSize(file.size),
      })),
    ].slice(0, 6))
  }

  function stopMobileVoiceDraft(): void {
    setMobileRecording(false)
    setMobileVoiceDraft(createComposerVoiceDraft())
  }

  function resetMobileMentionDrafts(): void {
    setMobileAttachments([])
    setMobileVoiceDraft(null)
    setMobileRecording(false)
  }

  async function submitPost(event?: Event, options: { compactMobile?: boolean } = {}): Promise<void> {
    event?.stopPropagation()
    const body = localBody.trim()
    const title = options.compactMobile ? mobilePostTitle(body) : localTitle.trim()
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
      setMobileOpen(false)
      showToast('글을 등록했습니다', 'success')
      refreshBoard()
    } catch (err) {
      console.warn('[board] post submit failed', err instanceof Error ? err.message : err)
      showToast('글 등록에 실패했습니다', 'error')
    } finally {
      setSubmitting(false)
    }
  }

  async function submitMobileQuick(event?: Event): Promise<void> {
    if (mode === 'post') {
      await submitPost(event, { compactMobile: true })
      return
    }

    event?.stopPropagation()
    const body = localBody.trim()
    const message = mode === 'mention'
      ? serializeComposerBody({ text: localBody, attachments: mobileAttachments, voice: mobileVoiceDraft })
      : body
    if (!message || mobileQuickDisabled) return
    setSubmitting(true)
    try {
      if (mode === 'mention') {
        const keeperId = mobileMentionTarget
        if (!keeperId) return
        await dispatchOperatorAction({
          actor: currentDashboardActor(),
          action_type: 'keeper_message',
          target_type: 'keeper',
          target_id: keeperId,
          payload: { message },
        })
      } else {
        await sendBroadcast(currentDashboardActor(), message)
      }
      setLocalBody('')
      resetMobileMentionDrafts()
      setMobileOpen(false)
      showToast('Message sent.', 'success')
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Message send failed.'
      console.warn('[board] mobile quick compose failed', message)
      showToast(message, 'error')
    } finally {
      setSubmitting(false)
    }
  }

  return html`
    <div class="bd-composer" data-testid="bd-composer" data-mobile-open=${mobileOpen ? 'true' : 'false'}>
      <div class="bd-composer-mobile-summary" data-testid="bd-composer-mobile-summary">
        <div class="bd-composer-mobile-copy">
          <span class="bd-composer-mobile-kicker">${localHearth ? `#${localHearth}` : 'Board'}</span>
          <span class="bd-composer-mobile-title">${activeModeLabel} 작성</span>
        </div>
        <button
          type="button"
          class="bd-composer-mobile-toggle"
          aria-expanded=${mobileOpen ? 'true' : 'false'}
          aria-controls="bd-composer-fields"
          onClick=${() => setMobileOpen(open => !open)}
          data-testid="bd-composer-mobile-toggle"
        >${mobileOpen ? '접기' : '새 글'}</button>
      </div>
      <div class="bd-composer-fields" id="bd-composer-fields">
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
        ${mode === 'mention' ? html`
          <div class="bd-mobile-mention-targets" aria-label="Mobile mention target picker">
            <span class="bd-mobile-mention-icon" aria-hidden="true">
              <${AtSign} size=${13} strokeWidth=${2.2} />
            </span>
            <select
              class="bd-mobile-mention-select"
              aria-label="Mobile mention target"
              value=${selectedMobileKeeperAvailable ? mobileKeeperTarget : ''}
              onInput=${(event: Event) => chooseMobileMentionTarget((event.target as HTMLSelectElement).value)}
              disabled=${mobileQuickBusy || mobileMentionOptions.length === 0}
              data-testid="bd-composer-mobile-mention-target"
            >
              ${mobileMentionOptions.length === 0
                ? html`<option value="">No keeper targets</option>`
                : mobileMentionOptions.map(keeper => html`
                  <option key=${keeper.name} value=${`keeper:${keeper.name}`}>${keeper.name}</option>
                `)}
            </select>
            <span class="bd-mobile-mention-current" aria-live="polite">
              ${mobileMentionUnresolved
                ? `No @${typedMobileMention} match`
                : mobileMentionTarget
                  ? `@${mobileMentionTarget}`
                  : 'No target'}
            </span>
          </div>
          ${mobileMention.mentionListOpen
            ? html`
              <div
                id="bd-mobile-mention-listbox"
                class="bd-mobile-mention-listbox"
                role="listbox"
                aria-label=${`Mobile mention autocomplete (${mobileMention.mentionMatches.length} matches)`}
                data-testid="bd-composer-mobile-mention-listbox"
              >
                ${mobileMention.mentionMatches.length > 0
                  ? mobileMention.mentionMatches.map((candidate, index) => html`
                    <button
                      id=${`bd-mobile-mention-listbox-option-${index}`}
                      key=${candidate.name}
                      type="button"
                      class=${`bd-mobile-mention-option ${candidate.selected || index === mobileMention.activeMentionIndex ? 'on' : ''}`}
                      role="option"
                      aria-selected=${candidate.selected || index === mobileMention.activeMentionIndex ? 'true' : 'false'}
                      disabled=${mobileQuickBusy}
                      onClick=${() => chooseMobileMentionCandidate(candidate.name)}
                    >
                      <${AtSign} size=${12} strokeWidth=${2.2} aria-hidden="true" />
                      <span class="bd-mobile-mention-option-name">${candidate.name}</span>
                      <span class="bd-mobile-mention-option-status">${candidate.status ?? 'online'}</span>
                    </button>
                  `)
                  : html`<div class="bd-mobile-mention-empty">No keeper target matches @${mobileMention.mentionQuery}</div>`}
              </div>
            `
            : null}
          ${mobileAttachments.length > 0 || mobileVoiceDraft
            ? html`
              <div class="bd-mobile-draft-tray composer-tray" data-testid="bd-composer-mobile-draft-tray">
                ${mobileAttachments.map(attachment => html`
                  <div class="cdraft att" key=${attachment.id}>
                    <div class="cdraft-thumb">
                      <span class="cdraft-glyph">${attachment.kind === 'image' ? '▧' : '◫'}</span>
                    </div>
                    <div class="cdraft-meta">
                      <span class="cdraft-name mono">${attachment.name}</span>
                      <span class="cdraft-sub mono">${[attachment.size, attachment.kind, attachment.dims].filter(Boolean).join(' · ')}</span>
                    </div>
                    <button
                      type="button"
                      class="cdraft-x"
                      title="첨부 제거"
                      aria-label=${`Remove mobile attachment ${attachment.name}`}
                      onClick=${() => { setMobileAttachments(current => current.filter(item => item.id !== attachment.id)) }}
                      disabled=${mobileQuickBusy}
                    >
                      <${X} size=${10} aria-hidden="true" />
                    </button>
                  </div>
                `)}
                ${mobileVoiceDraft
                  ? html`
                    <div class="cdraft voice">
                      <span class="cdraft-glyph mic">◌</span>
                      <div class="cdraft-wave" aria-hidden="true">
                        ${mobileVoiceDraft.wave.map((height, index) => html`<span class="vbar" key=${index} style=${{ height: `${Math.round(4 + height * 18)}px` }} />`)}
                      </div>
                      <span class="cdraft-dur mono">${formatClock(mobileVoiceDraft.secs)}</span>
                      <div class="cdraft-tx">
                        <span class="cdraft-tx-k">받아쓰기</span>
                        <span class="cdraft-tx-v">${mobileVoiceDraft.transcript}</span>
                      </div>
                      <button
                        type="button"
                        class="cdraft-x"
                        title="음성 제거"
                        aria-label="Remove mobile voice draft"
                        onClick=${() => { setMobileVoiceDraft(null) }}
                        disabled=${mobileQuickBusy}
                      >
                        <${X} size=${10} aria-hidden="true" />
                      </button>
                    </div>
                  `
                  : null}
              </div>
            `
            : null}
          ${mobileRecording
            ? html`
              <div class="bd-mobile-rec-bar rec-bar" data-testid="bd-composer-mobile-recorder">
                <span class="rec-dot" aria-hidden="true"></span>
                <span class="rec-lbl">녹음 중</span>
                <span class="rec-clock mono">0:12</span>
                <div class="rec-wave" aria-hidden="true">
                  ${[0.4, 0.8, 0.5, 0.9, 0.45, 0.75, 0.52, 0.84, 0.48, 0.7].map((height, index) => html`<span class="rbar" key=${index} style=${{ height: `${Math.round(3 + height * 20)}px` }} />`)}
                </div>
                <button
                  type="button"
                  class="rec-btn cancel"
                  onClick=${() => { setMobileRecording(false) }}
                  disabled=${mobileQuickBusy}
                  data-testid="bd-composer-mobile-voice-cancel"
                >취소</button>
                <button
                  type="button"
                  class="rec-btn stop"
                  onClick=${stopMobileVoiceDraft}
                  disabled=${mobileQuickBusy}
                  data-testid="bd-composer-mobile-voice-stop"
                >
                  <${Square} size=${11} aria-hidden="true" />
                  완료
                </button>
              </div>
            `
            : null}
        ` : null}
        <div class="bd-mobile-quick-compose bd-comp-box" data-mode=${mode}>
          <textarea
            rows=${1}
            class="bg-transparent border-0 outline-0 text-[var(--text-bright)] text-sm placeholder:text-[var(--text-dim)] resize-none"
            placeholder=${placeholder}
            value=${localBody}
            role=${mode === 'mention' ? 'combobox' : undefined}
            aria-autocomplete=${mode === 'mention' ? 'list' : undefined}
            aria-controls=${mode === 'mention' && mobileMention.mentionListOpen ? 'bd-mobile-mention-listbox' : undefined}
            aria-expanded=${mode === 'mention' ? String(mobileMention.mentionListOpen) : undefined}
            aria-activedescendant=${mobileMention.activeMentionOptionId}
            onInput=${(e: Event) => {
              if (mobileMention.dismissedMentionQuery !== null) mobileMention.setDismissedMentionQuery(null)
              setLocalBody((e.target as HTMLTextAreaElement).value)
            }}
            onKeyDown=${(event: KeyboardEvent) => {
              if (mode === 'mention' && mobileMention.mentionListOpen && mobileMention.mentionMatches.length > 0) {
                if (event.key === 'ArrowDown') {
                  event.preventDefault()
                  mobileMention.setActiveMentionIndex(index => (index + 1) % mobileMention.mentionMatches.length)
                  return
                }
                if (event.key === 'ArrowUp') {
                  event.preventDefault()
                  mobileMention.setActiveMentionIndex(index => (index - 1 + mobileMention.mentionMatches.length) % mobileMention.mentionMatches.length)
                  return
                }
                if (event.key === 'Enter' && !(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) {
                  event.preventDefault()
                  chooseMobileMentionCandidate(mobileMention.mentionMatches[mobileMention.activeMentionIndex]?.name ?? mobileMention.mentionMatches[0]!.name)
                  return
                }
              }
              if (mode === 'mention' && mobileMention.mentionListOpen && event.key === 'Escape') {
                event.preventDefault()
                mobileMention.setDismissedMentionQuery(mobileMention.mentionQuery ?? '')
              }
            }}
            data-testid="bd-composer-mobile-body"
          />
          ${mode === 'state' ? html`
            <button
              type="button"
              class="bd-mobile-state-template"
              title="Insert state block"
              aria-label="Insert state block"
              disabled=${mobileQuickBusy}
              onClick=${() => setLocalBody(current => ensureStateBlockDraft(current))}
              data-testid="bd-composer-mobile-state-template"
            >
              <${Braces} size=${15} strokeWidth=${2.2} aria-hidden="true" />
            </button>
          ` : null}
          ${mode === 'mention' ? html`
            <input
              ref=${mobileFileInputRef}
              type="file"
              accept="image/*,.pdf,.txt,.log,.json,.csv,.md"
              multiple
              hidden
              data-testid="bd-composer-mobile-file-input"
              onChange=${(event: Event) => {
                const input = event.target as HTMLInputElement
                if (input.files) attachMobileMentionFiles(input.files)
                input.value = ''
              }}
            />
            <button
              type="button"
              class="bd-mobile-compose-tool"
              title="이미지·파일 첨부"
              aria-label="Attach mobile mention file"
              disabled=${mobileQuickBusy || mobileAttachments.length >= 6}
              onClick=${() => { mobileFileInputRef.current?.click() }}
              data-testid="bd-composer-mobile-attach"
            >
              <${Paperclip} size=${15} strokeWidth=${2.2} aria-hidden="true" />
            </button>
            <button
              type="button"
              class="bd-mobile-compose-tool"
              title="음성 입력"
              aria-label="Start mobile mention voice draft"
              disabled=${mobileQuickBusy || mobileRecording}
              onClick=${() => { setMobileRecording(true) }}
              data-testid="bd-composer-mobile-voice"
            >
              <${Mic} size=${15} strokeWidth=${2.2} aria-hidden="true" />
            </button>
          ` : null}
          <button
            type="button"
            class="send"
            disabled=${mobileQuickDisabled}
            onClick=${(e: Event) => { void submitMobileQuick(e) }}
            data-testid="bd-composer-mobile-send"
          >${submitting ? '등록 중...' : '게시 ↑'}</button>
        </div>
        ${mode === 'post' ? html`
          <div class="bd-desktop-post-form bd-comp-box grid gap-2">
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
            <div class="bd-comp-meta flex gap-2">
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
          <div class="bd-desktop-composer-v2 bd-comp-box">
            <${ComposerV2}
              workspaceId=${localHearth || 'default'}
              mode=${composerMode}
              showModeSelector=${false}
              modeLabels=${{ broadcast: '게시', dm: '멘션', 'state-block': '상태 블록' }}
            />
          </div>
        `}
      </div>
    </div>
  `
}

function BdMobileQueues({
  activeFilter,
  mentionCount,
  modCount,
  onFilter,
  onMentions,
}: {
  activeFilter: 'all' | 'state' | 'mod'
  mentionCount: number
  modCount: number
  onFilter: (filter: 'all' | 'state' | 'mod') => void
  onMentions: () => void
}) {
  return html`
    <div class="bd-mobile-queues" aria-label="Board mobile queues" data-testid="bd-mobile-queues">
      <button
        type="button"
        class=${`bd-mobile-queue ${activeFilter === 'mod' ? 'on' : ''}`}
        onClick=${() => onFilter('mod')}
        data-testid="bd-mobile-queue-mod"
      >
        <span class="glyph">⚑</span>
        모더레이션
        <span class="n">${modCount}</span>
      </button>
      <button
        type="button"
        class="bd-mobile-queue"
        onClick=${onMentions}
        data-testid="bd-mobile-queue-mentions"
      >
        <span class="glyph">＠</span>
        멘션 인박스
        <span class="n">${mentionCount}</span>
      </button>
    </div>
  `
}

function BdFeed({ posts, onMentions }: { posts: BoardPost[]; onMentions: () => void }) {
  const [contentQuery, setContentQuery] = useState('')
  const filteredPosts = useMemo(
    () => filterBoardPosts(posts, contentQuery),
    [posts, contentQuery],
  )
  const isFiltering = contentQuery.trim() !== ''
  const visibleGroups = useMemo(() => splitVisiblePosts(filteredPosts), [filteredPosts])
  const mentionCount = useMemo(() => countMentionMessages(), [messages.value])
  const modCount = useMemo(
    () => posts.filter(post => post.moderation_status && post.moderation_status !== 'none' && post.moderation_status !== 'approved').length,
    [posts],
  )

  const modeFilteredGroups = useMemo(() => visibleGroups.groups.map(g => ({
    ...g,
    posts: g.posts.filter(post => {
      if (boardFilterMode.value === 'state') return postHasStateBlock(post)
      if (boardFilterMode.value === 'mod') return post.moderation_status && post.moderation_status !== 'none' && post.moderation_status !== 'approved'
      return true
    }),
  })), [visibleGroups, boardFilterMode.value])
  const filteredByMode = useMemo(() => modeFilteredGroups.flatMap(g => g.posts), [modeFilteredGroups])

  return html`
    <section class="bd-feed">
      <${BdFeedHead}
        activeFilter=${boardFilterMode.value}
        onFilter=${(filter: 'all' | 'state' | 'mod') => { boardFilterMode.value = filter }}
        count=${filteredByMode.length}
        contentQuery=${contentQuery}
        onContentQuery=${setContentQuery}
        sortMode=${boardSortMode.value}
        onSort=${(sortMode: BoardSortMode) => {
          if (boardSortMode.value === sortMode) return
          boardSortMode.value = sortMode
          categoryVisibleLimits.value = {
            article: PAGE_SIZE,
            review: PAGE_SIZE,
            notice: PAGE_SIZE,
            system: PAGE_SIZE,
          }
          selectedBoardPostId.value = null
          refreshBoard()
        }}
      />
      <${BdMobileQueues}
        activeFilter=${boardFilterMode.value}
        mentionCount=${mentionCount}
        modCount=${modCount}
        onFilter=${(filter: 'all' | 'state' | 'mod') => { boardFilterMode.value = filter }}
        onMentions=${onMentions}
      />
      <div class="bd-list">
        ${isFiltering && filteredByMode.length === 0 && posts.length > 0
          ? html`<div class="ov-empty">필터 결과 없음 (${posts.length} items)</div>`
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
  // The mention inbox opens on demand (from the rail's bd-queue-mentions button),
  // on desktop and mobile alike. When neither a post nor the mention inbox is open
  // the detail column collapses to a two-column rail + feed layout — see the
  // --bd-detail-width computation below. Matches the standalone v2 prototype.
  const [mentionInboxOpen, setMentionInboxOpen] = useState(false)
  const [detailWidth, setDetailWidth] = useState<number>(readStoredBoardDetailWidth)
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
          <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
            <${BoardSummary} />
            <${PostDetail} post=${post} />
          </div>
        `
      : html`
          <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
            <${BoardSummary} />
            <button type="button"
              class="v2-workspace-action mb-4 px-3 py-1.5 rounded-[var(--r-1)] text-xs font-medium text-[var(--color-fg-muted)] bg-transparent border border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] transition-colors cursor-pointer"
              onClick=${() => navigateBoard()}
            >← 게시판으로 돌아가기</button>
            ${detailLoading.value
              ? html`<${LoadingState} title="글 불러오는 중…" />`
              : html`<${EmptyState} title="글을 찾지 못했습니다" compact />`}
          </div>
        `
  }

  if (focus === 'mention-inbox') {
    return html`
      <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
        <${BoardSummary} />
        <${MentionInbox} />
      </div>
    `
  }

  if (focus === 'messages-workspace') {
    return html`
      <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
        <${BoardSummary} />
        <${MessageWorkspaceTimeline} />
      </div>
    `
  }

  if (focus === 'state-block') {
    return html`
      <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
        <${BoardSummary} />
        <${StateBlockMessages} />
      </div>
    `
  }

  if (focus === 'curation') {
    return html`
      <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
        <${BoardSummary} />
        <${BoardCurationPanel} />
      </div>
    `
  }

  if (focus === 'karma') {
    return html`
      <div class="v2-workspace-surface ss-surface bg-surface-page text-text-primary">
        <${BoardSummary} />
        <${BoardKarmaPanel} />
      </div>
    `
  }

  const activeSub = boardHearthFilter.value
  const selectedPost = selectedBoardPostId.value
    ? posts.find(p => p.id === selectedBoardPostId.value) ?? null
    : null

  function openMentionInbox(): void {
    selectedBoardPostId.value = null
    setMentionInboxOpen(true)
  }

  function setPersistentDetailWidth(width: number): void {
    const normalized = normalizeBoardDetailWidth(width)
    setDetailWidth(normalized)
    writeStoredBoardDetailWidth(normalized)
  }

  // Detail column is reserved only when a post thread or the mention inbox is
  // open; otherwise the grid track collapses to 0 (two-column rail + feed).
  const detailOpen = !!selectedPost || mentionInboxOpen

  return html`
    <div
      class="v2-board-surface ss-surface bg-surface-page text-text-primary"
      data-detail-width=${String(detailWidth)}
      data-detail-open=${String(detailOpen)}
    >
      <!-- Collapse is driven by the inline --bd-detail-width custom property
           (0 when no detail is open), which BOTH the legacy board-v2.css and the
           keeper-v2 surfaces.css .bd-body grids consume as their third track.
           This is the single source of truth: it does not depend on a separate
           .no-detail rule winning a same-specificity (0,2,0) cascade by load
           order (the #22098/#22103 split-brain), and it survives the legacy
           board-v2.css removal (main.ts:114 migration). -->
      <div class="bd-body" style=${`--bd-detail-width: ${detailOpen ? detailWidth : 0}px;`}>
        <${BdRail}
          activeSub=${activeSub}
          onSub=${(sub: string) => {
            boardHearthFilter.value = sub
            selectedBoardPostId.value = null
            setMentionInboxOpen(false)
            refreshBoard()
          }}
          onMentions=${openMentionInbox}
        />
        <${BdFeed} posts=${boardPosts.value} onMentions=${openMentionInbox} />
        <${BdDetail}
          post=${selectedPost}
          detailWidth=${detailWidth}
          mentionsOpen=${mentionInboxOpen}
          onDetailWidthChange=${setPersistentDetailWidth}
          onClose=${() => { selectedBoardPostId.value = null }}
          onCloseMentions=${() => setMentionInboxOpen(false)}
        />
      </div>
    </div>
  `
}

/**
 * `3 Knowledge > Board` Tab (`board-tab.ts`)
 *
 * - `MasterDetail` + `VirtualList` (zero eager 200-post DOM explosion).
 * - Signal-only default filter ON (matching TUI `#6`), toggleable to All.
 * - Multi-account capability gating: routes to `GET /api/v1/dashboard/board` in
 *   `multi_account_signed_in` sessions and derives hearths from posts (0× 404).
 * - Sub-boards & Hearths filter (`/api/v1/board/hearths`, `/api/v1/board/sub-boards` in single-user mode).
 * - Succession Chain folding (closed posts with `successor_id` fold into head thread).
 * - Zero-count emoji reactions collapsed behind a single `[+☺]` trigger (`#29` V2!).
 * - Full CRUD: create post, reply/comment, upvote/downvote, react, pin, delete.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { authSession } from '../../core/auth'
import {
  extractObserverTopics,
  markViewSynced,
  subscribeObserverFrames,
  subscribeObserverReconnect,
} from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { ok } from '../../lib/result'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail, VirtualList } from '../../components/primitives'
import {
  asNonEmptyString,
  asSafeInt,
  asString,
  decodeBoardComment,
  decodeBoardPost,
  foldSuccessionChains,
  formatRelativeTime,
  isRecord,
  partitionReactions,
  renderSanitizedMarkdown,
  type BoardAudience,
  type BoardCommentItem,
  type BoardCommentPageInfo,
  type BoardHearthItem,
  type BoardPostItem,
  type BoardReactionSummary,
  type FoldedBoardEntry,
  type SubBoardItem,
  type WorkspaceViewProps,
} from './types'

interface BoardBundle {
  readonly posts: readonly BoardPostItem[]
  readonly hearths: readonly BoardHearthItem[]
  readonly subBoards: readonly SubBoardItem[]
  readonly hasMore: boolean
  readonly filteredOutCount: number
  readonly signalScanTruncated: boolean
}

interface BoardDetailData {
  readonly post: BoardPostItem
  readonly comments: readonly BoardCommentItem[]
  readonly commentPage: BoardCommentPageInfo | null
  readonly focusedComment: BoardCommentItem | null
}

function postedCommentId(ack: unknown, postId: string): string | null {
  if (!isRecord(ack) || ack.ok !== true || typeof ack.message !== 'string') return null
  try {
    const comment: unknown = JSON.parse(ack.message)
    return isRecord(comment) && comment.post_id === postId ? asNonEmptyString(comment.id) : null
  } catch {
    return null
  }
}

function decodeCommentPageInfo(raw: unknown): BoardCommentPageInfo | null {
  if (!isRecord(raw)) return null
  const offset = asSafeInt(raw.offset)
  const returned = asSafeInt(raw.returned)
  const total = asSafeInt(raw.total)
  if (offset === null || returned === null || total === null) return null
  return {
    offset,
    returned,
    total,
    nextOffset: asSafeInt(raw.next_offset),
  }
}

function renderAudienceBadges(audience: BoardAudience | null | undefined, compact = false) {
  if (!audience) return null
  if (audience.kind === 'targets' && audience.targets.length > 0) {
    if (compact && audience.targets.length > 1) {
      return html`
        <span
          class="kn-badge kn-badge--info"
          title=${audience.targets.map((t) => `@${t}`).join(', ')}
        >
          @${audience.targets[0]} +${audience.targets.length - 1}
        </span>
      `
    }
    return html`
      ${audience.targets.map((target) => html`
        <span key=${target} class="kn-badge kn-badge--info">@${target}</span>
      `)}
    `
  }
  if (audience.kind === 'broadcast') {
    return html`<span class="kn-badge kn-badge--info">@broadcast</span>`
  }
  return null
}

function deriveHearthsFromPosts(posts: readonly BoardPostItem[]): readonly BoardHearthItem[] {
  const counts = new Map<string, number>()
  for (const p of posts) {
    if (!p.hearth) continue
    counts.set(p.hearth, (counts.get(p.hearth) ?? 0) + 1)
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([name, count]) => ({ name, count }))
}

function ReactionBar(props: {
  readonly reactions: readonly BoardReactionSummary[]
  readonly supportedEmojis: readonly string[]
  readonly onToggle: (emoji: string) => void
  readonly disabled?: boolean
}) {
  const [pickerOpen, setPickerOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)
  const { active, collapsedZero } = useMemo(
    () => partitionReactions(props.reactions, props.supportedEmojis),
    [props.reactions, props.supportedEmojis],
  )

  useEffect(() => {
    if (!pickerOpen) return
    const onOutside = (event: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(event.target as Node)) {
        setPickerOpen(false)
      }
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        setPickerOpen(false)
      }
    }
    document.addEventListener('mousedown', onOutside)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onOutside)
      document.removeEventListener('keydown', onKey)
    }
  }, [pickerOpen])

  return html`
    <div ref=${wrapRef} class="kn-reactions">
      ${active.map((r) => html`
        <button
          key=${r.emoji}
          type="button"
          class="kn-react-pill"
          aria-pressed=${r.reacted}
          disabled=${props.disabled}
          onClick=${() => props.onToggle(r.emoji)}
        >
          <span>${r.emoji}</span>
          <span class="tnum">${r.count}</span>
        </button>
      `)}
      ${collapsedZero.length > 0 && html`
        <button
          type="button"
          class="kn-react-pill"
          aria-expanded=${pickerOpen}
          aria-label="반응 추가"
          disabled=${props.disabled}
          onClick=${() => setPickerOpen((v) => !v)}
        >
          +☺
        </button>
      `}
      ${pickerOpen && collapsedZero.length > 0 && html`
        <div class="kn-react-picker" role="group" aria-label="이모지 선택">
          ${collapsedZero.map((emoji) => html`
            <button
              key=${emoji}
              type="button"
              class="kn-react-pill"
              disabled=${props.disabled}
              onClick=${() => {
                setPickerOpen(false)
                props.onToggle(emoji)
              }}
            >
              ${emoji}
            </button>
          `)}
        </div>
      `}
    </div>
  `
}

export function BoardTab(props: WorkspaceViewProps) {
  const isMultiAccount = authSession.value.kind === 'multi_account_signed_in'
  const [bundle, setBundle] = useState<BoardBundle>({
    posts: [],
    hearths: [],
    subBoards: [],
    hasMore: false,
    filteredOutCount: 0,
    signalScanTruncated: false,
  })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)

  // Filters: Signal-only ON by default per TUI `#6`
  const [signalOnly, setSignalOnly] = useState(true)
  const [sortBy, setSortBy] = useState<'recent' | 'hot' | 'trending' | 'discussed'>('recent')
  const [selectedHearth, setSelectedHearth] = useState<string>('')
  const [query, setQuery] = useState('')

  // Selection & Detail
  const [selectedPostId, setSelectedPostId] = useState<string | null>(props.entityId ?? null)
  const [detail, setDetail] = useState<BoardDetailData | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailRefreshing, setDetailRefreshing] = useState(false)
  const [loadingMoreComments, setLoadingMoreComments] = useState(false)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [expandedChainHeads, setExpandedChainHeads] = useState<Record<string, boolean>>({})
  const [commentWindowStart, setCommentWindowStart] = useState(0)
  const detailAbortRef = useRef<AbortController | null>(null)
  const loadMoreAbortRef = useRef<AbortController | null>(null)
  const detailSeqRef = useRef(0)
  const detailRefreshingRef = useRef(false)
  const detailRef = useRef<BoardDetailData | null>(null)
  detailRef.current = detail
  const boardSeqRef = useRef(0)
  const selectedPostIdRef = useRef<string | null>(selectedPostId)
  selectedPostIdRef.current = selectedPostId

  const COMMENT_PAGE_LIMIT = 40
  const MAX_RENDERED_COMMENTS = 40

  // CRUD Forms
  const [showCreate, setShowCreate] = useState(false)
  const [newTitle, setNewTitle] = useState('')
  const [newBody, setNewBody] = useState('')
  const [newHearth, setNewHearth] = useState('')
  const [replyText, setReplyText] = useState('')
  const [replyParentId, setReplyParentId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [feedback, setFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)
  const replyTextareaRef = useRef<HTMLTextAreaElement>(null)
  const commentsEndRef = useRef<HTMLDivElement>(null)
  const focusedCommentRef = useRef<HTMLDivElement>(null)
  const replyViewRef = useRef<{ postId: string; commentId: string | null; scroll: boolean } | null>(null)

  const loadBoard = useCallback(async (reason: 'mount' | 'manual' | 'sse' = 'mount') => {
    const seq = ++boardSeqRef.current
    if (reason !== 'sse') setLoading(true)
    setLoadError(null)
    const multiAccountNow = authSession.peek().kind === 'multi_account_signed_in'
    const params = new URLSearchParams({ sort_by: sortBy, limit: '200' })
    if (signalOnly) {
      params.set('signal_only', 'true')
      params.set('exclude_system', 'true')
    }
    if (selectedHearth) params.set('hearth', selectedHearth)
    const cacheKey = `kn:board:${multiAccountNow ? 'ma' : 'local'}:${params.toString()}`

    const obs = await resourceCache.fetch<BoardBundle>(
      cacheKey,
      async (signal) => {
        if (multiAccountNow) {
          const postsRes = await apiGet<unknown>(`/api/v1/dashboard/board?${params.toString()}`, { signal })
          if (!postsRes.ok) return postsRes
          const rawFeed = isRecord(postsRes.value) ? postsRes.value : null
          const posts: BoardPostItem[] = []
          if (rawFeed && Array.isArray(rawFeed.posts)) {
            for (const raw of rawFeed.posts) {
              const p = decodeBoardPost(raw)
              if (p) posts.push(p)
            }
          }
          return ok({
            posts,
            hearths: deriveHearthsFromPosts(posts),
            subBoards: [],
            hasMore: rawFeed?.has_more === true,
            filteredOutCount: asSafeInt(rawFeed?.filtered_out_count) ?? 0,
            signalScanTruncated: rawFeed?.signal_scan_truncated === true,
          })
        }

        const [postsRes, hearthsRes, subBoardsRes] = await Promise.all([
          apiGet<unknown>(`/api/v1/board?${params.toString()}`, { signal }),
          apiGet<unknown>('/api/v1/board/hearths', { signal }),
          apiGet<unknown>('/api/v1/board/sub-boards', { signal }),
        ])
        if (!postsRes.ok) return postsRes

        const rawFeed = isRecord(postsRes.value) ? postsRes.value : null
        const posts: BoardPostItem[] = []
        if (rawFeed && Array.isArray(rawFeed.posts)) {
          for (const raw of rawFeed.posts) {
            const p = decodeBoardPost(raw)
            if (p) posts.push(p)
          }
        }

        const hearths: BoardHearthItem[] = []
        if (hearthsRes.ok && isRecord(hearthsRes.value) && Array.isArray(hearthsRes.value.hearths)) {
          for (const h of hearthsRes.value.hearths) {
            if (!isRecord(h)) continue
            const name = asNonEmptyString(h.name)
            if (name) hearths.push({ name, count: asSafeInt(h.count) ?? 0 })
          }
        }

        const subBoards: SubBoardItem[] = []
        if (subBoardsRes.ok && isRecord(subBoardsRes.value) && Array.isArray(subBoardsRes.value.sub_boards)) {
          for (const sb of subBoardsRes.value.sub_boards) {
            if (!isRecord(sb)) continue
            const id = asNonEmptyString(sb.id)
            const slug = asNonEmptyString(sb.slug)
            if (!id || !slug) continue
            const access = sb.access === 'members_only' || sb.access === 'owner_only' ? sb.access : 'open'
            subBoards.push({
              id,
              slug,
              name: asString(sb.name, slug),
              description: asString(sb.description, ''),
              access,
              postCount: asSafeInt(sb.post_count) ?? 0,
            })
          }
        }
        return ok({
          posts,
          hearths,
          subBoards,
          hasMore: rawFeed?.has_more === true,
          filteredOutCount: asSafeInt(rawFeed?.filtered_out_count) ?? 0,
          signalScanTruncated: rawFeed?.signal_scan_truncated === true,
        })
      },
      { ttlMs: 10_000, topics: ['board', 'board_post', 'board_comment'], reason },
    )
    if (seq !== boardSeqRef.current) return
    setLoading(false)
    if (obs.kind === 'value') {
      setBundle(obs.data)
      markViewSynced()
      setSelectedPostId((prev) => {
        if (prev && (prev === props.entityId || obs.data.posts.some((p) => p.id === prev))) return prev
        return obs.data.posts[0]?.id ?? null
      })
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [sortBy, signalOnly, selectedHearth, props.entityId, isMultiAccount])

  useEffect(() => {
    if (props.entityId) setSelectedPostId(props.entityId)
  }, [props.entityId])

  useEffect(() => {
    void loadBoard('mount')
  }, [loadBoard])

  const loadPostDetail = useCallback(
    async (
      postId: string,
      signal?: AbortSignal,
      opts?: { readonly preserveOnError?: boolean; readonly resetWindow?: boolean },
    ) => {
      const preserveOnError = opts?.preserveOnError ?? false
      const resetWindow = opts?.resetWindow ?? true
      const seq = ++detailSeqRef.current
      loadMoreAbortRef.current?.abort()
      setLoadingMoreComments(false)
      if (authSession.peek().kind === 'multi_account_signed_in') {
        detailRefreshingRef.current = false
        setDetailRefreshing(false)
        setDetail(null)
        setDetailLoading(false)
        setDetailError(null)
        return
      }
      const existing = detailRef.current
      const samePost = existing !== null && existing.post.id === postId
      const targetLoadedCount =
        samePost && !resetWindow
          ? Math.max(COMMENT_PAGE_LIMIT, existing.comments.length)
          : COMMENT_PAGE_LIMIT

      detailRefreshingRef.current = true
      setDetailRefreshing(true)
      if (!preserveOnError) setDetailLoading(true)
      setDetailError(null)
      try {
        const replyView = replyViewRef.current
        const focusId = replyView?.postId === postId ? replyView.commentId : null
        const params = new URLSearchParams({
          format: 'flat',
          comment_limit: String(targetLoadedCount),
          comment_offset: '0',
        })
        if (focusId) params.set('comment_focus', focusId)
        const res = await apiGet<unknown>(`/api/v1/board/${encodeURIComponent(postId)}?${params}`, { signal })
        if (signal?.aborted || seq !== detailSeqRef.current) return
        setDetailLoading(false)
        if (!res.ok) {
          if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
          if (!preserveOnError) setDetail(null)
          setDetailError(`게시글 상세/댓글 조회 실패: ${res.error.message}`)
          return
        }
        if (!isRecord(res.value)) {
          if (!preserveOnError) setDetail(null)
          setDetailError('게시글 상세 응답 형식이 올바르지 않습니다.')
          return
        }
        const postRaw = isRecord(res.value.post) ? res.value.post : res.value
        const post = decodeBoardPost(postRaw)
        if (!post) {
          if (!preserveOnError) setDetail(null)
          setDetailError('게시글 상세 파싱에 실패했습니다.')
          return
        }
        const rawComments = Array.isArray(res.value.comments)
          ? res.value.comments
          : Array.isArray(res.value.comment_context)
            ? res.value.comment_context
            : []
        const comments: BoardCommentItem[] = []
        const seenIds = new Set<string>()
        for (const c of rawComments) {
          const dec = decodeBoardComment(c)
          if (dec && !seenIds.has(dec.id)) {
            seenIds.add(dec.id)
            comments.push(dec)
          }
        }
        // Supplemental context contains ancestors and the requested comment. The
        // numeric page alone owns the forward cursor and loaded-row count.
        const focusedRaw = focusId && Array.isArray(res.value.comment_context)
          ? res.value.comment_context.find((row: unknown) => isRecord(row) && row.id === focusId && row.post_id === postId)
          : null
        let focusedComment = focusId
          ? comments.find((row) => row.id === focusId && row.postId === postId) ?? decodeBoardComment(focusedRaw)
          : null
        let commentPage = decodeCommentPageInfo(res.value.comment_page)

        // When refreshing a post that already had multiple pages loaded, if the
        // server capped `comment_limit` below `targetLoadedCount`, continue
        // fetching contiguous pages until the entire previously read range is
        // restored. On any continuation error or cursor mismatch, preserve the
        // existing detail & reading window and surface an error rather than
        // silently replacing with a truncated prefix.
        let prevExpectedOffset = 0
        while (
          samePost
          && !resetWindow
          && comments.length < targetLoadedCount
          && commentPage !== null
          && commentPage.nextOffset !== null
          && commentPage.nextOffset > prevExpectedOffset
        ) {
          const expectedOffset = commentPage.nextOffset
          const pageParams = new URLSearchParams({
            format: 'flat',
            comment_limit: String(COMMENT_PAGE_LIMIT),
            comment_offset: String(expectedOffset),
          })
          const nextRes = await apiGet<unknown>(
            `/api/v1/board/${encodeURIComponent(postId)}?${pageParams}`,
            { signal },
          )
          if (signal?.aborted || seq !== detailSeqRef.current) return
          if (!nextRes.ok) {
            if (nextRes.error.kind === 'aborted' || nextRes.error.kind === 'epoch_stale') return
            setDetailError(`게시글 상세/댓글 조회 실패: ${nextRes.error.message}`)
            return
          }
          if (!isRecord(nextRes.value)) {
            setDetailError('게시글 댓글 페이지 응답 형식이 올바르지 않아 기존 목록을 유지합니다.')
            return
          }
          const nextPage = decodeCommentPageInfo(nextRes.value.comment_page)
          if (nextPage !== null && nextPage.offset !== expectedOffset) {
            setDetailError('게시글 댓글 페이지 순서가 어긋나 기존 목록을 유지합니다.')
            return
          }
          const nextRaw = Array.isArray(nextRes.value.comments) ? nextRes.value.comments : []
          let added = 0
          for (const c of nextRaw) {
            const dec = decodeBoardComment(c)
            if (dec && !seenIds.has(dec.id)) {
              seenIds.add(dec.id)
              comments.push(dec)
              added += 1
            }
          }
          commentPage = nextPage
          prevExpectedOffset = expectedOffset
          if (focusId && !focusedComment) {
            focusedComment = comments.find((row) => row.id === focusId && row.postId === postId) ?? null
          }
          if (added === 0 || nextPage === null || nextPage.nextOffset === null || nextPage.nextOffset <= expectedOffset) {
            break
          }
        }

        if (signal?.aborted || seq !== detailSeqRef.current) return
        if (resetWindow) {
          setCommentWindowStart(0)
        } else {
          setCommentWindowStart((cur) => Math.min(cur, Math.max(0, comments.length - MAX_RENDERED_COMMENTS)))
        }
        setDetail({ post, comments, commentPage, focusedComment })
      } finally {
        if (seq === detailSeqRef.current) {
          detailRefreshingRef.current = false
          setDetailRefreshing(false)
        }
      }
    },
    [],
  )

  useEffect(() => {
    const boardTopics = new Set(['board', 'board_post', 'board_comment', 'board_changed', 'notifications/board'])
    let timer: ReturnType<typeof setTimeout> | null = null
    let pendingCommentReload = false
    const unsub = subscribeObserverFrames((frame) => {
      const topics = extractObserverTopics(frame)
      if (!topics.some((t) => boardTopics.has(t))) return
      const eventPostId = isRecord(frame.data)
        ? (asNonEmptyString(frame.data.post_id)
          ?? (isRecord(frame.data.payload) ? asNonEmptyString(frame.data.payload.post_id) : null))
        : null
      const activeNow = selectedPostIdRef.current
      if (
        topics.includes('board_comment')
        && (!eventPostId || (activeNow !== null && eventPostId === activeNow))
      ) {
        pendingCommentReload = true
      }
      if (timer) return
      timer = setTimeout(() => {
        timer = null
        const reloadDetail = pendingCommentReload
        pendingCommentReload = false
        void loadBoard('sse')
        const activeId = selectedPostIdRef.current
        if (reloadDetail && activeId && authSession.peek().kind !== 'multi_account_signed_in') {
          detailAbortRef.current?.abort()
          const ctrl = new AbortController()
          detailAbortRef.current = ctrl
          void loadPostDetail(activeId, ctrl.signal, { preserveOnError: true, resetWindow: false })
        }
      }, 450)
    })
    const unsubReconnect = subscribeObserverReconnect(() => {
      void loadBoard('sse')
    })
    return () => {
      unsub()
      unsubReconnect()
      if (timer) clearTimeout(timer)
    }
  }, [loadBoard, loadPostDetail])

  const activeDetail = detail && detail.post.id === selectedPostId ? detail : null

  const visibleComments = activeDetail?.comments.slice(commentWindowStart, commentWindowStart + MAX_RENDERED_COMMENTS) ?? []
  const focusedComment = activeDetail?.focusedComment
  if (focusedComment && !activeDetail?.comments.some((row) => row.id === focusedComment.id)) {
    visibleComments.push(focusedComment)
  }

  useEffect(() => {
    const view = replyViewRef.current
    if (!view?.scroll || view.postId !== activeDetail?.post.id) return
    const target = view.commentId === null ? commentsEndRef.current
      : activeDetail.focusedComment?.id === view.commentId ? focusedCommentRef.current : null
    if (target) {
      view.scroll = false
      target.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' })
    }
  }, [activeDetail])

  const handleLoadMoreComments = useCallback(async () => {
    if (
      !activeDetail
      || activeDetail.commentPage?.nextOffset == null
      || loadingMoreComments
      || detailRefreshingRef.current
    ) {
      return
    }
    loadMoreAbortRef.current?.abort()
    const ctrl = new AbortController()
    loadMoreAbortRef.current = ctrl
    const targetPostId = activeDetail.post.id
    const expectedSeq = detailSeqRef.current
    const expectedOffset = activeDetail.commentPage.nextOffset
    setLoadingMoreComments(true)
    setDetailError(null)
    try {
      const res = await apiGet<unknown>(
        `/api/v1/board/${encodeURIComponent(targetPostId)}?format=flat&comment_limit=${COMMENT_PAGE_LIMIT}&comment_offset=${expectedOffset}`,
        { signal: ctrl.signal },
      )
      if (
        ctrl.signal.aborted
        || selectedPostIdRef.current !== targetPostId
        || expectedSeq !== detailSeqRef.current
      ) {
        return
      }
      if (!res.ok) {
        if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
        setDetailError(`추가 댓글 조회 실패: ${res.error.message}`)
        return
      }
      if (!isRecord(res.value)) return
      const rawComments = Array.isArray(res.value.comments) ? res.value.comments : []
      const nextComments: BoardCommentItem[] = []
      for (const c of rawComments) {
        const dec = decodeBoardComment(c)
        if (dec) nextComments.push(dec)
      }
      const nextPage = decodeCommentPageInfo(res.value.comment_page)
      if (nextPage !== null && nextPage.offset !== expectedOffset) return
      let mergedLen = 0
      let applied = false
      setDetail((prev) => {
        if (!prev || prev.post.id !== targetPostId) return prev
        if (expectedSeq !== detailSeqRef.current) return prev
        // Verify contiguous page range: never append offset N onto a refreshed
        // state whose cursor moved elsewhere (which would permanently skip a gap).
        if (prev.commentPage?.nextOffset !== expectedOffset) return prev
        const seen = new Set(prev.comments.map((c) => c.id))
        const merged = [...prev.comments]
        for (const c of nextComments) {
          if (!seen.has(c.id)) {
            seen.add(c.id)
            merged.push(c)
          }
        }
        mergedLen = merged.length
        applied = true
        return { ...prev, comments: merged, commentPage: nextPage }
      })
      if (applied && mergedLen > MAX_RENDERED_COMMENTS) {
        setCommentWindowStart(Math.max(0, mergedLen - MAX_RENDERED_COMMENTS))
      }
    } finally {
      if (loadMoreAbortRef.current === ctrl) {
        setLoadingMoreComments(false)
      }
    }
  }, [activeDetail, loadingMoreComments])

  useEffect(() => {
    detailSeqRef.current += 1
    detailAbortRef.current?.abort()
    loadMoreAbortRef.current?.abort()
    detailRefreshingRef.current = false
    setDetailRefreshing(false)
    setLoadingMoreComments(false)
    setCommentWindowStart(0)
    setReplyParentId(null)
    setReplyText('')
    if (!selectedPostId) {
      setDetail(null)
      setDetailLoading(false)
      setDetailError(null)
      return
    }
    const ctrl = new AbortController()
    replyViewRef.current = { postId: selectedPostId, commentId: null, scroll: false }
    detailAbortRef.current = ctrl
    void loadPostDetail(selectedPostId, ctrl.signal, { preserveOnError: false, resetWindow: true })
    return () => {
      replyViewRef.current = null
      ctrl.abort()
      detailAbortRef.current?.abort()
      loadMoreAbortRef.current?.abort()
    }
  }, [selectedPostId, isMultiAccount, loadPostDetail])

  const foldedFeed = useMemo<readonly FoldedBoardEntry[]>(() => {
    const q = query.trim().toLowerCase()
    const visible = bundle.posts.filter((p) => {
      if (signalOnly && !p.isSignal) return false
      if (selectedHearth && p.hearth !== selectedHearth) return false
      if (q && !p.title.toLowerCase().includes(q) && !p.body.toLowerCase().includes(q) && !p.author.toLowerCase().includes(q)) {
        return false
      }
      return true
    })
    return foldSuccessionChains(visible)
  }, [bundle.posts, signalOnly, selectedHearth, query])

  const selectedListPost = useMemo(
    () => bundle.posts.find((p) => p.id === selectedPostId) ?? null,
    [bundle.posts, selectedPostId],
  )
  const activePost = detail?.post.id === selectedPostId ? detail.post : selectedListPost
  const activeEntry = useMemo(
    () => foldedFeed.find((e) => e.head.id === selectedPostId) ?? null,
    [foldedFeed, selectedPostId],
  )

  const refreshActiveDetail = async (postId: string) => {
    detailAbortRef.current?.abort()
    const ctrl = new AbortController()
    detailAbortRef.current = ctrl
    await loadPostDetail(postId, ctrl.signal, { preserveOnError: true, resetWindow: false })
  }

  const handleCreatePost = async (e: Event) => {
    e.preventDefault()
    if (!newTitle.trim() || !newBody.trim()) {
      setFeedback({ kind: 'err', message: '제목과 본문을 모두 입력하세요.' })
      return
    }
    setBusy(true)
    setFeedback(null)
    const body: Record<string, unknown> = {
      title: newTitle.trim(),
      content: newBody.trim(),
      author: 'operator',
    }
    if (newHearth.trim()) body.hearth = newHearth.trim()
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_board_post', body)
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `게시글 작성 실패: ${res.error.message}` })
      return
    }
    setNewTitle('')
    setNewBody('')
    setShowCreate(false)
    setFeedback({ kind: 'ok', message: '게시글을 작성했습니다.' })
    resourceCache.invalidateTopic('board')
    await loadBoard('manual')
  }

  const handleReply = async (e: Event) => {
    e.preventDefault()
    const view = replyViewRef.current
    if (!activePost || view?.postId !== activePost.id || !replyText.trim()) return
    setBusy(true)
    setFeedback(null)
    const body: Record<string, unknown> = {
      post_id: activePost.id,
      author: 'operator',
      content: replyText.trim(),
    }
    if (replyParentId) body.parent_id = replyParentId
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_board_comment', body)
    setBusy(false)
    if (view !== replyViewRef.current || selectedPostIdRef.current !== activePost.id) return
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `댓글 작성 실패: ${res.error.message}` })
      return
    }
    setReplyText('')
    setReplyParentId(null)
    setFeedback({ kind: 'ok', message: '댓글이 등록되었습니다.' })
    view.commentId = postedCommentId(res.value, activePost.id)
    view.scroll = true
    await refreshActiveDetail(activePost.id)
  }

  const handleVotePost = async (postId: string, direction: 'up' | 'down') => {
    setBusy(true)
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_board_vote', {
      post_id: postId,
      direction,
      voter: 'operator',
    })
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `투표 실패: ${res.error.message}` })
      return
    }
    resourceCache.invalidateTopic('board')
    await loadBoard('manual')
    if (selectedPostId === postId) await refreshActiveDetail(postId)
  }

  const handleVoteComment = async (commentId: string, direction: 'up' | 'down') => {
    setBusy(true)
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_board_comment_vote', {
      comment_id: commentId,
      direction,
      voter: 'operator',
    })
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `댓글 투표 실패: ${res.error.message}` })
      return
    }
    if (selectedPostId) await refreshActiveDetail(selectedPostId)
  }

  const handleToggleReaction = async (targetType: 'post' | 'comment', targetId: string, emoji: string) => {
    setBusy(true)
    const res = await apiMutate<unknown>('POST', '/api/v1/board/reactions', {
      target_type: targetType,
      target_id: targetId,
      emoji,
    })
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `반응 변경 실패: ${res.error.message}` })
      return
    }
    if (selectedPostId) await refreshActiveDetail(selectedPostId)
  }

  const handlePinPost = async (post: BoardPostItem) => {
    setBusy(true)
    const res = await apiMutate<unknown>('POST', '/api/v1/dashboard/board/pin', {
      post_id: post.id,
      pinned: !post.pinned,
    })
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `고정 변경 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: post.pinned ? '고정이 해제되었습니다.' : '게시글이 고정되었습니다.' })
    resourceCache.invalidateTopic('board')
    await loadBoard('manual')
    await refreshActiveDetail(post.id)
  }

  const handleDeletePost = async (postId: string) => {
    setBusy(true)
    const res = await apiMutate<unknown>('POST', '/api/v1/dashboard/board/delete', { post_id: postId })
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `게시글 삭제 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `게시글 ${postId} 삭제 완료` })
    setSelectedPostId(null)
    resourceCache.invalidateTopic('board')
    await loadBoard('manual')
  }

  const TOP_HEARTH_CHIP_LIMIT = 6
  const allHearthOptions = useMemo(() => {
    const sortedHearths = [...bundle.hearths]
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name))
      .map((h) => ({ key: `h:${h.name}`, value: h.name, label: `#${h.name}`, count: h.count, title: h.name }))
    const subBoardItems = bundle.subBoards.map((sb) => ({
      key: `sb:${sb.id}`,
      value: sb.slug,
      label: `/${sb.slug}`,
      count: sb.postCount,
      title: sb.description || sb.name,
    }))
    return [...sortedHearths, ...subBoardItems]
  }, [bundle.hearths, bundle.subBoards])

  const visibleHearthChips = useMemo(() => {
    const top = allHearthOptions.slice(0, TOP_HEARTH_CHIP_LIMIT)
    if (selectedHearth && !top.some((item) => item.value === selectedHearth)) {
      const activeOption = allHearthOptions.find((item) => item.value === selectedHearth)
      if (activeOption) return [...top, activeOption]
    }
    return top
  }, [allHearthOptions, selectedHearth])

  const overflowHearthCount = Math.max(0, allHearthOptions.length - TOP_HEARTH_CHIP_LIMIT)

  const masterPane = html`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <h2 class="kn-pane-title">Board <span class="kn-chip-count">(${foldedFeed.length})</span></h2>
        <div class="kn-actions">
          ${!isMultiAccount && html`
            <button type="button" class="btn-primary" onClick=${() => setShowCreate((v) => !v)}>
              ${showCreate ? '닫기' : '+ 새 글'}
            </button>
          `}
          <button type="button" class="btn-ghost" onClick=${() => void loadBoard('manual')}>새로고침</button>
        </div>
      </div>

      <div class="kn-filter-bar">
        <div class="kn-toolbar">
          <div class="kn-chips" role="group" aria-label="피드 신호 필터">
            <button
              type="button"
              class="kn-chip"
              aria-pressed=${signalOnly}
              onClick=${() => setSignalOnly(true)}
            >
              Signal Only
            </button>
            <button
              type="button"
              class="kn-chip"
              aria-pressed=${!signalOnly}
              onClick=${() => setSignalOnly(false)}
            >
              All Posts
            </button>
          </div>
          <select
            class="kn-select"
            value=${sortBy}
            onChange=${(e: Event) => setSortBy((e.target as HTMLSelectElement).value as 'recent' | 'hot' | 'trending' | 'discussed')}
            aria-label="정렬 기준"
          >
            <option value="recent">최신순</option>
            <option value="hot">인기순</option>
            <option value="trending">트렌딩</option>
            <option value="discussed">댓글순</option>
          </select>
        </div>

        <input
          type="search"
          class="kn-input"
          placeholder="제목, 본문, 작성자 검색…"
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          aria-label="게시판 검색"
        />

        ${allHearthOptions.length > 0 && html`
          <div class="kn-hearth-bar">
            <div class="kn-hearth-strip" role="group" aria-label="Hearth 및 Sub-board 필터">
              <button
                type="button"
                class="kn-chip"
                aria-pressed=${selectedHearth === ''}
                onClick=${() => setSelectedHearth('')}
              >
                전체 Hearth
              </button>
              ${visibleHearthChips.map((item) => html`
                <button
                  key=${item.key}
                  type="button"
                  class="kn-chip"
                  aria-pressed=${selectedHearth === item.value}
                  onClick=${() => setSelectedHearth(item.value)}
                  title=${item.title}
                >
                  ${item.label} <span class="kn-chip-count">${item.count}</span>
                </button>
              `)}
            </div>
            ${overflowHearthCount > 0 && html`
              <select
                class="kn-select kn-hearth-select"
                aria-label="전체 Hearth 선택"
                value=${selectedHearth}
                onChange=${(e: Event) => setSelectedHearth((e.target as HTMLSelectElement).value)}
              >
                <option value="">더보기 (+${overflowHearthCount})</option>
                ${allHearthOptions.map((item) => html`
                  <option key=${item.key} value=${item.value}>
                    ${item.label} (${item.count})
                  </option>
                `)}
              </select>
            `}
          </div>
        `}
      </div>

      ${showCreate && !isMultiAccount && html`
        <form class="kn-section kn-inset" onSubmit=${handleCreatePost}>
          <h3 class="kn-section-title">새 게시글 작성</h3>
          <input
            type="text"
            class="kn-input"
            required
            placeholder="제목"
            value=${newTitle}
            onInput=${(e: Event) => setNewTitle((e.target as HTMLInputElement).value)}
          />
          <input
            type="text"
            class="kn-input"
            placeholder="Hearth / Sub-board (선택, 예: engineering)"
            value=${newHearth}
            onInput=${(e: Event) => setNewHearth((e.target as HTMLInputElement).value)}
          />
          <textarea
            class="kn-textarea"
            required
            placeholder="Markdown 본문… (⌘↵ 게시)"
            value=${newBody}
            onInput=${(e: Event) => setNewBody((e.target as HTMLTextAreaElement).value)}
            onKeyDown=${(e: KeyboardEvent) => {
              if (e.isComposing || e.keyCode === 229) return
              if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !busy) {
                e.preventDefault()
                void handleCreatePost(e)
              }
            }}
          />
          <div class="kn-actions">
            <button type="submit" class="btn-primary" disabled=${busy}>게시</button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreate(false)}>취소</button>
          </div>
        </form>
      `}

      ${loadError && html`<div class="kn-notice kn-notice--err kn-inset" role="alert">${loadError}</div>`}

      ${(bundle.signalScanTruncated || bundle.hasMore || bundle.filteredOutCount > 0) && html`
        <div class="kn-notice kn-notice--info kn-inset" role="note">
          ${bundle.signalScanTruncated
            ? '신호 스캔 상한에 도달하여 일부 오래된 글이 생략되었을 수 있습니다.'
            : bundle.hasMore
              ? '피드에 추가 게시글이 더 있습니다 (최대 200건 표시).'
              : ''}
          ${bundle.filteredOutCount > 0
            ? `${bundle.signalScanTruncated || bundle.hasMore ? ' · ' : ''}시스템/비신호 글 ${bundle.filteredOutCount}건 숨김`
            : ''}
        </div>
      `}

      ${loading && bundle.posts.length === 0
        ? html`<div class="kn-detail-pad"><span class="dtable-absent">게시글 불러오는 중…</span></div>`
        : html`
            <${VirtualList}
              items=${foldedFeed}
              estimateSize=${84}
              height="100%"
              ariaLabel="게시판 목록"
              getItemKey=${(e: FoldedBoardEntry) => e.head.id}
              empty=${html`<div class="kn-detail-pad"><span class="dtable-absent">표시할 게시글이 없습니다.</span></div>`}
              renderItem=${(entry: FoldedBoardEntry) => {
                const p = entry.head
                return html`
                  <button
                    type="button"
                    class="kn-row-btn kn-board-row"
                    data-selected=${selectedPostId === p.id ? 'true' : 'false'}
                    onClick=${() => setSelectedPostId(p.id)}
                  >
                    <div class="kn-row-top">
                      <span class="kn-row-title">
                        ${p.pinned ? '📌 ' : ''}${p.title}
                      </span>
                      ${p.hearth && html`<span class="kn-badge">#${p.hearth}</span>`}
                    </div>
                    <div class="kn-row-meta">
                      <${KeeperBadge} id=${p.author} size="sm" />
                      <span class="tnum">▲ ${p.votes}</span>
                      <span class="tnum">💬 ${p.commentCount}</span>
                      <span>${formatRelativeTime(p.updatedAt || p.createdAt)}</span>
                      ${renderAudienceBadges(p.audience, true)}
                      ${entry.predecessors.length > 0 && html`
                        <span class="kn-badge kn-badge--info">계승 체인 +${entry.predecessors.length}</span>
                      `}
                    </div>
                  </button>
                `
              }}
            />
          `}
    </div>
  `

  const detailPane = activePost
    ? html`
        <div class="kn-detail-pad">
          ${feedback && html`<div class=${`kn-notice kn-notice--${feedback.kind}`} role="status">${feedback.message}</div>`}
          ${detailError && html`<div class="kn-notice kn-notice--err" role="alert">${detailError}</div>`}
          ${isMultiAccount && html`
            <div class="kn-notice kn-notice--info" role="note">
              멀티-계정 대시보드 세션: <code>/api/v1/dashboard/board</code> 읽기 전용 피드를 표시합니다. 댓글·반응·편집은 단일-사용자 로컬 세션에서 지원됩니다.
            </div>
          `}
          <div class="kn-section-head">
            <div class="kn-min-w-0">
              <div class="kn-row-meta">
                <${KeeperBadge} id=${activePost.author} size="sm" />
                ${activePost.hearth && html`<span class="kn-badge">#${activePost.hearth}</span>`}
                ${renderAudienceBadges(activePost.audience)}
                ${activePost.pinned && html`<span class="kn-badge kn-badge--info">Pinned</span>`}
                <span>${formatRelativeTime(activePost.createdAt)}</span>
                ${activePost.updatedAt && activePost.updatedAt !== activePost.createdAt && html`
                  <span>· 수정 ${formatRelativeTime(activePost.updatedAt)}</span>
                `}
              </div>
              <h2 class="kn-heading">${activePost.title}</h2>
            </div>
            ${!isMultiAccount && html`
              <div class="kn-actions">
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${busy}
                  onClick=${() => void handleVotePost(activePost.id, 'up')}
                >
                  ▲ ${activePost.votes}
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${busy}
                  onClick=${() => void handleVotePost(activePost.id, 'down')}
                  aria-label="비추천"
                >
                  ▼
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${busy}
                  onClick=${() => void handlePinPost(activePost)}
                >
                  ${activePost.pinned ? '고정 해제' : '고정'}
                </button>
                <button
                  type="button"
                  class="kn-btn-danger"
                  disabled=${busy}
                  onClick=${() => void handleDeletePost(activePost.id)}
                >
                  삭제
                </button>
              </div>
            `}
          </div>

          ${activeEntry && activeEntry.predecessors.length > 0 && html`
            <section class="kn-section" aria-label="접힌 계승 체인">
              <div class="kn-section-head">
                <span class="kn-section-title">Succession Chain (${activeEntry.predecessors.length}개 이전 글 접힘)</span>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => setExpandedChainHeads((prev) => ({
                    ...prev,
                    [activePost.id]: !prev[activePost.id],
                  }))}
                >
                  ${expandedChainHeads[activePost.id] ? '접기' : '이전 체인 펼치기'}
                </button>
              </div>
              ${expandedChainHeads[activePost.id] && html`
                <div class="kn-stack-1">
                  ${activeEntry.predecessors.map((pred) => html`
                    <button
                      key=${pred.id}
                      type="button"
                      class="kn-row-btn kn-card-row"
                      onClick=${() => setSelectedPostId(pred.id)}
                    >
                      <div class="kn-row-top">
                        <span class="kn-row-title">${pred.title}</span>
                        <span class="kn-badge kn-badge--idle">Superseded</span>
                      </div>
                      <div class="kn-row-meta">
                        <span class="mono">${pred.id}</span>
                        ${pred.closed?.summary && html`<span>${pred.closed.summary}</span>`}
                      </div>
                    </button>
                  `)}
                </div>
              `}
            </section>
          `}

          <article
            class="markdown-content"
            dangerouslySetInnerHTML=${{ __html: renderSanitizedMarkdown(activePost.body) }}
          />

          <${ReactionBar}
            reactions=${activePost.reactions}
            supportedEmojis=${activePost.supportedReactionEmojis}
            disabled=${busy || isMultiAccount}
            onToggle=${(emoji: string) => void handleToggleReaction('post', activePost.id, emoji)}
          />

          ${!isMultiAccount && html`
            <section class="kn-section" aria-label="댓글 스레드">
              <h3 class="kn-section-title">
                Comments (${activeDetail ? `${activeDetail.comments.length}${activeDetail.commentPage && activeDetail.commentPage.total > activeDetail.comments.length ? ` / ${activeDetail.commentPage.total}` : ''}` : activePost.commentCount})
              </h3>
              ${detailLoading && !activeDetail && html`<span class="dtable-absent">댓글 불러오는 중…</span>`}
              ${activeDetail && activeDetail.comments.length === 0 && html`<span class="dtable-absent">아직 댓글이 없습니다.</span>`}
              ${activeDetail && commentWindowStart > 0 && html`
                <div class="kn-actions">
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => setCommentWindowStart((s) => Math.max(0, s - MAX_RENDERED_COMMENTS))}
                  >
                    이전 댓글 보기 (${commentWindowStart}건 접힘)
                  </button>
                </div>
              `}
              ${visibleComments.map((c) => html`
                <div key=${c.id} ref=${c.id === focusedComment?.id ? focusedCommentRef : undefined} class=${`kn-comment ${c.parentId ? 'kn-comment--nested' : ''}`.trim()}>
                  <div class="kn-row-top">
                    <div class="kn-row-meta">
                      <${KeeperBadge} id=${c.author} size="sm" />
                      ${renderAudienceBadges(c.audience)}
                      <span>${formatRelativeTime(c.createdAt)}</span>
                    </div>
                    <div class="kn-actions">
                      <button type="button" class="btn-ghost kn-btn-compact" disabled=${busy} onClick=${() => void handleVoteComment(c.id, 'up')}>
                        ▲ ${c.votes}
                      </button>
                      <button type="button" class="btn-ghost kn-btn-compact" disabled=${busy} onClick=${() => void handleVoteComment(c.id, 'down')} aria-label="댓글 비추천">
                        ▼
                      </button>
                      <button
                        type="button"
                        class="btn-ghost kn-btn-compact"
                        onClick=${() => {
                          setReplyParentId(c.id)
                          queueMicrotask(() => {
                            replyTextareaRef.current?.focus()
                            replyTextareaRef.current?.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' })
                          })
                        }}
                      >
                        답글
                      </button>
                    </div>
                  </div>
                  <div
                    class="markdown-content kn-body-md"
                    dangerouslySetInnerHTML=${{ __html: renderSanitizedMarkdown(c.content) }}
                  />
                  <${ReactionBar}
                    reactions=${c.reactions}
                    supportedEmojis=${activePost.supportedReactionEmojis}
                    disabled=${busy}
                    onToggle=${(emoji: string) => void handleToggleReaction('comment', c.id, emoji)}
                  />
                </div>
              `)}
              ${activeDetail && (commentWindowStart + MAX_RENDERED_COMMENTS < activeDetail.comments.length) && html`
                <div class="kn-actions">
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => setCommentWindowStart((s) => Math.min(activeDetail.comments.length - MAX_RENDERED_COMMENTS, s + MAX_RENDERED_COMMENTS))}
                  >
                    다음 로드된 댓글 보기
                  </button>
                </div>
              `}
              ${activeDetail && activeDetail.commentPage && activeDetail.commentPage.nextOffset !== null && html`
                <div class="kn-actions">
                  <button
                    type="button"
                    class="btn-ghost"
                    disabled=${loadingMoreComments || detailRefreshing}
                    onClick=${() => void handleLoadMoreComments()}
                  >
                    ${loadingMoreComments
                      ? '댓글 불러오는 중…'
                      : `댓글 더 불러오기 (${activeDetail.comments.length} / ${activeDetail.commentPage.total})`}
                  </button>
                </div>
              `}

              <div ref=${commentsEndRef} />

              <form class="kn-reply-form" onSubmit=${handleReply}>
                ${replyParentId && html`
                  <div class="kn-notice kn-notice--info">
                    댓글 <span class="mono">${replyParentId}</span>에 답글 작성 중
                    <button type="button" class="btn-ghost kn-btn-ml" onClick=${() => setReplyParentId(null)}>
                      취소
                    </button>
                  </div>
                `}
                <textarea
                  ref=${replyTextareaRef}
                  class="kn-textarea kn-textarea--reply"
                  placeholder="댓글을 작성하세요 (Markdown 지원 · ⌘↵ 등록)…"
                  value=${replyText}
                  onInput=${(e: Event) => setReplyText((e.target as HTMLTextAreaElement).value)}
                  onKeyDown=${(e: KeyboardEvent) => {
                    if (e.isComposing || e.keyCode === 229) return
                    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !busy && replyText.trim()) {
                      e.preventDefault()
                      void handleReply(e)
                    }
                  }}
                />
                <div class="kn-actions">
                  <button type="submit" class="btn-primary" disabled=${busy || !replyText.trim()}>
                    댓글 등록
                  </button>
                </div>
              </form>
            </section>
          `}
        </div>
      `
    : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${activePost !== null}
      selectionKey=${selectedPostId}
      masterLabel="게시글 목록"
      detailLabel="게시글 상세"
      emptyDetail=${html`
        <div class="kn-detail-pad">
          ${selectedPostId
            ? (detailLoading || loading
                ? html`<span class="dtable-absent">게시글 불러오는 중…</span>`
                : html`<div class="kn-notice kn-notice--err" role="alert">${detailError ?? `게시글 ${selectedPostId}을 확인할 수 없습니다.`}</div>`)
            : html`<span class="dtable-absent">게시글을 선택하세요.</span>`}
        </div>
      `}
    />
  `
}

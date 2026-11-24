/**
 * `3 Knowledge > Board` Tab (`board-tab.ts`)
 *
 * - `MasterDetail` + `VirtualList` (zero eager 200-post DOM explosion).
 * - Signal-only default filter ON (matching TUI `#6`), toggleable to All.
 * - Sub-boards & Hearths filter (`/api/v1/board/hearths`, `/api/v1/board/sub-boards`).
 * - Succession Chain folding (closed posts with `successor_id` fold into head thread).
 * - Zero-count emoji reactions collapsed behind a single `[+☺]` trigger (`#29` V2!).
 * - Full CRUD: create post, reply/comment, upvote/downvote, react, pin, delete.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { markViewSynced } from '../../core/observer'
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
  type BoardCommentItem,
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
}

interface BoardDetailData {
  readonly post: BoardPostItem
  readonly comments: readonly BoardCommentItem[]
}

function ReactionBar(props: {
  readonly reactions: readonly BoardReactionSummary[]
  readonly supportedEmojis: readonly string[]
  readonly onToggle: (emoji: string) => void
  readonly disabled?: boolean
}) {
  const [pickerOpen, setPickerOpen] = useState(false)
  const { active, collapsedZero } = useMemo(
    () => partitionReactions(props.reactions, props.supportedEmojis),
    [props.reactions, props.supportedEmojis],
  )

  return html`
    <div class="kn-reactions">
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
  const [bundle, setBundle] = useState<BoardBundle>({ posts: [], hearths: [], subBoards: [] })
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
  const [expandedChainHeads, setExpandedChainHeads] = useState<Record<string, boolean>>({})

  // CRUD Forms
  const [showCreate, setShowCreate] = useState(false)
  const [newTitle, setNewTitle] = useState('')
  const [newBody, setNewBody] = useState('')
  const [newHearth, setNewHearth] = useState('')
  const [replyText, setReplyText] = useState('')
  const [replyParentId, setReplyParentId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [feedback, setFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)

  const loadBoard = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const params = new URLSearchParams({ sort_by: sortBy, limit: '200' })
    if (signalOnly) params.set('exclude_system', 'true')
    if (selectedHearth) params.set('hearth', selectedHearth)
    const cacheKey = `kn:board:${params.toString()}`

    const obs = await resourceCache.fetch<BoardBundle>(
      cacheKey,
      async (signal) => {
        const [postsRes, hearthsRes, subBoardsRes] = await Promise.all([
          apiGet<unknown>(`/api/v1/board?${params.toString()}`, { signal }),
          apiGet<unknown>('/api/v1/board/hearths', { signal }),
          apiGet<unknown>('/api/v1/board/sub-boards', { signal }),
        ])
        if (!postsRes.ok) return postsRes

        const posts: BoardPostItem[] = []
        if (isRecord(postsRes.value) && Array.isArray(postsRes.value.posts)) {
          for (const raw of postsRes.value.posts) {
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
        return ok({ posts, hearths, subBoards })
      },
      { ttlMs: 10_000, topics: ['board', 'board_post', 'board_comment'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setBundle(obs.data)
      markViewSynced()
      setSelectedPostId((prev) => {
        if (props.entityId && obs.data.posts.some((p) => p.id === props.entityId)) return props.entityId
        if (prev && obs.data.posts.some((p) => p.id === prev)) return prev
        return obs.data.posts[0]?.id ?? null
      })
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [sortBy, signalOnly, selectedHearth, props.entityId])

  useEffect(() => {
    void loadBoard('mount')
  }, [loadBoard])

  const loadPostDetail = useCallback(async (postId: string) => {
    setDetailLoading(true)
    const res = await apiGet<unknown>(`/api/v1/board/${encodeURIComponent(postId)}?format=flat&comment_limit=100`)
    setDetailLoading(false)
    if (!res.ok || !isRecord(res.value)) return
    const postRaw = isRecord(res.value.post) ? res.value.post : res.value
    const post = decodeBoardPost(postRaw)
    if (!post) return
    const rawComments = Array.isArray(res.value.comments)
      ? res.value.comments
      : Array.isArray(res.value.comment_context)
        ? res.value.comment_context
        : []
    const comments: BoardCommentItem[] = []
    for (const c of rawComments) {
      const dec = decodeBoardComment(c)
      if (dec) comments.push(dec)
    }
    setDetail({ post, comments })
  }, [])

  useEffect(() => {
    if (selectedPostId) {
      void loadPostDetail(selectedPostId)
    } else {
      setDetail(null)
    }
  }, [selectedPostId, loadPostDetail])

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
    if (!activePost || !replyText.trim()) return
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
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `댓글 작성 실패: ${res.error.message}` })
      return
    }
    setReplyText('')
    setReplyParentId(null)
    setFeedback({ kind: 'ok', message: '댓글이 등록되었습니다.' })
    await loadPostDetail(activePost.id)
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
    if (selectedPostId === postId) await loadPostDetail(postId)
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
    if (selectedPostId) await loadPostDetail(selectedPostId)
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
    if (selectedPostId) await loadPostDetail(selectedPostId)
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
    await loadPostDetail(post.id)
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

  const masterPane = html`
    <div style=${{ display: 'flex', flexDirection: 'column', height: '100%', minWidth: 0 }}>
      <div class="kn-pane-head">
        <h2 class="kn-pane-title">Board <span class="kn-chip-count">(${foldedFeed.length})</span></h2>
        <div class="kn-actions">
          <button type="button" class="btn-primary" onClick=${() => setShowCreate((v) => !v)}>
            ${showCreate ? '닫기' : '+ 새 글'}
          </button>
          <button type="button" class="btn-ghost" onClick=${() => void loadBoard('manual')}>새로고침</button>
        </div>
      </div>

      <div style=${{ padding: 'var(--sp-2) var(--sp-3)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', borderBottom: '1px solid var(--line-1)' }}>
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

        ${(bundle.hearths.length > 0 || bundle.subBoards.length > 0) && html`
          <div class="kn-chips" role="group" aria-label="Hearth 및 Sub-board 필터">
            <button
              type="button"
              class="kn-chip"
              aria-pressed=${selectedHearth === ''}
              onClick=${() => setSelectedHearth('')}
            >
              전체 Hearth
            </button>
            ${bundle.hearths.map((h) => html`
              <button
                key=${`h:${h.name}`}
                type="button"
                class="kn-chip"
                aria-pressed=${selectedHearth === h.name}
                onClick=${() => setSelectedHearth(h.name)}
              >
                #${h.name} <span class="kn-chip-count">${h.count}</span>
              </button>
            `)}
            ${bundle.subBoards.map((sb) => html`
              <button
                key=${`sb:${sb.id}`}
                type="button"
                class="kn-chip"
                aria-pressed=${selectedHearth === sb.slug}
                onClick=${() => setSelectedHearth(sb.slug)}
                title=${sb.description || sb.name}
              >
                /${sb.slug} <span class="kn-chip-count">${sb.postCount}</span>
              </button>
            `)}
          </div>
        `}
      </div>

      ${showCreate && html`
        <form class="kn-section" style=${{ margin: 'var(--sp-2)' }} onSubmit=${handleCreatePost}>
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
            placeholder="Markdown 본문…"
            value=${newBody}
            onInput=${(e: Event) => setNewBody((e.target as HTMLTextAreaElement).value)}
          />
          <div class="kn-actions">
            <button type="submit" class="btn-primary" disabled=${busy}>게시</button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreate(false)}>취소</button>
          </div>
        </form>
      `}

      ${loadError && html`<div class="kn-notice kn-notice--err" style=${{ margin: 'var(--sp-2)' }} role="alert">${loadError}</div>`}

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
                    class="kn-row-btn"
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
                      <span>${formatRelativeTime(p.createdAt)}</span>
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
          <div class="kn-section-head">
            <div style=${{ minWidth: 0 }}>
              <div class="kn-row-meta">
                <${KeeperBadge} id=${activePost.author} portrait=${true} size="sm" />
                ${activePost.hearth && html`<span class="kn-badge">#${activePost.hearth}</span>`}
                ${activePost.pinned && html`<span class="kn-badge kn-badge--info">Pinned</span>`}
                <span>${formatRelativeTime(activePost.createdAt)}</span>
              </div>
              <h2 style=${{ margin: '4px 0 0', fontSize: 'var(--fs-16)' }}>${activePost.title}</h2>
            </div>
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
                <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
                  ${activeEntry.predecessors.map((pred) => html`
                    <button
                      key=${pred.id}
                      type="button"
                      class="kn-row-btn"
                      style=${{ border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)' }}
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
            disabled=${busy}
            onToggle=${(emoji: string) => void handleToggleReaction('post', activePost.id, emoji)}
          />

          <section class="kn-section" aria-label="댓글 스레드">
            <h3 class="kn-section-title">Comments (${detail?.comments.length ?? activePost.commentCount})</h3>
            ${detailLoading && !detail && html`<span class="dtable-absent">댓글 불러오는 중…</span>`}
            ${detail && detail.comments.length === 0 && html`<span class="dtable-absent">아직 댓글이 없습니다.</span>`}
            ${detail && detail.comments.map((c) => html`
              <div key=${c.id} class=${`kn-comment ${c.parentId ? 'kn-comment--nested' : ''}`.trim()}>
                <div class="kn-row-top">
                  <div class="kn-row-meta">
                    <${KeeperBadge} id=${c.author} size="sm" />
                    <span>${formatRelativeTime(c.createdAt)}</span>
                  </div>
                  <div class="kn-actions">
                    <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-1) var(--sp-2)' }} disabled=${busy} onClick=${() => void handleVoteComment(c.id, 'up')}>
                      ▲ ${c.votes}
                    </button>
                    <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-1) var(--sp-2)' }} disabled=${busy} onClick=${() => void handleVoteComment(c.id, 'down')} aria-label="댓글 비추천">
                      ▼
                    </button>
                    <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-1) var(--sp-2)' }} onClick=${() => setReplyParentId(c.id)}>
                      답글
                    </button>
                  </div>
                </div>
                <div
                  class="markdown-content"
                  style=${{ fontSize: 'var(--fs-13)' }}
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

            <form style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', marginTop: 'var(--sp-2)' }} onSubmit=${handleReply}>
              ${replyParentId && html`
                <div class="kn-notice kn-notice--info">
                  댓글 <span class="mono">${replyParentId}</span>에 답글 작성 중
                  <button type="button" class="btn-ghost" style=${{ marginLeft: 'var(--sp-2)', padding: 'var(--sp-1) var(--sp-2)' }} onClick=${() => setReplyParentId(null)}>
                    취소
                  </button>
                </div>
              `}
              <textarea
                class="kn-textarea"
                style=${{ minHeight: '72px' }}
                placeholder="댓글을 작성하세요 (Markdown 지원)…"
                value=${replyText}
                onInput=${(e: Event) => setReplyText((e.target as HTMLTextAreaElement).value)}
              />
              <div class="kn-actions">
                <button type="submit" class="btn-primary" disabled=${busy || !replyText.trim()}>
                  댓글 등록
                </button>
              </div>
            </form>
          </section>
        </div>
      `
    : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${activePost !== null}
      masterLabel="게시글 목록"
      detailLabel="게시글 상세"
      emptyDetail=${html`<div class="kn-detail-pad"><span class="dtable-absent">게시글을 선택하세요.</span></div>`}
    />
  `
}

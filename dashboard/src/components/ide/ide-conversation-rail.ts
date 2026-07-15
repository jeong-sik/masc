import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { useSignalValue } from './use-signal-value'
import { fetchBoard } from '../../api/board'
import type { BoardPost } from '../../types/core'
import { bridgePostsToTrace } from './anchored-thread-trace-bridge'
import { unixishToMs } from '../../lib/format-time'
import { bridgeDecisionsToTrace } from './decision-log-trace-bridge'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import { KeeperBadge } from '../keeper-badge'
import {
  fetchKeeperDecisions,
  type KeeperDecision,
} from '../../api/dashboard'
import {
  createAnchoredThreadRailStore,
  type AnchoredThread,
  type ThreadKind,
} from './anchored-thread-rail-store'
import {
  AuditReplaySlider,
  filterReplayEvents,
  type AuditReplayEvent,
} from './audit-replay-slider'
import { publishIdeConversationThreads } from './ide-context-bridge'
import { ideReplayUntilMs, setIdeReplayUntilMs } from './ide-replay-state'
import { activeIdeFile, focusIdeContextAnchor, normalizeIdeContextFilePath } from './ide-state'
import { activeKeeperName } from '../../keeper-state'
import { globalPresenceSnapshot, PRESENCE_DOT, presenceEntries, type KeeperPresenceEntry } from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursorOverlay } from './keeper-cursor-overlay'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  routeRefsFromText,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { IDE_INLINE_BADGE_BASE } from './context-badge-style'

function postAuthorId(post: BoardPost): string {
  return post.author_identity?.id ?? post.author ?? '(unknown author)'
}

const KIND_LABEL: Record<ThreadKind, string> = {
  flag: 'FLAG',
  question: 'QUESTION',
  approve: 'APPROVE',
  note: 'NOTE',
  suggest: 'SUGGEST',
}

const KIND_TOKEN: Record<ThreadKind, string> = {
  flag: 'var(--color-status-err)',
  question: 'var(--color-status-info)',
  approve: 'var(--color-status-ok)',
  note: 'var(--color-fg-muted)',
  suggest: 'var(--color-status-warn)',
}
const CONVERSATION_CONTEXT_BADGE_STYLE = {
  ...IDE_INLINE_BADGE_BASE,
  background: 'var(--color-bg-surface)',
}

const EMPTY_POSTS: ReadonlyArray<BoardPost> = []
const EMPTY_DECISIONS: ReadonlyArray<KeeperDecision> = []

interface ConversationContextSummary {
  readonly label: string
  readonly title: string
}

type ReplayRailItem =
  | { readonly source: 'thread'; readonly timestamp_ms: number; readonly post: BoardPost }
  | { readonly source: 'decision'; readonly id: string; readonly timestamp_ms: number; readonly decision: KeeperDecision }

async function fetchBoardPosts(): Promise<ReadonlyArray<BoardPost>> {
  try {
    const { posts } = await fetchBoard(undefined, { excludeSystem: true, excludeAutomation: true })
    return posts
  } catch {
    return EMPTY_POSTS
  }
}

async function fetchKeeperDecisionEvents(): Promise<ReadonlyArray<KeeperDecision>> {
  try {
    return (await fetchKeeperDecisions(200)).events
  } catch {
    return EMPTY_DECISIONS
  }
}

function parseIsoToMs(iso: string): number {
  return new Date(iso).getTime()
}

function parseThreadKind(hearth: string): ThreadKind | null {
  switch (hearth.toLowerCase()) {
    case 'approve': return 'approve'
    case 'flag': return 'flag'
    case 'question': return 'question'
    case 'suggest': return 'suggest'
    case 'note': return 'note'
    default: return null
  }
}

export function boardKindFromPost(post: BoardPost): ThreadKind {
  if (post.hearth) {
    const kind = parseThreadKind(post.hearth)
    if (kind !== null) return kind
  }
  return 'note'
}

export function IdeConversationRail() {
  const threadStore = useMemo(() => createAnchoredThreadRailStore(activeIdeFile.value), [])
  const [posts, setPosts] = useState<ReadonlyArray<BoardPost>>(EMPTY_POSTS)
  const [decisions, setDecisions] = useState<ReadonlyArray<KeeperDecision>>(EMPTY_DECISIONS)
  const [focusedId, setFocusedId] = useState<string | null>(null)
  const [replayUntilMs, setReplayUntilMs] = useState<number | null>(ideReplayUntilMs.value)
  const [activeFile, setActiveFile] = useState(activeIdeFile.value)
  const [keeperName, setKeeperName] = useState(activeKeeperName.value)
  const [, bumpThreads] = useState(0)
  useSignalValue(globalPresenceSnapshot)
  useSignalValue(cursorOverlaySignal)
  useEffect(() => {
    const unsub = ideReplayUntilMs.subscribe(value => setReplayUntilMs(value))
    return () => unsub()
  }, [])

  useEffect(() => {
    let cancelled = false
    void Promise.all([
      fetchBoardPosts(),
      fetchKeeperDecisionEvents(),
    ]).then(([nextPosts, nextDecisions]) => {
      if (cancelled) return
      setPosts(nextPosts)
      setDecisions(nextDecisions)
    })
    return () => { cancelled = true }
  }, [])
  useEffect(() => {
    const unsub = activeIdeFile.subscribe(file => setActiveFile(file))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = activeKeeperName.subscribe(name => setKeeperName(name))
    return () => unsub()
  }, [])
  useEffect(() => {
    const publish = () => {
      publishIdeConversationThreads(threadStore.filePath(), threadStore.visibleThreads())
      bumpThreads((t: number) => t + 1)
    }
    const unsub = threadStore.subscribe(publish)
    publish()
    return () => unsub()
  }, [threadStore])
  useEffect(() => {
    threadStore.reset(activeFile)
    threadStore.seed(postsToAnchoredThreads(posts))
    publishIdeConversationThreads(threadStore.filePath(), threadStore.visibleThreads())
  }, [activeFile, posts, threadStore])
  useEffect(() => {
    threadStore.setReplayUntilMs(replayUntilMs)
    publishIdeConversationThreads(threadStore.filePath(), threadStore.visibleThreads())
  }, [replayUntilMs, threadStore])

  // RFC-0028 PR-δ anchored-thread producer: each fetched post becomes a
  // keeper-trace event the first time it is observed, deduplicated by id
  // across renders. The ref carries the cumulative known-id set so a
  // re-render with the same posts is a no-op.
  const knownPostIds = useRef<ReadonlySet<string>>(new Set())
  useEffect(() => {
    knownPostIds.current = bridgePostsToTrace(posts.map(postToTraceInput), knownPostIds.current)
  }, [posts])

  // RFC-0028 PR-δ-3 decision-log producer: each KeeperDecision becomes a
  // keeper-trace event the first time it is observed. Dedup key is
  // `decision:${keeper_name}:${ts_unix}:${event_type}` since the
  // KeeperDecision payload has no native id field.
  const knownDecisionKeys = useRef<ReadonlySet<string>>(new Set())
  useEffect(() => {
    knownDecisionKeys.current = bridgeDecisionsToTrace(decisions, knownDecisionKeys.current)
  }, [decisions])
  const replayItems = replayRailItems(posts, decisions)
  const replayEvents = replayEventsForItems(replayItems)
  const visibleItemIds = new Set(filterReplayEvents(replayEvents, replayUntilMs).map(event => event.id))
  const visibleItems = replayUntilMs === null || replayEvents.length === 0
    ? replayItems
    : replayItems.filter(item => visibleItemIds.has(replayItemId(item)))
  const visibleCounts = sourceCounts(visibleItems)
  const lineAnchoredThreads = threadStore.visibleThreads().filter(thread =>
    thread.anchor.line_start !== null,
  )

  const presence = globalPresenceSnapshot.value
  const entries: ReadonlyArray<KeeperPresenceEntry> = presenceEntries(presence)
  const overlay = cursorOverlaySignal.value

  return html`
    <div
      class="ide-rail-panel ide-conversation-panel v2-ide-panel"
      role="region"
      aria-label="REACTION THREAD"
    >
      <div
        class="ide-rail-head v2-ide-toolbar"
      >
        <span>REACTION THREAD</span>
        <span>
          ${visibleCounts.thread}/${posts.length} threads ·
          ${visibleCounts.decision}/${decisions.length} decisions
        </span>
      </div>
      <div class="ide-rail-scope v2-ide-row" aria-label="Keeper workspace scope">
        <span>${keeperName ? `@${keeperName}` : 'all keepers'}</span>
        <span title=${activeFile}>${activeFile}</span>
      </div>
      <div class="ide-rail-context-row v2-ide-row" aria-label="Conversation context anchors">
        <span>${threadStore.visibleThreads().length} file threads</span>
        <span>${lineAnchoredThreads.length} line anchors</span>
      </div>
      <${AuditReplaySlider}
        events=${replayEvents}
        value=${replayUntilMs}
        onChange=${setIdeReplayUntilMs}
      />
      <ol
        class="ide-rail-list"
      >
        ${visibleItems.length === 0
          ? html`<li class="ide-rail-empty v2-ide-row">no conversation activity</li>`
          : visibleItems.map(item => ReplayRailCard(
              item,
              focusedId,
              nextFocusedId => setFocusedId(focusedId === nextFocusedId ? null : nextFocusedId),
              entries,
              overlay,
            ))}
      </ol>
    </div>
  `
}

export function postsToAnchoredThreads(
  posts: ReadonlyArray<BoardPost>,
): ReadonlyArray<AnchoredThread> {
  return posts
    .map(postToAnchoredThread)
    .filter((thread): thread is AnchoredThread => thread !== null)
}

export function replayRailItems(
  posts: ReadonlyArray<BoardPost>,
  decisions: ReadonlyArray<KeeperDecision>,
): ReplayRailItem[] {
  return [
    ...posts.map(post => ({
      source: 'thread' as const,
      timestamp_ms: parseIsoToMs(post.created_at),
      post,
    })),
    ...decisions.map((decision, index) => ({
      source: 'decision' as const,
      id: `decision-${index}`,
      timestamp_ms: unixishToMs(decision.ts_unix),
      decision,
    })),
  ]
    .filter(event => Number.isFinite(event.timestamp_ms))
    .sort((left, right) => right.timestamp_ms - left.timestamp_ms)
}

function replayItemId(item: ReplayRailItem): string {
  return item.source === 'thread' ? item.post.id : item.id
}

function replayEventsForItems(items: ReadonlyArray<ReplayRailItem>): AuditReplayEvent[] {
  return items.map(item => ({
    id: replayItemId(item),
    timestamp_ms: item.timestamp_ms,
  }))
}

function postToAnchoredThread(post: BoardPost): AnchoredThread | null {
  const createdMs = parseIsoToMs(post.created_at)
  if (!Number.isFinite(createdMs)) return null
  const anchor = anchorFromPost(post)
  if (!anchor) return null
  return {
    id: post.id,
    kind: boardKindFromPost(post),
    author_keeper_id: postAuthorId(post),
    anchor,
    body: post.body || post.title || 'board thread',
    created_ms: createdMs,
    resolved: false,
    reply_count: Number.isSafeInteger(post.comment_count) ? Math.max(0, post.comment_count) : 0,
  }
}

function postToTraceInput(post: BoardPost) {
  const anchor = postToAnchoredThread(post)?.anchor ?? null
  return {
    id: post.id,
    created_at: post.created_at,
    author_identity: postAuthorId(post),
    filePath: anchor?.file_path ?? null,
    line: anchor?.line_start ?? null,
  }
}

function anchorFromPost(post: BoardPost): AnchoredThread['anchor'] | null {
  const text = `${post.title ?? ''}\n${post.body ?? ''}`
  const lineRef = text.match(/(?:^|\s)([A-Za-z0-9_./\\-]+\.[A-Za-z0-9_]+):([1-9][0-9]*)\b/)
  if (!lineRef) return null
  const filePath = normalizePostAnchorFilePath(lineRef[1]!)
  if (!filePath) return null
  const line = lineRef?.[2] ? Number.parseInt(lineRef[2], 10) : null
  return {
    file_path: filePath,
    line_start: line,
    line_end: line,
    symbol_hint: symbolHintFromText(text),
  }
}

function normalizePostAnchorFilePath(rawFilePath: string): string | null {
  const withoutDotPrefix = rawFilePath.trim().replace(/\\/g, '/').replace(/^(\.\/)+/, '')
  return normalizeIdeContextFilePath(withoutDotPrefix)
}

function symbolHintFromText(text: string): string | undefined {
  const match = text.match(/\b(fn|token|if|task|pr):([A-Za-z0-9_./-]+)/)
  if (!match) return undefined
  return `${match[1]}:${match[2]}`
}

function sourceCounts(items: ReadonlyArray<ReplayRailItem>) {
  return items.reduce(
    (acc, item) => ({ ...acc, [item.source]: acc[item.source] + 1 }),
    { thread: 0, decision: 0 },
  )
}

function ReplayRailCard(
  item: ReplayRailItem,
  focusedId: string | null,
  onFocus: (id: string) => void,
  entries: ReadonlyArray<KeeperPresenceEntry>,
  overlay: KeeperCursorOverlay,
) {
  if (item.source === 'thread') {
    return PostCard(
      item.post,
      focusedId === item.post.id,
      () => onFocus(item.post.id),
      entries,
      overlay,
    )
  }
  return DecisionCard(item, entries, overlay)
}

function PostCard(
  post: BoardPost,
  focused: boolean,
  onFocus: () => void,
  entries: ReadonlyArray<KeeperPresenceEntry>,
  overlay: KeeperCursorOverlay,
) {
  const kind = boardKindFromPost(post)
  const kindColor = KIND_TOKEN[kind]
  const keeperSlot = keeperHueIndex(postAuthorId(post))
  const keeperColor = `var(--color-keeper-${keeperSlot}-glow, var(--k-${keeperSlot}))`
  const createdMs = parseIsoToMs(post.created_at)
  const bodyText = post.body || post.title || ''
  const entry = entries.find(e => e.keeper_id === postAuthorId(post))
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = overlay.cursors.get(postAuthorId(post))
  const hasFocus = !!cursor && !!cursor.file_path && cursor.line >= 1
  const focusFile = hasFocus ? cursor.file_path.split('/').pop() : null
  const thread = postToAnchoredThread(post)
  const anchor = thread?.anchor ?? null
  const routeLinks = conversationRouteLinks(post, anchor, kind, bodyText)
  const contextSummary = conversationContextSummary(routeLinks)

  return html`
    <li class="ide-rail-item v2-ide-row">
      <button
        class="ide-conversation-card v2-ide-card"
        type="button"
        aria-current=${focused ? 'true' : undefined}
        onClick=${() => {
          onFocus()
          if (!anchor) return
          focusIdeContextAnchor({
            file_path: anchor.file_path,
            line: anchor.line_start ?? undefined,
            surface: KIND_LABEL[kind],
            label: bodyText || post.title || 'board thread',
            source_id: `thread-${post.id}`,
            keeper_id: postAuthorId(post) || undefined,
          }, 'operator')
        }}
        style=${{
          '--ide-conversation-bg': focused ? 'var(--color-bg-muted)' : 'var(--color-bg-elevated)',
          borderLeft: `2px solid ${keeperColor}`,
        }}
      >
        <div class="ide-conversation-meta">
          <span style=${{ fontSize: 'var(--fs-11)', color: kindColor, letterSpacing: '0.05em' }}>${KIND_LABEL[kind]}</span>
          <${KeeperBadge} id=${postAuthorId(post)} variant="full" size="sm" />
          ${statusDot ? html`
            <span
              role="status"
              aria-label=${`Author: ${statusDot.label}`}
              style=${{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '2px',
                fontSize: 'var(--fs-10)',
                fontWeight: 600,
                letterSpacing: '0.04em',
                color: statusDot.color,
              }}
            >
              <span style=${{
                width: '4px',
                height: '4px',
                borderRadius: '50%',
                background: statusDot.color,
                display: 'inline-block',
              }} />
              ${statusDot.label}
            </span>
          ` : null}
          ${contextSummary ? ConversationContextBadge(contextSummary) : null}
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)', marginLeft: 'auto' }}>${formatThreadTime(createdMs)}</span>
        </div>
        ${post.hearth ? html`
          <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
            ${post.hearth}
          </div>
        ` : null}
        <p class="ide-conversation-body">${bodyText}</p>
        ${hasFocus ? html`
          <span style=${{
            fontSize: 'var(--fs-10)',
            fontFamily: 'var(--font-mono)',
            color: 'var(--color-accent-fg)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            display: 'block',
          }}
          title=${cursor.file_path}
          >↗ ${focusFile}:${cursor.line}</span>
        ` : null}
        <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
          ${post.comment_count > 0 ? `${post.comment_count} replies · ` : ''}${(post.votes ?? 0) > 0 ? `${post.votes ?? 0} votes` : ''}
        </div>
      </button>
      ${routeLinks.length > 0 ? html`
        <div class="ide-conversation-route-links v2-ide-detail" aria-label="Conversation operational links">
          ${routeLinks.map(link => ConversationRouteLink(link))}
        </div>
      ` : null}
    </li>
  `
}

function conversationRouteLinks(
  post: BoardPost,
  anchor: AnchoredThread['anchor'] | null,
  kind: ThreadKind,
  bodyText: string,
): ReadonlyArray<IdeContextRouteLink> {
  const refs = routeRefsFromText(`${post.title ?? ''}\n${post.body ?? ''}\n${post.hearth ?? ''}`)
  const logId = refs.logId
  const sessionId = refs.sessionId
  const operationId = refs.operationId
  const workerRunId = refs.workerRunId
  return routeLinksForContext({
    filePath: anchor?.file_path,
    line: anchor?.line_start ?? refs.line,
    surface: KIND_LABEL[kind],
    label: bodyText || post.title || 'board thread',
    sourceId: `thread-${post.id}`,
    taskId: refs.taskId,
    boardPostId: post.id,
    commentId: refs.commentId,
    prId: refs.prId,
    gitRef: refs.gitRef,
    logId,
    sessionId,
    operationId,
    workerRunId,
    telemetryQuery: logId ?? sessionId ?? operationId ?? workerRunId,
    keeperId: postAuthorId(post) || undefined,
    telemetry: Boolean(logId || sessionId || operationId || workerRunId),
  })
}

function ConversationRouteLink(link: IdeContextRouteLink) {
  return html`
    <button
      key=${link.id}
      type="button"
      class="ide-conversation-route-link v2-ide-action"
      title=${link.evidence}
      aria-label=${`Open ${link.evidence}`}
      onClick=${() => openIdeContextRouteLink(link)}
    >
      ${link.label}
    </button>
  `
}

export function conversationContextSummary(
  links: ReadonlyArray<IdeContextRouteLink>,
): ConversationContextSummary | null {
  if (links.length === 0) return null
  return {
    label: `CTX ${links.length}`,
    title: `Linked context: ${links.map(link => link.label).join(', ')}`,
  }
}

function ConversationContextBadge(summary: ConversationContextSummary) {
  return html`
    <span
      class="ide-conversation-context-badge"
      title=${summary.title}
      aria-label=${summary.title}
      style=${CONVERSATION_CONTEXT_BADGE_STYLE}
    >${summary.label}</span>
  `
}

function DecisionCard(
  item: Extract<ReplayRailItem, { source: 'decision' }>,
  entries: ReadonlyArray<KeeperPresenceEntry>,
  overlay: KeeperCursorOverlay,
) {
  const decision = item.decision
  const keeper = decision.keeper_name || '(unknown keeper)'
  const hue = keeperHueIndex(keeper)
  const color = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  const summary = [
    decision.event_type,
    decision.outcome,
    decision.tool,
  ].filter(Boolean).join(' · ')
  const entry = entries.find(e => e.keeper_id === keeper)
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = overlay.cursors.get(keeper)
  const hasFocus = !!cursor && !!cursor.file_path && cursor.line >= 1
  const focusFile = hasFocus ? cursor.file_path.split('/').pop() : null
  const routeLinks = decisionRouteLinks(
    item,
    hasFocus ? cursor.file_path : undefined,
    hasFocus ? cursor.line : undefined,
    summary,
  )
  const contextSummary = conversationContextSummary(routeLinks)
  return html`
    <li class="v2-ide-row" style=${{ display: 'block' }}>
      <div
        class="v2-ide-card"
        data-replay-source="decision"
        style=${{
          display: 'grid',
          gap: 'var(--sp-1)',
          padding: 'var(--sp-2)',
          background: 'var(--color-bg-elevated)',
          border: '1px solid var(--color-border-default)',
          borderLeft: `2px solid ${color}`,
          borderRadius: 'var(--r-2)',
        }}
      >
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-status-info)', letterSpacing: '0.05em' }}>DECISION</span>
          <${KeeperBadge} id=${keeper} variant="full" size="sm" />
          ${statusDot ? html`
            <span
              role="status"
              aria-label=${`Author: ${statusDot.label}`}
              style=${{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '2px',
                fontSize: 'var(--fs-10)',
                fontWeight: 600,
                letterSpacing: '0.04em',
                color: statusDot.color,
              }}
            >
              <span style=${{
                width: '4px',
                height: '4px',
                borderRadius: '50%',
                background: statusDot.color,
                display: 'inline-block',
              }} />
              ${statusDot.label}
            </span>
          ` : null}
          ${contextSummary ? ConversationContextBadge(contextSummary) : null}
          <span style=${{ marginLeft: 'auto', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${formatThreadTime(item.timestamp_ms)}</span>
        </div>
        <p style=${{ margin: 0, color: 'var(--color-fg-secondary)', fontSize: 'var(--fs-12)' }}>${summary || 'decision event'}</p>
        ${hasFocus ? html`
          <span style=${{
            fontSize: 'var(--fs-10)',
            fontFamily: 'var(--font-mono)',
            color: 'var(--color-accent-fg)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
          title=${cursor.file_path}
          >↗ ${focusFile}:${cursor.line}</span>
        ` : null}
        ${routeLinks.length > 0 ? html`
          <div class="ide-conversation-route-links v2-ide-detail" aria-label="Decision operational links">
            ${routeLinks.map(link => ConversationRouteLink(link))}
          </div>
        ` : null}
      </div>
    </li>
  `
}

function decisionRouteLinks(
  item: Extract<ReplayRailItem, { source: 'decision' }>,
  filePath: string | undefined,
  line: number | undefined,
  summary: string,
): ReadonlyArray<IdeContextRouteLink> {
  const decision = item.decision
  const keeper = decision.keeper_name || '(unknown keeper)'
  return routeLinksForContext({
    filePath,
    line,
    surface: 'Decision',
    label: summary || decision.event_type || '(unknown decision event)',
    sourceId: `decision-${keeper}-${item.timestamp_ms}-${decision.event_type}`,
    keeperId: keeper,
    telemetry: true,
    telemetryQuery: decisionTelemetryQuery(decision, item.timestamp_ms),
  })
}

function decisionTelemetryQuery(decision: KeeperDecision, timestampMs: number): string {
  return compactRouteQuery([
    'decision',
    `keeper:${decision.keeper_name || '(unknown keeper)'}`,
    decision.event_type ? `event:${decision.event_type}` : null,
    decision.outcome ? `outcome:${decision.outcome}` : null,
    decision.tool ? `tool:${decision.tool}` : null,
    decision.model_used ? `model:${decision.model_used}` : null,
    Number.isFinite(timestampMs) ? `ts:${Math.floor(timestampMs / 1000)}` : null,
  ])
}

function compactRouteQuery(values: ReadonlyArray<string | null>): string {
  return values.filter((value): value is string => Boolean(value)).join(' ')
}

function formatThreadTime(ms: number): string {
  if (!Number.isFinite(ms)) return ''
  return new Date(ms).toISOString().slice(11, 19)
}

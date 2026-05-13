import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { bridgePostsToTrace } from './anchored-thread-trace-bridge'
import { bridgeCascadeEventsToTrace } from './cascade-hop-trace-bridge'
import { bridgeDecisionsToTrace } from './decision-log-trace-bridge'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import { KeeperBadge } from '../keeper-badge'
import {
  fetchKeeperDecisions,
  type KeeperDecision,
} from '../../api/dashboard'
import {
  fetchCascadeStrategyTrace,
  type CascadeStrategyTraceEvent,
} from '../../api/dashboard-cascade'
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
import { activeIdeFile, focusIdeContextAnchor, normalizeIdeContextFilePath } from './ide-state'
import { activeKeeperName } from '../../keeper-state'
import { globalPresenceSnapshot, PRESENCE_DOT, type KeeperPresenceEntry } from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursorOverlay } from './keeper-cursor-overlay'

export interface BoardPost {
  readonly id: string
  readonly title: string
  readonly body: string
  readonly author_identity: string
  readonly votes: number
  readonly comment_count: number
  readonly created_at_iso: string
  readonly hearth?: string | null
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

const EMPTY_POSTS: ReadonlyArray<BoardPost> = []
const EMPTY_DECISIONS: ReadonlyArray<KeeperDecision> = []
const EMPTY_CASCADE: ReadonlyArray<CascadeStrategyTraceEvent> = []

type ReplayRailItem =
  | { readonly source: 'thread'; readonly timestamp_ms: number; readonly post: BoardPost }
  | { readonly source: 'decision'; readonly id: string; readonly timestamp_ms: number; readonly decision: KeeperDecision }
  | { readonly source: 'cascade'; readonly id: string; readonly timestamp_ms: number; readonly cascade: CascadeStrategyTraceEvent }

async function fetchBoardPosts(): Promise<ReadonlyArray<BoardPost>> {
  try {
    const res = await fetch('/api/v1/board?limit=20&exclude_system=true&exclude_automation=true')
    if (!res.ok) return EMPTY_POSTS
    const data = await res.json()
    if (Array.isArray(data) && data.length > 0) return data as BoardPost[]
    return EMPTY_POSTS
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

async function fetchCascadeReplayEvents(): Promise<ReadonlyArray<CascadeStrategyTraceEvent>> {
  try {
    return (await fetchCascadeStrategyTrace({ limit: 200 })).events
  } catch {
    return EMPTY_CASCADE
  }
}

function parseIsoToMs(iso: string): number {
  return new Date(iso).getTime()
}

function unixishToMs(ts: number | null): number {
  if (ts === null || !Number.isFinite(ts)) return Number.NaN
  return ts > 1_000_000_000_000 ? ts : ts * 1000
}

function boardKindFromPost(post: BoardPost): ThreadKind {
  if (post.hearth) {
    switch (post.hearth.toLowerCase()) {
      case 'approve': return 'approve'
      case 'flag': return 'flag'
      case 'question': return 'question'
      case 'suggest': return 'suggest'
      case 'note': return 'note'
    }
  }
  const body = (post.body ?? '').toLowerCase()
  const title = (post.title ?? '').toLowerCase()
  const text = `${title} ${body}`
  if (text.includes('approve') || text.includes('ship it') || text.includes('looks good')) return 'approve'
  if (text.includes('flag') || text.includes('blocker') || text.includes('race condition')) return 'flag'
  if (text.includes('suggest') || text.includes('could you') || text.includes('recommend')) return 'suggest'
  if (text.includes('?') || text.includes('question') || text.includes('should')) return 'question'
  return 'note'
}

export function IdeConversationRailMock() {
  const threadStore = useMemo(() => createAnchoredThreadRailStore(activeIdeFile.value), [])
  const [posts, setPosts] = useState<ReadonlyArray<BoardPost>>(EMPTY_POSTS)
  const [decisions, setDecisions] = useState<ReadonlyArray<KeeperDecision>>(EMPTY_DECISIONS)
  const [cascadeEvents, setCascadeEvents] = useState<ReadonlyArray<CascadeStrategyTraceEvent>>(EMPTY_CASCADE)
  const [focusedId, setFocusedId] = useState<string | null>(null)
  const [replayUntilMs, setReplayUntilMs] = useState<number | null>(null)
  const [activeFile, setActiveFile] = useState(activeIdeFile.value)
  const [keeperName, setKeeperName] = useState(activeKeeperName.value)
  const [, forceRender] = useState(0)

  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => forceRender((t: number) => t + 1))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(() => forceRender((t: number) => t + 1))
    return () => unsub()
  }, [])

  useEffect(() => {
    let cancelled = false
    void Promise.all([
      fetchBoardPosts(),
      fetchKeeperDecisionEvents(),
      fetchCascadeReplayEvents(),
    ]).then(([nextPosts, nextDecisions, nextCascadeEvents]) => {
      if (cancelled) return
      setPosts(nextPosts)
      setDecisions(nextDecisions)
      setCascadeEvents(nextCascadeEvents)
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
      forceRender((t: number) => t + 1)
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
    knownPostIds.current = bridgePostsToTrace(posts, knownPostIds.current)
  }, [posts])

  // RFC-0028 PR-δ-2 cascade-hop producer: each cascade strategy_trace
  // event becomes a keeper-trace event the first time it is observed.
  // Dedup key is `cascade:${cascade_name}:${cycle}:${ts}` so a server
  // restart that resets cycle counters cannot collide with prior runs.
  const knownCascadeKeys = useRef<ReadonlySet<string>>(new Set())
  useEffect(() => {
    knownCascadeKeys.current = bridgeCascadeEventsToTrace(cascadeEvents, knownCascadeKeys.current)
  }, [cascadeEvents])

  // RFC-0028 PR-δ-3 decision-log producer: each KeeperDecision becomes a
  // keeper-trace event the first time it is observed. Dedup key is
  // `decision:${keeper_name}:${ts_unix}:${event_type}` since the
  // KeeperDecision payload has no native id field.
  const knownDecisionKeys = useRef<ReadonlySet<string>>(new Set())
  useEffect(() => {
    knownDecisionKeys.current = bridgeDecisionsToTrace(decisions, knownDecisionKeys.current)
  }, [decisions])
  const replayItems = replayRailItems(posts, decisions, cascadeEvents)
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
  const entries: ReadonlyArray<KeeperPresenceEntry> = presence?.entries ?? []
  const overlay = cursorOverlaySignal.value

  return html`
    <div
      class="ide-rail-panel ide-conversation-panel"
      role="region"
      aria-label="REACTION THREAD"
    >
      <div
        class="ide-rail-head"
      >
        <span>REACTION THREAD</span>
        <span>
          ${visibleCounts.thread}/${posts.length} threads ·
          ${visibleCounts.decision}/${decisions.length} decisions ·
          ${visibleCounts.cascade}/${cascadeEvents.length} cascade
        </span>
      </div>
      <div class="ide-rail-scope" aria-label="Keeper workspace scope">
        <span>${keeperName ? `@${keeperName}` : 'all keepers'}</span>
        <span title=${activeFile}>${activeFile}</span>
      </div>
      <div class="ide-rail-context-row" aria-label="Conversation context anchors">
        <span>${threadStore.visibleThreads().length} file threads</span>
        <span>${lineAnchoredThreads.length} line anchors</span>
      </div>
      <${AuditReplaySlider}
        events=${replayEvents}
        value=${replayUntilMs}
        onChange=${setReplayUntilMs}
      />
      <ol
        class="ide-rail-list"
      >
        ${visibleItems.length === 0
          ? html`<li class="ide-rail-empty">no conversation activity</li>`
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
  cascadeEvents: ReadonlyArray<CascadeStrategyTraceEvent>,
): ReplayRailItem[] {
  return [
    ...posts.map(post => ({
      source: 'thread' as const,
      timestamp_ms: parseIsoToMs(post.created_at_iso),
      post,
    })),
    ...decisions.map((decision, index) => ({
      source: 'decision' as const,
      id: `decision-${index}`,
      timestamp_ms: unixishToMs(decision.ts_unix),
      decision,
    })),
    ...cascadeEvents.map((cascade, index) => ({
      source: 'cascade' as const,
      id: `cascade-${index}`,
      timestamp_ms: unixishToMs(cascade.ts),
      cascade,
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
  const createdMs = parseIsoToMs(post.created_at_iso)
  if (!Number.isFinite(createdMs)) return null
  const anchor = anchorFromPost(post)
  if (!anchor) return null
  return {
    id: post.id,
    kind: boardKindFromPost(post),
    author_keeper_id: post.author_identity || 'keeper',
    anchor,
    body: post.body || post.title || 'board thread',
    created_ms: createdMs,
    resolved: false,
    reply_count: Number.isSafeInteger(post.comment_count) ? Math.max(0, post.comment_count) : 0,
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
  const match = text.match(/\b(fn|token|if|goal|task|pr):([A-Za-z0-9_./-]+)/)
  if (!match) return undefined
  return `${match[1]}:${match[2]}`
}

function sourceCounts(items: ReadonlyArray<ReplayRailItem>) {
  return items.reduce(
    (acc, item) => ({ ...acc, [item.source]: acc[item.source] + 1 }),
    { thread: 0, decision: 0, cascade: 0 },
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
  if (item.source === 'decision') {
    return DecisionCard(item, entries, overlay)
  }
  return CascadeCard(item)
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
  const keeperSlot = keeperHueIndex(post.author_identity)
  const keeperColor = `var(--color-keeper-${keeperSlot}-glow, var(--k-${keeperSlot}))`
  const createdMs = parseIsoToMs(post.created_at_iso)
  const bodyText = post.body || post.title || ''
  const entry = entries.find(e => e.keeper_id === post.author_identity)
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = overlay.cursors.get(post.author_identity)
  const hasFocus = !!cursor && !!cursor.file_path && cursor.line >= 1
  const focusFile = hasFocus ? cursor.file_path.split('/').pop() : null
  const thread = postToAnchoredThread(post)
  const anchor = thread?.anchor ?? null

  return html`
    <li class="ide-rail-item">
      <button
        class="ide-conversation-card"
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
            keeper_id: post.author_identity || undefined,
          })
        }}
        style=${{
          '--ide-conversation-bg': focused ? 'var(--color-bg-muted)' : 'var(--color-bg-elevated)',
          borderLeft: `2px solid ${keeperColor}`,
        }}
      >
        <div class="ide-conversation-meta">
          <span style=${{ fontSize: 'var(--fs-11)', color: kindColor, letterSpacing: '0.05em' }}>${KIND_LABEL[kind]}</span>
          <${KeeperBadge} id=${post.author_identity} variant="full" size="sm" />
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
    </li>
  `
}

function DecisionCard(
  item: Extract<ReplayRailItem, { source: 'decision' }>,
  entries: ReadonlyArray<KeeperPresenceEntry>,
  overlay: KeeperCursorOverlay,
) {
  const decision = item.decision
  const keeper = decision.keeper_name || 'keeper'
  const hue = keeperHueIndex(keeper)
  const color = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  const summary = [
    decision.event_type,
    decision.outcome,
    decision.model_used,
    decision.tool,
  ].filter(Boolean).join(' · ')
  const entry = entries.find(e => e.keeper_id === keeper)
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = overlay.cursors.get(keeper)
  const hasFocus = !!cursor && !!cursor.file_path && cursor.line >= 1
  const focusFile = hasFocus ? cursor.file_path.split('/').pop() : null
  return html`
    <li style=${{ display: 'block' }}>
      <div
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
      </div>
    </li>
  `
}

function CascadeCard(item: Extract<ReplayRailItem, { source: 'cascade' }>) {
  const event = item.cascade
  return html`
    <li style=${{ display: 'block' }}>
      <div
        data-replay-source="cascade"
        style=${{
          display: 'grid',
          gap: 'var(--sp-1)',
          padding: 'var(--sp-2)',
          background: 'var(--color-bg-elevated)',
          border: '1px solid var(--color-border-default)',
          borderLeft: '2px solid var(--color-accent-fg)',
          borderRadius: 'var(--r-2)',
        }}
      >
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-accent-fg)', letterSpacing: '0.05em' }}>CASCADE</span>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-secondary)' }}>${event.cascade_name}</span>
          <span style=${{ marginLeft: 'auto', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${formatThreadTime(item.timestamp_ms)}</span>
        </div>
        <p style=${{ margin: 0, color: 'var(--color-fg-secondary)', fontSize: 'var(--fs-12)' }}>
          ${event.strategy} · ${event.kind} · ${event.candidates_in}->${event.candidates_out}
        </p>
      </div>
    </li>
  `
}

function formatThreadTime(ms: number): string {
  if (!Number.isFinite(ms)) return ''
  return new Date(ms).toISOString().slice(11, 19)
}

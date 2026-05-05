import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  fetchKeeperDecisions,
  type KeeperDecision,
} from '../../api/dashboard'
import {
  fetchCascadeStrategyTrace,
  type CascadeStrategyTraceEvent,
} from '../../api/dashboard-cascade'
import type { ThreadKind } from './anchored-thread-rail-store'
import {
  AuditReplaySlider,
  filterReplayEvents,
  type AuditReplayEvent,
} from './audit-replay-slider'

interface BoardPost {
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
  const [posts, setPosts] = useState<ReadonlyArray<BoardPost>>(EMPTY_POSTS)
  const [decisions, setDecisions] = useState<ReadonlyArray<KeeperDecision>>(EMPTY_DECISIONS)
  const [cascadeEvents, setCascadeEvents] = useState<ReadonlyArray<CascadeStrategyTraceEvent>>(EMPTY_CASCADE)
  const [focusedId, setFocusedId] = useState<string | null>(null)
  const [replayUntilMs, setReplayUntilMs] = useState<number | null>(null)

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

  const replayItems = replayRailItems(posts, decisions, cascadeEvents)
  const replayEvents = replayEventsForItems(replayItems)
  const visibleItemIds = new Set(filterReplayEvents(replayEvents, replayUntilMs).map(event => event.id))
  const visibleItems = replayUntilMs === null || replayEvents.length === 0
    ? replayItems
    : replayItems.filter(item => visibleItemIds.has(replayItemId(item)))
  const visibleCounts = sourceCounts(visibleItems)

  return html`
    <div
      role="region"
      aria-label="CONVERSATION"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--color-bg-surface)',
        borderLeft: '1px solid var(--color-border-default)',
        minHeight: 0,
      }}
    >
      <div
        style=${{
          display: 'flex',
          justifyContent: 'space-between',
          padding: 'var(--sp-2) var(--sp-3)',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
          borderBottom: '1px solid var(--color-border-divider)',
        }}
      >
        <span>CONVERSATION</span>
        <span>
          ${visibleCounts.thread}/${posts.length} threads ·
          ${visibleCounts.decision}/${decisions.length} decisions ·
          ${visibleCounts.cascade}/${cascadeEvents.length} cascade
        </span>
      </div>
      <${AuditReplaySlider}
        events=${replayEvents}
        value=${replayUntilMs}
        onChange=${setReplayUntilMs}
      />
      <ol
        style=${{
          listStyle: 'none',
          padding: 'var(--sp-2)',
          margin: 0,
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-2)',
          overflow: 'auto',
        }}
      >
        ${visibleItems.map(item => ReplayRailCard(
          item,
          focusedId,
          nextFocusedId => setFocusedId(focusedId === nextFocusedId ? null : nextFocusedId),
        ))}
      </ol>
    </div>
  `
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

function sourceCounts(items: ReadonlyArray<ReplayRailItem>) {
  return items.reduce(
    (acc, item) => ({ ...acc, [item.source]: acc[item.source] + 1 }),
    { thread: 0, decision: 0, cascade: 0 },
  )
}

function ReplayRailCard(item: ReplayRailItem, focusedId: string | null, onFocus: (id: string) => void) {
  if (item.source === 'thread') {
    return PostCard(
      item.post,
      focusedId === item.post.id,
      () => onFocus(item.post.id),
    )
  }
  if (item.source === 'decision') {
    return DecisionCard(item)
  }
  return CascadeCard(item)
}

function PostCard(post: BoardPost, focused: boolean, onFocus: () => void) {
  const kind = boardKindFromPost(post)
  const kindColor = KIND_TOKEN[kind]
  const keeperSlot = keeperHueIndex(post.author_identity)
  const keeperColor = `var(--color-keeper-${keeperSlot}-glow, var(--k-${keeperSlot}))`
  const createdMs = parseIsoToMs(post.created_at_iso)
  const bodyText = post.body || post.title || ''

  return html`
    <li style=${{ display: 'block' }}>
      <button
        type="button"
        aria-current=${focused ? 'true' : undefined}
        onClick=${onFocus}
        style=${{
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-1)',
          width: '100%',
          padding: 'var(--sp-2)',
          background: focused ? 'var(--color-bg-muted)' : 'var(--color-bg-elevated)',
          border: '1px solid var(--color-border-default)',
          borderLeft: `2px solid ${keeperColor}`,
          borderRadius: 'var(--r-2)',
          color: 'inherit',
          textAlign: 'left',
          cursor: 'pointer',
        }}
      >
        <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)' }}>
          <span style=${{ fontSize: 'var(--fs-11)', color: kindColor, letterSpacing: '0.05em' }}>${KIND_LABEL[kind]}</span>
          <span style=${{ fontSize: 'var(--fs-11)', color: keeperColor }}>${post.author_identity}</span>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)', marginLeft: 'auto' }}>${formatThreadTime(createdMs)}</span>
        </div>
        ${post.hearth ? html`
          <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
            ${post.hearth}
          </div>
        ` : null}
        <p style=${{ font: 'var(--type-body)', color: 'var(--color-fg-secondary)', margin: 0 }}>${bodyText}</p>
        <div style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
          ${post.comment_count > 0 ? `${post.comment_count} replies · ` : ''}${post.votes > 0 ? `${post.votes} votes` : ''}
        </div>
      </button>
    </li>
  `
}

function DecisionCard(item: Extract<ReplayRailItem, { source: 'decision' }>) {
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
          <span style=${{ fontSize: 'var(--fs-11)', color }}>${keeper}</span>
          <span style=${{ marginLeft: 'auto', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${formatThreadTime(item.timestamp_ms)}</span>
        </div>
        <p style=${{ margin: 0, color: 'var(--color-fg-secondary)', fontSize: 'var(--fs-12)' }}>${summary || 'decision event'}</p>
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

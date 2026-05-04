import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  IDE_MOCK_FILE_PATH,
  IDE_MOCK_RELATED_LINE,
  IDE_MOCK_THREADS,
} from './ide-mock-data'
import type { AnchoredThread, ThreadKind } from './anchored-thread-rail-store'

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

interface BoardListResponse {
  readonly posts?: ReadonlyArray<BoardPost>
}

const KIND_LABEL: Record<ThreadKind, string> = {
  flag: 'FLAG',
  question: 'QUESTION',
  approve: 'APPROVE',
  note: 'NOTE',
  suggest: 'SUGGEST',
}

const KIND_TOKEN: Record<ThreadKind, string> = {
  flag: 'var(--color-status-err, var(--err))',
  question: 'var(--color-status-info, var(--info))',
  approve: 'var(--color-status-ok, var(--ok))',
  note: 'var(--color-fg-muted)',
  suggest: 'var(--color-status-warn, var(--warn))',
}

const FALLBACK_POSTS: ReadonlyArray<BoardPost> = [
  { id: 'p-mock-1', title: '', body: "flag: tool schema edge we're seeing in prod - keep tools[] and tool_choice paired.", author_identity: 'nick0cave', votes: 2, comment_count: 2, created_at_iso: '2026-05-02T01:41:18Z' },
  { id: 'p-mock-2', title: '', body: 'Should normalizeTools also handle tool_choice=none? feels like an edge case.', author_identity: 'operator', votes: 0, comment_count: 1, created_at_iso: '2026-05-02T01:39:02Z' },
  { id: 'p-mock-3', title: '', body: 'Budget guard reads well. Ship it when tests pass.', author_identity: 'operator', votes: 1, comment_count: 0, created_at_iso: '2026-05-02T01:22:41Z' },
  { id: 'p-mock-4', title: '', body: 'telemetry event name needs to match the lifeline schema - will rename later.', author_identity: 'operator', votes: 0, comment_count: 0, created_at_iso: '2026-05-02T01:18:04Z' },
  { id: 'p-mock-5', title: '', body: 'Could you collapse the rest-spread into a small helper? Same pattern appears in provider.ts.', author_identity: 'masc-improver', votes: 0, comment_count: 3, created_at_iso: '2026-05-02T01:14:52Z' },
]

async function fetchBoardPosts(): Promise<ReadonlyArray<BoardPost>> {
  try {
    const res = await fetch('/api/v1/board?limit=20&exclude_system=true&exclude_automation=true')
    if (!res.ok) return FALLBACK_POSTS
    const data = await res.json()
    if (Array.isArray(data) && data.length > 0) return data as BoardPost[]
    return FALLBACK_POSTS
  } catch {
    return FALLBACK_POSTS
  }
}

function parseIsoToMs(iso: string): number {
  return new Date(iso).getTime()
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
  const [posts, setPosts] = useState<ReadonlyArray<BoardPost>>(FALLBACK_POSTS)
  const [focusedId, setFocusedId] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    fetchBoardPosts().then(data => { if (!cancelled) setPosts(data) })
    return () => { cancelled = true }
  }, [])

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
        <span>${posts.length}</span>
      </div>
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
        ${posts.map(post => PostCard(
          post,
          focusedId === post.id,
          () => setFocusedId(focusedId === post.id ? null : post.id),
        ))}
      </ol>
    </div>
  `
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

function formatThreadTime(ms: number): string {
  if (!Number.isFinite(ms)) return ''
  return new Date(ms).toISOString().slice(11, 19)
}

import { afterEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { globalPresenceSnapshot, LOADING_SNAPSHOT } from './keeper-presence-store'
import {
  IdePresenceStrip,
  agentsToPresence,
  prLabel,
  unwrapEnvelope,
  type ApiAgent,
  type ApiStatus,
} from './ide-presence-strip'

describe('agentsToPresence', () => {
  const sampleAgent: ApiAgent = {
    name: 'nick0cave',
    status: 'idle',
    current_task: null,
    model: null,
  }

  it('returns disconnected snapshot when no status body arrived', () => {
    const snap = agentsToPresence([sampleAgent], undefined)
    expect(snap.kind).toBe('disconnected')
    if (snap.kind === 'disconnected') {
      expect(snap.reason).toBe('runtime_unknown')
    }
  })

  it('returns disconnected snapshot when status arrived but no agents present', () => {
    const status: ApiStatus = { project: 'ws' }
    const snap = agentsToPresence([], status)
    expect(snap.kind).toBe('disconnected')
    if (snap.kind === 'disconnected') {
      expect(snap.reason).toBe('no_agents')
    }
  })

  it('returns live snapshot named by the trimmed project when status and agents arrived', () => {
    const status: ApiStatus = { project: '  ws  ' }
    const snap = agentsToPresence([sampleAgent], status)
    expect(snap.kind).toBe('live')
    if (snap.kind === 'live') {
      expect(snap.runtime_id).toBe('ws')
      expect(snap.entries).toHaveLength(1)
      expect(snap.entries[0]?.workspace_label).toBe('nick0cave')
    }
  })

  // A null project (the JSON wire form of OCaml's [None]) must not crash the
  // render; the runtime still answered, so the strip is live.
  it('returns live snapshot when the project is null', () => {
    const status: ApiStatus = { project: null }
    const snap = agentsToPresence([sampleAgent], status)
    expect(snap.kind).toBe('live')
    if (snap.kind === 'live') expect(snap.runtime_id).toBe('')
  })
})

describe('unwrapEnvelope', () => {
  it('unwraps the {ok,data} envelope returned by /api/v1/status', () => {
    const raw = { ok: true, data: { project: 'ws' } }
    expect(unwrapEnvelope<ApiStatus>(raw)).toEqual({ project: 'ws' })
  })

  it('returns an already-unwrapped payload unchanged when no data key is present', () => {
    const raw = { project: 'ws' }
    expect(unwrapEnvelope<ApiStatus>(raw)).toEqual({ project: 'ws' })
  })

  it('returns undefined for null / non-object input', () => {
    expect(unwrapEnvelope<ApiStatus>(null)).toBeUndefined()
  })

  // Regression: the strip read fields off the raw {ok,data} envelope, so they
  // were always undefined. Unwrapping first must yield a live snapshot.
  it('feeds an enveloped status into agentsToPresence as a live runtime', () => {
    const envelope = { ok: true, data: { project: 'ws' } }
    const status = unwrapEnvelope<ApiStatus>(envelope)
    const agent: ApiAgent = { name: 'nick0cave', status: 'active', current_task: null, model: null }
    const snap = agentsToPresence([agent], status)
    expect(snap.kind).toBe('live')
    if (snap.kind === 'live') expect(snap.runtime_id).toBe('ws')
  })
})

describe('prLabel', () => {
  it('formats open PR with no decoration', () => {
    expect(prLabel(123, 'open')).toBe('#123')
  })

  it('formats closed PR with ✕ suffix', () => {
    expect(prLabel(456, 'closed')).toBe('#456✕')
  })

  it('formats merged PR with ✓ suffix', () => {
    expect(prLabel(789, 'merged')).toBe('#789✓')
  })

  it('falls back to plain "#N" for unknown state strings', () => {
    expect(prLabel(42, 'draft')).toBe('#42')
    expect(prLabel(42, 'unknown')).toBe('#42')
    expect(prLabel(42, '')).toBe('#42')
  })

  it('falls back to plain "#N" when state is null', () => {
    expect(prLabel(7, null)).toBe('#7')
  })
})

describe('IdePresenceStrip', () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
    globalPresenceSnapshot.value = LOADING_SNAPSHOT
  })

  function presencePayload(status: 'active' | 'idle') {
    return {
      ok: true,
      data: {
        runtime_id: 'masc-local',
        branch: 'main',
        entries: [{
          keeper_id: 'sangsu',
          workspace_label: 'masc',
          role: 'keeper',
          status,
          last_seen_ms: 1_000,
        }],
      },
    }
  }

  // The interject pill, activity lens, conversation rail, persistence map
  // and editor all read globalPresenceSnapshot. The strip is the one
  // always-mounted reader of /api/v1/ide/presence, so if it keeps what it
  // read to itself every one of those surfaces stays on `loading`.
  it('publishes the presence it reads and re-reads it on the poll cadence', async () => {
    vi.useFakeTimers()
    const statuses: Array<'active' | 'idle'> = ['active', 'idle']
    let call = 0
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/api/v1/ide/presence')) {
        const status = statuses[Math.min(call, statuses.length - 1)]!
        call += 1
        return new Response(JSON.stringify(presencePayload(status)), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ ok: true, data: {} }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', fetchMock)

    const container = document.createElement('div')
    render(h(IdePresenceStrip, { compact: true, pollMs: 1_000 }), container)

    await vi.waitFor(() => {
      const snap = globalPresenceSnapshot.value
      expect(snap.kind).toBe('live')
      if (snap.kind === 'live') expect(snap.entries[0]?.status).toBe('active')
    })
    await waitFor(() => {
      expect(container.querySelector('[data-state="live"]')).not.toBeNull()
    })

    await vi.advanceTimersByTimeAsync(1_000)
    await vi.waitFor(() => {
      const snap = globalPresenceSnapshot.value
      if (snap.kind !== 'live') throw new Error('presence is not live')
      expect(snap.entries[0]?.status).toBe('idle')
    })

    // A poll that reads the same presence does not wake every reader.
    const unchanged = globalPresenceSnapshot.value
    const callsBefore = call
    await vi.advanceTimersByTimeAsync(1_000)
    await vi.waitFor(() => expect(call).toBe(callsBefore + 1))
    expect(globalPresenceSnapshot.value).toBe(unchanged)

    render(null, container)
    const callsAtUnmount = call
    await vi.advanceTimersByTimeAsync(3_000)
    expect(call).toBe(callsAtUnmount)
  })
})

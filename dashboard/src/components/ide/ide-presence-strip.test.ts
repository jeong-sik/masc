import { publishDashboardObservationChange } from '../../lib/observation-refresh'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { globalPresenceSnapshot, resetGlobalPresenceSnapshot } from './keeper-presence-store'
import { IdePresenceStrip, prLabel } from './ide-presence-strip'

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
  beforeEach(() => {
    acceptedExecutionWorkspace.value = { epoch: 'presence-fixture', workspaceRoot: '/workspace',
      connectionGeneration: 0, observerInstanceId: 'presence-fixture' }
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
    resetGlobalPresenceSnapshot()
    acceptedExecutionWorkspace.value = null
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
  it('publishes presence once and re-reads it only for observation changes', async () => {
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
    render(h(IdePresenceStrip, { compact: true }), container)

    await vi.waitFor(() => {
      const snap = globalPresenceSnapshot.value
      expect(snap.kind).toBe('live')
      if (snap.kind === 'live') expect(snap.entries[0]?.status).toBe('active')
    })
    await waitFor(() => {
      expect(container.querySelector('[data-state="live"]')).not.toBeNull()
    })

    publishDashboardObservationChange({ topic: 'ide_presence' })
    await vi.advanceTimersByTimeAsync(0)
    await vi.waitFor(() => {
      const snap = globalPresenceSnapshot.value
      if (snap.kind !== 'live') throw new Error('presence is not live')
      expect(snap.entries[0]?.status).toBe('idle')
    })

    // An unchanged read does not wake every downstream reader.
    const unchanged = globalPresenceSnapshot.value
    const callsBefore = call
    publishDashboardObservationChange({ topic: 'ide_presence' })
    await vi.advanceTimersByTimeAsync(0)
    await vi.waitFor(() => expect(call).toBe(callsBefore + 1))
    expect(globalPresenceSnapshot.value).toBe(unchanged)

    await vi.advanceTimersByTimeAsync(60_000)
    expect(call).toBe(callsBefore + 1)
    render(null, container)
    const callsAtUnmount = call
    publishDashboardObservationChange({ topic: 'ide_presence' })
    await vi.advanceTimersByTimeAsync(3_000)
    expect(call).toBe(callsAtUnmount)
  })
})

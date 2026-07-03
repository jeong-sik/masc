import { describe, expect, it } from 'vitest'
import {
  agentsToPresence,
  presenceContextAnchor,
  presenceContextSummary,
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

  it('returns disconnected snapshot when cluster is undefined', () => {
    const status: ApiStatus = { cluster: undefined }
    const snap = agentsToPresence([sampleAgent], status)
    expect(snap.kind).toBe('disconnected')
  })

  // Regression: prior code only checked `status.cluster === undefined`, so a
  // JSON payload with `cluster: null` (the wire form of OCaml's [None]) hit
  // `null.trim()` and crashed the entire CODE / IDE-shell surface render.
  it('returns disconnected snapshot when cluster is null', () => {
    const status: ApiStatus = { cluster: null }
    const snap = agentsToPresence([sampleAgent], status)
    expect(snap.kind).toBe('disconnected')
    if (snap.kind === 'disconnected') {
      expect(snap.reason).toBe('runtime_unknown')
    }
  })

  it('returns disconnected snapshot when cluster is whitespace only', () => {
    const status: ApiStatus = { cluster: '   ' }
    const snap = agentsToPresence([sampleAgent], status)
    expect(snap.kind).toBe('disconnected')
  })

  it('returns disconnected snapshot when cluster is set but no agents present', () => {
    const status: ApiStatus = { cluster: 'masc-local' }
    const snap = agentsToPresence([], status)
    expect(snap.kind).toBe('disconnected')
    if (snap.kind === 'disconnected') {
      expect(snap.reason).toBe('no_agents')
    }
  })

  it('returns live snapshot with trimmed cluster id when both cluster and agents present', () => {
    const status: ApiStatus = { cluster: '  masc-local  ' }
    const snap = agentsToPresence([sampleAgent], status)
    expect(snap.kind).toBe('live')
    if (snap.kind === 'live') {
      expect(snap.runtime_id).toBe('masc-local')
      expect(snap.entries).toHaveLength(1)
      expect(snap.entries[0]?.workspace_label).toBe('nick0cave')
    }
  })
})

describe('unwrapEnvelope', () => {
  it('unwraps the {ok,data} envelope returned by /api/v1/status', () => {
    const raw = { ok: true, data: { cluster: 'default', project: 'me' } }
    expect(unwrapEnvelope<ApiStatus>(raw)).toEqual({ cluster: 'default', project: 'me' })
  })

  it('returns an already-unwrapped payload unchanged when no data key is present', () => {
    const raw = { cluster: 'default' }
    expect(unwrapEnvelope<ApiStatus>(raw)).toEqual({ cluster: 'default' })
  })

  it('returns undefined for null / non-object input', () => {
    expect(unwrapEnvelope<ApiStatus>(null)).toBeUndefined()
  })

  // Regression: the strip read status.cluster off the raw {ok,data} envelope,
  // so cluster was always undefined -> permanent runtime_unknown even while the
  // server reported a live cluster. Unwrapping first must yield a live snapshot.
  it('feeds an enveloped status into agentsToPresence as a live runtime', () => {
    const envelope = { ok: true, data: { cluster: 'default', project: 'me' } }
    const status = unwrapEnvelope<ApiStatus>(envelope) ?? {}
    const agent: ApiAgent = { name: 'nick0cave', status: 'active', current_task: null, model: null }
    const snap = agentsToPresence([agent], status)
    expect(snap.kind).toBe('live')
    if (snap.kind === 'live') expect(snap.runtime_id).toBe('default')
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

describe('presenceContextAnchor', () => {
  const entry = {
    keeper_id: 'nick0cave',
    workspace_label: 'wt-run-47',
    role: 'agent',
    status: 'active',
    last_seen_ms: 123,
  } as const

  it('builds code, telemetry, and keeper route links from a focused keeper chip', () => {
    const anchor = presenceContextAnchor({
      entry,
      cursor: {
        keeper_id: 'nick0cave',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 7,
        focus_mode: 'editing',
        last_update: 123,
        tool_name: 'ocamllsp',
      },
    })

    expect(anchor).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 42,
      surface: 'Keeper',
      label: 'nick0cave@wt-run-47',
      source_id: 'presence:nick0cave',
      keeper_id: 'nick0cave',
    })
    expect(anchor?.route_links?.map(link => link.label)).toEqual([
      'Code',
      'Telemetry',
      'Keeper',
    ])
    expect(anchor?.route_links?.find(link => link.label === 'Telemetry')?.params).toMatchObject({
      section: 'fleet-health',
      view: 'event-log',
      q: 'nick0cave',
    })
  })

  it('does not create a focus anchor for keepers without cursor file context', () => {
    expect(presenceContextAnchor({
      entry,
      cursor: undefined,
    })).toBeNull()
  })

  it('summarizes visible context coverage for keeper presence chips', () => {
    const anchor = presenceContextAnchor({
      entry,
      cursor: {
        keeper_id: 'nick0cave',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 7,
        focus_mode: 'editing',
        last_update: 123,
        tool_name: 'ocamllsp',
      },
    })

    expect(presenceContextSummary(anchor)).toEqual({
      label: 'CTX 3',
      title: 'Linked context: Code, Telemetry, Keeper',
    })
  })

  it('omits context coverage when no route links are available', () => {
    expect(presenceContextSummary(null)).toBeNull()
  })
})

import { describe, it, expect } from 'vitest'
import {
  blobMarkerOfOutput,
  deriveKeeperToolCallDossier,
  formatInput,
  groupToolCallTree,
  toolCallRouteLinks,
} from './keeper-tool-call-inspector'
import type { ToolCallEntry } from '../api/dashboard'

function toolCall(overrides: Partial<ToolCallEntry> = {}): ToolCallEntry {
  return {
    ts: 1,
    keeper: 'k',
    tool: 'keeper_context_status',
    input: {},
    output: 'ok',
    success: true,
    duration_ms: 5,
    ...overrides,
  }
}

describe('formatInput', () => {
  it('returns dash for null', () => {
    expect(formatInput(null)).toBe('-')
  })

  it('returns dash for undefined', () => {
    expect(formatInput(undefined)).toBe('-')
  })

  it('returns string as-is', () => {
    expect(formatInput('hello world')).toBe('hello world')
  })

  it('returns empty string as-is', () => {
    expect(formatInput('')).toBe('')
  })

  it('JSON-stringifies objects with pretty print', () => {
    const result = formatInput({ key: 'value' })
    expect(result).toBe('{\n  "key": "value"\n}')
  })

  it('JSON-stringifies arrays', () => {
    const result = formatInput([1, 2, 3])
    expect(result).toBe('[\n  1,\n  2,\n  3\n]')
  })

  it('JSON-stringifies numbers', () => {
    expect(formatInput(42)).toBe('42')
  })

  it('JSON-stringifies booleans', () => {
    expect(formatInput(true)).toBe('true')
    expect(formatInput(false)).toBe('false')
  })

  it('handles circular references gracefully via String fallback', () => {
    const obj: Record<string, unknown> = {}
    obj.self = obj
    // JSON.stringify throws on circular, falls back to String()
    const result = formatInput(obj)
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })
})

describe('blobMarkerOfOutput', () => {
  const sha = 'a'.repeat(64)

  it('extracts the marker from the normalized {_blob} descriptor', () => {
    const marker = blobMarkerOfOutput({
      _blob: { sha256: sha, bytes: 2237, mime: 'application/json', preview: '{"con' },
    })
    expect(marker).toEqual({
      sha256: sha,
      bytes: 2237,
      mime: 'application/json',
      preview: '{"con',
    })
  })

  it('extracts the marker from the legacy [masc:blob ...] string', () => {
    const raw = `[masc:blob sha256=${sha} bytes=2237 mime=application/json preview="{\\"con"]`
    const marker = blobMarkerOfOutput(raw)
    expect(marker?.sha256).toBe(sha)
    expect(marker?.bytes).toBe(2237)
  })

  it('returns null for inline string outputs', () => {
    expect(blobMarkerOfOutput('{"ok":true}')).toBeNull()
    expect(blobMarkerOfOutput('')).toBeNull()
  })
})

describe('groupToolCallTree', () => {
  const compositionChild = (overrides: Partial<ToolCallEntry> = {}): ToolCallEntry =>
    toolCall({
      composition_tool: 'keeper_compose_mission-snapshot',
      composition_run_id: 'run-1',
      composition_execution: 'inline',
      parent_tool_use_id: 'call_parent',
      ...overrides,
    })

  it('nests composition children under their composite parent', () => {
    const parent = toolCall({
      ts: 100,
      tool: 'keeper_compose_mission-snapshot',
      tool_use_id: 'call_parent',
    })
    const childBoard = compositionChild({ ts: 95, tool: 'masc_board_stats', composition_node_id: 'board' })
    const childClock = compositionChild({ ts: 90, tool: 'keeper_time_now', composition_node_id: 'clock' })

    // Newest-first display order, as the inspector passes it.
    const nodes = groupToolCallTree([parent, childBoard, childClock])

    expect(nodes).toHaveLength(1)
    expect(nodes[0]?.entry).toBe(parent)
    expect(nodes[0]?.children).toEqual([childBoard, childClock])
  })

  it('keeps children top-level when the parent row is outside the window', () => {
    const childBoard = compositionChild({ ts: 95, tool: 'masc_board_stats', composition_node_id: 'board' })
    const childClock = compositionChild({ ts: 90, tool: 'keeper_time_now', composition_node_id: 'clock' })

    const nodes = groupToolCallTree([childBoard, childClock])

    expect(nodes.map(node => node.entry)).toEqual([childBoard, childClock])
    expect(nodes.every(node => node.children.length === 0)).toBe(true)
  })

  it('attaches a run to the nearest parent at or after its newest child when provider ids repeat', () => {
    const lateParent = toolCall({ ts: 200, tool: 'keeper_compose_mission-snapshot', tool_use_id: 'call_dup' })
    const nearParent = toolCall({ ts: 100, tool: 'keeper_compose_mission-snapshot', tool_use_id: 'call_dup' })
    const staleParent = toolCall({ ts: 50, tool: 'keeper_compose_mission-snapshot', tool_use_id: 'call_dup' })
    const child = compositionChild({ ts: 90, tool: 'keeper_time_now', composition_node_id: 'clock', parent_tool_use_id: 'call_dup' })

    const nodes = groupToolCallTree([lateParent, nearParent, child, staleParent])

    expect(nodes.find(node => node.entry === nearParent)?.children).toEqual([child])
    expect(nodes.find(node => node.entry === lateParent)?.children).toEqual([])
    expect(nodes.find(node => node.entry === staleParent)?.children).toEqual([])
  })

  it('attaches an async run to the parent recorded at dispatch, before its children', () => {
    // Recorded async shape (.masc/tool_calls 2026-08-18): the composite
    // parent row is written at dispatch, so its ts precedes every child ts.
    const parent = toolCall({
      ts: 1_787_025_233.044336,
      tool: 'keeper_compose_mission-snapshot',
      tool_use_id: 'call_async',
    })
    const childClock = compositionChild({
      ts: 1_787_025_233.045521,
      tool: 'keeper_time_now',
      composition_node_id: 'clock',
      composition_execution: 'async',
      parent_tool_use_id: 'call_async',
    })
    const childBoard = compositionChild({
      ts: 1_787_025_233.045685,
      tool: 'masc_board_stats',
      composition_node_id: 'board',
      composition_execution: 'async',
      parent_tool_use_id: 'call_async',
    })

    const nodes = groupToolCallTree([childBoard, childClock, parent])

    expect(nodes).toHaveLength(1)
    expect(nodes[0]?.entry).toBe(parent)
    expect(nodes[0]?.children).toEqual([childBoard, childClock])
  })

  it('attaches an async run to its dispatch parent, not a later reuse of the provider id', () => {
    const dispatchParent = toolCall({ ts: 80, tool: 'keeper_compose_mission-snapshot', tool_use_id: 'call_dup' })
    const laterReuse = toolCall({ ts: 200, tool: 'keeper_compose_mission-snapshot', tool_use_id: 'call_dup' })
    const child = compositionChild({
      ts: 90,
      tool: 'keeper_time_now',
      composition_node_id: 'clock',
      composition_execution: 'async',
      parent_tool_use_id: 'call_dup',
    })

    const nodes = groupToolCallTree([laterReuse, child, dispatchParent])

    expect(nodes.find(node => node.entry === dispatchParent)?.children).toEqual([child])
    expect(nodes.find(node => node.entry === laterReuse)?.children).toEqual([])
  })

  it('leaves a run unattributed when every candidate sits strictly inside the child ts window', () => {
    // Neither recorded shape: the candidate is after the oldest child and
    // before the newest child, so attaching would be a guess.
    const interiorCandidate = toolCall({ ts: 95, tool: 'keeper_compose_mission-snapshot', tool_use_id: 'call_mid' })
    const childEarly = compositionChild({ ts: 90, tool: 'keeper_time_now', composition_node_id: 'clock', parent_tool_use_id: 'call_mid' })
    const childLate = compositionChild({ ts: 100, tool: 'masc_board_stats', composition_node_id: 'board', parent_tool_use_id: 'call_mid' })

    const nodes = groupToolCallTree([childLate, interiorCandidate, childEarly])

    expect(nodes.map(node => node.entry)).toEqual([childLate, interiorCandidate, childEarly])
    expect(nodes.every(node => node.children.length === 0)).toBe(true)
  })

  it('never joins on blank provider ids', () => {
    const parent = toolCall({ ts: 100, tool: 'keeper_compose_mission-snapshot', tool_use_id: '' })
    const child = compositionChild({ ts: 90, tool: 'keeper_time_now', parent_tool_use_id: '' })

    const nodes = groupToolCallTree([parent, child])

    expect(nodes.map(node => node.entry)).toEqual([parent, child])
    expect(nodes.every(node => node.children.length === 0)).toBe(true)
  })

  it('keeps plain rows as leaf nodes in display order', () => {
    const first = toolCall({ ts: 3, tool: 'Execute' })
    const second = toolCall({ ts: 2, tool: 'keeper_context_status' })

    const nodes = groupToolCallTree([first, second])

    expect(nodes.map(node => node.entry)).toEqual([first, second])
    expect(nodes.map(node => node.children)).toEqual([[], []])
  })
})

describe('deriveKeeperToolCallDossier outcome', () => {
  it('keeps a clean call clean and falls back to transport success', () => {
    const dossier = deriveKeeperToolCallDossier(
      [toolCall({ success: true })],
      null,
    )
    expect(dossier.headline).toBe('1 calls clean')
    expect(dossier.tone).toBe('ok')
  })
})

describe('latest call tone', () => {
  // The tone, the colour class and the glyph all read one resolver now.
  // These pin the three outcomes it can return, plus the empty case, so a
  // fourth outcome cannot land on one surface and miss the others.
  const latestTone = (entries: Parameters<typeof deriveKeeperToolCallDossier>[0]) =>
    deriveKeeperToolCallDossier(entries, null).cards.find(c => c.key === 'latest')?.tone

  it('reads ok for a successful call', () => {
    expect(latestTone([toolCall({ success: true })])).toBe('ok')
  })

  it('reads warn for a deferred call', () => {
    expect(latestTone([toolCall({ success: false, disposition: 'deferred' })])).toBe('warn')
  })

  it('reads bad for a failed call', () => {
    expect(latestTone([toolCall({ success: false })])).toBe('bad')
  })

  it('reads neutral when there is no call at all', () => {
    expect(latestTone([])).toBe('neutral')
  })
})

describe('toolCallRouteLinks', () => {
  it('promotes a Code link for a file target', () => {
    const links = toolCallRouteLinks(toolCall({
      action_radius: { target_kind: 'path', target_path: 'lib/keeper/keeper_meta.ml' },
    }))
    expect(links.some(l => Object.values(l.params).includes('lib/keeper/keeper_meta.ml')))
      .toBe(true)
  })

  it('does not promote a Code link for a directory target', () => {
    // Execute records its cwd here. Before masc#29013 it arrived as
    // target_kind "path" and this row opened a directory as if it were a file.
    const links = toolCallRouteLinks(toolCall({
      tool: 'Execute',
      action_radius: { target_kind: 'directory', target_path: 'repos/masc' },
    }))
    expect(links.some(l => Object.values(l.params).includes('repos/masc'))).toBe(false)
  })
})

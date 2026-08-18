import { describe, it, expect } from 'vitest'
import {
  blobMarkerOfOutput,
  deriveKeeperToolCallDossier,
  formatInput,
  groupToolCallTree,
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

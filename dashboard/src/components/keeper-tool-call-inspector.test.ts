import { describe, it, expect } from 'vitest'
import { blobMarkerOfOutput, deriveKeeperToolCallDossier, formatInput } from './keeper-tool-call-inspector'
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

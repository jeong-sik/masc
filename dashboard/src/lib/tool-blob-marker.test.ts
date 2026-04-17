import { describe, it, expect } from 'vitest'
import { parseToolBlobMarker, isToolBlobMarker } from './tool-blob-marker'

describe('isToolBlobMarker', () => {
  it('detects marker prefix + closing bracket', () => {
    const m = '[masc:blob sha256=' + 'a'.repeat(64) + ' bytes=12 mime=text/plain preview="hi"]'
    expect(isToolBlobMarker(m)).toBe(true)
  })

  it('rejects plain text', () => {
    expect(isToolBlobMarker('hello world')).toBe(false)
  })

  it('rejects partial prefix', () => {
    expect(isToolBlobMarker('[masc:blob')).toBe(false)
    expect(isToolBlobMarker('[masc:other ...]')).toBe(false)
  })

  it('rejects missing close bracket', () => {
    expect(isToolBlobMarker('[masc:blob sha256=...')).toBe(false)
  })
})

describe('parseToolBlobMarker', () => {
  const sha = 'a'.repeat(64)

  it('parses a simple marker', () => {
    const m = `[masc:blob sha256=${sha} bytes=128934 mime=text/plain preview="first line"]`
    const parsed = parseToolBlobMarker(m)
    expect(parsed).not.toBeNull()
    expect(parsed!.sha256).toBe(sha)
    expect(parsed!.bytes).toBe(128934)
    expect(parsed!.mime).toBe('text/plain')
    expect(parsed!.preview).toBe('first line')
  })

  it('lowercases sha256 for canonical comparison', () => {
    const upper = 'A'.repeat(64)
    const m = `[masc:blob sha256=${upper} bytes=10 mime=text/plain preview="x"]`
    const parsed = parseToolBlobMarker(m)
    expect(parsed!.sha256).toBe('a'.repeat(64))
  })

  it('decodes OCaml-style escapes in preview', () => {
    const m = `[masc:blob sha256=${sha} bytes=10 mime=text/plain preview="line1\\nline2\\twith\\\\backslash"]`
    const parsed = parseToolBlobMarker(m)
    expect(parsed!.preview).toBe('line1\nline2\twith\\backslash')
  })

  it('decodes embedded escaped quote', () => {
    const m = `[masc:blob sha256=${sha} bytes=10 mime=text/plain preview="he said \\"hi\\""]`
    const parsed = parseToolBlobMarker(m)
    expect(parsed!.preview).toBe('he said "hi"')
  })

  it('returns null for non-marker text', () => {
    expect(parseToolBlobMarker('plain text output')).toBeNull()
    expect(parseToolBlobMarker('{"json":"object"}')).toBeNull()
    expect(parseToolBlobMarker('[tool:gh id:x lines:1 chars:5 summary:"hi"]')).toBeNull()
  })

  it('returns null for malformed marker (missing field)', () => {
    const m = `[masc:blob sha256=${sha} bytes=10 preview="x"]` // missing mime
    expect(parseToolBlobMarker(m)).toBeNull()
  })

  it('returns null when sha256 is wrong length', () => {
    const m = `[masc:blob sha256=${sha.slice(0, 60)} bytes=10 mime=text/plain preview="x"]`
    expect(parseToolBlobMarker(m)).toBeNull()
  })

  it('returns null when sha256 contains non-hex chars', () => {
    const sha_bad = 'g'.repeat(64)
    const m = `[masc:blob sha256=${sha_bad} bytes=10 mime=text/plain preview="x"]`
    expect(parseToolBlobMarker(m)).toBeNull()
  })

  it('handles empty preview', () => {
    const m = `[masc:blob sha256=${sha} bytes=0 mime=text/plain preview=""]`
    const parsed = parseToolBlobMarker(m)
    expect(parsed!.preview).toBe('')
  })

  it('handles bytes=0', () => {
    const m = `[masc:blob sha256=${sha} bytes=0 mime=text/plain preview=""]`
    const parsed = parseToolBlobMarker(m)
    expect(parsed!.bytes).toBe(0)
  })
})

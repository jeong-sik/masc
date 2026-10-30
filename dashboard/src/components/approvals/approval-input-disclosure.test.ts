import { describe, expect, it } from 'vitest'
import { approvalInputDisclosure, decisionWaitsForFullInput } from './approval-input-disclosure'

// A tool input whose dangerous part sits after any plausible preview limit.
function longInput(limit: number) {
  const filler = 'a'.repeat(limit + 100)
  return { path: 'notes.txt', content: `${filler} && rm -rf /srv/data` }
}

// The server's cut: head of the compact JSON, whatever its length.
function cutPreview(input: unknown, limit: number): string {
  return `${JSON.stringify(input).slice(0, limit)}…`
}

describe('approvalInputDisclosure', () => {
  it('says the full input was not sent when the server sent none', () => {
    expect(approvalInputDisclosure({ input_preview: '{"path":"a"}' }).kind).toBe('full_input_not_sent')
    expect(approvalInputDisclosure({}).kind).toBe('full_input_not_sent')
  })

  it('treats a preview equal to the compact input as the whole input', () => {
    const input = { path: 'a.txt', mode: 'w' }
    expect(approvalInputDisclosure({ input, input_preview: JSON.stringify(input) }).kind).toBe('preview_is_whole')
  })

  it('exposes text past the preview limit, whatever that limit is', () => {
    for (const limit of [20, 200, 4000]) {
      const input = longInput(limit)
      const disclosure = approvalInputDisclosure({ input, input_preview: cutPreview(input, limit) })
      expect(disclosure.kind).toBe('preview_is_partial')
      if (disclosure.kind === 'preview_is_partial') {
        expect(disclosure.fullText).toContain('rm -rf /srv/data')
      }
    }
  })

  it('reads a string input as itself, with its line breaks', () => {
    const input = 'echo one\necho two'
    const disclosure = approvalInputDisclosure({ input, input_preview: 'echo one…' })
    expect(disclosure).toEqual({ kind: 'preview_is_partial', fullText: input })
  })

  it('counts a preview that only differs in form as partial, never as whole', () => {
    const input = { path: 'a.txt' }
    expect(approvalInputDisclosure({ input, input_preview: '{ "path": "a.txt" }' }).kind).toBe('preview_is_partial')
    expect(approvalInputDisclosure({ input, input_preview: null }).kind).toBe('preview_is_partial')
  })

  it('writes invisible and reordering characters out by code point', () => {
    const input = 'rm\u202E\u200B -rf /\uFEFF'
    const disclosure = approvalInputDisclosure({ input, input_preview: 'rm…' })
    expect(disclosure.kind).toBe('preview_is_partial')
    if (disclosure.kind === 'preview_is_partial') {
      expect(disclosure.fullText).toBe('rm\u27E6U+202E\u27E7\u27E6U+200B\u27E7 -rf /\u27E6U+FEFF\u27E7')
    }
  })

  it('keeps ordinary whitespace and non-Latin text as written', () => {
    const input = 'echo 안녕\n\tdone'
    const disclosure = approvalInputDisclosure({ input, input_preview: 'echo…' })
    expect(disclosure).toEqual({ kind: 'preview_is_partial', fullText: input })
  })

  it('treats a null input as sent', () => {
    expect(approvalInputDisclosure({ input: null, input_preview: 'null' }).kind).toBe('preview_is_whole')
  })
})

describe('decisionWaitsForFullInput', () => {
  const partial = { kind: 'preview_is_partial', fullText: 'x' } as const
  it('holds the decision only while a partial preview is unopened', () => {
    expect(decisionWaitsForFullInput(partial, false)).toBe(true)
    expect(decisionWaitsForFullInput(partial, true)).toBe(false)
    expect(decisionWaitsForFullInput({ kind: 'preview_is_whole' }, false)).toBe(false)
    expect(decisionWaitsForFullInput({ kind: 'full_input_not_sent' }, false)).toBe(false)
  })
})

import { describe, expect, it } from 'vitest'
import { decodePromptCapture, PROMPT_BLOCK_IDS, systemPromptBlocks } from './prompt-capture-wire'

// The shape of a real capture (`Keeper_prompt_capture.to_json` behind
// `handle_last_prompt_get`), with the text replaced: the base instructions and
// one System observation make the system prompt, joined by a two-byte
// separator; the other blocks are the extra context, `assembled`.
const span = (source: unknown, bytes: number) => ({
  source, offset: 0, bytes, sha256: 'a'.repeat(64), subpartition: { status: 'not_applicable' },
})
const capture = (overrides: Record<string, unknown> = {}) => ({
  keeper: 'muse',
  dashboard_surface: '/api/v1/keepers/:name/last-prompt',
  captured_at: 1795000000.25,
  trace_id: 'trace-one',
  absolute_turn: 7,
  blocks: [
    { id: 'keeper_instructions', bytes: 12, text: 'write well.\n' },
    { id: 'active_goals', bytes: 6, text: 'goal.\n' },
    { id: 'dynamic_context', bytes: 5, text: 'now.\n' },
  ],
  assembled: 'now.\n',
  assembled_bytes: 5,
  system_prompt: 'write well.\n\n\ngoal.\n',
  system_prompt_partition: {
    carrier: 'system_prompt',
    scope: 'canonical_issued_system_prompt_before_transport_projection',
    partition: {
      schema: 'masc.logical-context-partition.v2',
      scope: 'assembled_raw_utf8_before_message_or_ipc_encoding',
      bytes: 20,
      sha256: 'b'.repeat(64),
      spans: [
        span({ kind: 'unattributed', reason: 'existing_prefix' }, 12),
        span({ kind: 'unattributed', reason: 'separator' }, 2),
        span({ kind: 'block', block: 'active_goals' }, 6),
      ],
    },
  },
  ...overrides,
})

describe('last-prompt capture at the wire boundary', () => {
  it('reads the blocks in assembly order', () => {
    const decoded = decodePromptCapture(capture())
    expect(decoded.blocks.map(b => b.id)).toEqual(['keeper_instructions', 'active_goals', 'dynamic_context'])
    expect(decoded.absolute_turn).toBe(7)
    expect(decoded.system_prompt).toBe('write well.\n\n\ngoal.\n')
  })

  it('reads which blocks the system prompt carries from its partition', () => {
    expect([...systemPromptBlocks(decodePromptCapture(capture()))].sort()).toEqual(['active_goals', 'keeper_instructions'])
    expect(systemPromptBlocks(decodePromptCapture(capture({ system_prompt: null, system_prompt_partition: null }))).size).toBe(0)
  })

  it('refuses a system prompt without its partition, and a partition without its prompt', () => {
    expect(() => decodePromptCapture(capture({ system_prompt_partition: null }))).toThrow()
    expect(() => decodePromptCapture(capture({ system_prompt: null }))).toThrow()
  })

  it('reads every block id the server names', () => {
    const blocks = PROMPT_BLOCK_IDS.map(id => ({ id, bytes: 0, text: '' }))
    expect(decodePromptCapture(capture({ blocks })).blocks).toHaveLength(15)
  })

  it('refuses a block id it does not know and missing fields instead of filling them', () => {
    expect(() => decodePromptCapture(capture({ blocks: [{ id: 'block', bytes: 1, text: 'x' }] }))).toThrow()
    expect(() => decodePromptCapture(capture({ trace_id: undefined }))).toThrow()
    expect(() => decodePromptCapture(capture({ blocks: [{ id: 'dynamic_context', text: 'x' }] }))).toThrow()
    expect(() => decodePromptCapture({ error: 'this keeper has not assembled a turn since prompt capture existed' })).toThrow()
  })

  it('reads a capture with no assembled text', () => {
    expect(decodePromptCapture(capture({ assembled: null, assembled_bytes: 0, system_prompt: null, system_prompt_partition: null })).assembled).toBeNull()
  })
})

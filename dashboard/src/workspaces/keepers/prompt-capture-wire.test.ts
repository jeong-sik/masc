import { describe, expect, it } from 'vitest'
import { decodePromptCapture, PROMPT_BLOCK_IDS } from './prompt-capture-wire'

// The answer `Server_dashboard_http_keeper_prompt_reads.handle_last_prompt_get`
// writes: `Keeper_prompt_capture.to_json` with the keeper and surface prefixed.
const capture = (overrides: Record<string, unknown> = {}) => ({
  keeper: 'muse',
  dashboard_surface: '/api/v1/keepers/:name/last-prompt',
  captured_at: 1795000000.25,
  trace_id: 'trace-one',
  absolute_turn: 7,
  blocks: [
    { id: 'keeper_instructions', bytes: 12, text: 'write well.\n' },
    { id: 'dynamic_context', bytes: 5, text: 'now.\n' },
  ],
  assembled: 'write well.\nnow.\n',
  assembled_bytes: 17,
  system_prompt: 'write well.\n',
  system_prompt_partition: null,
  ...overrides,
})

describe('last-prompt capture at the wire boundary', () => {
  it('reads the blocks in assembly order', () => {
    const decoded = decodePromptCapture(capture())
    expect(decoded.blocks.map(b => b.id)).toEqual(['keeper_instructions', 'dynamic_context'])
    expect(decoded.absolute_turn).toBe(7)
    expect(decoded.system_prompt).toBe('write well.\n')
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
    expect(decodePromptCapture(capture({ assembled: null, assembled_bytes: 0, system_prompt: null })).assembled).toBeNull()
  })
})

import { afterEach, describe, expect, it, vi } from 'vitest'
import { get } from './core'
import { fetchKeeperToolCall, fetchKeeperToolCalls, fetchKeeperToolCallsByExecutionIds } from './dashboard-keeper-tool-calls'

vi.mock('./core', () => ({ get: vi.fn() }))
afterEach(() => { vi.clearAllMocks() })

const schema = 'masc.board-action-evidence/v1'
const comment = { schema, kind: 'comment_added', post_id: 'post-one', comment_id: 'comment-one',
  parent_id: null, author: 'reviewer' }
const reaction = { schema, kind: 'reaction_changed', post_id: 'post-one', target_type: 'comment',
  target_id: 'comment-one', user_id: 'reviewer', emoji: '👍', reacted: true }
const missing = Symbol('missing')

function rawEntry(evidence: unknown = missing, tool = 'masc_board_comment') {
  return { ts: 1, keeper: 'reviewer', trace_id: 'trace-one', keeper_turn_id: 7,
    execution_id: 'exec-one', tool, input: {}, output: JSON.stringify(comment),
    wire_outcome: 'error', disposition: 'failed',
    ...(evidence === missing ? {} : { board_action_evidence: evidence }) }
}

async function decode(evidence: unknown = missing, tool = 'masc_board_comment') {
  vi.mocked(get).mockResolvedValue({ keeper: 'reviewer', entries: [rawEntry(evidence, tool)] })
  return (await fetchKeeperToolCalls('reviewer')).entries[0]!
}

describe('producer Board action evidence', () => {
  it.each([
    { tool: 'masc_board_comment', evidence: comment },
    { tool: 'masc_board_comment', evidence: { ...comment, parent_id: 'parent-comment' } },
    { tool: 'masc_board_reaction', evidence: reaction },
    { tool: 'masc_board_reaction', evidence: { ...reaction, reacted: false } },
    { tool: 'masc_board_reaction', evidence: { ...reaction, target_type: 'post', target_id: 'post-one' } },
  ])('retains the exact committed fact independently of the response outcome: $tool', async ({ tool, evidence }) => {
    const entry = await decode(evidence, tool)
    expect(entry.board_action_evidence).toEqual(evidence)
    expect(entry.wire_outcome).toBe('error')
    expect(entry.disposition).toBe('failed')
  })

  it.each([
    null, [], 'comment_added',
    { ...comment, schema: 'other' },
    { ...comment, kind: 'no_action' },
    { ...comment, post_id: ' ' },
    { ...comment, comment_id: '' },
    { ...comment, parent_id: ' ' },
    { ...comment, author: '' },
    { ...comment, parent_id: undefined },
    { ...comment, extra: 'unrecognized field' },
    { schema, kind: 'invalid' },
  ])('keeps malformed or unavailable evidence distinct from missing evidence: %#', async evidence => {
    expect((await decode(evidence)).board_action_evidence).toEqual({ schema, kind: 'invalid' })
  })

  it.each([
    { ...reaction, target_type: 'unknown' },
    { ...reaction, target_type: 'post', target_id: 'different-post' },
    { ...reaction, target_id: '' },
    { ...reaction, user_id: ' ' },
    { ...reaction, emoji: '' },
    { ...reaction, reacted: 'false' },
    { ...reaction, extra: true },
  ])('refuses malformed reaction fields at the reserved reaction writer: %#', async evidence => {
    expect((await decode(evidence, 'masc_board_reaction')).board_action_evidence).toEqual({ schema, kind: 'invalid' })
  })

  it.each([
    { tool: 'addon_comment', evidence: comment },
    { tool: ' masc_board_comment ', evidence: comment },
    { tool: 'masc_board_reaction', evidence: comment },
    { tool: 'masc_board_comment', evidence: reaction },
  ])('does not accept metadata supplied by another tool: $tool', async ({ tool, evidence }) => {
    expect((await decode(evidence, tool)).board_action_evidence).toEqual({ schema, kind: 'invalid' })
  })

  it('does not infer a Board action from the tool name or a response containing an action', async () => {
    const raw = { ...rawEntry(), tool: 'masc_board_comment_add', wire_outcome: 'ok' }
    vi.mocked(get).mockResolvedValue({ keeper: 'reviewer', entries: [raw] })
    const entry = (await fetchKeeperToolCalls('reviewer')).entries[0]!
    expect(entry.board_action_evidence).toBeUndefined()
    expect(entry.output).toBe(JSON.stringify(comment))
  })

  it('also decodes the existing exact execution lookup', async () => {
    vi.mocked(get).mockResolvedValue({ keeper: 'reviewer', execution_id: 'exec-one', entry: rawEntry(comment) })
    const entry = await fetchKeeperToolCall('reviewer', 'exec-one')
    expect(entry.board_action_evidence).toEqual(comment)
    expect(get).toHaveBeenCalledWith('/api/v1/keepers/reviewer/tool-calls?execution_id=exec-one', { signal: undefined })
  })
})

describe('exact execution selection', () => {
  it('uses one abortable body-scoped Admin request beyond the recent tail and preserves duplicate rows', async () => {
    const ids = Array.from({ length: 205 }, (_, index) => `exec-${index}`)
    const row = { ...rawEntry(comment), execution_id: ids[0] }
    vi.mocked(get).mockResolvedValue({ keeper: 'reviewer', requested_execution_ids: ids, entries: [row, row] })
    const controller = new AbortController()
    const result = await fetchKeeperToolCallsByExecutionIds('reviewer', ids, { signal: controller.signal })
    expect(result.entries).toHaveLength(2)
    expect(result.entries[0]?.board_action_evidence).toEqual(comment)
    expect(get).toHaveBeenCalledOnce()
    const [path, options] = vi.mocked(get).mock.calls[0]!
    const url = new URL(String(path), 'http://dashboard.test')
    expect(url.pathname).toBe('/api/v1/keepers/reviewer/tool-calls')
    expect(JSON.parse(url.searchParams.get('execution_ids')!)).toEqual(ids)
    expect(options).toEqual({ signal: controller.signal, consumeWithinTimeout: true })
  })

  it.each([[], [' '], ['same', 'same']])('refuses an invalid request selection without HTTP: %#', async (...ids) => {
    await expect(fetchKeeperToolCallsByExecutionIds('reviewer', ids)).rejects.toThrow()
    expect(get).not.toHaveBeenCalled()
  })

  const row = { ...rawEntry(comment), execution_id: 'one' }
  const response = { keeper: 'reviewer', requested_execution_ids: ['one', 'two'], entries: [row] }
  it.each([
    { ...response, keeper: 'other' },
    { ...response, requested_execution_ids: ['two', 'one'] },
    { ...response, requested_execution_ids: ['one'] },
    { ...response, requested_execution_ids: ['one', 'one'] },
    { ...response, requested_execution_ids: [1, 'two'] },
    { ...response, entries: null },
    { ...response, entries: [null] },
    { ...response, entries: [{ ...row, execution_id: 'foreign' }] },
    { ...response, entries: [{ ...row, execution_id: ' one ' }] },
    { ...response, entries: [{ ...row, execution_id: undefined }] },
    { ...response, entries: [{ ...row, keeper: 'other' }] },
    { ...response, entries: [{ ...row, keeper: ' reviewer ' }] },
  ])('rejects a malformed echo or a row outside the requested authority: %#', async raw => {
    vi.mocked(get).mockResolvedValue(raw)
    await expect(fetchKeeperToolCallsByExecutionIds('reviewer', ['one', 'two'])).rejects.toThrow()
  })

  it('leaves a missing execution absent and propagates lookup refusal without making an empty success', async () => {
    vi.mocked(get).mockResolvedValue({ ...response, entries: [] })
    expect((await fetchKeeperToolCallsByExecutionIds('reviewer', ['one', 'two'])).entries).toEqual([])
    const refusal = new Error('403 forbidden')
    vi.mocked(get).mockRejectedValueOnce(refusal)
    await expect(fetchKeeperToolCallsByExecutionIds('reviewer', ['one', 'two'])).rejects.toBe(refusal)
  })
})

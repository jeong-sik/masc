import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import asyncFixture from '../../../test/fixtures/skill-ledger-async-actions.json'
import type { ToolCallEntry } from '../api/dashboard'
import { fetchKeeperToolCalls, fetchKeeperToolCallsByExecutionIds, type ToolCallsByExecutionIdsResponse } from '../api/dashboard-keeper-tool-calls'
import { ApiRequestError, get } from '../api/core'
import { ADMIN_REQUIRED_MESSAGE } from '../api/admin-required'
import { skillAsyncResultDeliverySha256 } from '../api/dashboard-tools-prompts'
import { fetchTurnFlow } from '../api/keeper-turn-flow'
import { parseKeeperRuntimeTrace } from '../api/keeper-runtime-trace'
import { decodePhysicalSkillEvidence, fetchPhysicalSkillEvidence } from '../api/keeper-physical-skill-evidence'
import { route } from '../router'
import { KeeperTurnFlow, turnBoardActionEvidence, turnToolEvidence } from './keeper-turn-flow'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'

vi.mock('../api/keeper-turn-flow', () => ({ fetchTurnFlow: vi.fn() }))
vi.mock('../api/core', async importOriginal => ({
  ...await importOriginal<typeof import('../api/core')>(), get: vi.fn(),
}))
vi.mock('../api/dashboard-keeper-tool-calls', async importOriginal => ({
  ...await importOriginal<typeof import('../api/dashboard-keeper-tool-calls')>(), fetchKeeperToolCallsByExecutionIds: vi.fn(),
}))
vi.mock('../api/keeper-physical-skill-evidence', async importOriginal => ({
  ...await importOriginal<typeof import('../api/keeper-physical-skill-evidence')>(), fetchPhysicalSkillEvidence: vi.fn(),
}))
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  acceptedExecutionWorkspace.value = null
})
beforeEach(() => {
  // Reads run only for an accepted workspace that names its Observer instance.
  acceptedExecutionWorkspace.value = { epoch: 'fixture', workspaceRoot: '/fixture/workspace',
    connectionGeneration: 1, observerInstanceId: 'fixture-instance' }
  vi.mocked(get).mockReset()
  vi.mocked(fetchKeeperToolCallsByExecutionIds).mockReset()
  vi.mocked(fetchKeeperToolCallsByExecutionIds).mockImplementation(async (keeper, ids) => ({
    keeper, requested_execution_ids: [...ids], entries: [],
  }))
})

const record = { keeper: 'reviewer', trace_id: 'trace-one', absolute_turn: 7,
  turn_ref: 'trace-one#7', execution_ids: ['exec-one'], blocks: [] }
const entry: ToolCallEntry = { ts: 1, keeper: 'reviewer', trace_id: 'trace-one', keeper_turn_id: 7,
  tool: 'Execute', execution_id: 'exec-one', input: {}, output: 'ok', wire_outcome: 'ok', duration_ms: 1 }
const boardComment: NonNullable<ToolCallEntry['board_action_evidence']> = {
  schema: 'masc.board-action-evidence/v1', kind: 'comment_added', post_id: 'post-one',
  comment_id: 'comment-one', parent_id: 'parent-one', author: 'reviewer',
}
const boardEntry = { ...entry, tool: 'masc_board_comment' }

function physicalEvidence() {
  return decodePhysicalSkillEvidence({
    schema: 'masc.dashboard.skill-physical-turn/v1', turn_ref: 'new-physical-trace#73',
    origins: [{ trace_id: asyncFixture.session_id, ledger_revision: asyncFixture.revision,
      activations: asyncFixture.activations, async_result_deliveries: asyncFixture.async_result_deliveries,
      async_actions: asyncFixture.async_actions }],
    coverage: { scope: 'complete_retained_trace_snapshot', sessions_inspected: 2, ledgers_loaded: 1, gaps: [] },
  }, 'new-physical-trace#73')
}

describe('tool evidence identity', () => {
  it('requires the selected execution and rejects foreign or duplicate rows', () => {
    expect(turnToolEvidence(record, [entry])[0]?.entry).toEqual(entry)
    expect(turnToolEvidence(record, [{ ...entry, execution_id: 'other' }])[0]?.entry).toBeUndefined()
    for (const wrong of [{ keeper: 'other' }, { trace_id: 'other' }, { keeper_turn_id: 8 }]) {
      expect(turnToolEvidence(record, [{ ...entry, ...wrong }])[0]?.entry).toBeUndefined()
    }
    expect(turnToolEvidence(record, [entry, entry])[0]?.entry).toBeUndefined()
  })

  it('requires every Board join identity without changing legacy tool evidence', () => {
    expect(turnBoardActionEvidence(record, [entry])[0]?.entry).toEqual(entry)
    for (const wrong of [
      { keeper: 'other' }, { keeper: '' }, { trace_id: 'other' }, { trace_id: undefined },
      { keeper_turn_id: 8 }, { keeper_turn_id: undefined }, { execution_id: 'other' },
      { execution_id: undefined },
    ]) {
      expect(turnBoardActionEvidence(record, [{ ...entry, ...wrong }])[0]?.entry).toBeUndefined()
    }
    expect(turnBoardActionEvidence(record, [entry, entry])[0]?.entry).toBeUndefined()
    expect(turnBoardActionEvidence({ ...record, execution_ids: ['exec-one', 'exec-one'] }, [entry])[0]?.entry).toBeUndefined()
    expect(turnBoardActionEvidence({ ...record, trace_id: '' }, [entry])[0]?.entry).toBeUndefined()
    expect(turnBoardActionEvidence({ ...record, turn_ref: '' }, [entry])[0]?.entry).toBeUndefined()
    const legacy = { ...entry, trace_id: undefined, keeper_turn_id: undefined }
    expect(turnToolEvidence(record, [legacy])[0]?.entry).toEqual(legacy)
    expect(turnBoardActionEvidence(record, [legacy])[0]?.entry).toBeUndefined()
  })
})

describe('same-turn Board actions', () => {
  beforeEach(() => {
    route.value = { tab: 'board', params: {}, postId: null }
    vi.mocked(fetchTurnFlow).mockResolvedValue({
      intake: { state: 'observed', channel: 'reactive', sources: ['one', 'two'].map(stimulusId => ({
        stimulusId, snapshotRef: 'a'.repeat(64), admittedRevision: '55',
        firstAdmittedAt: 100, sourceKind: 'board_attention',
      })) },
      outcomes: { state: 'unavailable', reason: 'receipt unavailable' },
      events: [], trace: parseKeeperRuntimeTrace({}),
    })
    vi.mocked(fetchPhysicalSkillEvidence).mockResolvedValue({ turnRef: record.turn_ref, origins: [],
      coverage: { scope: 'complete_retained_trace_snapshot', sessionsInspected: 0, ledgersLoaded: 0, gaps: [] } })
  })

  function renderBoard(entries: ToolCallEntry[], toolCallError: string | null = null, selected = record) {
    const view = render(html`<${KeeperTurnFlow} record=${selected} toolEntries=${entries}
      toolCallError=${toolCallError} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    return { view, board: within(view.getByRole('region', { name: '같은 턴의 Board 댓글·반응' })) }
  }

  function exactRows(entries: ToolCallEntry[], ids = record.execution_ids) {
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({
      keeper: record.keeper, requested_execution_ids: ids, entries,
    })
  }

  it('links a committed comment and its parent even when the tool response failed, without attributing it to an input', async () => {
    const row = { ...boardEntry, wire_outcome: 'error', disposition: 'failed',
      board_action_evidence: boardComment } as const
    exactRows([row])
    const { view, board } = renderBoard([row])
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy())
    await waitFor(() => expect(view.getByRole('region', { name: '입력 자극' }).textContent).toContain('board_attention'))
    expect(board.getByRole('link', { name: 'Board 글 post-one' }).getAttribute('href')).toBe('#board?post=post-one')
    expect(board.getByRole('link', { name: '부모 댓글 parent-one' }).getAttribute('href')).toBe('#board?post=post-one&comment=parent-one')
    expect(board.getByText('댓글 작성 · reviewer')).toBeTruthy()
    expect(board.getByText('도구 응답 error · 처리 상태 failed')).toBeTruthy()
    expect(board.getByText('trace-one#7 · exec-one')).toBeTruthy()
    expect(within(view.getByRole('region', { name: '입력 자극' })).queryAllByRole('link')).toHaveLength(0)
    expect(board.getAllByRole('link', { name: '댓글 comment-one' })).toHaveLength(1)
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, record.execution_ids,
      { signal: expect.any(AbortSignal) })
    fireEvent.click(board.getByRole('link', { name: '댓글 comment-one' }))
    expect(route.value.tab).toBe('board')
    expect(route.value.params).toMatchObject({ post: 'post-one', comment: 'comment-one' })
  })

  it.each([
    { target_type: 'post', target_id: 'post-one', reacted: true, label: '반응 추가' },
    { target_type: 'comment', target_id: 'comment-one', reacted: false, label: '반응 제거' },
  ] as const)('shows the recorded reaction change and exact Board target: $label', async change => {
    const row: ToolCallEntry = { ...entry, tool: 'masc_board_reaction', board_action_evidence: {
      schema: 'masc.board-action-evidence/v1', kind: 'reaction_changed', post_id: 'post-one',
      target_type: change.target_type, target_id: change.target_id, user_id: 'reviewer',
      emoji: '👍', reacted: change.reacted,
    } }
    exactRows([row])
    const { board } = renderBoard([row])
    await waitFor(() => expect(board.getByText(`${change.label} · 👍 · reviewer`)).toBeTruthy())
    expect(board.getByText(`${change.label} · 👍 · reviewer`)).toBeTruthy()
    const link = change.target_type === 'post'
      ? board.getByRole('link', { name: 'Board 글 post-one' })
      : board.getByRole('link', { name: '댓글 comment-one' })
    fireEvent.click(link)
    expect(route.value.params.post).toBe('post-one')
    expect(route.value.params.comment).toBe(change.target_type === 'comment' ? 'comment-one' : undefined)
  })

  it('keeps malformed metadata unavailable and missing metadata unrecorded without interpreting a response', async () => {
    const row: ToolCallEntry = { ...entry, tool: 'masc_board_comment_add',
      output: JSON.stringify(boardComment), board_action_evidence: { schema: 'masc.board-action-evidence/v1', kind: 'invalid' } }
    exactRows([row])
    const { view, board } = renderBoard([row])
    await waitFor(() => expect(board.getByText('Board 행동 기록 확인 불가')).toBeTruthy())
    expect(board.queryAllByRole('link')).toHaveLength(0)
    view.unmount()
    const missingRow = { ...boardEntry, output: JSON.stringify(boardComment) }
    exactRows([missingRow])
    const missing = renderBoard([missingRow])
    await waitFor(() => expect(missing.board.getByText('Board 댓글·반응 미기록 실행 1개')).toBeTruthy())
    expect(missing.board.queryAllByRole('link')).toHaveLength(0)
    expect(missing.board.getByText('기록이 없으면 댓글·반응 여부와 무응답 이유를 알 수 없습니다.')).toBeTruthy()
  })

  it.each(['Execute', 'Read'])('does not report missing Board evidence for an ordinary %s execution', async tool => {
    exactRows([{ ...entry, tool }])
    const { board } = renderBoard([{ ...entry, tool }])
    await waitFor(() => expect(board.queryByText('선택한 실행 기록 조회 중…')).toBeNull())
    expect(board.queryByText('Board 댓글·반응 미기록 실행 1개')).toBeNull()
    expect(board.queryByText('정확한 턴·실행 기록 미확인 1개')).toBeNull()
    expect(board.queryAllByRole('link')).toHaveLength(0)
  })

  it('refuses Board facts for an inconsistent turn ref even when the independent flow request fails', async () => {
    vi.mocked(fetchTurnFlow).mockRejectedValueOnce(new Error('turn_ref mismatch'))
    const selected = { ...record, turn_ref: 'foreign-trace#7' }
    const { view, board } = renderBoard([{ ...boardEntry, board_action_evidence: boardComment }], null, selected)
    await waitFor(() => expect(view.getByRole('region', { name: '입력 자극' }).textContent).toContain('turn_ref mismatch'))
    expect(fetchTurnFlow).toHaveBeenCalledWith({ keeper: record.keeper, traceId: record.trace_id,
      absoluteTurn: record.absolute_turn, turnRef: selected.turn_ref }, { signal: expect.any(AbortSignal) })
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
    expect(turnToolEvidence(selected, [entry])[0]?.entry).toEqual(entry)
  })

  it.each([
    [{ ...entry, trace_id: undefined, board_action_evidence: boardComment }],
    [{ ...entry, keeper_turn_id: undefined, board_action_evidence: boardComment }],
    [{ ...entry, keeper: 'other', board_action_evidence: boardComment }],
    [{ ...entry, board_action_evidence: boardComment }, { ...entry, board_action_evidence: boardComment }],
  ])('does not display a fact with missing, foreign or ambiguous execution identity: %#', async (...entries) => {
    exactRows(entries)
    const { board } = renderBoard(entries)
    await waitFor(() => expect(board.queryByText('선택한 실행 기록 조회 중…')).toBeNull())
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
  })

  it('keeps a tool-call access failure explicit', () => {
    const { board } = renderBoard([], '관리자 권한 필요')
    expect(board.getByText('도구 기록 조회 실패: 관리자 권한 필요')).toBeTruthy()
    expect(board.queryAllByRole('link')).toHaveLength(0)
  })

  it('does not promote a foreign Add-on metadata object to a Board writer fact', async () => {
    const row = { ...entry, tool: 'addon_comment', board_action_evidence: boardComment }
    exactRows([row])
    const { board } = renderBoard([row])
    await waitFor(() => expect(board.getByText('Board 행동 기록 확인 불가')).toBeTruthy())
    expect(board.queryAllByRole('link')).toHaveLength(0)
  })

  it('loads a selected older execution outside the recent 200 rows through the exact Admin door', async () => {
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({ keeper: record.keeper,
      requested_execution_ids: record.execution_ids, entries: [{ ...boardEntry, board_action_evidence: boardComment }] })
    const tail = Array.from({ length: 200 }, (_, index) => ({ ...entry,
      execution_id: `recent-${index}`, keeper_turn_id: index + 80 }))
    const { board } = renderBoard(tail)
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy())
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, ['exec-one'], { signal: expect.any(AbortSignal) })
  })

  it('resolves incomplete attribution without borrowing the legacy turn association', async () => {
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({ keeper: record.keeper,
      requested_execution_ids: record.execution_ids, entries: [{ ...boardEntry, board_action_evidence: boardComment }] })
    const { board } = renderBoard([{ ...boardEntry, trace_id: undefined, board_action_evidence: boardComment }])
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy())
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
  })

  it.each([
    { keeper: ' reviewer ' },
    { trace_id: ' trace-one ' },
    { execution_id: ' exec-one ' },
    { keeper_turn_id: '7' },
  ])('preserves raw parser identities for the exact Board join without changing ordinary display: %#', async changed => {
    vi.mocked(get).mockResolvedValueOnce({ keeper: record.keeper,
      entries: [{ ...boardEntry, ...changed, board_action_evidence: boardComment }] })
    const tail = (await fetchKeeperToolCalls(record.keeper, 200)).entries
    // Ordinary log display keeps its existing normalization/legacy join.
    expect(turnToolEvidence(record, tail)[0]?.entry).toEqual(tail[0])
    exactRows(tail)
    const { board } = renderBoard(tail)
    await waitFor(() => expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce())
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
  })

  it('cancels a delayed lookup and discards its result when the selected turn changes', async () => {
    let finishOld!: (value: ToolCallsByExecutionIdsResponse) => void
    let oldSignal: AbortSignal | undefined
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockImplementationOnce((_keeper, _ids, options) => {
      oldSignal = options?.signal
      return new Promise(resolve => { finishOld = resolve })
    })
    const selected = { ...record, trace_id: 'trace-next', absolute_turn: 8, turn_ref: 'trace-next#8', execution_ids: ['exec-next'] }
    const next = { ...boardEntry, trace_id: selected.trace_id, keeper_turn_id: 8, execution_id: 'exec-next',
      board_action_evidence: { ...boardComment, comment_id: 'comment-next' } }
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({ keeper: record.keeper,
      requested_execution_ids: selected.execution_ids, entries: [next] })
    const { view } = renderBoard([])
    await waitFor(() => expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledTimes(1))
    view.rerender(html`<${KeeperTurnFlow} record=${selected} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    await waitFor(() => expect(view.getByRole('link', { name: '댓글 comment-next' })).toBeTruthy())
    expect(oldSignal?.aborted).toBe(true)
    await act(async () => {
      finishOld({ keeper: record.keeper, requested_execution_ids: record.execution_ids,
        entries: [{ ...boardEntry, board_action_evidence: boardComment }] })
      await Promise.resolve()
    })
    expect(view.queryByRole('link', { name: '댓글 comment-one' })).toBeNull()
    expect(view.getByRole('link', { name: '댓글 comment-next' })).toBeTruthy()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledTimes(2)
  })

  it('keeps recent-tail candidates unknown on 403, including after the tail moves', async () => {
    const selected = { ...record, execution_ids: ['exec-one', 'old-missing'] }
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockRejectedValueOnce(new ApiRequestError({
      method: 'GET', path: '/api/v1/keepers/reviewer/tool-calls', status: 403, detail: 'forbidden',
    }))
    const { view, board } = renderBoard([{ ...boardEntry, board_action_evidence: boardComment }], null, selected)
    await waitFor(() => expect(board.getByText(`선택한 실행 기록 조회 실패: ${ADMIN_REQUIRED_MESSAGE}`)).toBeTruthy())
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 2개')).toBeTruthy()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, selected.execution_ids, { signal: expect.any(AbortSignal) })
    view.rerender(html`<${KeeperTurnFlow} record=${selected} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
  })

  it('keeps a full exact-lookup positive when the recent tail moves without polling', async () => {
    const row = { ...boardEntry, board_action_evidence: boardComment }
    exactRows([row])
    const { view, board } = renderBoard([row])
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy())
    view.rerender(html`<${KeeperTurnFlow} record=${record} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
    expect(view.getByText('이 턴의 실행 ID 1개 · 최근 도구 목록에서 일치 0개')).toBeTruthy()
    expect(view.getByText('최근 목록에 실행 상세 없음 · exec-one')).toBeTruthy()
  })

  it('never heals duplicate supplied execution rows from the lookup or a later tail refresh', async () => {
    const selected = { ...record, execution_ids: ['exec-one', 'old-missing'] }
    const ambiguous = { ...boardEntry, board_action_evidence: boardComment }
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({ keeper: record.keeper,
      requested_execution_ids: selected.execution_ids, entries: [ambiguous, { ...boardEntry, execution_id: 'old-missing',
        board_action_evidence: { ...boardComment, comment_id: 'comment-missing' } }] })
    const { view, board } = renderBoard([ambiguous, ambiguous], null, selected)
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-missing' })).toBeTruthy())
    expect(board.queryByRole('link', { name: '댓글 comment-one' })).toBeNull()
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, selected.execution_ids, { signal: expect.any(AbortSignal) })
    view.rerender(html`<${KeeperTurnFlow} record=${selected} toolEntries=${[ambiguous]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(view.queryByRole('link', { name: '댓글 comment-one' })).toBeNull()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
  })

  it('invalidates a full exact-lookup positive when a later tail reveals duplicate execution rows and keeps it unknown', async () => {
    const row = { ...boardEntry, board_action_evidence: boardComment }
    exactRows([row])
    const { view, board } = renderBoard([row])
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy())
    view.rerender(html`<${KeeperTurnFlow} record=${record} toolEntries=${[row, row]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
    view.rerender(html`<${KeeperTurnFlow} record=${record} toolEntries=${[row]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
  })

  it('does not promote a unique recent-tail candidate when a duplicate exists outside the recent 200 rows', async () => {
    let finish!: (value: ToolCallsByExecutionIdsResponse) => void
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    const row = { ...boardEntry, board_action_evidence: boardComment }
    const tail = [row, ...Array.from({ length: 199 }, (_, index) => ({ ...entry,
      execution_id: `recent-${index}`, keeper_turn_id: index + 80 }))]
    const { view, board } = renderBoard(tail)
    expect(board.queryAllByRole('link')).toHaveLength(0)
    await waitFor(() => expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce())
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, record.execution_ids,
      { signal: expect.any(AbortSignal) })
    view.rerender(html`<${KeeperTurnFlow} record=${record} toolEntries=${[row]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(board.queryAllByRole('link')).toHaveLength(0)
    await act(async () => {
      finish({ keeper: record.keeper, requested_execution_ids: record.execution_ids, entries: [{ ...row, ts: 0 }, row] })
      await Promise.resolve()
    })
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
    view.rerender(html`<${KeeperTurnFlow} record=${record} toolEntries=${[row]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
  })

  it('preserves duplicate exact lookup rows as ambiguous instead of selecting a winner', async () => {
    const row = { ...boardEntry, board_action_evidence: boardComment }
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({ keeper: record.keeper,
      requested_execution_ids: record.execution_ids, entries: [row, row] })
    const { board } = renderBoard([])
    await waitFor(() => expect(board.queryByText('선택한 실행 기록 조회 중…')).toBeNull())
    expect(board.queryAllByRole('link')).toHaveLength(0)
    expect(board.getByText('정확한 턴·실행 기록 미확인 1개')).toBeTruthy()
  })

  it('requests every selected execution in one batch beyond 200 IDs', async () => {
    const ids = Array.from({ length: 205 }, (_, index) => `older-${index}`)
    const selected = { ...record, execution_ids: ids }
    vi.mocked(fetchKeeperToolCallsByExecutionIds).mockResolvedValueOnce({ keeper: record.keeper,
      requested_execution_ids: ids, entries: [{ ...boardEntry, execution_id: ids.at(-1), board_action_evidence: boardComment }] })
    const tail = ids.slice(0, 200).map(execution_id => ({ ...entry, execution_id }))
    const { board } = renderBoard(tail, null, selected)
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-one' })).toBeTruthy())
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledOnce()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, ids, { signal: expect.any(AbortSignal) })
  })

  it('queries all unique nonblank selected IDs while keeping repeated turn IDs ambiguous', async () => {
    const selected = { ...record, execution_ids: ['exec-one', ' ', 'exec-one', 'exec-two'] }
    const row = { ...boardEntry, board_action_evidence: boardComment }
    exactRows([row, { ...row, execution_id: 'exec-two',
      board_action_evidence: { ...boardComment, comment_id: 'comment-two' } }], ['exec-one', 'exec-two'])
    const { board } = renderBoard([row], null, selected)
    await waitFor(() => expect(board.getByRole('link', { name: '댓글 comment-two' })).toBeTruthy())
    expect(board.queryByRole('link', { name: '댓글 comment-one' })).toBeNull()
    expect(board.getByText('정확한 턴·실행 기록 미확인 2개')).toBeTruthy()
    expect(fetchKeeperToolCallsByExecutionIds).toHaveBeenCalledWith(record.keeper, ['exec-one', 'exec-two'],
      { signal: expect.any(AbortSignal) })
  })
})

describe('turn flow evidence doors', () => {
  it('shows exact queue receipts with partial coverage and does not invent current pending status', async () => {
    const source = { stimulusId: 'source-one', snapshotRef: 'a'.repeat(64), admittedRevision: '55',
      firstAdmittedAt: 100, sourceKind: 'keeper_delegate_completed' }
    vi.mocked(fetchTurnFlow).mockResolvedValue({
      intake: { state: 'observed', channel: 'reactive', sources: [source, { ...source, stimulusId: 'source-two' }] },
      outcomes: { state: 'observed', observedAt: 110, coverage: { state: 'partial', rowsInspected: 5,
        invalidJsonRows: 1, invalidLedgerRows: 0, storageError: true }, sources: [
        { ...source, receipts: [{ transitionId: 'real-transition', eventId: 'real-event', appliedAt: 105,
          kind: 'ack_turn_completed' }] },
        { ...source, stimulusId: 'source-two', receipts: [] },
      ] },
      events: [], trace: parseKeeperRuntimeTrace({}),
    })
    vi.mocked(fetchPhysicalSkillEvidence).mockResolvedValue({ turnRef: record.turn_ref, origins: [],
      coverage: { scope: 'complete_retained_trace_snapshot', sessionsInspected: 0, ledgersLoaded: 0, gaps: [] } })
    const view = render(html`<${KeeperTurnFlow} record=${record} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    await waitFor(() => expect(view.container.textContent).toContain('real-transition'))
    expect(view.container.textContent).toContain('턴 완료 후 ACK')
    expect(view.container.textContent).toContain('일부 기록만 확인')
    expect(view.container.textContent).toContain('현재 대기 상태인지는 확정할 수 없습니다')
    expect(view.container.textContent).toContain('ACK는 큐 처리 기록입니다')
  })

  it('groups physical async actions while preserving each causal result link', async () => {
    const evidence = physicalEvidence()
    const origin = evidence.origins[0]!
    const extra = { ...origin.async_result_deliveries[0]!, request_id: 'another-result', observed_at: '2026-10-15T12:00:00Z' }
    const digest = skillAsyncResultDeliverySha256(extra)
    const link = { ...origin.async_actions[0]!, delivery_sha256: digest, observed_at: '2026-10-15T12:00:01Z' }
    origin.async_result_deliveries.push(extra)
    origin.async_actions.push(link)
    vi.mocked(fetchTurnFlow).mockRejectedValue(new Error('manifest offline'))
    vi.mocked(fetchPhysicalSkillEvidence).mockResolvedValue(evidence)
    const receiving = { ...record, trace_id: 'new-physical-trace', absolute_turn: 73, turn_ref: 'new-physical-trace#73' }
    const view = render(html`<${KeeperTurnFlow} record=${receiving} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    await waitFor(() => expect(view.container.textContent).toContain('비동기 결과 사용 3건 · 인과 연결 4개'))
    expect(view.container.textContent).toContain('이 턴의 호출 0개 · 이 턴에서 받은 비동기 결과 3개')
    expect(view.container.textContent).toContain('trace-one#41 → 수신 턴 new-physical-trace#73')
    expect(view.container.textContent).toContain(asyncFixture.revision)
    expect(fetchPhysicalSkillEvidence).toHaveBeenCalledWith(receiving.turn_ref, { signal: expect.any(AbortSignal) })
    expect(view.container.textContent).toContain(digest)
    expect(view.container.textContent).toContain(asyncFixture.async_actions[0]!.delivery_sha256)
  })

  it('keeps an incomplete empty scan distinct from confirmed absence in retained coverage', async () => {
    vi.mocked(fetchTurnFlow).mockRejectedValue(new Error('manifest offline'))
    vi.mocked(fetchPhysicalSkillEvidence).mockResolvedValue({
      turnRef: record.turn_ref, origins: [], coverage: { scope: 'incomplete_retained_trace_snapshot',
        sessionsInspected: 1, ledgersLoaded: 0, gaps: [{ code: 'ledger_unreadable', trace_id: 'damaged-origin', cause_code: 'decode_failed', detail: 'damaged log' }] },
    })
    const view = render(html`<${KeeperTurnFlow} record=${record} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    await waitFor(() => expect(view.container.textContent).toContain('일부 원장 확인 불가'))
    expect(view.container.textContent).toContain('수신·사용이 없었다고 확정할 수 없습니다')
    expect(view.container.textContent).toContain('damaged-origin')
  })

  it('keeps Skill evidence and exact prompt navigation usable when the runtime trace fails', async () => {
    vi.mocked(fetchTurnFlow).mockRejectedValue(new Error('manifest offline'))
    vi.mocked(fetchPhysicalSkillEvidence).mockResolvedValue({
      turnRef: record.turn_ref, origins: [], coverage: {
        scope: 'complete_retained_trace_snapshot', sessionsInspected: 1, ledgersLoaded: 0, gaps: [] },
    })
    const onMessages = vi.fn(), onContext = vi.fn()
    const view = render(html`<${KeeperTurnFlow} record=${record} toolEntries=${[entry]}
      toolCallError=${null} onMessages=${onMessages} onContext=${onContext} />`)
    await waitFor(() => expect(fetchTurnFlow).toHaveBeenCalledOnce())
    await waitFor(() => expect(view.container.textContent).toContain('manifest offline'))
    expect(fetchPhysicalSkillEvidence).toHaveBeenCalledWith(record.turn_ref, { signal: expect.any(AbortSignal) })
    await waitFor(() => expect(view.container.textContent).toContain('보존된 모든 원장 확인'))
    expect(view.container.textContent).toContain('Execute · ok')
    fireEvent.click(view.getByRole('button', { name: '실제 메시지 열기' }))
    fireEvent.click(view.getByRole('button', { name: 'System·도구 스키마 열기' }))
    expect(onMessages).toHaveBeenCalledOnce()
    expect(onContext).toHaveBeenCalledOnce()
  })
})

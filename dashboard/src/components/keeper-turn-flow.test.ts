import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ToolCallEntry } from '../api/dashboard'
import { fetchTraceSkillActivations, fetchTurnFlow } from '../api/keeper-turn-flow'
import { KeeperTurnFlow, turnToolEvidence } from './keeper-turn-flow'

vi.mock('../api/keeper-turn-flow', () => ({ fetchTraceSkillActivations: vi.fn(), fetchTurnFlow: vi.fn() }))
afterEach(() => { cleanup(); vi.clearAllMocks() })

const record = { keeper: 'reviewer', trace_id: 'trace-one', absolute_turn: 7,
  turn_ref: 'trace-one#7', execution_ids: ['exec-one'], blocks: [] }
const entry: ToolCallEntry = { ts: 1, keeper: 'reviewer', trace_id: 'trace-one', keeper_turn_id: 7,
  tool: 'Execute', execution_id: 'exec-one', input: {}, output: 'ok', wire_outcome: 'ok', duration_ms: 1 }

describe('tool evidence identity', () => {
  it('requires the selected execution and rejects foreign or duplicate rows', () => {
    expect(turnToolEvidence(record, [entry])[0]?.entry).toEqual(entry)
    expect(turnToolEvidence(record, [{ ...entry, execution_id: 'other' }])[0]?.entry).toBeUndefined()
    for (const wrong of [{ keeper: 'other' }, { trace_id: 'other' }, { keeper_turn_id: 8 }]) {
      expect(turnToolEvidence(record, [{ ...entry, ...wrong }])[0]?.entry).toBeUndefined()
    }
    expect(turnToolEvidence(record, [entry, entry])[0]?.entry).toBeUndefined()
  })
})

describe('turn flow evidence doors', () => {
  it('keeps Skill evidence and exact prompt navigation usable when the runtime trace fails', async () => {
    vi.mocked(fetchTurnFlow).mockRejectedValue(new Error('manifest offline'))
    vi.mocked(fetchTraceSkillActivations).mockResolvedValue({ status: 'not_recorded' })
    const onMessages = vi.fn(), onContext = vi.fn()
    const view = render(html`<${KeeperTurnFlow} record=${record} toolEntries=${[entry]}
      toolCallError=${null} onMessages=${onMessages} onContext=${onContext} />`)
    await waitFor(() => expect(fetchTurnFlow).toHaveBeenCalledOnce())
    await waitFor(() => expect(view.container.textContent).toContain('manifest offline'))
    expect(fetchTraceSkillActivations).toHaveBeenCalledWith({ keeper: 'reviewer', traceId: 'trace-one',
      absoluteTurn: 7, turnRef: 'trace-one#7' }, { signal: expect.any(AbortSignal) })
    expect(view.container.textContent).toContain('Skill 사용 원장이 없습니다')
    expect(view.container.textContent).toContain('Execute · ok')
    fireEvent.click(view.getByRole('button', { name: '실제 메시지 열기' }))
    fireEvent.click(view.getByRole('button', { name: 'System·도구 스키마 열기' }))
    expect(onMessages).toHaveBeenCalledOnce()
    expect(onContext).toHaveBeenCalledOnce()
  })
})

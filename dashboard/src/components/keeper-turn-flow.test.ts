import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import asyncFixture from '../../../test/fixtures/skill-ledger-async-actions.json'
import type { ToolCallEntry } from '../api/dashboard'
import { skillAsyncResultDeliverySha256 } from '../api/dashboard-tools-prompts'
import { fetchTurnFlow } from '../api/keeper-turn-flow'
import { decodePhysicalSkillEvidence, fetchPhysicalSkillEvidence } from '../api/keeper-physical-skill-evidence'
import { KeeperTurnFlow, turnToolEvidence } from './keeper-turn-flow'

vi.mock('../api/keeper-turn-flow', () => ({ fetchTurnFlow: vi.fn() }))
vi.mock('../api/keeper-physical-skill-evidence', async importOriginal => ({
  ...await importOriginal<typeof import('../api/keeper-physical-skill-evidence')>(), fetchPhysicalSkillEvidence: vi.fn(),
}))
afterEach(() => { cleanup(); vi.clearAllMocks() })

const record = { keeper: 'reviewer', trace_id: 'trace-one', absolute_turn: 7,
  turn_ref: 'trace-one#7', execution_ids: ['exec-one'], blocks: [] }
const entry: ToolCallEntry = { ts: 1, keeper: 'reviewer', trace_id: 'trace-one', keeper_turn_id: 7,
  tool: 'Execute', execution_id: 'exec-one', input: {}, output: 'ok', wire_outcome: 'ok', duration_ms: 1 }

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
})

describe('turn flow evidence doors', () => {
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

import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { sha256 } from '@noble/hashes/sha2.js'
import { bytesToHex } from '@noble/hashes/utils.js'
import asyncFixture from '../../../test/fixtures/skill-ledger-async-actions.json'
import type { ToolCallEntry } from '../api/dashboard'
import { normalizeSkillActivationProjection } from '../api/dashboard-tools-prompts'
import { fetchTraceSkillActivations, fetchTurnFlow } from '../api/keeper-turn-flow'
import { KeeperTurnFlow, turnToolEvidence } from './keeper-turn-flow'

vi.mock('../api/keeper-turn-flow', () => ({ fetchTraceSkillActivations: vi.fn(), fetchTurnFlow: vi.fn() }))
afterEach(() => { cleanup(); vi.clearAllMocks() })

const record = { keeper: 'reviewer', trace_id: 'trace-one', absolute_turn: 7,
  turn_ref: 'trace-one#7', execution_ids: ['exec-one'], blocks: [] }
const entry: ToolCallEntry = { ts: 1, keeper: 'reviewer', trace_id: 'trace-one', keeper_turn_id: 7,
  tool: 'Execute', execution_id: 'exec-one', input: {}, output: 'ok', wire_outcome: 'ok', duration_ms: 1 }

function skillProjection(ledger = asyncFixture) {
  const summary = Object.fromEntries([
    'instruction_invocations', 'skill_bodies_served', 'skill_resources_served',
    'instruction_provider_deliveries', 'instruction_official_client_handoffs', 'instruction_actions_observed',
    'composition_invocations', 'composition_provider_deliveries', 'composition_official_client_handoffs',
    'composition_actions_observed', 'invalid_transitions',
  ].map(key => [key, 0]))
  const projection = normalizeSkillActivationProjection({
    status: 'available', keeper_name: record.keeper, summary, scoped_summaries: [], ledger,
  })
  if (projection?.status !== 'available') throw new Error('fixture ledger unavailable')
  return projection
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
    const extra = { ...asyncFixture.async_result_deliveries[0]!, request_id: 'another-result', observed_at: '2026-10-15T12:00:00Z' }
    const { observed_at: _clock, ...identity } = extra
    const digest = bytesToHex(sha256(new TextEncoder().encode(JSON.stringify(identity))))
    const link = { ...asyncFixture.async_actions[0]!, delivery_sha256: digest, observed_at: '2026-10-15T12:00:01Z' }
    vi.mocked(fetchTurnFlow).mockRejectedValue(new Error('manifest offline'))
    vi.mocked(fetchTraceSkillActivations).mockResolvedValue(skillProjection({
      ...asyncFixture, async_result_deliveries: [...asyncFixture.async_result_deliveries, extra],
      async_actions: [...asyncFixture.async_actions, link],
    }))
    // These canonical facts belong to the original trace ledger, while their
    // physical receiving turn is different. The view keeps that scope visible.
    const receiving = { ...record, trace_id: 'new-physical-trace', absolute_turn: 73, turn_ref: 'new-physical-trace#73' }
    const view = render(html`<${KeeperTurnFlow} record=${receiving} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    await waitFor(() => expect(view.container.textContent).toContain('비동기 결과 사용 3건 · 인과 연결 4개'))
    expect(view.container.textContent).toContain('원래 trace trace-one의 원장')
    expect(view.container.textContent).toContain('다른 원래 trace의 비동기 수신·사용은 조회하지 않았습니다')
    expect(view.container.textContent).toContain(digest)
    expect(view.container.textContent).toContain(asyncFixture.async_actions[0]!.delivery_sha256)
  })

  it('scopes zero receiving-turn matches to the original trace ledger', async () => {
    vi.mocked(fetchTurnFlow).mockRejectedValue(new Error('manifest offline'))
    vi.mocked(fetchTraceSkillActivations).mockResolvedValue(skillProjection())
    const view = render(html`<${KeeperTurnFlow} record=${record} toolEntries=${[]}
      toolCallError=${null} onMessages=${vi.fn()} onContext=${vi.fn()} />`)
    await waitFor(() => expect(view.container.textContent).toContain('이 턴과 일치한 비동기 결과 전달 0개'))
    expect(view.container.textContent).toContain('원래 trace trace-one의 원장')
    expect(view.container.textContent).toContain('다른 원래 trace의 비동기 수신·사용은 조회하지 않았습니다')
  })

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

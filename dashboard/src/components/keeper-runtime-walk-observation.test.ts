import { h } from 'preact'
import { cleanup, fireEvent, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'
import { readRuntimeLaneObservation } from '../lib/keeper-runtime-walk'
import { normalizeKeepers } from '../keeper-store-normalize'
import { KeeperRuntimeAlertStrip } from './keeper-detail-alert-strip'

afterEach(cleanup)

function observed() {
  return {
    state: 'observed',
    turn: { trace_id: 'previous-trace', turn_count: 2, ended_at: '2026-06-01T00:00:00Z' },
    error: null,
    evidence: {
      failures: [
        { attempt: 0, runtime_id: 'same.runtime', dispatch: 'rejected_before_dispatch',
          failure: { cause: { kind: 'core', core: { category: 'internal', message: 'binding unavailable' } } },
          summary: 'binding unavailable', api_candidate_fault: null },
        { attempt: 1, runtime_id: 'same.runtime', dispatch: 'dispatched',
          failure: { cause: { kind: 'core', core: { category: 'api', message: 'Prompt exceeds max length' } } },
          summary: 'HTTP 400: Prompt exceeds max length', api_candidate_fault: { kind: 'unattributed' } },
        { attempt: 2, runtime_id: 'last.runtime', dispatch: 'dispatched',
          failure: { cause: { kind: 'core', core: { category: 'api', message: 'quota' } } },
          summary: 'HTTP 429: quota', api_candidate_fault: { kind: 'binding', fact: 'rate_limit' } },
      ],
      terminal: { kind: 'candidate', attempt: 2, runtime_id: 'last.runtime',
        failure: { cause: { kind: 'core', core: { category: 'api', message: 'quota' } } },
        summary: 'HTTP 429: quota' },
    },
  }
}

describe('historical runtime candidate evidence', () => {
  it('retains order, repeated identities, dispatch, opaque source failures and exact terminal origin', () => {
    const wire = observed()
    expect(readRuntimeLaneObservation(wire)).toEqual(wire)
  })

  it('distinguishes no receipt, no capture and an observed walk without failures', () => {
    expect(readRuntimeLaneObservation(null)).toBeNull()
    const wire = observed()
    expect(readRuntimeLaneObservation({ ...wire, state: 'not_observed', evidence: null })?.state)
      .toBe('not_observed')
    const empty = { ...wire, evidence: { failures: [], terminal: { kind: 'not_observed' } } }
    expect(readRuntimeLaneObservation(empty)).toEqual(empty)
    expect(readRuntimeLaneObservation({ ...empty, turn: { ...wire.turn, turn_count: null } }))
      .toEqual({ ...empty, turn: { ...wire.turn, turn_count: null } })
  })

  it('makes malformed or missing wire evidence unreadable rather than empty or absent', () => {
    const wire = observed()
    const first = wire.evidence.failures[0]!
    for (const raw of [
      undefined, {}, { ...wire, state: 'future_state' },
      { ...wire, turn: { ...wire.turn, trace_id: null } },
      { ...wire, evidence: { ...wire.evidence, failures: null } },
      { ...wire, evidence: { ...wire.evidence, terminal: { kind: 'future_terminal' } } },
      { ...wire, evidence: { ...wire.evidence, failures: [{ ...first, summary: null }] } },
      { ...wire, evidence: { ...wire.evidence, failures: [{ ...first, attempt: -1 }] } },
      { ...wire, evidence: { ...wire.evidence, failures: [{ ...first, dispatch: 'maybe_sent' }] } },
      { ...wire, evidence: { ...wire.evidence, failures: [{ ...first, api_candidate_fault: { kind: 'binding', fact: 'future_fact' } }] } },
      { ...wire, unexpected: true },
    ]) {
      const parsed = readRuntimeLaneObservation(raw)
      expect(parsed?.state).toBe('unreadable')
      expect(parsed?.evidence).toBeNull()
    }
  })

  it('shows earlier failures and their source turn beside the current blocker after normalization', () => {
    const [keeper] = normalizeKeepers([{
      name: 'current-keeper', trace_id: 'current-trace', status: 'active', keepalive_running: true,
      runtime_blocker_class: 'operator_interrupt', runtime_blocker_summary: 'current operator stop',
      runtime_trust: { execution: { runtime_lane_observation: observed() } },
    }])
    expect(keeper?.runtime_blocker_class).toBe('operator_interrupt')
    const view = render(h(KeeperRuntimeAlertStrip, { keeper: keeper! }))
    fireEvent.click(view.getByText('기록된 턴의 런타임 후보 증거'))
    expect(view.getByText(/previous-trace/)).toBeVisible()
    const rows = [...view.container.querySelectorAll('li')]
    expect(rows).toHaveLength(3)
    expect(rows[0]?.textContent).toContain('binding unavailable')
    expect(rows[0]?.textContent).toContain('호출 전 거절')
    expect(rows[1]?.textContent).toContain('HTTP 400: Prompt exceeds max length')
    expect(rows[1]?.textContent).toContain('귀속 미분류')
    expect(rows[2]?.textContent).toContain('HTTP 429: quota')
    expect(view.container.textContent).toContain('current operator stop')
    expect(view.container.textContent).toContain('최종 오류 출처 · 후보 3')
  })

  it.each(['observed', 'not_observed', 'unreadable'])(
    'renders corrupt timestamps safely in %s observations', state => {
      for (const ended_at of ['', 'broken', '9999999999999999999999']) {
        const wire = observed()
        const [keeper] = normalizeKeepers([{
          name: 'corrupt-history', status: 'active', keepalive_running: true,
          runtime_blocker_class: 'operator_interrupt', runtime_blocker_summary: 'current stop',
          runtime_trust: { execution: { runtime_lane_observation: {
            ...wire, state, turn: { ...wire.turn, ended_at },
            evidence: state === 'observed' ? wire.evidence : null,
            error: state === 'unreadable' ? 'runtime.lane_evidence' : null,
          } } },
        }])
        expect(keeper?.trust?.execution_summary?.runtime_lane_observation).toMatchObject({
          state: 'unreadable', turn: null, evidence: null,
        })
        const view = render(h(KeeperRuntimeAlertStrip, { keeper: keeper! }))
        expect(view.container.textContent).toContain('current stop')
        expect(view.container.textContent).toContain('후보 증거를 읽을 수 없습니다')
        cleanup()
      }
    },
  )

  it('shows an earlier terminal origin and a later failure without equating them', () => {
    const wire = observed()
    wire.evidence.terminal = { kind: 'candidate', attempt: 0, runtime_id: 'same.runtime',
      failure: { cause: { kind: 'core', core: { category: 'internal', message: 'effect settlement unknown' } } },
      summary: 'effect settlement unknown' }
    const [keeper] = normalizeKeepers([{
      name: 'recovered-keeper', status: 'active', keepalive_running: true,
      runtime_trust: { execution: { runtime_lane_observation: wire } },
    }])
    const view = render(h(KeeperRuntimeAlertStrip, { keeper: keeper! }))
    fireEvent.click(view.getByText('기록된 턴의 런타임 후보 증거'))
    expect(view.container.textContent).toContain('최종 오류 출처 · 후보 1')
    expect(view.container.textContent).toContain('effect settlement unknown')
    expect(view.container.textContent).toContain('HTTP 429: quota')
  })

  it('retains earlier failures on successful fallback without inventing terminal or live failure', () => {
    const wire = observed()
    const [keeper] = normalizeKeepers([{
      name: 'recovered-keeper', status: 'active', keepalive_running: true,
      runtime_trust: { execution: { runtime_lane_observation: {
        ...wire, evidence: { failures: wire.evidence.failures, terminal: { kind: 'not_observed' } },
      } } },
    }])
    expect(keeper?.runtime_blocker_class).toBeNull()
    const view = render(h(KeeperRuntimeAlertStrip, { keeper: keeper! }))
    fireEvent.click(view.getByText('기록된 턴의 런타임 후보 증거'))
    expect(view.container.textContent).toContain('HTTP 400: Prompt exceeds max length')
    expect(view.container.textContent).toContain('후보에서 나온 종단 오류는 관측되지 않았습니다')
    expect(view.container.textContent).not.toContain('최종 오류 출처')
  })
})

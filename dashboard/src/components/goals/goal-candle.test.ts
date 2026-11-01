import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
const api = vi.hoisted(() => ({ getWithResponse: vi.fn() }))
const generation = vi.hoisted(() => ({ refreshExecution: vi.fn().mockResolvedValue(undefined), resetExecutionSnapshotGeneration: vi.fn() }))
vi.mock('../../api/core', async original => ({ ...await original<typeof import('../../api/core')>(), ...api }))
vi.mock('../../store', async original => ({ ...await original<typeof import('../../store')>(), ...generation }))
import { decodeGoalCandle, GoalCandleEpochMismatchError } from '../../api/goal-candle'
import { ApiRequestError } from '../../api/core'
import { GoalCandlePanel } from './goal-candle'

const workspace = { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }
let testSequence = 0
const owner = (goalId = 'goal-1', key = 'owner-a') => ({ key, recoveryKey: `${key}-${testSequence}`, goalId, workspace, executionEpoch: 'epoch-a' })
const current = () => true
const identity = { request_id: 'request-1', verification_run_id: 'run-1' }
function payload(goalId = 'goal-1', payout: unknown = { state: 'paid', ...identity, recorded_at: '2026-09-10T00:00:00Z',
  allocations: [{ keeper: 'keeper-a', weight: '7', amount_milli: '9007199254740993' }] }) {
  return { schema: 'masc.goal-candle-observation.v1', goal_id: goalId, config: { state: 'off' },
    ledger: { state: 'observed', payout }, execution: { state: 'not_observed', reason: 'no_complete_goal_request_index' } }
}
function response(data: unknown, attested = true, epoch = 'epoch-a') {
  return { data, headers: new Headers(attested ? { 'x-masc-workspace-read': 'matched-v1', 'x-masc-execution-publication-epoch': epoch } : {}) }
}
beforeEach(() => { testSequence++; api.getWithResponse.mockReset(); generation.refreshExecution.mockClear(); generation.resetExecutionSnapshotGeneration.mockClear() })
afterEach(cleanup)

describe('Goal Candle observation', () => {
  it('shows a past payment even when current config is off and does not claim model execution', async () => {
    api.getWithResponse.mockResolvedValue(response(payload()))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    expect(await screen.findByText(/지급이 원장에 기록되었습니다/)).toBeTruthy()
    expect(screen.getByText('마지막 조회 시 설정: 꺼짐')).toBeTruthy()
    expect(screen.getByText(/keeper-a: 9007199254740\.993 Candle · 가중치 7/)).toBeTruthy()
    expect(screen.getByText(/모델 요청의 실행 여부는 이 원장만으로 확인할 수 없습니다/)).toBeTruthy()
    expect(screen.getByText(/연결·삭제 이력 전체와 Snapshot 밖의 누락은 이 원장만으로 확인할 수 없습니다/)).toBeTruthy()
    expect(api.getWithResponse.mock.calls[0]?.[0]).toContain('expected_base_path=%2Fworkspace-a')
    expect(api.getWithResponse.mock.calls[0]?.[0]).toContain('expected_masc_root=%2Fworkspace-a%2F.masc')
  })

  it('does not present a candidate coverage warning when no payout is recorded', async () => {
    api.getWithResponse.mockResolvedValue(response(payload('goal-1', { state: 'no_recorded_obligation' })))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByText(/지급 의무가 기록되지 않았습니다/)
    expect(screen.queryByText(/현재 후보 생성은/)).toBeNull()
  })

  it('requires a workspace receipt and a matching Goal identity', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(payload(), false))
      .mockResolvedValueOnce(response(payload('other-goal')))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByRole('alert')
    expect(screen.queryByText(/지급이 원장에 기록되었습니다/)).toBeNull()
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(2))
    await screen.findByText(/서버 응답을 확인할 수 없습니다/)
  })

  it('hides the previous observation while a refresh is pending and after it fails', async () => {
    let failRefresh!: (reason: Error) => void
    api.getWithResponse.mockResolvedValueOnce(response(payload()))
      .mockReturnValueOnce(new Promise((_, reject) => { failRefresh = reject }))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByText(/지급이 원장에 기록되었습니다/)
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await screen.findByText('지급 기록을 확인하는 중...')
    expect(screen.queryByText(/keeper-a:/)).toBeNull()
    failRefresh(new Error('ledger read failed'))
    await screen.findByText(/서버 응답을 확인할 수 없습니다/)
    expect(screen.queryByText(/ledger read failed/)).toBeNull()
    expect(screen.queryByText(/지급이 원장에 기록되었습니다/)).toBeNull()
  })

  it('withdraws retained admin data after permission is revoked', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(payload()))
      .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/candle', status: 403 }))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByText(/지급이 원장에 기록되었습니다/)
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await screen.findByRole('alert')
    expect(screen.queryByText(/지급이 원장에 기록되었습니다/)).toBeNull()
    expect(screen.queryByText(/keeper-a:/)).toBeNull()
  })

  it('withdraws a previous epoch and asks execution to reconnect on a different server epoch', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(payload()))
      .mockResolvedValueOnce(response(payload(), true, 'epoch-b'))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByText(/지급이 원장에 기록되었습니다/)
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await screen.findByText(/서버 실행 세대가 변경되어/)
    expect(screen.queryByText(/지급이 원장에 기록되었습니다/)).toBeNull()
    expect(generation.resetExecutionSnapshotGeneration).toHaveBeenCalledOnce()
    expect(generation.refreshExecution).toHaveBeenCalledWith({ force: true })
  })

  it('withdraws the old workspace observation on a structured workspace refusal', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(payload()))
      .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/candle', status: 409,
        errorCode: 'workspace_precondition_failed' }))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByText(/지급이 원장에 기록되었습니다/)
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await screen.findByRole('alert')
    expect(screen.queryByText(/지급이 원장에 기록되었습니다/)).toBeNull()
    expect(generation.resetExecutionSnapshotGeneration).toHaveBeenCalledOnce()
    expect(generation.refreshExecution).toHaveBeenCalledWith({ force: true })
  })

  it('attempts automatic recovery only once until the user retries or a read succeeds', async () => {
    api.getWithResponse.mockRejectedValue(new GoalCandleEpochMismatchError())
    const first = render(html`<${GoalCandlePanel} owner=${owner('goal-1', 'loop')} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByRole('alert')
    expect(generation.resetExecutionSnapshotGeneration).toHaveBeenCalledOnce()
    first.unmount()
    render(html`<${GoalCandlePanel} owner=${owner('goal-1', 'loop')} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByRole('alert')
    expect(generation.resetExecutionSnapshotGeneration).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await waitFor(() => expect(generation.resetExecutionSnapshotGeneration).toHaveBeenCalledTimes(2))
  })

  it('does not draw a delayed result under a different Goal or credential', async () => {
    let finishOld!: (value: unknown) => void
    api.getWithResponse.mockReturnValueOnce(new Promise(resolve => { finishOld = resolve }))
      .mockResolvedValueOnce(response(payload('goal-2', { state: 'owed', ...identity, snapshot: 'matching', stage: 'candidates_consistent' })))
    let oldCurrent = true
    const view = render(html`<${GoalCandlePanel} key="old" owner=${owner()} isCurrent=${() => oldCurrent} refreshKey="completed" />`)
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(1))
    oldCurrent = false
    view.rerender(html`<${GoalCandlePanel} key="new" owner=${owner('goal-2', 'owner-b')} isCurrent=${current} refreshKey="completed" />`)
    await screen.findByText(/지급 의무와 후보가 기록되어/)
    finishOld(response(payload()))
    await waitFor(() => expect(screen.queryByText(/지급이 원장에 기록되었습니다/)).toBeNull())
    expect(screen.getByText(/지급 의무와 후보가 기록되어/)).toBeTruthy()
  })

  it('retains typed hold issues and rejects unrecognized or incomplete wire states', () => {
    const held = payload('goal-1', { state: 'held', ...identity, snapshot: 'matching', origin: 'stored',
      issues: { state: 'complete', entries: [{ kind: 'same_second', task_id: 'task-1', boundary: 'human_confirmed', completed_at: '2026-09-10T00:00:00Z' }] } })
    expect(decodeGoalCandle(held, 'goal-1').ledger).toMatchObject({ state: 'observed', payout: { state: 'held', issues: { entries: [{ task_id: 'task-1' }] } } })
    expect(() => decodeGoalCandle(payload('goal-1', { state: 'future' }), 'goal-1')).toThrow()
    expect(() => decodeGoalCandle({ ...held, execution: { state: 'not_observed' } }, 'goal-1')).toThrow()
  })

  it('says candidate consistency was not checked when a hold was derived', async () => {
    api.getWithResponse.mockResolvedValue(response(payload('goal-1', { state: 'held', ...identity,
      snapshot: 'matching', origin: 'derived_candidates',
      issues: { state: 'complete', entries: [{ kind: 'unfenced_nonterminal', task_id: 'task-1' }] } })))
    render(html`<${GoalCandlePanel} owner=${owner()} isCurrent=${current} refreshKey="completed" />`)
    expect(await screen.findByText(/후보 구성이 맞는지는 확인하지 않았습니다/)).toBeTruthy()
  })
})

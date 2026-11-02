import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

const generation = vi.hoisted(() => ({ refreshExecution: vi.fn().mockResolvedValue(undefined), resetExecutionSnapshotGeneration: vi.fn() }))
vi.mock('../../store', async original => ({
  ...await original<typeof import('../../store')>(),
  ...generation,
}))

import { GoalCandlePanel } from './goal-candle'
import { readGoalCandle } from '../../api/goal-candle'
import { clearStoredToken, getStoredToken, setRejectedCredentialListener, setStoredToken } from '../../api/core'
import { installRejectedCredentialRecovery } from '../../api/dev-token'

afterEach(() => { cleanup(); setRejectedCredentialListener(null); clearStoredToken(); vi.unstubAllGlobals() })

describe('Goal Candle response boundaries', () => {
  it.each([401, 403, 409, 429, 503, 200])('handles %i headers before a response body arrives', async status => {
    generation.resetExecutionSnapshotGeneration.mockClear()
    generation.refreshExecution.mockClear()
    const headers = { 'content-type': 'application/json', 'x-masc-workspace-read': 'matched-v1',
      'x-masc-execution-publication-epoch': 'epoch-a' }
    const body = { schema: 'masc.goal-candle-observation.v1', goal_id: 'goal-1', config: { state: 'enabled' },
      ledger: { state: 'observed', payout: { state: 'paid', request_id: 'request-1', verification_run_id: 'run-1',
        recorded_at: '2026-09-10T00:00:00Z', allocations: [{ keeper: 'keeper-a', weight: '1', amount_milli: '1000' }] } },
      execution: { state: 'not_observed', reason: 'no_complete_goal_request_index' } }
    let stream!: ReadableStreamDefaultController<Uint8Array>
    const interrupted = new ReadableStream<Uint8Array>({ start(controller) { stream = controller } })
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(body), { status: 200, headers }))
      .mockResolvedValueOnce(new Response(interrupted, { status, headers: {
        ...headers, 'x-masc-execution-publication-epoch': 'epoch-b',
      } }))
    vi.stubGlobal('fetch', fetchMock)
    const owner = { key: `owner-${status}`, recoveryKey: `owner-${status}`, goalId: 'goal-1', workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' },
      executionEpoch: 'epoch-a' }
    render(html`<${GoalCandlePanel} owner=${owner} isCurrent=${() => true} refreshKey="completed" />`)
    await screen.findByText(/keeper-a:/)
    fireEvent.click(screen.getByText('지급 기록 새로고침'))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    await screen.findByRole('alert')
    if (status === 401) expect(screen.getByRole('alert').textContent).toContain('인증을 확인한 뒤 다시 조회하세요')
    if (status !== 200) expect(screen.getByRole('alert').textContent).toContain(`HTTP ${status}`)
    expect(screen.queryByText(/keeper-a:/)).toBeNull()
    expect(generation.resetExecutionSnapshotGeneration).toHaveBeenCalledTimes(status === 409 || status === 200 ? 1 : 0)
    stream.error(new Error('response body interrupted'))
    expect(screen.queryByText(/keeper-a:/)).toBeNull()
  })

  it.each([[401, 'abort'], [401, 'network'], [403, 'abort'], [403, 'network'],
    [429, 'abort'], [429, 'network'], [503, 'abort'], [503, 'network']] as const)(
    'retains the %i refusal without waiting for the body (%s)', async (status, failure) => {
      let stream!: ReadableStreamDefaultController<Uint8Array>
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
        new ReadableStream<Uint8Array>({ start(controller) { stream = controller } }), { status },
      )))
      const owner = { key: `aborted-${status}`, recoveryKey: `aborted-${status}`, goalId: 'goal-1',
        workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }, executionEpoch: 'epoch-a' }
      render(html`<${GoalCandlePanel} owner=${owner} isCurrent=${() => true} refreshKey="completed" />`)
      await screen.findByRole('alert')
      stream.error(failure === 'abort' ? new DOMException('request timed out', 'AbortError') : new Error('network failed'))
      expect(screen.getByRole('alert').textContent).toContain(String(status))
      expect(screen.getByRole('alert').textContent).not.toContain('timeout after')
      expect(screen.getByRole('alert').textContent).not.toContain('network failed')
    })

  it('does not let this workspace-bound 401 mutate the shared credential', async () => {
    setStoredToken('fixture-token')
    const rejected = vi.fn()
    const onAccessRefused = vi.fn()
    setRejectedCredentialListener(rejected)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
      error: 'expired', auth_error_code: 'token_expired',
    }), { status: 401 })))
    await expect(readGoalCandle('goal-1', { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' },
      'epoch-a', onAccessRefused)).rejects.toMatchObject({ status: 401 })
    expect(onAccessRefused).toHaveBeenCalledOnce()
    expect(rejected).not.toHaveBeenCalled()
  })

  it('keeps the manual token when a delayed workspace-bound 401 completes', async () => {
    setStoredToken('fixture-token', { source: 'manual' })
    const uninstall = installRejectedCredentialRecovery()
    let stream!: ReadableStreamDefaultController<Uint8Array>
    let sawHeaders!: () => void
    const headers = new Promise<void>(resolve => { sawHeaders = resolve })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      new ReadableStream<Uint8Array>({ start(controller) { stream = controller } }), { status: 401 },
    )))
    const pending = readGoalCandle('goal-1', { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' },
      'epoch-a', sawHeaders)
    await headers
    // Recovery is suppressed even if this response outlives its workspace.
    stream.enqueue(new TextEncoder().encode(JSON.stringify({ error: 'invalid token', auth_error_code: 'invalid_token' })))
    stream.close()
    await expect(pending).rejects.toMatchObject({ status: 401 })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(getStoredToken()).toBe('fixture-token')
    uninstall()
  })

  it.each([401, 503])('withholds the %i error body while retaining its status', async status => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ error: 'repair the server setting' }), { status })))
    const owner = { key: `complete-${status}`, recoveryKey: `complete-${status}`, goalId: 'goal-1',
      workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }, executionEpoch: 'epoch-a' }
    render(html`<${GoalCandlePanel} owner=${owner} isCurrent=${() => true} refreshKey="completed" />`)
    await screen.findByRole('alert')
    expect(screen.getByRole('alert').textContent).toContain(String(status))
    expect(screen.queryByText(/repair the server setting/)).toBeNull()
  })

  it.each([
    new Error('private response detail'),
    new DOMException('private response detail', 'AbortError'),
  ])('reports an interrupted successful response as a body failure: %s', async failure => {
    let stream!: ReadableStreamDefaultController<Uint8Array>
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      new ReadableStream<Uint8Array>({ start(controller) { stream = controller } }),
      { status: 200, headers: { 'x-masc-workspace-read': 'matched-v1', 'x-masc-execution-publication-epoch': 'epoch-a' } },
    )))
    const owner = { key: 'interrupted-success', recoveryKey: 'interrupted-success', goalId: 'goal-1',
      workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }, executionEpoch: 'epoch-a' }
    render(html`<${GoalCandlePanel} owner=${owner} isCurrent=${() => true} refreshKey="completed" />`)
    await screen.findByText('지급 기록을 확인하는 중...')
    stream.error(failure)
    await screen.findByText(/HTTP 200 응답 본문을 읽거나 해석할 수 없습니다/)
    expect(screen.queryByText(/private response detail/)).toBeNull()
  })
})

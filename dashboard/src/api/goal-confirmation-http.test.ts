import { afterEach, describe, expect, it, vi } from 'vitest'
import { confirmationBinding, readGoalConfirmation, submitGoalConfirmation } from './goal-confirmation'
import { clearStoredToken, get, setRejectedCredentialListener, setStoredToken } from './core'
import { captureArtifactWorkspace } from './published-artifacts'
import { fetchDashboardGoalsTree } from './dashboard-goals'

const workspace = { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }
const epoch = 'epoch-a'
const instance = '018f83d7-93a4-7f5d-9a72-123456789abc'
const criterion = { revision: 'revision-1', title: 'Goal', metric: 'cases', target_value: '10' }
const proof = { inspection_operator_id: 'operator-a',
  goal: { id: 'goal-1', phase: 'awaiting_confirmation', criterion_revision: criterion.revision, ...criterion },
  verification: { goal_id: 'goal-1', updated_at: '2026-11-01T00:00:00Z', completion: { state: 'proof_proven',
    verdict: { criterion, request_id: 'request-1', verification_run_id: 'run-1', outcome: 'proven', reason: null,
      authority: { kind: 'system_llm_agent', actor: 'verifier' }, evidence: '10 cases', recorded_at: '2026-11-01T00:00:00Z' } } } }
const headers = { 'content-type': 'application/json', 'x-masc-workspace-read': 'matched-v1',
  'x-masc-execution-publication-epoch': epoch, 'x-masc-runtime-instance-id': instance }
const refusal = JSON.stringify({ error: 'invalid token', auth_error_code: 'invalid_token' })

afterEach(() => { setRejectedCredentialListener(null); clearStoredToken(); vi.unstubAllGlobals() })

describe('Goal confirmation credential boundaries', () => {
  it('does not let scoped workspace and Goal tree refusals invoke global credential recovery', async () => {
    setStoredToken('fixture-token')
    const rejected = vi.fn()
    setRejectedCredentialListener(rejected)
    vi.stubGlobal('fetch', vi.fn().mockImplementation(async () => new Response(refusal, { status: 401 })))
    await expect(captureArtifactWorkspace('/workspace-a', undefined, { reportCredentialRefusal: false }))
      .rejects.toMatchObject({ status: 401 })
    await expect(fetchDashboardGoalsTree(workspace)).rejects.toMatchObject({ status: 401 })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(rejected).not.toHaveBeenCalled()
  })
  it('rejects a different execution epoch before waiting for the proof body', async () => {
    let stream!: ReadableStreamDefaultController<Uint8Array>
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      new ReadableStream<Uint8Array>({ start(controller) { stream = controller } }),
      { status: 200, headers: { ...headers, 'x-masc-execution-publication-epoch': 'epoch-b' } },
    )))
    await expect(readGoalConfirmation('goal-1', workspace, epoch)).rejects.toThrow('서버 실행 세대가 변경되어')
    stream.close()
  })

  it('does not report a workspace-bound GET refusal to the global credential listener', async () => {
    setStoredToken('fixture-token')
    const rejected = vi.fn()
    setRejectedCredentialListener(rejected)
    vi.stubGlobal('fetch', vi.fn().mockImplementation(async () => new Response(refusal, { status: 401 })))
    await expect(readGoalConfirmation('goal-1', workspace, epoch)).rejects.toMatchObject({ status: 401 })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(rejected).not.toHaveBeenCalled()
    await expect(get('/api/v1/board/reactions')).rejects.toMatchObject({ status: 401 })
    await vi.waitFor(() => expect(rejected).toHaveBeenCalledOnce())
  })

  it('does not report a delayed POST refusal after its evidence owner may have changed', async () => {
    setStoredToken('fixture-token')
    const rejected = vi.fn()
    setRejectedCredentialListener(rejected)
    let stream!: ReadableStreamDefaultController<Uint8Array>
    const pendingBody = new ReadableStream<Uint8Array>({ start(controller) { stream = controller } })
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
      .mockResolvedValueOnce(new Response(pendingBody, { status: 401 }))
    vi.stubGlobal('fetch', fetchMock)
    const evidence = await readGoalConfirmation('goal-1', workspace, epoch)
    const pending = submitGoalConfirmation(confirmationBinding(evidence))
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    stream.enqueue(new TextEncoder().encode(refusal))
    stream.close()
    await expect(pending).rejects.toMatchObject({ status: 401 })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(rejected).not.toHaveBeenCalled()
  })
})

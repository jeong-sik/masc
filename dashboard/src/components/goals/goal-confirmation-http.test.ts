import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setRejectedCredentialListener } from '../../api/core'
import { GoalConfirmationPanel, _testResetConfirmationReceipts } from './goal-confirmation'

const instance = '018f83d7-93a4-7f5d-9a72-123456789abc'
const epoch = 'epoch-a'
const criterion = { revision: 'revision-1', title: 'Goal', metric: 'cases', target_value: '10' }
const evidence = 'sensitive verifier evidence'
const proof = { inspection_operator_id: 'operator-a',
  goal: { id: 'goal-1', phase: 'awaiting_confirmation', criterion_revision: criterion.revision, ...criterion },
  verification: { goal_id: 'goal-1', updated_at: '2026-11-01T00:00:00Z', completion: { state: 'proof_proven',
    verdict: { criterion, request_id: 'request-1', verification_run_id: 'run-1', outcome: 'proven', reason: null,
      authority: { kind: 'system_llm_agent', actor: 'verifier' }, evidence, recorded_at: '2026-11-01T00:00:00Z' } } } }
const headers = { 'content-type': 'application/json', 'x-masc-workspace-read': 'matched-v1',
  'x-masc-execution-publication-epoch': epoch, 'x-masc-runtime-instance-id': instance }
const owner = { key: 'owner-a', goalId: 'goal-1', workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' },
  credentialScope: 'credential-a', executionEpoch: epoch }
const props = { owner, isCurrent: () => true, readAuthority: {}, lifecyclePending: false,
  hasLifecyclePending: () => false, onConfirmed: vi.fn() }

afterEach(() => { cleanup(); _testResetConfirmationReceipts(); setRejectedCredentialListener(null); clearStoredToken(); vi.unstubAllGlobals() })

describe('Goal confirmation refusal visibility', () => {
  it('shows storage as a possible cause of an unavailable proof and permits a fresh read', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({ error: 'proof backend unavailable' }), { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers })))
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    await screen.findByText(/저장소 상태를 확인한 뒤/)
    expect(screen.queryByText(evidence)).toBeNull()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(evidence)
  })

  it.each([400, 401, 403, 429, 503])('withdraws proof at POST %i headers and retains the completed error detail', async status => {
    let stream!: ReadableStreamDefaultController<Uint8Array>
    const pending = new ReadableStream<Uint8Array>({ start(controller) { stream = controller } })
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
      .mockResolvedValueOnce(new Response(pending, { status }))
      .mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    await screen.findByText(evidence)
    fireEvent.click(screen.getByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(new RegExp(`HTTP ${status}`))
    expect(screen.queryByText(evidence)).toBeNull()
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    stream.enqueue(new TextEncoder().encode(JSON.stringify({ error: 'repair Candle; human confirmation may already be recorded' })))
    stream.close()
    await screen.findByText(/확인 요청의 결과를 다시 조회해 주세요/)
    expect(screen.getByText(new RegExp(`HTTP ${status}`))).toBeTruthy()
    expect(screen.getByText(/서버에 반영되었을 수 있습니다/)).toBeTruthy()
    expect(screen.queryByText(/repair Candle; human confirmation may already be recorded/)).toBeNull()
    expect(fetchMock).toHaveBeenCalledTimes(2)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(evidence)
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('repair Candle; human confirmation may already be recorded')
  })

  it('retains the POST status and unknown outcome when its error body is interrupted', async () => {
    let stream!: ReadableStreamDefaultController<Uint8Array>
    const pending = new ReadableStream<Uint8Array>({ start(controller) { stream = controller } })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
      .mockResolvedValueOnce(new Response(pending, { status: 503 })))
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/HTTP 503/)
    stream.error(new Error('body interrupted'))
    await screen.findByText(/확인 요청의 결과를 다시 조회해 주세요/)
    expect(screen.getByText(/HTTP 503/)).toBeTruthy()
    expect(screen.getByText(/서버에 반영되었을 수 있습니다/)).toBeTruthy()
    expect(screen.queryByText(evidence)).toBeNull()
    expect(screen.queryByText(/body interrupted/)).toBeNull()
  })

  it('labels an old refusal on remount and restores its detail only after fresh authorization', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'repair Candle configuration' }), { status: 400 }))
      .mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers })))
    const first = render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/repair Candle configuration/)).toBeNull()
    first.unmount()
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    await screen.findByText(/이전 요청에서 오류가 발생했습니다/)
    expect(screen.queryByText(/repair Candle configuration/)).toBeNull()
    expect(screen.queryByText(evidence)).toBeNull()
    expect(screen.getByText(/서버에 반영되었을 수 있습니다/)).toBeTruthy()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(evidence)
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('repair Candle configuration')
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('HTTP 400')
  })

  it('hides an uncertain proof during a reread and after a delayed GET refusal', async () => {
    let stream!: ReadableStreamDefaultController<Uint8Array>
    const pending = new ReadableStream<Uint8Array>({ start(controller) { stream = controller } })
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'response unavailable' }), { status: 503 }))
      .mockResolvedValueOnce(new Response(pending, { status: 403 }))
      .mockResolvedValueOnce(new Response(JSON.stringify(proof), { status: 200, headers }))
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3))
    await screen.findByText(/HTTP 403/)
    expect(screen.queryByText(evidence)).toBeNull()
    stream.enqueue(new TextEncoder().encode(JSON.stringify({ error: 'permission revoked' })))
    stream.close()
    await screen.findByText(/증거 조회에 실패했습니다/)
    expect(screen.queryByText(/permission revoked/)).toBeNull()
    expect(screen.getByText(/HTTP 403/)).toBeTruthy()
    expect(screen.getByText(/서버에 반영되었을 수 있습니다/)).toBeTruthy()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(evidence)
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('response unavailable')
    expect(screen.queryByText(/permission revoked/)).toBeNull()
  })
})

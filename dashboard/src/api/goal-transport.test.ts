import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, currentStoredTokenRevision, setStoredToken } from './core'
import { fetchDashboardGoalDetail, fetchDashboardGoalsTree } from './dashboard-goals'
import { devTokenBootstrapStatus, ensureDevToken, resetDevTokenBootstrap } from './dev-token'
import { callMcpTool, callMcpToolAtIdentity, mcpCallFailureDisposition, resetMcpClientState } from './mcp'
import { DEFAULT_GET_TIMEOUT_MS, DEFAULT_MCP_TIMEOUT_MS } from '../config/constants'

vi.mock('./tool-host-failure', () => ({
  // A stuck diagnostics endpoint must not hold the original operation receipt.
  reportToolHostFailure: () => new Promise(() => {}),
}))

const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }

beforeEach(() => {
  vi.useFakeTimers()
  clearStoredToken()
  resetDevTokenBootstrap()
  resetMcpClientState()
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
  clearStoredToken()
  resetDevTokenBootstrap()
  resetMcpClientState()
})

function stalledResponse(status: number, started: () => void, signal: AbortSignal): Response {
  const body = () => {
    started()
    return new Promise<never>((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
    })
  }
  const response = { ok: status === 200, status, statusText: '',
    headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }),
    text: body, json: body, clone: () => response } as unknown as Response
  return response
}

it.each([200, 409])('reports an unknown MCP outcome when the %i body stalls', async status => {
  setStoredToken('manual-test-token', { source: 'manual' })
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => stalledResponse(status, bodyStarted, init.signal!))
  vi.stubGlobal('fetch', fetchMock)
  const result = callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1', action: 'request_complete' },
    { revision: currentStoredTokenRevision(), actor: 'dashboard' }).catch(error => error)
  await started
  await vi.advanceTimersByTimeAsync(DEFAULT_MCP_TIMEOUT_MS)
  const error: unknown = await result
  expect(error).toBeInstanceOf(ApiRequestError)
  expect(error).toMatchObject({ timeout: true })
  expect(mcpCallFailureDisposition(error)).toBe('outcome_unknown')
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it('does not impose the Goal body deadline on other MCP mutations', async () => {
  setStoredToken('manual-test-token', { source: 'manual' })
  let bodyStarted!: () => void
  let finishBody!: (body: string) => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const body = new Promise<string>(resolve => { finishBody = resolve })
  const response = { ok: true, status: 200, headers: new Headers(), text: () => {
    bodyStarted()
    return body
  } } as unknown as Response
  vi.stubGlobal('fetch', vi.fn(async () => response))
  let settled = false
  const result = callMcpTool('masc_goal_upsert', { title: 'new goal' }).finally(() => { settled = true })
  await started
  await vi.advanceTimersByTimeAsync(DEFAULT_MCP_TIMEOUT_MS * 2)
  expect(settled).toBe(false)
  finishBody(JSON.stringify({ result: { content: [{ type: 'text', text: 'created' }] } }))
  await expect(result).resolves.toBe('created')
})

it.each(['tree', 'detail'] as const)('times out a stalled bound Goal %s read', async kind => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => stalledResponse(200, bodyStarted, init.signal!))
  vi.stubGlobal('fetch', fetchMock)
  const result = (kind === 'tree' ? fetchDashboardGoalsTree(workspace)
    : fetchDashboardGoalDetail('goal-1', workspace)).catch(error => error)
  await started
  await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
  expect(await result).toMatchObject({ timeout: true })
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it('releases dev-token bootstrap when the response body stalls', async () => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => stalledResponse(200, bodyStarted, init.signal!))
  vi.stubGlobal('fetch', fetchMock)
  const result = ensureDevToken()
  await started
  await vi.advanceTimersByTimeAsync(3000)
  await result
  expect(devTokenBootstrapStatus.value).toBe('network')
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

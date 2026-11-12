import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecutionWorkspaceAuthority } from '../store'
import type { NestedReading, OriginalToolResult } from '../api/composition-observation'
const api = vi.hoisted(() => ({ fetchAsyncRequestStatus: vi.fn(), fetchOriginalToolResult: vi.fn() }))
const workspace = vi.hoisted(() => ({ current: null as unknown as ReturnType<typeof signal<ExecutionWorkspaceAuthority | null>> }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  workspace.current = signal<ExecutionWorkspaceAuthority | null>(null)
  return { executionWorkspaceAuthority: workspace.current }
})
vi.mock('../api/composition-observation', async original => ({ ...await original<typeof import('../api/composition-observation')>(), ...api }))
import { clearStoredToken, setStoredToken } from '../api/core'
import { asyncRequestSourceKey, ObservationReadError } from '../api/composition-observation'
import { AsyncRequestDetails, OriginalToolResultInspector, NestedExecutionView } from './composition-observation-view'

const authority = () => ({ epoch: 'fixture', workspaceRoot: '/workspace', connectionGeneration: 1, observerInstanceId: null })
const reference = { identity: { source_id: 'workspace', package_id: 'child', name: 'child' }, content_revision: 'd'.repeat(64) }
const nested: NestedReading = { kind: 'observed', children: [{ alias: 'actual-child', reference, execution: 'async',
  arguments: { kind: 'fixed', value: { argument: 'declared' } }, admission: { kind: 'not_attempted' },
  disposition: 'partially_settled', cause: { kind: 'upstream_failed' }, nodes: [
    { node_id: 'submit', origin: { phase: 'submission' }, disposition: 'deferred', tool_use_id: 'submit-once', effect_disposition: 'effect_outcome_unknown', validation_error: null },
    { node_id: 'result', origin: { phase: 'result' }, disposition: null, tool_use_id: null, effect_disposition: null, validation_error: null },
  ], exports: [{ name: 'final', node_id: 'result', pointer: '/value', value: { available: false, error: { kind: 'producer_unavailable' } } }] }] }
function original(content: string): Extract<OriginalToolResult, { state: 'body' }> {
  return { state: 'body', source_id: 'a'.repeat(64), body_sha256: 'b'.repeat(64), recorded_bytes: content.length, is_error: false, content, nested }
}
function pending<T>() {
  let resolve!: (value: T) => void, reject!: (error: Error) => void
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail })
  return { promise, resolve, reject }
}
const lookup = { submitted_by: 'original-submitter', request_id: 'retained-request', keeper_name: 'observer' }
beforeEach(() => {
  workspace.current.value = authority()
  setStoredToken('credential-a')
  api.fetchOriginalToolResult.mockReset(); api.fetchAsyncRequestStatus.mockReset()
  api.fetchOriginalToolResult.mockResolvedValue(original('retained original body'))
  api.fetchAsyncRequestStatus.mockResolvedValue({ status: 'observed', request: { ...lookup, request_context: null, status: 'done' }, nested })
})
afterEach(() => { cleanup(); clearStoredToken() })

describe('actual nested result views', () => {
  it('renders observed settlement, occurrence, cause and unavailable exports without treating a declaration as success', () => {
    render(html`<${NestedExecutionView} reading=${nested} />`)
    expect(screen.getByTestId('nested-execution-child').textContent).toContain('partially_settled')
    expect(screen.getByText(/occurrence submit-once/)).toBeTruthy()
    expect(screen.getByText(/Effect evidence: effect_outcome_unknown/)).toBeTruthy()
    expect(screen.getAllByText(/producer_unavailable/).length).toBeGreaterThan(0)
    expect(screen.getByText(/not settled/)).toBeTruthy()
  })

  it('waits for an explicit original read and never displays a ledger preview as original evidence', async () => {
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    expect(api.fetchOriginalToolResult).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByText('retained original body')
    expect(api.fetchOriginalToolResult).toHaveBeenCalledWith('observer', 'exec-exact', { signal: expect.any(AbortSignal) })
    expect(screen.getByTestId('nested-execution-child')).toBeTruthy()
  })

  it.each(['success', 'failure'])('rejects late original %s across auth A to B to A', async outcome => {
    const old = pending<OriginalToolResult>(), fresh = pending<OriginalToolResult>()
    api.fetchOriginalToolResult.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise)
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await waitFor(() => expect(api.fetchOriginalToolResult).toHaveBeenCalledTimes(1))
    const oldSignal = api.fetchOriginalToolResult.mock.calls[0]![2].signal as AbortSignal
    await act(async () => { setStoredToken('credential-b'); setStoredToken('credential-a') })
    expect(screen.queryByText('Reading and verifying original result…')).toBeNull()
    await waitFor(() => expect(oldSignal.aborted).toBe(true))
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await act(async () => fresh.resolve(original('fresh original')))
    await screen.findByText('fresh original')
    await act(async () => {
      if (outcome === 'success') old.resolve(original('retired original body'))
      else old.reject(new Error('retired source error'))
    })
    expect(screen.queryByText(/retired source error/)).toBeNull()
    expect(screen.queryByText('retired original body')).toBeNull()
    expect(screen.getByText('fresh original')).toBeTruthy()
  })

  it('withdraws original bytes when the workspace authority changes even if fields compare equal', async () => {
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByText('retained original body')
    await act(async () => { workspace.current.value = authority() })
    expect(screen.queryByText('retained original body')).toBeNull()
    await act(async () => { workspace.current.value = null })
    expect(screen.queryByRole('button', { name: 'Read original result' })).toBeNull()
    expect(api.fetchOriginalToolResult).toHaveBeenCalledTimes(1)
  })

  it('cancels an old execution read and ignores its late body after selecting another execution', async () => {
    const old = pending<OriginalToolResult>()
    api.fetchOriginalToolResult.mockReturnValueOnce(old.promise)
    const view = render(html`<${OriginalToolResultInspector} keeper="observer" executionId="old-execution" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    const oldSignal = api.fetchOriginalToolResult.mock.calls[0]![2].signal as AbortSignal
    view.rerender(html`<${OriginalToolResultInspector} keeper="observer" executionId="new-execution" />`)
    await waitFor(() => expect(oldSignal.aborted).toBe(true))
    await act(async () => old.resolve(original('retired execution body')))
    expect(screen.queryByText('retired execution body')).toBeNull()
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
  })

  it('binds async status to the exact original triple and cancels it on workspace withdrawal', async () => {
    const old = pending<unknown>()
    api.fetchAsyncRequestStatus.mockReturnValueOnce(old.promise)
    render(html`<${AsyncRequestDetails} identity=${lookup} isCurrent=${() => true} />`)
    await waitFor(() => expect(api.fetchAsyncRequestStatus).toHaveBeenCalledWith(lookup, { signal: expect.any(AbortSignal) }))
    const signal = api.fetchAsyncRequestStatus.mock.calls[0]![1].signal as AbortSignal
    await act(async () => { workspace.current.value = null })
    await waitFor(() => expect(signal.aborted).toBe(true))
    await act(async () => old.resolve({ status: 'observed', request: { status: 'done' }, nested }))
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
  })

  it('keeps the last verified original source explicitly stale while refresh is pending and after a transport failure', async () => {
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByTestId('nested-execution-child')
    const refresh = pending<OriginalToolResult>()
    api.fetchOriginalToolResult.mockReturnValueOnce(refresh.promise)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    expect(screen.getByTestId('nested-execution-child')).toBeTruthy()
    expect(screen.getByText(/Showing last verified nested evidence/)).toBeTruthy()
    await act(async () => refresh.reject(new Error('original read unavailable')))
    expect(screen.getByText('original read unavailable')).toBeTruthy()
    expect(screen.getByText('retained original body')).toBeTruthy()
    expect(screen.getByTestId('nested-execution-child')).toBeTruthy()
  })

  it.each(['pending', 'unavailable'] as const)('retains verified body and children after original refresh state %s', async state => {
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByTestId('nested-execution-child')
    api.fetchOriginalToolResult.mockResolvedValueOnce(state === 'pending' ? { state }
      : { state, reason: 'original trace unavailable' })
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByRole('alert')
    expect(screen.getByText('retained original body')).toBeTruthy()
    expect(screen.getByTestId('nested-execution-child')).toBeTruthy()
    expect(screen.getByText(/Showing last verified nested evidence/)).toBeTruthy()
    expect(screen.getByText('The retained original-result snapshot is stale.')).toBeTruthy()
  })

  it.each(['pending', 'unavailable'] as const)('shows initial original state %s without inventing a prior verified body', async state => {
    api.fetchOriginalToolResult.mockResolvedValueOnce(state === 'pending' ? { state }
      : { state, reason: 'no raw trace retained' })
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByText(state === 'pending' ? 'Original result pending' : 'Original result unavailable: no raw trace retained')
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
    expect(screen.queryByText(/Showing last verified nested evidence/)).toBeNull()
    expect(screen.queryByText('The retained original-result snapshot is stale.')).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it.each(['same', 'source_id', 'body_sha256'] as const)('retains invalid nested refresh only for the %s original source', async change => {
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByTestId('nested-execution-child')
    const latest = { ...original('latest physical body'), nested: { kind: 'invalid' as const, detail: 'manifest no longer readable' } }
    if (change !== 'same') latest[change] = 'e'.repeat(64)
    api.fetchOriginalToolResult.mockResolvedValueOnce(latest)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByText(/manifest no longer readable/)
    expect(screen.getByText('latest physical body')).toBeTruthy()
    expect(screen.queryByTestId('nested-execution-child') !== null).toBe(change === 'same')
    expect(screen.queryByText(/Showing last verified nested evidence/) !== null).toBe(change === 'same')
    if (change !== 'same') {
      api.fetchOriginalToolResult.mockResolvedValueOnce({ state: 'pending' })
      fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
      await screen.findByText('Original result pending')
      expect(screen.queryByTestId('nested-execution-child')).toBeNull()
      expect(screen.getByText('latest physical body')).toBeTruthy()
    }
  })

  it('shows first-time invalid nested evidence alongside its actual physical original body', async () => {
    api.fetchOriginalToolResult.mockResolvedValueOnce({ ...original('physical body with invalid metadata'), nested: { kind: 'invalid', detail: 'first manifest failed' } })
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByText('physical body with invalid metadata')
    expect(screen.getByText(/first manifest failed/)).toBeTruthy()
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
    expect(screen.queryByText(/Showing last verified nested evidence/)).toBeNull()
  })

  it('preserves same-context async children through transport failure and canonical key reordering, but not a changed context', async () => {
    const request = { ...lookup, status: 'done', request_context: { source: 'composition', nested: { x: 1, y: 2 } } }
    api.fetchAsyncRequestStatus.mockResolvedValueOnce({ status: 'observed', request, nested })
    render(html`<${AsyncRequestDetails} identity=${lookup} isCurrent=${() => true} />`)
    await screen.findByTestId('nested-execution-child')
    api.fetchAsyncRequestStatus.mockRejectedValueOnce(new Error('status lookup unavailable'))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh exact request' }))
    await screen.findByText('status lookup unavailable')
    expect(screen.getByTestId('nested-execution-child')).toBeTruthy()
    api.fetchAsyncRequestStatus.mockResolvedValueOnce({ status: 'observed', request: { ...request,
      request_context: { nested: { y: 2, x: 1 }, source: 'composition' } }, nested: { kind: 'invalid', detail: 'nested refresh invalid' } })
    fireEvent.click(screen.getByRole('button', { name: 'Refresh exact request' }))
    await screen.findByText(/nested refresh invalid/)
    expect(screen.getByTestId('nested-execution-child')).toBeTruthy()
    expect(screen.getByText(/Showing last verified nested evidence/)).toBeTruthy()
    api.fetchAsyncRequestStatus.mockResolvedValueOnce({ status: 'observed', request: { ...request,
      request_context: { source: 'replacement' } }, nested: { kind: 'invalid', detail: 'replacement source invalid' } })
    fireEvent.click(screen.getByRole('button', { name: 'Refresh exact request' }))
    await screen.findByText(/replacement source invalid/)
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
    expect(screen.queryByText(/Showing last verified nested evidence/)).toBeNull()
  })

  it.each(['auth', 'workspace', 'target'])('never carries last-good children into another %s owner', async change => {
    const view = render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByTestId('nested-execution-child')
    if (change === 'auth') await act(async () => { setStoredToken('credential-b'); setStoredToken('credential-a') })
    if (change === 'workspace') await act(async () => { workspace.current.value = authority() })
    if (change === 'target') view.rerender(html`<${OriginalToolResultInspector} keeper="observer" executionId="another-execution" />`)
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
    expect(screen.queryByText('retained original body')).toBeNull()
  })

  it('does not carry children after an original read reports a different source before a later page fails', async () => {
    render(html`<${OriginalToolResultInspector} keeper="observer" executionId="exec-exact" />`)
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByTestId('nested-execution-child')
    api.fetchOriginalToolResult.mockRejectedValueOnce(new ObservationReadError('new source page corrupt', JSON.stringify(['e'.repeat(64), 'f'.repeat(64)])))
    fireEvent.click(screen.getByRole('button', { name: 'Read original result' }))
    await screen.findByText('new source page corrupt')
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
    expect(screen.queryByText('retained original body')).toBeNull()
  })

  it('does not carry prior-context children when a new context has an invalid physical or logical payload', async () => {
    render(html`<${AsyncRequestDetails} identity=${lookup} isCurrent=${() => true} />`)
    await screen.findByTestId('nested-execution-child')
    const source = asyncRequestSourceKey({ status: 'observed', request: { ...lookup, request_context: { changed: true } }, nested: { kind: 'absent' } })
    api.fetchAsyncRequestStatus.mockRejectedValueOnce(new ObservationReadError('changed context payload rejected', source))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh exact request' }))
    await screen.findByText('changed context payload rejected')
    expect(screen.queryByTestId('nested-execution-child')).toBeNull()
    expect(screen.queryByText(/Showing last verified nested evidence/)).toBeNull()
  })
})

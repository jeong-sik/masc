import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { clearStoredToken, setStoredToken } from '../api/core'
import { useManagedAsyncResource } from './use-managed-async-resource'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'

interface Pending {
  readonly signal: AbortSignal
  readonly resolve: (value: string) => void
}
const readCompletions: Promise<unknown>[] = []
async function complete(calls: Pending[], index: number, value: string, readIndex = index) {
  await act(async () => {
    calls[index]!.resolve(value)
    await readCompletions[readIndex]
  })
}

function pendingLoads() {
  const calls: Pending[] = []
  const load = vi.fn((signal: AbortSignal) => new Promise<string>((resolve) => {
    calls.push({ signal, resolve })
  }))
  return { calls, load }
}

function Probe({ load }: { load: (signal: AbortSignal) => Promise<string> }) {
  const resource = useManagedAsyncResource<string>(null)
  useEffect(() => {
    readCompletions.push(resource.load(load))
    return () => { resource.cancel() }
  }, [load, resource])
  return html`<output data-testid="data">${resource.state.value.data ?? ''}</output>`
}

const shown = () => screen.getByTestId('data').textContent

describe('useManagedAsyncResource credential scope', () => {
  beforeEach(() => {
    readCompletions.length = 0
    setStoredToken('admin-token', { source: 'manual' })
    acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'fixture', workspaceRoot: '/workspace-a',
      connectionGeneration: 0, observerInstanceId: 'workspace-a-instance' })
  })
  afterEach(() => {
    cleanup()
    acceptedExecutionWorkspace.value = null
    clearStoredToken()
  })

  it('stops rendering what the previous credential loaded and loads again', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await complete(calls, 0, 'admin evidence')
    expect(shown()).toBe('admin evidence')

    await act(async () => { clearStoredToken() })

    expect(shown()).toBe('')
    expect(load).toHaveBeenCalledTimes(2)
    await complete(calls, 1, 'anonymous view')
    expect(shown()).toBe('anonymous view')
  })

  it('drops a response that was still in flight when the credential changed', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)

    await act(async () => { setStoredToken('worker-token', { source: 'manual' }) })

    expect(calls[0]?.signal.aborted).toBe(true)
    await complete(calls, 1, 'worker view')
    await complete(calls, 0, 'admin evidence')
    expect(shown()).toBe('worker view')
  })

  it('keeps the resource and does not load again when the same credential is written', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await complete(calls, 0, 'admin evidence')

    await act(async () => { setStoredToken(' admin-token ', { source: 'manual' }) })

    expect(load).toHaveBeenCalledTimes(1)
    expect(shown()).toBe('admin evidence')
  })

  it('withdraws previous workspace evidence while its replacement is pending', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await complete(calls, 0, 'workspace A evidence')
    expect(shown()).toBe('workspace A evidence')
    await act(async () => {
      acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'fixture', workspaceRoot: '/workspace-b',
        connectionGeneration: 1, observerInstanceId: 'workspace-b-instance' })
    })
    expect(shown()).toBe('')
    expect(load).toHaveBeenCalledTimes(2)
    await complete(calls, 1, 'workspace B evidence')
    expect(shown()).toBe('workspace B evidence')
  })

  it('retires a still pending workspace read before accepting the new one', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await act(async () => {
      acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'fixture', workspaceRoot: '/workspace-b',
        connectionGeneration: 1, observerInstanceId: 'workspace-b-instance' })
    })
    expect(calls[0]!.signal.aborted).toBe(true)
    await complete(calls, 1, 'workspace B evidence')
    await complete(calls, 0, 'late workspace A evidence')
    expect(shown()).toBe('workspace B evidence')
  })

  it('waits for an accepted workspace before starting a read', async () => {
    const authority = acceptedExecutionWorkspace.peek()
    acceptedExecutionWorkspace.value = null
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await act(async () => {})
    expect(load).not.toHaveBeenCalled()
    expect(shown()).toBe('')
    await act(async () => { acceptedExecutionWorkspace.value = authority })
    expect(load).toHaveBeenCalledTimes(1)
    await complete(calls, 0, 'confirmed workspace', 1)
    expect(shown()).toBe('confirmed workspace')
  })
})

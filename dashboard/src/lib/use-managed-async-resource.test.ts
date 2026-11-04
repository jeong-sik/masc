import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { clearStoredToken, setStoredToken } from '../api/core'
import { useManagedAsyncResource } from './use-managed-async-resource'

interface Pending {
  readonly signal: AbortSignal
  readonly resolve: (value: string) => void
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
    void resource.load(load)
    return () => { resource.cancel() }
  }, [load, resource])
  return html`<output data-testid="data">${resource.state.value.data ?? ''}</output>`
}

const shown = () => screen.getByTestId('data').textContent

describe('useManagedAsyncResource credential scope', () => {
  beforeEach(() => { setStoredToken('admin-token', { source: 'manual' }) })
  afterEach(() => {
    cleanup()
    clearStoredToken()
  })

  it('stops rendering what the previous credential loaded and loads again', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await act(async () => { calls[0]?.resolve('admin evidence') })
    expect(shown()).toBe('admin evidence')

    await act(async () => { clearStoredToken() })

    expect(shown()).toBe('')
    expect(load).toHaveBeenCalledTimes(2)
    await act(async () => { calls[1]?.resolve('anonymous view') })
    expect(shown()).toBe('anonymous view')
  })

  it('drops a response that was still in flight when the credential changed', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)

    await act(async () => { setStoredToken('worker-token', { source: 'manual' }) })

    expect(calls[0]?.signal.aborted).toBe(true)
    await act(async () => { calls[1]?.resolve('worker view') })
    await act(async () => { calls[0]?.resolve('admin evidence') })
    expect(shown()).toBe('worker view')
  })

  it('keeps the resource and does not load again when the same credential is written', async () => {
    const { calls, load } = pendingLoads()
    render(html`<${Probe} load=${load} />`)
    await act(async () => { calls[0]?.resolve('admin evidence') })

    await act(async () => { setStoredToken(' admin-token ', { source: 'manual' }) })

    expect(load).toHaveBeenCalledTimes(1)
    expect(shown()).toBe('admin evidence')
  })
})

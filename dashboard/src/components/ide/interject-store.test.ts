import { describe, expect, it, vi } from 'vitest'
import {
  createInterjectStore,
  type InterjectDispatchRequest,
} from './interject-store'

describe('createInterjectStore', () => {
  it('enables send only when an active keeper and message are present', async () => {
    const dispatch = vi.fn<(request: InterjectDispatchRequest) => Promise<void>>()
      .mockResolvedValue(undefined)
    const store = createInterjectStore({
      initialActiveKeeper: ' nick0cave ',
      dispatch,
      now: () => 42,
    })

    expect(store.snapshot().active_keeper_id).toBe('nick0cave')
    expect(store.actions().find(action => action.kind === 'send')?.enabled).toBe(false)

    store.setMessage('  ship the fix  ')
    expect(store.actions().find(action => action.kind === 'send')?.enabled).toBe(true)

    await expect(store.submit('send')).resolves.toBe(true)
    expect(dispatch).toHaveBeenCalledWith({
      kind: 'send',
      keeper_id: 'nick0cave',
      message: 'ship the fix',
      timestamp_ms: 42,
    })
    expect(store.snapshot().message).toBe('')
    expect(store.snapshot().last_dispatch?.kind).toBe('send')
  })

  it('keeps unsupported keeper actions disabled by default', async () => {
    const dispatch = vi.fn()
    const store = createInterjectStore({
      initialActiveKeeper: 'nick0cave',
      dispatch,
    })

    const pause = store.actions().find(action => action.kind === 'pause')
    expect(pause?.enabled).toBe(false)
    expect(pause?.disabled_reason).toContain('Keeper-scoped pause')

    await expect(store.submit('pause')).resolves.toBe(false)
    expect(dispatch).not.toHaveBeenCalled()
    expect(store.snapshot().error).toContain('Keeper-scoped pause')
  })

  it('dispatches explicitly enabled non-message actions', async () => {
    const dispatch = vi.fn<(request: InterjectDispatchRequest) => Promise<void>>()
      .mockResolvedValue(undefined)
    const store = createInterjectStore({
      initialActiveKeeper: 'sangsu',
      actionPolicy: {
        approve: { enabled: true },
      },
      dispatch,
      now: () => 100,
    })

    await expect(store.submit('approve')).resolves.toBe(true)
    expect(dispatch).toHaveBeenCalledWith({
      kind: 'approve',
      keeper_id: 'sangsu',
      message: undefined,
      timestamp_ms: 100,
    })
  })

  it('notifies subscribers when snapshots change', () => {
    const store = createInterjectStore({
      initialActiveKeeper: 'nick0cave',
      dispatch: vi.fn(),
    })
    let calls = 0
    const unsubscribe = store.subscribe(() => {
      calls += 1
    })

    store.setMessage('hello')
    store.setActiveKeeper('masc-improver')
    unsubscribe()
    store.setMessage('ignored')

    expect(calls).toBe(2)
  })
})

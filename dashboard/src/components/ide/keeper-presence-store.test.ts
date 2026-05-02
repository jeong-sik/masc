import { describe, expect, it } from 'vitest'
import {
  createKeeperPresenceStore,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'

const sample: KeeperPresenceSnapshot = {
  runtime_id: 'runtime',
  branch: 'main',
  supervisor: 'local',
  connected: true,
  entries: [
    {
      keeper_id: 'idle-keeper',
      workspace_label: 'wt-idle',
      branch: 'main',
      role: 'observer',
      status: 'idle',
      last_seen_ms: 1000,
    },
    {
      keeper_id: 'nick0cave',
      workspace_label: 'dkr-a1',
      branch: 'main',
      role: 'driver',
      status: 'active',
      last_seen_ms: 2000,
    },
  ],
}

describe('createKeeperPresenceStore', () => {
  it('seeds a sorted presence snapshot', () => {
    const store = createKeeperPresenceStore(sample)

    expect(store.snapshot()).toMatchObject({
      runtime_id: 'runtime',
      branch: 'main',
      supervisor: 'local',
      connected: true,
    })
    expect(store.entries().map(entry => entry.keeper_id)).toEqual(['nick0cave', 'idle-keeper'])
    expect(store.activeEntries().map(entry => entry.keeper_id)).toEqual(['nick0cave'])
    expect(store.entryForKeeper('nick0cave')?.workspace_label).toBe('dkr-a1')
  })

  it('rejects malformed snapshots without replacing the current one', () => {
    const store = createKeeperPresenceStore(sample)

    expect(store.seed({ runtime_id: '', entries: [] })).toBe(false)
    expect(store.entries().map(entry => entry.keeper_id)).toEqual(['nick0cave', 'idle-keeper'])
  })

  it('publishes subscribers on seed and reset', () => {
    const store = createKeeperPresenceStore()
    let calls = 0
    const unsubscribe = store.subscribe(() => {
      calls += 1
    })

    expect(store.seed(sample)).toBe(true)
    store.reset()
    unsubscribe()
    store.seed(sample)

    expect(calls).toBe(2)
    expect(store.entries().map(entry => entry.keeper_id)).toEqual(['nick0cave', 'idle-keeper'])
  })
})

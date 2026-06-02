import { describe, expect, it } from 'vitest'

import type { Keeper } from '../types'
import { resolveKeeperForDetail } from './keeper-detail-resolution'

// #12283: dead-keeper resolution. Pre-fix, the panel kept rendering a
// stale [selectedKeeper.value] after the live registry had dropped it
// (e.g. stale-watchdog kill), causing "insertBefore parameter 1 is not
// of type 'Node'" downstream. The resolver now refuses the fallback
// when the registry is non-empty AND the target is missing.
//
// Pure unit tests — no React render, no signal harness. Lives in
// [src/lib/] to dodge the [src/components/keeper-detail.test.ts] mock
// chain that breaks on lucide-preact during setup.
describe('resolveKeeperForDetail (#12283)', () => {
  const live: Keeper = { name: 'sangsu', agent_name: 'sangsu' } as unknown as Keeper
  const stale: Keeper = { name: 'sangsu', agent_name: 'sangsu' } as unknown as Keeper

  it('prefers the live registry hit', () => {
    expect(resolveKeeperForDetail('sangsu', live, stale, 11)).toBe(live)
  })

  it('returns null when registry is loaded but target is absent (regression guard)', () => {
    // Pre-fix returned the stale fallback here, leading to crash. Post-fix
    // returns null so the caller renders the missing-state.
    expect(resolveKeeperForDetail('sangsu', null, stale, 11)).toBeNull()
  })

  it('honors fallback during registry-empty transition', () => {
    // Registry count = 0 means the snapshot has not loaded yet — keep
    // the cached pin so operators do not see a flash of "missing".
    expect(resolveKeeperForDetail('sangsu', null, stale, 0)).toBe(stale)
  })

  it('rejects fallback whose name does not match the requested keeper', () => {
    const other: Keeper = { name: 'qa-king', agent_name: 'qa-king' } as unknown as Keeper
    expect(resolveKeeperForDetail('sangsu', null, other, 0)).toBeNull()
  })

  it('matches fallback by agent_name', () => {
    const aliased: Keeper = { name: 'sangsu', agent_name: 'sangsu_v2' } as unknown as Keeper
    expect(resolveKeeperForDetail('sangsu_v2', null, aliased, 0)).toBe(aliased)
  })

  it('returns null when both live and fallback are absent', () => {
    expect(resolveKeeperForDetail('sangsu', null, null, 11)).toBeNull()
    expect(resolveKeeperForDetail('sangsu', null, null, 0)).toBeNull()
  })
})

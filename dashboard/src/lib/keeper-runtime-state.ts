// Typed parsers for keeper wire-format state strings.
//
// Companion to `lib/runtime-blocker-class.ts` — same boundary
// hardening pattern (string → closed-union narrowing at the wire
// boundary, `null` for anything else).
//
// Why a parser at all? Backend emits closed `pause_state` and
// `runtime_blocker_state` vocabularies.
// Previously `KeeperPauseState` carried a `| string` catch-all that
// hid this fact and let unmapped values flow silently through type
// narrowing (workaround-rejection-bar §5).
//
// This module is the SSOT for the *wire → typed* transition.

import type { KeeperPauseState, KeeperRuntimeBlockerState } from '../types'

const PAUSE_STATE_VALUES: ReadonlySet<string> = new Set([
  'active',
  'paused',
] satisfies readonly KeeperPauseState[])

const RUNTIME_BLOCKER_STATE_VALUES: ReadonlySet<string> = new Set([
  'clear',
  'blocked',
] satisfies readonly KeeperRuntimeBlockerState[])

export function isKeeperPauseState(value: string): value is KeeperPauseState {
  return PAUSE_STATE_VALUES.has(value)
}

export function asKeeperPauseState(
  value: unknown,
): KeeperPauseState | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  if (trimmed === '') return null
  return isKeeperPauseState(trimmed) ? trimmed : null
}

export function isKeeperRuntimeBlockerState(
  value: string,
): value is KeeperRuntimeBlockerState {
  return RUNTIME_BLOCKER_STATE_VALUES.has(value)
}

export function asKeeperRuntimeBlockerState(
  value: unknown,
): KeeperRuntimeBlockerState | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  if (trimmed === '') return null
  return isKeeperRuntimeBlockerState(trimmed) ? trimmed : null
}

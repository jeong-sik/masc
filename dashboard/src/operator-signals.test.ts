import { afterEach, describe, it, expect } from 'vitest'

import {
  operatorSnapshot,
  operatorWorkspaceDigest,
  operatorLoading,
  operatorError,
  operatorErrorStatus,
  operatorDigestLoading,
  operatorDigestError,
  operatorDigestErrorStatus,
  operatorActionBusy,
  operatorActionLog,
} from './operator-signals'

import type { OperatorActionLogEntry, OperatorDigest, OperatorSnapshot } from './types'

// Minimal values matching the real interfaces in types/dashboard-mission.ts —
// only required fields, so type drift in those interfaces fails this file at tsc.
const makeSnapshot = (): OperatorSnapshot => ({
  root: {},
  sessions: [],
  keepers: [],
  recent_messages: [],
  pending_confirms: [],
  available_actions: [],
})

const makeDigest = (): OperatorDigest => ({
  target_type: 'root',
  attention_items: [],
  recommended_actions: [],
  recent_reviews: [],
})

const makeLogEntry = (overrides: Partial<OperatorActionLogEntry> = {}): OperatorActionLogEntry => ({
  id: 1,
  at: '2026-06-10T00:00:00Z',
  actor: 'operator',
  action_type: 'refresh_snapshot',
  target_label: 'root',
  outcome: 'executed',
  message: 'ok',
  ...overrides,
})

// ─── Initial value validation ────────────────────────────────────

describe('operator-signals — initial values', () => {
  it('operatorSnapshot starts as null', () => {
    expect(operatorSnapshot.value).toBeNull()
  })

  it('operatorWorkspaceDigest starts as null', () => {
    expect(operatorWorkspaceDigest.value).toBeNull()
  })

  it('operatorLoading starts as false', () => {
    expect(operatorLoading.value).toBe(false)
  })

  it('operatorError starts as null', () => {
    expect(operatorError.value).toBeNull()
  })

  it('operatorErrorStatus starts as null', () => {
    expect(operatorErrorStatus.value).toBeNull()
  })

  it('operatorDigestLoading starts as false', () => {
    expect(operatorDigestLoading.value).toBe(false)
  })

  it('operatorDigestError starts as null', () => {
    expect(operatorDigestError.value).toBeNull()
  })

  it('operatorDigestErrorStatus starts as null', () => {
    expect(operatorDigestErrorStatus.value).toBeNull()
  })

  it('operatorActionBusy starts as false', () => {
    expect(operatorActionBusy.value).toBe(false)
  })

  it('operatorActionLog starts as empty array', () => {
    expect(operatorActionLog.value).toEqual([])
  })
})

// ─── Signal mutation behaviour ───────────────────────────────────

describe('operator-signals — mutation', () => {
  afterEach(() => {
    // Reset all signals to initial values
    operatorSnapshot.value = null
    operatorWorkspaceDigest.value = null
    operatorLoading.value = false
    operatorError.value = null
    operatorErrorStatus.value = null
    operatorDigestLoading.value = false
    operatorDigestError.value = null
    operatorDigestErrorStatus.value = null
    operatorActionBusy.value = false
    operatorActionLog.value = []
  })

  it('operatorSnapshot accepts and returns an OperatorSnapshot object', () => {
    const snap = makeSnapshot()
    operatorSnapshot.value = snap
    expect(operatorSnapshot.value).toEqual(snap)
  })

  it('operatorSnapshot can be set back to null', () => {
    operatorSnapshot.value = makeSnapshot()
    operatorSnapshot.value = null
    expect(operatorSnapshot.value).toBeNull()
  })

  it('operatorWorkspaceDigest accepts an OperatorDigest object', () => {
    const digest = makeDigest()
    operatorWorkspaceDigest.value = digest
    expect(operatorWorkspaceDigest.value).toEqual(digest)
  })

  it('operatorLoading toggles true/false', () => {
    operatorLoading.value = true
    expect(operatorLoading.value).toBe(true)
    operatorLoading.value = false
    expect(operatorLoading.value).toBe(false)
  })

  it('operatorError accepts error string', () => {
    operatorError.value = 'timeout fetching snapshot'
    expect(operatorError.value).toBe('timeout fetching snapshot')
  })

  it('operatorErrorStatus accepts HTTP status number', () => {
    operatorErrorStatus.value = 503
    expect(operatorErrorStatus.value).toBe(503)
  })

  it('operatorDigestLoading toggles true/false', () => {
    operatorDigestLoading.value = true
    expect(operatorDigestLoading.value).toBe(true)
    operatorDigestLoading.value = false
    expect(operatorDigestLoading.value).toBe(false)
  })

  it('operatorDigestError accepts error string', () => {
    operatorDigestError.value = 'digest fetch failed'
    expect(operatorDigestError.value).toBe('digest fetch failed')
  })

  it('operatorDigestErrorStatus accepts HTTP status number', () => {
    operatorDigestErrorStatus.value = 502
    expect(operatorDigestErrorStatus.value).toBe(502)
  })

  it('operatorActionBusy toggles true/false', () => {
    operatorActionBusy.value = true
    expect(operatorActionBusy.value).toBe(true)
    operatorActionBusy.value = false
    expect(operatorActionBusy.value).toBe(false)
  })

  it('operatorActionLog accepts an array of log entries', () => {
    const entry = makeLogEntry()
    operatorActionLog.value = [entry]
    expect(operatorActionLog.value).toHaveLength(1)
    expect(operatorActionLog.value[0]?.action_type).toBe('refresh_snapshot')
  })

  it('operatorActionLog can be cleared back to []', () => {
    operatorActionLog.value = [makeLogEntry({ id: 2, outcome: 'preview' })]
    operatorActionLog.value = []
    expect(operatorActionLog.value).toEqual([])
  })

  it('multiple signals can be set independently without interference', () => {
    operatorSnapshot.value = makeSnapshot()
    operatorLoading.value = true
    operatorError.value = 'test error'

    expect(operatorWorkspaceDigest.value).toBeNull() // unchanged
    expect(operatorDigestLoading.value).toBe(false) // unchanged
    expect(operatorActionLog.value).toEqual([]) // unchanged

    // Cleanup for other tests
    operatorSnapshot.value = null
    operatorLoading.value = false
    operatorError.value = null
  })
})
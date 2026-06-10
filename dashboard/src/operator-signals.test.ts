import { describe, it, expect } from 'vitest'

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
    const snap: OperatorSnapshot = {
      name: 'sangsu',
      status: 'active',
      uptime_seconds: 3600,
      memory_turns: 42,
    }
    operatorSnapshot.value = snap
    expect(operatorSnapshot.value).toEqual(snap)
  })

  it('operatorSnapshot can be set back to null', () => {
    operatorSnapshot.value = { name: 'sangsu', status: 'active', uptime_seconds: 0, memory_turns: 0 } as OperatorSnapshot
    operatorSnapshot.value = null
    expect(operatorSnapshot.value).toBeNull()
  })

  it('operatorWorkspaceDigest accepts an OperatorDigest object', () => {
    const digest: OperatorDigest = {
      active_count: 3,
      idle_count: 5,
      total_keepers: 8,
    }
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
    const entry: OperatorActionLogEntry = {
      action: 'refresh_snapshot',
      timestamp: Date.now(),
      status: 'success',
    }
    operatorActionLog.value = [entry]
    expect(operatorActionLog.value).toHaveLength(1)
    expect(operatorActionLog.value![0].action).toBe('refresh_snapshot')
  })

  it('operatorActionLog can be cleared back to []', () => {
    operatorActionLog.value = [{ action: 'test', timestamp: 0, status: 'pending' }]
    operatorActionLog.value = []
    expect(operatorActionLog.value).toEqual([])
  })

  it('multiple signals can be set independently without interference', () => {
    operatorSnapshot.value = { name: 'test', status: 'active', uptime_seconds: 1, memory_turns: 1 } as OperatorSnapshot
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
import { describe, expect, it } from 'vitest'
import {
  AGENT_STATUS_VALUES,
  isAgentActive,
  isAgentOffline,
  isAgentPresent,
  parseAgentStatus,
  type AgentStatus,
} from './agent-status'

describe('AGENT_STATUS_VALUES', () => {
  it('matches the Agent.status literal union (6 tokens)', () => {
    expect(AGENT_STATUS_VALUES).toEqual([
      'active',
      'busy',
      'listening',
      'idle',
      'inactive',
      'offline',
    ])
  })
})

describe('parseAgentStatus', () => {
  it('accepts each known token', () => {
    for (const token of AGENT_STATUS_VALUES) {
      expect(parseAgentStatus(token)).toBe(token)
    }
  })

  it('is case-insensitive', () => {
    expect(parseAgentStatus('ACTIVE')).toBe('active')
    expect(parseAgentStatus('Busy')).toBe('busy')
    expect(parseAgentStatus('OFFLINE')).toBe('offline')
  })

  it('returns null for unknown tokens', () => {
    expect(parseAgentStatus('retired')).toBeNull()
    expect(parseAgentStatus('unbooted')).toBeNull()
    expect(parseAgentStatus('stopped')).toBeNull()
    expect(parseAgentStatus('running')).toBeNull()
  })

  it('returns null for null / undefined / empty', () => {
    expect(parseAgentStatus(null)).toBeNull()
    expect(parseAgentStatus(undefined)).toBeNull()
    expect(parseAgentStatus('')).toBeNull()
  })
})

describe('isAgentOffline', () => {
  it('returns true for offline / inactive only', () => {
    expect(isAgentOffline({ status: 'offline' })).toBe(true)
    expect(isAgentOffline({ status: 'inactive' })).toBe(true)
  })

  it('returns false for presence states', () => {
    expect(isAgentOffline({ status: 'active' })).toBe(false)
    expect(isAgentOffline({ status: 'busy' })).toBe(false)
    expect(isAgentOffline({ status: 'listening' })).toBe(false)
    expect(isAgentOffline({ status: 'idle' })).toBe(false)
  })

  it('rejects keeper-domain tokens (unbooted / stopped)', () => {
    expect(isAgentOffline({ status: 'unbooted' as unknown as AgentStatus })).toBe(false)
    expect(isAgentOffline({ status: 'stopped' as unknown as AgentStatus })).toBe(false)
  })

  it('returns false for missing status', () => {
    expect(isAgentOffline({ status: undefined })).toBe(false)
  })
})

describe('isAgentActive', () => {
  it('returns true for active / busy', () => {
    expect(isAgentActive({ status: 'active' })).toBe(true)
    expect(isAgentActive({ status: 'busy' })).toBe(true)
  })

  it('returns false for listening / idle (present but not active)', () => {
    expect(isAgentActive({ status: 'listening' })).toBe(false)
    expect(isAgentActive({ status: 'idle' })).toBe(false)
  })

  it('returns false for offline / inactive', () => {
    expect(isAgentActive({ status: 'offline' })).toBe(false)
    expect(isAgentActive({ status: 'inactive' })).toBe(false)
  })

  it('returns false for missing / unknown', () => {
    expect(isAgentActive({ status: undefined })).toBe(false)
    expect(isAgentActive({ status: 'retired' as unknown as AgentStatus })).toBe(false)
  })
})

describe('isAgentPresent', () => {
  it('returns true for the 4 presence states', () => {
    expect(isAgentPresent({ status: 'active' })).toBe(true)
    expect(isAgentPresent({ status: 'busy' })).toBe(true)
    expect(isAgentPresent({ status: 'listening' })).toBe(true)
    expect(isAgentPresent({ status: 'idle' })).toBe(true)
  })

  it('returns false for offline / inactive', () => {
    expect(isAgentPresent({ status: 'offline' })).toBe(false)
    expect(isAgentPresent({ status: 'inactive' })).toBe(false)
  })

  it('returns false for unknown tokens', () => {
    expect(isAgentPresent({ status: 'retired' as unknown as AgentStatus })).toBe(false)
    expect(isAgentPresent({ status: undefined })).toBe(false)
  })
})

describe('boundary cases (cross-domain isolation)', () => {
  it('keeper-only tokens are not classified as agent presence', () => {
    expect(parseAgentStatus('unbooted')).toBeNull()
    expect(parseAgentStatus('stopped')).toBeNull()
    expect(isAgentPresent({ status: 'unbooted' as unknown as AgentStatus })).toBe(false)
    expect(isAgentOffline({ status: 'unbooted' as unknown as AgentStatus })).toBe(false)
  })
})

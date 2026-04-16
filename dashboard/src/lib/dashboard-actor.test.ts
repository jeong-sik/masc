import { describe, it, expect } from 'vitest'
import {
  sanitizeDashboardActorName,
  readStoredDashboardActorName,
  resolveDashboardActorName,
  persistDashboardActorName,
  DASHBOARD_AGENT_NAME_KEY,
} from './dashboard-actor'

// --- Helpers ---

function mockStorage(getResult: string | null = null): Storage {
  const store: Record<string, string> = {}
  return {
    getItem: (key: string) => store[key] ?? getResult,
    setItem: (key: string, value: string) => { store[key] = value },
    removeItem: (key: string) => { delete store[key] },
    clear: () => { for (const k of Object.keys(store)) delete store[k] },
    key: (_index: number) => null,
    get length() { return Object.keys(store).length },
  }
}

// --- Tests ---

describe('sanitizeDashboardActorName', () => {
  it('returns null for null', () => {
    expect(sanitizeDashboardActorName(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(sanitizeDashboardActorName(undefined)).toBeNull()
  })

  it('returns null for empty string', () => {
    expect(sanitizeDashboardActorName('')).toBeNull()
  })

  it('returns null for whitespace-only string', () => {
    expect(sanitizeDashboardActorName('   ')).toBeNull()
  })

  it('trims whitespace', () => {
    expect(sanitizeDashboardActorName('  hello  ')).toBe('hello')
  })

  it('removes non-alphanumeric characters', () => {
    expect(sanitizeDashboardActorName('agent@#$name')).toBe('agentname')
  })

  it('allows dots, underscores, and dashes', () => {
    expect(sanitizeDashboardActorName('my-agent_v2.1')).toBe('my-agent_v2.1')
  })

  it('truncates to 32 characters', () => {
    const long = 'a'.repeat(50)
    expect(sanitizeDashboardActorName(long)).toBe('a'.repeat(32))
  })

  it('handles Korean characters removal', () => {
    expect(sanitizeDashboardActorName('안녕hello')).toBe('hello')
  })
})

describe('readStoredDashboardActorName', () => {
  it('returns null when storage has no value', () => {
    expect(readStoredDashboardActorName(mockStorage())).toBeNull()
  })

  it('reads and sanitizes stored value', () => {
    const storage = mockStorage()
    storage.setItem(DASHBOARD_AGENT_NAME_KEY, 'test-agent')
    expect(readStoredDashboardActorName(storage)).toBe('test-agent')
  })

  it('returns null for invalid stored value', () => {
    const storage = mockStorage()
    storage.setItem(DASHBOARD_AGENT_NAME_KEY, '@#$%')
    expect(readStoredDashboardActorName(storage)).toBeNull()
  })

  it('handles null storage gracefully', () => {
    expect(readStoredDashboardActorName(null)).toBeNull()
  })
})

describe('resolveDashboardActorName', () => {
  it('resolves from agent query param', () => {
    expect(resolveDashboardActorName('?agent=my-agent', null)).toBe('my-agent')
  })

  it('resolves from agent_name query param', () => {
    expect(resolveDashboardActorName('?agent_name=fallback', null)).toBe('fallback')
  })

  it('prefers agent over agent_name', () => {
    expect(resolveDashboardActorName('?agent=first&agent_name=second', null)).toBe('first')
  })

  it('falls back to storage when no query params', () => {
    const storage = mockStorage()
    storage.setItem(DASHBOARD_AGENT_NAME_KEY, 'stored')
    expect(resolveDashboardActorName('', storage)).toBe('stored')
  })

  it('returns null when nothing available', () => {
    expect(resolveDashboardActorName('', null)).toBeNull()
  })
})

describe('persistDashboardActorName', () => {
  it('persists valid name to storage', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('my-agent', storage)
    expect(result).toBe('my-agent')
    expect(storage.getItem(DASHBOARD_AGENT_NAME_KEY)).toBe('my-agent')
  })

  it('defaults to "dashboard" for empty input', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('', storage)
    expect(result).toBe('dashboard')
  })

  it('defaults to "dashboard" for invalid input', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('@#$%', storage)
    expect(result).toBe('dashboard')
  })

  it('sanitizes before persisting', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('  hello world!!  ', storage)
    expect(result).toBe('helloworld')
    expect(storage.getItem(DASHBOARD_AGENT_NAME_KEY)).toBe('helloworld')
  })

  it('handles null storage gracefully', () => {
    const result = persistDashboardActorName('test', null)
    expect(result).toBe('test')
  })
})

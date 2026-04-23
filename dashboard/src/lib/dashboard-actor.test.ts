import { describe, it, expect, vi } from 'vitest'
import {
  sanitizeDashboardActorName,
  readStoredDashboardActorName,
  resolveDashboardActorName,
  persistDashboardActorName,
  hasDashboardActorQueryParam,
  replaceDashboardActorQueryParam,
  syncDashboardActorName,
  DASHBOARD_AGENT_NAME_KEY,
} from './dashboard-actor'

function mockStorage(init: Record<string, string> = {}): Storage {
  const store = { ...init }
  return {
    getItem: (key: string) => store[key] ?? null,
    setItem: (key: string, value: string) => { store[key] = value },
    removeItem: (key: string) => { delete store[key] },
    clear: () => { Object.keys(store).forEach(k => delete store[k]) },
    key: (_index: number) => null,
    get length() { return Object.keys(store).length },
  }
}

describe('sanitizeDashboardActorName', () => {
  it('returns null for null', () => { expect(sanitizeDashboardActorName(null)).toBeNull() })
  it('returns null for undefined', () => { expect(sanitizeDashboardActorName(undefined)).toBeNull() })
  it('returns null for empty string', () => { expect(sanitizeDashboardActorName('')).toBeNull() })
  it('returns null for whitespace only', () => { expect(sanitizeDashboardActorName('   ')).toBeNull() })
  it('passes through valid name', () => { expect(sanitizeDashboardActorName('janitor')).toBe('janitor') })
  it('strips special characters', () => {
    expect(sanitizeDashboardActorName('jan@itor!')).toBe('janitor')
  })
  it('strips unicode characters', () => {
    expect(sanitizeDashboardActorName('agent한글')).toBe('agent')
  })
  it('trims whitespace', () => {
    expect(sanitizeDashboardActorName('  janitor  ')).toBe('janitor')
  })
  it('truncates to 32 chars', () => {
    const long = 'a'.repeat(64)
    expect(sanitizeDashboardActorName(long)).toBe('a'.repeat(32))
  })
  it('allows dots dashes underscores', () => {
    expect(sanitizeDashboardActorName('my-agent.v2_beta')).toBe('my-agent.v2_beta')
  })
})

describe('readStoredDashboardActorName', () => {
  it('reads from storage', () => {
    const storage = mockStorage({ [DASHBOARD_AGENT_NAME_KEY]: 'janitor' })
    expect(readStoredDashboardActorName(storage)).toBe('janitor')
  })

  it('returns null for empty storage', () => {
    expect(readStoredDashboardActorName(mockStorage())).toBeNull()
  })

  it('returns null for null storage', () => {
    expect(readStoredDashboardActorName(null)).toBeNull()
  })

  it('sanitizes stored value', () => {
    const storage = mockStorage({ [DASHBOARD_AGENT_NAME_KEY]: 'bad@name' })
    expect(readStoredDashboardActorName(storage)).toBe('badname')
  })
})

describe('resolveDashboardActorName', () => {
  it('resolves from agent query param', () => {
    expect(resolveDashboardActorName('?agent=janitor', null)).toBe('janitor')
  })

  it('resolves from agent_name query param', () => {
    expect(resolveDashboardActorName('?agent_name=dreamer', null)).toBe('dreamer')
  })

  it('prioritizes agent over agent_name', () => {
    expect(resolveDashboardActorName('?agent=janitor&agent_name=dreamer', null)).toBe('janitor')
  })

  it('falls back to storage when no query param', () => {
    const storage = mockStorage({ [DASHBOARD_AGENT_NAME_KEY]: 'keeper1' })
    expect(resolveDashboardActorName('', storage)).toBe('keeper1')
  })

  it('returns null when no source', () => {
    expect(resolveDashboardActorName('', null)).toBeNull()
  })
})

describe('persistDashboardActorName', () => {
  it('persists sanitized value', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('janitor', storage)
    expect(result).toBe('janitor')
    expect(storage.getItem(DASHBOARD_AGENT_NAME_KEY)).toBe('janitor')
  })

  it('defaults to dashboard for invalid input', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('!!!', storage)
    expect(result).toBe('dashboard')
  })

  it('sanitizes before persisting', () => {
    const storage = mockStorage()
    const result = persistDashboardActorName('my-agent.v2', storage)
    expect(result).toBe('my-agent.v2')
  })

  it('handles null storage gracefully', () => {
    const result = persistDashboardActorName('janitor', null)
    expect(result).toBe('janitor')
  })
})

describe('actor query helpers', () => {
  it('detects actor query params', () => {
    expect(hasDashboardActorQueryParam('?agent=janitor')).toBe(true)
    expect(hasDashboardActorQueryParam('?agent_name=janitor')).toBe(true)
    expect(hasDashboardActorQueryParam('?token=abc')).toBe(false)
  })

  it('rewrites actor query params to the canonical agent key', () => {
    const history = { replaceState: vi.fn() }
    const location = {
      pathname: '/dashboard',
      search: '?agent_name=dashboard&tab=tools',
      hash: '#pane',
    }
    const result = replaceDashboardActorQueryParam(
      'codex',
      location as unknown as Location,
      history as unknown as History,
    )

    expect(result).toBe('codex')
    expect(history.replaceState).toHaveBeenCalledTimes(1)
    const [, , nextUrl] = history.replaceState.mock.calls[0] as [null, string, string]
    expect(nextUrl).toContain('/dashboard?')
    expect(nextUrl).toContain('agent=codex')
    expect(nextUrl).toContain('tab=tools')
    expect(nextUrl).toContain('#pane')
    expect(nextUrl).not.toContain('agent_name=')
  })

  it('syncs storage and query params together when requested', () => {
    const storage = mockStorage()
    const history = { replaceState: vi.fn() }
    const location = {
      pathname: '/dashboard',
      search: '?agent=dashboard',
      hash: '',
    }
    const result = syncDashboardActorName('codex', {
      storage,
      rewriteQuery: true,
      location: location as unknown as Location,
      history: history as unknown as History,
    })

    expect(result).toBe('codex')
    expect(storage.getItem(DASHBOARD_AGENT_NAME_KEY)).toBe('codex')
    expect(history.replaceState).toHaveBeenCalledWith(null, '', '/dashboard?agent=codex')
  })
})

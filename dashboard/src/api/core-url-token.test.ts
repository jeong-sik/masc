import { afterEach, describe, expect, it } from 'vitest'

afterEach(() => {
  window.sessionStorage.clear()
  window.history.replaceState({}, '', '/')
})

describe('URL bearer rejection', () => {
  it('strips a legacy token query without storing it as a credential', async () => {
    window.history.replaceState({}, '', '/dashboard/?token=url-secret&agent=dashboard-user#board')

    const freshCore = await import('./core')

    expect(freshCore.getStoredToken()).toBeNull()
    expect(window.location.pathname).toBe('/dashboard/')
    expect(window.location.search).toBe('?agent=dashboard-user')
    expect(window.location.hash).toBe('#board')
  })
})

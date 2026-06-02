import { afterEach, describe, expect, it } from 'vitest'
import {
  currentCanonicalDashboardActor,
  currentDashboardActorHint,
  currentDashboardActorName,
  resetDashboardSessionActorForTests,
  setCanonicalDashboardActor,
} from './dashboard-session-actor'

afterEach(() => {
  resetDashboardSessionActorForTests()
  window.history.replaceState({}, '', '/')
  window.localStorage?.clear?.()
})

describe('dashboard session actor runtime', () => {
  it('falls back to the local actor hint when no canonical actor is set', () => {
    window.history.replaceState({}, '', '/?agent=local-hint')

    expect(currentCanonicalDashboardActor()).toBeNull()
    expect(currentDashboardActorHint()).toBe('local-hint')
    expect(currentDashboardActorName()).toBe('local-hint')
  })

  it('prefers the canonical actor once the shell has validated it', () => {
    window.history.replaceState({}, '', '/?agent=local-hint')

    expect(setCanonicalDashboardActor('agent-code')).toBe('agent-code')
    expect(currentCanonicalDashboardActor()).toBe('agent-code')
    expect(currentDashboardActorHint()).toBe('local-hint')
    expect(currentDashboardActorName()).toBe('agent-code')
  })

  it('clears the canonical actor when asked', () => {
    window.history.replaceState({}, '', '/')
    setCanonicalDashboardActor('agent-code')
    setCanonicalDashboardActor(null)

    expect(currentCanonicalDashboardActor()).toBeNull()
    expect(currentDashboardActorName()).toBe('dashboard')
  })
})

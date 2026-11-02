import { afterEach, describe, expect, it } from 'vitest'
import {
  currentCanonicalDashboardActor,
  currentDashboardActorHint,
  currentDashboardActorName,
  managedDashboardActorRevision,
  managedDashboardAuthRevision,
  managedDashboardRefusal,
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

    expect(setCanonicalDashboardActor('codex')).toBe('codex')
    expect(currentCanonicalDashboardActor()).toBe('codex')
    expect(currentDashboardActorHint()).toBe('local-hint')
    expect(currentDashboardActorName()).toBe('codex')
  })

  it('clears the canonical actor when asked', () => {
    window.history.replaceState({}, '', '/')
    setCanonicalDashboardActor('codex')
    setCanonicalDashboardActor(null)

    expect(currentCanonicalDashboardActor()).toBeNull()
    expect(currentDashboardActorName()).toBe('dashboard')
  })

  it('keeps same-actor hydration but retires each new managed credential refusal', () => {
    const revision = managedDashboardActorRevision.peek()
    const authRevision = managedDashboardAuthRevision.peek()
    setCanonicalDashboardActor(null, { tokenRevision: 17, rejected: true })
    expect(managedDashboardActorRevision.peek()).toBe(revision + 1)
    setCanonicalDashboardActor(null, { tokenRevision: 17, rejected: true })
    expect(managedDashboardActorRevision.peek()).toBe(revision + 1)
    setCanonicalDashboardActor('dashboard', { tokenRevision: 17, rejected: false })
    expect(managedDashboardActorRevision.peek()).toBe(revision + 1)
    setCanonicalDashboardActor(null, { tokenRevision: 17, rejected: true })
    expect(managedDashboardActorRevision.peek()).toBe(revision + 2)
    setCanonicalDashboardActor('dashboard', { tokenRevision: 17, rejected: false })
    expect(managedDashboardActorRevision.peek()).toBe(revision + 2)
    expect(managedDashboardRefusal.peek()).toBe(17)
    expect(managedDashboardAuthRevision.peek()).toBe(authRevision + 1)
  })
})

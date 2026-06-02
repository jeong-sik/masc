import { resolveDashboardActorName, sanitizeDashboardActorName } from './dashboard-actor'

let canonicalDashboardActor: string | null = null

export function setCanonicalDashboardActor(value: string | null | undefined): string | null {
  canonicalDashboardActor = sanitizeDashboardActorName(value) ?? null
  return canonicalDashboardActor
}

export function currentCanonicalDashboardActor(): string | null {
  return canonicalDashboardActor
}

export function currentDashboardActorHint(): string {
  return resolveDashboardActorName() || 'dashboard'
}

export function currentDashboardActorName(): string {
  return canonicalDashboardActor ?? currentDashboardActorHint()
}

export function resetDashboardSessionActorForTests(): void {
  canonicalDashboardActor = null
}

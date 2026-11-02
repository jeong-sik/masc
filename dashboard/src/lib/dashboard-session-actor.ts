import { resolveDashboardActorName, sanitizeDashboardActorName } from './dashboard-actor'
import { signal, type ReadonlySignal } from '@preact/signals'

let canonicalDashboardActor: string | null = null
const actorRevision = signal(0)
export const dashboardActorRevision: ReadonlySignal<number> = actorRevision

export function setCanonicalDashboardActor(value: string | null | undefined): string | null {
  const next = sanitizeDashboardActorName(value) ?? null
  if (next !== canonicalDashboardActor) {
    canonicalDashboardActor = next
    actorRevision.value++
  }
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
  setCanonicalDashboardActor(null)
}

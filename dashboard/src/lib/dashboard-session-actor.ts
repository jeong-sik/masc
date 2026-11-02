import { resolveDashboardActorName, sanitizeDashboardActorName } from './dashboard-actor'
import { batch, signal, type ReadonlySignal } from '@preact/signals'

let canonicalDashboardActor: string | null = null
const actorRevision = signal(0)
export const dashboardActorRevision: ReadonlySignal<number> = actorRevision
// A managed dev credential already names dashboard. Confirming that same
// actor adds information; withdrawal or another actor retires its authority.
const managedActorRevision = signal(0)
export const managedDashboardActorRevision: ReadonlySignal<number> = managedActorRevision
const managedRefusalTokenRevision = signal<number | null>(null)
const managedUnverifiedTokenRevision = signal<number | null>(null)
const managedAuthRevision = signal(0)
let managedRefusalObservation = 0
export const managedDashboardRefusal: ReadonlySignal<number | null> = managedRefusalTokenRevision
export const managedDashboardUnverified: ReadonlySignal<number | null> = managedUnverifiedTokenRevision
export const managedDashboardAuthRevision: ReadonlySignal<number> = managedAuthRevision

export function currentManagedRefusalObservation(): number { return managedRefusalObservation }
export function noteManagedCredentialRefusalObservation(tokenRevision: number): void {
  managedRefusalObservation++
  managedUnverifiedTokenRevision.value = tokenRevision
}
export function managedCredentialNeedsRevalidation(tokenRevision: number): boolean {
  return managedRefusalTokenRevision.peek() === tokenRevision || managedUnverifiedTokenRevision.peek() === tokenRevision
}

export function recordManagedCredentialRefusal(tokenRevision: number): boolean {
  const isNew = managedRefusalTokenRevision.peek() !== tokenRevision
  batch(() => {
    noteManagedCredentialRefusalObservation(tokenRevision)
    if (isNew) {
      managedRefusalTokenRevision.value = tokenRevision
      managedAuthRevision.value++
    }
  })
  return isNew
}

export function setCanonicalDashboardActor(value: string | null | undefined,
  managedAuth?: { tokenRevision: number; rejected: boolean; verifiedAfterRefusal?: boolean }): string | null {
  const next = sanitizeDashboardActorName(value) ?? null
  const changed = next !== canonicalDashboardActor
  const sameManagedHydration = canonicalDashboardActor === null && next === 'dashboard'
  const newManagedRefusal = managedAuth?.rejected === true
    && managedRefusalTokenRevision.peek() !== managedAuth.tokenRevision
  const revalidatedManaged = managedAuth?.verifiedAfterRefusal === true && !managedAuth.rejected
    && next === 'dashboard' && managedCredentialNeedsRevalidation(managedAuth.tokenRevision)
  const retireManaged = (changed && !sameManagedHydration) || newManagedRefusal || revalidatedManaged
  if (changed || retireManaged || managedAuth?.rejected) {
    batch(() => {
      if (managedAuth?.rejected) noteManagedCredentialRefusalObservation(managedAuth.tokenRevision)
      canonicalDashboardActor = next
      if (changed) actorRevision.value++
      if (retireManaged) managedActorRevision.value++
      if (newManagedRefusal && managedAuth) {
        managedRefusalTokenRevision.value = managedAuth.tokenRevision
        managedAuthRevision.value++
      }
      if (revalidatedManaged) {
        managedRefusalTokenRevision.value = null
        managedUnverifiedTokenRevision.value = null
        managedAuthRevision.value++
      }
    })
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
  managedRefusalTokenRevision.value = null
  managedUnverifiedTokenRevision.value = null
  managedRefusalObservation++
}

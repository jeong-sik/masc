import {
  captureDashboardCredentialOwner,
  subscribeStoredTokenChanges,
} from '../api/core'
import { storedTokenRevision } from '../api/token-revision'
import {
  executionWorkspaceAuthority,
  type ExecutionWorkspaceAuthority,
} from '../execution-workspace-authority'
import { dashboardActorRevision, managedDashboardActorRevision } from './dashboard-session-actor'
import { isObserverInstance } from './observer-protocol'

export interface DashboardObservationOwner {
  readonly workspace: ExecutionWorkspaceAuthority | null
  readonly token: string | null
  readonly tokenRevision: number
  readonly actor: string
  readonly actorRevision: number
  readonly managed: boolean
}

/** Request-header identity and the existing accepted execution owner. An
 * observation of this request's own refusal is not a new request owner. */
export function captureDashboardObservationOwner(): DashboardObservationOwner {
  const credential = captureDashboardCredentialOwner()
  return {
    workspace: executionWorkspaceAuthority.peek(),
    token: credential.token,
    tokenRevision: credential.tokenRevision,
    actor: credential.actor,
    actorRevision: credential.managed ? credential.managedActorRevision : credential.actorRevision,
    managed: credential.managed,
  }
}

/** Capture the same owner while tracking only inputs that change its actual
 * request identity. Refusal observations do not re-admit a refused reader. */
export function readDashboardObservationOwner(): DashboardObservationOwner {
  void storedTokenRevision.value
  void dashboardActorRevision.value
  void managedDashboardActorRevision.value
  void executionWorkspaceAuthority.value
  return captureDashboardObservationOwner()
}

export function dashboardObservationOwnerIsCurrent(owner: DashboardObservationOwner): boolean {
  const current = captureDashboardObservationOwner()
  return owner.workspace === current.workspace && owner.token === current.token
    && owner.tokenRevision === current.tokenRevision && owner.actor === current.actor
    && owner.actorRevision === current.actorRevision && owner.managed === current.managed
}

export function dashboardObservationOwnerHasWorkspace(
  owner: DashboardObservationOwner,
): owner is DashboardObservationOwner & {
  readonly workspace: ExecutionWorkspaceAuthority & { readonly observerInstanceId: string }
} {
  return owner.workspace !== null && isObserverInstance(owner.workspace.observerInstanceId)
}

/** Change-only subscription. Stored credential/actor ABA and workspace ABA
 * retire an owner; managed refusal counters and unchanged values do not. */
export function subscribeDashboardObservationOwnerChanges(
  listener: (owner: DashboardObservationOwner) => void,
): () => void {
  let owner = captureDashboardObservationOwner()
  const observe = () => {
    if (dashboardObservationOwnerIsCurrent(owner)) return
    owner = captureDashboardObservationOwner()
    listener(owner)
  }
  const disposers = [
    subscribeStoredTokenChanges(observe),
    dashboardActorRevision.subscribe(observe),
    managedDashboardActorRevision.subscribe(observe),
    executionWorkspaceAuthority.subscribe(observe),
  ]
  return () => { for (const dispose of disposers) dispose() }
}

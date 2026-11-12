import { useEffect, useState } from 'preact/hooks'
import {
  captureDashboardObservationOwner,
  dashboardObservationOwnerHasWorkspace,
  dashboardObservationOwnerIsCurrent,
  readDashboardObservationOwner,
  type DashboardObservationOwner,
} from './observation-read-owner'
import {
  createManagedAsyncResource,
  type ManagedAsyncResource,
} from './async-state'

interface OwnerScopedResource<T> {
  readonly owner: DashboardObservationOwner
  readonly resource: ManagedAsyncResource<T>
}

function ownedResource<T>(owner: DashboardObservationOwner, initialData: T | null): ManagedAsyncResource<T> {
  const resource = createManagedAsyncResource<T>(initialData)
  return {
    ...resource,
    load: fn => {
      if (!dashboardObservationOwnerHasWorkspace(owner) || !dashboardObservationOwnerIsCurrent(owner)) {
        return Promise.resolve(undefined)
      }
      return resource.load(async (signal, previous) => {
        const value = await fn(signal, previous)
        if (!dashboardObservationOwnerIsCurrent(owner)) throw new DOMException('Observation owner retired', 'AbortError')
        return value
      })
    },
  }
}

// A resource belongs to the accepted workspace and credential it loaded under.
// When that owner changes, the component gets a new resource: what the previous owner
// loaded is not rendered, and an effect that depends on the resource cancels
// the old request and loads again under the new credential. The effect below
// cancels the old resource for a load that started from an event handler.
export function useManagedAsyncResource<T>(
  initialData: T | null = null,
): ManagedAsyncResource<T> {
  // Read the authority inputs reactively; the shared owner helper decides
  // whether a change actually affects this credential's request headers.
  void readDashboardObservationOwner()
  const [scoped, setScoped] = useState<OwnerScopedResource<T>>(() => {
    const owner = captureDashboardObservationOwner()
    return { owner, resource: ownedResource(owner, initialData) }
  })
  let current = scoped
  if (!dashboardObservationOwnerIsCurrent(scoped.owner)) {
    const owner = captureDashboardObservationOwner()
    current = {
      owner,
      resource: ownedResource(owner, initialData),
    }
    setScoped(current)
  }
  const { resource } = current
  useEffect(() => () => { resource.cancel() }, [resource])
  return resource
}

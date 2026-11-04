import { useEffect, useState } from 'preact/hooks'
import { storedTokenRevision } from '../api/token-revision'
import {
  createManagedAsyncResource,
  type ManagedAsyncResource,
} from './async-state'

interface CredentialScopedResource<T> {
  readonly credentialRevision: number
  readonly resource: ManagedAsyncResource<T>
}

// A resource belongs to the credential it loaded under. When the stored token
// changes, the component gets a new resource: what the previous credential
// loaded is not rendered, and an effect that depends on the resource cancels
// the old request and loads again under the new credential. The effect below
// cancels the old resource for a load that started from an event handler.
export function useManagedAsyncResource<T>(
  initialData: T | null = null,
): ManagedAsyncResource<T> {
  const credentialRevision = storedTokenRevision.value
  const [scoped, setScoped] = useState<CredentialScopedResource<T>>(() => ({
    credentialRevision,
    resource: createManagedAsyncResource<T>(initialData),
  }))
  let current = scoped
  if (scoped.credentialRevision !== credentialRevision) {
    current = {
      credentialRevision,
      resource: createManagedAsyncResource<T>(initialData),
    }
    setScoped(current)
  }
  const { resource } = current
  useEffect(() => () => { resource.cancel() }, [resource])
  return resource
}

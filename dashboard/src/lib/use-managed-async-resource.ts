import { useState } from 'preact/hooks'
import {
  createManagedAsyncResource,
  type ManagedAsyncResource,
} from './async-state'

export function useManagedAsyncResource<T>(
  initialData: T | null = null,
): ManagedAsyncResource<T> {
  const [resource] = useState<ManagedAsyncResource<T>>(() =>
    createManagedAsyncResource<T>(initialData),
  )
  return resource
}

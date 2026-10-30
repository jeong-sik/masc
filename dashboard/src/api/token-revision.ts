import { signal, type ReadonlySignal } from '@preact/signals'
import { currentStoredTokenRevision, subscribeStoredTokenChanges } from './core'

// Reactive projection of the existing credential epoch, never the credential.
const revision = signal(currentStoredTokenRevision())
subscribeStoredTokenChanges(() => { revision.value = currentStoredTokenRevision() })
export const storedTokenRevision: ReadonlySignal<number> = revision

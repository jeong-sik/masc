import { batch } from '@preact/signals'
import { isRecord } from './lib/type-guards'
import { projectionReadOutcome } from './lib/projection-read-outcome'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'
import {
  namespaceTruth, namespaceTruthError, namespaceTruthInitializing,
  namespaceTruthLoading, namespaceTruthReadRecovery,
} from './namespace-truth-signals'

const retry = () => { void import('./namespace-truth-actions').then(actions => actions.requestNamespaceTruthNow()) }

/** HTTP/bootstrap and pushed bodies retain the same observed read outcome.
 * A canonical producer owns its own failed-read retry. */
export function hydrateNamespaceTruthObservation(raw: unknown, origin: 'http' | 'canonical') {
  const outcome = projectionReadOutcome(raw)
  if (isRecord(raw) && raw.status === 'initializing' && outcome?.kind !== 'partial') {
    namespaceTruthInitializing.value = true
    namespaceTruthLoading.value = false
    if (origin === 'canonical') namespaceTruthReadRecovery.succeeded()
    else namespaceTruthReadRecovery.waiting(retry)
    return null
  }
  if (outcome === null) throw new Error('Project snapshot omitted its read outcome')
  const normalized = normalizeNamespaceTruth(raw)
  batch(() => {
    namespaceTruth.value = normalized
    namespaceTruthError.value = outcome.kind === 'partial' ? outcome.error : null
    namespaceTruthInitializing.value = false
    namespaceTruthLoading.value = false
  })
  // Fence older HTTP completions even if this body contains partial rows.
  if (outcome.kind === 'partial' && origin === 'http') namespaceTruthReadRecovery.failed(retry)
  else namespaceTruthReadRecovery.succeeded()
  return normalized
}

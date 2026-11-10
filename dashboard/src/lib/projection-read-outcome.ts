import { isRecord } from './type-guards'

export type ProjectionReadOutcome =
  | { readonly kind: 'complete' }
  | { readonly kind: 'partial'; readonly error: string }

/** A cache may be initializing before any source body exists. Once a read
 * outcome is present, its closed producer contract must be valid. */
export function projectionReadOutcome(raw: unknown): ProjectionReadOutcome | null {
  if (!isRecord(raw) || !isRecord(raw.projection_diagnostics)) return null
  const diagnostics = raw.projection_diagnostics
  if (!('read_completeness' in diagnostics) && !('read_error' in diagnostics)) return null
  if (diagnostics.read_completeness === 'complete' && diagnostics.read_error === null) {
    return { kind: 'complete' }
  }
  if (diagnostics.read_completeness === 'partial' && typeof diagnostics.read_error === 'string') {
    return { kind: 'partial', error: diagnostics.read_error }
  }
  throw new Error('Dashboard read outcome is invalid')
}

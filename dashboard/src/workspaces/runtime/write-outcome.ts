/**
 * What a failed write says about the server's state. Both views of Runtime →
 * Prompts read every failed override and preset answer through this one
 * function.
 */

import type { ApiErrorKind } from '../../core'

export type WriteFailure = 'applied' | 'refused' | 'unknown'

export function failureOutcome(kind: ApiErrorKind): WriteFailure {
  switch (kind) {
    // Transport decodes only a 2xx answer.
    case 'decode':
      return 'applied'
    // The server answered that it did not do it.
    case 'unauthorized':
    case 'forbidden':
    case 'csrf_rejected':
    case 'not_found':
    case 'conflict_cas':
    case 'validation':
      return 'refused'
    // No answer, or a 5xx that a proxy may have written: the server may have done it.
    case 'server':
    case 'network':
    case 'timeout':
    case 'aborted':
    case 'epoch_stale':
      return 'unknown'
  }
}

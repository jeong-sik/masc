import { signal } from '@preact/signals'
import { post, postControlPlane, type AbortableRequestOptions } from '../api/core'
import { isRecord } from './type-guards'

export type ModelSetupResumeState =
  | { kind: 'idle' }
  | { kind: 'resuming' }
  | { kind: 'active'; exactOutputAvailable: boolean }
  | { kind: 'failed'; reason: 'upgrade_required' | 'access_required' | 'activation_failed' }
export const modelSetupResumeState = signal<ModelSetupResumeState>({ kind: 'idle' })
let latestRequest = 0

export async function resumeSavedModelSetup(options: AbortableRequestOptions = {}): Promise<ModelSetupResumeState> {
  const request = ++latestRequest
  modelSetupResumeState.value = { kind: 'resuming' }
  let result: ModelSetupResumeState
  try {
    const response = options.signal
      ? await postControlPlane<unknown>('/api/v1/runtime/setup/resume', {}, undefined, options)
      : await post<unknown>('/api/v1/runtime/setup/resume', {})
    if (!isRecord(response) || response.runtime_ready !== true
      || typeof response.exact_output_authority_available !== 'boolean'
      || !isRecord(response.model_setup) || response.model_setup.status !== 'available') {
      throw new Error('Unconfirmed model setup activation')
    }
    result = { kind: 'active', exactOutputAvailable: response.exact_output_authority_available }
  } catch (error) {
    // Backend errors may contain configuration or credential details.
    const status = isRecord(error) ? error.status : null
    result = { kind: 'failed', reason: status === 404 ? 'upgrade_required'
      : status === 401 || status === 403 ? 'access_required' : 'activation_failed' }
  }
  if (options.signal?.aborted) result = { kind: 'idle' }
  if (request === latestRequest) modelSetupResumeState.value = result
  return result
}

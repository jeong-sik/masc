// Lean generation-fenced AbortSignal async resource replacing `effect` ManagedRuntime.

import { signal, type Signal } from '@preact/signals'
import { Option, TaggedError, type Result } from './result'
import {
  remoteFailure,
  remoteInitial,
  remoteLoading,
  remotePrevious,
  remoteSuccess,
  type RemoteData,
} from './remote-data'

export class ResourceDefectError extends TaggedError('ResourceDefectError')<{
  readonly message: string
  readonly cause: unknown
}>() {}

export type AsyncResourceError<E> = E | ResourceDefectError

export type AsyncTask<A, E> = (signal: AbortSignal) => Promise<Result<A, E>>

export interface AsyncResource<E, A> {
  readonly state: Signal<RemoteData<AsyncResourceError<E>, A>>
  load(task: AsyncTask<A, E>): Promise<void>
  cancel(): void
  reset(): void
}

function defectError(cause: unknown): ResourceDefectError {
  return new ResourceDefectError({
    message: cause instanceof Error ? cause.message : String(cause),
    cause,
  })
}

function isAbortError(cause: unknown): boolean {
  return cause instanceof DOMException
    ? cause.name === 'AbortError'
    : cause instanceof Error && cause.name === 'AbortError'
}

export function createAsyncResource<E, A>(): AsyncResource<E, A> {
  const state = signal<RemoteData<AsyncResourceError<E>, A>>(remoteInitial())
  let generation = 0
  let controller: AbortController | undefined

  function abortCurrent(): void {
    generation += 1
    controller?.abort()
    controller = undefined
  }

  return {
    state,

    async load(task: AsyncTask<A, E>): Promise<void> {
      const previous = remotePrevious(state.value)
      abortCurrent()
      const requestGeneration = generation
      const requestController = new AbortController()
      controller = requestController
      state.value = remoteLoading(previous)

      let result: Result<A, E>
      try {
        result = await task(requestController.signal)
      } catch (cause) {
        if (requestGeneration !== generation) return
        controller = undefined
        if (requestController.signal.aborted || isAbortError(cause)) {
          state.value = Option.match(previous, {
            onNone: () => remoteInitial(),
            onSome: value => remoteSuccess(value),
          })
          return
        }
        state.value = remoteFailure(defectError(cause), previous)
        return
      }

      if (requestGeneration !== generation) return
      controller = undefined

      if (result.ok) {
        state.value = remoteSuccess(result.value)
        return
      }

      if (requestController.signal.aborted) {
        state.value = Option.match(previous, {
          onNone: () => remoteInitial(),
          onSome: value => remoteSuccess(value),
        })
        return
      }

      state.value = remoteFailure(result.error, previous)
    },

    cancel(): void {
      const previous = remotePrevious(state.value)
      abortCurrent()
      state.value = Option.match(previous, {
        onNone: () => remoteInitial(),
        onSome: value => remoteSuccess(value),
      })
    },

    reset(): void {
      abortCurrent()
      state.value = remoteInitial()
    },
  }
}

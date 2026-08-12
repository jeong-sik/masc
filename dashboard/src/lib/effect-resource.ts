import { signal, type Signal } from '@preact/signals'
import { Cause, Data, Exit, Option, type Effect } from 'effect'

import {
  remoteFailure,
  remoteInitial,
  remoteLoading,
  remotePrevious,
  remoteSuccess,
  type RemoteData,
} from './remote-data'

export class EffectDefectError extends Data.TaggedError('EffectDefectError')<{
  readonly message: string
  readonly cause: unknown
}> {}

export type EffectResourceError<E> = E | EffectDefectError

export interface EffectRunner<R> {
  runPromiseExit<A, E>(
    effect: Effect.Effect<A, E, R>,
    options?: { readonly signal?: AbortSignal },
  ): Promise<Exit.Exit<A, E>>
}

export interface EffectResource<R, E, A> {
  readonly state: Signal<RemoteData<EffectResourceError<E>, A>>
  load(effect: Effect.Effect<A, E, R>): Promise<void>
  cancel(): void
  reset(): void
}

function defectError(cause: unknown): EffectDefectError {
  let message: string
  if (Cause.isCause(cause)) {
    message = Cause.pretty(cause)
  } else if (cause instanceof Error) {
    message = cause.message
  } else {
    message = String(cause)
  }
  return new EffectDefectError({ message, cause })
}

export function createEffectResource<R, E, A>(
  runner: EffectRunner<R>,
): EffectResource<R, E, A> {
  const state = signal<RemoteData<EffectResourceError<E>, A>>(
    remoteInitial(),
  )
  let generation = 0
  let controller: AbortController | undefined

  function abortCurrent(): void {
    generation += 1
    controller?.abort()
    controller = undefined
  }

  return {
    state,

    async load(effect: Effect.Effect<A, E, R>): Promise<void> {
      const previous = remotePrevious(state.value)
      abortCurrent()
      const requestGeneration = generation
      const requestController = new AbortController()
      controller = requestController
      state.value = remoteLoading(previous)

      let exit: Exit.Exit<A, E>
      try {
        exit = await runner.runPromiseExit(effect, {
          signal: requestController.signal,
        })
      } catch (cause) {
        if (requestGeneration !== generation) return
        state.value = remoteFailure(defectError(cause), previous)
        controller = undefined
        return
      }

      if (requestGeneration !== generation) return
      controller = undefined

      if (Exit.isSuccess(exit)) {
        state.value = remoteSuccess(exit.value)
        return
      }

      if (Cause.isInterruptedOnly(exit.cause)) {
        state.value = Option.match(previous, {
          onNone: () => remoteInitial(),
          onSome: value => remoteSuccess(value),
        })
        return
      }

      const failure = Cause.failureOption(exit.cause)
      state.value = Option.match(failure, {
        onNone: () => remoteFailure(defectError(exit.cause), previous),
        onSome: error => remoteFailure(error, previous),
      })
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

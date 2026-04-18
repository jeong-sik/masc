// Async state management — eliminates the 3-signal pattern (data/loading/error)
// scattered across 22+ dashboard components.
//
// Before: const data = signal<T | null>(null)
//         const loading = signal(false)
//         const error = signal<string | null>(null)
//         let request: Promise<void> | null = null
//
// After:  const resource = createAsyncResource<T>()

import { signal, type Signal } from '@preact/signals'

// ── Discriminated union ──

type Idle = { readonly status: 'idle' }
type Loading = { readonly status: 'loading' }
type Loaded<T> = { readonly status: 'loaded'; readonly data: T }
type Failed = { readonly status: 'error'; readonly message: string }

export type AsyncState<T> = Idle | Loading | Loaded<T> | Failed

// ── Constructors ──

export const idle: Idle = { status: 'idle' }
export const loading: Loading = { status: 'loading' }
export function loaded<T>(data: T): Loaded<T> { return { status: 'loaded', data } }
export function failed(message: string): Failed { return { status: 'error', message } }

// ── Type guards ──

export function isLoaded<T>(state: AsyncState<T>): state is Loaded<T> {
  return state.status === 'loaded'
}

export function isLoading<T>(state: AsyncState<T>): state is Loading {
  return state.status === 'loading'
}

export function isFailed<T>(state: AsyncState<T>): state is Failed {
  return state.status === 'error'
}

// ── Data extraction (returns undefined for non-loaded states) ──

export function getData<T>(state: AsyncState<T>): T | undefined {
  return state.status === 'loaded' ? state.data : undefined
}

// ── Managed async resource ──
//
// Bundles a signal holding AsyncState<T> with request deduplication.
// Replaces the manual `let request: Promise<void> | null` pattern.

export interface AsyncResource<T> {
  readonly state: Signal<AsyncState<T>>
  load(fn: () => Promise<T>): Promise<void>
  reset(): void
}

interface ManagedAsyncState<T> {
  readonly data: T | null
  readonly loading: boolean
  readonly error: string | null
}

export interface ManagedAsyncResource<T> {
  readonly state: Signal<ManagedAsyncState<T>>
  load(fn: (signal: AbortSignal, previous: T | null) => Promise<T>): Promise<T | undefined>
  cancel(): void
  reset(nextData?: T | null): void
}

export function createAsyncResource<T>(): AsyncResource<T> {
  const state = signal<AsyncState<T>>(idle)
  let inflight: Promise<void> | null = null
  let generation = 0

  return {
    state,

    load(fn: () => Promise<T>): Promise<void> {
      if (inflight) return inflight

      const gen = ++generation
      state.value = loading

      let promise: Promise<T>
      try {
        promise = fn()
      } catch (e) {
        if (gen === generation) {
          state.value = failed(e instanceof Error ? e.message : String(e))
        }
        return Promise.resolve()
      }

      inflight = promise
        .then(data => {
          if (gen === generation) state.value = loaded(data)
        })
        .catch(e => {
          if (gen === generation) state.value = failed(e instanceof Error ? e.message : String(e))
        })
        .finally(() => {
          if (gen === generation) inflight = null
        })

      return inflight
    },

    reset(): void {
      ++generation
      state.value = idle
      inflight = null
    },
  }
}

function toErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError'
}

export function createManagedAsyncResource<T>(initialData: T | null = null): ManagedAsyncResource<T> {
  const state = signal<ManagedAsyncState<T>>({
    data: initialData,
    loading: false,
    error: null,
  })
  let inflight: Promise<T | undefined> | null = null
  let generation = 0
  let controller: AbortController | null = null

  return {
    state,

    load(fn: (signal: AbortSignal, previous: T | null) => Promise<T>): Promise<T | undefined> {
      const previous = state.value.data
      const gen = ++generation
      controller?.abort()
      const requestController = new AbortController()
      controller = requestController
      state.value = {
        data: previous,
        loading: true,
        error: null,
      }

      let promise: Promise<T>
      try {
        promise = fn(requestController.signal, previous)
      } catch (error) {
        state.value = {
          data: previous,
          loading: false,
          error: toErrorMessage(error),
        }
        return Promise.resolve(undefined)
      }

      inflight = promise
        .then((data) => {
          if (gen !== generation || requestController.signal.aborted) return undefined
          state.value = {
            data,
            loading: false,
            error: null,
          }
          return data
        })
        .catch((error) => {
          if (gen !== generation || isAbortError(error)) return undefined
          state.value = {
            data: previous,
            loading: false,
            error: toErrorMessage(error),
          }
          return undefined
        })
        .finally(() => {
          if (gen === generation && controller === requestController) {
            inflight = null
            controller = null
          }
        })

      return inflight
    },

    cancel(): void {
      ++generation
      controller?.abort()
      controller = null
      inflight = null
      state.value = {
        ...state.value,
        loading: false,
      }
    },

    reset(nextData: T | null = null): void {
      ++generation
      controller?.abort()
      controller = null
      inflight = null
      state.value = {
        data: nextData,
        loading: false,
        error: null,
      }
    },
  }
}

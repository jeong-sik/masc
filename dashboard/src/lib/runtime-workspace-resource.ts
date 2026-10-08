import { computed, effect, signal } from '@preact/signals'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { failed, idle, loaded, loading, type AsyncState } from './async-state'

type Reading = { authority: ExecutionWorkspaceAuthority; controller: AbortController; promise: Promise<void> }
const unverified = failed('작업공간을 확인한 뒤 런타임 목록을 읽을 수 있습니다.')
const superseded = () => new Error('Runtime reading was superseded by a newer workspace or refresh.')

/** Shared runtime readings have the same workspace lifetime, regardless of
 * whether their consumers request them during render or only once on mount. */
export function createRuntimeWorkspaceResource<T>(fetch: (signal: AbortSignal) => Promise<T>) {
  const wanted = signal(false)
  const received = signal<{ authority: ExecutionWorkspaceAuthority; value: AsyncState<T> } | null>(null)
  const state = computed<AsyncState<T>>(() => {
    if (!wanted.value) return idle
    const authority = executionWorkspaceAuthority.value
    if (authority === null) return unverified
    return received.value?.authority === authority ? received.value.value : idle
  })
  let observedAuthority = executionWorkspaceAuthority.peek()
  let active: Reading | null = null
  let watching = false

  function cancel() {
    const previous = active
    active = null
    previous?.controller.abort()
  }
  function observe(authority: ExecutionWorkspaceAuthority | null): boolean {
    if (observedAuthority === authority) return false
    observedAuthority = authority
    cancel()
    received.value = null
    return true
  }
  function start(authority: ExecutionWorkspaceAuthority): Promise<void> {
    if (active?.authority === authority) return active.promise
    const controller = new AbortController()
    let reading: Reading
    const current = () => active === reading && !controller.signal.aborted
      && executionWorkspaceAuthority.peek() === authority
    // Install the request owner before calling a fetcher or publishing loading;
    // consumers can synchronously ask for the same reading without duplicating it.
    const promise = Promise.resolve().then(async () => {
      try {
        if (!current()) throw superseded()
        const value = await fetch(controller.signal)
        if (!current()) throw superseded()
        received.value = { authority, value: loaded(value) }
      } catch (error) {
        if (current()) received.value = { authority,
          value: failed(error instanceof Error ? error.message : String(error)) }
        throw error
      } finally { if (active === reading) active = null }
    })
    reading = { authority, controller, promise }
    active = reading
    received.value = { authority, value: loading }
    // Background demand has no awaiting caller. Explicit reload still receives
    // the original rejecting promise, so a failed refresh is not reported as done.
    void promise.catch(() => {})
    return promise
  }
  function watch() {
    if (watching) return
    watching = true
    effect(() => {
      const authority = executionWorkspaceAuthority.value
      if (observe(authority) && wanted.peek() && authority !== null) void start(authority)
    })
  }
  function request(force: boolean): Promise<void> {
    watch()
    const authority = executionWorkspaceAuthority.peek()
    observe(authority)
    wanted.value = true
    if (authority === null) return force ? Promise.reject(new Error(unverified.message)) : Promise.resolve()
    if (force) { cancel(); received.value = null }
    else if (state.peek().status !== 'idle') return active?.promise ?? Promise.resolve()
    return start(authority)
  }
  return {
    state,
    load: () => request(false).catch(() => {}),
    reload: () => request(true),
    reset() { wanted.value = false; cancel(); received.value = null },
  }
}

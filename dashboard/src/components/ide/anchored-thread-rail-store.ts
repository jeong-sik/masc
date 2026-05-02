/**
 * anchored-thread-rail-store - Preact signal adapter for RFC 0021.
 *
 * The headless controller owns file scoping, line lookup, and focus events.
 * This adapter publishes immutable snapshots for the IDE conversation rail.
 */

import { signal } from '@preact/signals'
import {
  createAnchoredThreadRail,
  type AnchoredThread,
} from '../../../design-system/headless-core/anchored-thread-rail'

export type { AnchoredThread, ThreadAnchor, ThreadKind } from '../../../design-system/headless-core/anchored-thread-rail'

export interface AnchoredThreadRailStore {
  readonly filePath: () => string
  readonly seed: (threads: ReadonlyArray<AnchoredThread>) => void
  readonly addThread: (thread: AnchoredThread) => void
  readonly resolveThread: (id: string, resolved?: boolean) => boolean
  readonly visibleThreads: () => ReadonlyArray<AnchoredThread>
  readonly threadsForLine: (line: number) => ReadonlyArray<AnchoredThread>
  readonly focusedThreadId: () => string | null
  readonly focusThread: (id: string) => boolean
  readonly clearFocus: () => void
  readonly knownAuthors: () => ReadonlyArray<string>
  readonly reset: (filePath?: string) => void
  readonly subscribe: (listener: () => void) => () => void
}

export function createAnchoredThreadRailStore(
  initialFilePath: string,
): AnchoredThreadRailStore {
  const activeFilePath = signal(initialFilePath)
  const allThreads = signal<ReadonlyArray<AnchoredThread>>([])
  const visibleThreadsSignal = signal<ReadonlyArray<AnchoredThread>>([])
  const focusedThreadIdSignal = signal<string | null>(null)
  const authorsSignal = signal<ReadonlyArray<string>>([])

  const controller = createAnchoredThreadRail({
    filePath: () => activeFilePath.value,
    threads: () => allThreads.value,
  })

  const publish = (): void => {
    const visible = controller.visibleThreads()
    visibleThreadsSignal.value = visible
    focusedThreadIdSignal.value = controller.focusedThreadId()
    authorsSignal.value = sortedAuthors(visible)
  }

  controller.subscribe(publish)

  const seed = (threads: ReadonlyArray<AnchoredThread>): void => {
    const hadFocus = focusedThreadIdSignal.value !== null
    allThreads.value = [...threads]
    if (hadFocus && controller.focusedThreadId() === null) {
      controller.clearFocus()
      return
    }
    publish()
  }

  const addThread = (thread: AnchoredThread): void => {
    allThreads.value = [...allThreads.value, thread]
    publish()
  }

  const resolveThread = (id: string, resolved = true): boolean => {
    let found = false
    allThreads.value = allThreads.value.map(thread => {
      if (thread.id !== id) return thread
      found = true
      return { ...thread, resolved }
    })
    if (found) publish()
    return found
  }

  const focusThread = (id: string): boolean => controller.focusThread(id)

  const clearFocus = (): void => {
    controller.clearFocus()
  }

  const reset = (filePath?: string): void => {
    if (filePath !== undefined) activeFilePath.value = filePath
    allThreads.value = []
    if (focusedThreadIdSignal.value !== null) controller.clearFocus()
    else publish()
  }

  const subscribe = (listener: () => void): (() => void) => {
    let sawInitialSnapshot = false
    const unsubscribe = visibleThreadsSignal.subscribe(() => {
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        return
      }
      listener()
    })
    return unsubscribe
  }

  return {
    filePath: () => activeFilePath.value,
    seed,
    addThread,
    resolveThread,
    visibleThreads: () => visibleThreadsSignal.value,
    threadsForLine: controller.threadsForLine,
    focusedThreadId: () => focusedThreadIdSignal.value,
    focusThread,
    clearFocus,
    knownAuthors: () => authorsSignal.value,
    reset,
    subscribe,
  }
}

function sortedAuthors(threads: ReadonlyArray<AnchoredThread>): ReadonlyArray<string> {
  const authors = new Set<string>()
  for (const thread of threads) authors.add(thread.author_keeper_id)
  return [...authors].sort()
}

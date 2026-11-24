/**
 * View Stream Slot — Enforces the TUI `2+1 SSE` connection invariant.
 *
 * At most ONE view-specific live SSE stream may hold the slot at any time
 * (alongside the shared Observer SSE stream). Acquiring the slot for a new view
 * immediately aborts the prior stream via its `AbortController` and bumps a
 * monotonic `generation` counter.
 *
 * Visibility & Epoch guards:
 * - Auto-pauses (aborts stream) when `document.hidden === true` and reconnects
 *   when `document.visibilityState === 'visible'`.
 * - Auto-releases when `sessionEpoch` advances (Account or Workspace switch).
 */

import { signal, type ReadonlySignal } from '@preact/signals'
import { currentSessionEpoch, sessionEpoch } from './auth'

export type ViewStreamConnector = (signal: AbortSignal, generation: number) => void | (() => void)

export interface ViewStreamHandle {
  readonly key: string
  readonly generation: number
  readonly paused: ReadonlySignal<boolean>
  release(): void
}

interface ActiveSlot {
  readonly key: string
  readonly connect: ViewStreamConnector
  readonly epoch: number
  generation: number
  controller: AbortController | null
  cleanup: (() => void) | null
}

const activeKeySignal = signal<string | null>(null)
const generationSignal = signal<number>(0)
const pausedSignal = signal<boolean>(false)

let activeSlot: ActiveSlot | null = null
let guardsInstalled = false

export const activeViewStreamKey: ReadonlySignal<string | null> = activeKeySignal
export const viewStreamGeneration: ReadonlySignal<number> = generationSignal
export const viewStreamPaused: ReadonlySignal<boolean> = pausedSignal

function stopSlotConnection(slot: ActiveSlot): void {
  const ctrl = slot.controller
  const cleanup = slot.cleanup
  slot.controller = null
  slot.cleanup = null
  if (ctrl && !ctrl.signal.aborted) {
    ctrl.abort('view_stream_preempted')
  }
  if (cleanup) {
    try { cleanup() } catch { /* ignore teardown errors */ }
  }
}

function startSlotConnection(slot: ActiveSlot): void {
  if (activeSlot !== slot) return
  if (typeof document !== 'undefined' && document.hidden) {
    pausedSignal.value = true
    return
  }
  pausedSignal.value = false
  const nextGen = generationSignal.peek() + 1
  generationSignal.value = nextGen
  slot.generation = nextGen
  const controller = new AbortController()
  slot.controller = controller
  try {
    const maybeCleanup = slot.connect(controller.signal, nextGen)
    if (typeof maybeCleanup === 'function') {
      slot.cleanup = maybeCleanup
    }
  } catch (err) {
    slot.controller = null
    slot.cleanup = null
    if (!controller.signal.aborted) {
      controller.abort('view_stream_connect_failed')
    }
    if (activeSlot === slot) {
      activeSlot = null
      activeKeySignal.value = null
      pausedSignal.value = false
    }
    throw err
  }
}

function ensureGuards(): void {
  if (guardsInstalled) return
  guardsInstalled = true

  sessionEpoch.subscribe(() => {
    if (activeSlot && activeSlot.epoch !== currentSessionEpoch()) {
      releaseAllViewStreams()
    }
  })

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (!activeSlot) return
      if (document.hidden) {
        stopSlotConnection(activeSlot)
        pausedSignal.value = true
      } else if (activeSlot.controller === null) {
        startSlotConnection(activeSlot)
      }
    })
  }
}

/**
 * Acquires the single view-stream slot for `key`, preempting and aborting any
 * previously held view stream immediately.
 */
export function acquireViewStream(
  key: string,
  connect: ViewStreamConnector,
): ViewStreamHandle {
  ensureGuards()
  if (activeSlot) {
    stopSlotConnection(activeSlot)
    activeSlot = null
  }

  const slot: ActiveSlot = {
    key,
    connect,
    epoch: currentSessionEpoch(),
    generation: generationSignal.peek(),
    controller: null,
    cleanup: null,
  }
  activeSlot = slot
  activeKeySignal.value = key
  startSlotConnection(slot)

  return {
    key,
    get generation() {
      return slot.generation
    },
    paused: pausedSignal,
    release() {
      if (activeSlot !== slot) return
      stopSlotConnection(slot)
      activeSlot = null
      activeKeySignal.value = null
      pausedSignal.value = false
    },
  }
}

export function releaseAllViewStreams(): void {
  if (activeSlot) {
    stopSlotConnection(activeSlot)
    activeSlot = null
  }
  activeKeySignal.value = null
  pausedSignal.value = false
}

export function getActiveViewStreamKey(): string | null {
  return activeKeySignal.peek()
}

export function getViewStreamGeneration(): number {
  return generationSignal.peek()
}

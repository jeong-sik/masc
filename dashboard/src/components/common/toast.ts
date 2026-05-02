import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { ComponentChildren } from 'preact'
import { CheckCircle2, AlertTriangle, XCircle, X } from 'lucide-preact'

type ToastType = 'success' | 'warning' | 'error'

interface ToastAction {
  label: string
  onClick: () => void
}

interface Toast {
  id: number
  message: string
  type: ToastType
  action?: ToastAction
}

let _nextId = 0
const toasts = signal<Toast[]>([])

/** Sonner / react-hot-toast cap: more than ~5 visible at once degrades
    into screen spam. When a sixth arrives we evict the oldest so the
    new one lands without the stack growing unbounded.

    Reference — Sonner's `visibleToasts` default is 3; react-hot-toast
    doesn't cap out of the box but most teams wrap it with a cap. We
    pick 5 here because masc-mcp often bursts 3-4 "sidecar started"
    toasts on bulk Start All, and 5 leaves headroom for one incidental
    toast on top. */
export const MAX_VISIBLE_TOASTS = 5

function enqueueToast(toast: Toast) {
  const current = toasts.value
  const next = current.length >= MAX_VISIBLE_TOASTS
    ? [...current.slice(current.length - MAX_VISIBLE_TOASTS + 1), toast]
    : [...current, toast]
  toasts.value = next
}

const BORDER_COLOR: Record<ToastType, string> = {
  success: 'border-l-[var(--color-status-ok)]',
  warning: 'border-l-[var(--color-status-warn)]',
  error: 'border-l-[var(--color-status-err)]'
}

const ICON_COLOR: Record<ToastType, string> = {
  success: 'text-[var(--color-status-ok)]',
  warning: 'text-[var(--color-status-warn)]',
  error: 'text-[var(--color-status-err)]'
}

const ICON: Record<ToastType, () => ComponentChildren> = {
  success: () => html`<${CheckCircle2} size=${14} />`,
  warning: () => html`<${AlertTriangle} size=${14} />`,
  error: () => html`<${XCircle} size=${14} />`
}

/** Pure: default dismiss duration per toast type. Reference — Sentry
    error banner lingers, GitHub success toast is quick. Error toasts
    need more reading time AND often carry information the operator
    wants to copy (stack, id, retry token); dismissing at 4s has
    burned users. Warnings sit in the middle. Success confirms an
    already-completed action, so short is fine.

    Callers that pass an explicit \`durationMs\` still win. */
export function defaultToastDuration(type: ToastType): number {
  switch (type) {
    case 'success': return 3000
    case 'warning': return 5000
    case 'error': return 8000
  }
}

/** Per-toast dismiss bookkeeping — one entry while the toast is
    visible. `paused === true` means the timer has been cleared and
    the remaining ms should resume on the next resume call. Tracked
    here (module scope) instead of on the Toast record so we don't
    re-render the whole stack every time a timer advances. */
interface ToastTimer {
  remainingMs: number
  startedAt: number
  timerId: number
  paused: boolean
}
const toastTimers = new Map<number, ToastTimer>()

function scheduleToastDismiss(id: number, ms: number): void {
  const timerId = (typeof window === 'undefined'
    ? setTimeout(() => finalizeDismiss(id), ms)
    : window.setTimeout(() => finalizeDismiss(id), ms)) as unknown as number
  toastTimers.set(id, { remainingMs: ms, startedAt: Date.now(), timerId, paused: false })
}

function finalizeDismiss(id: number): void {
  toasts.value = toasts.value.filter(t => t.id !== id)
  toastTimers.delete(id)
}

/** Pause the dismiss timer for a toast — called on hover enter.
    Computes the elapsed time and stores the remainder so resume can
    schedule the same wall-clock deadline. Idempotent: calling twice
    is a no-op (Sonner / Sentry behaviour: nested hover from a child
    does not restart the clock). */
export function pauseToastTimer(id: number): void {
  const t = toastTimers.get(id)
  if (t === undefined || t.paused) return
  if (typeof window !== 'undefined') window.clearTimeout(t.timerId)
  else clearTimeout(t.timerId)
  const elapsed = Date.now() - t.startedAt
  const remaining = Math.max(0, t.remainingMs - elapsed)
  toastTimers.set(id, { remainingMs: remaining, startedAt: 0, timerId: -1, paused: true })
}

/** Resume a previously-paused dismiss. If the remaining time has
    already elapsed (e.g. paused at 0s left, mouse lingered forever),
    dismisses immediately. Idempotent on already-running timers. */
export function resumeToastTimer(id: number): void {
  const t = toastTimers.get(id)
  if (t === undefined || !t.paused) return
  if (t.remainingMs <= 0) { finalizeDismiss(id); return }
  scheduleToastDismiss(id, t.remainingMs)
}

export function showToast(message: string, type: ToastType = 'success', durationMs?: number) {
  const id = ++_nextId
  const dismissMs = durationMs ?? defaultToastDuration(type)
  enqueueToast({ id, message, type })
  scheduleToastDismiss(id, dismissMs)
}

export function showActionToast(message: string, action: ToastAction, type: ToastType = 'error', durationMs = 12000) {
  const id = ++_nextId
  enqueueToast({ id, message, type, action })
  scheduleToastDismiss(id, durationMs)
}

function dismissToast(id: number) {
  const t = toastTimers.get(id)
  if (t !== undefined) {
    if (typeof window !== 'undefined') window.clearTimeout(t.timerId)
    else clearTimeout(t.timerId)
    toastTimers.delete(id)
  }
  toasts.value = toasts.value.filter(t => t.id !== id)
}

/** Test-only: wipe the toast queue so assertions don't see leftovers
    from earlier tests. Not a public reset — the sequence id counter
    is deliberately left intact so ids remain unique across tests. */
export function _testResetToasts() {
  toasts.value = []
}

/** Test-only: snapshot of the current toast queue. Keeps the signal
    private while still letting tests assert on the stored shape. */
export function _testGetToasts(): ReadonlyArray<{ id: number; message: string; type: ToastType }> {
  return toasts.value.map(t => ({ id: t.id, message: t.message, type: t.type }))
}

export function ToastContainer() {
  const items = toasts.value
  if (items.length === 0) return null

  return html`
    <div
      class="fixed top-5 right-5 z-[var(--z-overlay-toast,3070)] flex flex-col gap-2 pointer-events-none"
      aria-live="polite"
      aria-atomic="true"
    >
      ${items.map(t => html`
        <div
          key=${t.id}
          role=${t.type === 'error' ? 'alert' : 'status'}
          class="pointer-events-auto flex items-center gap-2.5 py-2 px-3 min-w-55 max-w-90 rounded-[var(--r-1)] border-l-[3px] border-l-solid border border-solid border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] shadow-sm animate-[slideInRight_var(--enter-duration)_var(--enter-easing)] ${BORDER_COLOR[t.type]}"
          onMouseEnter=${() => pauseToastTimer(t.id)}
          onMouseLeave=${() => resumeToastTimer(t.id)}
          onFocusIn=${() => pauseToastTimer(t.id)}
          onFocusOut=${() => resumeToastTimer(t.id)}
          data-toast-id=${t.id}
        >
          <span class="shrink-0 flex items-center ${ICON_COLOR[t.type]}">${ICON[t.type]()}</span>
          <span class="flex-1 text-sm text-[var(--color-fg-primary)] leading-[1.4]">${t.message}</span>
          ${t.action ? html`
            <button
              type="button"
              class="shrink-0 text-2xs px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-5)] text-[var(--color-accent-fg)] hover:bg-[var(--white-10)] cursor-pointer transition-colors duration-[var(--t-fast)]"
              onClick=${(e: Event) => {
                e.stopPropagation()
                t.action!.onClick()
                dismissToast(t.id)
              }}
            >
              ${t.action.label}
            </button>
          ` : null}
          <button
            type="button"
            class="shrink-0 text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] cursor-pointer p-1 rounded hover:bg-[var(--white-5)] transition-colors duration-[var(--t-fast)] flex items-center justify-center"
            aria-label="닫기"
            title="닫기"
            onClick=${(e: Event) => {
              e.stopPropagation()
              dismissToast(t.id)
            }}
          >
            <${X} size=${14} />
          </button>
        </div>
      `)}
    </div>
  `
}

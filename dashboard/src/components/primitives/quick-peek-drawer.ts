/**
 * Read-only Right Quick-Peek Drawer (`480px` default, `720px/760px` wide expand `[⤢]`).
 *
 * - Push layout on `>=1440px` viewports (`data-mode="push"`), overlay below (`data-mode="overlay"`).
 * - Pressing `Escape` closes the drawer and restores focus to the trigger element.
 * - Strictly read-only inspector surface (never owns inline HITL mutations).
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'

export type QuickPeekMode = 'auto' | 'push' | 'overlay'

export interface QuickPeekDrawerProps {
  readonly open: boolean
  readonly title: string
  readonly subtitle?: ComponentChildren
  readonly mode?: QuickPeekMode
  readonly defaultWide?: boolean
  readonly onClose: () => void
  readonly headerActions?: ComponentChildren
  readonly children: ComponentChildren
}

function detectDesktopPush(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false
  return window.matchMedia('(min-width: 1440px)').matches
}

export function QuickPeekDrawer(props: QuickPeekDrawerProps) {
  const [wide, setWide] = useState(props.defaultWide ?? false)
  const [isPushViewport, setIsPushViewport] = useState(detectDesktopPush)
  const previousFocusRef = useRef<HTMLElement | null>(null)
  const closeBtnRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const mq = window.matchMedia('(min-width: 1440px)')
    const onChange = (ev: MediaQueryListEvent) => setIsPushViewport(ev.matches)
    setIsPushViewport(mq.matches)
    mq.addEventListener?.('change', onChange)
    return () => mq.removeEventListener?.('change', onChange)
  }, [])

  useEffect(() => {
    if (!props.open) return
    previousFocusRef.current =
      typeof document !== 'undefined' && document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        props.onClose()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      previousFocusRef.current?.focus?.()
    }
  }, [props.open, props.onClose])

  if (!props.open) return null

  const resolvedMode = props.mode === 'push'
    ? 'push'
    : props.mode === 'overlay'
      ? 'overlay'
      : isPushViewport
        ? 'push'
        : 'overlay'

  const isOverlay = resolvedMode === 'overlay'

  return html`
    ${isOverlay && html`
      <div
        class="qpeek-backdrop"
        aria-hidden="true"
        onClick=${props.onClose}
      />
    `}
    <aside
      class="qpeek"
      role=${isOverlay ? 'dialog' : 'complementary'}
      aria-modal=${isOverlay ? 'true' : undefined}
      aria-label=${props.title}
      data-mode=${resolvedMode}
      data-wide=${wide ? 'true' : 'false'}
    >
      <header class="qpeek-head">
        <div>
          <h2 class="qpeek-title">${props.title}</h2>
          ${props.subtitle && html`<div>${props.subtitle}</div>`}
        </div>
        <div class="qpeek-actions">
          ${props.headerActions}
          <button
            type="button"
            class="btn-ghost"
            aria-pressed=${wide ? 'true' : 'false'}
            aria-label=${wide ? '기본 너비로 축소' : '넓게 보기'}
            title=${wide ? '기본 너비로 축소' : '넓게 보기'}
            onClick=${() => setWide((w) => !w)}
          >
            ⤢
          </button>
          <button
            ref=${closeBtnRef}
            type="button"
            class="btn-ghost"
            aria-label="닫기"
            onClick=${props.onClose}
          >
            ✕
          </button>
        </div>
      </header>
      <div class="qpeek-body">
        ${props.children}
      </div>
    </aside>
  `
}

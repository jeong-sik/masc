/**
 * Read-only Right Quick-Peek Drawer (`480px` default, `720px/760px` wide expand `[⤢]`).
 *
 * - Push layout on `>=1440px` viewports (`data-mode="push"`), overlay below (`data-mode="overlay"`).
 * - Pressing `Escape` closes the drawer and restores focus to the trigger element.
 * - Strictly read-only inspector surface (never owns inline HITL mutations).
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'
import { isEditableTarget } from '../../lib/keyboard'
import { SplitHandle, useSplitSize } from './split-handle'

export type QuickPeekMode = 'auto' | 'push' | 'overlay'

const QPEEK_MIN_WIDTH = 360
const QPEEK_MAX_WIDTH = 960
const QPEEK_DEFAULT_WIDTH = 480
const QPEEK_WIDE_WIDTH = 720
const QPEEK_WIDE_THRESHOLD = 640

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
  const { size: drawerWidth, setSize: setDrawerWidth } = useSplitSize({
    id: 'quick-peek',
    defaultSize: props.defaultWide ? QPEEK_WIDE_WIDTH : QPEEK_DEFAULT_WIDTH,
    min: QPEEK_MIN_WIDTH,
    max: QPEEK_MAX_WIDTH,
  })
  const [wide, setWide] = useState(() => (props.defaultWide ?? false) || drawerWidth >= QPEEK_WIDE_THRESHOLD)
  const wideRef = useRef(wide)
  wideRef.current = wide
  const [isPushViewport, setIsPushViewport] = useState(detectDesktopPush)
  const previousFocusRef = useRef<HTMLElement | null>(null)
  const drawerRef = useRef<HTMLElement>(null)
  const closeBtnRef = useRef<HTMLButtonElement>(null)
  const bodyRef = useRef<HTMLDivElement>(null)
  const onCloseRef = useRef(props.onClose)
  onCloseRef.current = props.onClose

  const toggleWide = useCallback(() => {
    const nextWide = !wideRef.current
    wideRef.current = nextWide
    const nextWidth = nextWide ? QPEEK_WIDE_WIDTH : QPEEK_DEFAULT_WIDTH
    setWide(nextWide)
    setDrawerWidth(nextWidth)
    drawerRef.current?.style.setProperty('--qpeek-w', `${nextWidth}px`)
  }, [setDrawerWidth])

  const handleResizeChange = useCallback(
    (next: number) => {
      const nextWide = next >= QPEEK_WIDE_THRESHOLD
      wideRef.current = nextWide
      setDrawerWidth(next)
      setWide(nextWide)
    },
    [setDrawerWidth],
  )

  const resolvedMode = props.mode === 'push'
    ? 'push'
    : props.mode === 'overlay'
      ? 'overlay'
      : isPushViewport
        ? 'push'
        : 'overlay'

  const isOverlay = resolvedMode === 'overlay'

  useFocusScope({
    containerRef: drawerRef,
    active: props.open && isOverlay,
    initialFocus: () => {
      const activeEl = typeof document !== 'undefined' ? document.activeElement : null
      if (activeEl && drawerRef.current?.contains(activeEl)) return null
      return closeBtnRef.current
    },
    restoreFocus: false,
  })

  useEffect(() => {
    if (bodyRef.current) bodyRef.current.scrollTop = 0
  }, [props.title, props.subtitle, props.open])

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const mq = window.matchMedia('(min-width: 1440px)')
    const onChange = (ev: MediaQueryListEvent) => setIsPushViewport(ev.matches)
    setIsPushViewport(mq.matches)
    mq.addEventListener?.('change', onChange)
    return () => mq.removeEventListener?.('change', onChange)
  }, [])

  useLayoutEffect(() => {
    if (!props.open) return
    previousFocusRef.current =
      typeof document !== 'undefined' && document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null

    closeBtnRef.current?.focus?.()

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        if (typeof document !== 'undefined') {
          const otherModalOpen = Array.from(
            document.querySelectorAll('[role="dialog"][aria-modal="true"]'),
          ).some((el) => el !== drawerRef.current)
          if (otherModalOpen) return
        }
        event.preventDefault()
        event.stopPropagation()
        onCloseRef.current()
        return
      }
      if (!event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'z') {
        if (isEditableTarget(event.target)) {
          return
        }
        if (typeof document !== 'undefined') {
          const otherModalOpen = Array.from(
            document.querySelectorAll('[role="dialog"][aria-modal="true"]'),
          ).some((el) => el !== drawerRef.current)
          if (otherModalOpen) return
        }
        event.preventDefault()
        toggleWide()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      previousFocusRef.current?.focus?.()
    }
  }, [props.open, toggleWide])

  if (!props.open) return null

  return html`
    ${isOverlay && html`
      <div
        class="qpeek-backdrop"
        aria-hidden="true"
        onClick=${props.onClose}
      />
    `}
    <aside
      ref=${drawerRef}
      class="qpeek"
      role=${isOverlay ? 'dialog' : 'complementary'}
      aria-modal=${isOverlay ? 'true' : undefined}
      aria-label=${props.title}
      data-mode=${resolvedMode}
      data-wide=${wide ? 'true' : 'false'}
      data-resizable="true"
      style=${{ '--qpeek-w': `${drawerWidth}px` } as Record<string, string>}
    >
      <${SplitHandle}
        id="quick-peek"
        orientation="vertical"
        value=${drawerWidth}
        defaultSize=${QPEEK_DEFAULT_WIDTH}
        min=${QPEEK_MIN_WIDTH}
        max=${QPEEK_MAX_WIDTH}
        cssVar="--qpeek-w"
        targetRef=${drawerRef}
        onChange=${handleResizeChange}
        reverse=${true}
        label="미리보기 서랍 너비 조절"
        className="qpeek-split-handle"
      />
      <header class="qpeek-head">
        <div>
          <h2 class="qpeek-title">${props.title}</h2>
          ${props.subtitle && html`<div class="qpeek-sub">${props.subtitle}</div>`}
        </div>
        <div class="qpeek-actions">
          ${props.headerActions}
          <button
            type="button"
            class="btn-ghost"
            aria-pressed=${wide ? 'true' : 'false'}
            aria-label=${wide ? '기본 너비로 축소' : '넓게 보기'}
            title=${wide ? '기본 너비로 축소' : '넓게 보기'}
            onClick=${toggleWide}
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
      <div ref=${bodyRef} class="qpeek-body">
        ${props.children}
      </div>
    </aside>
  `
}

// ScrollToTopButton — floating \"back to top\" affordance.
//
// Reference UIs (Gmail thread list, YouTube channel grid, GitHub
// issue discussion, Twitter/X feed): once the user has scrolled
// past a threshold, a floating circular button appears at the
// bottom-right. Click smooth-scrolls to the top of the scroll
// container. It's background-quiet until you need it, then it's
// exactly where the thumb / mouse expects.
//
// Why add one here: connector cards, keeper detail panels, fsm-hub
// timelines, and the session trace view routinely produce pages
// that scroll multiple viewports. Operators who've drilled deep
// into a panel lose their orientation — a reliable \"home\" anchor
// is a tiny UX investment.
//
// Pure helper shouldShowScrollToTop exposed so callers (tests,
// future embedded uses) can pin the threshold semantics without
// simulating a real scroll event.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { ChevronUp } from 'lucide-preact'

/** Pure: decide whether the button should be visible based on the
    current scroll offset. Threshold matches what Gmail / YouTube
    use — ~one viewport's worth — so the button appears when the
    operator has actually lost their anchor, not on the first
    scroll wiggle. */
export function shouldShowScrollToTop(scrollY: number, thresholdPx = 400): boolean {
  return scrollY >= thresholdPx
}

interface ScrollToTopButtonProps {
  /** Threshold in pixels before the button fades in. Default 400
      matches Gmail / YouTube; callers with a denser layout can
      lower it. */
  thresholdPx?: number
  class?: string
  testId?: string
}

/** Pure: scroll the window to the top. Split so tests can call it
    directly and not rely on a real browser scroll API. */
export function scrollWindowToTop(): void {
  if (typeof window === 'undefined') return
  window.scrollTo({ top: 0, behavior: 'smooth' })
}

export function ScrollToTopButton({
  thresholdPx = 400,
  class: cx,
  testId,
}: ScrollToTopButtonProps = {}) {
  const [visible, setVisible] = useState<boolean>(
    typeof window !== 'undefined'
      ? shouldShowScrollToTop(window.scrollY, thresholdPx)
      : false,
  )
  useEffect(() => {
    if (typeof window === 'undefined') return
    const update = () => {
      setVisible(shouldShowScrollToTop(window.scrollY, thresholdPx))
    }
    update() // sync initial state in case scrollY changed between mount and render
    window.addEventListener('scroll', update, { passive: true })
    return () => window.removeEventListener('scroll', update)
  }, [thresholdPx])

  if (!visible) return null

  return html`<button
    type="button"
    class=${`fixed bottom-6 right-6 z-[var(--z-overlay-toast,3070)] flex h-10 w-10 items-center justify-center rounded-sm border border-[var(--white-10)] bg-[var(--bg-1)]/90 text-[var(--text-body)] shadow-[0_6px_18px_rgba(0,0,0,0.32)] backdrop-blur transition-all duration-150 hover:border-[var(--accent-30)] hover:text-[var(--accent)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-0)] cursor-pointer ${cx ?? ''}`}
    aria-label="맨 위로"
    title="맨 위로 (Home)"
    data-scroll-to-top
    data-testid=${testId}
    onClick=${scrollWindowToTop}
  >
    <${ChevronUp} size=${18} />
  </button>`
}

/**
 * Master-detail: a list beside what is picked from it.
 *
 * - Wide container: both panes side by side, 42% / 58%.
 * - Container under 768px (`primitives.css`): one pane at a time at the full
 *   height, with a switch between the two that names them.
 *
 * Which pane a narrow container shows is the reader's call, with three things
 * decided for them when the screen says what is selected (`selectionKey`):
 * - a click on a row of the list, or on a control marked `data-opens-detail`,
 *   shows the detail, and a click on a control of the detail marked
 *   `data-opens-master` shows the list;
 * - with nothing selected the list is shown;
 * - a link to one item (`linkedKey`) shows the detail of that item once there
 *   is one. Until then the pane that was shown stays: the list, or the detail
 *   for as long as the screen keeps the item it was showing. What a screen
 *   selects in place of the linked item is not opened for it. The reader's
 *   first click or key in a pane ends the wait, and so does an address that
 *   stops naming an item: the pane shown then is not taken from them.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'

export interface MasterDetailProps {
  readonly master: ComponentChildren
  readonly detail: ComponentChildren
  /** Shown in the detail pane while `hasSelection` is false. */
  readonly emptyDetail?: ComponentChildren
  /**
   * Whether `detail` has something to say of what is selected: the item, or
   * that it is loading, or why it cannot be read. A link waits for it.
   */
  readonly hasSelection?: boolean
  /**
   * What is selected, `null` for nothing. Given, the detail pane is of that
   * item. Left out, the panes are two views with no pick between them.
   */
  readonly selectionKey?: string | number | null
  /** The item a link to this screen names, `null` for a link to the screen. */
  readonly linkedKey?: string | number | null
  readonly masterLabel?: string
  readonly detailLabel?: string
  readonly className?: string
}

type Pane = 'master' | 'detail'
type Key = string | number

/** In the master pane: a row of its list, or a control that says it opens the detail. */
const OPENER_SELECTOR = '[role="listitem"], [data-opens-detail]'

/** In the detail pane: a control that says it goes back to the list. */
const CLOSER_SELECTOR = '[data-opens-master]'

/** Whether a click passed through an element matching `selector` inside the pane that hears it. */
function clickedIn(event: MouseEvent, selector: string): boolean {
  for (const node of event.composedPath()) {
    if (node === event.currentTarget) return false
    if (node instanceof Element && node.matches(selector)) return true
  }
  return false
}

/**
 * What a detail pane says when a link names an item the list does not hold.
 * The screen keeps that item selected and selects no other in its place, so
 * the reader is told why the detail is empty.
 */
export function LinkedItemAbsent(props: { readonly kind: string; readonly id: string; readonly class: string }) {
  return html`
    <div class=${props.class} role="status" data-testid="linked-item-absent">
      이 링크가 가리키는 ${props.kind}(<span class="mono">${props.id}</span>)가 목록에 없습니다.
    </div>
  `
}

export function MasterDetail(props: MasterDetailProps) {
  const showDetail = props.hasSelection ?? true
  const masterLabel = props.masterLabel ?? '목록'
  const detailLabel = props.detailLabel ?? '상세 정보'
  const containerRef = useRef<HTMLDivElement>(null)
  const masterRef = useRef<HTMLElement>(null)
  const detailRef = useRef<HTMLElement>(null)

  const followsSelection = props.selectionKey !== undefined
  const nothingSelected = props.selectionKey === null
  const selected = props.selectionKey ?? null
  const linked = props.linkedKey ?? null

  // The pane the reader asked a narrow container to show. A wide one shows
  // both and ignores it.
  const [asked, setAsked] = useState<Pane>('master')
  // The item a link named, until the reader takes a pane themselves or the
  // address stops naming an item. Its detail is shown once there is one,
  // whatever pane was asked for.
  const [awaited, setAwaited] = useState<Key | null>(linked)
  // The item whose detail was shown when that link was followed. Its detail
  // stays for as long as the screen keeps it selected.
  const [kept, setKept] = useState<Key | null>(null)
  const awaitedIsThere = selected === awaited && showDetail
  const linkShowsDetail = awaited !== null && selected !== null && (awaitedIsThere || selected === kept)
  const shownPane: Pane = linkShowsDetail || asked === 'detail' ? 'detail' : 'master'

  // The address changed while this screen is open.
  const [linkedBefore, setLinkedBefore] = useState(linked)
  if (linkedBefore !== linked) {
    setLinkedBefore(linked)
    setAwaited(linked)
    if (linked === null) {
      // It names no item any more: nothing is waited for, and the pane that
      // is shown stays.
      setAsked(shownPane)
    } else {
      // It names another item: that one is waited for as the item of a link
      // the screen opened on is. The pane asked for before is not asked for
      // by this link; a detail that is shown stays for its own item only.
      setAsked('master')
      setKept(shownPane === 'detail' ? selected : null)
    }
  } else if (kept !== null && selected !== kept) {
    // The screen let go of the item whose detail was kept. Selected again
    // later, as a reload selects, it is an item nobody picked.
    setKept(null)
  }

  // With nothing selected the list is shown: the detail asked for is dropped
  // before this render is drawn, so a selection made later without a pick, as
  // a reload makes one, does not bring the detail back. The item a link named
  // is still waited for.
  if (nothingSelected && asked === 'detail') setAsked('master')

  /** The reader's own choice of a pane: no link is waited for after it. */
  const take = (pane: Pane) => {
    setAsked(pane)
    setAwaited(null)
  }

  useEffect(() => {
    if (props.selectionKey === undefined) return
    if (detailRef.current) {
      detailRef.current.scrollTop = 0
    }
  }, [props.selectionKey])

  // The path is the one the click took, whatever its handlers did to the tree
  // on the way: it is read up to the pane and no further. A click that picks
  // nothing ends the wait for a link and keeps the pane it showed: in a wide
  // container the list is used beside the detail of the linked item.
  const onMasterClick = (event: MouseEvent) => {
    if (!followsSelection) return
    if (clickedIn(event, OPENER_SELECTOR)) take('detail')
    else if (awaited !== null) take(shownPane)
  }

  // A key pressed in a pane is the reader using it, as a click in it is.
  const onMasterKeyDown = () => {
    if (followsSelection && awaited !== null) take(shownPane)
  }

  const onDetailKeyDown = () => {
    if (followsSelection && awaited !== null) take('detail')
  }

  // Heard on the way down, before the control's own handler: a control of the
  // detail that selects another item finds the detail already the reader's,
  // and the list is not shown for the render in between.
  const onDetailClick = (event: MouseEvent) => {
    if (!followsSelection) return
    if (clickedIn(event, CLOSER_SELECTOR)) take('master')
    else if (awaited !== null) take('detail')
  }

  // The control the focus was last put on and the pane it was in. `left` says
  // the reader took the focus off it: its pane was shown, and the control was
  // still there when the event was over. A browser takes the focus off a
  // control it finds hidden, and may raise the event for one it is removing.
  // A control that goes away may also raise no event: what is noted here
  // still names it.
  const lastFocus = useRef<{ readonly control: Node; readonly pane: Pane | null; readonly left: boolean } | null>(null)
  useEffect(() => {
    const noteIn = (event: FocusEvent) => {
      const control = event.target
      if (!(control instanceof Node)) return
      let pane: Pane | null = null
      if (masterRef.current?.contains(control)) pane = 'master'
      else if (detailRef.current?.contains(control)) pane = 'detail'
      lastFocus.current = { control, pane, left: false }
    }
    const noteOut = () => {
      const last = lastFocus.current
      if (last === null || last.pane === null) return
      const pane = last.pane === 'master' ? masterRef.current : detailRef.current
      if (!pane || getComputedStyle(pane).visibility === 'hidden') return
      queueMicrotask(() => {
        if (lastFocus.current === last && last.control.isConnected) lastFocus.current = { ...last, left: true }
      })
    }
    document.addEventListener('focusin', noteIn)
    document.addEventListener('focusout', noteOut)
    return () => {
      document.removeEventListener('focusin', noteIn)
      document.removeEventListener('focusout', noteOut)
    }
  }, [])

  // The focus follows out of a pane that gets hidden: from a control in it, or
  // from nowhere when the pane had it until then. That is told by the control
  // the focus was last on: it was in that pane and the reader did not take
  // the focus off it. A focus the reader put elsewhere, on another control or
  // on nothing, is left alone. Whether a pane is hidden is the stylesheet's
  // call, so it is read from there. The focus moves for the keyboard; the
  // page stays where the reader has it.
  const followFocus = (shownNow: Pane) => {
    const hiddenPane: Pane = shownNow === 'detail' ? 'master' : 'detail'
    const hidden = hiddenPane === 'master' ? masterRef.current : detailRef.current
    const shown = hiddenPane === 'master' ? detailRef.current : masterRef.current
    if (!hidden || !shown) return
    const active = document.activeElement
    const nowhere = active === null || active === document.body || !active.isConnected
    const last = lastFocus.current
    const hadItUntilHidden = last !== null && last.pane === hiddenPane && !last.left
    const wasInHidden = nowhere ? hadItUntilHidden : hidden.contains(active)
    if (!wasInHidden) return
    if (getComputedStyle(hidden).visibility === 'hidden') shown.focus({ preventScroll: true })
  }

  // A pane gets hidden when the other one is shown in its place: in the render
  // that does it, before the browser takes the focus off a hidden element.
  useLayoutEffect(() => {
    followFocus(shownPane)
  }, [shownPane])

  // And when its container is made narrow, with no render of this component.
  // A browser may have taken the focus off the hidden control by then.
  useEffect(() => {
    const container = containerRef.current
    if (!container || typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(() => followFocus(shownPane))
    observer.observe(container)
    return () => observer.disconnect()
  }, [shownPane])

  return html`
    <div class="md-container" ref=${containerRef}>
      <div class=${`md-split ${props.className ?? ''}`.trim()} data-pane=${shownPane}>
        <div class="md-switch" role="group" aria-label="표시할 영역">
          <button
            type="button"
            class="md-switch-btn"
            aria-pressed=${shownPane === 'master'}
            onClick=${() => take('master')}
          >${masterLabel}</button>
          <button
            type="button"
            class="md-switch-btn"
            aria-pressed=${shownPane === 'detail'}
            disabled=${nothingSelected}
            onClick=${() => take('detail')}
          >${detailLabel}</button>
        </div>
        <section
          ref=${masterRef}
          class="md-master"
          tabindex="-1"
          aria-label=${masterLabel}
          onClick=${onMasterClick}
          onKeyDown=${onMasterKeyDown}
        >
          ${props.master}
        </section>
        <section
          ref=${detailRef}
          class="md-detail"
          tabindex="-1"
          aria-label=${detailLabel}
          onClickCapture=${onDetailClick}
          onKeyDown=${onDetailKeyDown}
        >
          ${showDetail
            ? props.detail
            : (props.emptyDetail ?? html`<div class="dtable-absent">항목을 선택하세요.</div>`)}
        </section>
      </div>
    </div>
  `
}

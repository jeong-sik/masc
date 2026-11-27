/**
 * The refresh button of a workspace toolbar.
 *
 * A press starts a read. From the press until the read ends the button says
 * so, so a slow server never leaves a press unanswered. A read often ends
 * within a few frames: the in-flight label would flash unread and the press
 * would look unanswered, so the label stays until `REFRESH_MIN_BUSY_MS` after
 * the press at the least.
 *
 * Every press is taken. One that comes while a read is out starts the read
 * again, and the label then follows that later read: a request that never
 * answers must not leave the operator with a button that does nothing. A read
 * through `resourceCache.fetch` with `reason: 'manual'` ends the request it
 * replaces; a loader of its own that cannot is left to finish unseen.
 *
 * The button is always as wide as the wider of its two labels (see
 * `.refresh-btn` in primitives.css): the toolbar holds still when the label
 * changes.
 */
import { html } from 'htm/preact'
import { useRef, useState } from 'preact/hooks'

export interface RefreshButtonProps {
  /** Starts the read. Its promise ends when the read does, whatever the
   *  outcome; showing a failure stays with the caller. */
  readonly onRefresh: () => Promise<unknown>
  /** Names what is read again when "새로고침" alone would be ambiguous. */
  readonly label?: string
  /** A read the screen started itself, on mount or after a change, is out.
   *  The button says so as it does for a press, and holds as still. */
  readonly reading?: boolean
}

const DEFAULT_LABEL = '새로고침'

/** Kept about as wide as "새로고침": a longer in-flight label would widen the
 *  resting button and give it more side padding than its neighbours. */
export const REFRESH_BUSY_LABEL = '읽는 중…'

/** What a press does while a read is out, for the pointer that waits on it. */
export const REFRESH_AGAIN_HINT = '다시 누르면 처음부터 다시 읽습니다'

/** How long after a press the in-flight label comes down at the earliest. */
export const REFRESH_MIN_BUSY_MS = 400

export function RefreshButton(props: RefreshButtonProps) {
  // The label is up: a read is out, or the label's minimum time is not over.
  const [busy, setBusy] = useState(false)
  // The label comes down for the press that put it up last. An earlier press,
  // whose read or minimum time ends while a later read is out, leaves it up.
  const lastPress = useRef(0)

  const label = props.label ?? DEFAULT_LABEL
  const shownBusy = busy || props.reading === true

  const press = async () => {
    lastPress.current += 1
    const thisPress = lastPress.current
    setBusy(true)
    const shownLongEnough = new Promise<void>((resolve) => {
      setTimeout(resolve, REFRESH_MIN_BUSY_MS)
    })
    try {
      await props.onRefresh()
    } finally {
      // A read may end after the toolbar is gone: Preact drops a state set on
      // a component that is no longer there.
      await shownLongEnough
      if (lastPress.current === thisPress) setBusy(false)
    }
  }

  // Never disabled: the next press is the way out of a read that does not end.
  return html`
    <button
      type="button"
      class="btn-ghost refresh-btn"
      aria-busy=${shownBusy}
      title=${shownBusy ? REFRESH_AGAIN_HINT : undefined}
      data-label=${label}
      data-busy-label=${REFRESH_BUSY_LABEL}
      onClick=${() => void press()}
    >
      ${shownBusy ? REFRESH_BUSY_LABEL : label}
    </button>
  `
}

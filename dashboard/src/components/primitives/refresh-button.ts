/**
 * The refresh button of a workspace toolbar.
 *
 * A press starts a read. From the press until the read ends the button says
 * so and takes no second press, so a slow server never leaves a press
 * unanswered. A read often ends within a few frames: the in-flight label would
 * flash unread and the press would look unanswered, so the label stays until
 * `REFRESH_MIN_BUSY_MS` after the press at the least.
 *
 * That minimum holds the label and nothing else. Whether a press is taken
 * depends on the read alone: one that comes after the read has ended starts
 * the next read, with the label still up. A press dropped for the clock's
 * sake would be a press nobody could account for.
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
}

const DEFAULT_LABEL = '새로고침'

/** Kept about as wide as "새로고침": a longer in-flight label would widen the
 *  resting button and give it more side padding than its neighbours. */
export const REFRESH_BUSY_LABEL = '읽는 중…'

/** How long after a press the in-flight label comes down at the earliest. */
export const REFRESH_MIN_BUSY_MS = 400

export function RefreshButton(props: RefreshButtonProps) {
  // The label is up: a read is out, or the label's minimum time is not over.
  const [busy, setBusy] = useState(false)
  // A read is out. The gate is the ref: two presses inside one frame both see
  // the same render.
  const [reading, setReading] = useState(false)
  const readOut = useRef(false)
  // The label comes down for the press that put it up last. An earlier press,
  // whose minimum time ends while a later read is out, leaves it up.
  const lastPress = useRef(0)

  const label = props.label ?? DEFAULT_LABEL

  const press = async () => {
    if (readOut.current) return
    readOut.current = true
    lastPress.current += 1
    const thisPress = lastPress.current
    setReading(true)
    setBusy(true)
    const shownLongEnough = new Promise<void>((resolve) => {
      setTimeout(resolve, REFRESH_MIN_BUSY_MS)
    })
    try {
      await props.onRefresh()
    } finally {
      // A read may end after the toolbar is gone: Preact drops a state set on
      // a component that is no longer there.
      readOut.current = false
      setReading(false)
      await shownLongEnough
      if (lastPress.current === thisPress) setBusy(false)
    }
  }

  // aria-disabled, not disabled: a disabled button can drop keyboard focus,
  // and the reader would lose their place for the length of a read. It is set
  // for as long as a press is not taken, which is the read and no longer.
  return html`
    <button
      type="button"
      class="btn-ghost refresh-btn"
      aria-busy=${busy}
      aria-disabled=${reading}
      data-label=${label}
      data-busy-label=${REFRESH_BUSY_LABEL}
      onClick=${() => void press()}
    >
      ${busy ? REFRESH_BUSY_LABEL : label}
    </button>
  `
}

/** Shared keyboard ownership rules for composition, submission and dismissal. */

/** Safari can report composition keydowns with only the legacy code set. */
export function isImeComposing(
  event: Partial<Pick<KeyboardEvent, 'isComposing' | 'keyCode'>>,
): boolean {
  return event.isComposing || event.keyCode === 229
}

/** True when this keydown is a committed Enter that should trigger submit.
 *
 *  Returns false while an IME composition is active: Korean/Japanese/Chinese
 *  input commits the trailing syllable with an Enter keydown that carries
 *  `isComposing: true` (legacy engines report `keyCode: 229` instead).
 *  Treating that keydown as submit sends the message while the last
 *  character is still being composed; the IME then flushes the committed
 *  character back into the cleared input, and a queued send fires it as a
 *  stray one-character message after the reply arrives.
 *
 *  Shift/modifier semantics stay at the call site (textareas treat
 *  Shift+Enter as newline; single-line inputs do not care). */
export function isSubmitEnter(event: KeyboardEvent): boolean {
  if (event.key !== 'Enter') return false
  if (isImeComposing(event)) return false
  return true
}

/** True when Escape is available to dismiss the current overlay or menu.
 * Input-owned and IME composition keydowns remain with their owner. */
export function isDismissEscape(event: KeyboardEvent): boolean {
  return event.key === 'Escape' && !event.defaultPrevented && !isImeComposing(event)
}

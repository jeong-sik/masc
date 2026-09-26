/**
 * The Enter (or Escape) that confirms or cancels an IME composition belongs
 * to the IME. Safari reports that keydown with isComposing false and the
 * legacy keyCode 229, so both are read.
 */
export function isImeComposing(event: KeyboardEvent): boolean {
  return event.isComposing || event.keyCode === 229
}

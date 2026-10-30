// Approval text must show characters that can hide or reorder the executed
// input. Use the same projection for full inputs and every preview consumer.
const INVISIBLE_OR_REORDERING =
  /[\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]|[\u{E0000}-\u{E007F}]/gu

export function approvalInputText(text: string): string {
  return text.replace(INVISIBLE_OR_REORDERING, ch => {
    const code = ch.codePointAt(0) ?? 0
    return `\u27E6U+${code.toString(16).toUpperCase().padStart(4, '0')}\u27E7`
  })
}

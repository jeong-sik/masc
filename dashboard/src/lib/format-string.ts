// Unified string formatting utilities.

/** Capitalize first character. Returns empty string unchanged. */
export function capitalize(text: string): string {
  if (!text) return text
  return text.charAt(0).toUpperCase() + text.slice(1)
}

// Unified text truncation utilities.

/** Truncate text, collapsing whitespace. Returns null for empty input. Uses ellipsis. */
export function trimText(value: string | null | undefined, max = 120): string | null {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return null
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

/** Simple truncate — returns original if short enough, otherwise slices with ellipsis. */
export function truncate(value: string, limit = 260): string {
  if (value.length <= limit) return value
  return `${value.slice(0, limit - 1)}…`
}

// Highlight-on-match utility.
//
// Splits `text` into alternating raw string / <mark>-wrapped Preact
// fragments on case-insensitive substring match of `needle`. Designed to
// be dropped into an htm template without changing surrounding DOM:
//
//     ${highlightMatch(row.summary, query.value)}
//
// When `needle` is empty / whitespace-only the function returns `[text]`
// unchanged so callers can render unconditionally. Original casing of the
// matched substring is preserved (the lowercased needle is only used to
// locate indices).

import { html } from 'htm/preact'

/**
 * Split `text` into a sequence of Preact-renderable parts, wrapping each
 * case-insensitive occurrence of `needle` in a `<mark>` tag. Adjacent /
 * overlapping matches are merged into a single `<mark>` span.
 *
 * - Empty or whitespace-only `needle` → `[text]` (single raw string).
 * - Empty `text` → `['']` (single empty raw string, preserves stable shape).
 * - No match → `[text]` unchanged.
 * - Leading / trailing match produces no empty prefix or suffix parts.
 */
export function highlightMatch(text: string, needle: string): readonly unknown[] {
  const trimmed = needle.trim()
  if (trimmed === '') return [text]
  if (text === '') return ['']

  const lowerText = text.toLowerCase()
  const lowerNeedle = trimmed.toLowerCase()
  const needleLen = lowerNeedle.length

  // 1st pass: collect raw match positions (possibly overlapping if the
  // needle itself overlaps its own shifts, e.g. needle "aa" in "aaaa").
  const raw: Array<{ start: number; end: number }> = []
  let from = 0
  while (from <= lowerText.length - needleLen) {
    const idx = lowerText.indexOf(lowerNeedle, from)
    if (idx === -1) break
    raw.push({ start: idx, end: idx + needleLen })
    from = idx + 1 // advance by 1 so overlapping matches are captured
  }

  if (raw.length === 0) return [text]

  // 2nd pass: merge overlapping / adjacent ranges into single spans.
  const merged: Array<{ start: number; end: number }> = []
  for (const r of raw) {
    const last = merged[merged.length - 1]
    if (last && r.start <= last.end) {
      if (r.end > last.end) last.end = r.end
    } else {
      merged.push({ start: r.start, end: r.end })
    }
  }

  // 3rd pass: emit alternating raw / <mark> parts, slicing the ORIGINAL
  // text to preserve casing. Skip zero-length prefix/suffix chunks.
  const parts: unknown[] = []
  let cursor = 0
  for (const { start, end } of merged) {
    if (start > cursor) parts.push(text.slice(cursor, start))
    const matched = text.slice(start, end)
    parts.push(
      html`<mark class="bg-yellow-500/20 text-inherit rounded-sm px-0.5">${matched}</mark>`,
    )
    cursor = end
  }
  if (cursor < text.length) parts.push(text.slice(cursor))
  return parts
}

/**
 * Nullable-safe wrapper. `null` / `undefined` text renders as empty string.
 */
export function highlightSafe(
  text: string | null | undefined,
  needle: string,
): readonly unknown[] {
  return text ? highlightMatch(text, needle) : ['']
}

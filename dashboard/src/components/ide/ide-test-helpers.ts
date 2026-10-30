// Test-only helpers shared across IDE component test files.
//
// The router this dashboard ships writes route state into
// `window.location.hash` as `#/path?query`. IDE tests routinely assert
// the resulting query string by parsing it back into URLSearchParams.
// Two test files (`ide-conversation-rail.test.ts`, `ide-interject.test.ts`)
// shipped the same one-liner inline; centralise it here so that a future
// router change (e.g. moving the query off the hash) updates one spot.

/**
 * Parse the current `window.location.hash` query string into
 * `URLSearchParams`. Returns an empty params object when the hash has
 * no `?` segment or window is unavailable.
 */
export function routeHashParams(): URLSearchParams {
  return new URLSearchParams(window.location.hash.split('?')[1] ?? '')
}

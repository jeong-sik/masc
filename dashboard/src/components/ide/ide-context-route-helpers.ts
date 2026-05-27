// Display helpers for `IdeContextRouteLink` collections.
//
// Four IDE surfaces (`execute-output-drawer`, `overlay-keeper-trace`,
// `ide-branch-context-panel`, `ide-persistence-panel`) each shipped the
// same one-line label-joiner inline as `routeLinkLabels`. Centralised
// here so a future change (e.g. localising the comma separator,
// truncating long lists, or adding accessibility hints) updates one
// place rather than four.

import type { IdeContextRouteLink } from './ide-context-lens'

/**
 * Concatenate `routeLinks[].label` into a single comma-separated string
 * for display. Empty input returns the empty string.
 */
export function routeLinkLabels(routeLinks: ReadonlyArray<IdeContextRouteLink>): string {
  return routeLinks.map(link => link.label).join(', ')
}

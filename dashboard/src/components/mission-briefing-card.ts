import { html } from 'htm/preact'

// Shim for the legacy barrel import in mission-cards.ts. The real
// MissionBriefingCard component was removed in #8081 when the mission
// navigation cascade was purged. mission-cards.ts still re-exports the
// symbol, so dropping this file breaks the TypeScript typecheck on
// main (TS2307: Cannot find module './mission-briefing-card').
export function MissionBriefingCard() {
  return html`<div class="hidden" data-component="mission-briefing-card"></div>`
}

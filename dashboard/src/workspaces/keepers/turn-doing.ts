import { formatTurnActivityLabel } from './chat-blocks'
import { openWorkLead, openWorkLeadPhrase, type OpenWorkLead } from './turn-open-work'
import type { KeeperActiveTurnPreview } from './types'

// What a running turn is doing now, in one line: the open work the server
// lists, or the word the activity alone gives when the list says nothing.

export interface TurnDoing {
  readonly phrase: string
  /** When what the phrase names began, in unix seconds. `null` when the preview does not say. */
  readonly sinceUnix: number | null
}

// A failed attempt's list is of the attempt that failed, and a turn that
// still prepares has opened nothing yet: neither says what happens now. The
// TUI leaves the same two out (`fleet_store.ml` `open_work_of_preview`).
function listedOpenWork(preview: KeeperActiveTurnPreview): OpenWorkLead | null {
  switch (preview.activity) {
    case 'failed':
    case 'preparing':
      return null
    default:
      return openWorkLead(preview.open_activities ?? [])
  }
}

export function turnDoing(preview: KeeperActiveTurnPreview): TurnDoing {
  const open = listedOpenWork(preview)
  if (open !== null) return { phrase: openWorkLeadPhrase(open), sinceUnix: open.lead.since_unix }
  return { phrase: formatTurnActivityLabel(preview.activity).label, sinceUnix: null }
}

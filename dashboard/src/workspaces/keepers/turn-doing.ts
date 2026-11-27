import { formatTurnActivityLabel } from './chat-blocks'
import { preparationHaltedLabel, preparationPhaseLabel } from './turn-context'
import { openWorkLead, openWorkLeadPhrase, type OpenWorkLead } from './turn-open-work'
import type { KeeperActiveTurnPreview, KeeperTurnPreparation } from './types'

// What a running turn is doing now, in one line: the preparation step the
// server names, then the open work it lists, then the word the activity
// alone gives. The TUI reads a preview in the same order
// (`lib/masc_tui/store/chat_transcript.ml` `active_turn_detail_summary`).

export interface TurnDoing {
  readonly phrase: string
  /** When what the phrase names began, in unix seconds. `null` when the preview does not say. */
  readonly sinceUnix: number | null
  /** `bad` when the turn stopped short: an attempt failed, or a preparation step halted. */
  readonly tone: ReturnType<typeof formatTurnActivityLabel>['tone']
}

// A step that is done has no time: the server has seen nothing after it yet,
// and how long ago it ended is not how long it took.
function preparationDoing(preparation: KeeperTurnPreparation): TurnDoing {
  switch (preparation.state) {
    case 'active': {
      const preparing = formatTurnActivityLabel('preparing')
      return {
        phrase: `${preparing.label} · ${preparationPhaseLabel(preparation.phase)}`,
        sinceUnix: preparation.started_at_unix,
        tone: preparing.tone,
      }
    }
    case 'prepared':
      return { phrase: `${preparationPhaseLabel(preparation.phase)} 준비 완료`, sinceUnix: null, tone: 'info' }
    case 'rejected':
    case 'raised':
    case 'cancelled':
      return { phrase: preparationHaltedLabel(preparation), sinceUnix: null, tone: 'bad' }
  }
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
  if (preview.preparation !== null) return preparationDoing(preview.preparation)
  const activity = formatTurnActivityLabel(preview.activity)
  const open = listedOpenWork(preview)
  if (open !== null) return { phrase: openWorkLeadPhrase(open), sinceUnix: open.lead.since_unix, tone: activity.tone }
  return { phrase: activity.label, sinceUnix: null, tone: activity.tone }
}

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

// The open work the line speaks from. A preparation step in effect comes
// before the list. A failed attempt's list is of the attempt that failed, and
// a turn that still prepares has opened nothing yet: neither says what
// happens now. The TUI leaves the same two out (`fleet_store.ml`
// `open_work_of_preview`).
function listedOpenWork(preview: KeeperActiveTurnPreview): OpenWorkLead | null {
  if (preview.preparation !== null) return null
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

/**
 * The one line, for a place that lists the open work in rows below it: `null`
 * while the line speaks from that list, which the rows say themselves. What
 * no row names stays: a preparation step, a failed attempt, an activity with
 * nothing open.
 */
export function turnDoingBesideRows(preview: KeeperActiveTurnPreview): TurnDoing | null {
  return listedOpenWork(preview) === null ? turnDoing(preview) : null
}

/** A turn the turns read reports and no preview has described yet. */
export const TURN_RUNNING_PHRASE = '턴 실행 중'

/**
 * What a turn is doing, for a place too narrow for the sentence. An open tool
 * is its name, kept apart from how many more calls are open, so a layout can
 * cut the name and keep the count. Where the named call stands is left to the
 * sentence.
 */
export type TurnDoingBrief =
  | { readonly kind: 'words'; readonly words: string }
  | {
      readonly kind: 'tool'
      readonly name: string
      /** How many more calls are open behind the named one. */
      readonly otherCalls: number
    }

export function turnDoingBrief(preview: KeeperActiveTurnPreview | null): TurnDoingBrief {
  if (preview === null) return { kind: 'words', words: TURN_RUNNING_PHRASE }
  const open = listedOpenWork(preview)
  if (open === null || open.lead.kind !== 'tool') return { kind: 'words', words: turnDoing(preview).phrase }
  return { kind: 'tool', name: open.lead.name, otherCalls: open.otherCalls }
}

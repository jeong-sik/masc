import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { keeperTurnOutcomeSuppressesReply, normalizeKeeperConversationDetails } from './keeper-message'

// Backend -> frontend parity for Keeper_turn_outcome.
//
// sse-event-type-parity.test.ts guards the FE -> backend direction and says so:
// "The reverse (backend emits a type the FE never handles) ... tracked
// separately." This is that reverse direction for one vocabulary, and it was
// not hypothetical. keeper_turn_outcome.ml emits five labels;
// normalizeKeeperTurnOutcome listed four. The fifth,
// external_effect_completed, fell to `default: return null`, and null is
// documented there as "consumers treat as a visible reply" — the exact
// opposite of the backend's own projection, which maps
// External_effect_completed to Connector_no_visible_reply.
//
// vitest cwd = dashboard/, so the backend source is one level up. A wrong path
// throws ENOENT rather than passing vacuously.

const TURN_OUTCOME_ML = resolve(__dirname, '../../lib/keeper/keeper_turn_outcome.ml')

function backendLabels(): string[] {
  const source = readFileSync(TURN_OUTCOME_ML, 'utf8')
  const toLabel = source.match(/let to_label = function\n((?:\s*\|[^\n]*\n)+)/)
  const arms = toLabel?.[1]
  if (!arms) throw new Error(`could not find to_label in ${TURN_OUTCOME_ML}`)
  const labels = [...arms.matchAll(/->\s*"([^"]+)"/g)]
    .map(match => match[1])
    .filter((label): label is string => label !== undefined)
  if (labels.length === 0) throw new Error(`to_label in ${TURN_OUTCOME_ML} yielded no labels`)
  return labels
}

function decode(turnOutcome: string) {
  const details = normalizeKeeperConversationDetails({ turn_outcome: turnOutcome })
  return details?.turnOutcome ?? null
}

describe('Keeper_turn_outcome parity', () => {
  it('decodes every label the backend can emit', () => {
    const undecoded = backendLabels().filter(label => decode(label) === null)
    expect(undecoded).toEqual([])
  })

  it('reads the labels from the backend source, not a copy', () => {
    // Guards the guard: a regex that stops matching would make the assertion
    // above vacuously true over an empty list.
    expect(backendLabels().length).toBeGreaterThanOrEqual(5)
    expect(backendLabels()).toContain('external_effect_completed')
  })

  // The backend maps Continuation_checkpoint, External_effect_completed,
  // External_effect_pending and No_visible_reply to Connector_no_visible_reply
  // (keeper_chat_blocks.ml connector_projection); only Visible_reply can carry
  // one. The FE suppression predicate has to agree or a turn with no reply
  // renders as though it had one.
  it('suppresses the reply for every non-visible outcome', () => {
    for (const label of backendLabels()) {
      const decoded = decode(label)
      expect(decoded).not.toBeNull()
      expect(keeperTurnOutcomeSuppressesReply(decoded)).toBe(label !== 'visible_reply')
    }
  })

  it('still fails open for a label no backend version emits', () => {
    // The #20870 policy: an unknown label decodes to null and consumers show
    // the reply rather than dropping it. Adding known labels must not change
    // that for genuinely unknown ones.
    expect(decode('outcome_from_a_future_server')).toBeNull()
  })
})

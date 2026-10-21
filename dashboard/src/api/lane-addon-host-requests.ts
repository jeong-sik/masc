import { Either, Schema } from 'effect'

const text = Schema.NonEmptyString
const wait = Schema.Union(
  Schema.Struct({ reason: Schema.Literal('lane_unconfigured', 'lane_off', 'no_admitted_slots',
    'attempt_in_progress', 'awaiting_operator') }),
  Schema.Struct({ reason: Schema.Literal('lane_registry_unavailable', 'provider_unavailable',
    'provider_auth_refused', 'provider_configuration_refused', 'source_unavailable'), detail: Schema.String }),
)
const issue = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('listing_failed', 'listing_refused'), detail: Schema.String }),
  Schema.Struct({ kind: Schema.Literal('relisted_delivered_request'), request_id: text }),
  Schema.Struct({ kind: Schema.Literal('result_delivery_failed', 'exact_record_failed', 'ask_record_failed'),
    request_id: text, detail: Schema.String }),
  Schema.Struct({ kind: Schema.Literal('no_exact_runner') }),
)
const cycle = Schema.Struct({
  cycles: Schema.Int.pipe(Schema.nonNegative()),
  waiting: Schema.Array(Schema.Struct({ request_id: text, reason: wait })),
  issue: Schema.NullOr(issue),
})
export type LaneAddonHostRequestCycle = Schema.Schema.Type<typeof cycle>
export type LaneAddonHostRequestObservation =
  | { readonly kind: 'observed'; readonly cycle: LaneAddonHostRequestCycle }
  | { readonly kind: 'unreadable'; readonly detail: string }

/** Matches the host's host_status_json and not_final_to_json contracts. A bad
 * diagnostic must not erase the original worker, observations or action target. */
export function parseLaneAddonHostRequests(value: unknown): LaneAddonHostRequestObservation {
  const decoded = Schema.decodeUnknownEither(cycle, { onExcessProperty: 'error' })(value)
  return Either.isRight(decoded)
    ? { kind: 'observed', cycle: decoded.right }
    : { kind: 'unreadable', detail: decoded.left.message }
}

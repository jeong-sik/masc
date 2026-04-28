(** Meta_cognition_interpret — salience interpretation engine.

    Takes a parsed {!Meta_cognition_types.summary_input} and determines
    the primary salience (stable / contested / tension / desire /
    stagnant) with supporting evidence and a Korean-language reason
    string suitable for the dashboard "메타 인지" surface card.

    {!Meta_cognition} re-exports the public surface via
    [include Meta_cognition_interpret], so callers reach
    {!interpret} / {!interpretation_to_json} / {!summary_signature}
    either through this module directly or through the
    {!Meta_cognition} namespace.  All internal helpers
    ([operator_actionability], [evidence_refs_of_belief],
    [evidence_refs_of_salience], [reason_of_salience],
    [target_id_of_salience], [salience_list_to_json]) stay
    private — they are stable contract-internal pieces but exposing
    them would invite duplicate-rendering paths that drift from the
    canonical {!interpret} + {!interpretation_to_json} pair.

    @since God file decomposition — extracted from
    meta_cognition.ml *)

val interpret :
  Meta_cognition_types.summary_input ->
  Meta_cognition_types.interpretation
(** [interpret summary] computes the salience interpretation.

    {2 Salience priority order (pinned)}

    The signal cascade evaluates four predicates in order, returning
    the {b first} matching salience as primary; the rest become
    secondary.  When none match, {!Meta_cognition_types.Stable} is
    returned.

    1. {!Meta_cognition_types.Contested_belief} — [contested_belief_count > 0]
    2. {!Meta_cognition_types.Operator_tension} — [top_tension] has
       [needs_operator = true] {b OR} [severity = Some "high"]
    3. {!Meta_cognition_types.Operator_desire} — [top_desire]
       [actionability] is one of:
       [operator] / [operator_or_platform] /
       [operator_or_scheduler] / [room_or_operator]
    4. {!Meta_cognition_types.Stagnant_room} — [stagnation_score >= 0.65]

    {2 Threshold pinning}

    The 0.65 stagnation cutoff and the 4-string operator-actionability
    set are the dashboard's "alert threshold" contract.  A future
    "let's tune the threshold" change must touch this contract
    explicitly so dashboard CSS / runbook explanations stay in sync.

    {2 Reason string locale}

    {!Meta_cognition_types.interpretation.reason} is rendered in
    Korean (the operator-language convention for masc-mcp dashboard
    surface cards).  Adding a non-Korean locale requires extending
    the contract, not silently switching at this layer. *)

val interpretation_to_json :
  Meta_cognition_types.interpretation -> Yojson.Safe.t
(** [interpretation_to_json i] returns a JSON object with fields:

    - [primary_salience] : `String` (snake_case salience tag)
    - [secondary_saliences] : `List` of `String` (same tags)
    - [reason] : `String` (Korean-language line)
    - [target_id] : `String | `Null` (entity id when the primary
      salience identifies one)
    - [evidence_refs] : `List` of `String` (entity refs supporting
      the primary salience)

    The field names are the dashboard / API contract — do not
    rename without coordinating with the meta-cognition surface card
    consumers. *)

val summary_signature : Meta_cognition_types.summary_input -> string
(** [summary_signature summary] returns a deterministic MD5 hex
    digest of the summary's salience-driving fields, used by
    {!Meta_cognition_digest} for board-post deduplication.

    {2 Signature inputs (8 fields, [|]-joined before digest)}

    1. [dominant_belief.id] (or ["none"])
    2. [dominant_belief.status] (or ["none"])
    3. [top_tension.id] (or ["none"])
    4. [top_tension.severity] (or ["none"])
    5. [top_desire.id] (or ["none"])
    6. [top_desire.actionability] (or ["none"])
    7. [contested_belief_count] (string-encoded int)
    8. [stagnation_score * 10] floored to int (the "stagnation
       bucket" — collapses 0.61 / 0.64 / 0.69 into the same
       [6] bucket so trivial drift does not invalidate cached
       digests)

    The bucket-based collapse on [stagnation_score] is the only
    lossy field — every other field round-trips losslessly into
    the digest.  A future "let's use a finer bucket" change must
    coordinate with the digest cache: existing cached digests
    become invalid for the same room state and the dashboard
    will see one round of digest churn. *)

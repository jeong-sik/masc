(** Keeper_memory_os_consolidation — per-keeper LLM consolidation pass.

    The "summarize" half of RFC-0247. An LLM reads a keeper's whole fact set and
    judges which claims to merge into one consolidated claim and which to forget.
    The DECISION is the LLM's; the STRUCTURE — parsing the plan and applying it
    while preserving provenance — is deterministic and lives here. No score.

    Apply is conservative (R7): the LLM references facts only by index, so it
    cannot fabricate a survivor; an unreferenced fact is kept unchanged; a group
    needs >= 2 in-range members to merge; out-of-range/duplicate indices skip.

    [valid_until] is no longer a precondition: it is derived from write-time
    policy, so exact timestamp equality is not a semantic grouping contract. It
    is combined by a meet at apply time instead. [claim_kind] is no longer a
    precondition either — the judge states the merged row's tag, and the group is
    refused only when it states nothing while the members disagree. Every
    remaining refusal is one the judge can clear by restating its plan. *)

open Keeper_memory_os_types

val wire_field_member_indices : string
val wire_field_consolidated_claim : string
val wire_field_category : string
val wire_field_groups : string
val wire_field_drop_indices : string
val wire_field_claim_kind : string

(** [claim_kind] is the origin tag the judge assigns to the row it authors, like
    [category] — a merged row is a new claim, not a union needing lossless
    representation. [None] is "not stated": {!apply_plan} then inherits the
    members' one distinct tag, or refuses the group when they disagree rather
    than writing [None], which would mean "producer emitted no tag" and is
    omitted entirely at the read boundary. *)
type merge_group =
  { member_indices : int list
  ; consolidated_claim : string
  ; category : category
  ; claim_kind : claim_kind option
  }

type consolidation_plan =
  { groups : merge_group list
  ; drop_indices : int list
  }

val empty_plan : consolidation_plan

type output_rejection_reason =
  | Non_json
  | Non_object_json

val output_rejection_reason_to_string : output_rejection_reason -> string

(** The numbered fact list the consolidation prompt sees: one 0-based line per
    fact, ["i: [category] (kind=k until=t) claim"], where [kind=untagged] renders
    an absent tag and [until=] is omitted when there is no expiry. The
    annotations are not decoration: [kind=] is the judge's only input for
    choosing a group's own [claim_kind]. The index is the LLM's only handle on an
    existing fact, matching [apply_plan]'s reading. *)
val render_numbered_facts : fact list -> string

(** Parse the LLM's consolidation output. Garbled groups degrade individually
    (dropped with warning counts, not fatal); a wholly invalid object yields
    [empty_plan]. *)
val plan_of_json : Yojson.Safe.t -> consolidation_plan

(** Parse the provider output as an exact JSON object, preserving the structured
    rejection reason for runtime outcome classification. *)
val plan_result_of_string :
  string -> (consolidation_plan, output_rejection_reason) result

(** [plan_of_string raw] is [None] only when [raw] is not an exact JSON object.
    Rejections emit a warning with a bounded reason label and byte count so
    model-provider contract regressions are observable without logging raw
    provider text. A parseable-but-empty/garbled object returns [Some
    empty_plan]-equivalent. *)
val plan_of_string : string -> consolidation_plan option

(** Typed apply outcome breakdown, so "the judge proposed no merges" does not
    collapse into the same silent before = after as "the plan was rejected".
    [rejected_kind_mismatch] is the gate disagreement worth alerting on;
    [rejected_too_few_members] is expected behavior, since first-group-wins
    legitimately shrinks a later overlapping group below two free members on
    ordinary contested-duplicate plans. *)
type apply_stats =
  { merged_groups : int
  ; rejected_kind_mismatch : int
  ; rejected_too_few_members : int
  ; dropped : int
  }

(** Apply a plan to a keeper's facts, returning the new fact list and the typed
    apply statistics. Each group of >= 2 in-range, not-yet-consumed members
    collapses into one consolidated fact (claim/category from the plan;
    provenance — earliest source/first_seen, union of [observed_by], and
    [last_verified_at] = the members' latest — reconstructed from the members).
    Merging is not a verification, so [now] does not advance that anchor.

    The merged row's [valid_until] is the meet of its members': [None] is "no
    expiry", the lattice top and identity, and two expiries take the earlier, so
    a consolidated claim never outlives the shortest-lived claim it absorbed.
    That invariant holds unconditionally because expired rows never reach here —
    {!Keeper_memory_os_consolidation_runtime} partitions them out before the
    judge sees the store, so no group can mix a dead row with a live one.
    The merged row's [claim_kind] is the judge's stated tag, taken as given like
    [category]; parsing has already bounded it to the closed variants, and no
    code branches on it, so no admissibility rule narrows it further. When the
    judge states nothing, one distinct member tag is inherited and disagreement
    is rejected and counted — the code will not invent a tag, and [None] is not
    available as a stand-in because it means "producer emitted no tag".
    [render_numbered_facts] shows the judge each member's tag so that refusal is
    never hit blind. Explicitly dropped indices are removed; every other fact
    survives unchanged. *)
val apply_plan
  :  now:float
  -> facts:fact list
  -> consolidation_plan
  -> fact list * apply_stats

(** Keeper_memory_os_consolidation — per-keeper LLM consolidation pass.

    The "summarize" half of RFC-0247. An LLM reads a keeper's whole fact set and
    judges which claims to merge into one consolidated claim and which to forget.
    The DECISION is the LLM's; the STRUCTURE — parsing the plan and applying it
    while preserving provenance — is deterministic and lives here. No score.

    Apply is conservative (R7): the LLM references facts only by index, so it
    cannot fabricate a survivor; an unreferenced fact is kept unchanged; a group
    needs >= 2 in-range members to merge; out-of-range/duplicate indices skip. *)

open Keeper_memory_os_types

val wire_field_member_indices : string
val wire_field_consolidated_claim : string
val wire_field_category : string
val wire_field_groups : string
val wire_field_drop_indices : string

type merge_group =
  { member_indices : int list
  ; consolidated_claim : string
  ; category : category
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
    fact, ["i: [category] claim"]. The index is the LLM's only handle on an
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

(** Apply a plan to a keeper's facts, returning the new fact list. Each group of
    >= 2 in-range, not-yet-consumed members collapses into one consolidated fact
    (claim/category from the plan; provenance — earliest source/first_seen, union
    of [observed_by], [last_verified_at] = [now] — reconstructed from the
    members). A merge whose members disagree on [claim_kind] or exact
    [valid_until] is rejected so metadata is not collapsed by a heuristic.
    Explicitly dropped indices are removed; every other fact survives unchanged. *)
val apply_plan : now:float -> facts:fact list -> consolidation_plan -> fact list

(** Closed structured-output boundary for LLM decisions over eligible Keeper
    history. Wire field names and action tokens remain private to this codec. *)

module History = Keeper_compaction_eligible_history

type t

type decision_issue =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Invalid_unit_index
  | Invalid_action
  | Invalid_summary
  | Missing_summary
  | Unexpected_summary
  | Empty_summary
  | Unknown_unit of int

type decode_error =
  | Expected_plan_object
  | Unknown_plan_field of string
  | Duplicate_plan_field of string
  | Missing_plan_field of string
  | Decisions_not_array
  | Invalid_decision of
      { position : int
      ; issue : decision_issue
      }
  | Invalid_binding of History.apply_error

val input_json : History.t -> Yojson.Safe.t
(** Exact eligible units presented to the LLM. Protected history is absent. *)

val output_schema : Yojson.Safe.t
(** Closed per-unit [keep]/[drop]/[summarize] response schema. *)

val decode :
  source:History.t -> Yojson.Safe.t -> (t, decode_error) result
(** Decode and bind exactly one decision to every eligible unit. Keep-all and
    drop-all remain valid semantic choices; this boundary adds no policy. *)

val apply :
  source:History.t ->
  t ->
  (History.outcome, History.apply_error) result

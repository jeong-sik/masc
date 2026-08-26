(** Turn-frozen authority for durable Skill activation recording. *)

type t

type error =
  | Turn_scope_mismatch
  | Task_scope_missing of Skill_reference.t
  | Composition_reference_missing of { tool_name : string }
  | Activation_rejected of Keeper_skill_activation_ledger.decode_error
  | Store_failed of Keeper_skill_activation_ledger.store_error

val make :
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  task_id:Keeper_id.Task_id.t option ->
  task_references:Skill_reference.t list ->
  (t, error) result
(** Capture the immutable facts used by every Skill call in one turn. *)

val record_instruction :
  config:Workspace.config ->
  t ->
  Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result

val record_composition :
  config:Workspace.config ->
  t ->
  tool_name:string ->
  Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result

val error_code : error -> string
val error_to_string : error -> string
val error_to_yojson : error -> Yojson.Safe.t

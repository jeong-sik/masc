(** Exact current-schema durable intent for one runtime/metadata transaction. *)

type operation =
  | Create
  | Update

type intent =
  { transaction_id : string
  ; owner_id : string
  ; keeper_name : string
  ; operation : operation
  ; previous_runtime : string option
  ; candidate_runtime : string option
  ; previous_meta : Keeper_meta_contract.keeper_meta option
  ; candidate_meta : Keeper_meta_contract.keeper_meta
  ; shutdown_supersession : Keeper_shutdown_supersession.t option
  }

type tombstone =
  { transaction_id : string
  ; keeper_name : string
  }

type row =
  | Active of intent
  | Cleared of tombstone

type error =
  | Authority_failure of string
  | Invalid_current of string
  | Authority_conflict of string

val error_to_string : error -> string
val journal_dir : Workspace.config -> string
val journal_leaf : string -> string
val row_evidence : row -> Keeper_lifecycle_admission_durable_types.evidence

val make_intent :
  operation:operation ->
  keeper_name:string ->
  previous_runtime:string option ->
  candidate_runtime:string option ->
  previous_meta:Keeper_meta_contract.keeper_meta option ->
  candidate_meta:Keeper_meta_contract.keeper_meta ->
  shutdown_supersession:Keeper_shutdown_supersession.t option ->
  (intent, error) result

val reserve : Workspace.config -> intent -> (unit, error) result
val clear : Workspace.config -> intent -> (unit, error) result
val read_current : Workspace.config -> string -> (row option, error) result
val read_leaf : Workspace.config -> string -> (row option, error) result

val admission_decision :
  Workspace.config ->
  string ->
  Keeper_lifecycle_admission_durable_types.decision

val is_journal_leaf : string -> bool

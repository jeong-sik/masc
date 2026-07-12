type command_family =
  | Read
  | Search
  | List
  | Build
  | Test
  | Git_read
  | Git_write
  | Package_install
  | Network_read
  | Clone
  | Unknown

type reversibility =
  | Read_only
  | Reversible
  | Irreversible

type risk =
  | Low
  | Medium
  | High

type semantic_status =
  | Ok
  | No_match
  | Partial
  | Blocked
  | Timeout
  | Runtime_error

type retryability =
  | None_
  | Self_correct
  | Operator_required

type artifact_policy =
  | Inline_only
  | Persist_if_large

type classification = {
  family : command_family;
  reversibility : reversibility;
  risk : risk;
  risk_class : Masc_exec.Shell_ir_risk.risk_class;
}

type artifact_storage =
  | Filesystem

type artifact_ref = {
  path : string;
  bytes : int;
  storage : artifact_storage;
}

type executed_result = {
  command : string;
  process_status : Unix.process_status;
  output : string;
  semantic_status : semantic_status;
  classification : classification;
  summary : string;
  retryability : retryability;
  artifact_refs : artifact_ref list;
  recovery_hint : string option;
}

type diagnosis = {
  rule_id : string;
  explanation : string;
  rewrite : string option;
  tool_suggestion : string option;
}

type blocked_result = {
  command : string;
  error : string;
  reason : string;
  hint : string;
  alternatives : string list;
  classification : classification;
  retryability : retryability;
  summary : string;
  diagnosis : diagnosis option;
}

type outcome =
  | Executed of executed_result
  | Blocked_result of blocked_result

type project_kind =
  | OCaml_dune
  | Node_js
  | Python
  | Rust_cargo
  | Go_module
  | Unknown_project

type exec_env_snapshot = {
  cwd : string;
  git_repo : bool;
  git_branch : string option;
  project_kind : project_kind;
  project_name : string option;
}

val snapshot_env : cwd:string -> exec_env_snapshot

val classify_command_of_ir : Masc_exec.Shell_ir.t -> classification
(** IR-based classification. Direct consumers of parsed Shell IR
    should use this. *)

val classification_to_json : classification -> Yojson.Safe.t

val string_of_semantic_status : semantic_status -> string

val failure_class_of_semantic_status :
  semantic_status ->
  Tool_result.tool_failure_class option
(** Declared projection onto the shared tool-failure taxonomy, emitted on the
    wire as the ["failure_class"] field of every failed outcome JSON. [None]
    exactly when {!semantic_status_is_success} holds. Timeout declares
    [Transient_error] (retryable), Blocked declares [Policy_rejection];
    Partial/Runtime_error declare [Runtime_failure]. *)

val semantic_status_is_success : semantic_status -> bool

val semantic_status_of_process :
  cmd:string ->
  output:string ->
  Unix.process_status ->
  semantic_status

val build_process_outcome :
  classification:classification ->
  artifact_policy:artifact_policy ->
  base_path:string ->
  keeper_name:string ->
  cmd:string ->
  status:Unix.process_status ->
  output:string ->
  outcome

val process_result_json :
  ?artifact_policy:artifact_policy ->
  ?classification:classification ->
  base_path:string ->
  keeper_name:string ->
  cmd:string ->
  ?extra:(string * Yojson.Safe.t) list ->
  ?env_snapshot:exec_env_snapshot option ->
  status:Unix.process_status ->
  output:string ->
  unit ->
  Yojson.Safe.t

val blocked_result_json :
  ?classification:classification ->
  cmd:string ->
  error:string ->
  reason:string ->
  ?hint:string ->
  ?alternatives:string list ->
  ?retryability:retryability ->
  ?diag:diagnosis option ->
  ?extra:(string * Yojson.Safe.t) list ->
  ?env_snapshot:exec_env_snapshot option ->
  unit ->
  Yojson.Safe.t

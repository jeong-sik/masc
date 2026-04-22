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
  write_intent : bool;
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

type blocked_result = {
  command : string;
  error : string;
  reason : string;
  hint : string;
  alternatives : string list;
  classification : classification;
  retryability : retryability;
  summary : string;
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

val string_of_project_kind : project_kind -> string
val detect_project_kind : string -> project_kind
val snapshot_env : cwd:string -> exec_env_snapshot
val env_snapshot_to_json : exec_env_snapshot -> Yojson.Safe.t

val classify_command : cmd:string -> classification
val classification_to_json : classification -> Yojson.Safe.t

val string_of_semantic_status : semantic_status -> string
val semantic_status_of_process :
  cmd:string ->
  output:string ->
  Unix.process_status ->
  semantic_status

val string_of_retryability : retryability -> string

val build_process_outcome :
  artifact_policy:artifact_policy ->
  base_path:string ->
  keeper_name:string ->
  cmd:string ->
  status:Unix.process_status ->
  output:string ->
  outcome

val build_blocked_outcome :
  cmd:string ->
  error:string ->
  reason:string ->
  ?hint:string ->
  ?alternatives:string list ->
  ?retryability:retryability ->
  unit ->
  outcome

val outcome_to_json :
  ?extra:(string * Yojson.Safe.t) list ->
  ?env_snapshot:exec_env_snapshot option ->
  outcome ->
  Yojson.Safe.t

val process_result_json :
  ?artifact_policy:artifact_policy ->
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
  cmd:string ->
  error:string ->
  reason:string ->
  ?hint:string ->
  ?alternatives:string list ->
  ?retryability:retryability ->
  ?extra:(string * Yojson.Safe.t) list ->
  ?env_snapshot:exec_env_snapshot option ->
  unit ->
  Yojson.Safe.t

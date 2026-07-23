(** Strict operator command for recovering one owned Task to [Todo].

    The command is an explicit compare-and-set over the observed backlog
    version and persisted assignee. It performs no liveness or elapsed-time
    inference. *)

val tool_command_schema : string
val result_schema : string

type t =
  { task_id : string
  ; expected_assignee : string
  ; expected_version : int
  ; reason : string
  }

type input_error =
  | Object_required of string
  | Duplicate_fields of string list
  | Unsupported_fields of string list
  | Missing_fields of string list
  | Invalid_field of
      { field : string
      ; expectation : string
      }
  | Unsupported_schema of string

val input_error_to_string : input_error -> string
val input_error_to_json : input_error -> Yojson.Safe.t
val parse_tool_command : Yojson.Safe.t -> (t, input_error) result

val execute :
  Workspace.config ->
  actor:string ->
  t ->
  Workspace.operator_task_recovery_result Masc_domain.masc_result

val audit :
  Workspace.config ->
  actor:string ->
  t ->
  outcome:Audit_log.outcome ->
  (unit, string) result

val audit_json : (unit, string) result -> Yojson.Safe.t

val success_json :
  audit:Yojson.Safe.t ->
  t ->
  Workspace.operator_task_recovery_result ->
  Yojson.Safe.t

val mutation_error_json :
  audit:Yojson.Safe.t -> Masc_domain.masc_error -> Yojson.Safe.t

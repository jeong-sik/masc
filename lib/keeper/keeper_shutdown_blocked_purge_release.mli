(** Authenticated operator command for releasing one exact blocked dashboard
    purge. The HTTP adapter owns authentication; this module owns strict input,
    store CAS, durable release audit, and admission-fence release. *)

val command_schema : string
val result_schema : string

type command =
  { keeper_id : string
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  ; expected_revision : int
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

type error =
  | Store_release_failed of Keeper_shutdown_store.error
  | Successor_lookup_failed of Keeper_shutdown_store.error
  | Admission_reserved_by_other of Keeper_shutdown_types.Operation_id.t
  | Admission_release_failed of string

type released =
  { operation : Keeper_shutdown_types.t
  ; already_released : bool
  }

val input_error_to_string : input_error -> string
val input_error_to_json : input_error -> Yojson.Safe.t
val parse_command : Yojson.Safe.t -> (command, input_error) result
val error_to_string : error -> string

val execute :
  config:Workspace.config ->
  actor:string ->
  command ->
  (released, error) result

val audit :
  Workspace.config ->
  actor:string ->
  command ->
  outcome:Audit_log.outcome ->
  (unit, string) result

val success_json :
  audit:Yojson.Safe.t -> command -> released -> Yojson.Safe.t

val error_json : audit:Yojson.Safe.t -> error -> Yojson.Safe.t

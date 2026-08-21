(** Authenticated operator command for reissuing one exact blocked dashboard
    purge without opening admission. The HTTP adapter owns authentication;
    this module owns strict input, paused recovery materialization, store CAS,
    durable intent/audit, and synchronous finalization. *)

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
  | Operation_load_failed of Keeper_shutdown_store.error
  | Profile_materialization_failed of string
  | Metadata_materialization_failed of string
  | Store_reissue_failed of Keeper_shutdown_store.error
  | Finalization_failed of Keeper_shutdown_finalize.error
  | Injected_after_reissue of string

type released =
  { operation : Keeper_shutdown_types.t
  ; already_reissued : bool
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

val reissue_same_command_json : actor:string -> command -> Yojson.Safe.t
(** Exact operator action returned when the immutable audit append fails after
    the operation intent is already durable. This is not generic retry
    authority: callers must resubmit the same actor, operation identity,
    reason, and expected revision. *)

val error_json : audit:Yojson.Safe.t -> error -> Yojson.Safe.t

module For_testing : sig
  val fail_next_audit_write : string -> unit
  val fail_next_after_reissue : string -> unit
  val reset_audit_writer : unit -> unit
end

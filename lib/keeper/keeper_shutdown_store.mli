(** Atomic persistence for Keeper shutdown operations under the configured
    MASC base path. Reads and writes are serialized per operation path; an
    unrelated Keeper operation never holds the same lock across filesystem
    I/O. *)

type error =
  | Already_exists of string
  | Not_found of string
  | Io_error of string
  | Decode_error of string
  | Identity_mismatch of string
  | Revision_conflict of
      { expected : int
      ; actual : int
      }

type persist_blocked_result =
  | State_preserved of Keeper_shutdown_types.t
  | Blocked_persisted of Keeper_shutdown_types.t

val error_to_string : error -> string

val path :
  config:Workspace.config ->
  Keeper_shutdown_types.Operation_id.t ->
  string

val to_json : Keeper_shutdown_types.t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_shutdown_types.t, error) result

val persist_new :
  config:Workspace.config ->
  Keeper_shutdown_types.t ->
  (unit, error) result

val replace :
  config:Workspace.config ->
  expected_revision:int ->
  Keeper_shutdown_types.t ->
  (unit, error) result

(** Read the latest durable revision and persist [Blocked failure] while
    holding the operation's write lock. Existing [Finalized], [Blocked], and
    effect-unknown reconciliation states are preserved. *)
val persist_blocked_latest :
  config:Workspace.config ->
  identity:Keeper_shutdown_types.t ->
  failure:Keeper_shutdown_types.failure ->
  updated_at:string ->
  (persist_blocked_result, error) result

val load :
  config:Workspace.config ->
  Keeper_shutdown_types.Operation_id.t ->
  (Keeper_shutdown_types.t, error) result

val list_for_keeper :
  config:Workspace.config ->
  keeper_name:string ->
  (Keeper_shutdown_types.t list, error) result

val list_all :
  config:Workspace.config ->
  (Keeper_shutdown_types.t list, error) result

module For_testing : sig
  val with_operation_write_lock :
    config:Workspace.config ->
    Keeper_shutdown_types.Operation_id.t ->
    (unit -> 'a) ->
    'a
end

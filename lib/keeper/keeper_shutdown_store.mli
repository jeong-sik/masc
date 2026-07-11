(** Atomic persistence for Keeper shutdown operations under the configured
    MASC base path. Reads and writes are serialized per operation path, while
    a per-Keeper inventory lock keeps directory scans from observing atomic
    writer temporaries. Unrelated Keepers never share either lock across
    filesystem I/O. *)

type error =
  | Already_exists of string
  | Not_found of string
  | Io_error of string
  | Decode_error of string
  | Invalid_operation of Keeper_shutdown_types.invariant_error
  | Identity_mismatch of string
  | Revision_conflict of
      { expected : int
      ; actual : int
      }

type persist_blocked_result =
  | State_preserved of Keeper_shutdown_types.t
  | Blocked_persisted of Keeper_shutdown_types.t

type corrupt_record =
  { keeper_name : string
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  ; path : string
  ; error : error
  }

type inventory_entry =
  | Operation of Keeper_shutdown_types.t
  | Corrupt_record of corrupt_record

val error_to_string : error -> string

val path :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_shutdown_types.Operation_id.t ->
  (string, error) result

val to_json : Keeper_shutdown_types.t -> Yojson.Safe.t
(** Decode the current schema and deterministically upgrade schema 3 records
    emitted by the immediately preceding durable-shutdown implementation.
    Unknown versions remain explicit decode failures. *)
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
    effect-unknown reconciliation states are preserved. [now] is sampled only
    after the lock is acquired and the latest revision is loaded. *)
val persist_blocked_latest :
  config:Workspace.config ->
  identity:Keeper_shutdown_types.t ->
  failure:Keeper_shutdown_types.failure ->
  now:(unit -> string) ->
  (persist_blocked_result, error) result

val load :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_shutdown_types.Operation_id.t ->
  (Keeper_shutdown_types.t, error) result

val list_for_keeper :
  config:Workspace.config ->
  keeper_name:string ->
  (Keeper_shutdown_types.t list, error) result

(** Enumerate every owner-addressable operation independently. A corrupt
    payload remains associated with the Keeper and operation identities from
    its validated directory/file path, so boot can fence only that Keeper and
    continue recovering unrelated lanes. Store entries whose path does not
    encode both identities still fail the outer result because they cannot be
    isolated safely. *)
val scan_inventory :
  config:Workspace.config ->
  (inventory_entry list, error) result

module For_testing : sig
  val with_operation_write_lock :
    config:Workspace.config ->
    keeper_name:string ->
    Keeper_shutdown_types.Operation_id.t ->
    (unit -> 'a) ->
    ('a, error) result
end

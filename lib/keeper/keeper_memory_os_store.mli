(** Canonical, fresh-state-only Memory OS persistence.

    A store has one authority:

    {v HEAD -> immutable commit record -> immutable manifest
             -> immutable facts/episode objects v}

    Immutable object presence is never authority.  The implementation does not
    enumerate objects, read legacy Memory OS files, migrate old rows, or retry a
    stale HEAD publication. *)

module Sha256 : sig
  type t

  val equal : t -> t -> bool
  val to_string : t -> string
end

type artifact_kind =
  | Fact_object
  | Episode_object
  | Manifest_object
  | Commit_record_object

type immutable_ref

val immutable_ref_kind : immutable_ref -> artifact_kind
val immutable_ref_leaf : immutable_ref -> string
val immutable_ref_sha256 : immutable_ref -> Sha256.t
val immutable_ref_byte_count : immutable_ref -> int

type state =
  { facts : Keeper_memory_os_types.fact list
  ; episodes : Keeper_memory_os_types.episode list
  }

type 'a observation =
  { value : 'a
  ; settlement_error : Fs_compat.private_jsonl_transaction_error option
  }

type error =
  | Invalid_layout of string
  | Root_binding_changed
  | Invalid_domain_value of string
  | Conflicting_operation of
      { operation_id : string
      ; committed_payload_sha256 : Sha256.t
      ; requested_payload_sha256 : Sha256.t
      }
  | Store_open_failed of
      { path : string
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Immutable_create_failed of
      artifact_kind * Fs_compat.capability_write_error
  | Immutable_read_failed of
      immutable_ref * exn * Printexc.raw_backtrace
  | Immutable_digest_mismatch of immutable_ref
  | Invalid_store_json of
      { artifact : string
      ; detail : string
      }
  | Head_busy of { lock_path : string }
  | Head_conflict of
      { expected : string
      ; actual : string
      }
  | Head_publication_indeterminate of
      Fs_compat.private_jsonl_transaction_error
  | Head_transaction_failed of
      Fs_compat.private_jsonl_transaction_error

type t
type snapshot
type prepared_commit
type commit_receipt

type prepare_outcome =
  | Prepared of prepared_commit
  | Already_committed of commit_receipt

val with_open :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  root_path:string ->
  owner_id:string ->
  (t -> ('a, error) result) ->
  ('a, error) result

val load : t -> (snapshot observation, error) result

val snapshot_state : snapshot -> state
val snapshot_sequence : snapshot -> int64
val snapshot_head_commit : snapshot -> immutable_ref option

val prepare :
  t ->
  expected:snapshot ->
  operation_id:string ->
  state:state ->
  (prepare_outcome, error) result

val publish :
  t ->
  prepared_commit ->
  (commit_receipt observation, error) result

val committed_snapshot : commit_receipt -> snapshot
val commit_receipt_id : commit_receipt -> Sha256.t
val commit_receipt_operation_id : commit_receipt -> string
val commit_receipt_payload_sha256 : commit_receipt -> Sha256.t
val commit_receipt_sequence : commit_receipt -> int64

val error_to_string : error -> string

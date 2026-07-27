(** Durable lifecycle nonce allocation, independent of Keeper content state.

    Each keeper owns one current-schema HEAD row within its explicit base path.
    [owner_id] records which lifecycle receives an allocation, but is not an
    authority key: a later lifecycle for the same keeper must continue the
    keeper-wide sequence. The allocator has no scan, repair, migration,
    fallback, or ambient-state read surface. Allocations may contain gaps after
    a caller-side failure, but a successfully returned nonce is positive,
    monotonic, and exclusive for its keeper. *)

type corruption =
  | Invalid_current of string

type error =
  | Invalid_base_path of string
  | Invalid_keeper_id
  | Invalid_owner_id
  | Invalid_floor of int64
  | Authority_missing
  | Authority_identity_mismatch
  | Lifecycle_admission_mismatch
  | Shutdown_floor_invalid of string
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Entropy_source_failed of string
  | Corrupt_current of corruption
  | Head_read_failed of Fs_compat.Capability_head.failure
  | Head_read_settlement_failed of
      { cursor : Fs_compat.Capability_head.cursor
      ; row : string option
      ; observed_nonce : int64 option
      ; warnings : Fs_compat.Capability_head.settlement_warning list
      }
  | Head_write_failed of Fs_compat.Capability_head.failure
  | Contention_exhausted of
      { attempts : int
      ; last_failure : Fs_compat.Capability_head.failure
      }
  | Published_with_warnings of
      { nonce : int64
      ; evidence : Fs_compat.Capability_head.publication_evidence
      ; warnings : Fs_compat.Capability_head.settlement_warning list
      }
  | Published_with_failure of
      { nonce : int64
      ; failure : Fs_compat.Capability_head.failure
      }
  | Publication_indeterminate of
      { nonce : int64
      ; failure : Fs_compat.Capability_head.failure
      }
  | Nonce_exhausted
  | Runtime_nonce_out_of_range of int64

val error_to_string : error -> string

type identity
type create
type replace
type recover_exact
type 'kind witness

type settled_replace =
  | Settled_allocated of replace witness
  | Settled_recovered of recover_exact witness * error option

val identity :
  owner_id:string ->
  nonce:int64 ->
  (identity, error) result

val create :
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  Workspace.config ->
  keeper_id:string ->
  owner_id:string ->
  unit ->
  (create witness, error) result

val recover_exact :
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  Workspace.config ->
  keeper_id:string ->
  source:identity option ->
  target:identity ->
  unit ->
  (recover_exact witness, error) result
(** Recover only the exact published forward transition from [source] to
    [target]. This never authorizes an identity rewind. *)

val replace_settled :
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  Workspace.config ->
  keeper_id:string ->
  source:identity ->
  owner_id:string ->
  unit ->
  (settled_replace, error) result
(** Allocate the replacement or convert only the actual publication result
    from this call into an exact forward witness. No caller-provided
    publication claim and no reverse witness is accepted. *)

val witness_masc_root : _ witness -> string
val witness_keeper_id : _ witness -> string
val witness_source : _ witness -> identity option
val witness_target : _ witness -> identity
val identity_owner_id : identity -> string
val identity_nonce : identity -> int64

val runtime_int_of_nonce : int64 -> (int, error) result
(** Checked projection for the existing Keeper runtime metadata field. The
    durable authority remains int64 even while that field remains [int]. *)

module For_testing : sig
  type fault =
    | Publication_settlement_warning
    | Verified_publication_failure
    | Publication_indeterminate
    | Cancellation_after_publication

  val root_path : Workspace.config -> string
  val authority_leaf : keeper_id:string -> string
  val with_fd_backed_parent_opening : (unit -> 'a) -> 'a

  val with_fault : fault -> (unit -> 'a) -> 'a
end

(** Durable lifecycle nonce allocation, independent of Keeper content state.

    Each keeper owns one current-schema HEAD row within its explicit base path.
    [owner_id] records which lifecycle receives an allocation, but is not an
    authority key: a later lifecycle for the same keeper must continue the
    keeper-wide sequence. The allocator has no scan, repair, migration,
    fallback, or ambient-state read surface. Allocations may contain gaps after
    a caller-side failure, but a successfully returned nonce is positive,
    monotonic, and exclusive for its keeper. *)

type corruption =
  | Malformed_current of string
  | Unsupported_schema of string
  | Noncanonical_current
  | Keeper_binding_mismatch of
      { expected : string
      ; observed : string
      }
  | Invalid_current_nonce of string
  | Checksum_mismatch

type error =
  | Invalid_base_path of string
  | Invalid_keeper_id
  | Invalid_owner_id
  | Invalid_floor of int64
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

val next_for_base_path :
  base_path:string ->
  keeper_id:string ->
  owner_id:string ->
  ?floor:int64 ->
  unit ->
  (int64, error) result
(** Reserve the next nonce from the explicit workspace. [floor], when
    supplied, is an inclusive positive lower bound. The workspace's current
    [.masc] ownership root must already exist. *)

val runtime_int_of_nonce : int64 -> (int, error) result
(** Checked projection for the existing Keeper runtime metadata field. The
    durable authority remains int64 even while that field remains [int]. *)

module For_testing : sig
  val root_path_for_base_path : base_path:string -> string
  val authority_leaf : keeper_id:string -> string

  val with_read_settlement_warning :
    base_path:string ->
    keeper_id:string ->
    owner_id:string ->
    ?floor:int64 ->
    unit ->
    (int64, error) result

  val with_publication_settlement_warning :
    base_path:string ->
    keeper_id:string ->
    owner_id:string ->
    ?floor:int64 ->
    unit ->
    (int64, error) result

  val with_published_failure :
    base_path:string ->
    keeper_id:string ->
    owner_id:string ->
    ?floor:int64 ->
    unit ->
    (int64, error) result

  val with_forced_conflicts :
    base_path:string ->
    keeper_id:string ->
    owner_id:string ->
    ?floor:int64 ->
    unit ->
    (int64, error) result
end

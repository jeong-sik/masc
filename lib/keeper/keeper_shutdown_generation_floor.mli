(** Current-schema keeper-keyed shutdown generation floor.

    This is a single point-read HEAD per Keeper. It has no scan, historical
    decoder, migration, reconciliation, or missing-value default. *)

type t

type error =
  | Invalid_base_path of string
  | Invalid_keeper_id
  | Invalid_generation of int64
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Entropy_source_failed of string
  | Invalid_current of string
  | Head_read_failed of Fs_compat.Capability_head.failure
  | Head_read_settlement_failed of
      Fs_compat.Capability_head.settlement_warning list
  | Head_write_failed of Fs_compat.Capability_head.failure
  | Contention_exhausted of
      { attempts : int
      ; last_failure : Fs_compat.Capability_head.failure
      }
  | Published_with_warnings of
      { generation : int64
      ; warnings : Fs_compat.Capability_head.settlement_warning list
      }
  | Published_with_failure of
      { generation : int64
      ; failure : Fs_compat.Capability_head.failure
      }
  | Publication_indeterminate of
      { generation : int64
      ; failure : Fs_compat.Capability_head.failure
      }

val error_to_string : error -> string
val generation : t -> int64

val point_read :
  base_path:string ->
  keeper_id:string ->
  unit ->
  (t option, error) result

val record_exact :
  base_path:string ->
  keeper_id:string ->
  generation:int64 ->
  unit ->
  (t, error) result

module For_testing : sig
  val root_path_for_base_path : base_path:string -> string
  val authority_leaf : keeper_id:string -> string
  val with_fd_backed_parent_opening : (unit -> 'a) -> 'a
end

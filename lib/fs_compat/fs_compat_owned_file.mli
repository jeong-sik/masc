(** Path probes and owned-file reads of [Fs_compat]: [append_file],
    [file_exists], the path kind and owned directory chain types, and the
    reads of one owned regular file with their snapshot checks and failure
    types. [Fs_compat] includes this module. *)
open Fs_compat_internal

val append_file : string -> string -> unit

val file_exists : string -> bool

type path_kind =
  | Missing
  | Directory
  | Other

type exact_path_kind =
  | Exact_missing
  | Exact_kind of Unix.file_kind
  | Exact_unknown

val exact_path_kind : ?follow:bool -> string -> exact_path_kind

val path_kind : ?follow:bool -> string -> path_kind

type owned_directory_chain_rejection = Owned_directory_chain.rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type owned_directory_chain_observation = Owned_directory_chain.observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

val inspect_owned_directory_chain :
  ownership_root:string ->
  string ->
  (owned_directory_chain_observation, owned_directory_chain_rejection) result

val owned_directory_paths :
  ownership_root:string ->
  string -> (string list, owned_directory_chain_rejection) result

val owned_directory_chain_rejection_to_string :
  owned_directory_chain_rejection -> string

type owned_regular_file_read_operation =
  | Inspect_parent
  | Inspect_path
  | Open_path
  | Inspect_descriptor
  | Read_contents
  | Close_descriptor

type owned_regular_file_read_failure =
  | Ownership_boundary_rejected of
      { path : string
      ; rejection : owned_directory_chain_rejection
      }
  | Path_is_not_regular_file of
      { path : string
      ; kind : Unix.file_kind
      }
  | Filesystem_identity_changed of { path : string }
  | Owned_path_owner_mismatch of { path : string; expected_uid : int; actual_uid : int }
  | Owned_path_writable_by_others of { path : string; permissions : int }
  | Owned_file_operation_failed of
      { path : string
      ; operation : owned_regular_file_read_operation
      ; cause : exn
      }

type owned_regular_file_read_error =
  { failure : owned_regular_file_read_failure
  ; close_failure : exn option
  }

val file_kind_to_string : Unix.file_kind -> string

val owned_regular_file_read_error_to_string :
  owned_regular_file_read_error -> string

val same_file_identity : Unix.stats -> Unix.stats -> bool

val same_file_snapshot : Unix.stats -> Unix.stats -> bool

type owned_regular_file_snapshot =
  { device : int
  ; inode : int
  ; owner_uid : int
  ; permissions : int
  ; file_size : int
  ; modified_at : float
  ; changed_at : float
  }

val owned_regular_file_snapshot_of_stats :
  Unix.stats -> owned_regular_file_snapshot

val equal_owned_regular_file_snapshot :
  owned_regular_file_snapshot -> owned_regular_file_snapshot -> bool

val owned_file_error :
  owned_regular_file_read_failure ->
  ('a, owned_regular_file_read_error) result

val owned_file_operation_error :
  path:string ->
  owned_regular_file_read_operation ->
  exn -> ('a, owned_regular_file_read_error) result

val reraise_current : exn -> 'a

val read_exact_file_descriptor :
  path:string ->
  Unix.file_descr -> int -> (string, owned_regular_file_read_error) result

val load_owned_regular_file_blocking_with :
  ?owner_uid:int ->
  ?single_link:bool ->
  ?parent_lstat:(string -> Unix.stats) ->
  ownership_root:string ->
  read_descriptor:(path:string ->
                   Unix.file_descr ->
                   Unix.stats -> ('a, owned_regular_file_read_error) result) ->
  string -> ('a option, owned_regular_file_read_error) result

type owned_regular_file_contents =
  { content : string
  ; snapshot : owned_regular_file_snapshot
  }

val load_owned_regular_file_with_snapshot :
  ?owner_uid:int ->
  ?single_link:bool ->
  ownership_root:string ->
  string ->
  (owned_regular_file_contents option, owned_regular_file_read_error) result

module Owned_read_for_testing :
  sig
    val load_with_snapshot :
      ?single_link:bool ->
      parent_lstat:(string -> Unix.stats) ->
      owner_uid:int ->
      ownership_root:string ->
      string ->
      (owned_regular_file_contents option, owned_regular_file_read_error)
      result
  end

val load_owned_regular_file :
  ownership_root:string ->
  string -> (string option, owned_regular_file_read_error) result

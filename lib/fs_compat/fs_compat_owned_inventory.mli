(** Owned directory inventory of [Fs_compat]: [Retention_directory], the
    inventory root, the blocking read and listing of one owned directory, the
    prefix and range reads of owned regular files with their digest, and the
    access to one inventory entry. [Fs_compat] includes this module. *)
open Fs_compat_owned_file

module Retention_directory :
  sig
    type t = Fs_compat_internal.Retention_directory.t
    type io =
      Fs_compat_internal.Retention_directory.io = {
      run : 'a. (unit -> 'a) -> 'a;
    }
    val with_child : t -> string -> (t -> 'a) -> 'a option
    val names : t -> string list
    val fold_children : t -> init:'a -> f:('a -> string -> t -> 'a) -> 'a
    val descend : t -> string list -> (t -> int) -> int
    val remove_regular_file : ?older_than:float -> t -> string -> bool
    val unlink_entry : t -> string -> bool
    val remove_empty_child_checked : t -> string -> bool
    val remove_empty_child : t -> string -> unit
    val blocking_io : io
    val with_root : ?io:io -> string -> (t -> 'a) -> 'a option
  end

type owned_inventory_root =
  { inventory_path : string
  ; requested_path : string
  ; inventory_fd : Unix.file_descr
  ; inventory_stat : Unix.stats
  }

val owned_inventory_root_path : owned_inventory_root -> string

val owned_inventory_root_stat : owned_inventory_root -> Unix.stats

val with_owned_inventory_root :
  string ->
  (owned_inventory_root ->
   ('a, owned_regular_file_read_error) result) ->
  ('a, owned_regular_file_read_error) result

val read_owned_directory :
  ?owner_uid:int ->
  ?inventory_root:owned_inventory_root ->
  ?before_read:(string -> unit) ->
  ?after_read:(string -> unit) ->
  ownership_root:string ->
  string ->
  (string list,
   owned_regular_file_read_error)
  result

val read_owned_directory_if_present :
  owner_uid:int ->
  ?inventory_root:owned_inventory_root ->
  ?before_read:(string -> unit) ->
  ?after_read:(string -> unit) ->
  ownership_root:string ->
  string ->
  (string list option,
   owned_regular_file_read_error)
  result

val with_owned_directory_inventory_if_present :
  owner_uid:int ->
  inventory_root:owned_inventory_root ->
  sync_directory:(Unix.file_descr -> unit) ->
  string ->
  (owned_inventory_root -> string list -> 'a) ->
  ('a option, owned_regular_file_read_error)
  result

type owned_regular_file_prefix =
  { content : string
  ; file_size : int
  ; modified_at : float
  ; truncated : bool
  }

val load_owned_regular_file_prefix :
  ownership_root:string ->
  max_bytes:int ->
  string ->
  (owned_regular_file_prefix option,
   owned_regular_file_read_error)
  result

type owned_regular_file_range =
  { content : string
  ; snapshot : owned_regular_file_snapshot
  }

val load_owned_regular_file_range :
  ownership_root:string ->
  offset:int ->
  max_bytes:int ->
  string ->
  (owned_regular_file_range option,
   owned_regular_file_read_error)
  result

(* One descriptor serves both the window and the whole-file digest, so the
   bytes returned are the bytes hashed by construction (#38972): there is no
   second open whose file state could differ. The digest streams through a
   fixed buffer; only the window is copied out, so memory is bounded by
   [max_bytes] plus the buffer, never by the file size. *)
type owned_regular_file_range_digest =
  { content : string
  ; sha256 : string
  ; snapshot : owned_regular_file_snapshot
  }

val read_owned_range_digest_descriptor :
  offset:int ->
  max_bytes:int ->
  path:string ->
  Unix.file_descr ->
  Unix.stats ->
  (owned_regular_file_range_digest,
   owned_regular_file_read_error)
  result

val load_owned_regular_file_range_with_sha256_blocking :
  ownership_root:string ->
  offset:int ->
  max_bytes:int ->
  string ->
  (owned_regular_file_range_digest option,
   owned_regular_file_read_error)
  result

exception No_exactly_named_entry
(** The cause of the failure [with_owned_inventory_entry ~exact_names:true]
    returns when a held directory lists no name of the same bytes as the
    component asked for, or when a component before the last names a regular
    file. It is raised nowhere else. *)

val with_owned_inventory_entry :
  ?owner_uid:int ->
  ?single_link:bool ->
  ?exact_names:bool ->
  ?excluded_stat:Unix.stats ->
  owned_inventory_root ->
  string ->
  (Unix.file_descr ->
   Unix.stats ->
   Unix.file_descr ->
   ('a, owned_regular_file_read_error) result) ->
  ('a, owned_regular_file_read_error) result

type owned_relative_path = string list

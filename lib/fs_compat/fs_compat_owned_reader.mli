(** Owned readers of [Fs_compat]: the owned relative path helpers, the read
    of one regular file beneath an owned root, the [owned_reader] that keeps a
    descriptor open across reads, its sync stage, the sha256 of an owned
    regular file, and [read_dir]. [Fs_compat] includes this module. *)
open Fs_compat_owned_file
open Fs_compat_owned_inventory

val owned_relative_path : string list -> (owned_relative_path, string) result

val owned_relative_path_to_string : owned_relative_path -> string

val owned_inventory_entry_kind :
  owned_inventory_root ->
  string list ->
  (Unix.file_kind,
   owned_regular_file_read_error)
  result

val load_single_link_regular_file_beneath :
  root:string ->
  ?excluded_directory:string list ->
  string list ->
  (owned_regular_file_contents option,
   owned_regular_file_read_error)
  result

type owned_regular_file_reread =
  | Same_file
  | Read of owned_regular_file_contents

val reload_single_link_regular_file_beneath :
  root:string ->
  ?excluded_directory:string list ->
  held:owned_regular_file_snapshot ->
  string list ->
  (owned_regular_file_reread option,
   owned_regular_file_read_error)
  result

val with_owned_inventory_regular_file :
  owner_uid:int ->
  owned_inventory_root ->
  string list ->
  (file:Unix.file_descr -> parent:Unix.file_descr -> stat:Unix.stats -> 'a) ->
  ('a, owned_regular_file_read_error) result

type owned_reader = Eio_unix.Fd.t

val open_owned_reader :
  sw:Eio.Switch.t -> parent:Eio.Fs.dir_ty Eio.Path.t -> leaf:string ->
  (owned_reader, owned_regular_file_read_error) result

val owned_reader_stat : owned_reader -> Eio.File.Stat.t

val owned_reader_pread : owned_reader -> offset:int64 -> length:int -> string

module Owned_reader_sync_stage : sig type t = Sync_file | Sync_parent end

val sync_owned_reader :
  parent:Eio.Fs.dir_ty Eio.Path.t -> leaf:string -> owned_reader ->
  (unit, owned_regular_file_read_error) result

module Owned_reader_for_testing :
  sig
    type sync_stage = Owned_reader_sync_stage.t = Sync_file | Sync_parent
    val sync_owned_reader :
      before_sync:(sync_stage -> 'a) ->
      parent:[> Eio.Fs.dir_ty ] Eio.Path.t ->
      leaf:string ->
      owned_reader ->
      (unit, owned_regular_file_read_error)
      result
  end

val owned_inventory_entry_digest :
  owned_inventory_root ->
  string list ->
  (owned_regular_file_range_digest,
   owned_regular_file_read_error)
  result

val load_owned_regular_file_range_with_sha256 :
  ownership_root:string ->
  offset:int ->
  max_bytes:int ->
  string ->
  (owned_regular_file_range_digest
   option, owned_regular_file_read_error)
  result

val sha256_owned_regular_file :
  ownership_root:string ->
  string ->
  (string option,
   owned_regular_file_read_error)
  result

val read_dir : string -> string list

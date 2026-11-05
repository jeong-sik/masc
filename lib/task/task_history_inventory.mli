(** The dated files of both stores at one moment: each file with its owner
    check and stat snapshot, the ceilings a cursor records, and the digest
    that pins the set so a continuation can tell it changed.
    [Task_history_page] includes this module. *)

open Task_history_types

type file = { source : source; relative : string; path : string; snapshot : Fs_compat.owned_regular_file_snapshot }

type inventory = { files : file list; observations : (source * availability) list; roots : Yojson.Safe.t list }

val same_stat_identity : Unix.stats -> Unix.stats -> bool

val inspect_owned_dir :
  root:string ->
  string -> (Unix.stats, error) result

val inventory :
  root:string ->
  held:Fs_compat.owned_inventory_root ->
  (inventory, error) result

val capture :
  file list -> ceiling list

val prefix :
  ceilings:ceiling list ->
  file list -> file list

val inventory_hash :
  ceilings:ceiling list ->
  inventory -> string

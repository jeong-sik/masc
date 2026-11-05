(** The index of one scanned dated file and the cache that keeps it.
    A [task_table] collects the row offsets of each task id while a file is
    scanned, and [task_table_to_map] turns it into the per-task offset map.
    A [cached_segment] stores that map with the file snapshot and the digests
    of the scanned blocks. The cache is process-wide and bounded by the
    number of files and of rows; [verify_cached_segment] decides from the
    current snapshot and the block digests whether a cached segment is still
    valid. [Task_history_page] includes this module. *)

open Task_history_types
open Task_history_reader

type task_table

val create_task_table : unit -> task_table

val add_slice_to_table : task_table -> string -> int -> int -> int -> unit

val add_string_to_table : task_table -> string -> int -> unit

val task_table_to_map :
  task_table -> int list String_map.t

type cached_segment = {
  device : int;
  inode : int;
  snapshot : Fs_compat.owned_regular_file_snapshot;
  scanned_from : int;
  scanned_to : int;
  row_count : int;
  first_row_offset : int;
  block_digests : (int * int * string) list;
  by_task : int list String_map.t;
  conflicting : int list String_map.t;
  verified_settled : bool;
  mutable last_used : int;
}

val find_cached_segment :
  root:string -> relative:string -> cached_segment option

val invalidate_cached_segment_if_same :
  root:string -> relative:string -> cached_segment -> unit

val store_cached_segment :
  root:string -> relative:string -> cached_segment -> unit

val make_cached_segment :
  reader ->
  scanned_from:int ->
  scanned_to:int ->
  row_count:int ->
  first_row_offset:int ->
  by_task:int list String_map.t ->
  conflicting:int list String_map.t ->
  (cached_segment, error) result

val verify_cached_segment :
  is_ceiling:bool ->
  reader ->
  cached_segment ->
  (bool, error) result

val add_offset_to_map :
  string ->
  'a ->
  'a list String_map.t ->
  'a list String_map.t

val merge_desc_maps :
  'a list String_map.t ->
  'a list String_map.t ->
  'a list String_map.t

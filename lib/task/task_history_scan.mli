(** The fast path that reads one stored row without building a JSON tree.
    [scan_row_slice_fast] walks the bytes of a row once and validates the
    JSON as it goes. It returns 0 when the row names no task, 1 when it names
    one task (the offset and length of the id land in [state.(1)] and
    [state.(2)]), and -1 when the row needs [Task_history_row.classify_row].
    The caller sizes the scratch arrays: [key_buf] holds
    [max_fast_depth * key_stride] ints and [state] holds 13.
    [Task_history_page] includes this module. *)

open Task_history_types

val max_fast_depth : int

val key_stride : int

val slice_eq_lit : string -> int -> int -> string -> bool

val scan_row_slice_fast :
  source:source ->
  string -> pos:int -> len:int -> int array -> int array -> int

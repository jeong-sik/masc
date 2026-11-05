(** Classifies one stored row. [classify_row] parses a line of a dated file,
    checks the JSON (finite numbers, no repeated keys) and the fields that
    carry a task id, and returns a [row_outcome]: the one task the row names,
    conflicting task ids, no task, or an invalid row. [is_whitespace] and
    [is_blank_slice] are the blank test the rest of the file reuses.
    [Task_history_page] includes this module. *)

open Task_history_types

val is_whitespace : char -> bool

val is_blank_slice : string -> pos:int -> len:int -> bool

type row_outcome =
  | Row_unrelated
  | Row_task of { task_id : string; json : Yojson.Safe.t }
  | Row_conflicting of { string_ids : string list }
  | Row_invalid

val classify_row :
  source:source ->
  string -> row_outcome

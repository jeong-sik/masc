(** Producer-owned line evidence for a completed filesystem change. *)

type line_range = private {
  start_line : int;
  end_line : int;
}
(** 1-based inclusive file coordinates. *)

type edit_occurrence = private {
  old_range : line_range;
  new_range : line_range option;
}
(** One actual Edit match. [old_range] addresses the input file;
    [new_range] addresses the completed file and is [None] for deletion. *)

type t = private
  | Edited of {
      occurrence_count : int;
      occurrences : edit_occurrence list option;
    }
  | Written of { new_range : line_range option }
(** [Edited.occurrences] is [Some] only when every range is present. [None]
    is explicit bounded-evidence omission; [occurrence_count] remains exact. *)

val max_recorded_edit_occurrences : int
(** Maximum number of per-occurrence ranges retained in one durable record.
    Larger edits retain their exact occurrence count and explicitly omit the
    range list. *)

val advance_line : start_line:int -> string -> int
(** Advance a file cursor by the line breaks in [text]. *)

val edit_occurrence :
  old_start_line:int ->
  new_start_line:int ->
  old_string:string ->
  new_string:string ->
  edit_occurrence
(** Build the evidence for one non-empty matched [old_string]. Raises
    [Invalid_argument] when either start is below one or [old_string] is empty. *)

val edited : edit_occurrence list -> t
(** Build Edit evidence in producer match order. Raises [Invalid_argument]
    for an empty list because a completed Edit must have matched. *)

val edited_ranges_omitted : occurrence_count:int -> t
(** Build bounded Edit evidence when the exact positive occurrence count is
    known but retaining every range would exceed
    {!max_recorded_edit_occurrences}. *)

val written : string -> t
(** Build full-body Write evidence. Empty content has no line range. *)

val to_yojson : t -> Yojson.Safe.t
(** Stable durable representation stored independently of opaque tool output. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict decoder for the durable representation. Rejects invalid ranges,
    mismatched counts, a bounded omission below the producer limit, and a
    Write range that does not start at line one. *)

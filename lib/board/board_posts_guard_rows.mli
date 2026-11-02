(** Pure physical-row validation for an initialization guard. The caller owns
    reading, offsets, hashing and settlement; these values grant no authority. *)

type framing = Complete | Torn of { rows_end : int; end_offset : int }

val framing : rows_end:int -> end_offset:int -> framing
val framing_to_yojson : framing -> Yojson.Safe.t

type rows

val empty : rows
val add_row : rows -> string -> rows
(** Fold complete physical rows without their terminating LF. Blank rows count;
    only the first row's text is retained. No decoding or effects occur here. *)
val physical_rows : rows -> int

type validation =
  | Valid_guard of Board_posts_guard_json.t
  | Torn_guard
  | Guard_row_count_rejected of int
  | Guard_row_rejected of Board_posts_guard_json.rejection

val validate : framing:framing -> rows -> validation
(** Refuse a torn tail before interpreting row count or decoding the sole row. *)
val validation_to_yojson : validation -> Yojson.Safe.t

(** Closed JSONL record codec around one typed compaction operation event. *)

module Cursor : sig
  type t
  type error = Negative of int
  val zero : t
  val of_int : int -> (t, error) result
  val to_int : t -> int
end

type row =
  { recorded_at : float
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; event : Keeper_compaction_operation.event
  }

type envelope_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Invalid_recorded_at
  | Invalid_event of Keeper_compaction_operation_codec.decode_error

type issue =
  | Incomplete_tail
  | Malformed_json of string
  | Invalid_envelope of envelope_error

type decode_error =
  { row_number : int option
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; issue : issue
  }

val encode :
  recorded_at:float ->
  Keeper_compaction_operation.event ->
  (string, envelope_error) result
(** Returns exactly one newline-terminated JSONL row. *)

val decode_rows :
  from:Cursor.t ->
  row_number:int option ->
  string ->
  (row list, decode_error) result
(** [row_number] is [Some] only when the caller owns the complete prefix. *)

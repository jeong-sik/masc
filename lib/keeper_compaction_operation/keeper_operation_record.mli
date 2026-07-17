(** Closed JSONL envelope around one caller-owned typed operation codec. *)

module Cursor : sig
  type t
  type error = Negative of int
  val zero : t
  val of_int : int -> (t, error) result
  val to_int : t -> int
end

type 'event row =
  { recorded_at : float
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; event : 'event
  }

type 'event_error envelope_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Invalid_recorded_at
  | Invalid_event of 'event_error

type encode_error = Non_finite_recorded_at

type 'event_error issue =
  | Incomplete_tail
  | Malformed_json of string
  | Invalid_envelope of 'event_error envelope_error

type 'event_error decode_error =
  { row_number : int option
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; issue : 'event_error issue
  }

val encode :
  encode_event:('event -> Yojson.Safe.t) ->
  recorded_at:float ->
  'event ->
  (string, encode_error) result
(** Returns exactly one newline-terminated JSONL row. *)

val decode_rows :
  decode_event:(Yojson.Safe.t -> ('event, 'event_error) result) ->
  from:Cursor.t ->
  row_number:int option ->
  string ->
  ('event row list, 'event_error decode_error) result
(** [row_number] is [Some] only when the caller owns the complete prefix. *)

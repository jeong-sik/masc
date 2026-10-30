(** Closed JSON boundary helpers shared by execution codecs.

    [validate] rejects every value that cannot cross a standard JSON boundary,
    including repeated object keys at any depth.  Its typed path is rooted at
    the value passed to [validate]; [context] only labels that root for human
    diagnostics. *)

type path_segment =
  | Object_field of string
  | Array_index of int

type validation_reason =
  | Duplicate_object_key
  | Non_finite_float
  | Invalid_integer_literal of string

type validation_error =
  { context : string
  ; path : path_segment list
  ; reason : validation_reason
  }

val validation_error_to_string : validation_error -> string

val is_finite_number : float -> bool
val validate : context:string -> Yojson.Safe.t -> (unit, validation_error) result

val object_fields
  :  context:string
  -> required:string list
  -> optional:string list
  -> Yojson.Safe.t
  -> ((string * Yojson.Safe.t) list, string) result

val field : string -> (string * Yojson.Safe.t) list -> (Yojson.Safe.t, string) result
val string_field : string -> (string * Yojson.Safe.t) list -> (string, string) result
val int_field : string -> (string * Yojson.Safe.t) list -> (int, string) result

val option_string_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (string option, string) result

val option_json : Yojson.Safe.t option -> Yojson.Safe.t

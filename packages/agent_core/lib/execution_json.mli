(** Closed JSON boundary helpers shared by execution codecs. *)

val is_finite_number : float -> bool
val validate : context:string -> Yojson.Safe.t -> (unit, string) result

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

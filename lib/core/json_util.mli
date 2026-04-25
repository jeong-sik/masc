(** JSON utilities for MASC-MCP *)

(** Field extraction with type coercion *)

val get_string : Yojson.Safe.t -> string -> string option
(** [get_string json key] extracts string field, returns None if missing/wrong type *)

val get_string_with_default : Yojson.Safe.t -> key:string -> default:string -> string
(** [get_string_with_default json key ~default] extracts string with fallback *)

val get_string_nonempty : Yojson.Safe.t -> string -> string option
(** [get_string_nonempty json key] returns [Some s] only when the field
    is a non-empty string after [String.trim]; whitespace-only inputs
    yield [None].  SSOT for the bespoke trim+empty filter previously
    duplicated in keeper/judge JSON parsers. *)

val get_int : Yojson.Safe.t -> string -> int option
(** [get_int json key] extracts int field, supports Int and Intlit *)

val get_int_with_default : Yojson.Safe.t -> key:string -> default:int -> int
(** [get_int_with_default json key ~default] extracts int with fallback *)

val get_float : Yojson.Safe.t -> string -> float option
(** [get_float json key] extracts float field, coerces int to float *)

val get_bool : Yojson.Safe.t -> string -> bool option
(** [get_bool json key] extracts bool field *)

val get_string_list : Yojson.Safe.t -> string -> string list
(** [get_string_list json key] extracts list of strings, filters empty *)

val get_object : Yojson.Safe.t -> string -> Yojson.Safe.t option
(** [get_object json key] extracts JSON object *)

val get_array : Yojson.Safe.t -> string -> Yojson.Safe.t option
(** [get_array json key] extracts JSON array *)

(** {1 Required field extraction (Result-returning)}

    Return [(value, string) result] with an error message identifying
    the missing or mistyped field. Use with [let ( let* ) = Result.bind]. *)

val require_string : Yojson.Safe.t -> string -> (string, string) result
val require_int : Yojson.Safe.t -> string -> (int, string) result
val require_float : Yojson.Safe.t -> string -> (float, string) result
val require_bool : Yojson.Safe.t -> string -> (bool, string) result

(** Construction helpers *)

val json_string_list : string list -> Yojson.Safe.t
(** [json_string_list xs] creates JSON string array *)

val json_assoc_list : (string * string) list -> Yojson.Safe.t
(** [json_assoc_list kv] creates JSON object from string pairs *)

val parse_json_or_string : string -> Yojson.Safe.t
(** [parse_json_or_string s] parses JSON or returns string literal *)

(** {1 Option serialization helpers}

    Canonical [None -> `Null] converters for building JSON. *)

val option_to_yojson : ('a -> Yojson.Safe.t) -> 'a option -> Yojson.Safe.t
val int_opt_to_json : int option -> Yojson.Safe.t
val string_opt_to_json : string option -> Yojson.Safe.t
val float_opt_to_json : float option -> Yojson.Safe.t
val bool_opt_to_json : bool option -> Yojson.Safe.t

(** List utilities *)

val dedupe_keep_order : 'a list -> 'a list
(** [dedupe_keep_order xs] removes duplicates while preserving order *)

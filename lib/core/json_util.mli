(** JSON utilities for MASC *)

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

(** {1 Required field extraction (Result-returning)} *)

val require_string : Yojson.Safe.t -> string -> (string, string) result
val require_int : Yojson.Safe.t -> string -> (int, string) result
val require_float : Yojson.Safe.t -> string -> (float, string) result
val require_bool : Yojson.Safe.t -> string -> (bool, string) result

(** Construction helpers *)

val json_string_list : string list -> Yojson.Safe.t
(** [json_string_list xs] creates JSON string array *)

val string_assoc_to_json : (string * string) list -> Yojson.Safe.t
(** [string_assoc_to_json fields] builds an object whose every member is a
    string. *)

val string_assoc_of_json :
  Yojson.Safe.t -> ((string * string) list, string) result
(** [string_assoc_of_json json] reads an object back into string pairs,
    preserving field order.  Returns an explicit error when [json] is not an
    object or any member is not a string; malformed metadata is never silently
    dropped. *)

val string_field_if_present :
  string -> string option -> (string * Yojson.Safe.t) list
(** [string_field_if_present key opt] returns [[ (key, `String v) ]] for
    [Some v] and [[]] for [None], so the key is absent from the built
    object rather than present as null.  Contrast {!string_opt_field},
    which always emits the key. *)

(** {1 Option serialization helpers}

    Canonical [None -> `Null] converters for building JSON. *)

val string_opt_to_json : string option -> Yojson.Safe.t
val string_opt_to_json_trimmed : string option -> Yojson.Safe.t
(** [string_opt_to_json_trimmed] trims whitespace and returns [`Null]
    for empty or whitespace-only strings. *)
val int_opt_to_json : int option -> Yojson.Safe.t
val int_ratio_json : int -> int -> Yojson.Safe.t
(** [int_ratio_json numerator denominator] returns
    [`Float (numerator /. denominator)] as floats, or [`Null] when
    [denominator] is 0. *)
val float_opt_to_json : float option -> Yojson.Safe.t
val bool_opt_to_json : bool option -> Yojson.Safe.t
val string_opt_field : string -> string option -> string * Yojson.Safe.t
(** [string_opt_field name opt] returns [(name, `String v)] for [Some v]
    or [(name, `Null)] for [None]. Common pattern for JSON assoc fields. *)
val option_to_yojson : ('a -> Yojson.Safe.t) -> 'a option -> Yojson.Safe.t
(** Higher-order: [option_to_yojson f] maps [f] over [Some] or returns [`Null]. *)

val int_option_to_yojson : int option -> Yojson.Safe.t
(** [int_option_to_yojson] maps [Some n] to [`Int n] or [None] to [`Null]. *)

val string_option_to_yojson : string option -> Yojson.Safe.t
(** [string_option_to_yojson] maps [Some s] to [`String s] or [None] to [`Null]. *)


(** {1 Diagnostic helpers} *)

val kind_name : Yojson.Safe.t -> string
val excerpt : ?max:int -> Yojson.Safe.t -> string

(** {1 Assoc field extraction} *)

val assoc_member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option
(** [assoc_member_opt name json] extracts field [name] from [`Assoc] *)

val assoc_string_opt : string -> Yojson.Safe.t -> string option
(** [assoc_string_opt name json] extracts non-empty string field *)

val assoc_int_opt : string -> Yojson.Safe.t -> int option
(** [assoc_int_opt name json] extracts int field, supports Intlit *)

val assoc_bool_opt : string -> Yojson.Safe.t -> bool option
(** [assoc_bool_opt name json] extracts bool field *)

val assoc_object_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option
(** [assoc_object_opt name json] extracts the [`Assoc] field [name],
    returning [None] when the field is missing, null, or not an object.
    Same result as {!get_object} with the arguments in assoc-family order. *)

val find_assoc_row_by_string_field :
  field:string -> value:string -> Yojson.Safe.t -> Yojson.Safe.t option
(** [find_assoc_row_by_string_field ~field ~value json] returns the first
    [`Assoc] row of the JSON array [json] whose [field] member is the
    string [value].  Returns [None] when [json] is not an array or when
    no row matches. *)

val json_string_list_member : string -> Yojson.Safe.t -> string list
(** [json_string_list_member name json] extracts a list of non-empty
    trimmed strings from the JSON array at field [name]. Returns [[]]
    if the field is missing or not an array. *)
(** {1 Assoc field validation (Result-returning)}

    These take an already-destructured [`Assoc] field list, unlike the
    [require_*] family above which takes a whole [Yojson.Safe.t].
    [surface] names the object in the error message, so a failure reads
    ["<surface>.<field> is required"]. *)

val reject_unknown_fields :
  surface:string ->
  allowed:string list ->
  (string * Yojson.Safe.t) list ->
  (unit, string) result
(** [reject_unknown_fields ~surface ~allowed fields] returns [Ok ()] when
    every key in [fields] appears in [allowed] and no key repeats.
    Reports the duplicate key first, then the first unsupported key. *)

val require_field_string :
  surface:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (string, string) result
(** [require_field_string ~surface field fields] returns the string at
    [field].  Errors when the field is missing, is not a string, or is
    blank after trimming.  The value is returned untrimmed. *)

val require_field_float :
  surface:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (float, string) result
(** [require_field_float ~surface field fields] returns the float at
    [field], widening [`Int] to float.  Errors when the field is missing
    or is neither a float nor an int. *)

val require_field_positive_int :
  surface:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (int, string) result
(** [require_field_positive_int ~surface field fields] returns the int at
    [field] when it is greater than 0.  Errors when the field is missing,
    is not an int, or is 0 or negative. *)

val require_field_string_list :
  surface:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (string list, string) result
(** [require_field_string_list ~surface field fields] returns the array at
    [field] as a string list.  Errors when the field is missing, is not an
    array, or holds a non-string element (the error names its index). *)

(** List utilities *)

val dedupe_keep_order : 'a list -> 'a list
(** [dedupe_keep_order xs] removes duplicates while preserving order *)

val normalize_string_list : string list -> string list
(** [normalize_string_list items] trims each item, drops the ones that
    are empty after trimming, and removes duplicates while preserving
    the order of first occurrence. *)

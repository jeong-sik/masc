(** Shared utility functions.

    Small helpers extracted from multiple modules to eliminate
    duplication.

    @stability Internal
    @since 0.93.1 *)

(** Return [a] if [Some], otherwise [b]. *)
val first_some : 'a option -> 'a option -> 'a option

(** Check whether [haystack] contains [needle] as a substring. *)
val string_contains : needle:string -> string -> bool

(** Construct a {!Error.Serialization} [JsonParseError]. *)
val json_parse_error : string -> Error.sdk_error

(** Construct a {!Error.Io} [FileOpFailed] with [op = "read"]. *)
val file_read_error : path:string -> detail:string -> Error.sdk_error

(** Construct a {!Error.Io} [FileOpFailed] with [op = "write"]. *)
val file_write_error : path:string -> detail:string -> Error.sdk_error

(** Append a single element to the end of a list. *)
val snoc : 'a list -> 'a -> 'a list

(** Concatenate two lists (alias for [@]). *)
val snoc_list : 'a list -> 'a list -> 'a list

(** Traverse a list with [f], collecting [Ok] values.
    Short-circuits on first [Error]. *)
val result_traverse : f:('a -> ('b, 'e) result) -> 'a list -> ('b list, 'e) result

(** Truncate string to [max_len], appending "..." if truncated. *)
val clip : string -> int -> string

(** Safe substring: returns "" if start is past end or len is negative. *)
val safe_sub : string -> int -> int -> string

(** Case-insensitive substring search. *)
val contains_substring_ci : haystack:string -> needle:string -> bool

(** [regex_match re s] returns [true] if regex [re] matches anywhere in [s]. *)
val regex_match : Str.regexp -> string -> bool

(** Filter out empty strings from a list. *)
val filter_non_empty : string list -> string list

(** Split on [sep], trim each fragment, discard empty results. *)
val split_on_char_trim : char -> string -> string list

(** [trim_non_empty s] trims [s] and returns [Some trimmed] if non-empty,
    [None] otherwise. *)
val trim_non_empty : string -> string option

(** [trim_non_empty_opt opt] maps [trim_non_empty] over an option. *)
val trim_non_empty_opt : string option -> string option

(** [json_member_str key json] returns the string value for [key] in [json],
    or [""] if missing or wrong type. *)
val json_member_str : string -> Yojson.Safe.t -> string

(** [json_member_bool key json] returns the bool value for [key] in [json],
    or [false] if missing or wrong type. *)
val json_member_bool : string -> Yojson.Safe.t -> bool

(** Serialize optional int to JSON: [Some n] -> [`Int n], [None] -> [`Null]. *)
val json_of_int_opt : int option -> Yojson.Safe.t

(** Serialize optional float to JSON: [Some f] -> [`Float f], [None] -> [`Null]. *)
val json_of_float_opt : float option -> Yojson.Safe.t

(** Serialize optional bool to JSON: [Some b] -> [`Bool b], [None] -> [`Null]. *)
val json_of_bool_opt : bool option -> Yojson.Safe.t

(** Serialize optional string to JSON: [Some s] -> [`String s], [None] -> [`Null]. *)
val json_of_string_opt : string option -> Yojson.Safe.t

(** Serialize string list to JSON: [["a"; "b"]] -> [`List [`String "a"; `String "b"]]. *)
val json_of_string_list : string list -> Yojson.Safe.t

(** Extract string list from JSON value list, ignoring non-string elements. *)
val string_list_of_json : Yojson.Safe.t list -> string list

(** Serialize (string * string) list to JSON assoc: [[("k","v")]] -> [`Assoc [["k", `String "v"]]]. *)
val json_of_string_pairs : (string * string) list -> Yojson.Safe.t

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
val json_parse_error : string -> Error.t

(** Append a single element to the end of a list. *)
val snoc : 'a list -> 'a -> 'a list

(** Concatenate two lists (alias for [@]). *)
val snoc_list : 'a list -> 'a list -> 'a list

(** Truncate string to [max_len] bytes on a UTF-8 character boundary,
    appending "..." if truncated. *)
val clip : string -> int -> string

(** Case-insensitive substring search. *)
val contains_substring_ci : haystack:string -> needle:string -> bool

(** [regex_match re s] returns [true] if regex [re] matches anywhere in [s]. *)
val regex_match : Str.regexp -> string -> bool

(** Filter out empty strings from a list. *)
val filter_non_empty : string list -> string list

(** [trim_non_empty s] trims [s] and returns [Some trimmed] if non-empty,
    [None] otherwise. *)
val trim_non_empty : string -> string option

(** [trim_non_empty_opt opt] maps [trim_non_empty] over an option. *)
val trim_non_empty_opt : string option -> string option

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

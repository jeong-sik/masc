(** Comment-preserving, line-based TOML editing.

    The editor updates selected table keys without parsing and re-emitting the
    whole file, so comments, blank lines, and unrelated table content remain
    byte-for-byte stable. *)

val escape_string : string -> string
(** Escape a TOML basic string payload. *)

val scalar_line : key:string -> value:string -> string
(** Render [key = "value"]. *)

val string_array_line : key:string -> values:string list -> string
(** Render [key = ["a", "b"]] on one line. *)

val multiline_array_lines : key:string -> values:string list -> string list
(** Render [key = []] as a multi-line array block. *)

val split_lines : string -> string list * bool
(** Split content into lines and whether it ended with a trailing newline. *)

val join_lines : string list -> trailing_newline:bool -> string
(** Join lines, optionally restoring a final newline. *)

val strip_comment : string -> string
(** Remove the first TOML line comment from [line]. *)

val is_table_header : string -> bool
(** Return [true] when [line] is a TOML table header after trimming comments. *)

val split_at : int -> 'a list -> 'a list * 'a list
(** Split a list at [n], returning [(prefix, suffix)]. *)

val find_index : ('a -> bool) -> 'a list -> int option
(** Return the zero-based index of the first matching element. *)

val key_of_line : string -> string option
(** Return the assignment key in a [key = value] line, if present. *)

val edit_table_scalar :
  string -> path:string -> key:string -> value:string option -> string
(** Set or remove a scalar key inside [[path]]. *)

val edit_table_multiline_array :
  string -> path:string -> key:string -> values:string list -> string
(** Set a multi-line string array key inside [[path]]. *)

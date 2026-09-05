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

val split_lines : string -> string list * bool
(** Split content into lines and whether it ended with a trailing newline. *)

val join_lines : string list -> trailing_newline:bool -> string
(** Join lines, optionally restoring a final newline. *)

val strip_comment : string -> string
(** Remove the first TOML line comment from [line]. *)

type header =
  | Table of string list
  | Table_array of string list
(** A table header by the key path the TOML grammar reads out of it: [Table]
    for [[a.b]], [Table_array] for [[[a.b]]]. Keys are unescaped. *)

val header_of_line : string -> header option
(** The header [line] opens, when the line parses on its own as one empty
    table and nothing else. Whitespace, quoting and a trailing comment are
    the grammar's to read; a line that does not parse alone is [None]. *)

val is_table_header : string -> bool
(** Return [true] when [header_of_line line] is a header of either kind. *)

val is_table : path:string -> string -> bool
(** Return [true] when [line] opens the standard table [[path]], compared by
    the key path the grammar reads from each. *)

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

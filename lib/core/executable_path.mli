(** Shell-free executable lookup helpers.

    These helpers intentionally do not mirror shell quirks such as treating an
    empty PATH entry as the current directory. Callers use them only for
    pre-spawn availability checks; the actual spawn path remains the authority. *)

val regular_file_is_executable : string -> bool
(** [regular_file_is_executable path] returns [true] when [path] is an
    executable regular file. *)

val search_path_separator : char
(** Platform search-path separator for [PATH]-style variables. *)

val split_search_path : ?separator:char -> string -> string list
(** [split_search_path raw] splits [raw] with {!search_path_separator}.
    Empty entries are preserved so callers can explicitly reject shell-style
    current-directory segments. *)

val path_has_executable : ?getenv:(string -> string option) -> string -> bool
(** [path_has_executable name] returns [true] when [PATH] contains a non-empty
    directory with an executable regular file named [name]. *)

val command_available : ?getenv:(string -> string option) -> string -> bool
(** [command_available name] trims [name], rejects empty strings, checks path
    names containing ['/'] directly, and otherwise searches [PATH]. *)

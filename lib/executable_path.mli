(** Shell-free executable lookup helpers. *)

val regular_file_is_executable : string -> bool
(** [regular_file_is_executable path] is [true] when [path] names a regular
    file that the current process may execute. *)

val path_has_executable : ?getenv:(string -> string option) -> string -> bool
(** [path_has_executable name] checks [PATH] entries for an executable named
    [name]. Empty [PATH] entries are ignored instead of being interpreted as the
    current directory. *)

val command_available : ?getenv:(string -> string option) -> string -> bool
(** [command_available name] checks absolute/relative paths directly and plain
    command names through [PATH]. Blank command names are unavailable. *)

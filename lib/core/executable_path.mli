(** Shell-free executable lookup helpers.

    These helpers intentionally do not mirror shell quirks such as treating an
    empty PATH entry as the current directory. The availability checks answer
    before a spawn, and the actual spawn path remains the authority there.
    {!absolute_on_path} gives the file itself, for a caller that hands its
    path to another process. *)

val regular_file_is_executable : string -> bool
(** Check the supplied path directly, following symbolic links as [Unix.stat]
    does. Only a regular file with execute permission returns [true]; a missing
    or inaccessible path, other file kind, [Unix.Unix_error] or [Sys_error]
    returns [false]. Does not trim the path or search [PATH]. *)

val search_path_separator : char
(** Platform search-path separator for [PATH]-style variables. *)

val split_search_path : ?separator:char -> string -> string list
(** [split_search_path ?separator raw] splits [raw] on [separator], which
    defaults to {!search_path_separator}. Pass [separator] explicitly only to
    parse a non-native layout (e.g. a Windows [';'] list on a POSIX host in
    tests). Empty entries are preserved so callers can explicitly reject
    shell-style current-directory segments. *)

val path_has_executable : ?getenv:(string -> string option) -> string -> bool
(** [path_has_executable name] returns [true] when [PATH] contains a non-empty
    directory with an executable regular file named [name]. *)

val absolute_on_path : ?getenv:(string -> string option) -> string -> string option
(** [absolute_on_path name] is the first executable regular file named [name]
    in a directory of [PATH] that is spelled as an absolute path, as that
    directory joined with [name]. An empty or relative entry of [PATH] is
    passed over: the file it names depends on the working directory of
    whoever resolves it, and a process that is handed the path may run in
    another one. [None] when [PATH] is unset or no such directory holds the
    file. *)

val command_available : ?getenv:(string -> string option) -> string -> bool
(** [command_available name] trims [name], rejects empty strings, checks path
    names containing ['/'] directly, and otherwise searches [PATH]. *)

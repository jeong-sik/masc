(** Shell-free executable lookup helpers. *)

val regular_file_is_executable : string -> bool

val path_has_executable
  :  ?getenv:(string -> string option)
  -> string
  -> bool

val command_available
  :  ?getenv:(string -> string option)
  -> string
  -> bool

(** Shared shell safety helpers.

    [Shell_command_gate] is the authoritative command gate.  This
    module keeps live shared helpers: destructive command taxonomy,
    destructive pattern metadata, and stable command hashes for logs. *)

type destructive_class =
  | Recursive_delete
  | Sql_destructive
  | Forced_git_mutation
  | Privilege_escalation
  | Filesystem_format
  | Device_write
  | Process_signal
  | System_control

val destructive_class_to_string : destructive_class -> string
(** [destructive_class_to_string c] returns the canonical snake_case
    tag for metrics and audit logs. *)

type destructive_pattern =
  { class_ : destructive_class
  ; pattern : string
  ; description : string
  }

val classify_destructive :
  destructive_pattern list -> string -> (destructive_class * string) option
(** [classify_destructive patterns cmd] returns the first matching
    [(class, substring)] pair in declaration order, or [None] when no
    pattern matches. Matching is case-insensitive.

    The pattern catalogue is owned by {!Destructive_ops_policy}; this
    function performs only the typed classification over a given list. *)

val cmd_hash_for_log : string -> string
(** [cmd_hash_for_log cmd] returns a deterministic 12-hex-char prefix
    of the command digest for log de-duplication. *)

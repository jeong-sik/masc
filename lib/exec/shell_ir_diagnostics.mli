(** Pure diagnostics derived from Shell IR and process output. *)

val glob_literal_failure_fields :
  ir:Shell_ir.t ->
  status:Unix.process_status ->
  stderr:string ->
  (string * Yojson.Safe.t) list
(** JSON fields explaining likely literal glob argv failures. *)

val duplicate_argv0_failure_fields :
  ir:Shell_ir.t ->
  status:Unix.process_status ->
  stderr:string ->
  (string * Yojson.Safe.t) list
(** JSON fields for a path-not-found failure whose argv[0] duplicates the
    executable (the execve-style "repeated program name" mistake). Advisory
    only — the typed gate still accepts such argv because it may be an
    intentional literal argument. *)

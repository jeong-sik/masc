(** Pure diagnostics derived from Shell IR and process output. *)

val glob_literal_failure_fields :
  ir:Shell_ir.t ->
  status:Unix.process_status ->
  stderr:string ->
  (string * Yojson.Safe.t) list
(** JSON fields explaining likely literal glob argv failures. *)

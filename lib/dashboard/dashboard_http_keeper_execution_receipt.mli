(** Execution-receipt path resolution and dashboard diagnostics. *)

val execution_receipt_store_pattern : Workspace.config -> string
val count_execution_receipt_entries : Workspace.config -> string list -> int
val execution_receipt_coverage_gaps : Workspace.config -> Yojson.Safe.t list
val execution_receipt_coverage_gaps_with_read_errors :
  Workspace.config -> Yojson.Safe.t list * Yojson.Safe.t list

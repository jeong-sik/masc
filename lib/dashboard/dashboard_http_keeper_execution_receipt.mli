(** Execution-receipt path resolution and dashboard diagnostics. *)

val execution_receipt_dir : Coord.config -> string -> string
val execution_receipt_store_pattern : Coord.config -> string
val count_execution_receipt_entries : Coord.config -> string list -> int
val execution_receipt_coverage_gaps : Coord.config -> Yojson.Safe.t list

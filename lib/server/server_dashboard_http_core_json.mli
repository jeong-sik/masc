(** JSON helpers for dashboard HTTP core projections. *)

val json_assoc_int_opt : string -> Yojson.Safe.t -> int option
val operator_generated_at_iso : Yojson.Safe.t -> string

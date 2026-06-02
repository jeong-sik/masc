(** JSON helpers for dashboard HTTP core projections. *)

val json_assoc_int_opt : string -> Yojson.Safe.t -> int option
val projection_diagnostics_fields : Yojson.Safe.t -> (string * Yojson.Safe.t) list
val projection_diagnostics_field : Yojson.Safe.t -> string -> Yojson.Safe.t option
val operator_generated_at_iso : Yojson.Safe.t -> string

val operator_cache_json
  :  ?cache_key:string
  -> scope:string
  -> Yojson.Safe.t
  -> Yojson.Safe.t

val process_status_to_json : Unix.process_status -> Yojson.Safe.t

val process_status_is_success : Unix.process_status -> bool

val process_result_json :
  ?extra:(string * Yojson.Safe.t) list ->
  status:Unix.process_status ->
  output:string ->
  unit ->
  Yojson.Safe.t
(** Serialize only objective process metadata and the caller's explicit fields.
    No executable-specific interpretation, retry advice, output truncation, or
    automatic artifact persistence is performed. *)

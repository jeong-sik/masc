(** Runtime-lens proof aggregation for keeper runtime trace responses. *)

val runtime_lens_runtime_proof_json :
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  unit ->
  Yojson.Safe.t

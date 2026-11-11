(** Pure join over a bounded retained window. Missing observations do not prove
    that a slot was never attempted. Historical endpoint/time stay on their
    original run and binding; current declarations cannot supply them. *)
val slots_json :
  current_http:(string * Agent_core.Exact_output.binding_observation) list ->
  declared_http:string list -> declared_cli:string list ->
  runs:Exact_lane_run_registry.run list -> Yojson.Safe.t

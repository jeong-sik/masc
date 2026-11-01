(** Exact-revision Skill evidence joined from retained activation ledgers and
    producer-owned composition evidence. *)

val request_of_string :
  string ->
  (Skill_reference.t * Keeper_tool_plan.Composition_run_id.t option, string) result
(** Only the exact reference and an optional UUIDv7 selector are accepted.
    An absent selector requests latest; invalid/duplicate fields are refused. *)

val project :
  ?composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  config:Workspace.config -> Skill_reference.t -> Yojson.Safe.t
(** History, selection and statistics share one exact-reference read.
    A missing requested run never falls back to latest. *)

module For_testing : sig
  val to_yojson :
    reference:Skill_reference.t ->
    composition:Yojson.Safe.t option ->
    composition_runs_observed:int ->
    composition_scope:[ `Exact_reference_retained_runs | `Unavailable ] ->
    composition_unavailable:string list ->
    activation:Yojson.Safe.t option ->
    activation_scope:Keeper_skill_activation_discovery.scope ->
    activation_sessions_inspected:int ->
    activation_ledgers_loaded:int ->
    activation_gaps:Keeper_skill_activation_discovery.gap list ->
    activation_owner_gap_count:int ->
    Yojson.Safe.t
end

(** Exact-revision Skill evidence joined from retained activation ledgers and
    producer-owned composition evidence. *)

val project : config:Workspace.config -> Skill_reference.t -> Yojson.Safe.t

module For_testing : sig
  val to_yojson :
    reference:Skill_reference.t ->
    composition:Yojson.Safe.t option ->
    composition_records_read:int ->
    composition_scope:[ `Exact_reference_latest_completed | `Unavailable ] ->
    composition_unavailable:string list ->
    activation:Yojson.Safe.t option ->
    activation_scope:Keeper_skill_activation_discovery.scope ->
    activation_sessions_inspected:int ->
    activation_ledgers_loaded:int ->
    activation_gaps:Keeper_skill_activation_discovery.gap list ->
    activation_owner_gap_count:int ->
    Yojson.Safe.t
end

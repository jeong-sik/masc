open Keeper_types

val active_model_of_meta : keeper_meta -> string
val next_model_hint_of_meta : keeper_meta -> string option
val string_of_fiber_health : fiber_health -> string
val parse_agent_status : Room.config -> agent_name:string -> Yojson.Safe.t
val keeper_reply_snapshot_of_history :
  Yojson.Safe.t list -> Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t

val keeper_diagnostic_json :
  meta:keeper_meta ->
  agent_status:Yojson.Safe.t ->
  keepalive_running:bool ->
  history_items:Yojson.Safe.t list ->
  now_ts:float ->
  Yojson.Safe.t

val augment_keeper_diagnostic_json :
  meta:keeper_meta ->
  keepalive_running:bool ->
  keepalive_started_at:float option ->
  now_ts:float ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val keeper_surface_status :
  agent_status:Yojson.Safe.t ->
  diagnostic:Yojson.Safe.t ->
  string

val derive_pipeline_stage :
  meta:keeper_meta ->
  surface_status:string ->
  now_ts:float ->
  string

(** RFC-0002: derive pipeline stage directly from phase.
    Deterministic mapping, no 30s recency heuristic. *)
val pipeline_stage_of_phase : Keeper_state_machine.phase -> string

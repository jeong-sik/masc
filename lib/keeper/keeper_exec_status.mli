open Keeper_types

val active_model_of_meta : keeper_meta -> string
val next_model_hint_of_meta : keeper_meta -> string option
val string_of_fiber_health : fiber_health -> string
val agent_status_text : Yojson.Safe.t -> string
val agent_runtime_has_live_signal : Yojson.Safe.t -> bool
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

val keeper_health_state :
  ?fiber_health:fiber_health ->
  ?keepalive_interval_s:float ->
  meta:keeper_meta ->
  keepalive_running:bool ->
  agent_status:Yojson.Safe.t ->
  quiet_reason:string option ->
  now_ts:float ->
  unit ->
  string

val keeper_surface_status :
  agent_status:Yojson.Safe.t ->
  diagnostic:Yojson.Safe.t ->
  string

(** Derive pipeline stage directly from phase (RFC-0002).
    Deterministic mapping, no 30s recency heuristic. *)
val pipeline_stage_of_phase : Keeper_state_machine.phase -> string

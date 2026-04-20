open Keeper_types

val active_model_of_meta : keeper_meta -> string
val active_model_label_of_meta : keeper_meta -> string
val next_model_hint_of_meta : keeper_meta -> string option
val string_of_fiber_health : fiber_health -> string
val agent_status_text : Yojson.Safe.t -> string
val agent_runtime_has_live_signal : Yojson.Safe.t -> bool
val parse_agent_status : Coord.config -> agent_name:string -> Yojson.Safe.t
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

val keeper_health_to_string : keeper_health -> string

(** Strict parse: returns [None] when the wire string is not one of the
    seven canonical keeper_health labels. Prefer this over
    [keeper_health_of_string] for new code so drift is visible. *)
val keeper_health_of_string_opt : string -> keeper_health option

(** Back-compat parse: returns [KH_offline] on unknown strings and
    logs a warning so the typo is operator-visible. Issue #8670. *)
val keeper_health_of_string : string -> keeper_health
val keeper_continuity_to_string : keeper_continuity -> string

val keeper_health_state :
  ?fiber_health:fiber_health ->
  ?keepalive_interval_s:float ->
  meta:keeper_meta ->
  keepalive_running:bool ->
  agent_status:Yojson.Safe.t ->
  quiet_reason:string option ->
  now_ts:float ->
  unit ->
  keeper_health

val keeper_surface_status :
  agent_status:Yojson.Safe.t ->
  diagnostic:Yojson.Safe.t ->
  string

(** Derive pipeline stage directly from phase (RFC-0002).
    Deterministic mapping, no 30s recency heuristic. *)
val pipeline_stage_of_phase : Keeper_state_machine.phase -> string

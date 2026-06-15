open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val active_model_of_meta : keeper_meta -> string
val active_model_label_of_meta : keeper_meta -> string
val next_model_hint_of_meta : keeper_meta -> string option
val string_of_fiber_health : fiber_health -> string
(** Parse the "status" field of an agent-status snapshot blob (produced by
    {!parse_agent_status}) into the closed [Masc_domain.agent_status] ADT.
    Returns [None] when the field is absent or not one of the four canonical
    lowercase labels, so callers classify the closed domain exhaustively
    instead of comparing string literals. *)
val agent_runtime_status_opt : Yojson.Safe.t -> Masc_domain.agent_status option

val agent_runtime_has_live_signal : Yojson.Safe.t -> bool
val parse_agent_status : Workspace.config -> agent_name:string -> Yojson.Safe.t
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
    seven canonical keeper_health labels so drift is visible at the
    call site. *)
val keeper_health_of_string_opt : string -> keeper_health option

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

(** Human/operator-facing explanation for the lossy [pipeline_stage] label.
    For example, [Offline], [Stopped], and [Dead] all map to ["offline"],
    but their detail strings remain distinct. *)
val pipeline_stage_detail_of_phase : Keeper_state_machine.phase -> string

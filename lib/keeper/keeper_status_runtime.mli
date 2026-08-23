open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val active_model_of_meta : keeper_meta -> string
val active_model_label_of_meta : keeper_meta -> string
val string_of_fiber_health : fiber_health -> string
val keeper_heartbeat_stale_after_s :
  keepalive_interval_s:float -> snapshot_interval_s:float -> float
(** Operator-facing Keeper freshness window. The persisted heartbeat producer
    is bounded by both the cycle cadence and the snapshot cadence, so the
    window follows the slower resolved cadence plus one minute of scheduling /
    transport jitter. The ordinary-agent 120-second floor is preserved. *)
val keeper_turn_record_freshness_slo_s : keepalive_interval_s:float -> float
(** Turn-record freshness window.  A record is emitted after a Keeper cycle,
    so the SLO covers the configured sleep cadence plus two minutes of cycle
    execution/scheduling slack while preserving the historical 300-second
    floor for short cadences. *)
val keeper_turn_record_source_health :
  skipped_rows:int ->
  live_turn_in_progress:bool ->
  latest_age_s:float option ->
  freshness_slo_s:float ->
  string * string
(** Classify the turn-record source. A live turn keeps the producer healthy
    even when its previous completed record is old; live-turn progress/stall
    diagnosis remains on the dedicated turn observation surface. Incompatible
    stored rows remain fail-visible. *)
val keeper_metric_producer_active : base_path:string -> bool
(** [true] while a registered Keeper is inside a live turn, or while a failed
    turn's lane is in its legitimate inter-cycle cadence sleep. These are the
    two intervals in which the next metrics-ledger append is still owned by a
    live producer even when the prior row exceeds its age-only SLO. *)
val keeper_diagnostic_json :
  config:Workspace.config ->
  meta:keeper_meta ->
  keepalive_running:bool ->
  history_items:Yojson.Safe.t list ->
  now_ts:float ->
  Yojson.Safe.t

val augment_keeper_diagnostic_json :
  keepalive_running:bool ->
  keepalive_started_at:float option ->
  now_ts:float ->
  Yojson.Safe.t ->
  Yojson.Safe.t

(** Keeper display status derived from keeper health. Closed so consumers that
    classify it match exhaustively. "paused" is an operator override applied
    above this layer, not a member of this domain. *)
type surface_status =
  | Surface_active
  | Surface_busy
  | Surface_listening
  | Surface_inactive
  | Surface_offline
  | Surface_idle

val surface_status_to_string : surface_status -> string

(** Parse a wire/display status string into {!surface_status}; [None] when the
    value is outside the six labels (e.g. "paused" or drift). *)
val surface_status_of_string_opt : string -> surface_status option

(** The [status] field the operator snapshot publishes: a
    {!surface_status}, or the pause override that replaces it. Producers render
    through {!control_plane_status_to_string} and consumers parse through
    {!control_plane_status_of_string_opt} so neither side carries the "paused"
    literal, and a new member fails both ends at compile time. *)
type control_plane_status =
  | Cp_surface of surface_status
  | Cp_paused

val control_plane_status_to_string : control_plane_status -> string

(** [None] when the value is outside the published vocabulary. Producer drift
    stays a rejected parse rather than an accepted default. *)
val control_plane_status_of_string_opt : string -> control_plane_status option

val keeper_surface_status :
  diagnostic:Yojson.Safe.t ->
  string

(** Derive pipeline stage directly from phase (RFC-0002).
    Deterministic mapping, no 30s recency heuristic. *)
val pipeline_stage_of_phase : Keeper_state_machine.phase -> string

(** Human/operator-facing explanation for the lossy [pipeline_stage] label.
    For example, [Offline] and [Stopped] both map to ["offline"], but their
    detail strings remain distinct. *)
val pipeline_stage_detail_of_phase : Keeper_state_machine.phase -> string

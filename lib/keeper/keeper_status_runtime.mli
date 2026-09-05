open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type keeper_quiet_reason =
  | Proactive_disabled
  | Keepalive_not_running
  | Starting_up
  | Never_started

val keeper_quiet_reason_to_string : keeper_quiet_reason -> string
(** Wire form of the keeper diagnostic's [quiet_reason]. The dashboard's
    [KeeperQuietReason] union must list exactly these strings; an unlisted one
    is dropped when the diagnostic is normalised. *)

type keeper_next_action_path =
  | Auto_restart
  | Recover
  | Probe
  | Direct_message

val keeper_next_action_path_to_string : keeper_next_action_path -> string

val keeper_next_action_path_of_string_opt :
  string -> keeper_next_action_path option
(** Strict inverse of {!keeper_next_action_path_to_string}.

    [None] outside the published vocabulary: a reader that cannot spell an
    action says so rather than resolving it to whichever action happens to be
    first, which would paint an operator's screen for work that was never
    asked for. *)
(** Wire form of the keeper diagnostic's [next_action_path]. The dashboard's
    [KeeperNextActionPath] union must list exactly these strings; an unlisted
    one makes it reject the whole diagnostic. *)

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
val keeper_tool_call_source_health :
  gap_reason:string option ->
  latest_age_s:float option ->
  freshness_slo_s:float ->
  string * string
(** The same classification for a tool-call source, plus ["coverage_gap"].

    A recorded telemetry gap outranks freshness: a store can be current about
    the window it did record and still be missing an hour of it, and the gap
    carries its own reason rather than one derived from the verdict. With no
    gap this is {!keeper_turn_record_source_health} with the two turn-record
    answers ([live], [incompatible]) out of reach. *)

val keeper_turn_record_source_health :
  skipped_rows:int ->
  live_turn_in_progress:bool ->
  latest_age_s:float option ->
  freshness_slo_s:float ->
  string * string
(** Classify the turn-record source as one of ["ok"], ["live"], ["stale"],
    ["empty"] or ["incompatible"], with the reason string that goes on the wire
    ([""] for the two healthy ones).

    ["live"] and ["ok"] are separate answers on purpose. A running turn has not
    written its record yet, so the age of the newest finished one says nothing
    about whether the store is keeping up; ["ok"] additionally asserts that age
    is inside the SLO. Both used to report ["ok"], and the dashboard, which
    recomputes the age to check the response against its contract, read a live
    keeper's over-SLO age as a violation and dropped the whole payload
    (#28720). Live-turn progress and stall diagnosis stay on the turn
    observation surface. Incompatible stored rows remain fail-visible. *)
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

val keeper_health_to_string : keeper_health -> string

val keeper_health_of_string_opt : string -> keeper_health option
(** Strict inverse of {!keeper_health_to_string}; [None] outside the published
    vocabulary. Callers that must resolve a value anyway go through
    {!keeper_diagnostic_health}, which falls to [KH_offline] with a warning. *)
(** Wire spelling of a health reading. *)

val keeper_diagnostic_health :
  diagnostic:Yojson.Safe.t -> source:string -> keeper_health
(** Health as the diagnostic reports it.

    An unreadable [health_state] resolves to [KH_offline] with a warning, not
    to a healthy-looking value: the reader could not tell, and a keeper that
    cannot be read is not a keeper that is fine. [source] names the caller in
    that warning. *)

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

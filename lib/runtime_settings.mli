(** Runtime_settings — typed runtime parameter declarations.

    Each parameter is registered with {!Runtime_params.register} at
    module load.  Public params expose the [_ Runtime_params.param]
    handle so callers reach values via [Runtime_params.get
    Runtime_settings.<param>].

    Surfaces (groups of related params published as a single
    runtime settings group, see {!surface}):

    - [board_policy] — message retention cap
    - [inference_config] — default model + timeout
    - [cost_policy] — per-session cost reporting threshold
    - [keeper_lifecycle] — heartbeat / supervisor / restart limits
    - [keeper_handoff] — handoff threshold / cooldown / pressure
    - [keeper_diagnostics] — snapshot / hb tuning / profiling ring
    - [drift_guard] — handoff drift classification thresholds
    - [keeper_turn] / [keeper_compaction] / [keeper_proactive] /
      [keeper_rules] — keeper LLM tuning surfaces
    - [dashboard] — display-only thresholds + truncation lengths

    Internal: 6 deserialization / validation helpers stay
    private — \[validate_float_range], \[validate_int_range],
    \[deserialize_float], \[deserialize_int],
    \[deserialize_string], \[deserialize_bool].  Plus 25+
    keeper.turn / keeper.compaction / keeper.proactive /
    keeper.rule param handles + \[message_max_count] +
    \[_cost_max_session_usd] + \[inference_timeout] are
    intentionally unexported — these are reachable only via
    {!Runtime_params.get_by_key} (runtime settings UI) and are pinned
    in the {!surfaces} catalog by string key. *)

(** {1 Inference} *)

val inference_default_model : string Runtime_params.param
(** Default LLM model label.  Validation: 1-100 chars. *)

(** {1 Keeper lifecycle} *)

val keeper_supervisor_sweep_sec : float Runtime_params.param
(** Supervisor sweep interval (seconds).  Range \[10.0, 120.0]. *)

val keeper_keepalive_interval_sec : int Runtime_params.param
(** Heartbeat interval (seconds).  Range \[5, 300]. *)

val keeper_dead_ttl_sec : float Runtime_params.param
(** Dead-state retention (seconds).  Range \[60.0, 1 day]. *)

(** {1 Keeper handoff} *)

val keeper_handoff_threshold : float Runtime_params.param
(** Default handoff context-ratio threshold.
    Range \[0.5, 0.99].  Default 0.85. *)

val keeper_handoff_cooldown_sec : int Runtime_params.param
(** Post-handoff suppression window (seconds).
    Range \[30, 3600].  Default 300. *)

val keeper_handoff_pressure_threshold : float Runtime_params.param
(** Context ratio above which handoff-pressure alert fires.
    Range \[0.5, 0.99].  Default 0.88. *)

(** {1 Keeper diagnostics} *)

val keeper_snapshot_sec : int Runtime_params.param
(** Snapshot capture interval (seconds).  Range \[15, 3600]. *)

val keeper_work_as_hb_enabled : bool Runtime_params.param
(** Enable work-as-heartbeat fallback. *)

val keeper_work_as_hb_max_silence_sec : float Runtime_params.param
(** Maximum silence allowed in work-as-heartbeat mode (seconds).
    Range \[10.0, 600.0]. *)

val keeper_stage_timing_ring_size : int Runtime_params.param
(** Stage-timing ring buffer size.  Applied on fiber restart only —
    runtime mutation requires keeper restart.  Range \[10, 1000]. *)

(** {1 Drift guard (uncalibrated)} *)

val drift_factual_coverage_floor : float Runtime_params.param
(** Token-coverage floor — handoffs below this are flagged as
    factual drift.  Range \[0.0, 1.0].  Default 0.55.  Initial
    estimate; not corpus-calibrated. *)

val drift_factual_size_ratio_floor : float Runtime_params.param
(** Size-ratio floor (handoff/original) — captures
    "content replaced" vs "content edited".  Range \[0.0, 1.0].
    Default 0.6. *)

val drift_structural_divergence_threshold : float Runtime_params.param
(** Cosine-jaccard divergence threshold for structural drift.
    Range \[0.0, 1.0].  Default 0.18. *)

(** {1 Dashboard rendering} *)

val dashboard_max_path_length : int Runtime_params.param
(** Path truncation cap (chars).  Range \[10, 200].  Default 30. *)

val dashboard_max_message_length : int Runtime_params.param
(** Message-body truncation cap (chars).  Range \[10, 500].
    Default 35. *)

val dashboard_max_pending_tasks : int Runtime_params.param
(** Pending-task display cap.  Range \[1, 50].  Default 5. *)

val dashboard_max_recent_messages : int Runtime_params.param
(** Recent-message display cap.  Range \[1, 50].  Default 5. *)

val dashboard_min_border_length : int Runtime_params.param
(** Section-border minimum length.  Range \[20, 200].  Default 45. *)

val dashboard_agent_quiet_threshold_sec : float Runtime_params.param
(** Quiet-agent-warning threshold (seconds).
    Range \[30.0, 1 day]. *)

val dashboard_agent_stuck_threshold_sec : float Runtime_params.param
(** Stuck-agent-warning threshold (seconds).
    Range \[60.0, 7 days]. *)

(** {1 Surface catalog} *)

type surface = {
  id : string;
  description : string;
  param_keys : string list;
}
(** Group of related runtime parameters. *)

val surfaces : surface list
(** [surfaces] is the catalog of runtime setting surfaces in
    registration order.  Used by the dashboard surfaces panel
    via {!surfaces_json} and by tests for invariant checks
    (every published key has a registered param). *)

(** {1 Initialization + JSON} *)

val ensure_init : unit -> unit
(** [ensure_init ()] forces module-load side effects so every
    param is registered before
    {!Runtime_params.restore} runs.  Called from server bootstrap.
    Touches each param via [Runtime_params.get] — drift here would
    leave some params unregistered, breaking restore. *)

val surfaces_json : unit -> Yojson.Safe.t
(** [surfaces_json ()] renders {!surfaces} as a JSON array for
    the dashboard surfaces endpoint. *)

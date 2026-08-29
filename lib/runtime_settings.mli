(** Runtime_settings — typed runtime parameter declarations.

    Each parameter is registered with {!Runtime_params.register} at
    module load.  Public params expose the [_ Runtime_params.param]
    handle so callers reach values via [Runtime_params.get
    Runtime_settings.<param>].

    Surfaces (groups of related params published as a single
    runtime settings group, see {!surface}):

    - [keeper_lifecycle] — heartbeat / supervisor / restart limits
    - [keeper_handoff] — handoff threshold / cooldown / pressure
    - [keeper_diagnostics] — snapshot / hb tuning / profiling ring
    - [keeper_turn] / [keeper_proactive] / [keeper_rules] — keeper LLM tuning surfaces
    - [dashboard] — display-only thresholds + truncation lengths

    Internal: the deserialization / validation helpers stay private,
    as do the 25+ keeper.turn / keeper.proactive / keeper.rule param
    handles — those are reachable through the runtime settings UI by
    string key and are pinned in the {!surfaces} catalog. *)

(** {1 Keeper lifecycle} *)

val keeper_supervisor_sweep_sec : float Runtime_params.param
(** Supervisor sweep interval (seconds).  Range \[10.0, 120.0\]. *)

val keeper_keepalive_interval_sec : int Runtime_params.param
(** Heartbeat interval (seconds). Any positive value is accepted without an
    implicit upper bound. *)

(** {1 Keeper diagnostics} *)

val keeper_snapshot_sec : int Runtime_params.param
(** Snapshot capture interval (seconds).  Range \[15, 3600\]. *)

val keeper_work_as_hb_enabled : bool Runtime_params.param
(** Enable work-as-heartbeat fallback. *)

val keeper_stage_timing_ring_size : int Runtime_params.param
(** Stage-timing ring buffer size.  Applied on fiber restart only —
    runtime mutation requires keeper restart.  Range \[10, 1000\]. *)

val keeper_chat_redact_identity_scalars : bool Runtime_params.param
(** Whether identity scalars (a [user:] login in a GitHub hosts.yml) mined
    from keeper secret files are masked as [REDACTED] in chat text and tool
    output. Credential-shaped values (tokens, passwords) are always masked;
    this switch governs only the identity half. *)

(** {1 Dashboard rendering} *)

val dashboard_max_path_length : int Runtime_params.param
(** Path truncation cap (chars).  Range \[10, 200\].  Default 30. *)

val dashboard_max_message_length : int Runtime_params.param
(** Message-body truncation cap (chars).  Range \[10, 500\].
    Default 35. *)

val dashboard_max_pending_tasks : int Runtime_params.param
(** Pending-task display cap.  Range \[1, 50\].  Default 5. *)

val dashboard_max_recent_messages : int Runtime_params.param
(** Recent-message display cap.  Range \[1, 50\].  Default 5. *)

val dashboard_min_border_length : int Runtime_params.param
(** Section-border minimum length.  Range \[20, 200\].  Default 45. *)

val dashboard_agent_quiet_threshold_sec : float Runtime_params.param
(** Quiet-agent-warning threshold (seconds).
    Range \[30.0, 1 day\]. *)

val dashboard_agent_stuck_threshold_sec : float Runtime_params.param
(** Stuck-agent-warning threshold (seconds).
    Range \[60.0, 7 days\]. *)

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

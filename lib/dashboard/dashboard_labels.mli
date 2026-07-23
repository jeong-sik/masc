(** Dashboard Labels — pure translation from raw states to operator-readable text.

    No side effects, no IO. All functions take raw values and return
    human-readable strings. This module has no dependency on Dashboard
    to break circular deps; [Dashboard] and [Dashboard_attention]
    both depend on it. *)

(** {1 Shared types}

    These break circular dependency between Dashboard subsystems. *)

(** Workspace snapshot shared between Dashboard and Dashboard_attention. *)
type workspace_snapshot = {
  workspace_id : string;
  agents : Masc_domain.agent list;
  tasks : Masc_domain.task list;
  messages : Masc_domain.message list;
  locks : int;
}

(** {1 Timestamp parsing}

    Parses dashboard timestamps to Unix time. Accepts canonical UTC,
    fractional-second RFC3339, numeric UTC offsets, and bare local
    timestamps from older read models. Returns [None] on any parse
    failure (empty / malformed / wrong-length). *)
val parse_iso_timestamp : string -> float option

(** [format_elapsed now timestamp fallback] renders the elapsed time
    since [timestamp] as ["Ns ago"] (<60s), ["Nm ago"] (<1h), or
    ["N.Nh ago"]. Returns [fallback] when parsing fails. *)
val format_elapsed : float -> string -> string -> string

(** {1 Agent status}

    Thresholds come from {!Runtime_params} /
    {!Runtime_settings.dashboard_agent_quiet_threshold_sec} and
    {!Runtime_settings.dashboard_agent_stuck_threshold_sec}. *)

(** Translate agent status + [last_seen_iso] into operator-readable text
    like ["working"], ["quiet (Nm)"], ["STUCK (Nm, needs check)"], etc. *)
val translate_agent_status :
  now:float -> Masc_domain.agent_status -> string -> string

(** Agent grouping for capacity / operator views.

    [Offline] (Inactive) is distinct from [Idle] (Listening) so
    downstream capacity logic does not treat offline agents as
    available. *)
type agent_group = Working | Stuck | Idle | Offline
[@@deriving eq]

(** Classify an agent using wall-clock [now] and the stuck threshold.
    [Active]/[Busy] past the threshold → [Stuck]; otherwise → [Working].
    [Listening] → [Idle]. [Inactive] → [Offline]. *)
val classify_agent : now:float -> Masc_domain.agent -> agent_group

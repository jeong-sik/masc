(** Behavioral Baseline & Anomaly Detection

    Builds per-agent behavioral profiles from audit_log entries and detects
    deviations using z-score thresholds. Profiles are persisted to disk so
    baselines survive restarts.

    Dimensions monitored:
    - activity_volume : actions per hour
    - tool_diversity  : unique tools / total tool calls (0..1)
    - token_volume    : mean token_count per action (if logged)
    - failure_rate    : fraction of actions with Failure outcome (0..1)
    - hourly_pattern  : max deviation from expected hourly activity distribution

    @since governance-stack Phase 3 *)

type stat =
  { mean : float
  ; stddev : float
  }

type behavioral_profile =
  { agent_id : string
  ; window_days : int
  ; sample_count : int
  ; activity_volume : stat
  ; tool_diversity : stat
  ; token_volume : stat option
  ; failure_rate : stat
  ; hourly_dist : float array
  ; updated_at : float
  }

type deviation =
  { dimension : string
  ; observed : float
  ; expected : float
  ; z_score : float
  ; severity : Governance_pipeline_types.risk_level
  }

type anomaly_report =
  { agent_id : string
  ; generated_at : float
  ; deviations : deviation list
  ; overall_risk : Governance_pipeline_types.risk_level
  }

(** Build a profile from the last [window_days] of audit_log entries for
    [agent_id]. Returns [None] when fewer than 3 samples exist — not enough
    for a meaningful stddev. *)
val build_profile
  :  config:Coord.config
  -> agent_id:string
  -> window_days:int
  -> behavioral_profile option

(** Persist a profile to [.masc/governance/baselines/<agent_id>.json]. *)
val save_profile : base_path:string -> behavioral_profile -> unit

(** Load a previously saved profile. Returns [None] if the file is missing
    or malformed. *)
val load_profile : base_path:string -> agent_id:string -> behavioral_profile option

(** Compare [entries] against [profile] and return deviations whose |z_score|
    exceeds the supplied [threshold]. Entries should be recent (e.g. last hour)
    for timely detection. *)
val detect_deviations
  :  profile:behavioral_profile
  -> entries:Audit_log.audit_entry list
  -> threshold:float
  -> deviation list

(** JSON projection for dashboard consumption. *)
val profile_json : behavioral_profile -> Yojson.Safe.t

(** JSON projection for dashboard consumption. *)
val report_json : anomaly_report -> Yojson.Safe.t

(** Convenience: read audit log, build or load profile, detect deviations,
    and return a report. [None] when the agent has no audit history. *)
val check_agent
  :  config:Coord.config
  -> agent_id:string
  -> window_days:int
  -> threshold:float
  -> anomaly_report option

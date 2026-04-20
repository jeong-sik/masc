(** Dashboard HTTP monitoring — tool-call health, board, and governance
    JSON builders for the dashboard server.

    Extracted from [server_dashboard_http.ml]. All builders are pure
    reads of on-disk stores ([Audit_log], board state, governance log)
    plus wall-clock time; no side effects apart from reading. *)

(** [tool_call_health_json ?now_ts config] aggregates [ToolCall] actions
    from the audit log within a 1-hour window, partitioned by outcome
    and per tool. [~now_ts] is injectable for tests (defaults to
    [Unix.gettimeofday ()]). *)
val tool_call_health_json :
  ?now_ts:float -> Coord.config -> Yojson.Safe.t

(** [board_monitoring_json ~now_ts] returns a JSON snapshot of the
    internal board plus a boolean [needs_attention] flag. *)
val board_monitoring_json : now_ts:float -> Yojson.Safe.t * bool

(** [governance_monitoring_json ~now_ts ~base_path] summarises governance
    state rooted at [base_path]. Second element is [needs_attention]
    (e.g. stale pending rulings). *)
val governance_monitoring_json :
  now_ts:float -> base_path:string -> Yojson.Safe.t * bool

(** Point-in-time slot occupancy / queue depth snapshot. *)
val slot_monitoring_json : unit -> Yojson.Safe.t

(** Per-executor outcome counts (success / failure / cancelled)
    aggregated from the audit log. *)
val executor_outcomes_json : Coord.config -> Yojson.Safe.t

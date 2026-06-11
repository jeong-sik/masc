(** Dashboard API types — ops iteration dashboard for keeper recovery tracking.

    Tracks recovery iteration cycles per keeper: how many recovery events
    have occurred, what errors triggered them, recovery resolution status,
    and aggregate statistics for the ops dashboard view.

    Served at [GET /dashboard/b/api/keepers/iteration] (projected).
    Server assembles response from {!Keeper_ops_iteration} ring buffer and
    ongoing keeper state. *)

(** Phase/status of one recovery iteration. *)
type recovery_phase =
  | Detecting    (* error detected, recovery triggered *)
  | Hinting      (* recovery hint generated *)
  | Retrying     (* retry in progress *)
  | Resolved     (* recovery succeeded *)
  | Escalated    (* recovery failed, escalated to operator *)
[@@deriving yojson]

(** One recorded recovery event. *)
type recovery_event = {
  id : string;                       (* unique event id *)
  keeper_name : string;              (* the recovering keeper *)
  phase : recovery_phase;
  error_hint : string option;        [@default None]
  error_message : string;            (* truncated original error *)
  tool_name : string option;         [@default None]
  started_at : string;               (* ISO-8601 UTC *)
  resolved_at : string option;       [@default None]
  duration_ms : int option;          [@default None]
}
[@@deriving yojson { strict = false }]

(** Aggregate stats for one keeper. *)
type keeper_recovery_stats = {
  name : string;
  total_recoveries : int;
  active_recoveries : int;           (* Detecting / Hinting / Retrying *)
  resolved_count : int;
  escalated_count : int;
  avg_duration_ms : int;             (* average ms to resolve *)
  top_error : string option;         [@default None]
  last_recovery_at : string option;  [@default None]
}
[@@deriving yojson { strict = false }]

(** Overall iteration summary for the workspace. *)
type iteration_summary = {
  total_events : int;
  active_events : int;
  resolved_events : int;
  escalated_events : int;
  global_avg_duration_ms : int;
}
[@@deriving yojson { strict = false }]

(** Top-level iteration response for the ops dashboard. *)
type response = {
  events : recovery_event list;
  keeper_stats : keeper_recovery_stats list;
  summary : iteration_summary;
  cycle : int;                      (* current cycle number — aligned with
                                       {!K summary} *)
  workspace : string option;             [@default None]
  generated_at : string;            (* ISO-8601 UTC *)
}
[@@deriving yojson { strict = false }]
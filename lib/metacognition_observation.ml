(** Metacognition_observation — deterministic observation layer for keeper behavior.

    Computes rate-based metrics from {!Keeper_exec_status_metrics.metrics_summary}
    to enable threshold-based alerting and dashboard display.

    All computations are pure and deterministic — no LLM calls.

    @since 2.158.0 *)

(** Observation snapshot for a single keeper. *)
type snapshot = {
  keeper_name : string;
  timestamp : float;
  (* ── Rate metrics (0.0–1.0) ─────────────────────── *)
  memory_success_rate : float;     (** passed / (passed + failed) *)
  guardrail_stop_rate : float;     (** stops / total turns *)
  avg_repetition_risk : float;     (** mean repetition risk score *)
  avg_goal_alignment : float;      (** mean goal alignment score *)
  avg_goal_drift : float;          (** mean goal drift score *)
  (* ── Count metrics ──────────────────────────────── *)
  total_turns : int;
  compaction_events : int;
  handoff_count : int;
}

let safe_rate num denom =
  if denom = 0 then 1.0  (* no data = assume healthy *)
  else Float.of_int num /. Float.of_int denom

let safe_avg sum points =
  if points = 0 then 0.0
  else sum /. Float.of_int points

(** Build an observation snapshot from a keeper's metrics summary. *)
let of_metrics ~keeper_name ~timestamp
    (m : Keeper_exec_status_metrics.metrics_summary) : snapshot =
  { keeper_name;
    timestamp;
    memory_success_rate = safe_rate m.memory_passed (m.memory_passed + m.memory_failed);
    guardrail_stop_rate =
      safe_rate m.guardrail_stop_count
        (m.turn_points + m.heartbeat_points + m.proactive_points);
    avg_repetition_risk = safe_avg m.repetition_risk_sum m.repetition_risk_points;
    avg_goal_alignment = safe_avg m.goal_alignment_sum m.goal_alignment_points;
    avg_goal_drift = safe_avg m.goal_drift_sum m.goal_drift_points;
    total_turns = m.turn_points;
    compaction_events = m.compaction_events;
    handoff_count = m.handoff_count;
  }

(** Serialize snapshot to JSON for dashboard/persistence. *)
let to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    ("keeper_name", `String s.keeper_name);
    ("timestamp", `Float s.timestamp);
    ("memory_success_rate", `Float s.memory_success_rate);
    ("guardrail_stop_rate", `Float s.guardrail_stop_rate);
    ("avg_repetition_risk", `Float s.avg_repetition_risk);
    ("avg_goal_alignment", `Float s.avg_goal_alignment);
    ("avg_goal_drift", `Float s.avg_goal_drift);
    ("total_turns", `Int s.total_turns);
    ("compaction_events", `Int s.compaction_events);
    ("handoff_count", `Int s.handoff_count);
  ]

[@@@coverage off]

let%test "safe_rate: zero denominator returns 1.0" =
  safe_rate 0 0 = 1.0

let%test "safe_rate: normal computation" =
  safe_rate 8 10 = 0.8

let%test "safe_avg: zero points returns 0.0" =
  safe_avg 5.0 0 = 0.0

let%test "of_metrics: snapshot from empty metrics" =
  let m = Keeper_exec_status_metrics.empty_metrics_summary in
  let s = of_metrics ~keeper_name:"test" ~timestamp:0.0 m in
  s.memory_success_rate = 1.0  (* no data = healthy *)
  && s.guardrail_stop_rate = 1.0
  && s.total_turns = 0

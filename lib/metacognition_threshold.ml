(** Metacognition_threshold — configurable threshold rules for keeper alerts.

    Evaluates observation snapshots against rules to produce alerts.
    All evaluation is deterministic — pure function of snapshot + rules.

    Rules support:
    - metric name (matches snapshot field)
    - operator (Lt = below threshold is bad, Gt = above threshold is bad)
    - threshold value
    - min_samples: minimum total_turns before rule activates
    - cooldown_sec: minimum time between alerts for same rule

    @since 2.158.0 *)

type operator = Lt | Gt

type rule = {
  name : string;
  metric : string;
  operator : operator;
  threshold : float;
  min_samples : int;
  cooldown_sec : float;
}

type alert = {
  rule_name : string;
  keeper_name : string;
  metric_name : string;
  actual_value : float;
  threshold : float;
  message : string;
  timestamp : float;
}

(** Extract a metric value from a snapshot by field name. *)
let metric_value (s : Metacognition_observation.snapshot) = function
  | "memory_success_rate" -> Some s.memory_success_rate
  | "guardrail_stop_rate" -> Some s.guardrail_stop_rate
  | "avg_repetition_risk" -> Some s.avg_repetition_risk
  | "avg_goal_alignment" -> Some s.avg_goal_alignment
  | "avg_goal_drift" -> Some s.avg_goal_drift
  | _ -> None

let check_threshold op actual threshold =
  match op with
  | Lt -> actual < threshold  (* e.g. success_rate < 0.7 is bad *)
  | Gt -> actual > threshold  (* e.g. guardrail_stop_rate > 0.3 is bad *)

(** Evaluate a single rule against a snapshot.
    Returns Some alert if the rule triggers, None otherwise.
    [last_alert_times] maps "keeper_name:rule_name" -> last alert timestamp
    for per-keeper cooldown tracking. *)
let evaluate_rule ~(last_alert_times : (string, float) Hashtbl.t)
    (s : Metacognition_observation.snapshot) (r : rule) : alert option =
  (* Check min_samples gate — also prevents false positives from safe_avg 0.0 defaults *)
  if s.total_turns < r.min_samples then None
  else
    match metric_value s r.metric with
    | None -> None  (* unknown metric, skip *)
    | Some actual ->
      if not (check_threshold r.operator actual r.threshold) then None
      else
        (* Check cooldown — keyed per keeper to avoid cross-keeper suppression *)
        let cooldown_key = Printf.sprintf "%s:%s" s.keeper_name r.name in
        let last_time = Hashtbl.find_opt last_alert_times cooldown_key
          |> Option.value ~default:0.0 in
        if s.timestamp -. last_time < r.cooldown_sec then None
        else begin
          Hashtbl.replace last_alert_times cooldown_key s.timestamp;
          let op_str = match r.operator with Lt -> "<" | Gt -> ">" in
          Some {
            rule_name = r.name;
            keeper_name = s.keeper_name;
            metric_name = r.metric;
            actual_value = actual;
            threshold = r.threshold;
            message = Printf.sprintf "[%s] %s: %s=%.3f %s %.3f"
              r.name s.keeper_name r.metric actual op_str r.threshold;
            timestamp = s.timestamp;
          }
        end

(** Evaluate all rules against a snapshot. Returns list of triggered alerts. *)
let evaluate ~last_alert_times
    (s : Metacognition_observation.snapshot) (rules : rule list) : alert list =
  List.filter_map (evaluate_rule ~last_alert_times s) rules

(** Serialize an alert to JSON. *)
let alert_to_json (a : alert) : Yojson.Safe.t =
  `Assoc [
    ("rule_name", `String a.rule_name);
    ("keeper_name", `String a.keeper_name);
    ("metric_name", `String a.metric_name);
    ("actual_value", `Float a.actual_value);
    ("threshold", `Float a.threshold);
    ("message", `String a.message);
    ("timestamp", `Float a.timestamp);
  ]

(* ── Default rules ─────────────────────────────────── *)

let default_rules = [
  { name = "memory_failure_high";
    metric = "memory_success_rate";
    operator = Lt;
    threshold = 0.7;
    min_samples = 5;
    cooldown_sec = 600.0;  (* 10 min *)
  };
  { name = "guardrail_stops_high";
    metric = "guardrail_stop_rate";
    operator = Gt;
    threshold = 0.3;
    min_samples = 5;
    cooldown_sec = 600.0;
  };
  { name = "repetition_risk_high";
    metric = "avg_repetition_risk";
    operator = Gt;
    threshold = 0.6;
    min_samples = 3;
    cooldown_sec = 900.0;  (* 15 min *)
  };
  { name = "goal_drift_high";
    metric = "avg_goal_drift";
    operator = Gt;
    threshold = 0.5;
    min_samples = 5;
    cooldown_sec = 900.0;
  };
]

[@@@coverage off]

let%test "evaluate: no alerts when below min_samples" =
  let s = Metacognition_observation.of_metrics
    ~keeper_name:"test" ~timestamp:1.0
    Keeper_exec_status_metrics.empty_metrics_summary in
  let tbl = Hashtbl.create 4 in
  evaluate ~last_alert_times:tbl s default_rules = []

let%test "evaluate: triggers on bad memory rate" =
  let m = { Keeper_exec_status_metrics.empty_metrics_summary with
    turn_points = 10;
    memory_passed = 3;
    memory_failed = 7;
  } in
  let s = Metacognition_observation.of_metrics
    ~keeper_name:"bad-keeper" ~timestamp:100.0 m in
  let tbl = Hashtbl.create 4 in
  let alerts = evaluate ~last_alert_times:tbl s default_rules in
  List.exists (fun a -> a.rule_name = "memory_failure_high") alerts

let%test "evaluate: cooldown prevents duplicate alerts" =
  let m = { Keeper_exec_status_metrics.empty_metrics_summary with
    turn_points = 10;
    memory_passed = 2;
    memory_failed = 8;
  } in
  let tbl = Hashtbl.create 4 in
  let s1 = Metacognition_observation.of_metrics
    ~keeper_name:"k" ~timestamp:100.0 m in
  let _a1 = evaluate ~last_alert_times:tbl s1 default_rules in
  (* Second evaluation within cooldown *)
  let s2 = Metacognition_observation.of_metrics
    ~keeper_name:"k" ~timestamp:200.0 m in
  let a2 = evaluate ~last_alert_times:tbl s2 default_rules in
  not (List.exists (fun a -> a.rule_name = "memory_failure_high") a2)

let%test "evaluate: cooldown is per-keeper (no cross-keeper suppression)" =
  let m = { Keeper_exec_status_metrics.empty_metrics_summary with
    turn_points = 10;
    memory_passed = 2;
    memory_failed = 8;
  } in
  let tbl = Hashtbl.create 4 in
  let s_a = Metacognition_observation.of_metrics
    ~keeper_name:"keeper-a" ~timestamp:100.0 m in
  let _alerts_a = evaluate ~last_alert_times:tbl s_a default_rules in
  (* keeper-b should still alert despite keeper-a's cooldown *)
  let s_b = Metacognition_observation.of_metrics
    ~keeper_name:"keeper-b" ~timestamp:150.0 m in
  let alerts_b = evaluate ~last_alert_times:tbl s_b default_rules in
  List.exists (fun a -> a.rule_name = "memory_failure_high") alerts_b

(** Dashboard Labels unit tests *)

module Lib = Masc_mcp

(* ===== Agent Status Translation ===== *)

(** Helper: create an ISO timestamp string and matching [now] value.
    Returns (now_float, iso_string) where now_float is [seconds_from_now] later
    than the timestamp, using parse_iso_timestamp for consistency. *)
let make_timestamp_pair seconds_ago =
  let base = Unix.gettimeofday () in
  let tm = Unix.localtime base in
  let now_iso =
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  (* Use parse_iso_timestamp for now to ensure consistent timezone handling *)
  let now =
    match Lib.Dashboard_labels.parse_iso_timestamp now_iso with
    | Some t -> t
    | None -> base
  in
  let past = Unix.localtime (base -. seconds_ago) in
  let past_iso =
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (past.Unix.tm_year + 1900) (past.Unix.tm_mon + 1) past.Unix.tm_mday
      past.Unix.tm_hour past.Unix.tm_min past.Unix.tm_sec
  in
  (now, past_iso)

let test_working_agent () =
  let (now, recent_iso) = make_timestamp_pair 60.0 in
  let result =
    Lib.Dashboard_labels.translate_agent_status ~now Types.Active recent_iso
  in
  Alcotest.(check string) "active+recent = working" "working" result

let test_stuck_agent () =
  let (now, old_iso) = make_timestamp_pair 1200.0 in (* 20 minutes ago *)
  let result =
    Lib.Dashboard_labels.translate_agent_status ~now Types.Active old_iso
  in
  Alcotest.(check bool) "stuck agent contains STUCK" true
    (try
       ignore (Str.search_forward (Str.regexp_string "STUCK") result 0);
       true
     with Not_found -> false)

let test_parse_iso_timestamp_matches_canonical_utc () =
  let ts = "2026-04-08T12:38:15Z" in
  match
    Lib.Dashboard_labels.parse_iso_timestamp ts,
    Types.parse_iso8601_opt ts
  with
  | Some actual, Some expected ->
      Alcotest.(check bool) "dashboard parser matches canonical UTC parser" true
        (abs_float (actual -. expected) < 0.001)
  | _ -> Alcotest.fail "expected both parsers to accept UTC timestamp"

let test_idle_agent () =
  let now = Unix.gettimeofday () in
  let result =
    Lib.Dashboard_labels.translate_agent_status ~now Types.Listening
      "2026-01-01T00:00:00Z"
  in
  Alcotest.(check string) "listening = idle" "idle" result

let test_offline_agent () =
  let now = Unix.gettimeofday () in
  let result =
    Lib.Dashboard_labels.translate_agent_status ~now Types.Inactive
      "2026-01-01T00:00:00Z"
  in
  Alcotest.(check string) "inactive = offline" "offline" result

(* ===== Lane Status Translation ===== *)

let test_lane_running () =
  let result =
    Lib.Dashboard_labels.translate_lane_status ~phase:"executing"
      ~motion_state:"moving" ~age:"5m ago"
  in
  Alcotest.(check string) "executing/moving" "Running (last 5m ago)" result

let test_lane_stalled () =
  let result =
    Lib.Dashboard_labels.translate_lane_status ~phase:"executing"
      ~motion_state:"stalled" ~age:"10m ago"
  in
  Alcotest.(check string) "executing/stalled" "STALLED - no progress" result

let test_lane_blocked () =
  let result =
    Lib.Dashboard_labels.translate_lane_status ~phase:"awaiting_approval"
      ~motion_state:"waiting" ~age:"5m ago"
  in
  Alcotest.(check string) "awaiting_approval"
    "BLOCKED - needs your approval" result

let test_lane_done () =
  let result =
    Lib.Dashboard_labels.translate_lane_status ~phase:"completed"
      ~motion_state:"terminal" ~age:"n/a"
  in
  Alcotest.(check string) "completed" "Done" result

(* ===== Flag Code Translation ===== *)

let test_flag_approval () =
  let result =
    Lib.Dashboard_labels.translate_flag_code "pending_manual_confirmation"
  in
  Alcotest.(check string) "approval flag" "Waiting for your approval" result

let test_flag_unknown () =
  let result = Lib.Dashboard_labels.translate_flag_code "some_new_flag" in
  Alcotest.(check string) "unknown passthrough" "some_new_flag" result

let test_flag_duration () =
  let result =
    Lib.Dashboard_labels.translate_flag_code "duration_reached"
  in
  Alcotest.(check string) "duration flag" "Time limit reached" result

(* ===== Health Verdict ===== *)

let test_health_no_lanes () =
  let result = Lib.Dashboard_labels.health_verdict [] in
  Alcotest.(check string) "no lanes" "No active lanes" result

let test_health_all_moving () =
  let lanes =
    [
      Lib.Dashboard_labels.
        {
          label = "test";
          present = true;
          phase = "executing";
          motion_state = "moving";
          age = "5m ago";
          current_step = "step";
          hard_flags = [];
        };
    ]
  in
  let result = Lib.Dashboard_labels.health_verdict lanes in
  Alcotest.(check bool) "healthy verdict" true
    (try
       ignore
         (Str.search_forward (Str.regexp_string "running") result 0);
       true
     with Not_found -> false)

let test_health_with_stalled () =
  let lanes =
    [
      Lib.Dashboard_labels.
        {
          label = "test";
          present = true;
          phase = "executing";
          motion_state = "stalled";
          age = "10m ago";
          current_step = "step";
          hard_flags = [];
        };
    ]
  in
  let result = Lib.Dashboard_labels.health_verdict lanes in
  Alcotest.(check bool) "needs attention" true
    (try
       ignore
         (Str.search_forward (Str.regexp_string "needs attention") result 0);
       true
     with Not_found -> false)

(** A lane that is both stalled (motion_state) and blocked (phase)
    should only be counted once in the attention count. *)
let test_health_stalled_blocked_no_double_count () =
  let lanes =
    [
      Lib.Dashboard_labels.
        {
          label = "lane-1";
          present = true;
          phase = "blocked";
          motion_state = "stalled";
          age = "10m ago";
          current_step = "step";
          hard_flags = [];
        };
    ]
  in
  let result = Lib.Dashboard_labels.health_verdict lanes in
  Alcotest.(check string) "1 lane, 1 needs attention"
    "1 lane active, 1 needs attention" result

(* ===== Agent Classification ===== *)

let test_classify_inactive_is_offline () =
  let now = Unix.gettimeofday () in
  let agent : Types.agent =
    {
      name = "test-agent";
      agent_type = "test";
      status = Types.Inactive;
      capabilities = [];
      current_task = None;
      joined_at = "2026-01-01T00:00:00Z";
      last_seen = "2026-01-01T00:00:00Z";
      meta = None;
    }
  in
  let group = Lib.Dashboard_labels.classify_agent ~now agent in
  Alcotest.(check bool) "inactive = Offline, not Idle" true
    (Lib.Dashboard_labels.equal_agent_group group Lib.Dashboard_labels.Offline)

let test_classify_listening_is_idle () =
  let now = Unix.gettimeofday () in
  let agent : Types.agent =
    {
      name = "test-agent";
      agent_type = "test";
      status = Types.Listening;
      capabilities = [];
      current_task = None;
      joined_at = "2026-01-01T00:00:00Z";
      last_seen = "2026-01-01T00:00:00Z";
      meta = None;
    }
  in
  let group = Lib.Dashboard_labels.classify_agent ~now agent in
  Alcotest.(check bool) "listening = Idle" true
    (Lib.Dashboard_labels.equal_agent_group group Lib.Dashboard_labels.Idle)

(* ===== Attention Items ===== *)

let test_attention_empty () =
  let now = Unix.gettimeofday () in
  let items =
    Lib.Dashboard_attention.collect ~now []
      (`Assoc [ ("lanes", `List []) ])
  in
  Alcotest.(check int) "no items" 0 (List.length items)

let test_attention_compact_empty () =
  let result = Lib.Dashboard_attention.compact_summary [] in
  Alcotest.(check string) "no action" "No action needed" result

(* ===== Test Suite ===== *)

let () =
  Alcotest.run "Dashboard Labels"
    [
      ( "Agent Status",
        [
          ("working agent", `Quick, test_working_agent);
          ("stuck agent", `Quick, test_stuck_agent);
          ("utc parser matches canonical", `Quick, test_parse_iso_timestamp_matches_canonical_utc);
          ("idle agent", `Quick, test_idle_agent);
          ("offline agent", `Quick, test_offline_agent);
        ] );
      ( "Lane Status",
        [
          ("running lane", `Quick, test_lane_running);
          ("stalled lane", `Quick, test_lane_stalled);
          ("blocked lane", `Quick, test_lane_blocked);
          ("done lane", `Quick, test_lane_done);
        ] );
      ( "Flag Codes",
        [
          ("approval flag", `Quick, test_flag_approval);
          ("unknown flag", `Quick, test_flag_unknown);
          ("duration flag", `Quick, test_flag_duration);
        ] );
      ( "Health Verdict",
        [
          ("no lanes", `Quick, test_health_no_lanes);
          ("all moving", `Quick, test_health_all_moving);
          ("with stalled", `Quick, test_health_with_stalled);
          ("stalled+blocked no double count", `Quick, test_health_stalled_blocked_no_double_count);
        ] );
      ( "Agent Classification",
        [
          ("inactive is Offline", `Quick, test_classify_inactive_is_offline);
          ("listening is Idle", `Quick, test_classify_listening_is_idle);
        ] );
      ( "Attention",
        [
          ("empty attention", `Quick, test_attention_empty);
          ("compact empty", `Quick, test_attention_compact_empty);
        ] );
    ]

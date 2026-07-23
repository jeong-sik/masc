module Types = Masc_domain

(** Dashboard Labels unit tests *)

module Lib = Masc

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
    match Dashboard_labels.parse_iso_timestamp now_iso with
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

let with_dashboard_label_thresholds ?quiet ?stuck f =
  let set_or_fail param value =
    match Lib.Runtime_params.set param value with
    | Ok () -> ()
    | Error msg -> Alcotest.fail msg
  in
  Fun.protect
    ~finally:(fun () ->
      Option.iter
        (fun _ ->
          Lib.Runtime_params.clear
            Lib.Runtime_settings.dashboard_agent_quiet_threshold_sec)
        quiet;
      Option.iter
        (fun _ ->
          Lib.Runtime_params.clear
            Lib.Runtime_settings.dashboard_agent_stuck_threshold_sec)
        stuck)
    (fun () ->
      Option.iter
        (set_or_fail Lib.Runtime_settings.dashboard_agent_quiet_threshold_sec)
        quiet;
      Option.iter
        (set_or_fail Lib.Runtime_settings.dashboard_agent_stuck_threshold_sec)
        stuck;
      f ())

let test_working_agent () =
  let (now, recent_iso) = make_timestamp_pair 60.0 in
  let result =
    Dashboard_labels.translate_agent_status ~now Masc_domain.Active recent_iso
  in
  Alcotest.(check string) "active+recent = working" "working" result

let test_quiet_threshold_override () =
  with_dashboard_label_thresholds ~quiet:30.0 ~stuck:900.0 @@ fun () ->
  let (now, quiet_iso) = make_timestamp_pair 60.0 in
  let result =
    Dashboard_labels.translate_agent_status ~now Masc_domain.Active quiet_iso
  in
  Alcotest.(check bool) "override surfaces quiet warning" true
    (try
       ignore (Str.search_forward (Str.regexp_string "quiet") result 0);
       true
     with Not_found -> false)

let test_stuck_agent () =
  let (now, old_iso) = make_timestamp_pair 1200.0 in (* 20 minutes ago *)
  let result =
    Dashboard_labels.translate_agent_status ~now Masc_domain.Active old_iso
  in
  Alcotest.(check bool) "stuck agent contains STUCK" true
    (try
       ignore (Str.search_forward (Str.regexp_string "STUCK") result 0);
       true
     with Not_found -> false)

let test_stuck_threshold_override () =
  with_dashboard_label_thresholds ~quiet:300.0 ~stuck:60.0 @@ fun () ->
  let (now, stuck_iso) = make_timestamp_pair 120.0 in
  let result =
    Dashboard_labels.translate_agent_status ~now Masc_domain.Busy stuck_iso
  in
  Alcotest.(check bool) "override surfaces stuck warning" true
    (try
       ignore (Str.search_forward (Str.regexp_string "STUCK") result 0);
       true
     with Not_found -> false)

let test_parse_iso_timestamp_matches_canonical_utc () =
  let ts = "2026-04-08T12:38:15Z" in
  match
    Dashboard_labels.parse_iso_timestamp ts,
    Masc_domain.parse_iso8601_opt ts
  with
  | Some actual, Some expected ->
      Alcotest.(check bool) "dashboard parser matches canonical UTC parser" true
        (abs_float (actual -. expected) < 0.001)
  | _ -> Alcotest.fail "expected both parsers to accept UTC timestamp"

let test_parse_iso_timestamp_fractional_utc_normalizes () =
  let ts = "2026-04-08T12:38:15.123Z" in
  match
    Dashboard_labels.parse_iso_timestamp ts,
    Masc_domain.parse_iso8601_opt "2026-04-08T12:38:15Z"
  with
  | Some actual, Some expected ->
      Alcotest.(check bool) "fractional UTC keeps sub-second precision" true
        (abs_float (actual -. (expected +. 0.123)) < 0.001)
  | _ ->
      Alcotest.fail
        "expected dashboard parser to preserve fractional UTC timestamp"

let test_parse_iso_timestamp_offset_matches_utc () =
  let ts = "2026-04-08T21:38:15+09:00" in
  match
    Dashboard_labels.parse_iso_timestamp ts,
    Masc_domain.parse_iso8601_opt "2026-04-08T12:38:15Z"
  with
  | Some actual, Some expected ->
      Alcotest.(check bool) "numeric offset normalizes to UTC" true
        (abs_float (actual -. expected) < 0.001)
  | _ -> Alcotest.fail "expected dashboard parser to accept timezone offsets"

let test_parse_iso_timestamp_fractional_offset_matches_utc () =
  let ts = "2026-04-08T21:38:15.250+09:00" in
  match
    Dashboard_labels.parse_iso_timestamp ts,
    Masc_domain.parse_iso8601_opt "2026-04-08T12:38:15Z"
  with
  | Some actual, Some expected ->
      Alcotest.(check bool) "fractional offset keeps sub-second precision" true
        (abs_float (actual -. (expected +. 0.250)) < 0.001)
  | _ ->
      Alcotest.fail
        "expected dashboard parser to preserve fractional timezone offsets"

let test_parse_iso_timestamp_local_without_timezone_is_supported () =
  let ts = "2026-04-08T12:38:15.125" in
  match Dashboard_labels.parse_iso_timestamp ts with
  | Some actual ->
      let tm =
        {
          Unix.tm_sec = 15;
          tm_min = 38;
          tm_hour = 12;
          tm_mday = 8;
          tm_mon = 3;
          tm_year = 126;
          tm_wday = 0;
          tm_yday = 0;
          tm_isdst = false;
        }
      in
      let expected, _ = Unix.mktime tm in
      Alcotest.(check bool) "bare local timestamps stay parseable" true
        (abs_float (actual -. (expected +. 0.125)) < 0.001)
  | None ->
      Alcotest.fail "expected dashboard parser to accept bare local timestamps"

let test_parse_iso_timestamp_empty_rejected () =
  Alcotest.(check (option (float 0.001))) "empty timestamps are rejected" None
    (Dashboard_labels.parse_iso_timestamp "")

let test_parse_iso_timestamp_garbage_rejected () =
  Alcotest.(check (option (float 0.001))) "garbage timestamps are rejected" None
    (Dashboard_labels.parse_iso_timestamp "garbage")

let test_parse_iso_timestamp_partial_rejected () =
  Alcotest.(check (option (float 0.001))) "partial timestamps are rejected" None
    (Dashboard_labels.parse_iso_timestamp "2026-04-08")

let test_idle_agent () =
  let now = Unix.gettimeofday () in
  let result =
    Dashboard_labels.translate_agent_status ~now Masc_domain.Listening
      "2026-01-01T00:00:00Z"
  in
  Alcotest.(check string) "listening = idle" "idle" result

let test_offline_agent () =
  let now = Unix.gettimeofday () in
  let result =
    Dashboard_labels.translate_agent_status ~now Masc_domain.Inactive
      "2026-01-01T00:00:00Z"
  in
  Alcotest.(check string) "inactive = offline" "offline" result

(* ===== Agent Classification ===== *)

let test_classify_inactive_is_offline () =
  let now = Unix.gettimeofday () in
  let agent : Masc_domain.agent =
    {
      id = None;
      name = "test-agent";
      agent_type = "test";
      status = Masc_domain.Inactive;
      capabilities = [];
      current_task = None;
      session_bound_at = "2026-01-01T00:00:00Z";
      last_seen = "2026-01-01T00:00:00Z";
      meta = None;
    }
  in
  let group = Dashboard_labels.classify_agent ~now agent in
  Alcotest.(check bool) "inactive = Offline, not Idle" true
    (Dashboard_labels.equal_agent_group group Dashboard_labels.Offline)

let test_classify_listening_is_idle () =
  let now = Unix.gettimeofday () in
  let agent : Masc_domain.agent =
    {
      id = None;
      name = "test-agent";
      agent_type = "test";
      status = Masc_domain.Listening;
      capabilities = [];
      current_task = None;
      session_bound_at = "2026-01-01T00:00:00Z";
      last_seen = "2026-01-01T00:00:00Z";
      meta = None;
    }
  in
  let group = Dashboard_labels.classify_agent ~now agent in
  Alcotest.(check bool) "listening = Idle" true
    (Dashboard_labels.equal_agent_group group Dashboard_labels.Idle)

let test_classify_uses_stuck_threshold_override () =
  with_dashboard_label_thresholds ~stuck:60.0 @@ fun () ->
  let (now, stuck_iso) = make_timestamp_pair 120.0 in
  let agent : Masc_domain.agent =
    {
      id = None;
      name = "test-agent";
      agent_type = "test";
      status = Masc_domain.Active;
      capabilities = [];
      current_task = None;
      session_bound_at = "2026-01-01T00:00:00Z";
      last_seen = stuck_iso;
      meta = None;
    }
  in
  let group = Dashboard_labels.classify_agent ~now agent in
  Alcotest.(check bool) "active can classify as Stuck via override" true
    (Dashboard_labels.equal_agent_group group Dashboard_labels.Stuck)

(* ===== Attention Items ===== *)

let test_attention_empty () =
  let now = Unix.gettimeofday () in
  let items =
    Dashboard_attention.collect ~now []
  in
  Alcotest.(check int) "no items" 0 (List.length items)

let test_attention_compact_empty () =
  let result = Dashboard_attention.compact_summary [] in
  Alcotest.(check string) "no action" "No action needed" result

(* ===== Test Suite ===== *)

let () =
  Alcotest.run "Dashboard Labels"
    [
      ( "Agent Status",
        [
          ("working agent", `Quick, test_working_agent);
          ("quiet threshold override", `Quick, test_quiet_threshold_override);
          ("stuck agent", `Quick, test_stuck_agent);
          ("stuck threshold override", `Quick, test_stuck_threshold_override);
          ("utc parser matches canonical", `Quick, test_parse_iso_timestamp_matches_canonical_utc);
          ("fractional utc normalizes", `Quick, test_parse_iso_timestamp_fractional_utc_normalizes);
          ("numeric offset normalizes", `Quick, test_parse_iso_timestamp_offset_matches_utc);
          ("fractional offset normalizes", `Quick,
            test_parse_iso_timestamp_fractional_offset_matches_utc);
          ("bare local timestamp", `Quick,
            test_parse_iso_timestamp_local_without_timezone_is_supported);
          ("empty timestamp rejected", `Quick,
            test_parse_iso_timestamp_empty_rejected);
          ("garbage timestamp rejected", `Quick,
            test_parse_iso_timestamp_garbage_rejected);
          ("partial timestamp rejected", `Quick,
            test_parse_iso_timestamp_partial_rejected);
          ("idle agent", `Quick, test_idle_agent);
          ("offline agent", `Quick, test_offline_agent);
        ] );
      ( "Agent Classification",
        [
          ("inactive is Offline", `Quick, test_classify_inactive_is_offline);
          ("listening is Idle", `Quick, test_classify_listening_is_idle);
          ("stuck override applied", `Quick, test_classify_uses_stuck_threshold_override);
        ] );
      ( "Attention",
        [
          ("empty attention", `Quick, test_attention_empty);
          ("compact empty", `Quick, test_attention_compact_empty);
        ] );
    ]

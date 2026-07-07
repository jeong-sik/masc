open Alcotest

module CB = Masc.Keeper_failure_circuit_breaker
module KSR = Masc.Keeper_tool_shared_runtime
module KAP = Masc.Keeper_alerting_path
module PCE = Keeper_path_check_error

let path_not_found_msg raw =
  KAP.rejection_to_user_message (KAP.Not_found_relative { raw })
;;

let path_not_allowed_msg raw =
  KAP.rejection_to_user_message (KAP.Outside_sandbox { raw })
;;

let json_error error = Yojson.Safe.to_string (`Assoc [ "ok", `Bool false; "error", `String error ])

let contains haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  if nl > hl then false
  else
    let rec scan i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else scan (i + 1)
    in scan 0

let test_classify_path_not_found () =
  check bool "path_not_found from prefix" true
    (CB.classify_error (path_not_found_msg "/foo") = CB.Path_not_found);
  check bool "path_not_found from JSON error field" true
    (CB.classify_error (json_error (path_not_found_msg "/foo")) = CB.Path_not_found);
  check bool "path_not_found from NSFD" true
    (CB.classify_error "No such file or directory" = CB.Path_not_found)

let test_classify_path_not_allowed () =
  check bool "path_not_allowed from typed rejection" true
    (CB.classify_error (path_not_allowed_msg "/x") = CB.Path_not_allowed);
  check bool "path_not_allowed from JSON error field" true
    (CB.classify_error (json_error (path_not_allowed_msg "/x")) = CB.Path_not_allowed);
  check bool "outside project root is path_not_allowed" true
    (CB.classify_error
       (KAP.rejection_to_user_message (KAP.Outside_project_root { raw = "../x" }))
     = CB.Path_not_allowed);
  check bool "legacy path_not_in_allowed no longer drives KCB" true
    (CB.classify_error "path_not_in_allowed_paths: /x" = CB.Other)

let test_classify_typed_path_check_prefixes () =
  let cwd_msg =
    PCE.to_message (PCE.Cwd_not_directory { path = ".worktrees/missing"; hint = None })
  in
  check bool "typed cwd_not_directory prefix" true
    (CB.classify_error cwd_msg = CB.Cwd_not_directory);
  let blocked_msg =
    PCE.to_message
      (PCE.Path_outside_whitelist
         { path = "/etc/passwd"; for_keeper_command = true })
  in
  check bool "typed path blocked prefix" true
    (CB.classify_error blocked_msg = CB.Path_not_allowed)

let test_classify_other () =
  check bool "other" true
    (CB.classify_error "random error" = CB.Other)

let test_no_hint_under_threshold () =
  CB.record_success ~keeper_name:"t1";
  let r1 = CB.maybe_enrich_error ~keeper_name:"t1" ~error_msg:(path_not_found_msg "/a") in
  check bool "1st: no hint" true (not (contains r1 "CIRCUIT BREAKER"));
  let r2 = CB.maybe_enrich_error ~keeper_name:"t1" ~error_msg:(path_not_found_msg "/b") in
  check bool "2nd: no hint" true (not (contains r2 "CIRCUIT BREAKER"))

let test_hint_at_threshold () =
  CB.record_success ~keeper_name:"t2";
  ignore (CB.maybe_enrich_error ~keeper_name:"t2" ~error_msg:(path_not_found_msg "/a"));
  ignore (CB.maybe_enrich_error ~keeper_name:"t2" ~error_msg:(path_not_found_msg "/b"));
  let r3 = CB.maybe_enrich_error ~keeper_name:"t2" ~error_msg:(path_not_found_msg "/c") in
  check bool "3rd: HAS hint" true (contains r3 "CIRCUIT BREAKER");
  check bool "mentions playground" true (contains r3 "playground");
  check bool "mentions visible path inspection" true
    (contains r3 "Inspect visible paths");
  check bool "does not mention Execute" false (contains r3 "Execute");
  check bool "does not invent Grep op syntax" false (contains r3 "Grep op=")

let test_actionable_path_not_found_hint () =
  let action =
    KSR.actionable_path_action_for_class
      ~playground:".masc/playground/taskmaster/"
      ~raw_path:"repos/masc/.worktrees/task-676/lib"
      CB.Path_not_found
  in
  check bool "mentions visible path inspection" true
    (contains action "Inspect visible paths");
  check bool "mentions task/context tools for .masc" true
    (contains action "keeper task/context tools");
  check bool "does not mention Execute" false (contains action "Execute");
  check bool "does not invent Grep op syntax" false (contains action "Grep op=")

let test_reset_on_success () =
  CB.record_success ~keeper_name:"t3";
  ignore (CB.maybe_enrich_error ~keeper_name:"t3" ~error_msg:(path_not_found_msg "/a"));
  ignore (CB.maybe_enrich_error ~keeper_name:"t3" ~error_msg:(path_not_found_msg "/b"));
  CB.record_success ~keeper_name:"t3";
  let r = CB.maybe_enrich_error ~keeper_name:"t3" ~error_msg:(path_not_found_msg "/c") in
  check bool "after reset: no hint" true (not (contains r "CIRCUIT BREAKER"))

let test_class_change_resets () =
  ignore (CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:(path_not_found_msg "/a"));
  ignore (CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:(path_not_found_msg "/b"));
  ignore (CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:(path_not_allowed_msg "/x"));
  let r = CB.maybe_enrich_error ~keeper_name:"t4" ~error_msg:(path_not_allowed_msg "/y") in
  check bool "class switch: no hint at 2nd" true (not (contains r "CIRCUIT BREAKER"))

let test_snapshot () =
  ignore (CB.maybe_enrich_error ~keeper_name:"t5" ~error_msg:(path_not_found_msg "/a"));
  match CB.snapshot_json () with
  | `List entries -> check bool "has entries" true (List.length entries > 0)
  | _ -> Alcotest.fail "expected list"

(* ── LT-16-KCB Phase 1: display_state classifier ─────────────── *)

let display_state_str = function
  | CB.Clean -> "clean"
  | CB.Warning -> "warning"
  | CB.Cooling -> "cooling"

let test_display_state_clean () =
  let s = CB.derive_display_state ~consecutive_count:0 ~total_tripped:0 in
  check string "fresh state is clean" "clean" (display_state_str s);
  check string "to_string agrees" "clean" (CB.display_state_to_string s)

let test_display_state_warning () =
  let s1 = CB.derive_display_state ~consecutive_count:1 ~total_tripped:0 in
  let s2 = CB.derive_display_state ~consecutive_count:2 ~total_tripped:0 in
  (* count > 0 dominates total_tripped: warning takes precedence over cooling *)
  let s3 = CB.derive_display_state ~consecutive_count:1 ~total_tripped:5 in
  check string "count=1 is warning" "warning" (display_state_str s1);
  check string "count=2 is warning" "warning" (display_state_str s2);
  check string "count>0 shadows trips" "warning" (display_state_str s3)

let test_display_state_cooling () =
  let s = CB.derive_display_state ~consecutive_count:0 ~total_tripped:1 in
  check string "count=0 but trips>0 is cooling" "cooling" (display_state_str s);
  let s2 = CB.derive_display_state ~consecutive_count:0 ~total_tripped:42 in
  check string "many trips, count=0 is cooling" "cooling" (display_state_str s2)

let test_classify_snapshot_json_happy () =
  let json : Yojson.Safe.t = `List [
    `Assoc [
      "keeper", `String "alpha";
      "consecutive_class", `String "path_not_found";
      "consecutive_count", `Int 0;
      "total_tripped", `Int 0;
    ];
    `Assoc [
      "keeper", `String "beta";
      "consecutive_class", `String "other";
      "consecutive_count", `Int 2;
      "total_tripped", `Int 0;
    ];
    `Assoc [
      "keeper", `String "gamma";
      "consecutive_class", `String "path_not_found";
      "consecutive_count", `Int 0;
      "total_tripped", `Int 3;
    ];
  ] in
  match CB.classify_snapshot_json json with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok assoc ->
    check int "three entries parsed" 3 (List.length assoc);
    check string "alpha=clean" "clean"
      (display_state_str (List.assoc "alpha" assoc));
    check string "beta=warning" "warning"
      (display_state_str (List.assoc "beta" assoc));
    check string "gamma=cooling" "cooling"
      (display_state_str (List.assoc "gamma" assoc))

let test_classify_snapshot_skips_malformed () =
  let json : Yojson.Safe.t = `List [
    `Assoc [
      "keeper", `String "good";
      "consecutive_count", `Int 0;
      "total_tripped", `Int 0;
    ];
    `Assoc [
      "keeper", `String "bad-no-count";
      "total_tripped", `Int 0;
    ];
    `String "completely malformed";
  ] in
  match CB.classify_snapshot_json json with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok assoc ->
    check int "only 'good' survives" 1 (List.length assoc);
    check bool "good is present" true (List.mem_assoc "good" assoc);
    check bool "malformed is skipped" false (List.mem_assoc "bad-no-count" assoc)

let test_classify_snapshot_not_a_list () =
  match CB.classify_snapshot_json (`Assoc [("x", `Int 1)]) with
  | Ok _ -> Alcotest.fail "should have errored"
  | Error msg ->
    check bool "error mentions expected shape" true
      (contains msg "array")

let test_classify_snapshot_round_trip () =
  (* Force a keeper with count>0 into the real state, snapshot, classify. *)
  CB.record_success ~keeper_name:"rt1";
  ignore (CB.maybe_enrich_error
            ~keeper_name:"rt1" ~error_msg:(path_not_found_msg "/x"));
  let json = CB.snapshot_json () in
  match CB.classify_snapshot_json json with
  | Error msg -> Alcotest.fail ("round-trip failed: " ^ msg)
  | Ok assoc ->
    (* rt1 should be in warning (1 failure, 0 trips) *)
    check bool "rt1 is present" true (List.mem_assoc "rt1" assoc);
    check string "rt1=warning" "warning"
      (display_state_str (List.assoc "rt1" assoc))

(* ── LT-16-KCB Phase 2: per-keeper display_state_of ─────────── *)

let test_display_state_of_unknown_is_clean () =
  (* A keeper that has never been touched must classify as Clean,
     not raise. The composite observer relies on this to render newly
     spawned keepers before their first tool call. *)
  let s = CB.display_state_of ~keeper_name:"never-seen-prefix-xyz" in
  check string "unknown keeper = clean" "clean" (display_state_str s)

let test_display_state_of_matches_snapshot () =
  let name = "p2-alpha" in
  CB.record_success ~keeper_name:name;
  ignore (CB.maybe_enrich_error
            ~keeper_name:name ~error_msg:(path_not_found_msg "/a"));
  let direct = CB.display_state_of ~keeper_name:name in
  check string "direct lookup = warning" "warning" (display_state_str direct);
  let json = CB.snapshot_json () in
  match CB.classify_snapshot_json json with
  | Error msg -> Alcotest.fail ("json classify: " ^ msg)
  | Ok assoc ->
    check string "json-path agrees" "warning"
      (display_state_str (List.assoc name assoc))

let test_display_state_of_clears_after_success () =
  let name = "p2-beta" in
  CB.record_success ~keeper_name:name;
  ignore (CB.maybe_enrich_error
            ~keeper_name:name ~error_msg:(path_not_found_msg "/a"));
  CB.record_success ~keeper_name:name;
  let s = CB.display_state_of ~keeper_name:name in
  check string "after success, back to clean" "clean" (display_state_str s)

let trip_keeper name =
  CB.record_success ~keeper_name:name;
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:(path_not_found_msg "/a"));
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:(path_not_found_msg "/b"));
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:(path_not_found_msg "/c"))

let test_display_state_of_success_closes_trip () =
  let name = "p2-trip-success-closes" in
  trip_keeper name;
  let cooling = CB.display_state_of ~keeper_name:name in
  check string "trip opens cooling" "cooling" (display_state_str cooling);
  CB.record_success ~keeper_name:name;
  let closed = CB.display_state_of ~keeper_name:name in
  check string "success closes cooling" "clean" (display_state_str closed)

let test_display_state_of_cooling_auto_resets () =
  let name = "p2-trip-auto-reset" in
  trip_keeper name;
  let cooling = CB.display_state_of ~keeper_name:name in
  check string "trip opens cooling" "cooling" (display_state_str cooling);
  let after_window =
    CB.display_state_of_at
      ~now:(Unix.gettimeofday () +. CB.cooling_reset_sec +. 1.0)
      ~keeper_name:name
  in
  check string "cooling expires to clean" "clean"
    (display_state_str after_window)

(* ── task-240: failure signature diagnostics ────────────────── *)

let test_fingerprint_collapses_whitespace () =
  let fp = CB.fingerprint_of_error "line1\n  line2\ttab" in
  check bool "no newline" false (contains fp "\n");
  check bool "no tab" false (contains fp "\t");
  check bool "starts with line1" true (contains fp "line1")

let test_fingerprint_truncates () =
  let long = String.make 200 'x' in
  let fp = CB.fingerprint_of_error ~max_len:50 long in
  check bool "truncated length bounded" true (String.length fp <= 60);
  check bool "has ellipsis" true (contains fp "…")

let test_fingerprint_does_not_fake_truncation_after_space_collapse () =
  let padded = (String.make 200 ' ') ^ "tool_search_files failed" in
  let fp = CB.fingerprint_of_error ~max_len:50 padded in
  check bool "keeps content" true (contains fp "tool_search_files failed");
  check bool "no fake ellipsis" false (contains fp "…")

let test_recent_failures_empty_for_unknown () =
  let r = CB.recent_failures_of ~keeper_name:"never-touched-sig-xyz" in
  check int "empty list" 0 (List.length r)

let test_recent_failures_bounded_and_newest_first () =
  let name = "sig-bounded" in
  CB.record_success ~keeper_name:name;
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"err-1");
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"err-2");
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"err-3");
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"err-4");
  let r = CB.recent_failures_of ~keeper_name:name in
  check int "bounded to 3" 3 (List.length r);
  (* newest first: err-4 is head *)
  (match r with
   | first :: _ ->
     check bool "newest fingerprint is err-4" true
       (contains first.CB.fingerprint "err-4")
   | [] -> Alcotest.fail "expected entries")

let test_snapshot_json_exposes_recent_failures () =
  let name = "sig-snap" in
  CB.record_success ~keeper_name:name;
  ignore (CB.maybe_enrich_error
            ~keeper_name:name ~error_msg:"uniq-signature-ABC");
  let json = CB.snapshot_json () in
  match json with
  | `List entries ->
    let found =
      List.exists (fun e ->
        match e with
        | `Assoc fields ->
          (match List.assoc_opt "keeper" fields,
                 List.assoc_opt "recent_failures" fields with
           | Some (`String n), Some (`List rs) when n = name ->
             List.exists (fun r ->
               match r with
               | `Assoc rf ->
                 (match List.assoc_opt "fingerprint" rf with
                  | Some (`String fp) -> contains fp "uniq-signature-ABC"
                  | _ -> false)
               | _ -> false
             ) rs
           | _ -> false)
        | _ -> false
      ) entries
    in
    check bool "snapshot includes fingerprint" true found
  | _ -> Alcotest.fail "expected top-level list"

let test_recent_failures_survive_trip () =
  (* After a trip, consecutive_count resets but recent_failures must
     still hold the 3 signatures so operators can diagnose the trip. *)
  let name = "sig-survive" in
  CB.record_success ~keeper_name:name;
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"trip-a");
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"trip-b");
  ignore (CB.maybe_enrich_error ~keeper_name:name ~error_msg:"trip-c");
  let r = CB.recent_failures_of ~keeper_name:name in
  check int "3 signatures retained post-trip" 3 (List.length r)

let test_observed_failure_records_memory_without_tripping () =
  let name = "sig-observed-workflow" in
  CB.record_success ~keeper_name:name;
  CB.record_observed_failure ~keeper_name:name
    ~error_msg:
      "{\"failure_class\":\"workflow_rejection\",\"error\":\"tool_execute_command_shape_blocked\"}";
  CB.record_observed_failure ~keeper_name:name
    ~error_msg:
      "{\"failure_class\":\"workflow_rejection\",\"error\":\"tool_execute_command_shape_blocked\",\"shape_block\":\"pipe_or_redirect\"}";
  let recent = CB.recent_failures_of ~keeper_name:name in
  check int "observed failures are retained" 2 (List.length recent);
  check string "observed failure does not trip or warn" "clean"
    (display_state_str (CB.display_state_of ~keeper_name:name))

let test_prompt_failures_include_fleet_observed_failure () =
  let source = "sig-fleet-source" in
  let fresh = "sig-fleet-fresh" in
  let fingerprint =
    "{\"failure_class\":\"workflow_rejection\",\"error\":\"tool_execute_command_shape_blocked\",\"shape_block\":\"chaining\"}"
  in
  CB.record_success ~keeper_name:source;
  CB.record_success ~keeper_name:fresh;
  CB.record_observed_failure ~keeper_name:source ~error_msg:fingerprint;
  let recent = CB.recent_failures_for_prompt ~keeper_name:fresh in
  check bool "fresh keeper sees fleet failure" true
    (List.exists
       (fun (sig_ : CB.failure_signature) ->
          String_util.contains_substring sig_.fingerprint
            "tool_execute_command_shape_blocked")
       recent);
  check string "fresh keeper remains clean" "clean"
    (display_state_str (CB.display_state_of ~keeper_name:fresh))

let () =
  run "Circuit_breaker" [
    "classify", [
	      test_case "path_not_found" `Quick test_classify_path_not_found;
	      test_case "path_not_allowed" `Quick test_classify_path_not_allowed;
	      test_case "typed path-check prefixes" `Quick
	        test_classify_typed_path_check_prefixes;
	      test_case "other" `Quick test_classify_other;
    ];
    "signatures", [
      test_case "fingerprint collapses whitespace"
        `Quick test_fingerprint_collapses_whitespace;
      test_case "fingerprint truncates with ellipsis"
        `Quick test_fingerprint_truncates;
      test_case "fingerprint does not fake truncation after space collapse"
        `Quick test_fingerprint_does_not_fake_truncation_after_space_collapse;
      test_case "recent_failures empty for unknown"
        `Quick test_recent_failures_empty_for_unknown;
      test_case "recent_failures bounded, newest first"
        `Quick test_recent_failures_bounded_and_newest_first;
      test_case "snapshot_json exposes recent_failures"
        `Quick test_snapshot_json_exposes_recent_failures;
      test_case "recent_failures survive trip"
        `Quick test_recent_failures_survive_trip;
      test_case "observed failure records memory without tripping"
        `Quick test_observed_failure_records_memory_without_tripping;
      test_case "prompt failures include fleet observed failure"
        `Quick test_prompt_failures_include_fleet_observed_failure;
    ];
    "threshold", [
      test_case "no hint under threshold" `Quick test_no_hint_under_threshold;
      test_case "hint at threshold" `Quick test_hint_at_threshold;
      test_case "actionable path hint uses visible listing"
        `Quick test_actionable_path_not_found_hint;
      test_case "reset on success" `Quick test_reset_on_success;
      test_case "class change resets" `Quick test_class_change_resets;
    ];
    "diagnostics", [
      test_case "snapshot" `Quick test_snapshot;
    ];
    "display_state", [
      test_case "clean" `Quick test_display_state_clean;
      test_case "warning" `Quick test_display_state_warning;
      test_case "cooling" `Quick test_display_state_cooling;
      test_case "classify_snapshot_json happy path"
        `Quick test_classify_snapshot_json_happy;
      test_case "classify_snapshot_json skips malformed"
        `Quick test_classify_snapshot_skips_malformed;
      test_case "classify_snapshot_json rejects non-list"
        `Quick test_classify_snapshot_not_a_list;
      test_case "round-trip via snapshot_json"
        `Quick test_classify_snapshot_round_trip;
    ];
    "display_state_of", [
      test_case "unknown keeper = clean"
        `Quick test_display_state_of_unknown_is_clean;
      test_case "direct lookup matches json walk"
        `Quick test_display_state_of_matches_snapshot;
      test_case "success clears back to clean"
        `Quick test_display_state_of_clears_after_success;
      test_case "success closes a tripped cooling window"
        `Quick test_display_state_of_success_closes_trip;
      test_case "cooling window auto-resets"
        `Quick test_display_state_of_cooling_auto_resets;
    ];
  ]

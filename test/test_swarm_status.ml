open Alcotest

module U = Yojson.Safe.Util
module M = Masc_mcp

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > hay_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let find_lane json lane_id =
  json |> U.member "lanes" |> U.to_list
  |> List.find (fun lane ->
         String.equal (lane |> U.member "lane_id" |> U.to_string) lane_id)

let test_supervised_trace_only_does_not_make_lane_present () =
  let trace : M.Swarm_status.trace_info =
    {
      event_id = "trace-1";
      event_type = "autonomy_tick";
      source = "operator";
      trace_id = "ops_1";
      operation_id = None;
      actor = Some "dashboard-kind-crane";
      timestamp = Some "2026-03-07T18:02:18Z";
      detail = `Assoc [ ("action_type", `String "autonomy_tick") ];
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit
      ~now:(Time_compat.now ()) ~operations:[] ~detachments:[] ~alerts:[]
      ~decisions:[] ~traces:[ trace ] ~sessions:[]
  in
  let supervised = find_lane json "supervised" in
  check bool "supervised lane absent" false
    (supervised |> U.member "present" |> U.to_bool);
  check string "lane provenance" "derived"
    (supervised |> U.member "provenance" |> U.to_string);
  check int "no supervised hard flags" 0
    (supervised |> U.member "hard_flags" |> U.to_list |> List.length);
  check string "root recommendation provenance" "fallback"
    (json |> U.member "recommended_next_action" |> U.member "provenance" |> U.to_string);
  check string "timeline provenance contract" "truth"
    (json |> U.member "provenance_summary" |> U.member "timeline" |> U.to_string);
  check bool "do not recommend namespace digest" false
    (String.equal "masc_operator_digest"
       (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string))

let test_managed_trace_only_does_not_make_lane_present () =
  let trace : M.Swarm_status.trace_info =
    {
      event_id = "trace-managed-1";
      event_type = "operation_search_scored";
      source = "control_plane";
      trace_id = "trace-managed-1";
      operation_id = Some "op-old";
      actor = Some "dashboard";
      timestamp = Some "2026-03-07T18:02:18Z";
      detail = `Assoc [ ("selected_unit_id", `String "company-runtime") ];
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit
      ~now:(Time_compat.now ()) ~operations:[] ~detachments:[] ~alerts:[]
      ~decisions:[] ~traces:[ trace ] ~sessions:[]
  in
  let managed = find_lane json "managed" in
  check bool "managed lane absent" false
    (managed |> U.member "present" |> U.to_bool);
  check int "no managed hard flags" 0
    (managed |> U.member "hard_flags" |> U.to_list |> List.length);
  check bool "do not recommend dispatch tick from trace residue" false
    (String.equal "masc_dispatch_tick"
       (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string))

let test_active_managed_operation_keeps_lane_present () =
  let now = Time_compat.now () in
  let now_iso = M.Command_plane_v2.iso_of_unix now in
  let operation : M.Swarm_status.operation_info =
    {
      operation_id = "op-running";
      objective = "Live managed lane";
      source = "managed";
      status = "running";
      trace_id = "trace-running";
      detachment_session_id = None;
      note = Some "live operation";
      updated_at = Some now_iso;
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit ~now
      ~operations:[ operation ] ~detachments:[] ~alerts:[] ~decisions:[]
      ~traces:[] ~sessions:[]
  in
  let managed = find_lane json "managed" in
  check bool "managed lane present for active operation" true
    (managed |> U.member "present" |> U.to_bool);
  check string "overview provenance" "derived"
    (json |> U.member "overview" |> U.member "provenance" |> U.to_string)

let test_managed_alert_only_keeps_lane_present () =
  let now = Time_compat.now () in
  let now_iso = M.Command_plane_v2.iso_of_unix now in
  let alert : M.Swarm_status.alert_info =
    {
      alert_id = "alert-unit-frozen";
      severity = "warn";
      scope_type = Some "unit";
      scope_id = Some "company-runtime";
      title = Some "Company runtime is frozen";
      detail = Some "Dispatch into this unit is blocked until it is unfrozen.";
      timestamp = Some now_iso;
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit ~now
      ~operations:[] ~detachments:[] ~alerts:[ alert ] ~decisions:[]
      ~traces:[] ~sessions:[]
  in
  let managed = find_lane json "managed" in
  check bool "managed lane present for live alert" true
    (managed |> U.member "present" |> U.to_bool)

let test_supervised_session_keeps_lane_present () =
  let now = Time_compat.now () in
  let now_iso = M.Command_plane_v2.iso_of_unix now in
  let session : M.Swarm_status.session_info =
    {
      session_id = "sess-1";
      goal = "Exercise supervised lane";
      status = "running";
      started_at = 0.0;
      updated_at_iso = now_iso;
      last_event_at = Some now_iso;
      last_turn_at = Some now_iso;
      worker_names = [ "worker-a" ];
      min_agents_violation_streak = 0;
      policy_violation_count = 0;
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit
      ~now:(Time_compat.now ()) ~operations:[] ~detachments:[] ~alerts:[]
      ~decisions:[] ~traces:[] ~sessions:[ session ]
  in
  let supervised = find_lane json "supervised" in
  check bool "supervised lane present" true
    (supervised |> U.member "present" |> U.to_bool);
  check string "next action" "masc_observe_traces"
    (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string);
  check string "narrative state" "running"
    (json |> U.member "narrative" |> U.member "state" |> U.to_string);
  check bool "narrative active work present" true
    (json |> U.member "narrative" |> U.member "active_work" |> U.to_string <> "")

let test_stale_supervised_session_keeps_stale_flag () =
  let stale_iso = M.Command_plane_v2.iso_of_unix (Time_compat.now () -. 1200.) in
  let session : M.Swarm_status.session_info =
    {
      session_id = "sess-stale";
      goal = "Exercise stale supervised lane";
      status = "running";
      started_at = 0.0;
      updated_at_iso = stale_iso;
      last_event_at = Some stale_iso;
      last_turn_at = Some stale_iso;
      worker_names = [ "worker-a" ];
      min_agents_violation_streak = 0;
      policy_violation_count = 0;
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit
      ~now:(Time_compat.now ()) ~operations:[] ~detachments:[] ~alerts:[]
      ~decisions:[] ~traces:[] ~sessions:[ session ]
  in
  let supervised = find_lane json "supervised" in
  let hard_flags = supervised |> U.member "hard_flags" |> U.to_list in
  check bool "supervised lane still present" true
    (supervised |> U.member "present" |> U.to_bool);
  check bool "stale_data flag present" true
    (List.exists
       (fun flag ->
         String.equal "stale_data" (flag |> U.member "code" |> U.to_string))
       hard_flags);
  check string "stale supervised recommendation" "masc_observe_traces"
    (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string);
  check string "stale narrative lane" "supervised"
    (json |> U.member "narrative" |> U.member "lane_id" |> U.to_string);
  let stale_gap =
    json |> U.member "gaps" |> U.member "items" |> U.to_list
    |> List.find (fun row ->
           String.equal "stale_data" (row |> U.member "code" |> U.to_string))
  in
  check string "stale gap next tool" "masc_observe_traces"
    (stale_gap |> U.member "next_tool" |> U.to_string);
  check bool "stale gap why" true
    (stale_gap |> U.member "why_it_matters" |> U.to_string <> "")

let test_recommendation_lane_drives_narrative_lane_and_start_event () =
  let now = Time_compat.now () in
  let current_iso = M.Command_plane_v2.iso_of_unix now in
  let stale_iso = M.Command_plane_v2.iso_of_unix (now -. 1200.) in
  let old_iso = M.Command_plane_v2.iso_of_unix (now -. 90.) in
  let recent_iso = M.Command_plane_v2.iso_of_unix (now -. 30.) in
  let operation : M.Swarm_status.operation_info =
    {
      operation_id = "op-managed";
      objective = "Managed work should win the narrative";
      source = "managed";
      status = "running";
      trace_id = "trace-managed";
      detachment_session_id = None;
      note = Some "managed work";
      updated_at = Some current_iso;
    }
  in
  let supervised : M.Swarm_status.session_info =
    {
      session_id = "sess-stale";
      goal = "Old supervised lane";
      status = "running";
      started_at = now -. 3600.;
      updated_at_iso = stale_iso;
      last_event_at = Some stale_iso;
      last_turn_at = Some stale_iso;
      worker_names = [ "worker-a" ];
      min_agents_violation_streak = 0;
      policy_violation_count = 0;
    }
  in
  let old_trace : M.Swarm_status.trace_info =
    {
      event_id = "trace-old";
      event_type = "operation_progress";
      source = "control_plane";
      trace_id = "trace-managed";
      operation_id = Some "op-managed";
      actor = Some "manager";
      timestamp = Some old_iso;
      detail = `Assoc [ ("message", `String "older managed progress") ];
    }
  in
  let recent_trace : M.Swarm_status.trace_info =
    {
      event_id = "trace-new";
      event_type = "operation_progress";
      source = "control_plane";
      trace_id = "trace-managed";
      operation_id = Some "op-managed";
      actor = Some "manager";
      timestamp = Some recent_iso;
      detail = `Assoc [ ("message", `String "newer managed progress") ];
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit ~now
      ~operations:[ operation ] ~detachments:[] ~alerts:[]
      ~decisions:[] ~traces:[ old_trace; recent_trace ] ~sessions:[ supervised ]
  in
  check string "managed recommendation chosen" "managed"
    (json |> U.member "recommended_next_action" |> U.member "lane_id"
   |> U.to_string);
  check string "narrative lane follows recommendation" "managed"
    (json |> U.member "narrative" |> U.member "lane_id" |> U.to_string);
  check bool "started uses earliest managed event" true
    (contains_substring
       (json |> U.member "narrative" |> U.member "started" |> U.to_string)
       "older managed progress")

let test_terminal_projected_session_artifacts_do_not_keep_supervised_lane_present ()
    =
  let now = Time_compat.now () in
  let stale_iso = M.Command_plane_v2.iso_of_unix (now -. 3600.) in
  let operation : M.Swarm_status.operation_info =
    {
      operation_id = "detachment-ts-old";
      objective = "Historical supervised session";
      source = "projected";
      status = "completed";
      trace_id = "ts-old";
      detachment_session_id = Some "ts-old";
      note = Some "duration_reached";
      updated_at = Some stale_iso;
    }
  in
  let detachment : M.Swarm_status.detachment_info =
    {
      detachment_id = "detachment-ts-old";
      operation_id = "detachment-ts-old";
      source = "projected";
      status = "cancelled";
      runtime_kind = Some "operation";
      session_id = Some "ts-old";
      roster = [ "worker-a"; "worker-b" ];
      leader_id = Some "worker-a";
      last_event_at = Some stale_iso;
      last_progress_at = Some stale_iso;
      updated_at = Some stale_iso;
    }
  in
  let session : M.Swarm_status.session_info =
    {
      session_id = "ts-old";
      goal = "Historical supervised session";
      status = "completed";
      started_at = now -. 7200.;
      updated_at_iso = stale_iso;
      last_event_at = Some stale_iso;
      last_turn_at = Some stale_iso;
      worker_names = [ "worker-a"; "worker-b" ];
      min_agents_violation_streak = 0;
      policy_violation_count = 0;
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit ~now
      ~operations:[ operation ] ~detachments:[ detachment ] ~alerts:[]
      ~decisions:[] ~traces:[] ~sessions:[ session ]
  in
  let supervised = find_lane json "supervised" in
  check bool "supervised lane absent for terminal-only artifacts" false
    (supervised |> U.member "present" |> U.to_bool);
  check int "supervised operations filtered" 0
    (supervised |> U.member "counts" |> U.member "operations" |> U.to_int);
  check int "supervised detachments filtered" 0
    (supervised |> U.member "counts" |> U.member "detachments" |> U.to_int);
  check int "supervised workers filtered" 0
    (supervised |> U.member "counts" |> U.member "workers" |> U.to_int);
  check bool "no stale flag when lane absent" false
    (List.exists
       (fun flag ->
         String.equal "stale_data" (flag |> U.member "code" |> U.to_string))
       (supervised |> U.member "hard_flags" |> U.to_list))

let test_terminal_managed_artifacts_do_not_keep_managed_lane_present () =
  let now = Time_compat.now () in
  let stale_iso = M.Command_plane_v2.iso_of_unix (now -. 3600.) in
  let operation : M.Swarm_status.operation_info =
    {
      operation_id = "op-old";
      objective = "Historical managed lane";
      source = "managed";
      status = "failed";
      trace_id = "trace-old";
      detachment_session_id = None;
      note = Some "historical failure";
      updated_at = Some stale_iso;
    }
  in
  let detachment : M.Swarm_status.detachment_info =
    {
      detachment_id = "det-op-old";
      operation_id = "op-old";
      source = "managed";
      status = "failed";
      runtime_kind = Some "managed";
      session_id = None;
      roster = [ "worker-a" ];
      leader_id = Some "worker-a";
      last_event_at = Some stale_iso;
      last_progress_at = Some stale_iso;
      updated_at = Some stale_iso;
    }
  in
  let trace : M.Swarm_status.trace_info =
    {
      event_id = "trace-old";
      event_type = "operation_failed";
      source = "control_plane";
      trace_id = "trace-old";
      operation_id = Some "op-old";
      actor = Some "dashboard";
      timestamp = Some stale_iso;
      detail = `Assoc [ ("status", `String "failed") ];
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs
      ~timeline_limit_override:M.Swarm_status.timeline_limit ~now
      ~operations:[ operation ] ~detachments:[ detachment ] ~alerts:[]
      ~decisions:[] ~traces:[ trace ] ~sessions:[]
  in
  let managed = find_lane json "managed" in
  check bool "managed lane absent for terminal-only artifacts" false
    (managed |> U.member "present" |> U.to_bool);
  check bool "no stale flag when lane absent" false
    (List.exists
       (fun flag ->
         String.equal "stale_data" (flag |> U.member "code" |> U.to_string))
       (managed |> U.member "hard_flags" |> U.to_list));
  check bool "do not recommend dispatch tick from terminal residue" false
    (String.equal "masc_dispatch_tick"
       (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string))

let () =
  run "Swarm_status"
    [
      ( "lane_presence",
        [
          test_case "trace_only_does_not_activate_supervised_lane" `Quick
            test_supervised_trace_only_does_not_make_lane_present;
          test_case "trace_only_does_not_activate_managed_lane" `Quick
            test_managed_trace_only_does_not_make_lane_present;
          test_case "active_managed_operation_keeps_lane_present" `Quick
            test_active_managed_operation_keeps_lane_present;
          test_case "managed_alert_only_keeps_lane_present" `Quick
            test_managed_alert_only_keeps_lane_present;
          test_case "session_keeps_supervised_lane_present" `Quick
            test_supervised_session_keeps_lane_present;
          test_case "stale_session_keeps_stale_flag" `Quick
            test_stale_supervised_session_keeps_stale_flag;
          test_case "recommendation_lane_drives_narrative_lane_and_start_event"
            `Quick
            test_recommendation_lane_drives_narrative_lane_and_start_event;
          test_case "terminal_projected_artifacts_do_not_keep_supervised_lane_present"
            `Quick
            test_terminal_projected_session_artifacts_do_not_keep_supervised_lane_present;
          test_case "terminal_managed_artifacts_do_not_keep_managed_lane_present"
            `Quick
            test_terminal_managed_artifacts_do_not_keep_managed_lane_present;
        ] );
    ]

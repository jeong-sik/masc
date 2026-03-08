open Alcotest

module U = Yojson.Safe.Util
module M = Masc_mcp

let find_lane json lane_id =
  json |> U.member "lanes" |> U.to_list
  |> List.find (fun lane ->
         String.equal (lane |> U.member "lane_id" |> U.to_string) lane_id)

let test_supervised_trace_only_does_not_make_lane_present () =
  let trace : M.Swarm_status.trace_info =
    {
      event_id = "trace-1";
      event_type = "lodge_tick";
      source = "operator";
      trace_id = "ops_1";
      operation_id = None;
      actor = Some "dashboard-kind-crane";
      timestamp = Some "2026-03-07T18:02:18Z";
      detail = `Assoc [ ("action_type", `String "lodge_tick") ];
    }
  in
  let json =
    M.Swarm_status.build_json_from_inputs ~now:(M.Time_compat.now ()) ~operations:[]
      ~detachments:[] ~alerts:[] ~decisions:[] ~traces:[ trace ] ~sessions:[]
  in
  let supervised = find_lane json "supervised" in
  check bool "supervised lane absent" false
    (supervised |> U.member "present" |> U.to_bool);
  check int "no supervised hard flags" 0
    (supervised |> U.member "hard_flags" |> U.to_list |> List.length);
  check bool "do not recommend team session inspection" false
    (String.equal "masc_team_session_status"
       (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string))

let test_supervised_session_keeps_lane_present () =
  let now = M.Time_compat.now () in
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
    M.Swarm_status.build_json_from_inputs ~now:(M.Time_compat.now ()) ~operations:[]
      ~detachments:[] ~alerts:[] ~decisions:[] ~traces:[] ~sessions:[ session ]
  in
  let supervised = find_lane json "supervised" in
  check bool "supervised lane present" true
    (supervised |> U.member "present" |> U.to_bool);
  check string "next action" "masc_observe_traces"
    (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string)

let test_stale_supervised_session_keeps_stale_flag () =
  let stale_iso = M.Command_plane_v2.iso_of_unix (M.Time_compat.now () -. 1200.) in
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
    M.Swarm_status.build_json_from_inputs ~now:(M.Time_compat.now ()) ~operations:[]
      ~detachments:[] ~alerts:[] ~decisions:[] ~traces:[] ~sessions:[ session ]
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
  check string "stale supervised recommendation" "masc_team_session_status"
    (json |> U.member "recommended_next_action" |> U.member "tool" |> U.to_string)

let test_terminal_projected_session_artifacts_do_not_keep_supervised_lane_present ()
    =
  let now = M.Time_compat.now () in
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
      runtime_kind = Some "team_session";
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
    M.Swarm_status.build_json_from_inputs ~now ~operations:[ operation ]
      ~detachments:[ detachment ] ~alerts:[] ~decisions:[] ~traces:[]
      ~sessions:[ session ]
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

let () =
  run "Swarm_status"
    [
      ( "lane_presence",
        [
          test_case "trace_only_does_not_activate_supervised_lane" `Quick
            test_supervised_trace_only_does_not_make_lane_present;
          test_case "session_keeps_supervised_lane_present" `Quick
            test_supervised_session_keeps_lane_present;
          test_case "stale_session_keeps_stale_flag" `Quick
            test_stale_supervised_session_keeps_stale_flag;
          test_case "terminal_projected_artifacts_do_not_keep_supervised_lane_present"
            `Quick
            test_terminal_projected_session_artifacts_do_not_keep_supervised_lane_present;
        ] );
    ]

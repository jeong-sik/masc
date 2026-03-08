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
        ] );
    ]

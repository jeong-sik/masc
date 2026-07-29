open Alcotest
open Dashboard_execution_builders

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let keeper ?(status = "offline") ?(last_autonomous_action_at = "")
    ?(updated_at = "") ?(turn_count = 0) ?(autonomous_turn_count = 0) () =
  `Assoc
    [
      ("name", `String "executor");
      ("agent", `Assoc [ ("last_seen", `String "") ]);
      ("agent_name", `String "executor");
      ("keeper_id", `String "k-executor");
      ("status", `String status);
      ("generation", `Int 0);
      ("turn_count", `Int turn_count);
      ("autonomous_turn_count", `Int autonomous_turn_count);
      ("autonomous_action_count", `Int 0);
      ("noop_turn_count", `Int 0);
      ("active_goal_ids", `List []);
      ("last_autonomous_action_at", `String last_autonomous_action_at);
      ("updated_at", `String updated_at);
      ("tool_audit_at", `String "");
      ("recent_input_preview", `Null);
      ("recent_output_preview", `Null);
      ("recent_tool_names", `List []);
      ("latest_tool_names", `List []);
      ("latest_action_source", `Null);
      ("context_ratio", `Null);
    ]

let state_of row =
  Yojson.Safe.Util.(row.json |> member "state" |> to_string)

let lifecycle_of row =
  Yojson.Safe.Util.(row.json |> member "lifecycle" |> to_string)

let build_one k =
  List.hd (build_continuity_briefs ~now_ts:1_000_000_000.0 [ k ] [])

let test_offline_without_signal_is_critical () =
  let row = build_one (keeper ()) in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_offline_with_action_is_healthy_active () =
  let row =
    build_one
      (keeper ~status:"offline" ~last_autonomous_action_at:"2026-07-29T12:00:00Z"
         ~turn_count:1 ~autonomous_turn_count:1 ())
  in
  check string "lifecycle" "active" (lifecycle_of row);
  check string "state" "healthy" (state_of row)

let test_offline_with_heartbeat_is_healthy_idle () =
  let row =
    build_one
      (keeper ~status:"offline" ~updated_at:"2026-07-29T12:00:00Z" ())
  in
  check string "lifecycle" "idle" (lifecycle_of row);
  check string "state" "healthy" (state_of row)

let () =
  run "dashboard_continuity_briefs"
    [
      ( "offline_status_override",
        [
          test_case "no signal -> critical" `Quick
            test_offline_without_signal_is_critical;
          test_case "action signal -> healthy active" `Quick
            test_offline_with_action_is_healthy_active;
          test_case "heartbeat signal -> healthy idle" `Quick
            test_offline_with_heartbeat_is_healthy_idle;
        ] );
    ]

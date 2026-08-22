open Alcotest
open Dashboard_execution_builders

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let keeper ?(status = "offline") ?(last_autonomous_action_at = "")
    ?(updated_at = "") ?(keepalive_running = false) ?(turn_count = 0)
    ?(autonomous_turn_count = 0) ?(paused = false) () =
  `Assoc
    [
      ("name", `String "omega");
      ("agent_name", `String "omega");
      ("keeper_id", `String "k-executor");
      ("status", `String status);
      ("paused", `Bool paused);
      ("keepalive_running", `Bool keepalive_running);
      ("generation", `Int 0);
      ("turn_count", `Int turn_count);
      ("autonomous_turn_count", `Int autonomous_turn_count);
      ("autonomous_action_count", `Int 0);
      ("noop_turn_count", `Int 0);
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

let status_of row =
  Yojson.Safe.Util.(row.json |> member "status" |> to_string)

let note_of row =
  Yojson.Safe.Util.(row.json |> member "note" |> to_string)

let build_one k =
  List.hd (build_continuity_briefs ~now_ts:1_000_000_000.0 [ k ])

let test_offline_without_signal_is_critical () =
  let row = build_one (keeper ()) in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_offline_with_persisted_action_stays_critical () =
  let row =
    build_one
      (keeper ~last_autonomous_action_at:"2001-09-09T01:46:40Z"
         ~turn_count:1 ~autonomous_turn_count:1 ())
  in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_running_flag_does_not_override_offline_status () =
  let row =
    build_one
      (keeper ~keepalive_running:true
         ~last_autonomous_action_at:"2001-09-09T01:46:40Z" ~turn_count:1
         ~autonomous_turn_count:1 ())
  in
  check string "status" "offline" (status_of row);
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_reconciled_active_status_is_healthy_active () =
  let row =
    build_one
      (keeper
         ~status:"active"
         ~keepalive_running:true
         ~last_autonomous_action_at:"2001-09-09T01:46:40Z"
         ~turn_count:1
         ~autonomous_turn_count:1
         ())
  in
  check string "status" "active" (status_of row);
  check string "lifecycle" "active" (lifecycle_of row);
  check string "state" "healthy" (state_of row)

let test_running_but_inactive_stays_critical () =
  let row =
    build_one
      (keeper
         ~status:"inactive"
         ~keepalive_running:true
         ~last_autonomous_action_at:"2001-09-09T01:46:40Z"
         ~turn_count:1
         ~autonomous_turn_count:1
         ())
  in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

(* The operator pauses a keeper that was running a moment ago. Every activity
   signal still looks fresh, so the healthy branch is the one this row falls
   into unless the pause is classified on its own. Reporting a stopped keeper as
   "정상 동작 중" is a worse signal than the offline misread this PR removed. *)
let test_paused_keeper_with_fresh_activity_is_not_healthy () =
  let row =
    build_one
      (keeper
         ~status:"paused"
         ~paused:true
         ~last_autonomous_action_at:"2001-09-09T01:46:40Z"
         ~updated_at:"2001-09-09T01:46:40Z"
         ~turn_count:4
         ~autonomous_turn_count:4
         ())
  in
  check string "status" "paused" (status_of row);
  check string "lifecycle" "idle" (lifecycle_of row);
  check string "state" "warning" (state_of row);
  check string "note" "운영자 일시정지" (note_of row)

(* A pause is not a liveness failure, so it must not inherit the offline
   verdict either. *)
let test_paused_keeper_is_not_critical () =
  let row = build_one (keeper ~status:"paused" ~paused:true ()) in
  check string "state" "warning" (state_of row);
  check string "note" "운영자 일시정지" (note_of row)

(* [paused] is a duplicate of what [status] already carries. Letting it rescue
   an unparsed status would reopen the permissive fallback one field over: any
   producer drift would be accepted for free on every paused keeper. *)
let test_unknown_status_is_rejected_even_when_paused () =
  check_raises
    "unknown status stays a rejected parse"
    (Invalid_argument
       "dashboard continuity: unknown current keeper status \"suspended\"")
    (fun () -> ignore (build_one (keeper ~status:"suspended" ~paused:true ())))

let () =
  run "dashboard_continuity_briefs"
    [
      ( "offline_status_override",
        [
          test_case "no signal -> critical" `Quick
            test_offline_without_signal_is_critical;
          test_case "persisted action without runtime -> critical" `Quick
            test_offline_with_persisted_action_stays_critical;
          test_case "running flag cannot override offline status" `Quick
            test_running_flag_does_not_override_offline_status;
          test_case "reconciled active status -> healthy active" `Quick
            test_reconciled_active_status_is_healthy_active;
          test_case "running + inactive -> critical" `Quick
            test_running_but_inactive_stays_critical;
          test_case "paused keeper with fresh activity is not healthy" `Quick
            test_paused_keeper_with_fresh_activity_is_not_healthy;
          test_case "paused keeper is not critical" `Quick
            test_paused_keeper_is_not_critical;
          test_case "unknown status is rejected even when paused" `Quick
            test_unknown_status_is_rejected_even_when_paused;
        ] );
    ]

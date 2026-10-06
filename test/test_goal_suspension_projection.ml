open Alcotest
let test_actions () =
  let actions phase = Dashboard_goals_types_health.goal_fsm_next_actions ~goal_phase:phase in
  check (list string) "paused public controls" ["drop";"reopen";"resume";"block"]
    (actions (Goal_phase.Paused Goal_phase.Resume_verifying));
  check (list string) "blocked public controls" ["drop";"reopen";"pause";"unblock"]
    (actions (Goal_phase.Blocked Goal_phase.Resume_awaiting_confirmation));
  check (list string) "verifier actions not exposed as operator controls"
    ["drop";"reopen";"pause";"block"] (actions Goal_phase.Verifying)
let test_timeline () =
  let event = `Assoc ["event_type", `String "goal_phase"; "ts", `String "2026-10-04T00:00:00Z";
    "payload", `Assoc ["phase", `String "blocked"; "resume_phase", `String "verifying"; "actor", `String "operator"]] in
  let projection = Dashboard_goals_types_timeline.goal_event_timeline_json event in
  let field name = Yojson.Safe.Util.member name projection |> Yojson.Safe.Util.to_string in
  check string "restoration visible in timeline" "phase=blocked; resumes verifying by operator" (field "summary");
  check string "recognized lifecycle" "ok" (field "severity")
let () = run "Goal suspension projection" ["dashboard",[
  test_case "public actions from FSM" `Quick test_actions;
  test_case "audit restoration state" `Quick test_timeline;
]]

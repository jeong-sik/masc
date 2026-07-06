open Alcotest
open Masc

let temp_dir () =
  let path = Filename.temp_file "goal_liveness_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test"));
      f config)

let make_goal id phase active_verification_request_id =
  let ts = Masc_domain.now_iso () in
  {
    Goal_store.id;
    title = "Test Goal";
    metric = None;
    target_value = None;
    due_date = None;
    priority = 3;
    status = Active;
    phase;
    verifier_policy = None;
    require_completion_approval = false;
    active_verification_request_id;
    parent_goal_id = None;
    last_review_note = None;
    last_review_at = None;
    created_at = ts;
    updated_at = ts;
  }

let make_context config : Workspace_types.context =
  {
    config;
    agent_name = "test";
  }

let test_sweep_expired_verification_reverts_goal () =
  let open Goal_verification in
  with_workspace @@ fun config ->
  let ctx = make_context config in
  
  let goal_id = "goal-timeout-1" in
  (* 1. Create an expired verification request *)
  let requested_by = { id = "test-operator"; display_name = None } in
  let policy_snapshot = { principals = []; eligible_principals = []; required_verdicts = 1 } in
  let expires_at_unix = Unix.gettimeofday () -. 60.0 in (* Expired 1 minute ago *)
  let expires_at = Some (Masc_domain.iso8601_of_unix_seconds expires_at_unix) in
  let request =
    match
      create_request config ~goal_id ~requested_by ~policy_snapshot
    with
    | Error msg -> fail msg
    | Ok req -> { req with expires_at }
  in
  let state = read_state config in
  let updated_state = { state with requests = List.map (fun r -> if String.equal r.id request.id then request else r) state.requests } in
  let () =
    let path = Goal_verification.requests_path config in
    let json = Goal_verification.state_to_yojson updated_state in
    Fs_compat.save_file path (Yojson.Safe.to_string json)
  in

  (* 2. Create a goal in Awaiting_verification phase referencing the request *)
  let goal = make_goal goal_id Goal_phase.Awaiting_verification (Some request.id) in
  let () =
    Goal_store.write_state config
      { version = 1; updated_at = Masc_domain.now_iso (); goals = [ goal ] }
  in

  (* 3. Run the sweep (implicitly via handle_goal_list) *)
  let args = `Assoc [] in
  let _result = Workspace_goals.handle_goal_list ~tool_name:"goal_list" ~start_time:(Unix.gettimeofday ()) ctx args in

  (* 4. Verify that the goal phase has reverted to Executing *)
  match Goal_store.get_goal config ~goal_id with
  | None -> fail "goal not found after sweep"
  | Some updated_goal ->
      check string "goal phase reverted to executing"
        "executing" (Goal_phase.to_string updated_goal.phase);
      check bool "active_verification_request_id cleared"
        true (Option.is_none updated_goal.active_verification_request_id);
      check string "last_review_note set"
        "Verification request expired (timeout)" (Option.value updated_goal.last_review_note ~default:"")

let test_sweep_expired_approval_reverts_goal () =
  with_workspace @@ fun config ->
  let ctx = make_context config in

  (* 1. Create a goal in Awaiting_approval phase *)
  let goal_id = "goal-timeout-2" in
  let goal = make_goal goal_id Goal_phase.Awaiting_approval None in
  let () =
    Goal_store.write_state config
      { version = 1; updated_at = Masc_domain.now_iso (); goals = [ goal ] }
  in

  (* 2. Since we do not create a pending confirmation, it is missing (effectively expired).
     Run the sweep via handle_goal_list *)
  let args = `Assoc [] in
  let _result = Workspace_goals.handle_goal_list ~tool_name:"goal_list" ~start_time:(Unix.gettimeofday ()) ctx args in

  (* 3. Verify that the goal phase has reverted to Executing *)
  match Goal_store.get_goal config ~goal_id with
  | None -> fail "goal not found after sweep"
  | Some updated_goal ->
      check string "goal phase reverted to executing"
        "executing" (Goal_phase.to_string updated_goal.phase);
      check string "last_review_note set"
        "Goal approval request expired (timeout)" (Option.value updated_goal.last_review_note ~default:"")

let () =
  run "goal liveness timeout"
    [
      ( "sweep",
        [
          test_case "expired verification request reverts goal phase" `Quick
            test_sweep_expired_verification_reverts_goal;
          test_case "missing approval pending confirm reverts goal phase" `Quick
            test_sweep_expired_approval_reverts_goal;
        ] );
    ]

(** Tests for Goal_verification error paths preserving state. *)

open Alcotest
open Masc

let temp_dir () =
  let path = Filename.temp_file "goal_verification_test" "" in
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

let operator ?display_name id : Goal_verification.goal_principal =
  { id; display_name }

let agent ?display_name id : Goal_verification.goal_principal =
  { id; display_name }

let requests_recovery_path config =
  Goal_verification.requests_path config ^ ".last-good"

let request_snapshot ~requested_by =
  let reviewer = operator "reviewer-1" in
  let verifier = agent "agent-a" in
  let principals = [ requested_by; reviewer; verifier ] in
  {
    Goal_verification.principals;
    eligible_principals = [ reviewer; verifier ];
    required_verdicts = 2;
  }

let single_approver_snapshot ~requested_by =
  let reviewer = operator "reviewer-1" in
  {
    Goal_verification.principals = [ requested_by; reviewer ];
    eligible_principals = [ reviewer ];
    required_verdicts = 1;
  }

let test_cancel_missing_request_does_not_bump () =
  with_workspace @@ fun config ->
  let before = Goal_verification.read_state config in
  (match Goal_verification.cancel_request config ~request_id:"ghost" with
   | Error _ -> ()
   | Ok _ -> fail "expected missing request error");
  let after = Goal_verification.read_state config in
  check int "version unchanged" before.version after.version;
  check string "updated_at unchanged" before.updated_at after.updated_at

let test_invalid_vote_does_not_bump () =
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let request =
    match
      Goal_verification.create_request config ~goal_id:"goal-1" ~requested_by
        ~policy_snapshot:(request_snapshot ~requested_by)
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let before = Goal_verification.read_state config in
  (match
     Goal_verification.submit_vote config ~request_id:request.id
       ~goal_id:"goal-1"
       ~principal:requested_by ~decision:Goal_verification.Approve ()
   with
   | Error _ -> ()
   | Ok _ -> fail "expected requester self-vote error");
  let after = Goal_verification.read_state config in
  check int "version unchanged on invalid vote" before.version after.version;
  check string "updated_at unchanged on invalid vote" before.updated_at after.updated_at;
  let saved =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "request missing after invalid vote"
  in
  check int "no votes written" 0 (List.length saved.votes)

let test_cancel_if_open_reports_already_resolved () =
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let reviewer = operator "reviewer-1" in
  let request =
    match
      Goal_verification.create_request config ~goal_id:"goal-1" ~requested_by
        ~policy_snapshot:(single_approver_snapshot ~requested_by)
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let approved_request =
    match
      Goal_verification.submit_vote config ~request_id:request.id ~goal_id:"goal-1"
        ~principal:reviewer ~decision:Goal_verification.Approve ()
    with
    | Ok (request, _) -> request
    | Error msg -> fail msg
  in
  check bool "fixture approved" true
    (approved_request.status = Goal_verification.Approved);
  let before = Goal_verification.read_state config in
  (match Goal_verification.cancel_request_if_open config ~request_id:request.id with
   | Ok (Goal_verification.Already_resolved_request resolved) ->
       check bool "already resolved status preserved" true
         (resolved.status = Goal_verification.Approved)
   | Ok (Goal_verification.Cancelled_request _) ->
       fail "approved request must not report a fresh cancellation"
   | Error msg -> fail msg);
  let after = Goal_verification.read_state config in
  check int "version unchanged on already resolved cancel" before.version after.version;
  let saved =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "request missing after already resolved cancel"
  in
  check bool "saved status still approved" true
    (saved.status = Goal_verification.Approved)

let test_create_request_keeps_primary_commit_when_recovery_write_fails () =
  with_workspace @@ fun config ->
  Unix.mkdir (requests_recovery_path config) 0o755;
  let requested_by = operator "planner" in
  let request =
    match
      Goal_verification.create_request
        config
        ~goal_id:"goal-1"
        ~requested_by
        ~policy_snapshot:(request_snapshot ~requested_by)
    with
    | Ok request -> request
    | Error msg ->
      fail
        ("recovery mirror failure should not fail committed primary write: " ^ msg)
  in
  match Goal_verification.find_request config ~request_id:request.id with
  | Some stored -> check string "primary has request" request.id stored.id
  | None -> fail "primary request missing after recovery mirror failure"

let test_read_state_result_reports_corrupt_primary_and_recovery () =
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  (match
     Goal_verification.create_request
       config
       ~goal_id:"goal-1"
       ~requested_by
       ~policy_snapshot:(request_snapshot ~requested_by)
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let write_text path content =
    Out_channel.with_open_text path (fun oc -> output_string oc content)
  in
  write_text (Goal_verification.requests_path config) "{not-json";
  write_text (requests_recovery_path config) "{not-json";
  (match Goal_verification.read_state_result config with
   | Error msg ->
     check bool "read error reported" true (String.length msg > 0)
   | Ok _ -> fail "expected corrupt primary/recovery read failure");
  let legacy = Goal_verification.read_state config in
  check int "legacy wrapper returns default requests" 0 (List.length legacy.requests)

let () =
  run "Goal_verification"
    [
      ( "state_integrity",
        [
          test_case "missing cancel: no bump" `Quick
            test_cancel_missing_request_does_not_bump;
          test_case "invalid vote: no bump" `Quick
            test_invalid_vote_does_not_bump;
          test_case "cancel if open reports already resolved" `Quick
            test_cancel_if_open_reports_already_resolved;
          test_case "recovery mirror write failure preserves primary" `Quick
            test_create_request_keeps_primary_commit_when_recovery_write_fails;
          test_case "read_state_result reports corrupt primary and recovery" `Quick
            test_read_state_result_reports_corrupt_primary_and_recovery;
        ] );
    ]

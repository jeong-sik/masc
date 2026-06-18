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

let request_snapshot ?(required_verdicts = 2) ~requested_by () =
  let reviewer = operator "reviewer-1" in
  let verifier = agent "agent-a" in
  let principals = [ requested_by; reviewer; verifier ] in
  {
    Goal_verification.principals;
    eligible_principals = [ reviewer; verifier ];
    required_verdicts;
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
        ~policy_snapshot:(request_snapshot ~requested_by ())
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let before = Goal_verification.read_state config in
  (match
     Goal_verification.submit_vote config ~request_id:request.id
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

let test_resolved_requests_bounded () =
  (* Cap resolved requests via a small env value, create more resolved
     requests than the cap plus one Open request, and verify: (1) total
     requests == cap + open count, (2) the Open request survives, (3) the
     oldest resolved request is pruned. Proves the prune is
     correctness-preserving for active quorum (Open) while bounding
     long-lived growth. *)
  Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "3";
  Fun.protect ~finally:(fun () ->
      Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "")
  @@ fun () ->
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let mk i =
    match
      Goal_verification.create_request config
        ~goal_id:(Printf.sprintf "goal-%d" i) ~requested_by
        ~policy_snapshot:(request_snapshot ~requested_by ())
    with
    | Ok r -> r
    | Error msg -> fail msg
  in
  (* 5 resolved (Cancelled) requests — exceeds the cap of 3 *)
  let resolved_ids = List.init 5 (fun i -> (mk i).id) in
  List.iter
    (fun id ->
      match Goal_verification.cancel_request config ~request_id:id with
      | Ok _ -> ()
      | Error msg -> fail msg)
    resolved_ids;
  (* 1 Open request that must survive the cap *)
  let open_req = mk 6 in
  let state = Goal_verification.read_state config in
  check int "requests bounded to cap + open" 4 (List.length state.requests);
  (match Goal_verification.find_request config ~request_id:open_req.id with
   | Some r ->
       (match r.Goal_verification.status with
        | Goal_verification.Open -> ()
        | _ -> fail "open request has non-Open status after cap")
   | None -> fail "open request dropped by cap");
  (* Oldest resolved request (index 0, first created) must be pruned. *)
  (match Goal_verification.find_request config ~request_id:(List.nth resolved_ids 0) with
   | None -> ()
   | Some _ -> fail "oldest resolved request not pruned")

let test_cancel_request_prunes_on_direct_write () =
  Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "3";
  Fun.protect ~finally:(fun () ->
      Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "")
  @@ fun () ->
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let mk i =
    match
      Goal_verification.create_request config
        ~goal_id:(Printf.sprintf "cancel-goal-%d" i) ~requested_by
        ~policy_snapshot:(request_snapshot ~requested_by ())
    with
    | Ok r -> r
    | Error msg -> fail msg
  in
  let ids = List.init 5 (fun i -> (mk i).id) in
  List.iter
    (fun id ->
      match Goal_verification.cancel_request config ~request_id:id with
      | Ok _ -> ()
      | Error msg -> fail msg)
    ids;
  let state = Goal_verification.read_state config in
  check int "direct cancel writes are capped" 3 (List.length state.requests);
  (match Goal_verification.find_request config ~request_id:(List.nth ids 0) with
   | None -> ()
   | Some _ -> fail "oldest cancelled request not pruned by direct write")

let test_submit_vote_prunes_on_direct_write () =
  Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "3";
  Fun.protect ~finally:(fun () ->
      Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "")
  @@ fun () ->
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let voter = operator "reviewer-1" in
  let mk i =
    match
      Goal_verification.create_request config
        ~goal_id:(Printf.sprintf "vote-goal-%d" i) ~requested_by
        ~policy_snapshot:(request_snapshot ~required_verdicts:1 ~requested_by ())
    with
    | Ok r -> r
    | Error msg -> fail msg
  in
  let ids = List.init 5 (fun i -> (mk i).id) in
  List.iter
    (fun id ->
      match
        Goal_verification.submit_vote config ~request_id:id ~principal:voter
          ~decision:Goal_verification.Approve ()
      with
      | Ok _ -> ()
      | Error msg -> fail msg)
    ids;
  let state = Goal_verification.read_state config in
  check int "direct vote writes are capped" 3 (List.length state.requests);
  (match Goal_verification.find_request config ~request_id:(List.nth ids 0) with
   | None -> ()
   | Some _ -> fail "oldest approved request not pruned by direct write")

let test_late_resolution_survives_cap () =
  Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "3";
  Fun.protect ~finally:(fun () ->
      Unix.putenv "MASC_GOAL_VERIFICATION_MAX_RESOLVED" "")
  @@ fun () ->
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let mk goal_id =
    match
      Goal_verification.create_request config ~goal_id ~requested_by
        ~policy_snapshot:(request_snapshot ~requested_by ())
    with
    | Ok r -> r
    | Error msg -> fail msg
  in
  let old_open = mk "old-open" in
  let newer = List.init 5 (fun i -> mk (Printf.sprintf "newer-%d" i)) in
  List.iter
    (fun (request : Goal_verification.goal_verification_request) ->
      match Goal_verification.cancel_request config ~request_id:request.id with
      | Ok _ -> ()
      | Error msg -> fail msg)
    newer;
  (match Goal_verification.cancel_request config ~request_id:old_open.id with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let state = Goal_verification.read_state config in
  check int "resolved cap still applies" 3 (List.length state.requests);
  match Goal_verification.find_request config ~request_id:old_open.id with
  | Some request ->
    (match request.Goal_verification.status with
     | Goal_verification.Cancelled -> ()
     | _ -> fail "late-resolved request has unexpected status")
  | None -> fail "late-resolved old request was pruned immediately"

let () =
  run "Goal_verification"
    [
      ( "state_integrity",
        [
          test_case "missing cancel: no bump" `Quick
            test_cancel_missing_request_does_not_bump;
          test_case "invalid vote: no bump" `Quick
            test_invalid_vote_does_not_bump;
        ] );
      ( "bounded_growth",
        [
          test_case "resolved requests capped, open preserved"
            `Quick test_resolved_requests_bounded;
          test_case "cancel_request direct writes are capped"
            `Quick test_cancel_request_prunes_on_direct_write;
          test_case "submit_vote direct writes are capped"
            `Quick test_submit_vote_prunes_on_direct_write;
          test_case "late resolution survives resolved cap"
            `Quick test_late_resolution_survives_cap;
        ] );
    ]

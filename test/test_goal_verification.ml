(** Tests for Goal_verification error paths preserving state. *)

open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()

module StringSet = Set.Make (String)

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

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0 then true
    else if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  loop 0

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let read_source_file rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  read_file (Filename.concat source_root rel)

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

let request_snapshot ~requested_by =
  let reviewer = operator "reviewer-1" in
  let verifier = agent "agent-a" in
  let principals = [ requested_by; reviewer; verifier ] in
  {
    Goal_verification.principals;
    eligible_principals = [ reviewer; verifier ];
    required_verdicts = 2;
  }

let three_reviewer_snapshot ~requested_by =
  let reviewer_1 = operator "reviewer-1" in
  let reviewer_2 = operator "reviewer-2" in
  let reviewer_3 = operator "reviewer-3" in
  let principals = [ requested_by; reviewer_1; reviewer_2; reviewer_3 ] in
  {
    Goal_verification.principals;
    eligible_principals = [ reviewer_1; reviewer_2; reviewer_3 ];
    required_verdicts = 2;
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

let test_reject_does_not_seal_when_quorum_still_reachable () =
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let request =
    match
      Goal_verification.create_request
        config
        ~goal_id:"goal-1"
        ~requested_by
        ~policy_snapshot:(three_reviewer_snapshot ~requested_by)
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let submit principal decision =
    match
      Goal_verification.submit_vote
        config
        ~goal_id:"goal-1"
        ~request_id:request.id
        ~principal
        ~decision
        ()
    with
    | Ok result -> result
    | Error msg -> fail msg
  in
  (match submit (operator "reviewer-1") Goal_verification.Reject with
   | updated, Goal_verification.Pending ->
     check bool "reject leaves request open" true
       (updated.status = Goal_verification.Open);
     check int "one reject vote recorded" 1 (List.length updated.votes)
   | _ -> fail "single reject must remain pending while quorum is reachable");
  (match submit (operator "reviewer-2") Goal_verification.Approve with
   | updated, Goal_verification.Pending ->
     check bool "one approve plus one reject stays open" true
       (updated.status = Goal_verification.Open);
     check int "two votes recorded" 2 (List.length updated.votes)
   | _ -> fail "one approve after one reject must not seal before quorum");
  (match submit (operator "reviewer-3") Goal_verification.Approve with
   | updated, Goal_verification.Passed ->
     check bool "second approve seals request" true
       (updated.status = Goal_verification.Approved);
     check int "all votes recorded" 3 (List.length updated.votes)
   | _ -> fail "second approve must pass reachable quorum")

let test_reject_seals_only_when_quorum_unreachable () =
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
  (match
     Goal_verification.submit_vote
       config
       ~goal_id:"goal-1"
       ~request_id:request.id
       ~principal:(operator "reviewer-1")
       ~decision:Goal_verification.Reject
       ()
   with
   | Ok (updated, Goal_verification.Failed) ->
     check bool "unreachable quorum rejects request" true
       (updated.status = Goal_verification.Rejected);
     check int "reject vote recorded" 1 (List.length updated.votes)
   | Ok _ -> fail "reject must fail only after quorum becomes unreachable"
   | Error msg -> fail msg);
  (match
     Goal_verification.submit_vote
       config
       ~goal_id:"goal-1"
       ~request_id:request.id
       ~principal:(agent "agent-a")
       ~decision:Goal_verification.Approve
       ()
   with
   | Error msg ->
     check bool "sealed request refuses later vote" true
       (contains_substring msg "not open")
   | Ok _ -> fail "sealed rejected request must not accept later votes")

let test_vote_rejects_request_goal_mismatch () =
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
     Goal_verification.submit_vote config ~goal_id:"goal-2" ~request_id:request.id
       ~principal:(agent "agent-a") ~decision:Goal_verification.Approve ()
   with
   | Error msg ->
     check
       bool
       "mismatch error explains ownership"
       true
       (contains_substring msg "does not belong")
   | Ok _ -> fail "expected request/goal mismatch error");
  let after = Goal_verification.read_state config in
  check int "version unchanged on mismatched goal vote" before.version after.version;
  let saved =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "request missing after mismatched goal vote"
  in
  check int "no votes written after mismatched goal" 0 (List.length saved.votes)

let test_effective_policy_rejects_missing_parent () =
  let child_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals = [ agent "agent-a" ]
    ; required_verdicts = Some 1
    }
  in
  let goals =
    [ { Goal_verification.goal_id = "child"
      ; parent_goal_id = Some "missing-parent"
      ; verifier_policy = Some child_policy
      }
    ]
  in
  match Goal_verification.effective_policy_for_nodes ~goals ~goal_id:"child" with
  | Error msg ->
    check
      bool
      "error names missing parent"
      true
      (contains_substring msg "missing-parent")
  | Ok _ -> fail "expected missing parent to reject effective policy"

let test_effective_policy_rejects_parent_cycle () =
  let root_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals = [ agent "agent-a" ]
    ; required_verdicts = Some 1
    }
  in
  let goals =
    [ { Goal_verification.goal_id = "goal-a"
      ; parent_goal_id = Some "goal-b"
      ; verifier_policy = Some root_policy
      }
    ; { Goal_verification.goal_id = "goal-b"
      ; parent_goal_id = Some "goal-a"
      ; verifier_policy = None
      }
    ]
  in
  match Goal_verification.effective_policy_for_nodes ~goals ~goal_id:"goal-a" with
  | Error msg ->
    check bool "error names parent cycle" true (contains_substring msg "cycle");
    check bool "error names cycle edge" true (contains_substring msg "goal-b -> goal-a")
  | Ok _ -> fail "expected parent cycle to reject effective policy"

let test_create_request_ids_are_unique_in_burst () =
  with_workspace @@ fun config ->
  let requested_by = operator "planner" in
  let policy_snapshot = request_snapshot ~requested_by in
  let rec create acc = function
    | 0 -> acc
    | n ->
      let request =
        match
          Goal_verification.create_request
            config
            ~goal_id:"goal-burst"
            ~requested_by
            ~policy_snapshot
        with
        | Ok request -> request
        | Error msg -> fail msg
      in
      create (request.id :: acc) (n - 1)
  in
  let ids = create [] 64 in
  let unique =
    List.fold_left (fun set id -> StringSet.add id set) StringSet.empty ids
  in
  check int "all burst request ids unique" (List.length ids) (StringSet.cardinal unique)

let test_request_ids_use_random_id_source_guard () =
  let source = read_source_file "lib/goal/goal_verification.ml" in
  check bool "verification request id uses Random_id" true
    (contains_substring source "Random_id.prefixed ~prefix:\"gvr-\" ~bytes:16");
  check bool "old millisecond request id shape absent" false
    (contains_substring source "gvr-%d-%x-%x-%08x");
  check bool "old request id counter absent" false
    (contains_substring source "request_id_counter")

let test_create_request_fails_closed_on_unrecoverable_corrupt_state () =
  with_workspace @@ fun config ->
  let path = Goal_verification.requests_path config in
  let recovery = path ^ ".last-good" in
  let corrupt = "{not-valid-goal-verification-json" in
  write_file path corrupt;
  if Sys.file_exists recovery then Sys.remove recovery;
  let requested_by = operator "planner" in
  (match
     Goal_verification.create_request
       config
       ~goal_id:"goal-corrupt"
       ~requested_by
       ~policy_snapshot:(request_snapshot ~requested_by)
   with
   | Error msg ->
     check
       bool
       "create rejects unreadable state"
       true
       (contains_substring msg "failed to read goal verification state")
   | Ok _ -> fail "corrupt state must not be overwritten by create_request");
  check string "primary corrupt file preserved" corrupt (read_file path);
  check bool "missing recovery still missing" false (Sys.file_exists recovery)

let test_read_state_result_surfaces_unrecoverable_corrupt_state () =
  with_workspace @@ fun config ->
  let path = Goal_verification.requests_path config in
  let recovery = path ^ ".last-good" in
  let corrupt_primary = "{primary-corrupt-read" in
  let corrupt_recovery = "{recovery-corrupt-read" in
  write_file path corrupt_primary;
  write_file recovery corrupt_recovery;
  (match Goal_verification.read_state_result config with
   | Error msg ->
     check
       bool
       "result reader names verification state failure"
       true
       (contains_substring msg "failed to read goal verification state")
   | Ok _ -> fail "result reader must not hide corrupt verification state");
  (match Goal_verification.find_request_result config ~request_id:"missing" with
   | Error msg ->
     check
       bool
       "result lookup names verification state failure"
       true
       (contains_substring msg "failed to read goal verification state")
   | Ok _ -> fail "result lookup must not hide corrupt verification state");
  let legacy_projection = Goal_verification.read_state config in
  check int "legacy read-only projection stays empty" 0
    (List.length legacy_projection.requests);
  check string "primary corrupt file preserved" corrupt_primary (read_file path);
  check string "recovery corrupt file preserved" corrupt_recovery (read_file recovery)

let test_dashboard_goals_uses_result_reader_source_guard () =
  let source = read_source_file "lib/dashboard/dashboard_goals.ml" in
  check
    bool
    "dashboard uses fail-closed verification reader"
    true
    (contains_substring source "Goal_verification.read_state_result");
  check
    bool
    "dashboard exposes unreadable verification diagnostics"
    true
    (contains_substring source "goal_verification_state_unreadable");
  check
    bool
    "dashboard no longer reads verification state as empty projection"
    false
    (contains_substring source "Goal_verification.read_state config")

let test_submit_vote_fails_closed_on_corrupt_primary_and_recovery () =
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
  let path = Goal_verification.requests_path config in
  let recovery = path ^ ".last-good" in
  let corrupt_primary = "{primary-corrupt" in
  let corrupt_recovery = "{recovery-corrupt" in
  write_file path corrupt_primary;
  write_file recovery corrupt_recovery;
  (match
     Goal_verification.submit_vote
       config
       ~goal_id:"goal-1"
       ~request_id:request.id
       ~principal:(agent "agent-a")
       ~decision:Goal_verification.Approve
       ()
   with
   | Error msg ->
     check
       bool
       "vote rejects unreadable state"
       true
       (contains_substring msg "failed to read goal verification state")
   | Ok _ -> fail "corrupt state must not be overwritten by submit_vote");
  check string "primary corrupt file preserved" corrupt_primary (read_file path);
  check string "recovery corrupt file preserved" corrupt_recovery (read_file recovery)

let test_submit_vote_recovers_from_last_good_when_primary_missing () =
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
  let path = Goal_verification.requests_path config in
  let recovery = path ^ ".last-good" in
  check bool "recovery exists after create" true (Sys.file_exists recovery);
  Sys.remove path;
  (match
     Goal_verification.submit_vote
       config
       ~goal_id:"goal-1"
       ~request_id:request.id
       ~principal:(operator "reviewer-1")
       ~decision:Goal_verification.Approve
       ()
   with
   | Error msg -> fail msg
   | Ok (updated, _outcome) ->
     check int "vote persisted after recovery" 1 (List.length updated.votes));
  check bool "primary restored after recovery write" true (Sys.file_exists path);
  let saved =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "request missing after primary recovery"
  in
  check int "saved vote count" 1 (List.length saved.votes)

let test_submit_vote_fails_closed_on_missing_primary_and_corrupt_recovery () =
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
  let path = Goal_verification.requests_path config in
  let recovery = path ^ ".last-good" in
  let corrupt_recovery = "{recovery-corrupt" in
  Sys.remove path;
  write_file recovery corrupt_recovery;
  (match
     Goal_verification.submit_vote
       config
       ~goal_id:"goal-1"
       ~request_id:request.id
       ~principal:(operator "reviewer-1")
       ~decision:Goal_verification.Approve
       ()
   with
   | Error msg ->
     check
       bool
       "vote rejects missing primary with corrupt recovery"
       true
       (contains_substring msg "failed to read goal verification state")
   | Ok _ -> fail "corrupt recovery must not be overwritten by submit_vote");
  check bool "primary still missing" false (Sys.file_exists path);
  check string "recovery corrupt file preserved" corrupt_recovery (read_file recovery)

let () =
  run "Goal_verification"
    [
      ( "state_integrity",
        [
          test_case "missing cancel: no bump" `Quick
            test_cancel_missing_request_does_not_bump;
          test_case "invalid vote: no bump" `Quick
            test_invalid_vote_does_not_bump;
          test_case "reject pending while quorum reachable" `Quick
            test_reject_does_not_seal_when_quorum_still_reachable;
          test_case "reject seals only when quorum unreachable" `Quick
            test_reject_seals_only_when_quorum_unreachable;
          test_case "request goal mismatch: no bump" `Quick
            test_vote_rejects_request_goal_mismatch;
          test_case "missing parent policy: error" `Quick
            test_effective_policy_rejects_missing_parent;
          test_case "parent cycle policy: error" `Quick
            test_effective_policy_rejects_parent_cycle;
          test_case "request ids unique in burst" `Quick
            test_create_request_ids_are_unique_in_burst;
          test_case "request ids use random source" `Quick
            test_request_ids_use_random_id_source_guard;
          test_case "corrupt state: create fails closed" `Quick
            test_create_request_fails_closed_on_unrecoverable_corrupt_state;
          test_case "corrupt state: result reader surfaces failure" `Quick
            test_read_state_result_surfaces_unrecoverable_corrupt_state;
          test_case "dashboard goals uses result reader" `Quick
            test_dashboard_goals_uses_result_reader_source_guard;
          test_case "corrupt state: vote fails closed" `Quick
            test_submit_vote_fails_closed_on_corrupt_primary_and_recovery;
          test_case "missing primary: vote recovers from last-good" `Quick
            test_submit_vote_recovers_from_last_good_when_primary_missing;
          test_case "missing primary: corrupt recovery fails closed" `Quick
            test_submit_vote_fails_closed_on_missing_primary_and_corrupt_recovery;
        ] );
    ]

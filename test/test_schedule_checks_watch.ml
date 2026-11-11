open Alcotest
open Masc
module Watch = Schedule_run_watch
module Checks = Schedule_checks_watch

(* The commit watch: how a commit URL and a stored watch are read, how the
   runs answer of GitHub becomes "settled or not", and one pass of [tick] over
   a real schedule store. The runs answer used for the main cases is the one
   GitHub gave for the head of jeong-sik/masc#51286, reduced to the fields the
   reader looks at. *)

let sha = "8b666a19e3455100528bb90b861374c56e563f82"
let repo_exn raw =
  match Watch.repo_of_string raw with
  | Ok repo -> repo
  | Error detail -> fail detail
;;

let sha_exn raw =
  match Checks.sha_of_string raw with
  | Ok sha -> sha
  | Error detail -> fail detail
;;

let target = { Checks.repo = repo_exn "jeong-sik/masc"; sha = sha_exn sha }

let commit_url = "https://github.com/jeong-sik/masc/commit/" ^ sha

(* --- The runs answer --- *)

let run_json ?(head = sha) ?(conclusion = `Null) ~name ~event ~status () =
  `Assoc
    [ "name", `String name
    ; "event", `String event
    ; "head_sha", `String head
    ; "status", `String status
    ; "conclusion", conclusion
    ]
;;

let approval_target =
  run_json ~name:"Approval merge request" ~event:"pull_request_target" ~status:"completed" ~conclusion:(`String "success") ()
;;

let approval_review =
  run_json ~name:"Approval merge request" ~event:"pull_request_review" ~status:"completed" ~conclusion:(`String "success") ()
;;

let type_check_cancelled =
  run_json ~name:"PR type-check (dune build @check)" ~event:"pull_request" ~status:"completed" ~conclusion:(`String "cancelled") ()
;;

let changelog =
  run_json ~name:"Changelog fragments" ~event:"pull_request" ~status:"completed" ~conclusion:(`String "success") ()
;;

let type_check_failed =
  run_json ~name:"PR type-check (dune build @check)" ~event:"pull_request" ~status:"completed" ~conclusion:(`String "failure") ()
;;

let answer ?total runs =
  let total = Option.value total ~default:(List.length runs) in
  `Assoc [ "total_count", `Int total; "workflow_runs", `List runs ]
;;

(* The eight runs of the head, in the order GitHub lists them. *)
let runs_51286 =
  [ approval_target
  ; approval_target
  ; approval_review
  ; type_check_cancelled
  ; changelog
  ; changelog
  ; type_check_failed
  ; approval_review
  ]
;;

let describe_check_run (r : Checks.check_run) =
  Printf.sprintf
    "%s (%s): %s"
    r.Checks.workflow
    (Checks.event_to_string r.Checks.event)
    (match r.Checks.conclusion with
     | Some conclusion -> Watch.conclusion_to_string conclusion
     | None -> "none")
;;

let describe_observation = function
  | Ok Checks.Not_settled -> "not settled"
  | Ok (Checks.Settled runs) ->
    "settled: " ^ String.concat "; " (List.map describe_check_run runs)
  | Error detail -> "error: " ^ detail
;;

let observation json = Checks.observation_of_runs_json target json

let check_observation label expected json =
  check string label expected (describe_observation (observation json))
;;

let check_refused label json =
  match observation json with
  | Error _ -> ()
  | Ok _ -> fail (label ^ ": expected an error, got " ^ describe_observation (observation json))
;;

let test_the_head_of_51286_is_settled_by_its_four_pull_request_runs () =
  check_observation
    "only the four pull_request runs are the checks"
    "settled: PR type-check (dune build @check) (pull_request): cancelled; Changelog \
     fragments (pull_request): success; Changelog fragments (pull_request): success; PR \
     type-check (dune build @check) (pull_request): failure"
    (answer runs_51286)
;;

(* At 09:34:40Z the head had only the approval runs, all ended. Reading every
   run, "all runs ended" was already true; reading the check runs, no check was
   there yet. *)
let test_approval_runs_alone_are_not_the_checks () =
  check_observation
    "approval runs ended, no check run yet"
    "not settled"
    (answer [ approval_target; approval_target; approval_review ])
;;

let test_a_check_run_that_has_not_completed_holds_the_wake () =
  let running =
    run_json ~name:"PR type-check (dune build @check)" ~event:"pull_request" ~status:"in_progress" ()
  in
  check_observation "one check run in progress" "not settled" (answer [ approval_target; changelog; running ]);
  let queued = run_json ~name:"Test" ~event:"push" ~status:"queued" () in
  check_observation "one check run queued" "not settled" (answer [ changelog; queued ])
;;

let test_an_approval_run_in_progress_does_not_hold_the_wake () =
  let approval_running =
    run_json ~name:"Approval merge request" ~event:"pull_request_review" ~status:"in_progress" ()
  in
  check_observation
    "checks completed while an approval run is still going"
    "settled: Changelog fragments (pull_request): success"
    (answer [ changelog; approval_running ])
;;

let test_an_answer_without_runs_is_not_settled () =
  check_observation "no run at all" "not settled" (answer [])
;;

let test_a_completed_run_may_have_no_conclusion () =
  check_observation
    "a null conclusion is kept as none"
    "settled: Test (push): none"
    (answer [ run_json ~name:"Test" ~event:"push" ~status:"completed" () ])
;;

let test_a_workflow_run_event_is_a_check () =
  check_observation
    "workflow_run"
    "settled: Report (workflow_run): success"
    (answer
       [ run_json ~name:"Report" ~event:"workflow_run" ~status:"completed" ~conclusion:(`String "success") () ])
;;

let test_an_answer_that_cannot_be_trusted_is_an_error () =
  check_refused
    "an incomplete answer still rejects another commit"
    (answer ~total:101 [ run_json ~head:(String.make 40 'a') ~name:"Test" ~event:"push" ~status:"completed" () ]);
  check_refused
    "an incomplete answer still rejects a missing status"
    (answer ~total:101 [ `Assoc [ "name", `String "Test"; "event", `String "push"; "head_sha", `String sha; "status", `Null ] ]);
  check_refused "a run of another commit" (answer [ changelog; run_json ~head:(String.make 40 'a') ~name:"Test" ~event:"push" ~status:"completed" () ]);
  check_refused "an error body" (`Assoc [ "message", `String "Not Found" ]);
  check_refused "not an object" (`List []);
  check_refused "no total_count" (`Assoc [ "workflow_runs", `List [] ]);
  check_refused "workflow_runs is not a list" (`Assoc [ "total_count", `Int 0; "workflow_runs", `Null ]);
  check_refused "a run is not an object" (answer [ `String "run" ]);
  check_refused
    "status is null"
    (answer [ `Assoc [ "name", `String "Test"; "event", `String "push"; "head_sha", `String sha; "status", `Null ] ]);
  check_refused
    "conclusion is a number"
    (answer
       [ `Assoc
           [ "name", `String "Test"
           ; "event", `String "push"
           ; "head_sha", `String sha
           ; "status", `String "completed"
           ; "conclusion", `Int 1
           ]
       ])
;;

let test_a_short_page_is_not_an_error () =
  check_observation
    "total_count is more than the runs carried: wait for the next page"
    "not settled"
    (answer ~total:101 runs_51286)
;;

let test_a_head_sha_in_upper_case_is_the_same_commit () =
  check_observation
    "case is ignored"
    "settled: Changelog fragments (pull_request): success"
    (answer
       [ run_json ~head:(String.uppercase_ascii sha) ~name:"Changelog fragments" ~event:"pull_request" ~status:"completed" ~conclusion:(`String "success") ()
       ])
;;

(* --- Commit and stored watch --- *)

let target_text = function
  | Ok (t : Checks.target) -> Checks.target_url t
  | Error detail -> "error: " ^ detail
;;

let test_a_commit_url_is_read () =
  check string "plain" commit_url (target_text (Checks.target_of_commit_url commit_url));
  check string "trailing slash" commit_url (target_text (Checks.target_of_commit_url (commit_url ^ "/")));
  check string "fragment and query" commit_url (target_text (Checks.target_of_commit_url (commit_url ^ "?diff=split#diff-1")));
  check string "surrounding space" commit_url (target_text (Checks.target_of_commit_url ("  " ^ commit_url ^ "\n")));
  check
    string
    "upper case digits become lower case"
    commit_url
    (target_text
       (Checks.target_of_commit_url ("https://github.com/jeong-sik/masc/commit/" ^ String.uppercase_ascii sha)))
;;

let test_a_url_that_is_not_a_full_commit_is_refused () =
  List.iter
    (fun (label, raw) ->
      match Checks.target_of_commit_url raw with
      | Error _ -> ()
      | Ok t -> fail (label ^ ": read as " ^ Checks.target_url t))
    [ "short sha", "https://github.com/jeong-sik/masc/commit/8b666a19e345"
    ; "41 digits", commit_url ^ "0"
    ; "not hexadecimal", "https://github.com/jeong-sik/masc/commit/" ^ String.make 40 'g'
    ; "a pull request", "https://github.com/jeong-sik/masc/pull/51286"
    ; "a run", "https://github.com/jeong-sik/masc/actions/runs/9"
    ; "another host", "https://gitlab.com/jeong-sik/masc/commit/" ^ sha
    ; "http", "http://github.com/jeong-sik/masc/commit/" ^ sha
    ; "a sub path", commit_url ^ "/files"
    ; "no repository", "https://github.com/jeong-sik/commit/" ^ sha
    ; "empty", ""
    ]
;;

let test_the_stored_watch_round_trips_and_is_strict () =
  (match Checks.target_of_yojson (Checks.target_to_yojson target) with
   | Ok back -> check string "round trip" commit_url (Checks.target_url back)
   | Error detail -> fail detail);
  List.iter
    (fun (label, json) ->
      match Checks.target_of_yojson json with
      | Error _ -> ()
      | Ok t -> fail (label ^ ": read as " ^ Checks.target_url t))
    [ "unknown field", `Assoc [ "repo", `String "jeong-sik/masc"; "sha", `String sha; "branch", `String "main" ]
    ; "short sha", `Assoc [ "repo", `String "jeong-sik/masc"; "sha", `String "8b666a1" ]
    ; "no sha", `Assoc [ "repo", `String "jeong-sik/masc" ]
    ; "no repo", `Assoc [ "sha", `String sha ]
    ; "repo without an owner", `Assoc [ "repo", `String "masc"; "sha", `String sha ]
    ; "sha is a number", `Assoc [ "repo", `String "jeong-sik/masc"; "sha", `Int 1 ]
    ; "not an object", `String commit_url
    ]
;;

let keeper_wake ?(extra = []) ~message watch =
  let watch_fields =
    match watch with
    | None -> []
    | Some t -> [ Checks.watch_field, Checks.target_to_yojson t ]
  in
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          ([ "keeper_name", `String "k-1"; "message", `String message ] @ extra @ watch_fields) )
    ]
;;

let test_the_watch_is_read_from_a_keeper_wake_payload () =
  (match Checks.watch_of_payload (keeper_wake ~message:"merge" (Some target)) with
   | Ok (Some t) -> check string "the watch" commit_url (Checks.target_url t)
   | Ok None -> fail "no watch read"
   | Error detail -> fail detail);
  (match Checks.watch_of_payload (keeper_wake ~message:"merge" None) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "a payload without the field has no watch");
  (match Checks.watch_of_payload (`Assoc [ "kind", `String "other"; "body", `Assoc [] ]) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "a payload that is not a Keeper wake has no watch");
  (match
     Checks.watch_of_payload
       (`Assoc
           [ "kind", `String Schedule_supported_kinds.keeper_wake
           ; ( "body"
             , `Assoc
                 [ "keeper_name", `String "k-1"
                 ; "message", `String "m"
                 ; Checks.watch_field, `Assoc [ "repo", `String "jeong-sik/masc" ]
                 ] )
           ])
   with
   | Error _ -> ()
   | Ok _ -> fail "a watch without a sha is an error, not an absent watch")
;;

(* A run watch is not a checks watch: the two fields do not read each other. *)
let test_a_run_watch_is_not_a_checks_watch () =
  let run_target = { Watch.repo = repo_exn "jeong-sik/masc"; run_id = 9; run_attempt = None } in
  let payload =
    `Assoc
      [ "kind", `String Schedule_supported_kinds.keeper_wake
      ; ( "body"
        , `Assoc
            [ "keeper_name", `String "k-1"
            ; "message", `String "m"
            ; Watch.watch_field, Watch.target_to_yojson run_target
            ] )
      ]
  in
  match Checks.watch_of_payload payload with
  | Ok None -> ()
  | Ok (Some _) | Error _ -> fail "the checks watch reads only its own field"
;;

(* --- The wake --- *)

let completed_runs =
  [ { Checks.workflow = "PR type-check"
    ; event = Checks.Pull_request
    ; conclusion = Some Watch.Failure
    }
  ; { Checks.workflow = "Changelog fragments"
    ; event = Checks.Pull_request
    ; conclusion = Some Watch.Success
    }
  ; { Checks.workflow = "Test"; event = Checks.Push; conclusion = None }
  ]
;;

let test_the_wake_message_lists_each_check_run () =
  check
    string
    "message"
    (String.concat
       "\n"
       [ "[github_checks_watch] jeong-sik/masc commit 8b666a19e345: 3 check runs completed"
       ; "- PR type-check (pull_request): failure"
       ; "- Changelog fragments (pull_request): success"
       ; "- Test (push): no conclusion"
       ; commit_url
       ; ""
       ; "merge if green"
       ])
    (Checks.wake_message target (Checks.Checks_completed completed_runs) ~original:"merge if green")
;;

let test_the_wake_message_of_an_unreadable_wake_says_to_look_yourself () =
  let message =
    Checks.wake_message target (Checks.Checks_unreadable Watch.Not_visible) ~original:"merge if green"
  in
  check bool "names the commit" true (String.starts_with ~prefix:"[github_checks_watch] could not read the runs of jeong-sik/masc commit 8b666a19e345" message);
  check bool "keeps the Keeper's words last" true (String.ends_with ~suffix:"\n\nmerge if green" message)
;;

let message_of_payload payload =
  match payload with
  | `Assoc fields ->
    (match List.assoc_opt "body" fields with
     | Some (`Assoc body) ->
       (match List.assoc_opt "message" body with
        | Some (`String message) -> message
        | Some _ | None -> fail "no message")
     | Some _ | None -> fail "no body")
  | _ -> fail "payload is not an object"
;;

let test_settling_a_payload_drops_the_watch_and_swaps_the_message () =
  let payload = keeper_wake ~extra:[ "urgency", `String "immediate" ] ~message:"merge if green" (Some target) in
  match Checks.settle_payload payload target (Checks.Checks_completed completed_runs) with
  | Error detail -> fail detail
  | Ok settled ->
    (match Checks.watch_of_payload settled with
     | Ok None -> ()
     | Ok (Some _) | Error _ -> fail "the watch is removed");
    check
      string
      "the message"
      (Checks.wake_message target (Checks.Checks_completed completed_runs) ~original:"merge if green")
      (message_of_payload settled);
    (match settled with
     | `Assoc fields ->
       (match List.assoc_opt "body" fields with
        | Some (`Assoc body) ->
          check bool "other fields stay" true (List.mem_assoc "urgency" body && List.mem_assoc "keeper_name" body)
        | Some _ | None -> fail "no body")
     | _ -> fail "payload is not an object")
;;

let test_settling_a_payload_that_is_not_a_keeper_wake_is_an_error () =
  match
    Checks.settle_payload
      (`Assoc [ "kind", `String "other"; "body", `Assoc [] ])
      target
      (Checks.Checks_completed completed_runs)
  with
  | Error _ -> ()
  | Ok _ -> fail "expected an error"
;;

(* --- One pass --- *)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_dir "schedule_checks_watch_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf path);
  let config = Workspace.default_config path in
  ignore (Workspace.init config ~agent_name:(Some "checks-watch-test"));
  f config
;;

let runner_tick_sec = 1.0

let person id =
  { Schedule_domain.id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let create_row config ?(schedule_id = "s-1") ?(due_at = 200.0) ?recurrence payload =
  match
    Schedule_service.create
      config
      ~now:100.0
      ~runner_tick_sec
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(person "requester")
      ~scheduled_by:(person "scheduler")
      ~due_at
      ~payload
      ~source:Schedule_domain.Operator_request
      ?recurrence
      ()
  with
  | Ok request -> request
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

let row config schedule_id =
  match Schedule_store.get_schedule config ~schedule_id with
  | Some request -> request
  | None -> fail ("no schedule " ^ schedule_id)
;;

let message_of (request : Schedule_domain.schedule_request) =
  message_of_payload (Schedule_domain.payload_to_yojson request.Schedule_domain.payload)
;;

let tick_ok config ~read =
  match Checks.tick config ~now:150.5 ~runner_tick_sec ~read with
  | Ok outcomes -> outcomes
  | Error detail -> fail detail
;;

let outcome_of outcomes schedule_id =
  match
    List.find_opt
      (fun (o : Checks.outcome) -> String.equal o.Checks.schedule_id schedule_id)
      outcomes
  with
  | Some outcome -> outcome
  | None -> fail ("no outcome for " ^ schedule_id)
;;

let verdict_to_string = function
  | Checks.Woken (Checks.Checks_completed runs) ->
    Printf.sprintf "woken: %d check runs completed" (List.length runs)
  | Checks.Woken (Checks.Checks_unreadable failure) ->
    "woken: unreadable, " ^ Watch.read_failure_to_string failure
  | Checks.Waiting_for_checks -> "waiting for the checks"
  | Checks.Waiting_to_read failure -> "waiting to read: " ^ Watch.read_failure_to_string failure
  | Checks.Not_woken detail -> "not woken: " ^ detail
;;

(* The reason of a [Not_woken] is a sentence for a person, so only the case is
   compared. *)
let same_verdict a b =
  match a, b with
  | Checks.Not_woken _, Checks.Not_woken _ -> true
  | _ -> a = b
;;

let verdict =
  testable (fun ppf v -> Format.pp_print_string ppf (verdict_to_string v)) same_verdict
;;

let counting_reader ~answer =
  let urls = ref [] in
  let read (t : Checks.target) =
    urls := Checks.target_url t :: !urls;
    answer t
  in
  read, fun () -> List.rev !urls
;;

let settled_runs = [ { Checks.workflow = "Test"; event = Checks.Push; conclusion = Some Watch.Success } ]

let test_checks_that_are_still_going_change_nothing () =
  with_config
  @@ fun config ->
  let before = create_row config (keeper_wake ~message:"check" (Some target)) in
  let read, urls = counting_reader ~answer:(fun _ -> Ok Checks.Not_settled) in
  let outcomes = tick_ok config ~read in
  check verdict "the verdict" Checks.Waiting_for_checks (outcome_of outcomes "s-1").Checks.verdict;
  check (list string) "one read" [ commit_url ] (urls ());
  let after = row config "s-1" in
  check
    string
    "same instance"
    before.Schedule_domain.schedule_instance_id
    after.Schedule_domain.schedule_instance_id;
  check (float 0.0) "same due time" before.Schedule_domain.due_at after.Schedule_domain.due_at;
  check string "same message" "check" (message_of after)
;;

let test_settled_checks_make_the_schedule_due_now () =
  with_config
  @@ fun config ->
  let before = create_row config (keeper_wake ~message:"merge if green" (Some target)) in
  let read, _ = counting_reader ~answer:(fun _ -> Ok (Checks.Settled settled_runs)) in
  let outcomes = tick_ok config ~read in
  check
    verdict
    "the verdict"
    (Checks.Woken (Checks.Checks_completed settled_runs))
    (outcome_of outcomes "s-1").Checks.verdict;
  let after = row config "s-1" in
  check
    bool
    "a new instance"
    false
    (String.equal before.Schedule_domain.schedule_instance_id after.Schedule_domain.schedule_instance_id);
  check (float 0.0) "due at the current second" 150.0 after.Schedule_domain.due_at;
  check string "still scheduled" "scheduled" (Schedule_domain.schedule_status_to_string after.Schedule_domain.status);
  check
    string
    "the message"
    (Checks.wake_message target (Checks.Checks_completed settled_runs) ~original:"merge if green")
    (message_of after);
  (match Checks.watch_of_payload (Schedule_domain.payload_to_yojson after.Schedule_domain.payload) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "the watch is removed");
  (* A second pass finds no watch, so it neither reads nor changes the row. *)
  let read_again, urls = counting_reader ~answer:(fun _ -> Ok (Checks.Settled settled_runs)) in
  check int "nothing left to watch" 0 (List.length (tick_ok config ~read:read_again));
  check (list string) "no read" [] (urls ())
;;

let test_a_due_time_that_has_passed_is_not_moved_later () =
  with_config
  @@ fun config ->
  let before = create_row config ~due_at:120.0 (keeper_wake ~message:"check" (Some target)) in
  let read, _ = counting_reader ~answer:(fun _ -> Ok (Checks.Settled settled_runs)) in
  ignore (tick_ok config ~read);
  check (float 0.0) "the due time stays" before.Schedule_domain.due_at (row config "s-1").Schedule_domain.due_at
;;

let test_a_read_that_can_never_work_wakes_early () =
  with_config
  @@ fun config ->
  ignore (create_row config (keeper_wake ~message:"check" (Some target)));
  let read, _ = counting_reader ~answer:(fun _ -> Error Watch.Not_visible) in
  let outcomes = tick_ok config ~read in
  check
    verdict
    "the verdict"
    (Checks.Woken (Checks.Checks_unreadable Watch.Not_visible))
    (outcome_of outcomes "s-1").Checks.verdict;
  check
    string
    "the message says why"
    (Checks.wake_message target (Checks.Checks_unreadable Watch.Not_visible) ~original:"check")
    (message_of (row config "s-1"))
;;

let test_a_read_that_can_pass_keeps_the_fallback () =
  with_config
  @@ fun config ->
  let before = create_row config (keeper_wake ~message:"check" (Some target)) in
  let failure = Watch.Transport_failed "curl exit code 28" in
  let read, _ = counting_reader ~answer:(fun _ -> Error failure) in
  let outcomes = tick_ok config ~read in
  check verdict "the verdict" (Checks.Waiting_to_read failure) (outcome_of outcomes "s-1").Checks.verdict;
  check
    string
    "same instance"
    before.Schedule_domain.schedule_instance_id
    (row config "s-1").Schedule_domain.schedule_instance_id
;;

let test_one_read_serves_every_schedule_on_the_commit () =
  with_config
  @@ fun config ->
  let other = { target with Checks.sha = sha_exn (String.make 40 'b') } in
  ignore (create_row config ~schedule_id:"a" (keeper_wake ~message:"first" (Some target)));
  ignore (create_row config ~schedule_id:"b" (keeper_wake ~message:"second" (Some target)));
  ignore (create_row config ~schedule_id:"c" (keeper_wake ~message:"third" (Some other)));
  let read, urls = counting_reader ~answer:(fun _ -> Ok (Checks.Settled settled_runs)) in
  let outcomes = tick_ok config ~read in
  check int "three outcomes" 3 (List.length outcomes);
  check
    (list string)
    "one read per commit"
    (List.sort String.compare [ Checks.target_url target; Checks.target_url other ])
    (List.sort String.compare (urls ()))
;;

let test_a_rate_limit_stops_the_pass () =
  with_config
  @@ fun config ->
  let other = { target with Checks.sha = sha_exn (String.make 40 'b') } in
  ignore (create_row config ~schedule_id:"a" (keeper_wake ~message:"first" (Some target)));
  ignore (create_row config ~schedule_id:"b" (keeper_wake ~message:"second" (Some other)));
  let limited = Watch.Rate_limited { reset_at = Some 4000.0 } in
  let read, urls = counting_reader ~answer:(fun _ -> Error limited) in
  let outcomes = tick_ok config ~read in
  check int "one read only" 1 (List.length (urls ()));
  List.iter
    (fun id ->
      check verdict id (Checks.Waiting_to_read limited) (outcome_of outcomes id).Checks.verdict)
    [ "a"; "b" ]
;;

let test_rows_without_a_checks_watch_are_left_alone () =
  with_config
  @@ fun config ->
  ignore (create_row config ~schedule_id:"plain" (keeper_wake ~message:"plain" None));
  ignore
    (create_row
       config
       ~schedule_id:"recurring"
       ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
       (keeper_wake ~message:"every minute" (Some target)));
  let read, urls = counting_reader ~answer:(fun _ -> Ok (Checks.Settled settled_runs)) in
  check int "no outcomes" 0 (List.length (tick_ok config ~read));
  check (list string) "no reads" [] (urls ());
  check string "recurring untouched" "every minute" (message_of (row config "recurring"))
;;

let test_a_stored_watch_that_cannot_be_read_is_reported () =
  with_config
  @@ fun config ->
  let payload =
    `Assoc
      [ "kind", `String Schedule_supported_kinds.keeper_wake
      ; ( "body"
        , `Assoc
            [ "keeper_name", `String "k-1"
            ; "message", `String "check"
            ; Checks.watch_field, `Assoc [ "repo", `String "jeong-sik/masc" ]
            ] )
      ]
  in
  ignore (create_row config payload);
  let read, urls = counting_reader ~answer:(fun _ -> Ok Checks.Not_settled) in
  let outcome = outcome_of (tick_ok config ~read) "s-1" in
  check (list string) "nothing was read" [] (urls ());
  check bool "it names no commit" true (Option.is_none outcome.Checks.target);
  check verdict "it is reported and not woken" (Checks.Not_woken "") outcome.Checks.verdict;
  check string "the row is untouched" "check" (message_of (row config "s-1"))
;;

(* The edit lands between the scan and the write, so the only thing that can
   refuse the write is the instance id the write names. *)
let test_an_edit_made_while_the_commit_is_read_is_kept () =
  with_config
  @@ fun config ->
  ignore (create_row config (keeper_wake ~message:"original" (Some target)));
  let read _ =
    (match
       Schedule_service.update
         config
         ~authority:Schedule_store.Operator_authority
         ~now:120.0
         ~runner_tick_sec
         ~schedule_id:"s-1"
         ~requested_at:100.0
         ~requested_by:(person "requester")
         ~scheduled_by:(person "scheduler")
         ~due_at:300.0
         ~payload:(keeper_wake ~message:"edited" (Some target))
         ~source:Schedule_domain.Operator_request
         ~recurrence:Schedule_domain.One_shot
         ()
     with
     | Ok _ -> ()
     | Error err -> fail (Schedule_service.service_error_to_string err));
    Ok (Checks.Settled settled_runs)
  in
  let outcomes = tick_ok config ~read in
  let after = row config "s-1" in
  check verdict "refused as a stale instance" (Checks.Not_woken "") (outcome_of outcomes "s-1").Checks.verdict;
  check string "the edit stays" "edited" (message_of after);
  check (float 0.0) "its due time stays" 300.0 after.Schedule_domain.due_at
;;

let () =
  run
    "schedule_checks_watch"
    [ ( "runs answer"
      , [ test_case
            "the head of 51286"
            `Quick
            test_the_head_of_51286_is_settled_by_its_four_pull_request_runs
        ; test_case "approval runs alone" `Quick test_approval_runs_alone_are_not_the_checks
        ; test_case
            "a check run not completed"
            `Quick
            test_a_check_run_that_has_not_completed_holds_the_wake
        ; test_case
            "an approval run in progress"
            `Quick
            test_an_approval_run_in_progress_does_not_hold_the_wake
        ; test_case "no run" `Quick test_an_answer_without_runs_is_not_settled
        ; test_case "no conclusion" `Quick test_a_completed_run_may_have_no_conclusion
        ; test_case "workflow_run" `Quick test_a_workflow_run_event_is_a_check
        ; test_case "an untrustworthy answer" `Quick test_an_answer_that_cannot_be_trusted_is_an_error
        ; test_case "a short page is not an error" `Quick test_a_short_page_is_not_an_error
        ; test_case "upper case sha" `Quick test_a_head_sha_in_upper_case_is_the_same_commit
        ] )
    ; ( "target"
      , [ test_case "commit url" `Quick test_a_commit_url_is_read
        ; test_case "not a full commit" `Quick test_a_url_that_is_not_a_full_commit_is_refused
        ; test_case "stored watch" `Quick test_the_stored_watch_round_trips_and_is_strict
        ; test_case "payload" `Quick test_the_watch_is_read_from_a_keeper_wake_payload
        ; test_case "run watch" `Quick test_a_run_watch_is_not_a_checks_watch
        ] )
    ; ( "wake"
      , [ test_case "message" `Quick test_the_wake_message_lists_each_check_run
        ; test_case
            "unreadable message"
            `Quick
            test_the_wake_message_of_an_unreadable_wake_says_to_look_yourself
        ; test_case "settle payload" `Quick test_settling_a_payload_drops_the_watch_and_swaps_the_message
        ; test_case
            "settle a non wake"
            `Quick
            test_settling_a_payload_that_is_not_a_keeper_wake_is_an_error
        ] )
    ; ( "tick"
      , [ test_case "still going" `Quick test_checks_that_are_still_going_change_nothing
        ; test_case "settled" `Quick test_settled_checks_make_the_schedule_due_now
        ; test_case "due time passed" `Quick test_a_due_time_that_has_passed_is_not_moved_later
        ; test_case "never readable" `Quick test_a_read_that_can_never_work_wakes_early
        ; test_case "readable later" `Quick test_a_read_that_can_pass_keeps_the_fallback
        ; test_case "one read per commit" `Quick test_one_read_serves_every_schedule_on_the_commit
        ; test_case "rate limit" `Quick test_a_rate_limit_stops_the_pass
        ; test_case "no watch" `Quick test_rows_without_a_checks_watch_are_left_alone
        ; test_case "unreadable watch" `Quick test_a_stored_watch_that_cannot_be_read_is_reported
        ; test_case "edit during read" `Quick test_an_edit_made_while_the_commit_is_read_is_kept
        ] )
    ]
;;

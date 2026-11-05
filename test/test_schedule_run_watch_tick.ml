open Alcotest
open Masc
module Watch = Schedule_run_watch

(* One pass of [Schedule_run_watch.tick] over a real schedule store, with the
   GitHub read replaced by a function that answers from the test. *)

let repo_exn raw =
  match Watch.repo_of_string raw with
  | Ok repo -> repo
  | Error detail -> fail detail
;;

let target ?attempt run_id =
  { Watch.repo = repo_exn "jeong-sik/masc"; run_id; run_attempt = attempt }
;;

let keeper_wake ?(extra = []) ~message watch =
  let watch_fields =
    match watch with
    | None -> []
    | Some t -> [ Watch.watch_field, Watch.target_to_yojson t ]
  in
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          ([ "keeper_name", `String "k-1"; "message", `String message ] @ extra @ watch_fields) )
    ]
;;

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
  let path = Filename.temp_dir "schedule_run_watch_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf path);
  let config = Workspace.default_config path in
  ignore (Workspace.init config ~agent_name:(Some "run-watch-test"));
  f config
;;

(* The fixture tick is the runner's floor, below every interval used here. *)
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
  match Schedule_domain.payload_to_yojson request.Schedule_domain.payload with
  | `Assoc fields ->
    (match List.assoc_opt "body" fields with
     | Some (`Assoc body) ->
       (match List.assoc_opt "message" body with
        | Some (`String message) -> message
        | Some _ | None -> fail "no message")
     | Some _ | None -> fail "no body")
  | _ -> fail "payload is not an object"
;;

let status_to_string (request : Schedule_domain.schedule_request) =
  Schedule_domain.schedule_status_to_string request.Schedule_domain.status
;;

let tick_ok config ~read =
  match Watch.tick config ~now:150.5 ~runner_tick_sec ~read with
  | Ok outcomes -> outcomes
  | Error detail -> fail detail
;;

let outcome_of outcomes schedule_id =
  match List.find_opt (fun (o : Watch.outcome) -> String.equal o.Watch.schedule_id schedule_id) outcomes with
  | Some outcome -> outcome
  | None -> fail ("no outcome for " ^ schedule_id)
;;

let verdict_to_string = function
  | Watch.Woken (Watch.Run_completed None) -> "woken: completed, no conclusion"
  | Watch.Woken (Watch.Run_completed (Some conclusion)) ->
    "woken: completed " ^ Watch.conclusion_to_string conclusion
  | Watch.Woken (Watch.Run_unreadable failure) ->
    "woken: unreadable, " ^ Watch.read_failure_to_string failure
  | Watch.Waiting_for_run -> "waiting for the run"
  | Watch.Waiting_to_read failure -> "waiting to read: " ^ Watch.read_failure_to_string failure
  | Watch.Not_woken detail -> "not woken: " ^ detail
;;

(* Verdicts are compared as values. The reason of a [Not_woken] is a sentence
   for a person, so only the case is compared. *)
let same_verdict a b =
  match a, b with
  | Watch.Not_woken _, Watch.Not_woken _ -> true
  | _ -> a = b
;;

let verdict =
  testable (fun ppf v -> Format.pp_print_string ppf (verdict_to_string v)) same_verdict
;;

let counting_reader ~answer =
  let urls = ref [] in
  let read target =
    urls := Watch.target_url target :: !urls;
    answer target
  in
  read, fun () -> List.rev !urls
;;

let test_a_run_that_is_still_going_changes_nothing () =
  with_config
  @@ fun config ->
  let before = create_row config (keeper_wake ~message:"check" (Some (target 9))) in
  let read, urls = counting_reader ~answer:(fun _ -> Ok Watch.Not_completed) in
  let outcomes = tick_ok config ~read in
  check int "one outcome" 1 (List.length outcomes);
  check verdict "the verdict" Watch.Waiting_for_run (outcome_of outcomes "s-1").Watch.verdict;
  check (list string) "one read" [ Watch.target_url (target 9) ] (urls ());
  let after = row config "s-1" in
  check string "same instance" before.Schedule_domain.schedule_instance_id after.Schedule_domain.schedule_instance_id;
  check (float 0.0) "same due time" before.Schedule_domain.due_at after.Schedule_domain.due_at;
  check string "same message" "check" (message_of after)
;;

let test_a_completed_run_makes_the_schedule_due_now () =
  with_config
  @@ fun config ->
  let before =
    create_row
      config
      (keeper_wake ~extra:[ "urgency", `String "immediate" ] ~message:"merge if green" (Some (target 9)))
  in
  let read, _ = counting_reader ~answer:(fun _ -> Ok (Watch.Completed (Some Watch.Success))) in
  let outcomes = tick_ok config ~read in
  check
    verdict
    "the verdict"
    (Watch.Woken (Watch.Run_completed (Some Watch.Success)))
    (outcome_of outcomes "s-1").Watch.verdict;
  let after = row config "s-1" in
  check bool "a new instance" false (String.equal before.Schedule_domain.schedule_instance_id after.Schedule_domain.schedule_instance_id);
  check (float 0.0) "due at the current second" 150.0 after.Schedule_domain.due_at;
  check string "still scheduled" "scheduled" (status_to_string after);
  check
    string
    "the message tells the outcome and keeps the Keeper's words"
    (Watch.wake_message
       (target 9)
       (Watch.Run_completed (Some Watch.Success))
       ~original:"merge if green")
    (message_of after);
  (match Watch.watch_of_payload (Schedule_domain.payload_to_yojson after.Schedule_domain.payload) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "the watch is removed");
  check string "requester kept" "requester" after.Schedule_domain.requested_by.Schedule_domain.id;
  check string "scheduler kept" "scheduler" after.Schedule_domain.scheduled_by.Schedule_domain.id;
  (* A second pass finds no watch, so it neither reads nor changes the row. *)
  let read_again, urls = counting_reader ~answer:(fun _ -> Ok (Watch.Completed None)) in
  check int "nothing left to watch" 0 (List.length (tick_ok config ~read:read_again));
  check (list string) "no read" [] (urls ());
  check string "instance unchanged" after.Schedule_domain.schedule_instance_id (row config "s-1").Schedule_domain.schedule_instance_id
;;

let test_a_due_time_that_has_passed_is_not_moved_later () =
  with_config
  @@ fun config ->
  (* Due at 120 and the pass runs at 150.5: no runner pass has taken the row
     yet, so it is still [Scheduled]. Waking it "now" must not push 120 to 150. *)
  let before = create_row config ~due_at:120.0 (keeper_wake ~message:"check" (Some (target 9))) in
  let read, _ = counting_reader ~answer:(fun _ -> Ok (Watch.Completed (Some Watch.Success))) in
  let outcomes = tick_ok config ~read in
  check
    verdict
    "the verdict"
    (Watch.Woken (Watch.Run_completed (Some Watch.Success)))
    (outcome_of outcomes "s-1").Watch.verdict;
  let after = row config "s-1" in
  check (float 0.0) "the due time stays" before.Schedule_domain.due_at after.Schedule_domain.due_at;
  (match Watch.watch_of_payload (Schedule_domain.payload_to_yojson after.Schedule_domain.payload) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "the watch is removed")
;;

let test_the_schedule_runner_takes_the_woken_row () =
  with_config
  @@ fun config ->
  ignore (create_row config (keeper_wake ~message:"check" (Some (target 9))));
  let runner_pass ~now =
    match
      Schedule_runner.tick
        config
        ~pending_settlements:[]
        ~now
        ~retention_days:Schedule_store.terminal_schedule_retention_days
    with
    | Ok result -> result
    | Error failure -> fail (Schedule_runner.tick_failure_to_string failure)
  in
  check int "before the run ends nothing is due" 0 (runner_pass ~now:120.0).Schedule_runner.due_changed;
  let read, _ = counting_reader ~answer:(fun _ -> Ok (Watch.Completed (Some Watch.Failure))) in
  ignore (tick_ok config ~read);
  let result = runner_pass ~now:152.0 in
  check int "the woken row is due" 1 result.Schedule_runner.due_changed;
  check int "and its wake is emitted" 1 (List.length result.Schedule_runner.emitted);
  check string "due" "due" (status_to_string (row config "s-1"))
;;

let test_a_read_that_can_never_work_wakes_early () =
  with_config
  @@ fun config ->
  ignore (create_row config (keeper_wake ~message:"check" (Some (target 9))));
  let read, _ = counting_reader ~answer:(fun _ -> Error Watch.Not_visible) in
  let outcomes = tick_ok config ~read in
  check
    verdict
    "the verdict"
    (Watch.Woken (Watch.Run_unreadable Watch.Not_visible))
    (outcome_of outcomes "s-1").Watch.verdict;
  let after = row config "s-1" in
  check (float 0.0) "due now" 150.0 after.Schedule_domain.due_at;
  check
    string
    "the message says why"
    (Watch.wake_message (target 9) (Watch.Run_unreadable Watch.Not_visible) ~original:"check")
    (message_of after)
;;

let test_a_read_that_can_pass_keeps_the_fallback () =
  with_config
  @@ fun config ->
  let before = create_row config (keeper_wake ~message:"check" (Some (target 9))) in
  let read, _ = counting_reader ~answer:(fun _ -> Error (Watch.Transport_failed "curl exit code 28")) in
  let outcomes = tick_ok config ~read in
  check
    verdict
    "the verdict"
    (Watch.Waiting_to_read (Watch.Transport_failed "curl exit code 28"))
    (outcome_of outcomes "s-1").Watch.verdict;
  let after = row config "s-1" in
  check string "same instance" before.Schedule_domain.schedule_instance_id after.Schedule_domain.schedule_instance_id;
  check (float 0.0) "same due time" before.Schedule_domain.due_at after.Schedule_domain.due_at
;;

let test_one_read_serves_every_schedule_on_the_run () =
  with_config
  @@ fun config ->
  ignore (create_row config ~schedule_id:"a" (keeper_wake ~message:"first" (Some (target 9))));
  ignore (create_row config ~schedule_id:"b" (keeper_wake ~message:"second" (Some (target 9))));
  ignore (create_row config ~schedule_id:"c" (keeper_wake ~message:"third" (Some (target ~attempt:1 9))));
  let read, urls = counting_reader ~answer:(fun _ -> Ok (Watch.Completed (Some Watch.Cancelled))) in
  let outcomes = tick_ok config ~read in
  check int "three outcomes" 3 (List.length outcomes);
  List.iter
    (fun id ->
      check
        verdict
        id
        (Watch.Woken (Watch.Run_completed (Some Watch.Cancelled)))
        (outcome_of outcomes id).Watch.verdict)
    [ "a"; "b"; "c" ];
  check
    (list string)
    "one read for the run and one for its attempt"
    (List.sort String.compare [ Watch.target_url (target 9); Watch.target_url (target ~attempt:1 9) ])
    (List.sort String.compare (urls ()))
;;

let test_a_rate_limit_stops_the_pass () =
  with_config
  @@ fun config ->
  ignore (create_row config ~schedule_id:"a" (keeper_wake ~message:"first" (Some (target 9))));
  ignore (create_row config ~schedule_id:"b" (keeper_wake ~message:"second" (Some (target 10))));
  let read, urls =
    counting_reader ~answer:(fun _ -> Error (Watch.Rate_limited { reset_at = Some 4000.0 }))
  in
  let outcomes = tick_ok config ~read in
  check int "one read only" 1 (List.length (urls ()));
  List.iter
    (fun id ->
      check
        verdict
        id
        (Watch.Waiting_to_read (Watch.Rate_limited { reset_at = Some 4000.0 }))
        (outcome_of outcomes id).Watch.verdict)
    [ "a"; "b" ]
;;

let test_rows_without_a_watch_are_left_alone () =
  with_config
  @@ fun config ->
  ignore (create_row config ~schedule_id:"plain" (keeper_wake ~message:"plain" None));
  ignore
    (create_row
       config
       ~schedule_id:"recurring"
       ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
       (keeper_wake ~message:"every minute" (Some (target 9))));
  ignore (create_row config ~schedule_id:"cancelled" (keeper_wake ~message:"cancelled" (Some (target 9))));
  (match
     Schedule_service.cancel
       config
       ~authority:Schedule_store.Operator_authority
       ~schedule_id:"cancelled"
       ~cancelled_by:(person "operator")
       ~reason:"not needed"
       ~withdraw_queued_wakes:(fun _ _ -> Ok ())
   with
   | Ok _ -> ()
   | Error err -> fail (Schedule_service.service_error_to_string err));
  let read, urls = counting_reader ~answer:(fun _ -> Ok (Watch.Completed (Some Watch.Success))) in
  check int "no outcomes" 0 (List.length (tick_ok config ~read));
  check (list string) "no reads" [] (urls ());
  check string "recurring untouched" "every minute" (message_of (row config "recurring"))
;;

(* A body whose watch does not decode is reported on its own; nothing is read
   for it and the row stays as it was. *)
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
            ; Watch.watch_field, `Assoc [ "repo", `String "jeong-sik/masc" ]
            ] )
      ]
  in
  ignore (create_row config payload);
  let read, urls = counting_reader ~answer:(fun _ -> Ok Watch.Not_completed) in
  let outcome = outcome_of (tick_ok config ~read) "s-1" in
  check (list string) "nothing was read" [] (urls ());
  check bool "it names no run" true (Option.is_none outcome.Watch.target);
  check verdict "it is reported and not woken" (Watch.Not_woken "") outcome.Watch.verdict;
  check string "the row is untouched" "check" (message_of (row config "s-1"))
;;

(* The edit lands between the scan and the write, so the only thing that can
   refuse the write is the instance id the write names. Without
   [~expected_instance_id] the tick would overwrite the edit with the scanned
   row, and this test fails on the message. *)
let test_an_edit_made_while_the_run_is_read_is_kept () =
  with_config
  @@ fun config ->
  let scanned = create_row config (keeper_wake ~message:"original" (Some (target 9))) in
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
         ~payload:(keeper_wake ~message:"edited" (Some (target 9)))
         ~source:Schedule_domain.Operator_request
         ~recurrence:Schedule_domain.One_shot
         ()
     with
     | Ok _ -> ()
     | Error err -> fail (Schedule_service.service_error_to_string err));
    Ok (Watch.Completed (Some Watch.Success))
  in
  let outcomes = tick_ok config ~read in
  let after = row config "s-1" in
  check
    string
    "not woken, refused as a stale instance"
    ("not woken: "
     ^ Schedule_service.service_error_to_string
         (Schedule_service.Store_error
            (Schedule_store.Stale_instance
               { schedule_id = "s-1"
               ; expected = scanned.Schedule_domain.schedule_instance_id
               ; found = after.Schedule_domain.schedule_instance_id
               })))
    (verdict_to_string (outcome_of outcomes "s-1").Watch.verdict);
  check string "the edit stays" "edited" (message_of after);
  check (float 0.0) "its due time stays" 300.0 after.Schedule_domain.due_at
;;

let () =
  run
    "schedule_run_watch_tick"
    [ ( "tick"
      , [ test_case "a run still going" `Quick test_a_run_that_is_still_going_changes_nothing
        ; test_case
            "a completed run makes the schedule due now"
            `Quick
            test_a_completed_run_makes_the_schedule_due_now
        ; test_case
            "a due time that has passed is not moved later"
            `Quick
            test_a_due_time_that_has_passed_is_not_moved_later
        ; test_case
            "the schedule runner takes the woken row"
            `Quick
            test_the_schedule_runner_takes_the_woken_row
        ; test_case "a read that can never work" `Quick test_a_read_that_can_never_work_wakes_early
        ; test_case "a read that can pass" `Quick test_a_read_that_can_pass_keeps_the_fallback
        ; test_case "one read per target" `Quick test_one_read_serves_every_schedule_on_the_run
        ; test_case "a rate limit stops the pass" `Quick test_a_rate_limit_stops_the_pass
        ; test_case "rows without a watch" `Quick test_rows_without_a_watch_are_left_alone
        ; test_case
            "a stored watch that cannot be read"
            `Quick
            test_a_stored_watch_that_cannot_be_read_is_reported
        ; test_case
            "an edit during the read is kept"
            `Quick
            test_an_edit_made_while_the_run_is_read_is_kept
        ] )
    ]
;;

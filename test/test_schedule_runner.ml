open Alcotest
open Schedule_domain
open Schedule_runner
open Schedule_service

let temp_dir () =
  let path = Filename.temp_file "schedule_runner_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f config
;;

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json text =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String text ]
    ]
;;

let create_ok
  ?(schedule_id = "sched-1")
  ?recurrence
  config
  =
  match
    create config ~schedule_id ~requested_at:100.0
      ~requested_by:(human "requester") ~scheduled_by:(human "scheduler")
      ~due_at:200.0 ~payload:(payload_json "wake me") ~source:Operator_request
      ?recurrence ()
  with
  | Ok request -> request
  | Error err -> fail (service_error_to_string err)
;;

let tick_ok ?consumer config ~now =
  match tick ?consumer config ~now with
  | Ok result -> result
  | Error err -> fail (runner_error_to_string err)
;;

let check_kind label expected actual =
  check string label (signal_kind_to_string expected) (signal_kind_to_string actual)
;;

let check_dispatch_status label expected actual =
  check string label (dispatch_status_to_string expected) (dispatch_status_to_string actual)
;;

let read_recent_signals_exn config n =
  match read_recent_signals config n with
  | Ok signals -> signals
  | Error error -> fail error
;;

let json_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let json_string key json =
  match json_field key json with
  | Some (`String value) -> value
  | Some other -> failf "field %s expected string, got %s" key (Yojson.Safe.to_string other)
  | None -> failf "missing string field %s" key
;;

let json_int key json =
  match json_field key json with
  | Some (`Int value) -> value
  | Some other -> failf "field %s expected int, got %s" key (Yojson.Safe.to_string other)
  | None -> failf "missing int field %s" key
;;

let json_float key json =
  match json_field key json with
  | Some (`Float value) -> value
  | Some (`Int value) -> float_of_int value
  | Some other -> failf "field %s expected float, got %s" key (Yojson.Safe.to_string other)
  | None -> failf "missing float field %s" key
;;

let accepting_consumer ?(accept = Ok ()) ?dispatch_result calls =
  let dispatch_result =
    Option.value
      ~default:(Ok (`Assoc [ "ok", `Bool true ]))
      dispatch_result
  in
  { accepts = (fun _request -> accept)
  ; dispatch =
      (fun _config ~now:_ _signal request ->
        calls := request.schedule_id :: !calls;
        dispatch_result)
  }
;;

let test_tick_emits_due_candidate_once () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"read-1" config in
  let before_due = tick_ok config ~now:199.0 in
  check int "no early signal" 0 (List.length before_due.emitted);
  let due = tick_ok config ~now:201.0 in
  check int "one signal" 1 (List.length due.emitted);
  check int "one status transition" 1 due.due_changed;
  check int "one-shot not rescheduled" 0 due.rescheduled;
  let signal = List.hd due.emitted in
  check_kind "kind" Due_candidate signal.kind;
  check string "schedule id" request.schedule_id signal.schedule_id;
  check string "payload digest"
    (Schedule_domain.payload_digest request.payload)
    signal.payload_digest;
  let repeated = tick_ok config ~now:202.0 in
  check int "dedupe repeated tick" 0 (List.length repeated.emitted);
  check int "durable signal count" 1
    (List.length (read_recent_signals_exn config 10))
;;

let test_tick_dispatches_due_candidate_to_success () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request = create_ok ~schedule_id:"dispatch-1" config in
  let result =
    tick_ok config ~now:201.0 ~consumer:(accepting_consumer calls)
  in
  check int "one dispatch" 1 (List.length result.dispatches);
  check_dispatch_status "dispatch status" Dispatch_succeeded
    (List.hd result.dispatches).status;
  check Alcotest.(list string) "consumer called" [ request.schedule_id ] !calls;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing after dispatch"
   | Some stored ->
     check string "stored succeeded" "succeeded"
       (schedule_status_to_string stored.status));
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing execution record"
   | Some execution ->
     check string "execution status" "succeeded"
       (Schedule_domain.execution_status_to_string execution.status);
     (match execution.detail with
      | Some (`Assoc fields) ->
        (match List.assoc_opt "ok" fields with
         | Some (`Bool true) -> ()
         | _ -> fail "execution detail missing ok=true")
      | _ -> fail "execution detail missing"))
;;

let test_tick_marks_unsupported_candidate_failed () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request = create_ok ~schedule_id:"unsupported-1" config in
  let result =
    tick_ok config ~now:201.0
      ~consumer:(accepting_consumer ~accept:(Error "unsupported") calls)
  in
  check int "one dispatch decision" 1 (List.length result.dispatches);
  check_dispatch_status "unsupported" Dispatch_unsupported
    (List.hd result.dispatches).status;
  check Alcotest.(list string) "consumer not called" [] !calls;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing after unsupported"
   | Some stored ->
     check string "stored failed" "failed" (schedule_status_to_string stored.status));
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing unsupported execution"
   | Some execution ->
     check string "unsupported execution status" "failed"
       (Schedule_domain.execution_status_to_string execution.status);
     check (option string) "unsupported execution error" (Some "unsupported")
       execution.error);
  let repeated =
    tick_ok config ~now:202.0
      ~consumer:(accepting_consumer ~accept:(Error "unsupported") calls)
  in
  check int "unsupported does not dispatch repeatedly" 0
    (List.length repeated.dispatches)
;;

let test_tick_reschedules_recurring_candidate_after_signal () =
  with_workspace
  @@ fun config ->
  let request =
    create_ok ~schedule_id:"loop-1"
      ~recurrence:(Interval { interval_sec = 60 })
      config
  in
  let due = tick_ok config ~now:201.0 in
  check int "first signal" 1 (List.length due.emitted);
  check int "first reschedule" 1 due.rescheduled;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing after first tick"
   | Some stored ->
     check string "first status" "scheduled"
       (schedule_status_to_string stored.status);
     check (float 0.001) "first next due" 260.0 stored.due_at);
  let before_next_due = tick_ok config ~now:259.0 in
  check int "no early repeat" 0 (List.length before_next_due.emitted);
  check int "no early reschedule" 0 before_next_due.rescheduled;
  let second_due = tick_ok config ~now:260.0 in
  check int "second signal" 1 (List.length second_due.emitted);
  check int "second reschedule" 1 second_due.rescheduled;
  check int "two durable signals" 2
    (List.length (read_recent_signals_exn config 10))
;;

let test_tick_dispatches_recurring_candidate_to_next_due () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request =
    create_ok ~schedule_id:"loop-dispatch-1"
      ~recurrence:(Interval { interval_sec = 60 })
      config
  in
  let result =
    tick_ok config ~now:201.0 ~consumer:(accepting_consumer calls)
  in
  check int "one dispatch" 1 (List.length result.dispatches);
  check int "consumer mode does not separately reschedule" 0 result.rescheduled;
  check Alcotest.(list string) "consumer called" [ request.schedule_id ] !calls;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing after recurring dispatch"
   | Some stored ->
     check string "stored scheduled" "scheduled"
       (schedule_status_to_string stored.status);
     check (float 0.001) "next due" 260.0 stored.due_at);
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing recurring execution"
   | Some execution ->
     check string "recurring execution status" "succeeded"
       (Schedule_domain.execution_status_to_string execution.status);
     check (float 0.001) "recurring execution due" 200.0 execution.due_at)
;;

let test_tick_dispatches_every_recurring_occurrence () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request =
    create_ok ~schedule_id:"loop-dispatch-every-occurrence"
      ~recurrence:(Interval { interval_sec = 60 })
      config
  in
  let first =
    tick_ok config ~now:201.0 ~consumer:(accepting_consumer calls)
  in
  check int "first dispatch" 1 (List.length first.dispatches);
  check Alcotest.(list string) "first consumer call" [ request.schedule_id ] !calls;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing after first dispatch"
   | Some stored ->
     check string "stored scheduled after first dispatch" "scheduled"
       (schedule_status_to_string stored.status);
     check (float 0.001) "second due_at" 260.0 stored.due_at);
  let second =
    tick_ok config ~now:260.0 ~consumer:(accepting_consumer calls)
  in
  check int "second dispatch" 1 (List.length second.dispatches);
  check Alcotest.(list string) "second consumer call"
    [ request.schedule_id; request.schedule_id ]
    !calls
;;

let test_tick_marks_terminal_dispatch_rejection_failed () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request = create_ok ~schedule_id:"dispatch-fail-1" config in
  let result =
    tick_ok config ~now:201.0
      ~consumer:
        (accepting_consumer
           ~dispatch_result:(Error (Terminal_dispatch_rejection "boom"))
           calls)
  in
  check int "one dispatch" 1 (List.length result.dispatches);
  check_dispatch_status "failed" Dispatch_failed (List.hd result.dispatches).status;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing after failed dispatch"
   | Some stored ->
     check string "stored failed" "failed" (schedule_status_to_string stored.status));
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing failed execution"
   | Some execution ->
     check string "failed execution status" "failed"
       (Schedule_domain.execution_status_to_string execution.status);
     check (option string) "failed execution error" (Some "boom")
       execution.error)
;;

let test_tick_retries_same_occurrence_without_blocking_other_schedule () =
  with_workspace
  @@ fun config ->
  let retry_request = create_ok ~schedule_id:"retry-1" config in
  let healthy_request = create_ok ~schedule_id:"healthy-1" config in
  let retry_first_attempt = ref true in
  let retry_signal_ids = ref [] in
  let healthy_calls = ref 0 in
  let consumer : Schedule_runner.consumer =
    { accepts = (fun _request -> Ok ())
    ; dispatch =
        (fun _config ~now:_ signal request ->
           if String.equal request.schedule_id retry_request.schedule_id then (
             retry_signal_ids := signal.signal_id :: !retry_signal_ids;
             if !retry_first_attempt then (
               retry_first_attempt := false;
               Error (Retryable_dispatch_failure "queue storage unavailable"))
             else Ok (`Assoc [ "retried", `Bool true ]))
           else (
             incr healthy_calls;
             Ok (`Assoc [ "healthy", `Bool true ])))
    }
  in
  let first = tick_ok config ~now:201.0 ~consumer in
  check int "both schedules dispatched" 2 (List.length first.dispatches);
  check int "healthy schedule dispatched once" 1 !healthy_calls;
  let occurrence_id =
    match !retry_signal_ids with
    | [ signal_id ] -> signal_id
    | _ -> fail "retry schedule did not dispatch exactly once"
  in
  (match Schedule_store.get_schedule config ~schedule_id:retry_request.schedule_id with
   | Some stored -> check string "retry schedule remains due" "due"
                      (schedule_status_to_string stored.status)
   | None -> fail "retry schedule missing");
  (match Schedule_store.get_schedule config ~schedule_id:healthy_request.schedule_id with
   | Some stored -> check string "other schedule succeeded" "succeeded"
                      (schedule_status_to_string stored.status)
   | None -> fail "healthy schedule missing");
  let second = tick_ok config ~now:202.0 ~consumer in
  check int "durable signal is not duplicated" 0 (List.length second.emitted);
  check int "only retry schedule dispatched" 1 (List.length second.dispatches);
  check Alcotest.(list string) "same occurrence identity reused"
    [ occurrence_id; occurrence_id ]
    (List.rev !retry_signal_ids);
  check int "healthy schedule not replayed" 1 !healthy_calls;
  (match Schedule_store.get_schedule config ~schedule_id:retry_request.schedule_id with
   | Some stored -> check string "retry eventually succeeded" "succeeded"
                      (schedule_status_to_string stored.status)
   | None -> fail "retry schedule missing after success");
  check Alcotest.(list string) "failed attempt remains beside successful retry"
    [ "succeeded"; "failed" ]
    (Schedule_store.executions_for_schedule
       (Schedule_store.read_state config)
       ~schedule_id:retry_request.schedule_id
     |> List.map (fun (execution : execution_record) ->
       execution_status_to_string execution.status))
;;

let test_recent_signal_decode_error_is_explicit () =
  with_workspace
  @@ fun config ->
  Dated_jsonl.append
    (Dated_jsonl.create ~base_dir:(signals_dir config) ())
    (`Assoc
      [ "event_type", `String "schedule.due_candidate"
      ; "signal_id", `String "malformed"
      ]);
  match read_recent_signals config 10 with
  | Ok _ -> fail "malformed durable signal was silently ignored"
  | Error error ->
    check bool "decode error identifies row" true
      (String_util.contains_substring error "schedule signal row 0")
;;

let test_runner_status_snapshot_tracks_liveness () =
  Schedule_runner_status.reset_for_test ();
  let render ?(now = 0.0) ?(stale_after_sec = 10.0) () =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now ~stale_after_sec
  in
  check string "initial status" "not_started" (json_string "status" (render ()));
  Schedule_runner_status.record_tick_started ~now:1.0;
  check string "running status" "running"
    (json_string "status" (render ~now:1.5 ()));
  let ok_result =
    { due_changed = 1
    ; emitted = []
    ; rescheduled = 2
    ; dispatches =
        [ { schedule_id = "status-1"
          ; status = Dispatch_succeeded
          ; detail = Some (`Assoc [ "ok", `Bool true ])
          ; error = None
          }
        ]
    }
  in
  Schedule_runner_status.record_tick_ok ~started_at:1.0 ~finished_at:1.25 ok_result;
  let ok = render ~now:2.25 () in
  check string "ok status" "ok" (json_string "status" ok);
  check int "tick count" 1 (json_int "tick_count" ok);
  check int "success count" 1 (json_int "success_count" ok);
  check (float 0.000001) "last duration" 0.25
    (json_float "last_duration_sec" ok);
  check (float 0.000001) "last tick age" 1.0
    (json_float "last_tick_age_sec" ok);
  let counts =
    match json_field "last_counts" ok with
    | Some counts -> counts
    | None -> fail "missing last_counts"
  in
  check int "last due count" 1 (json_int "due_changed" counts);
  check int "last reschedule count" 2 (json_int "rescheduled" counts);
  check int "last success dispatch count" 1 (json_int "dispatch_succeeded" counts);
  check int "last failed dispatch count" 0 (json_int "dispatch_failed" counts);
  check int "last unsupported dispatch count" 0 (json_int "dispatch_unsupported" counts);
  check int "last start-rejected dispatch count" 0
    (json_int "dispatch_start_rejected" counts);
  let dispatch_failure_result =
    { due_changed = 3
    ; emitted = []
    ; rescheduled = 0
    ; dispatches =
        [ { schedule_id = "status-dispatch-failed"
          ; status = Dispatch_failed
          ; detail = None
          ; error = Some "dispatch failed"
          }
        ; { schedule_id = "status-dispatch-unsupported"
          ; status = Dispatch_unsupported
          ; detail = None
          ; error = Some "unsupported"
          }
        ; { schedule_id = "status-dispatch-start-rejected"
          ; status = Dispatch_start_rejected
          ; detail = None
          ; error = Some "start rejected"
          }
        ]
    }
  in
  Schedule_runner_status.record_tick_ok
    ~started_at:2.0
    ~finished_at:2.125
    dispatch_failure_result;
  let dispatch_degraded = render ~now:2.25 () in
  check string "dispatch failure degrades status" "degraded"
    (json_string "status" dispatch_degraded);
  let dispatch_counts =
    match json_field "last_counts" dispatch_degraded with
    | Some counts -> counts
    | None -> fail "missing dispatch failure last_counts"
  in
  check int "failed dispatch count" 1 (json_int "dispatch_failed" dispatch_counts);
  check int "unsupported dispatch count" 1
    (json_int "dispatch_unsupported" dispatch_counts);
  check int "start-rejected dispatch count" 1
    (json_int "dispatch_start_rejected" dispatch_counts);
  let wake_enqueue_counts : Schedule_runner_status.wake_enqueue_counts =
    { wake_enqueued = 2
    ; wake_skipped_no_keeper = 3
    ; wake_skipped_missing_schedule = 1
    ; wake_skipped_non_keeper_actor = 1
    ; wake_skipped_unregistered_keeper = 1
    ; wake_failed = 1
    }
  in
  Schedule_runner_status.record_tick_ok
    ~wake_enqueue_counts
    ~started_at:2.5
    ~finished_at:2.75
    ok_result;
  let wake_degraded = render ~now:3.0 () in
  check string "wake failure degrades status" "degraded"
    (json_string "status" wake_degraded);
  let wake_counts =
    match json_field "last_counts" wake_degraded with
    | Some counts -> counts
    | None -> fail "missing wake failure last_counts"
  in
  check int "wake enqueued count" 2 (json_int "wake_enqueued" wake_counts);
  check int "wake skipped count" 3 (json_int "wake_skipped_no_keeper" wake_counts);
  check int "wake missing schedule count" 1
    (json_int "wake_skipped_missing_schedule" wake_counts);
  check int "wake non-keeper actor count" 1
    (json_int "wake_skipped_non_keeper_actor" wake_counts);
  check int "wake unregistered keeper count" 1
    (json_int "wake_skipped_unregistered_keeper" wake_counts);
  check int "wake failed count" 1 (json_int "wake_failed" wake_counts);
  Schedule_runner_status.record_tick_error ~started_at:3.0 ~finished_at:3.5 "boom";
  let degraded = render ~now:4.0 () in
  check string "degraded status" "degraded" (json_string "status" degraded);
  check int "failure count" 1 (json_int "failure_count" degraded);
  Schedule_runner_status.record_tick_crash ~started_at:5.0 ~finished_at:5.5 "crash";
  let stale = render ~now:20.0 () in
  check string "stale status" "stale" (json_string "status" stale);
  check int "crash count" 1 (json_int "crash_count" stale)
;;

let () =
  run "Schedule_runner"
    [ ( "tick",
        [ test_case "emits due candidate once" `Quick
            test_tick_emits_due_candidate_once
        ; test_case "dispatches due candidate to success" `Quick
            test_tick_dispatches_due_candidate_to_success
        ; test_case "marks unsupported candidate failed" `Quick
            test_tick_marks_unsupported_candidate_failed
        ; test_case "reschedules recurring candidate after signal" `Quick
            test_tick_reschedules_recurring_candidate_after_signal
        ; test_case "dispatches recurring candidate to next due" `Quick
            test_tick_dispatches_recurring_candidate_to_next_due
        ; test_case "dispatches every recurring occurrence" `Quick
            test_tick_dispatches_every_recurring_occurrence
        ; test_case "marks terminal dispatch rejection failed" `Quick
            test_tick_marks_terminal_dispatch_rejection_failed
        ; test_case "retries same occurrence without blocking other schedule" `Quick
            test_tick_retries_same_occurrence_without_blocking_other_schedule
        ; test_case "recent signal decode error is explicit" `Quick
            test_recent_signal_decode_error_is_explicit
        ] )
    ; ( "status",
        [ test_case "tracks liveness snapshot" `Quick
            test_runner_status_snapshot_tracks_liveness
        ] )
    ]
;;

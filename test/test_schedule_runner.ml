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

let test_occurrence_id schedule_id =
  Schedule_occurrence_id.make
    ~schedule_id
    ~due_at:200.0
    ~payload_digest:"test-payload"
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

let replace_json_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | json -> json
;;

let accepting_consumer ?(accept = Ok ()) ?dispatch_result ?settlement calls =
  let dispatch_result =
    Option.value
      ~default:(Ok (Work_completed (`Assoc [ "ok", `Bool true ])))
      dispatch_result
  in
  let settlement =
    Option.value
      ~default:(fun _config _execution -> Ok Consumer_holds_occurrence)
      settlement
  in
  { accepts = (fun _request -> accept)
  ; dispatch =
      (fun _config ~now:_ _signal request ->
        calls := request.schedule_id :: !calls;
        dispatch_result)
  ; settlements =
      (fun config executions ->
         List.map (settlement config) executions)
  }
;;

let accepted_dispatch = Ok (Work_accepted (`Assoc [ "queued", `Bool true ]))

let reclaim_ok ~consumer config ~now =
  match reclaim_lost_occurrences ~consumer config ~now with
  | Ok outcome -> outcome
  | Error err -> fail (runner_error_to_string err)
;;

let latest_execution config ~schedule_id =
  let state = Schedule_store.read_state config in
  match Schedule_store.last_execution_for_schedule state ~schedule_id with
  | Some execution -> execution
  | None -> failf "no execution recorded for %s" schedule_id
;;

(* Drives a schedule to the state this whole feature exists for: the consumer
   durably accepted the work, so the execution is [Execution_dispatched] and
   nothing in the scheduler will ever finish it on its own. *)
let accepted_recurring_occurrence config ~schedule_id =
  let calls = ref [] in
  let request =
    create_ok ~schedule_id ~recurrence:(Interval { interval_sec = 3600 }) config
  in
  let consumer = accepting_consumer ~dispatch_result:accepted_dispatch calls in
  let _ = tick_ok config ~now:201.0 ~consumer in
  let accepted = latest_execution config ~schedule_id in
  check bool "precondition: work accepted but unsettled" true
    (accepted.status = Execution_dispatched);
  request
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
  (match result.emitted, result.dispatches with
   | [ signal ], [ dispatch ] ->
     check bool "dispatch keeps exact occurrence identity" true
       (Schedule_occurrence_id.equal signal.occurrence_id dispatch.occurrence_id)
   | _ -> fail "expected one emitted and dispatched occurrence");
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

let test_tick_records_async_acceptance_without_claiming_work_success () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request = create_ok ~schedule_id:"dispatch-accepted-1" config in
  let detail = `Assoc [ "kind", `String "consumer.work_accepted" ] in
  let result =
    tick_ok config ~now:201.0
      ~consumer:
        (accepting_consumer
           ~dispatch_result:(Ok (Work_accepted detail))
           calls)
  in
  check_dispatch_status "dispatch itself succeeded" Dispatch_succeeded
    (List.hd result.dispatches).status;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "accepted schedule missing"
   | Some stored ->
     check string "one-shot remains running" "running"
       (schedule_status_to_string stored.status));
  (match
     Schedule_store.last_execution_for_schedule
       (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "accepted execution missing"
   | Some execution ->
     check string "accepted work is not succeeded" "dispatched"
       (Schedule_domain.execution_status_to_string execution.status);
     check (option (float 0.001)) "accepted work has no finish time" None
       execution.finished_at);
  (match Schedule_store.recover_running_on_startup config ~now:202.0 with
   | Ok (_, recovered) ->
     check int "restart does not duplicate durably accepted work" 0 recovered
   | Error err -> fail (Schedule_store.store_error_to_string err))
;;

let test_tick_records_terminal_work_failure_for_exact_recurrence () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request =
    create_ok
      ~schedule_id:"dispatch-work-failed"
      ~recurrence:(Interval { interval_sec = 60 })
      config
  in
  let detail = `Assoc [ "kind", `String "consumer.work_failed" ] in
  let result =
    tick_ok
      config
      ~now:201.0
      ~consumer:
        (accepting_consumer
           ~dispatch_result:
             (Ok (Work_failed { error = "operator cancelled occurrence"; detail }))
           calls)
  in
  let dispatch = List.hd result.dispatches in
  check_dispatch_status "terminal work failure is visible" Dispatch_failed
    dispatch.status;
  check (option string) "terminal work failure reason"
    (Some "operator cancelled occurrence")
    dispatch.error;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "failed recurring schedule missing"
   | Some stored ->
     check string "recurring intent advances" "scheduled"
       (schedule_status_to_string stored.status);
     check (float 0.001) "next occurrence remains scheduled" 260.0 stored.due_at);
  match
    Schedule_store.execution_for_occurrence
      (Schedule_store.read_state config)
      ~schedule_id:request.schedule_id
      ~due_at:request.due_at
      ~payload_digest:(Schedule_domain.payload_digest request.payload)
  with
  | None -> fail "failed occurrence execution missing"
  | Some execution ->
    check string "exact occurrence failed" "failed"
      (Schedule_domain.execution_status_to_string execution.status)
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
             retry_signal_ids :=
               Schedule_occurrence_id.to_string signal.occurrence_id
               :: !retry_signal_ids;
             if !retry_first_attempt then (
               retry_first_attempt := false;
               Error (Retryable_dispatch_failure "queue storage unavailable"))
             else Ok (Work_completed (`Assoc [ "retried", `Bool true ])))
           else (
             incr healthy_calls;
             Ok (Work_completed (`Assoc [ "healthy", `Bool true ]))))
    ; settlements =
        (fun _config executions ->
           List.map (fun _ -> Ok Consumer_holds_occurrence) executions)
    }
  in
  let first = tick_ok config ~now:201.0 ~consumer in
  check int "both schedules dispatched" 2 (List.length first.dispatches);
  check int "healthy schedule dispatched once" 1 !healthy_calls;
  let occurrence_id =
    match !retry_signal_ids with
    | [ occurrence_id ] -> occurrence_id
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
      ; "occurrence_id", `String "malformed"
      ]);
  match read_recent_signals config 10 with
  | Ok _ -> fail "malformed durable signal was silently ignored"
  | Error error ->
    check bool "decode error identifies row" true
      (String_util.contains_substring error "schedule signal row 0")
;;

let test_occurrence_decode_rejects_tampered_facts () =
  with_workspace
  @@ fun config ->
  let _request = create_ok ~schedule_id:"codec-1" config in
  let signal =
    tick_ok config ~now:201.0 |> fun result -> List.hd result.emitted
  in
  let encoded = wake_signal_to_yojson signal in
  (match wake_signal_of_yojson encoded with
   | Ok decoded ->
     check bool "round trip occurrence identity" true
       (Schedule_occurrence_id.equal signal.occurrence_id decoded.occurrence_id)
   | Error error -> fail error);
  let tampered_id =
    replace_json_field "occurrence_id" (`String "tampered") encoded
  in
  (match wake_signal_of_yojson tampered_id with
   | Error _ -> ()
   | Ok _ -> fail "tampered occurrence_id was accepted");
  let tampered_payload =
    replace_json_field "payload" (payload_json "different payload") encoded
  in
  match wake_signal_of_yojson tampered_payload with
  | Error _ -> ()
  | Ok _ -> fail "payload facts diverging from payload_digest were accepted"
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
        [ { occurrence_id = test_occurrence_id "status-1"
          ; schedule_id = "status-1"
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
        [ { occurrence_id = test_occurrence_id "status-dispatch-failed"
          ; schedule_id = "status-dispatch-failed"
          ; status = Dispatch_failed
          ; detail = None
          ; error = Some "dispatch failed"
          }
        ; { occurrence_id = test_occurrence_id "status-dispatch-unsupported"
          ; schedule_id = "status-dispatch-unsupported"
          ; status = Dispatch_unsupported
          ; detail = None
          ; error = Some "unsupported"
          }
        ; { occurrence_id = test_occurrence_id "status-dispatch-start-rejected"
          ; schedule_id = "status-dispatch-start-rejected"
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


let test_reclaim_settles_lost_occurrence () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-lost" in
  let calls = ref [] in
  let lost_consumer =
    accepting_consumer
      ~settlement:(fun _config _execution ->
        Ok (Consumer_lost_occurrence "queue entry vanished"))
      calls
  in
  let outcome = reclaim_ok ~consumer:lost_consumer config ~now:400.0 in
  check int "one occurrence examined" 1 outcome.examined;
  check int "one occurrence reclaimed" 1 outcome.reclaimed;
  check int "no reclaim failure" 0 (List.length outcome.failures);
  let settled = latest_execution config ~schedule_id:request.schedule_id in
  check bool "occurrence is terminal" true (settled.status = Execution_failed);
  check (option string) "consumer reason is the recorded failure"
    (Some "queue entry vanished") settled.error;
  match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
  | None -> fail "schedule row disappeared"
  | Some stored ->
    check bool "recurring intent survives the reclaim" false (is_terminal stored.status)
;;

let test_reclaim_leaves_held_occurrence_alone () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-held" in
  let calls = ref [] in
  let holding_consumer = accepting_consumer calls in
  let outcome = reclaim_ok ~consumer:holding_consumer config ~now:400.0 in
  check int "occurrence examined" 1 outcome.examined;
  check int "nothing reclaimed" 0 outcome.reclaimed;
  check int "occurrence counted as held" 1 outcome.held;
  let untouched = latest_execution config ~schedule_id:request.schedule_id in
  check bool "occurrence stays dispatched" true
    (untouched.status = Execution_dispatched)
;;

let test_reclaim_projects_consumer_completion () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-completed" in
  let calls = ref [] in
  let completed_consumer =
    accepting_consumer
      ~settlement:(fun _config _execution -> Ok Consumer_completed_occurrence)
      calls
  in
  let outcome = reclaim_ok ~consumer:completed_consumer config ~now:400.0 in
  check int "completed occurrence examined" 1 outcome.examined;
  check int "completed occurrence settled" 1 outcome.settled_elsewhere;
  check int "completion projection has no failure" 0 (List.length outcome.failures);
  let settled = latest_execution config ~schedule_id:request.schedule_id in
  check bool "consumer completion leaves dispatched" false
    (settled.status = Execution_dispatched);
  check bool "consumer completion succeeds execution" true
    (settled.status = Execution_succeeded)
;;

let test_reclaim_then_prune_removes_settled_terminal_request () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-prune" in
  (match cancel config ~schedule_id:request.schedule_id with
   | Ok _ -> ()
   | Error error -> fail (service_error_to_string error));
  let calls = ref [] in
  let completed_consumer =
    accepting_consumer
      ~settlement:(fun _config _execution -> Ok Consumer_completed_occurrence)
      calls
  in
  let outcome = reclaim_ok ~consumer:completed_consumer config ~now:400.0 in
  check int "terminal request occurrence settled" 1 outcome.settled_elsewhere;
  let state, pruned =
    match Schedule_store.prune_completed config with
    | Ok result -> result
    | Error error -> fail (Schedule_store.store_error_to_string error)
  in
  check int "settled terminal request pruned" 1 pruned;
  check int "request removed after exact settlement" 0 (List.length state.schedules);
  check int "execution removed with request" 0 (List.length state.executions)
;;

let test_reclaim_projects_consumer_cancellation () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-cancelled" in
  let calls = ref [] in
  let cancelled_consumer =
    accepting_consumer
      ~settlement:(fun _config _execution ->
        Ok (Consumer_cancelled_occurrence "operator cancelled durable work"))
      calls
  in
  let outcome = reclaim_ok ~consumer:cancelled_consumer config ~now:400.0 in
  check int "cancelled occurrence examined" 1 outcome.examined;
  check int "cancelled occurrence settled" 1 outcome.settled_elsewhere;
  check int "cancellation projection has no failure" 0 (List.length outcome.failures);
  let settled = latest_execution config ~schedule_id:request.schedule_id in
  check bool "consumer cancellation leaves dispatched" false
    (settled.status = Execution_dispatched);
  check bool "consumer cancellation fails execution" true
    (settled.status = Execution_failed);
  check (option string) "durable cancellation reason is preserved"
    (Some "operator cancelled durable work") settled.error
;;

let test_reclaim_projects_consumer_failure () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-failed" in
  let calls = ref [] in
  let failed_consumer =
    accepting_consumer
      ~settlement:(fun _config _execution ->
        Ok (Consumer_failed_occurrence "keeper turn failed before schedule settlement"))
      calls
  in
  let outcome = reclaim_ok ~consumer:failed_consumer config ~now:400.0 in
  check int "failed occurrence examined" 1 outcome.examined;
  check int "failed occurrence settled" 1 outcome.settled_elsewhere;
  check int "failure projection has no reclaim error" 0 (List.length outcome.failures);
  let settled = latest_execution config ~schedule_id:request.schedule_id in
  check bool "consumer failure fails execution" true
    (settled.status = Execution_failed);
  check (option string) "consumer failure reason is preserved"
    (Some "keeper turn failed before schedule settlement")
    settled.error
;;

let test_reclaim_reports_empty_batch_cardinality_mismatch () =
  with_workspace
  @@ fun config ->
  let consumer =
    { (accepting_consumer (ref [])) with
      settlements =
        (fun _config _executions -> [ Ok Consumer_holds_occurrence ])
    }
  in
  let outcome = reclaim_ok ~consumer config ~now:400.0 in
  check int "empty batch examines no occurrences" 0 outcome.examined;
  match outcome.failures with
  | [ Settlement_batch_cardinality_mismatch { expected; actual } ] ->
    check int "batch failure reports expected cardinality" 0 expected;
    check int "batch failure reports actual cardinality" 1 actual
  | _ -> fail "empty batch cardinality mismatch was hidden"
;;

let test_reclaim_reports_empty_batch_consumer_exception () =
  with_workspace
  @@ fun config ->
  let consumer =
    { (accepting_consumer (ref [])) with
      settlements =
        (fun _config _executions -> failwith "empty settlement batch exploded")
    }
  in
  let outcome = reclaim_ok ~consumer config ~now:400.0 in
  check int "empty batch examines no occurrences" 0 outcome.examined;
  match outcome.failures with
  | [ Settlement_batch_consumer_failure error ] ->
    check bool "batch exception remains visible" true
      (String_util.contains_substring error "empty settlement batch exploded")
  | _ -> fail "empty batch consumer exception was hidden"
;;

let test_reclaim_counts_nonempty_batch_cardinality_mismatch () =
  with_workspace
  @@ fun config ->
  ignore
    (accepted_recurring_occurrence config ~schedule_id:"reclaim-cardinality"
      : Schedule_domain.schedule_request);
  let consumer =
    { (accepting_consumer (ref [])) with
      settlements = (fun _config _executions -> [])
    }
  in
  let outcome = reclaim_ok ~consumer config ~now:400.0 in
  check int "mismatched occurrence is examined" 1 outcome.examined;
  match outcome.failures with
  | [ Occurrence_reclaim_failure { occurrence_id; error } ] ->
    check bool "mismatch keeps an occurrence identity" true
      (String.trim occurrence_id <> "");
    check bool "mismatch reports exact cardinality" true
      (String_util.contains_substring error "expected=1 actual=0")
  | _ -> fail "nonempty batch cardinality mismatch was not occurrence-scoped"
;;

let test_reclaim_leaves_occurrence_alone_when_consumer_errors () =
  with_workspace
  @@ fun config ->
  let request = accepted_recurring_occurrence config ~schedule_id:"reclaim-error" in
  let calls = ref [] in
  let failing_consumer =
    accepting_consumer
      ~settlement:(fun _config _execution ->
        Error "keeper event queue snapshot read failed: disk gone")
      calls
  in
  let outcome = reclaim_ok ~consumer:failing_consumer config ~now:400.0 in
  check int "occurrence examined" 1 outcome.examined;
  check int "nothing reclaimed on an unreadable consumer" 0 outcome.reclaimed;
  check int "the error is reported" 1 (List.length outcome.failures);
  let untouched = latest_execution config ~schedule_id:request.schedule_id in
  check bool "occurrence stays dispatched" true
    (untouched.status = Execution_dispatched)
;;


let () =
  run "Schedule_runner"
    [ ( "tick",
        [ test_case "emits due candidate once" `Quick
            test_tick_emits_due_candidate_once
        ; test_case "dispatches due candidate to success" `Quick
            test_tick_dispatches_due_candidate_to_success
        ; test_case "records async acceptance without work success" `Quick
            test_tick_records_async_acceptance_without_claiming_work_success
        ; test_case "records exact recurring terminal work failure" `Quick
            test_tick_records_terminal_work_failure_for_exact_recurrence
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
        ; test_case "occurrence decode rejects tampered facts" `Quick
            test_occurrence_decode_rejects_tampered_facts
        ] )
    ; ( "reclaim",
        [ test_case "settles an occurrence the consumer lost" `Quick
            test_reclaim_settles_lost_occurrence
        ; test_case "leaves an occurrence the consumer still holds" `Quick
            test_reclaim_leaves_held_occurrence_alone
        ; test_case "projects consumer completion to schedule execution" `Quick
            test_reclaim_projects_consumer_completion
        ; test_case "reclaim then prune removes settled terminal request" `Quick
            test_reclaim_then_prune_removes_settled_terminal_request
        ; test_case "projects consumer cancellation to schedule execution" `Quick
            test_reclaim_projects_consumer_cancellation
        ; test_case "projects consumer failure to schedule execution" `Quick
            test_reclaim_projects_consumer_failure
        ; test_case "reports empty settlement batch mismatch" `Quick
            test_reclaim_reports_empty_batch_cardinality_mismatch
        ; test_case "reports empty settlement batch consumer exception" `Quick
            test_reclaim_reports_empty_batch_consumer_exception
        ; test_case "counts nonempty settlement batch mismatch" `Quick
            test_reclaim_counts_nonempty_batch_cardinality_mismatch
        ; test_case "leaves an occurrence when the consumer cannot answer" `Quick
            test_reclaim_leaves_occurrence_alone_when_consumer_errors
        ] )
    ; ( "status",
        [ test_case "tracks liveness snapshot" `Quick
            test_runner_status_snapshot_tracks_liveness
        ] )
    ]
;;

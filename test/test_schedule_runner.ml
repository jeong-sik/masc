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
  match rm dir with
  | () -> ()
  | exception Sys_error msg -> fail ("rm_rf failed: " ^ msg)
  | exception Unix.Unix_error (err, fn, arg) ->
    fail
      (Printf.sprintf
         "rm_rf failed: %s %s %s"
         fn
         arg
         (Unix.error_message err))
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
  ?(risk_class = Read_only)
  ?approval_required
  ?recurrence
  config
  =
  match
    create config ~schedule_id ?approval_required ~requested_at:100.0
      ~requested_by:(human "requester") ~scheduled_by:(human "scheduler")
      ~due_at:200.0 ~payload:(payload_json "wake me") ~risk_class
      ~source:Operator_request ?recurrence ()
  with
  | Ok request -> request
  | Error err -> fail (service_error_to_string err)
;;

let tick_ok ?dispatch_wrapper ?consumer config ~now =
  match tick ?dispatch_wrapper ?consumer config ~now with
  | Ok result -> result
  | Error err -> fail (runner_error_to_string err)
;;

let check_kind label expected actual =
  check string label (signal_kind_to_string expected) (signal_kind_to_string actual)
;;

let check_dispatch_status label expected actual =
  check string label (dispatch_status_to_string expected) (dispatch_status_to_string actual)
;;

let check_dispatch_duration_recorded label (dispatch : dispatch_result) =
  check bool label true (dispatch.duration_sec >= 0.0)
;;

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let check_json_string_field label expected name json =
  match json_field name json with
  | Some (`String actual) -> check string label expected actual
  | _ -> fail (Printf.sprintf "missing string JSON field: %s" name)
;;

let check_json_int_field label expected name json =
  match json_field name json with
  | Some (`Int actual) -> check int label expected actual
  | _ -> fail (Printf.sprintf "missing int JSON field: %s" name)
;;

let check_json_float_field label expected name json =
  match json_field name json with
  | Some (`Float actual) -> check (float 0.001) label expected actual
  | Some (`Int actual) -> check (float 0.001) label expected (float_of_int actual)
  | _ -> fail (Printf.sprintf "missing float JSON field: %s" name)
;;

let current_dated_jsonl_file base_dir =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month =
    Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
  in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  Filename.concat (Filename.concat base_dir month) day
;;

let append_raw_line path line =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       output_string oc line;
       output_char oc '\n')
;;

let accepting_consumer ?(accept = Ok ()) ?dispatch_result calls =
  let dispatch_result =
    Option.value
      ~default:(Ok (`Assoc [ "ok", `Bool true ]))
      dispatch_result
  in
  { accepts = (fun _request -> accept)
  ; dispatch =
      (fun request ->
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
  check int "durable signal count" 1 (List.length (read_recent_signals config 10))
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
  check_dispatch_duration_recorded "dispatch duration recorded" (List.hd result.dispatches);
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
  check_dispatch_duration_recorded "unsupported duration recorded" (List.hd result.dispatches);
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

let test_tick_emits_approval_blocker_then_candidate_after_grant () =
  with_workspace
  @@ fun config ->
  let request =
    create_ok ~schedule_id:"write-1" ~risk_class:Workspace_write config
  in
  let blocked = tick_ok config ~now:201.0 in
  check int "blocked signal" 1 (List.length blocked.emitted);
  let blocked_signal = List.hd blocked.emitted in
  check_kind "blocked kind" Due_blocked_approval blocked_signal.kind;
  check string "blocked id" request.schedule_id blocked_signal.schedule_id;
  let blocked_again = tick_ok config ~now:202.0 in
  check int "blocked dedupe" 0 (List.length blocked_again.emitted);
  (match approve config ~schedule_id:request.schedule_id ~approved_by:(human "approver") () with
   | Ok _ -> ()
   | Error err -> fail (service_error_to_string err));
  let due = tick_ok config ~now:203.0 in
  check int "candidate after approval" 1 (List.length due.emitted);
  check_kind "candidate kind" Due_candidate (List.hd due.emitted).kind;
  check int "two durable signals" 2 (List.length (read_recent_signals config 10))
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
  check int "two durable signals" 2 (List.length (read_recent_signals config 10))
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

let test_tick_blocks_recurring_side_effect_until_fresh_grant () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request =
    create_ok ~schedule_id:"write-loop-dispatch-1" ~risk_class:Workspace_write
      ~recurrence:(Interval { interval_sec = 60 })
      config
  in
  (match
     approve config ~grant_id:"grant-loop-1" ~approved_at:150.0
       ~schedule_id:request.schedule_id ~approved_by:(human "approver-1") ()
   with
   | Ok _ -> ()
   | Error err -> fail (service_error_to_string err));
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
  let blocked =
    tick_ok config ~now:260.0 ~consumer:(accepting_consumer calls)
  in
  check int "blocked signal" 1 (List.length blocked.emitted);
  check_kind "blocked kind" Due_blocked_approval (List.hd blocked.emitted).kind;
  check int "no stale-grant dispatch" 0 (List.length blocked.dispatches);
  check Alcotest.(list string) "no second consumer call yet" [ request.schedule_id ] !calls;
  (match
     approve config ~grant_id:"grant-loop-2" ~approved_at:260.5
       ~schedule_id:request.schedule_id ~approved_by:(human "approver-2") ()
   with
   | Ok stored -> check string "fresh grant keeps due" "due" (schedule_status_to_string stored.status)
   | Error err -> fail (service_error_to_string err));
  let second =
    tick_ok config ~now:261.0 ~consumer:(accepting_consumer calls)
  in
  check int "second dispatch" 1 (List.length second.dispatches);
  check Alcotest.(list string) "second consumer call"
    [ request.schedule_id; request.schedule_id ]
    !calls
;;

let test_tick_marks_dispatch_failure_failed () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let request = create_ok ~schedule_id:"dispatch-fail-1" config in
  let result =
    tick_ok config ~now:201.0
      ~consumer:(accepting_consumer ~dispatch_result:(Error "boom") calls)
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

let test_tick_reraises_dispatch_cancellation () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"dispatch-cancel-1" config in
  let consumer =
    { accepts = (fun _request -> Ok ())
    ; dispatch =
        (fun _request ->
          raise (Eio.Cancel.Cancelled (Failure "schedule-dispatch-cancel")))
    }
  in
  let raised = ref false in
  (try ignore (tick ~consumer config ~now:201.0 : (tick_result, runner_error) result) with
   | Eio.Cancel.Cancelled (Failure message)
     when String.equal message "schedule-dispatch-cancel" ->
     raised := true);
  check bool "dispatch cancellation is re-raised" true !raised;
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> ()
   | Some execution ->
     fail
       ("cancellation must not be recorded as business dispatch failure: "
        ^ Schedule_domain.execution_status_to_string execution.status))
;;

let test_tick_dispatch_wrapper_observes_candidate () =
  with_workspace
  @@ fun config ->
  let calls = ref [] in
  let wrapped = ref [] in
  let request = create_ok ~schedule_id:"dispatch-wrapper-1" config in
  let dispatch_wrapper request run =
    wrapped := request.schedule_id :: !wrapped;
    let result = run () in
    check_dispatch_status "wrapped result status" Dispatch_succeeded result.status;
    result
  in
  let result =
    tick_ok
      ~dispatch_wrapper
      ~consumer:(accepting_consumer calls)
      config
      ~now:201.0
  in
  check int "one dispatch" 1 (List.length result.dispatches);
  check Alcotest.(list string) "wrapper saw candidate" [ request.schedule_id ] !wrapped;
  check Alcotest.(list string) "consumer still called" [ request.schedule_id ] !calls
;;

let test_signal_seen_write_failure_is_explicit () =
  with_workspace
  @@ fun config ->
  Workspace_utils.mkdir_p (schedules_dir config);
  Unix.mkdir (signal_seen_path config) 0o755;
  match Schedule_runner.For_testing.write_seen config [ "signal-key" ] with
  | Ok () -> fail "signal seen write failure was silently accepted"
  | Error msg ->
    check bool "failure detail is surfaced" true (String.length msg > 0)
;;

let test_read_recent_signals_reports_decode_errors () =
  with_workspace
  @@ fun config ->
  let signal =
    { signal_id = "sig-read-error-valid"
    ; kind = Due_candidate
    ; schedule_id = "sched-read-error-valid"
    ; emitted_at = 201.0
    ; due_at = 200.0
    ; risk_class = Read_only
    ; payload_digest = "sha256:valid"
    ; payload = payload_json "valid"
    }
  in
  let store = Dated_jsonl.create ~base_dir:(signals_dir config) () in
  (match Dated_jsonl.append_result store (wake_signal_to_yojson signal) with
   | Ok () -> ()
   | Error msg -> fail ("signal append failed: " ^ msg));
  let signal_file = current_dated_jsonl_file (signals_dir config) in
  append_raw_line signal_file "{not-json";
  append_raw_line
    signal_file
    {|{"event_type":"schedule.due_candidate","signal_id":"sig-missing-schedule"}|};
  let read = read_recent_signals_with_errors config 10 in
  check int "one valid signal" 1 (List.length read.signals);
  check int "two signal read errors" 2 (List.length read.errors);
  (match read.errors with
   | first :: second :: [] ->
     check string "first read error kind" "json_parse"
       (wake_signal_read_error_kind_to_string first.kind);
     check int "first ordinal" 1 first.ordinal;
     check string "second read error kind" "schema_decode"
       (wake_signal_read_error_kind_to_string second.kind);
     check int "second ordinal" 2 second.ordinal
   | _ -> fail "expected two typed signal read errors");
  let json_labels = [ "kind", "json_parse" ] in
  let schema_labels = [ "kind", "schema_decode" ] in
  let json_before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_schedule_signal_read_error_total
      ~labels:json_labels
      ()
  in
  let schema_before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_schedule_signal_read_error_total
      ~labels:schema_labels
      ()
  in
  let legacy = read_recent_signals config 10 in
  check int "legacy wrapper returns only valid signals" 1 (List.length legacy);
  check (float 0.000001) "json parse metric increments" 1.0
    (Otel_metric_store.metric_value_or_zero
       Otel_metric_store.metric_schedule_signal_read_error_total
       ~labels:json_labels
       ()
     -. json_before);
  check (float 0.000001) "schema decode metric increments" 1.0
    (Otel_metric_store.metric_value_or_zero
       Otel_metric_store.metric_schedule_signal_read_error_total
       ~labels:schema_labels
       ()
     -. schema_before)
;;

let test_runner_status_snapshot_tracks_liveness () =
  Schedule_runner_status.reset_for_test ();
  let initial =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now:0.0 ~stale_after_sec:10.0
  in
  check_json_string_field "initial status" "not_started" "status" initial;
  Schedule_runner_status.record_tick_started ~now:1.0;
  let running =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now:1.5 ~stale_after_sec:10.0
  in
  check_json_string_field "running status" "running" "status" running;
  let result =
    { due_changed = 1
    ; emitted = []
    ; rescheduled = 2
    ; dispatches =
        [ { schedule_id = "status-1"
          ; status = Dispatch_succeeded
          ; detail = Some (`Assoc [ "ok", `Bool true ])
          ; error = None
          ; duration_sec = 0.125
          }
        ; { schedule_id = "status-2"
          ; status = Dispatch_unsupported
          ; detail = None
          ; error = Some "unsupported"
          ; duration_sec = 0.0
          }
        ]
    }
  in
  Schedule_runner_status.record_tick_ok ~started_at:1.0 ~finished_at:1.25 result;
  let ok =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now:2.25 ~stale_after_sec:10.0
  in
  check_json_string_field "ok status" "ok" "status" ok;
  check_json_int_field "tick count" 1 "tick_count" ok;
  check_json_int_field "success count" 1 "success_count" ok;
  check_json_float_field "last duration" 0.25 "last_duration_sec" ok;
  check_json_float_field "last tick age" 1.0 "last_tick_age_sec" ok;
  (match json_field "last_counts" ok with
   | Some counts ->
     check_json_int_field "last due count" 1 "due_changed" counts;
     check_json_int_field "last reschedule count" 2 "rescheduled" counts;
     check_json_int_field "last success dispatch count" 1 "dispatch_succeeded" counts;
     check_json_int_field "last unsupported dispatch count" 1 "dispatch_unsupported" counts;
     check_json_int_field "last wake enqueued count" 0 "wake_enqueued" counts;
     check_json_int_field "last wake skipped missing schedule count" 0
       "wake_skipped_missing_schedule"
       counts;
     check_json_int_field "last wake skipped non-keeper actor count" 0
       "wake_skipped_non_keeper_actor"
       counts;
     check_json_int_field "last wake skipped unregistered keeper count" 0
       "wake_skipped_unregistered_keeper"
       counts;
     check_json_int_field "last wake failed count" 0 "wake_failed" counts
   | None -> fail "missing last_counts");
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
    result;
  let wake_degraded =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now:3.0 ~stale_after_sec:10.0
  in
  check_json_string_field "wake failure degrades status" "degraded" "status" wake_degraded;
  (match json_field "last_counts" wake_degraded with
   | Some counts ->
     check_json_int_field "wake enqueued count" 2 "wake_enqueued" counts;
     check_json_int_field "wake skipped count" 3 "wake_skipped_no_keeper" counts;
     check_json_int_field "wake missing schedule count" 1
       "wake_skipped_missing_schedule"
       counts;
     check_json_int_field "wake non-keeper actor count" 1
       "wake_skipped_non_keeper_actor"
       counts;
     check_json_int_field "wake unregistered keeper count" 1
       "wake_skipped_unregistered_keeper"
       counts;
     check_json_int_field "wake failed count" 1 "wake_failed" counts
   | None -> fail "missing wake failure last_counts");
  Schedule_runner_status.record_tick_error ~started_at:3.0 ~finished_at:3.5 "boom";
  let degraded =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now:4.0 ~stale_after_sec:10.0
  in
  check_json_string_field "degraded status" "degraded" "status" degraded;
  check_json_int_field "failure count" 1 "failure_count" degraded;
  Schedule_runner_status.record_tick_crash ~started_at:5.0 ~finished_at:5.5 "crash";
  let stale =
    Schedule_runner_status.snapshot ()
    |> Schedule_runner_status.snapshot_to_yojson ~now:20.0 ~stale_after_sec:10.0
  in
  check_json_string_field "stale status" "stale" "status" stale;
  check_json_int_field "crash count" 1 "crash_count" stale
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
        ; test_case "emits approval blocker then candidate after grant" `Quick
            test_tick_emits_approval_blocker_then_candidate_after_grant
        ; test_case "reschedules recurring candidate after signal" `Quick
            test_tick_reschedules_recurring_candidate_after_signal
        ; test_case "dispatches recurring candidate to next due" `Quick
            test_tick_dispatches_recurring_candidate_to_next_due
        ; test_case "blocks recurring side-effect until fresh grant" `Quick
            test_tick_blocks_recurring_side_effect_until_fresh_grant
        ; test_case "marks dispatch failure failed" `Quick
            test_tick_marks_dispatch_failure_failed
        ; test_case "re-raises dispatch cancellation" `Quick
            test_tick_reraises_dispatch_cancellation
        ; test_case "dispatch wrapper observes candidate" `Quick
            test_tick_dispatch_wrapper_observes_candidate
        ; test_case "signal seen write failure is explicit" `Quick
            test_signal_seen_write_failure_is_explicit
        ; test_case "read recent signals reports decode errors" `Quick
            test_read_recent_signals_reports_decode_errors
        ] )
    ; ( "status",
        [ test_case "tracks liveness snapshot" `Quick
            test_runner_status_snapshot_tracks_liveness
        ] )
    ]
;;

(** Regression coverage for Agent periodic callback cleanup.

    Periodic callbacks run in Eio fibers while an agent turn is in flight. The
    agent must stop that loop when the run exits normally or by cancellation so
    long-lived caller switches do not retain active callback loops. *)

open Agent_sdk

let response : Types.api_response =
  { id = "periodic-cleanup-response"
  ; model = "mock-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "ok" ]
  ; usage = None
  ; telemetry = None
  }
;;

let provider_config =
  Provider_mock.local_provider_config
    ~base_url:"http://mock.local"
    ~model_id:"mock-model"
    ~request_path:"/v1/chat/completions"
    ()
;;

let make_transport ~clock ~sleep_s () : Llm_provider.Llm_transport.t =
  let complete () =
    Eio.Time.sleep clock sleep_s;
    response
  in
  { complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok (complete ()); latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok (complete ()))
  }
;;

let make_agent ?on_run_complete ?raw_trace ~net ~transport ?(periodic_callbacks = []) () =
  let options =
    { Agent.default_options with
      provider_config = Some provider_config
    ; transport = Some transport
    ; periodic_callbacks
    ; on_run_complete
    ; raw_trace
    }
  in
  let config =
    { (Types.default_config ~model:"test-model") with
      name = "periodic-cleanup"
    ; model = "mock-model"
    }
  in
  Agent.create ~net ~config ~options ()
;;

let with_log_capture f =
  let sink, get_records = Log.collector_sink () in
  Log.clear_sinks ();
  Log.set_global_level Log.Info;
  Log.add_sink sink;
  Fun.protect
    ~finally:(fun () ->
      Log.clear_sinks ();
      Log.set_global_level Log.Info)
    (fun () -> f get_records)
;;

let has_log_message message records =
  List.exists (fun (record : Log.record) -> String.equal record.message message) records
;;

let find_log_message message records =
  List.find_opt (fun (record : Log.record) -> String.equal record.message message) records
;;

let string_field name fields =
  List.find_map
    (function
      | Log.S (field_name, value) when String.equal field_name name -> Some value
      | _ -> None)
    fields
;;

let unwrap = function
  | Ok value -> value
  | Error err -> Alcotest.fail (Error.to_string err)
;;

let with_temp_dir prefix f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%06x" prefix (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let check_callback_loop_stopped ~clock calls =
  let calls_at_exit = Atomic.get calls in
  Alcotest.(check bool) "callback loop had started" true (calls_at_exit > 0);
  Eio.Time.sleep clock 0.015;
  let calls_after_quiesce = Atomic.get calls in
  Eio.Time.sleep clock 0.04;
  Alcotest.(check int) "callback loop stopped" calls_after_quiesce (Atomic.get calls)
;;

let test_run_stops_periodic_callbacks_after_success () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let calls = Atomic.make 0 in
  let callback : Agent.periodic_callback =
    { interval_sec = 0.005; callback = (fun () -> Atomic.incr calls) }
  in
  let transport = make_transport ~clock ~sleep_s:0.03 () in
  let agent =
    make_agent ~net:(Eio.Stdenv.net env) ~transport ~periodic_callbacks:[ callback ] ()
  in
  (match Agent.run ~sw ~clock agent "finish" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected success: " ^ Error.to_string err));
  check_callback_loop_stopped ~clock calls
;;

let test_run_stops_periodic_callbacks_after_cancellation () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let calls = Atomic.make 0 in
  let callback : Agent.periodic_callback =
    { interval_sec = 0.005; callback = (fun () -> Atomic.incr calls) }
  in
  let transport = make_transport ~clock ~sleep_s:1.0 () in
  let agent =
    make_agent ~net:(Eio.Stdenv.net env) ~transport ~periodic_callbacks:[ callback ] ()
  in
  (try
     ignore
       (Eio.Time.with_timeout_exn clock 0.05 (fun () ->
          Agent.run ~sw ~clock agent "cancel"));
     Alcotest.fail "expected timeout"
   with
   | Eio.Time.Timeout -> ());
  check_callback_loop_stopped ~clock calls
;;

let test_run_stream_uses_same_cleanup_scope () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let calls = Atomic.make 0 in
  let callback : Agent.periodic_callback =
    { interval_sec = 0.005; callback = (fun () -> Atomic.incr calls) }
  in
  let transport = make_transport ~clock ~sleep_s:0.03 () in
  let agent =
    make_agent ~net:(Eio.Stdenv.net env) ~transport ~periodic_callbacks:[ callback ] ()
  in
  (match Agent.run_stream ~sw ~clock ~on_event:(fun _ -> ()) agent "finish" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected stream success: " ^ Error.to_string err));
  check_callback_loop_stopped ~clock calls
;;

let test_on_run_complete_failure_is_structured_log () =
  with_log_capture
  @@ fun get_records ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let transport = make_transport ~clock ~sleep_s:0.0 () in
  let agent =
    make_agent
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~on_run_complete:(fun _ -> failwith "completion sink failed")
      ()
  in
  (match Agent.run ~sw ~clock agent "finish" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected success: " ^ Error.to_string err));
  Alcotest.(check bool)
    "on_run_complete failure logged"
    true
    (has_log_message "on_run_complete callback raised" (get_records ()))
;;

(* Mirror of the #2036 observer-isolation contract for [on_run_complete]:
   generic exceptions are contained (test above), but
   [Eio.Cancel.Cancelled] must propagate so structured cancellation is
   not absorbed by the finalize callback. *)
let test_on_run_complete_cancelled_propagates () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let transport = make_transport ~clock ~sleep_s:0.0 () in
  let agent =
    make_agent
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~on_run_complete:(fun _ -> raise (Eio.Cancel.Cancelled Exit))
      ()
  in
  match Agent.run ~sw ~clock agent "finish" with
  | _ -> Alcotest.fail "expected Cancelled to propagate out of run"
  | exception Eio.Cancel.Cancelled _ -> ()
;;

let test_on_run_complete_cancelled_finishes_raw_trace () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir "oas-agent-complete-cancel-raw-trace"
  @@ fun session_root ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let transport = make_transport ~clock ~sleep_s:0.0 () in
  let raw_trace =
    unwrap
      (Raw_trace.create_for_session
         ~session_root
         ~session_id:"callback-cancel"
         ~agent_name:"periodic-cleanup"
         ())
  in
  let agent =
    make_agent
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~raw_trace
      ~on_run_complete:(fun _ -> raise (Eio.Cancel.Cancelled Exit))
      ()
  in
  (match Agent.run ~sw ~clock agent "finish" with
   | _ -> Alcotest.fail "expected Cancelled to propagate out of raw trace run"
   | exception Eio.Cancel.Cancelled _ -> ());
  let records = unwrap (Raw_trace.read_all ~path:(Raw_trace.file_path raw_trace) ()) in
  Alcotest.(check bool)
    "raw trace was finished before callback cancellation propagated"
    true
    (List.exists
       (fun (record : Raw_trace.record) -> record.record_type = Raw_trace.Run_finished)
       records)
;;

exception Primary_run_failure

let test_exception_preserved_when_raw_trace_finalization_fails () =
  let previous_backtrace_status = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous_backtrace_status)
    (fun () ->
       with_log_capture
       @@ fun get_records ->
       Eio_main.run
       @@ fun env ->
       with_temp_dir "oas-agent-exception-raw-trace-finalize"
       @@ fun session_root ->
       Eio.Switch.run
       @@ fun sw ->
       let clock = Eio.Stdenv.clock env in
       let raw_trace =
         unwrap
           (Raw_trace.create_for_session
              ~session_root
              ~session_id:"exception-finalize"
              ~agent_name:"periodic-cleanup"
              ())
       in
       let trace_path = Raw_trace.file_path raw_trace in
       let expected_backtrace = ref None in
       let raise_primary () =
         try raise Primary_run_failure with
         | exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           expected_backtrace := Some (Printexc.raw_backtrace_to_string backtrace);
           Printexc.raise_with_backtrace exn backtrace
       in
       let transport : Llm_provider.Llm_transport.t =
         { complete_sync =
             (fun _req ->
               Sys.remove trace_path;
               Unix.mkdir trace_path 0o755;
               raise_primary ())
         ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok response)
         }
       in
       let agent = make_agent ~net:(Eio.Stdenv.net env) ~transport ~raw_trace () in
       let observed_backtrace =
         match Agent.run ~sw ~clock agent "raise" with
         | _ -> Alcotest.fail "expected the primary run exception"
         | exception exn ->
           let backtrace =
             Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ())
           in
           (match exn with
            | Primary_run_failure -> backtrace
            | _ ->
              Alcotest.failf
                "expected Primary_run_failure, got %s"
                (Printexc.to_string exn))
       in
       Alcotest.(check bool)
         "captured primary backtrace"
         true
         (match !expected_backtrace with
          | Some backtrace -> String.length backtrace > 0
          | None -> false);
       Alcotest.(check bool)
         "original raw backtrace prefix preserved"
         true
         (match !expected_backtrace with
          | Some backtrace -> String.starts_with ~prefix:backtrace observed_backtrace
          | None -> false);
       let record =
         match
           find_log_message
             "raw trace finalization failed after run exception"
             (get_records ())
         with
         | Some record -> record
         | None -> Alcotest.fail "missing raw trace finalization failure log"
       in
       Alcotest.(check (option string))
         "structured primary exception"
         (Some (Printexc.to_string Primary_run_failure))
         (string_field "primary_exception" record.fields);
       Alcotest.(check bool)
         "structured finalization error"
         true
         (Option.is_some (string_field "finalization_error" record.fields));
       Alcotest.(check bool)
         "structured worker run id"
         true
         (Option.is_some (string_field "worker_run_id" record.fields)))
;;

(* Contract (agent_types.mli): on_run_complete runs *before* the terminal
   lifecycle transition, so a completion hook observes the pre-terminal run
   state rather than Completed/Failed. (Codex P2 on #2057.) *)
let test_on_run_complete_observes_pre_terminal_lifecycle () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let transport = make_transport ~clock ~sleep_s:0.0 () in
  let agent_ref = ref None in
  let observed = ref None in
  let agent =
    make_agent
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~on_run_complete:(fun _ ->
        match !agent_ref with
        | Some a ->
          observed
          := Option.map
               (fun (s : Agent.lifecycle_snapshot) -> s.status)
               (Agent.lifecycle a)
        | None -> ())
      ()
  in
  agent_ref := Some agent;
  (match Agent.run ~sw ~clock agent "finish" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected success: " ^ Error.to_string err));
  (match !observed with
   | Some status ->
     Alcotest.(check bool)
       "on_run_complete observed pre-terminal lifecycle"
       false
       (Agent_lifecycle.is_terminal status)
   | None -> Alcotest.fail "on_run_complete did not observe a lifecycle snapshot");
  match Agent.lifecycle agent with
  | Some snap ->
    Alcotest.(check bool)
      "agent ends Completed after the callback"
      true
      (snap.status = Agent.Completed)
  | None -> Alcotest.fail "expected terminal lifecycle after run"
;;

let test_periodic_callback_failure_is_structured_log () =
  with_log_capture
  @@ fun get_records ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let calls = Atomic.make 0 in
  let callback : Agent.periodic_callback =
    { interval_sec = 0.005
    ; callback =
        (fun () ->
          Atomic.incr calls;
          failwith "periodic sink failed")
    }
  in
  let transport = make_transport ~clock ~sleep_s:0.03 () in
  let agent =
    make_agent ~net:(Eio.Stdenv.net env) ~transport ~periodic_callbacks:[ callback ] ()
  in
  (match Agent.run ~sw ~clock agent "finish" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected success: " ^ Error.to_string err));
  Alcotest.(check bool) "callback loop had started" true (Atomic.get calls > 0);
  Alcotest.(check bool)
    "periodic callback failure logged"
    true
    (has_log_message "periodic callback raised" (get_records ()))
;;

let () =
  Alcotest.run
    "Agent periodic callback cleanup"
    [ ( "cleanup"
      , [ Alcotest.test_case
            "run stops callbacks after success"
            `Quick
            test_run_stops_periodic_callbacks_after_success
        ; Alcotest.test_case
            "run stops callbacks after cancellation"
            `Quick
            test_run_stops_periodic_callbacks_after_cancellation
        ; Alcotest.test_case
            "run_stream uses same cleanup"
            `Quick
            test_run_stream_uses_same_cleanup_scope
        ; Alcotest.test_case
            "on_run_complete failure uses structured log"
            `Quick
            test_on_run_complete_failure_is_structured_log
        ; Alcotest.test_case
            "on_run_complete Cancelled propagates"
            `Quick
            test_on_run_complete_cancelled_propagates
        ; Alcotest.test_case
            "on_run_complete Cancelled still finishes raw trace"
            `Quick
            test_on_run_complete_cancelled_finishes_raw_trace
        ; Alcotest.test_case
            "run exception survives raw trace finalization failure"
            `Quick
            test_exception_preserved_when_raw_trace_finalization_fails
        ; Alcotest.test_case
            "on_run_complete observes pre-terminal lifecycle (#2057)"
            `Quick
            test_on_run_complete_observes_pre_terminal_lifecycle
        ; Alcotest.test_case
            "periodic callback failure uses structured log"
            `Quick
            test_periodic_callback_failure_is_structured_log
        ] )
    ]
;;

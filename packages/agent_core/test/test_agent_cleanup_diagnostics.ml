open Agent_core

type cleanup_failure =
  | Returned_error
  | Raised_reserved

type diagnostic_failure =
  | Closed_private_channel
  | Reserved_logger of exn

let first_location backtrace =
  Alcotest.(check bool) "exception has a recorded backtrace" true
    (Printexc.raw_backtrace_length backtrace > 0);
  let slot = Printexc.get_raw_backtrace_slot backtrace 0 in
  match Printexc.Slot.location (Printexc.convert_raw_backtrace_slot slot) with
  | Some location -> location
  | None -> Alcotest.fail "exception has no recorded source location"
;;

let raise_recorded origin exn =
  try raise exn with
  | observed ->
    let backtrace = Printexc.get_raw_backtrace () in
    origin := Some (first_location backtrace);
    Printexc.raise_with_backtrace observed backtrace
;;

let with_execution f =
  let recording = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect ~finally:(fun () -> Printexc.record_backtrace recording) (fun () ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let native_path = Filename.temp_file "agent-cleanup-diagnostic-" ".dir" in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
    let runtime =
      match Agent.create_execution_runtime ~sw
        ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1 with
      | Ok runtime -> runtime
      | Error error -> Alcotest.fail (Error.to_string error)
    in
    f ~env ~sw ~runtime ~dir)
;;

(* This channel owns a private duplicate. Neither process stderr nor the global
   Format.err_formatter is closed or redirected, including during assertions. *)
let with_failed_debug env failure f =
  let channel = Unix.out_channel_of_descr (Unix.dup Unix.stderr) in
  close_out channel;
  let entered = ref false in
  let channel_failed = ref false in
  let logger_origin = ref None in
  let sink =
    { Eio.Debug.traceln = (fun ?__POS__:_ format ->
        Format.kasprintf (fun message ->
          entered := true;
          match failure with
          | Reserved_logger exn -> raise_recorded logger_origin exn
          | Closed_private_channel ->
            (try output_string channel message; flush channel with
             | Sys_error _ as exn -> channel_failed := true; raise exn)) format)
    }
  in
  Eio.Fiber.with_binding (Eio.Stdenv.debug env)#traceln sink (fun () ->
    f ~entered ~channel_failed ~logger_origin)
;;

let agent ~net ~provider_calls =
  let response : Types.api_response =
    { id = "unused-cleanup-response"; model = "test-model"
    ; content = [Types.Text "unexpected provider call"]
    ; unreadable_tool_uses = []; stop_reason = Types.EndTurn
    ; usage = None; telemetry = None }
  in
  let transport = Llm_provider.Llm_transport.custom
    { complete_sync = (fun _ ->
        incr provider_calls;
        { Llm_provider.Llm_transport.response = Ok response; latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ ->
        incr provider_calls; Ok response)
    }
  in
  Agent.create ~media_store:(History.Memory_store.create ()) ~net
    ~config:{ (Types.default_config ~model:"test-model") with
      name = "cleanup-diagnostic-fixture" }
    ~options:{ Agent.default_options with transport = Some transport
      ; provider_config = Some (Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"test"
          ~base_url:"http://cleanup.invalid" ~model_id:"test-model" ~api_key:""
          ~request_path:"/v1/chat/completions" ()) }
    ()
;;

let check_cleanup ~primary ~expected_outcome ~cleanup ~diagnostic () =
  with_execution @@ fun ~env ~sw ~runtime ~dir ->
  let provider_calls = ref 0 in
  let scope_ready_calls = ref 0 in
  let terminal_calls = ref 0 in
  let locator = ref None in
  let primary_origin = ref None in
  let agent = agent ~net:(Eio.Stdenv.net env) ~provider_calls in
  let store = Agent.execution_store ~runtime ~dir
    ~on_scope_ready:(fun value ->
      incr scope_ready_calls;
      locator := Some value;
      raise_recorded primary_origin primary)
    ~on_terminal_disposition:(fun _ ->
      incr terminal_calls;
      match cleanup with
      | Returned_error -> Error "terminal receipt unavailable"
      | Raised_reserved ->
        raise (Fun.Finally_raised (Eio.Cancel.Cancelled Exit)))
    ()
  in
  with_failed_debug env diagnostic
  @@ fun ~entered ~channel_failed ~logger_origin ->
  let observed, backtrace =
    match Agent.run ~sw ~execution_store:store agent "stop at scope publication" with
    | Ok _ | Error _ -> Alcotest.fail "reserved publication failure became a result"
    | exception observed -> observed, Printexc.get_raw_backtrace ()
  in
  (match diagnostic with
   | Closed_private_channel ->
     Alcotest.(check bool) "private debug channel really failed" true !channel_failed;
     Alcotest.(check bool) "original exception object survives diagnostic IO failure"
       true (observed == primary);
     Alcotest.(check bool) "original exception source location survives"
       true (Some (first_location backtrace) = !primary_origin)
   | Reserved_logger logger_exn ->
     Alcotest.(check bool) "new reserved logger exception propagates intact"
       true (observed == logger_exn);
     Alcotest.(check bool) "new reserved logger source location survives"
       true (Some (first_location backtrace) = !logger_origin));
  Alcotest.(check bool) "cleanup diagnostic was attempted" true !entered;
  Alcotest.(check int) "publication runs once" 1 !scope_ready_calls;
  Alcotest.(check int) "terminal sink runs once" 1 !terminal_calls;
  Alcotest.(check int) "publication failure never dispatches a provider" 0 !provider_calls;
  let locator = match !locator with
    | Some locator -> locator
    | None -> Alcotest.fail "scope publication did not expose its locator"
  in
  let projection = match Agent.open_execution_projection ~runtime ~dir locator with
    | Ok projection -> projection
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error)
  in
  let terminal = match Agent.read_execution_terminal projection with
    | Ok (Some terminal) -> terminal
    | Ok None -> Alcotest.fail "diagnostic failure erased the canonical terminal"
    | Error error -> Alcotest.fail (Agent.Execution_projection.error_to_string error)
  in
  Alcotest.(check bool) "canonical operation outcome is unchanged" true
    (terminal.disposition.outcome = expected_outcome);
  Alcotest.(check bool) "no unsettled effect was invented" true
    (terminal.disposition.recovery = Agent.Retire)
;;

let () =
  let mixed_logger = Eio.Exn.Multiple
    [ Failure "ordinary diagnostic member", Printexc.get_callstack 0
    ; Eio.Cancel.Cancelled Exit, Printexc.get_callstack 0 ]
  in
  Alcotest.run "agent_cleanup_diagnostics"
    [ "public_execution_store",
      [ Alcotest.test_case "returned cleanup error preserves primary through debug IO failure"
          `Quick (check_cleanup ~primary:Sys.Break ~expected_outcome:Agent.Terminal_failed
            ~cleanup:Returned_error ~diagnostic:Closed_private_channel)
      ; Alcotest.test_case "raised cleanup error preserves cancellation through debug IO failure"
          `Quick (check_cleanup ~primary:(Eio.Cancel.Cancelled Exit)
            ~expected_outcome:Agent.Terminal_cancelled ~cleanup:Raised_reserved
            ~diagnostic:Closed_private_channel)
      ; Alcotest.test_case "returned cleanup error propagates mixed reserved logger failure"
          `Quick (check_cleanup ~primary:Sys.Break ~expected_outcome:Agent.Terminal_failed
            ~cleanup:Returned_error ~diagnostic:(Reserved_logger mixed_logger))
      ; Alcotest.test_case "raised cleanup error propagates logger runtime failure"
          `Quick (check_cleanup ~primary:Sys.Break ~expected_outcome:Agent.Terminal_failed
            ~cleanup:Raised_reserved ~diagnostic:(Reserved_logger Out_of_memory))
      ] ]
;;

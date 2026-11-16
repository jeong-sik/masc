open Agent_core
open Alcotest
module Internal = Agent_core__
module Writer = Internal.Execution_lane_writer
module Scope = Internal.Execution_agent_scope
module Runtime = Internal.Execution_runtime
module Codec = Internal.Execution_codec_executor
module Projection = Agent.Execution_projection

(* The host's own reasons. [Host_stop] is the one it names to agent_core. *)
exception Host_stop
exception Operator_stop

let host_stop = function
  | Host_stop -> true
  | _ -> false
;;

let agent_name = "host-stop-agent"
let tool_name = "blocking_tool"

let value = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let scope_value = function
  | Ok value -> value
  | Error error -> fail (Scope.error_to_string error)
;;

let projection_value = function
  | Ok value -> value
  | Error error -> fail (Projection.error_to_string error)
;;

let make_dir fs prefix =
  let native_path = Filename.temp_file prefix ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(fs / native_path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  dir
;;

let tool_use_response : Types.api_response =
  { id = "host-stop-tool-use"
  ; model = "host-stop-model"
  ; unreadable_tool_uses = []
  ; stop_reason = Types.StopToolUse
  ; content =
      [ Llm_provider.Types.ToolUse
          { id = "host-stop-call"; name = tool_name; input = `Assoc [] }
      ]
  ; usage = None
  ; telemetry = None
  }
;;

(* Where the call is when the host stops it. *)
type cut =
  | In_provider_call
  | In_tool_handler

let never () = Eio.Promise.await (fst (Eio.Promise.create ()))

let transport ~cut ~entered : Llm_provider.Llm_transport.t =
  let complete () =
    match cut with
    | In_provider_call ->
      ignore (Eio.Promise.try_resolve entered () : bool);
      never ()
    | In_tool_handler -> tool_use_response
  in
  Llm_provider.Llm_transport.custom
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = Ok (complete ()); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok (complete ()))
    }
;;

let blocking_tool ~entered =
  Tool.create ~name:tool_name ~description:"blocks until cancelled" ~parameters:[]
    (fun _input ->
       ignore (Eio.Promise.try_resolve entered () : bool);
       never ())
;;

let agent ~net ~cut ~entered =
  let options =
    { Agent.default_options with
      transport = Some (transport ~cut ~entered)
    ; provider_config =
        Some
          (Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.OpenAI_compat
             ~provider_id:"test"
             ~base_url:"http://host-stop.invalid"
             ~model_id:"host-stop-model"
             ~api_key:""
             ~headers:[ "Content-Type", "application/json" ]
             ~request_path:"/v1/chat/completions"
             ())
    }
  in
  Agent.create
    ~media_store:(Agent_core.History.Memory_store.create ())
    ~net
    ~config:{ (Types.default_config ~model:"host-stop-model") with name = agent_name }
    ~tools:[ blocking_tool ~entered ]
    ~options
    ()
;;

type outcome =
  { locator : Agent.execution_locator
  ; dispositions : Agent.execution_terminal_disposition list
  ; raised : exn
  }

(* Runs one Agent call in its own switch and fails that switch with [reason]
   once the call reaches [cut], as the masc Owner stops its child. *)
let run_and_stop env ~runtime ~dir ?host_stop ~cut reason =
  let entered, entered_resolver = Eio.Promise.create () in
  let locator = ref None in
  let dispositions = ref [] in
  let store =
    Agent.execution_store
      ~runtime
      ~dir
      ~on_scope_ready:(fun value ->
        locator := Some value;
        Ok ())
      ~on_terminal_disposition:(fun disposition ->
        dispositions := disposition :: !dispositions;
        Ok ())
      ?host_stop
      ()
  in
  let agent = agent ~net:(Eio.Stdenv.net env) ~cut ~entered:entered_resolver in
  let raised =
    match
      Eio.Switch.run (fun child_sw ->
        Eio.Fiber.fork ~sw:child_sw (fun () ->
          Eio.Promise.await entered;
          Eio.Switch.fail child_sw reason);
        Agent.run ~sw:child_sw ~execution_store:store agent "start")
    with
    | Ok _ -> fail "the stopped call returned a response"
    | Error error -> fail ("the stopped call returned an error: " ^ Error.to_string error)
    | exception raised -> raised
  in
  match !locator with
  | None -> fail "the call never published its locator"
  | Some locator -> { locator; dispositions = List.rev !dispositions; raised }
;;

let terminal ~runtime ~dir locator =
  projection_value
    (Agent.read_execution_terminal
       (projection_value (Agent.open_execution_projection ~runtime ~dir locator)))
;;

(* Reopening the journal also proves the stopped call released its writer. *)
let with_reopened ~codec ~dir locator read =
  let scope_locator =
    Agent.execution_locator_to_yojson locator |> Scope.scope_locator_of_yojson |> value
  in
  match
    Writer.resume ~codec ~dir (fun ~sw:_ writer ->
      (match Writer.await_ready writer with
       | Ok () -> ()
       | Error failure -> fail (Writer.scope_failure_to_string failure));
      read (scope_value (Scope.resume_running ~writer ~agent_name scope_locator)))
  with
  | Ok result -> result
  | Error failure -> fail (Writer.scope_failure_to_string failure)
;;

let open_attempt scope =
  match scope_value (Scope.resume_current_turn scope) with
  | Scope.Resume_turn_absent | Scope.Resume_turn_settled _ -> fail "no open turn was left"
  | Scope.Resume_turn_open turn ->
    (match scope_value (Scope.resume_provider_attempt turn) with
     | Scope.Resume_provider_absent | Scope.Resume_provider_settled _ ->
       fail "no open provider attempt was left"
     | Scope.Resume_provider_open attempt -> attempt)
;;

let with_env run =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count:1
    |> Result.map_error Error.to_string
    |> value
  in
  let codec =
    Runtime.create ~sw ~domain_mgr ~domain_count:1
    |> Result.map_error Runtime.create_error_to_string
    |> value
    |> Codec.of_runtime
  in
  let fresh_dir () =
    let dir = make_dir (Eio.Stdenv.fs env) "agent_core-host-stop-" in
    Eio.Switch.on_release sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
    dir
  in
  run env ~runtime ~codec ~fresh_dir
;;

let check_left_open label outcome ~runtime ~dir =
  check int (label ^ ": no terminal disposition") 0 (List.length outcome.dispositions);
  check bool (label ^ ": no terminal in the journal") true
    (Option.is_none (terminal ~runtime ~dir outcome.locator))
;;

let check_closed_cancelled label outcome ~runtime ~dir =
  (match outcome.dispositions with
   | [ { Agent.outcome = Terminal_cancelled; _ } ] -> ()
   | _ -> fail (label ^ ": expected one cancelled terminal disposition"));
  match terminal ~runtime ~dir outcome.locator with
  | Some { Agent.disposition = { Agent.outcome = Terminal_cancelled; _ }; _ } -> ()
  | Some _ | None -> fail (label ^ ": expected a cancelled terminal in the journal")
;;

let test_stop_in_provider_call_leaves_the_run_open () =
  with_env @@ fun env ~runtime ~codec ~fresh_dir ->
  let dir = fresh_dir () in
  let outcome = run_and_stop env ~runtime ~dir ~host_stop ~cut:In_provider_call Host_stop in
  check bool "the host's stop reaches the caller" true (outcome.raised = Host_stop);
  check_left_open "provider call" outcome ~runtime ~dir;
  with_reopened ~codec ~dir outcome.locator (fun scope ->
    let attempt = open_attempt scope in
    check int "no Tool invocation" 0
      (List.length (scope_value (Scope.provider_invocations attempt))))
;;

let test_stop_in_tool_handler_leaves_the_attempt_open () =
  with_env @@ fun env ~runtime ~codec ~fresh_dir ->
  let dir = fresh_dir () in
  let outcome = run_and_stop env ~runtime ~dir ~host_stop ~cut:In_tool_handler Host_stop in
  check_left_open "tool handler" outcome ~runtime ~dir;
  with_reopened ~codec ~dir outcome.locator (fun scope ->
    let attempt = open_attempt scope in
    (match scope_value (Scope.provider_invocations attempt) with
     | [ invocation ] -> check string "the cut Tool" tool_name invocation.Scope.tool_name
     | _ -> fail "expected exactly one Tool invocation");
    check bool "the Tool attempt has no result" false
      (scope_value (Scope.provider_invocations_settled attempt)))
;;

let test_wrapped_stops_leave_the_run_open () =
  with_env @@ fun env ~runtime ~codec:_ ~fresh_dir ->
  let backtrace = Printexc.get_callstack 1 in
  let dir = fresh_dir () in
  let outcome =
    run_and_stop env ~runtime ~dir ~host_stop ~cut:In_provider_call
      (Eio.Exn.Multiple [ Host_stop, backtrace; Stdlib.Fun.Finally_raised Host_stop, backtrace ])
  in
  check_left_open "every member is a stop" outcome ~runtime ~dir
;;

let test_stop_mixed_with_another_reason_closes () =
  with_env @@ fun env ~runtime ~codec:_ ~fresh_dir ->
  let backtrace = Printexc.get_callstack 1 in
  let dir = fresh_dir () in
  let outcome =
    run_and_stop env ~runtime ~dir ~host_stop ~cut:In_provider_call
      (Eio.Exn.Multiple [ Host_stop, backtrace; Operator_stop, backtrace ])
  in
  check_closed_cancelled "stop and another reason" outcome ~runtime ~dir
;;

let test_other_reason_closes () =
  with_env @@ fun env ~runtime ~codec:_ ~fresh_dir ->
  let dir = fresh_dir () in
  let outcome = run_and_stop env ~runtime ~dir ~host_stop ~cut:In_provider_call Operator_stop in
  check_closed_cancelled "another reason" outcome ~runtime ~dir
;;

let test_without_host_stop_closes () =
  with_env @@ fun env ~runtime ~codec:_ ~fresh_dir ->
  let dir = fresh_dir () in
  let outcome = run_and_stop env ~runtime ~dir ~cut:In_provider_call Host_stop in
  check_closed_cancelled "no host_stop" outcome ~runtime ~dir
;;

let () =
  run
    "agent_host_stop"
    [ ( "left open"
      , [ test_case "stop in a provider call" `Quick
            test_stop_in_provider_call_leaves_the_run_open
        ; test_case "stop in a Tool handler" `Quick
            test_stop_in_tool_handler_leaves_the_attempt_open
        ; test_case "wrapped stops" `Quick test_wrapped_stops_leave_the_run_open
        ] )
    ; ( "closed"
      , [ test_case "stop mixed with another reason" `Quick
            test_stop_mixed_with_another_reason_closes
        ; test_case "another reason" `Quick test_other_reason_closes
        ; test_case "without host_stop" `Quick test_without_host_stop_closes
        ] )
    ]
;;

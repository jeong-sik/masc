(** Integration tests for Event_bus run/handoff lifecycle variants:
    AgentStarted, AgentCompleted, AgentFailed, HandoffRequested, and
    HandoffCompleted.

    These verify that [lib/agent/agent.ml] ([run], [run_with_handoffs])
    publishes the surface end-to-end — not just that the variants
    typecheck. *)

open Alcotest
open Agent_sdk

let event_kind (event : Event_bus.event) = Event_bus.payload_kind event.payload

let local_provider_config ~base_url ~model_id =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"test"
    ~model_id
    ~base_url
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path:"/v1/chat/completions"
    ()
;;

(* ── A. run_with_handoffs emits Handoff{Requested,Completed} ──── *)

(* Reuse the same mock wire format as test_handoff: OpenAI-compatible
   chat.completions that responds with the exact target tool on the
   first request and a plain text response on the second. *)

let response_for_message body_str =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body_str in
  let messages = json |> member "messages" |> to_list in
  let last_msg = List.hd (List.rev messages) in
  let role = last_msg |> member "role" |> to_string_option |> Option.value ~default:"" in
  match role with
  | "tool" ->
    Printf.sprintf
      {|{"id":"chatcmpl-final","object":"chat.completion","model":"c","choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
  | _ ->
    let text =
      last_msg |> member "content" |> to_string_option |> Option.value ~default:""
    in
    if text = "delegate"
    then
      {|{"id":"chatcmpl-handoff","object":"chat.completion","model":"c","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"h-1","type":"function","function":{"name":"researcher","arguments":"{\"prompt\":\"sub\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    else
      {|{"id":"chatcmpl-sub","object":"chat.completion","model":"c","choices":[{"index":0,"message":{"role":"assistant","content":"sub ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}|}
;;

let mock_handler _conn req body =
  match Uri.path (Cohttp.Request.uri req) with
  | "/v1/chat/completions" ->
    let body_str = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:(response_for_message body_str) ()
  | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"nf" ()
;;

let fresh_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "not inet"
  in
  Unix.close s;
  port
;;

let skip_if_bisect label =
  match Sys.getenv_opt "BISECT_ENABLE" with
  | Some ("1" | "yes" | "true") ->
    Printf.printf "  [SKIP] %s under bisect coverage run\n%!" label;
    Alcotest.skip ()
  | _ -> ()
;;

let test_handoff_emits_request_and_completion () =
  skip_if_bisect "run_with_handoffs emits Requested+Completed";
  let port = fresh_port () in
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:mock_handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let bus = Event_bus.create () in
    let config =
      Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest
      |> Result.get_ok
    in
    let sub = Event_bus.subscribe ~config bus in
    let target =
      let parent_config = Types.default_config ~model:"test-model" in
      { Handoff.name = "researcher"
      ; description = "Research specialist"
      ; config =
          { parent_config with name = "researcher"; system_prompt = Some "Research." }
      ; tools = []
      }
    in
    let provider_config = local_provider_config ~base_url ~model_id:"mock" in
    let options =
      { Agent.default_options with
        provider_config = Some provider_config
      ; event_bus = Some bus
      }
    in
    let agent =
      Agent.create
        ~config:(Types.default_config ~model:"test-model")
        ~net:env#net
        ~options
        ()
    in
    let _ = Agent.run_with_handoffs ~sw agent ~targets:[ target ] "delegate" in
    let events = Event_bus.drain sub in
    let names = List.map event_kind events in
    check bool "handoff requested emitted" true (List.mem "handoff_requested" names);
    check bool "handoff completed emitted" true (List.mem "handoff_completed" names);
    (* Requested must precede Completed. *)
    let req_idx =
      List.find_index (( = ) "handoff_requested") names |> Option.value ~default:(-1)
    in
    let done_idx =
      List.find_index (( = ) "handoff_completed") names |> Option.value ~default:(-1)
    in
    check bool "requested before completed" true (req_idx < done_idx);
    (* Payload checks: from_agent/to_agent flow direction. *)
    let reqs = List.filter (fun e -> event_kind e = "handoff_requested") events in
    (match (List.hd reqs).payload with
     | Event_bus.HandoffRequested { from_agent = _; to_agent; reason } ->
       check string "to_agent" "researcher" to_agent;
       (* [reason] carries the sub-agent prompt passed to the target tool,
          not the parent prompt. *)
       check string "reason carries sub-prompt" "sub" reason
     | _ -> fail "expected HandoffRequested payload");
    (* Causation chain (#877): HandoffCompleted.caused_by must point
       at the HandoffRequested envelope that opened the handoff.
       HandoffRequested itself is the chain root. *)
    let requested =
      try List.find (fun e -> event_kind e = "handoff_requested") events with
      | Not_found -> fail "HandoffRequested missing"
    in
    let completed =
      try List.find (fun e -> event_kind e = "handoff_completed") events with
      | Not_found -> fail "HandoffCompleted missing"
    in
    check
      (option string)
      "HandoffRequested.caused_by is None (root)"
      None
      requested.meta.caused_by;
    check
      (option string)
      "HandoffCompleted.caused_by points at requested.run_id"
      (Some requested.meta.run_id)
      completed.meta.caused_by;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── B. Agent.run emits AgentStarted/AgentCompleted/AgentFailed ── *)
(* ── B. Agent.run emits AgentStarted/AgentCompleted/AgentFailed ── *)

(* Run-level lifecycle triple restored in [Agent.run]: the legacy
   orchestrator producer was removed in #1755, leaving the variants
   without any producer.  [publish_agent_started]/[publish_agent_finished]
   in [lib/agent/agent.ml] now emit the triple around every run. *)

let with_mock_server ~handler f =
  let port = fresh_port () in
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    f ~sw env base_url;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let find_kind kind events =
  try List.find (fun e -> event_kind e = kind) events with
  | Not_found -> fail (Printf.sprintf "%s missing" kind)
;;

let index_of_kind kind names =
  List.find_index (( = ) kind) names |> Option.value ~default:(-1)
;;

let run_agent_once ~sw env ~base_url bus =
  let provider_config = local_provider_config ~base_url ~model_id:"mock" in
  let options =
    { Agent.default_options with
      provider_config = Some provider_config
    ; event_bus = Some bus
    }
  in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~net:env#net
      ~options
      ()
  in
  let result = Agent.run ~sw agent "hello" in
  agent, result
;;

let test_run_emits_started_and_completed () =
  skip_if_bisect "Agent.run emits Started+Completed";
  with_mock_server ~handler:mock_handler (fun ~sw env base_url ->
    let bus = Event_bus.create () in
    let config =
      Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest
      |> Result.get_ok
    in
    let sub = Event_bus.subscribe ~config bus in
    let agent, result = run_agent_once ~sw env ~base_url bus in
    (match result with
     | Ok _ -> ()
     | Error error -> fail (Error.to_string error));
    let events = Event_bus.drain sub in
    let names = List.map event_kind events in
    check bool "agent_started emitted" true (List.mem "agent_started" names);
    check bool "agent_completed emitted" true (List.mem "agent_completed" names);
    check bool "agent_failed not emitted" false (List.mem "agent_failed" names);
    check
      bool
      "started before completed"
      true
      (index_of_kind "agent_started" names < index_of_kind "agent_completed" names);
    let started = find_kind "agent_started" events in
    let completed = find_kind "agent_completed" events in
    let agent_name = (Agent.state agent).config.name in
    (match started.payload with
     | Event_bus.AgentStarted r ->
       check string "started agent_name" agent_name r.agent_name;
       check string "started task_id is the started run_id" started.meta.run_id r.task_id
     | _ -> fail "expected AgentStarted payload");
    (match completed.payload with
     | Event_bus.AgentCompleted r ->
       check string "completed agent_name" agent_name r.agent_name;
       check string "completed task_id groups the triple" started.meta.run_id r.task_id;
       check bool "completed carries Ok result" true (Result.is_ok r.result);
       check bool "completed elapsed non-negative" true (r.elapsed >= 0.)
     | _ -> fail "expected AgentCompleted payload");
    check
      string
      "shared correlation_id"
      started.meta.correlation_id
      completed.meta.correlation_id;
    check
      (option string)
      "completed caused_by points at started.run_id"
      (Some started.meta.run_id)
      completed.meta.caused_by)
;;

(* HTTP 400 classifies as non-retryable [InvalidRequest], so the run fails
   immediately without retry backoff. *)
let failing_mock_handler _conn _req _body =
  Cohttp_eio.Server.respond_string
    ~status:`Bad_request
    ~body:
      {|{"error":{"message":"mock run failure","type":"invalid_request_error","code":400}}|}
    ()
;;

let test_run_emits_failed_companion_on_error () =
  skip_if_bisect "Agent.run emits Failed companion on error";
  with_mock_server ~handler:failing_mock_handler (fun ~sw env base_url ->
    let bus = Event_bus.create () in
    let config =
      Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest
      |> Result.get_ok
    in
    let sub = Event_bus.subscribe ~config bus in
    let agent, result = run_agent_once ~sw env ~base_url bus in
    (match result with
     | Ok _ -> fail "expected run failure"
     | Error _ -> ());
    let events = Event_bus.drain sub in
    let names = List.map event_kind events in
    check bool "agent_started emitted" true (List.mem "agent_started" names);
    check bool "agent_completed emitted" true (List.mem "agent_completed" names);
    check bool "agent_failed emitted" true (List.mem "agent_failed" names);
    check
      bool
      "started before failed"
      true
      (index_of_kind "agent_started" names < index_of_kind "agent_failed" names);
    let started = find_kind "agent_started" events in
    let completed = find_kind "agent_completed" events in
    let failed = find_kind "agent_failed" events in
    let agent_name = (Agent.state agent).config.name in
    (match completed.payload with
     | Event_bus.AgentCompleted r ->
       check bool "completed carries Error result" true (Result.is_error r.result)
     | _ -> fail "expected AgentCompleted payload");
    (match failed.payload with
     | Event_bus.AgentFailed r ->
       check string "failed agent_name" agent_name r.agent_name;
       check string "failed task_id groups the triple" started.meta.run_id r.task_id;
       check
         bool
         "failed error non-empty"
         true
         (String.length (Error.to_string r.error) > 0);
       check bool "failed elapsed non-negative" true (r.elapsed >= 0.)
     | _ -> fail "expected AgentFailed payload");
    check
      (option string)
      "completed caused_by points at started.run_id"
      (Some started.meta.run_id)
      completed.meta.caused_by;
    check
      (option string)
      "failed caused_by points at started.run_id"
      (Some started.meta.run_id)
      failed.meta.caused_by)
;;

(* ── C. with_run_lifecycle_events closes Started on synchronous exn ── *)

(* F5 regression: when the run switch is cancelled mid-flight, [Agent.run]
   observes [Eio.Cancel.Cancelled] from the inner pipeline.  Before the
   exception-arm fix in [lib/agent/agent_lifecycle_events.ml], that path
   skipped [publish_finished], leaving a dangling [AgentStarted] with no
   [AgentCompleted]/[AgentFailed].  The wrapper now mirrors the
   [Agent_trace] exception-arm contract: publish a terminal event, then
   re-raise. *)

let slow_handler _conn _req _body =
  (* Hold the connection so the agent is mid HTTP read when the sub-switch
     is cancelled below.  Cancellation raises [Eio.Cancel.Cancelled]
     inside the in-flight read. *)
  Unix.sleepf 30.0 |> ignore;
  Cohttp_eio.Server.respond_string ~status:`OK ~body:"never" ()
;;

let test_run_emits_terminal_on_switch_cancel () =
  skip_if_bisect "Agent.run emits terminal on switch cancel";
  with_mock_server ~handler:slow_handler (fun ~sw env base_url ->
    let bus = Event_bus.create () in
    let config =
      Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
      |> Result.get_ok
    in
    let sub = Event_bus.subscribe ~config bus in
    let provider_config = local_provider_config ~base_url ~model_id:"mock" in
    let options =
      { Agent.default_options with
        provider_config = Some provider_config
      ; event_bus = Some bus
      }
    in
    let agent =
      Agent.create
        ~config:(Types.default_config ~model:"test-model")
        ~net:env#net
        ~options
        ()
    in
    (* Run the agent in its own sub-switch so we can cancel it without
       tearing down the outer mock-server switch. *)
    (try
       Eio.Switch.run
       @@ fun agent_sw ->
       let (_ : unit) =
         Eio.Fiber.fork ~sw:agent_sw (fun () ->
           let _ = Agent.run ~sw:agent_sw agent "hello" in
           ())
       in
       (* Yield once so the forked fiber can enter [Agent.run] and
          publish [AgentStarted].  The slow handler keeps the forked
          fiber in an in-flight HTTP read when we cancel. *)
       Eio.Fiber.yield ();
       Eio.Switch.fail agent_sw Exit
     with
     | Exit -> ());
    (* Sub-switch has been torn down.  The outer switch is still live,
       so [Event_bus.drain] (which uses [Eio.Mutex]) works.  Whatever
       events were published before the cancellation re-raise must be
       available on the bus. *)
    let events = Event_bus.drain sub in
    let names = List.map event_kind events in
    check bool "agent_started emitted" true (List.mem "agent_started" names);
    check
      bool
      "terminal event emitted (completed or failed)"
      true
      (List.mem "agent_completed" names || List.mem "agent_failed" names);
    Eio.Switch.fail sw Exit)
;;

(* ── Entry point ─────────────────────────────────────────────────── *)

let () =
  if Sys.getenv_opt "ANTHROPIC_API_KEY" = None
  then Unix.putenv "ANTHROPIC_API_KEY" "test-mock-key";
  run
    "Event_integration"
    [ ( "handoff_lifecycle"
      , [ test_case
            "run_with_handoffs emits Requested+Completed"
            `Quick
            test_handoff_emits_request_and_completion
        ] )
    ; ( "run_lifecycle"
      , [ test_case
            "Agent.run emits Started+Completed"
            `Quick
            test_run_emits_started_and_completed
        ; test_case
            "Agent.run emits Failed companion on error"
            `Quick
            test_run_emits_failed_companion_on_error
        ; test_case
            "Agent.run emits terminal on switch cancel"
            `Quick
            test_run_emits_terminal_on_switch_cancel
        ] )
    ]
;;

(** Tests for Event_bus — typed publish/subscribe for agent lifecycle events. *)

open Alcotest
open Agent_sdk

(* ── Helpers ──────────────────────────────────────────────────────── *)

let string_contains ~needle haystack =
  try
    let _ = Str.search_forward (Str.regexp_string needle) haystack 0 in
    true
  with
  | Not_found -> false
;;

let mock_response text =
  { Types.id = "r-1"
  ; model = "mock"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text text ]
  ; usage = None
  ; telemetry = None
  }
;;

(** Shorthand: wrap a payload into an event with a fresh envelope. *)
let ev payload = Event_bus.mk_event payload

let invocation ?(tool_use_id = "tu-test") ?(turn = 0) ?(planned_index = 0) () =
  let schedule : Tool_contract.schedule =
    { planned_index
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  Tool_contract.Invocation.create
    ~tool_use_id
    ~turn
    ~schedule
    ~completion:Tool_contract.Continue_after_success
;;

let subscription_config_exn ~capacity ~overflow =
  match Event_bus.subscription_config ~capacity ~overflow with
  | Ok config -> config
  | Error (Event_bus.Non_positive_capacity rejected) ->
    failf "test supplied non-positive subscription capacity: %d" rejected
;;

(* These tests exercise routing rather than capacity pressure. The fixture
   capacity is deliberately larger than every event batch in this file; the
   overflow tests below use their own exact capacities. *)
let routing_subscription =
  subscription_config_exn ~capacity:64 ~overflow:Event_bus.Drop_newest
;;

let subscribe_routing ?filter ?purpose bus =
  Event_bus.subscribe ~config:routing_subscription ?filter ?purpose bus
;;

let require_tool_execution = function
  | Ok result -> result
  | Error (Agent_tools.Hook_execution_failed failure) ->
    failf
      "unexpected hook failure %s at %s: %s"
      failure.hook_name
      (Hooks.hook_stage_to_string failure.stage)
      failure.detail
;;

(* ── create ───────────────────────────────────────────────────────── *)

let test_create_default () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  check int "no subscribers" 0 (Event_bus.subscriber_count bus)
;;

let test_subscription_config_accepts_positive_capacity () =
  match Event_bus.subscription_config ~capacity:8 ~overflow:Event_bus.Drop_oldest with
  | Ok _ -> ()
  | Error _ -> fail "positive capacity was rejected"
;;

let test_subscription_config_rejects_non_positive_capacity () =
  let rejected capacity =
    match Event_bus.subscription_config ~capacity ~overflow:Event_bus.Drop_oldest with
    | Error (Event_bus.Non_positive_capacity actual) -> actual
    | Ok _ -> failf "capacity %d was accepted" capacity
  in
  check int "zero capacity" 0 (rejected 0);
  check int "negative capacity" (-1) (rejected (-1))
;;

(* ── subscribe / unsubscribe ──────────────────────────────────────── *)

let test_subscribe_count () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let _sub = subscribe_routing bus in
  check int "one subscriber" 1 (Event_bus.subscriber_count bus)
;;

let test_unsubscribe_count () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.unsubscribe bus sub;
  check int "zero after unsub" 0 (Event_bus.subscriber_count bus)
;;

let test_unsubscribe_and_drain_preserves_pending_fifo () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 2 }));
  let pending = Event_bus.unsubscribe_and_drain bus sub in
  check int "subscriber removed" 0 (Event_bus.subscriber_count bus);
  (match List.map (fun (event : Event_bus.event) -> event.payload) pending with
   | [ TurnStarted first; TurnStarted second ] ->
     check int "first pending turn" 1 first.turn;
     check int "second pending turn" 2 second.turn
   | _ -> fail "expected both pending events in FIFO order");
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 3 }));
  check
    int
    "cancelled subscription accepts no later event"
    0
    (List.length (Event_bus.drain sub))
;;

(* ── publish / drain ──────────────────────────────────────────────── *)

let test_publish_received () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  let events = Event_bus.drain sub in
  check int "one event" 1 (List.length events)
;;

let test_publish_multiple_subscribers () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub1 = subscribe_routing bus in
  let sub2 = subscribe_routing bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  let e1 = Event_bus.drain sub1 in
  let e2 = Event_bus.drain sub2 in
  check int "sub1 got event" 1 (List.length e1);
  check int "sub2 got event" 1 (List.length e2)
;;

let test_unsubscribed_no_receive () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.unsubscribe bus sub;
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  let events = Event_bus.drain sub in
  check int "no events after unsub" 0 (List.length events)
;;

let test_publish_no_subscribers_is_noop () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  check int "count stays zero" 0 (Event_bus.subscriber_count bus)
;;

let test_unsubscribe_idempotent_count () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.unsubscribe bus sub;
  Event_bus.unsubscribe bus sub;
  check int "count not negative" 0 (Event_bus.subscriber_count bus)
;;

let test_accept_all_subscriber_gets_all_events () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let all_sub = subscribe_routing bus in
  let tool_sub = subscribe_routing ~filter:Event_bus.filter_tools_only bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (ev
       (ToolCalled
          { invocation = invocation ~tool_use_id:"1" ()
          ; agent_name = "a"
          ; tool_name = "t"
          ; input = `Null
          }));
  let all_events = Event_bus.drain all_sub in
  let tool_events = Event_bus.drain tool_sub in
  check int "accept_all gets both events" 2 (List.length all_events);
  check int "tools_only gets one event" 1 (List.length tool_events)
;;

(* ── drain ────────────────────────────────────────────────────────── *)

let test_drain_fifo () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 2 }));
  let events = Event_bus.drain sub in
  check int "three events" 3 (List.length events);
  (* Verify FIFO order *)
  match List.map (fun (e : Event_bus.event) -> e.payload) events with
  | [ TurnStarted r0; TurnStarted r1; TurnStarted r2 ] ->
    check int "first turn" 0 r0.turn;
    check int "second turn" 1 r1.turn;
    check int "third turn" 2 r2.turn
  | _ -> fail "unexpected event types"
;;

let test_drain_empty () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  let events = Event_bus.drain sub in
  check int "no events" 0 (List.length events)
;;

(* ── filters ──────────────────────────────────────────────────────── *)

let test_filter_agent_name () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:(Event_bus.filter_agent "alpha") bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "alpha"; turn = 0 }));
  Event_bus.publish bus (ev (TurnStarted { agent_name = "beta"; turn = 0 }));
  Event_bus.publish bus (ev (TurnCompleted { agent_name = "alpha"; turn = 0 }));
  let events = Event_bus.drain sub in
  check int "only alpha events" 2 (List.length events)
;;

let test_filter_tools_only () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:Event_bus.filter_tools_only bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (ev
       (ToolCalled
          { invocation = invocation ()
          ; agent_name = "a"
          ; tool_name = "calc"
          ; input = `Null
          }));
  Event_bus.publish
    bus
    (ev
       (ToolCompleted
          { invocation = invocation ()
          ; agent_name = "a"
          ; tool_name = "calc"
          ; output = Ok { Types.content = "42"; _meta = None }
          }));
  Event_bus.publish bus (ev (TurnCompleted { agent_name = "a"; turn = 0 }));
  let events = Event_bus.drain sub in
  check int "only tool events" 2 (List.length events)
;;

let test_filter_agent_passes_custom () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:(Event_bus.filter_agent "alpha") bus in
  Event_bus.publish bus (ev (Custom ("my_event", `Null)));
  let events = Event_bus.drain sub in
  check int "custom passes through agent filter" 1 (List.length events)
;;

let test_accept_all () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:Event_bus.accept_all bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (ev
       (ToolCalled
          { invocation = invocation (); agent_name = "a"; tool_name = "x"; input = `Null }));
  Event_bus.publish bus (ev (Custom ("test", `Null)));
  let events = Event_bus.drain sub in
  check int "all three events" 3 (List.length events)
;;

(* ── event types ──────────────────────────────────────────────────── *)

let test_custom_event () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  let payload = `Assoc [ "key", `String "value" ] in
  Event_bus.publish bus (ev (Custom ("my_event", payload)));
  let events = Event_bus.drain sub in
  check int "one event" 1 (List.length events);
  match (List.hd events).payload with
  | Custom (name, _) -> check string "event name" "my_event" name
  | _ -> fail "expected Custom event"
;;

(* ── payload_kind ─────────────────────────────────────────────────── *)

let test_payload_kind_canonical_labels () =
  let cases : (Event_bus.payload * string) list =
    [ Event_bus.AgentStarted { agent_name = "a"; task_id = "t" }, "agent_started"
    ; Event_bus.TurnStarted { agent_name = "a"; turn = 0 }, "turn_started"
    ; Event_bus.TurnReady { agent_name = "a"; turn = 0; tool_names = [] }, "turn_ready"
    ; Event_bus.TurnCompleted { agent_name = "a"; turn = 0 }, "turn_completed"
    ; ( Event_bus.ToolCalled
          { invocation = invocation (); agent_name = "a"; tool_name = "f"; input = `Null }
      , "tool_called" )
    ; ( Event_bus.HandoffRequested { from_agent = "a"; to_agent = "b"; reason = "" }
      , "handoff_requested" )
    ; ( Event_bus.HandoffCompleted { from_agent = "a"; to_agent = "b"; elapsed = 0.0 }
      , "handoff_completed" )
    ; ( Event_bus.Custom ("downstream.agent.lifecycle", `Null)
      , "custom:downstream.agent.lifecycle" )
    ]
  in
  List.iter
    (fun (payload, expected) ->
       check string expected expected (Event_bus.payload_kind payload))
    cases
;;

(* Stable-API guard: the snake_case label set is documented as part of
   OAS's public surface.  Subscribers may persist these strings, so an
   accidental rename (e.g. "agent_started" → "agentStarted") would be a
   silent breaking change for consumers reading historical event logs.
   This test pins the exact characters so any rename trips a code
   review. *)
let test_payload_kind_label_set_is_stable () =
  let label_cases : (Event_bus.payload * string) list =
    [ Event_bus.AgentStarted { agent_name = ""; task_id = "" }, "agent_started"
    ; ( Event_bus.AgentFailed
          { agent_name = ""
          ; task_id = ""
          ; error = Error.Agent (Error.UnrecognizedStopReason { reason = "test" })
          ; elapsed = 0.0
          }
      , "agent_failed" )
    ; ( Event_bus.InferenceTelemetry
          { agent_name = ""
          ; turn = 0
          ; provider = ""
          ; model = ""
          ; prompt_tokens = None
          ; completion_tokens = None
          ; prompt_ms = None
          ; decode_ms = None
          ; decode_tok_s = None
          }
      , "inference_telemetry" )
    ]
  in
  List.iter
    (fun (p, expected) -> check string expected expected (Event_bus.payload_kind p))
    label_cases
;;

let test_multiple_event_types () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (AgentStarted { agent_name = "a"; task_id = "t1" }));
  Event_bus.publish bus (ev (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (ev
       (ToolCalled
          { invocation = invocation (); agent_name = "a"; tool_name = "f"; input = `Null }));
  Event_bus.publish
    bus
    (ev
       (ToolCompleted
          { invocation = invocation ()
          ; agent_name = "a"
          ; tool_name = "f"
          ; output = Ok { Types.content = "ok"; _meta = None }
          }));
  Event_bus.publish bus (ev (TurnCompleted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (ev
       (AgentCompleted
          { agent_name = "a"
          ; task_id = "t1"
          ; result = Ok (mock_response "done")
          ; elapsed = 0.1
          }));
  let events = Event_bus.drain sub in
  check int "six events" 6 (List.length events)
;;

(* ── field access ─────────────────────────────────────────────────── *)

let test_agent_started_fields () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (AgentStarted { agent_name = "worker"; task_id = "t-42" }));
  match Event_bus.drain sub with
  | [ { payload = AgentStarted r; _ } ] ->
    check string "agent_name" "worker" r.agent_name;
    check string "task_id" "t-42" r.task_id
  | _ -> fail "expected AgentStarted"
;;

let test_tool_called_fields () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  let input = `Assoc [ "x", `Int 1 ] in
  Event_bus.publish
    bus
    (ev
       (ToolCalled
          { invocation = invocation (); agent_name = "a"; tool_name = "calc"; input }));
  match Event_bus.drain sub with
  | [ { payload = ToolCalled r; _ } ] ->
    check string "agent_name" "a" r.agent_name;
    check string "tool_name" "calc" r.tool_name;
    check string "input json" {|{"x":1}|} (Yojson.Safe.to_string r.input);
    check int "turn" 0 (Tool_contract.Invocation.turn r.invocation)
  | _ -> fail "expected ToolCalled"
;;

let test_turn_started_fields () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (TurnStarted { agent_name = "bot"; turn = 5 }));
  match Event_bus.drain sub with
  | [ { payload = TurnStarted r; _ } ] ->
    check string "agent_name" "bot" r.agent_name;
    check int "turn" 5 r.turn
  | _ -> fail "expected TurnStarted"
;;

let test_tool_completed_preserves_non_retryable_flag () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:Event_bus.filter_tools_only bus in
  let tool =
    Tool.create ~name:"fail" ~description:"Always fails" ~parameters:[] (fun _ ->
      Error { Types.message = "boom"; recoverable = false; error_class = None })
  in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let _result =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[ tool ]
      ~hooks:Hooks.empty
      ~event_bus:(Some bus)
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~correlation_id:"sess-event"
      ~run_id:"run-event"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-1"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "fail"
      (`Assoc [])
    |> require_tool_execution
  in
  match Event_bus.drain sub with
  | [ { meta = called_meta; payload = ToolCalled _; _ }
    ; { meta = completed_meta
      ; payload = ToolCompleted { output = Error { message; recoverable; _ }; _ }
      ; _
      }
    ] ->
    check string "message" "boom" message;
    check bool "non-retryable preserved" false recoverable;
    check string "tool_called correlation_id" "sess-event" called_meta.correlation_id;
    check string "tool_called run_id" "run-event" called_meta.run_id;
    check
      string
      "tool_completed correlation_id"
      "sess-event"
      completed_meta.correlation_id;
    check string "tool_completed run_id" "run-event" completed_meta.run_id;
    (* Causation chain (#877): ToolCalled is the chain root for this
         tool invocation; ToolCompleted.caused_by must point at
         called_meta.run_id. *)
    check
      (option string)
      "tool_called.caused_by is None (root)"
      None
      called_meta.caused_by;
    check
      (option string)
      "tool_completed.caused_by points at called.run_id"
      (Some called_meta.run_id)
      completed_meta.caused_by
  | _ -> fail "expected tool called/completed events"
;;

(* ── Hooks.OnToolError emit on tool failure (#1029) ─────── *)

let test_on_tool_error_hook_fires_on_tool_failure () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let bus = Event_bus.create () in
  let tool =
    Tool.create ~name:"fail" ~description:"Always fails" ~parameters:[] (fun _ ->
      Error { Types.message = "boom"; recoverable = false; error_class = None })
  in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let fired = ref [] in
  let on_tool_error =
    Some
      (fun event ->
        (match event with
         | Hooks.OnToolError { tool_name; error; invocation = _ } ->
           fired := (tool_name, error) :: !fired
         | _ -> ());
        Hooks.Continue)
  in
  let hooks = { Hooks.empty with on_tool_error } in
  let _result =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[ tool ]
      ~hooks
      ~event_bus:(Some bus)
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~correlation_id:"c"
      ~run_id:"r"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-1"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "fail"
      (`Assoc [])
    |> require_tool_execution
  in
  match List.rev !fired with
  | [ (tool_name, error) ] ->
    check string "hook fired for failing tool" "fail" tool_name;
    check string "hook error carries tool message" "boom" error
  | [] -> fail "on_tool_error hook not fired"
  | _ -> fail "on_tool_error fired more than once"
;;

let test_on_tool_error_hook_silent_on_success () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let bus = Event_bus.create () in
  let tool =
    Tool.create ~name:"ok" ~description:"" ~parameters:[] (fun _ ->
      Ok { Types.content = "done"; _meta = None })
  in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let fired = ref 0 in
  let on_tool_error =
    Some
      (fun _event ->
        incr fired;
        Hooks.Continue)
  in
  let hooks = { Hooks.empty with on_tool_error } in
  let _ =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[ tool ]
      ~hooks
      ~event_bus:(Some bus)
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~correlation_id:"c"
      ~run_id:"r"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-2"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "ok"
      (`Assoc [])
    |> require_tool_execution
  in
  check int "hook not fired on Ok result" 0 !fired
;;

(* ── Hooks.OnError emit on tool-not-found (#1032) ──────── *)

let test_on_error_fires_on_tool_not_found () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let bus = Event_bus.create () in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let fired = ref [] in
  let on_error =
    Some
      (fun event ->
        (match event with
         | Hooks.OnError { detail; context; invocation } ->
           fired := (detail, context, invocation) :: !fired
         | _ -> ());
        Hooks.Continue)
  in
  let hooks = { Hooks.empty with on_error } in
  (* No tools registered -> dispatch falls to the None branch. *)
  let _result =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[]
      ~hooks
      ~event_bus:(Some bus)
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~correlation_id:"c"
      ~run_id:"r"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-1"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "ghost_tool"
      (`Assoc [])
    |> require_tool_execution
  in
  match List.rev !fired with
  | [ (detail, ctx, Some error_invocation) ] ->
    check
      bool
      "detail mentions tool name"
      true
      (String.length detail > 0
       && String.length detail >= String.length "ghost_tool"
       &&
       try
         let _ = Str.search_forward (Str.regexp_string "ghost_tool") detail 0 in
         true
       with
       | Not_found -> false);
    check string "context labels dispatch site" "agent_tools.find_and_execute_tool" ctx;
    check
      string
      "error retains exact tool occurrence"
      "tool-1"
      (Tool_contract.Invocation.tool_use_id error_invocation)
  | [ (_, _, None) ] -> fail "tool-attributed on_error lost its invocation"
  | [] -> fail "on_error hook not fired"
  | _ -> fail "on_error fired more than once"
;;

let test_unknown_tool_reports_available_tools_and_retries () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let bus = Event_bus.create () in
  let read_file =
    Tool.create ~name:"ReadFile" ~description:"Read a file" ~parameters:[] (fun _ ->
      Ok { Types.content = "unused"; _meta = None })
  in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let fired = ref [] in
  let on_error =
    Some
      (fun event ->
        (match event with
         | Hooks.OnError { detail; context; invocation = _ } ->
           fired := (detail, context) :: !fired
         | _ -> ());
        Hooks.Continue)
  in
  let hooks = { Hooks.empty with on_error } in
  let result =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[ read_file ]
      ~hooks
      ~event_bus:(Some bus)
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~correlation_id:"c"
      ~run_id:"r"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-unknown"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "MissingRead"
      (`Assoc [])
    |> require_tool_execution
  in
  check
    bool
    "unknown call is an error"
    true
    (Types.tool_result_outcome_is_error result.outcome);
  check
    (option string)
    "unknown call is retryable validation"
    (Some "validation")
    (match result.outcome with
     | Types.Tool_failed { failure_kind = Agent_tools.Validation_error; _ } ->
       Some "validation"
     | Types.Tool_failed { failure_kind = Agent_tools.Recoverable_tool_error; _ } ->
       Some "recoverable"
     | Types.Tool_failed { failure_kind = Agent_tools.Non_retryable_tool_error; _ } ->
       Some "non_retryable"
     | Types.Tool_failed { failure_kind = Agent_tools.Reported_tool_error; _ } ->
       Some "reported"
     | Types.Tool_failed { failure_kind = Agent_tools.Unattributed_tool_error; _ } ->
       Some "unattributed"
     | Types.Tool_succeeded -> None);
  check
    bool
    "content names missing tool"
    true
    (string_contains ~needle:"Tool not found: MissingRead" result.content);
  check
    bool
    "content includes available tools"
    true
    (string_contains ~needle:"Available tools: ReadFile" result.content);
  match List.rev !fired with
  | [ (detail, ctx) ] ->
    check
      bool
      "detail names missing tool"
      true
      (string_contains ~needle:"Tool not found: MissingRead" detail);
    check
      bool
      "detail includes available tools"
      true
      (string_contains ~needle:"Available tools: ReadFile" detail);
    check string "context labels dispatch site" "agent_tools.find_and_execute_tool" ctx
  | [] -> fail "on_error hook not fired"
  | _ -> fail "on_error fired more than once"
;;

let test_execution_rejects_invalid_input_unchanged () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let handler_input = ref `Null in
  let tool =
    Tool.create
      ~name:"Count"
      ~description:"Count"
      ~parameters:
        [ { Types.name = "count"
          ; description = "count"
          ; param_type = Integer
          ; required = true
          }
        ]
      (fun input ->
         handler_input := input;
         Ok { Types.content = "ok"; _meta = None })
  in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let result =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[ tool ]
      ~hooks:Hooks.empty
      ~event_bus:None
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-invalid-input"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "Count"
      (`Assoc [ "count", `String "42" ])
    |> require_tool_execution
  in
  check bool "handler not called" true (Yojson.Safe.equal `Null !handler_input);
  check
    bool
    "invalid input preserved"
    true
    (Yojson.Safe.equal result.input (`Assoc [ "count", `String "42" ]));
  match result.outcome with
  | Types.Tool_failed { failure_kind = Agent_tools.Validation_error; _ } -> ()
  | _ -> fail "expected validation failure"
;;

let test_on_error_silent_on_successful_dispatch () =
  Eio_main.run
  @@ fun _env ->
  let context = Context.create_sync () in
  let bus = Event_bus.create () in
  let tool =
    Tool.create ~name:"ok" ~description:"" ~parameters:[] (fun _ ->
      Ok { Types.content = "done"; _meta = None })
  in
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let fired = ref 0 in
  let on_error =
    Some
      (fun _ ->
        incr fired;
        Hooks.Continue)
  in
  let hooks = { Hooks.empty with on_error } in
  let _ =
    Agent_tools.find_and_execute_tool
      ~context
      ~tools:[ tool ]
      ~hooks
      ~event_bus:(Some bus)
      ~tracer:Tracing.null
      ~agent_name:"agent"
      ~correlation_id:"c"
      ~run_id:"r"
      ~invocation:
        (Tool_contract.Invocation.create
           ~tool_use_id:"tool-2"
           ~turn:0
           ~schedule
           ~completion:Tool_contract.Continue_after_success)
      "ok"
      (`Assoc [])
    |> require_tool_execution
  in
  check int "on_error not fired on success" 0 !fired
;;

let test_correlation_fields_roundtrip () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish
    bus
    (Event_bus.mk_event
       ~correlation_id:"sess-7"
       ~run_id:"run-7"
       (TurnStarted { agent_name = "corr"; turn = 7 }));
  match Event_bus.drain sub with
  | [ { meta; payload = TurnStarted _; _ } ] ->
    check string "correlation_id" "sess-7" meta.correlation_id;
    check string "run_id" "run-7" meta.run_id
  | _ -> fail "expected TurnStarted"
;;

(* ── envelope filters ─────────────────────────────────────────────── *)

let test_filter_correlation () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:(Event_bus.filter_correlation "c1") bus in
  Event_bus.publish
    bus
    (Event_bus.mk_event ~correlation_id:"c1" (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (Event_bus.mk_event ~correlation_id:"c2" (TurnStarted { agent_name = "a"; turn = 1 }));
  let events = Event_bus.drain sub in
  check int "only c1 events" 1 (List.length events)
;;

let test_filter_run () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing ~filter:(Event_bus.filter_run "r1") bus in
  Event_bus.publish
    bus
    (Event_bus.mk_event ~run_id:"r1" (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (Event_bus.mk_event ~run_id:"r2" (TurnStarted { agent_name = "a"; turn = 1 }));
  let events = Event_bus.drain sub in
  check int "only r1 events" 1 (List.length events)
;;

let test_fresh_id_unique () =
  let id1 = Event_bus.fresh_id () in
  let id2 = Event_bus.fresh_id () in
  check bool "ids differ" true (id1 <> id2)
;;

let test_mk_envelope_defaults () =
  let env = Event_bus.mk_envelope () in
  check bool "correlation_id non-empty" true (String.length env.correlation_id > 0);
  check bool "run_id non-empty" true (String.length env.run_id > 0);
  check bool "ts > 0" true (env.ts > 0.0);
  check (option string) "caused_by defaults to None" None env.caused_by
;;

let test_mk_envelope_explicit () =
  let env = Event_bus.mk_envelope ~correlation_id:"c" ~run_id:"r" () in
  check string "correlation_id" "c" env.correlation_id;
  check string "run_id" "r" env.run_id;
  check (option string) "caused_by omitted stays None" None env.caused_by
;;

let test_mk_envelope_with_caused_by () =
  let env = Event_bus.mk_envelope ~caused_by:"run-42" () in
  check (option string) "caused_by propagated" (Some "run-42") env.caused_by
;;

let test_mk_event_propagates_caused_by () =
  let ev =
    Event_bus.mk_event
      ~correlation_id:"s"
      ~run_id:"r"
      ~caused_by:"parent-7"
      (Custom ("x", `Null))
  in
  check (option string) "event.meta.caused_by" (Some "parent-7") ev.meta.caused_by
;;

let test_publish_preserves_fifo_without_drain () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 2 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 3 }));
  let events = Event_bus.drain sub in
  let turns =
    List.filter_map
      (fun e ->
         match e.Event_bus.payload with
         | Event_bus.TurnStarted r -> Some r.turn
         | _ -> None)
      events
  in
  check (list int) "all events remain in FIFO order" [ 1; 2; 3 ] turns;
  let s = Event_bus.stats bus in
  match s.subscriptions with
  | [ ss ] ->
    check int "published_total=3" 3 ss.published_total;
    check int "drained_total=3" 3 ss.drained_total;
    check int "depth=0" 0 ss.depth
  | _ -> fail "one subscription"
;;

(* ── Per-subscriber overflow ─────────────────────────────────────── *)

let turns events =
  List.filter_map
    (fun event ->
       match event.Event_bus.payload with
       | Event_bus.TurnStarted r -> Some r.turn
       | _ -> None)
    events
;;

let test_drop_oldest_policy () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config = subscription_config_exn ~capacity:2 ~overflow:Event_bus.Drop_oldest in
  let sub = Event_bus.subscribe ~config bus in
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 2 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 3 }));
  check (list int) "oldest event was evicted" [ 2; 3 ] (turns (Event_bus.drain sub));
  match (Event_bus.stats bus).subscriptions with
  | [ stats ] ->
    check int "configured capacity" 2 stats.capacity;
    check bool "configured overflow" true (stats.overflow = Event_bus.Drop_oldest);
    check int "all matching events were offered" 3 stats.published_total;
    check int "one capacity drop is observed" 1 stats.dropped_total;
    check int "two retained events were drained" 2 stats.drained_total
  | _ -> fail "one subscription"
;;

let test_drop_newest_policy () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config = subscription_config_exn ~capacity:2 ~overflow:Event_bus.Drop_newest in
  let sub = Event_bus.subscribe ~config bus in
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 2 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 3 }));
  check (list int) "incoming event was discarded" [ 1; 2 ] (turns (Event_bus.drain sub));
  match (Event_bus.stats bus).subscriptions with
  | [ stats ] ->
    check int "configured capacity" 2 stats.capacity;
    check bool "configured overflow" true (stats.overflow = Event_bus.Drop_newest);
    check int "one capacity drop is observed" 1 stats.dropped_total
  | _ -> fail "one subscription"
;;

let test_slow_subscriber_does_not_stall_other_subscribers () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let slow_config = subscription_config_exn ~capacity:1 ~overflow:Event_bus.Drop_newest in
  let fast_config = subscription_config_exn ~capacity:3 ~overflow:Event_bus.Drop_oldest in
  let slow = Event_bus.subscribe ~config:slow_config ~purpose:"slow" bus in
  let fast = Event_bus.subscribe ~config:fast_config ~purpose:"fast" bus in
  List.iter
    (fun turn ->
       Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn })))
    [ 1; 2; 3 ];
  check
    (list int)
    "fast subscriber receives all events"
    [ 1; 2; 3 ]
    (turns (Event_bus.drain fast));
  check
    (list int)
    "slow subscriber retains its first event"
    [ 1 ]
    (turns (Event_bus.drain slow));
  let slow_stats =
    List.find
      (fun (stats : Event_bus.subscription_stats) -> stats.purpose = Some "slow")
      (Event_bus.stats bus).subscriptions
  in
  check int "slow subscriber observes its own drops" 2 slow_stats.dropped_total
;;

let test_unsubscribe_discards_full_queue_without_stalling_publish () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config = subscription_config_exn ~capacity:1 ~overflow:Event_bus.Drop_oldest in
  let sub = Event_bus.subscribe ~config bus in
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.unsubscribe bus sub;
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 2 }));
  check (list int) "unsubscribed queue is released" [] (turns (Event_bus.drain sub))
;;

(* ── Stats shape ──────────────────────────────────────────────────── *)

let test_stats_initial_shape () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let s = Event_bus.stats bus in
  check int "no subscribers" 0 s.subscriber_count;
  check int "empty subscriptions list" 0 (List.length s.subscriptions)
;;

let test_stats_tracks_counts () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = subscribe_routing bus in
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 1 }));
  Event_bus.publish bus (ev (Event_bus.TurnStarted { agent_name = "a"; turn = 2 }));
  let s1 = Event_bus.stats bus in
  (match s1.subscriptions with
   | [ ss ] ->
     check int "depth=2 before drain" 2 ss.depth;
     check int "published_total=2" 2 ss.published_total;
     check int "drained_total=0" 0 ss.drained_total
   | _ -> fail "one sub");
  let _ = Event_bus.drain sub in
  let s2 = Event_bus.stats bus in
  match s2.subscriptions with
  | [ ss ] ->
    check int "depth=0 after drain" 0 ss.depth;
    check int "drained_total=2" 2 ss.drained_total
  | _ -> fail "one sub"
;;

(* ── Purpose label ────────────────────────────────────────────────── *)

let test_subscribe_purpose_surfaces_in_stats () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let _s1 = subscribe_routing ~purpose:"sse_bridge" bus in
  let _s2 = subscribe_routing bus in
  let s = Event_bus.stats bus in
  let purposes =
    List.map (fun (ss : Event_bus.subscription_stats) -> ss.purpose) s.subscriptions
  in
  (* Subscribers are prepended, so newest first. *)
  check
    (list (option string))
    "purposes match insertion order"
    [ None; Some "sse_bridge" ]
    purposes
;;

let test_subscribe_without_purpose_defaults_none () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let _sub = subscribe_routing bus in
  let s = Event_bus.stats bus in
  match s.subscriptions with
  | [ ss ] -> check (option string) "purpose=None" None ss.purpose
  | _ -> fail "one sub"
;;

(* ── Suite ────────────────────────────────────────────────────────── *)

let () =
  run
    "Event_bus"
    [ ( "create"
      , [ test_case "default" `Quick test_create_default
        ; test_case
            "subscription config accepts positive capacity"
            `Quick
            test_subscription_config_accepts_positive_capacity
        ; test_case
            "subscription config rejects non-positive capacity"
            `Quick
            test_subscription_config_rejects_non_positive_capacity
        ] )
    ; ( "subscribe"
      , [ test_case "count" `Quick test_subscribe_count
        ; test_case "unsubscribe" `Quick test_unsubscribe_count
        ; test_case
            "unsubscribe and drain preserves pending FIFO"
            `Quick
            test_unsubscribe_and_drain_preserves_pending_fifo
        ] )
    ; ( "publish"
      , [ test_case "received" `Quick test_publish_received
        ; test_case "multiple subscribers" `Quick test_publish_multiple_subscribers
        ; test_case "unsubscribed no receive" `Quick test_unsubscribed_no_receive
        ; test_case "no subscribers is noop" `Quick test_publish_no_subscribers_is_noop
        ; test_case
            "unsubscribe idempotent count"
            `Quick
            test_unsubscribe_idempotent_count
        ; test_case
            "accept_all gets all events"
            `Quick
            test_accept_all_subscriber_gets_all_events
        ] )
    ; ( "drain"
      , [ test_case "fifo order" `Quick test_drain_fifo
        ; test_case "empty" `Quick test_drain_empty
        ] )
    ; ( "filters"
      , [ test_case "agent name" `Quick test_filter_agent_name
        ; test_case "agent filter passes custom" `Quick test_filter_agent_passes_custom
        ; test_case "tools only" `Quick test_filter_tools_only
        ; test_case "accept all" `Quick test_accept_all
        ] )
    ; ( "event_types"
      , [ test_case "custom" `Quick test_custom_event
        ; test_case "multiple types" `Quick test_multiple_event_types
        ] )
    ; ( "payload_kind"
      , [ test_case "canonical labels" `Quick test_payload_kind_canonical_labels
        ; test_case "label set is stable" `Quick test_payload_kind_label_set_is_stable
        ] )
    ; ( "fields"
      , [ test_case "agent_started" `Quick test_agent_started_fields
        ; test_case "tool_called" `Quick test_tool_called_fields
        ; test_case "turn_started" `Quick test_turn_started_fields
        ; test_case
            "tool_completed preserves non-retryable flag"
            `Quick
            test_tool_completed_preserves_non_retryable_flag
        ; test_case
            "correlation fields roundtrip"
            `Quick
            test_correlation_fields_roundtrip
        ; test_case
            "on_tool_error fires on tool failure"
            `Quick
            test_on_tool_error_hook_fires_on_tool_failure
        ; test_case
            "on_tool_error silent on success"
            `Quick
            test_on_tool_error_hook_silent_on_success
        ; test_case
            "on_error fires on tool-not-found"
            `Quick
            test_on_error_fires_on_tool_not_found
        ; test_case
            "unknown tool reports available tools and retries"
            `Quick
            test_unknown_tool_reports_available_tools_and_retries
        ; test_case
            "execution rejects invalid input unchanged"
            `Quick
            test_execution_rejects_invalid_input_unchanged
        ; test_case
            "on_error silent on successful dispatch"
            `Quick
            test_on_error_silent_on_successful_dispatch
        ] )
    ; ( "envelope"
      , [ test_case "filter_correlation" `Quick test_filter_correlation
        ; test_case "filter_run" `Quick test_filter_run
        ; test_case "fresh_id unique" `Quick test_fresh_id_unique
        ; test_case "mk_envelope defaults" `Quick test_mk_envelope_defaults
        ; test_case "mk_envelope explicit" `Quick test_mk_envelope_explicit
        ; test_case "mk_envelope with caused_by" `Quick test_mk_envelope_with_caused_by
        ; test_case
            "mk_event propagates caused_by"
            `Quick
            test_mk_event_propagates_caused_by
        ] )
    ; ( "purpose"
      , [ test_case
            "subscribe ~purpose surfaces in stats"
            `Quick
            test_subscribe_purpose_surfaces_in_stats
        ; test_case
            "subscribe without purpose defaults None"
            `Quick
            test_subscribe_without_purpose_defaults_none
        ] )
    ; ( "delivery"
      , [ test_case
            "preserves FIFO without subscriber drain"
            `Quick
            test_publish_preserves_fifo_without_drain
        ] )
    ; ( "overflow"
      , [ test_case "Drop_oldest evicts oldest" `Quick test_drop_oldest_policy
        ; test_case "Drop_newest discards incoming" `Quick test_drop_newest_policy
        ; test_case
            "slow subscriber does not stall others"
            `Quick
            test_slow_subscriber_does_not_stall_other_subscribers
        ; test_case
            "unsubscribe discards full queue without stalling publish"
            `Quick
            test_unsubscribe_discards_full_queue_without_stalling_publish
        ] )
    ; ( "stats"
      , [ test_case "initial shape" `Quick test_stats_initial_shape
        ; test_case "tracks publish/drain counts" `Quick test_stats_tracks_counts
        ] )
    ]
;;

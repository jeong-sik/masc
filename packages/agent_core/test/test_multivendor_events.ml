(** Multi-vendor Event_bus taxonomy invariants.

    Every provider OAS supports — Anthropic, Openai (+ compatibles),
    Gemini, Glm, Openrouter, llama.cpp, Ollama, vLLM, LM Studio, etc. —
    produces the same native Event_bus payload variants when running
    through OAS.  This test encodes the taxonomy invariants so any
    refactor that changes the public surface breaks the build here
    instead of silently diverging between providers.

    Invariants checked (see docs/EVENT-CATALOG.md Invariants I1-I6):

    - I1/I2: Envelope fields (correlation_id, run_id, ts) are present and
      preserved across every native variant.
    - Event_bus.payload_kind returns the canonical label for each native
      variant.
    - The golden lifecycle transcript (AgentStarted -> TurnStarted ->
      ToolCalled -> ToolCompleted -> TurnCompleted -> AgentCompleted)
      round-trips through the bus without reordering or loss.

    This test does NOT require an LLM; it verifies taxonomy invariants
    directly. A live-mode companion test (not yet authored) would drive
    an actual provider end-to-end and assert the same golden transcript
    emerges. *)

open Alcotest
open Agent_sdk

(* Canonical Types values used for payload construction *)
let stub_api_response : Types.api_response =
  { id = "msg_test"
  ; model = "any-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "done" ]
  ; usage = None
  ; telemetry = None
  }
;;

let stub_tool_result : Types.tool_result = Ok { Types.content = "ok"; _meta = None }

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

(* ── I1/I2: envelope preserved across variants ────────────────── *)

let test_envelope_preserved_across_variants () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:16 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config bus in
  let corr = "mv-corr" in
  let run_id = "mv-run" in
  let mk p = Event_bus.mk_event ~correlation_id:corr ~run_id p in
  let variants : Event_bus.payload list =
    [ AgentStarted { agent_name = "alpha"; task_id = "t1" }
    ; TurnStarted { agent_name = "alpha"; turn = 0 }
    ; ToolCalled
        { invocation = invocation ()
        ; agent_name = "alpha"
        ; tool_name = "echo"
        ; input = `Null
        }
    ; ToolCompleted
        { invocation = invocation ()
        ; agent_name = "alpha"
        ; tool_name = "echo"
        ; output = stub_tool_result
        }
    ; TurnCompleted { agent_name = "alpha"; turn = 0 }
    ; HandoffRequested { from_agent = "alpha"; to_agent = "beta"; reason = "delegate" }
    ; HandoffCompleted { from_agent = "alpha"; to_agent = "beta"; elapsed = 0.5 }
    ; ElicitationCompleted
        { agent_name = "alpha"; question = "?"; response = Hooks.Declined }
    ; ToolApprovalCompleted
        { agent_name = "alpha"
        ; invocation = invocation ()
        ; tool_name = "echo"
        ; approval = Hooks.Denied
        }
    ; AgentCompleted
        { agent_name = "alpha"
        ; task_id = "t1"
        ; result = Ok stub_api_response
        ; elapsed = 1.0
        }
    ; Custom ("example.namespace.ok", `Null)
    ]
  in
  List.iter (fun p -> Event_bus.publish bus (mk p)) variants;
  let received = Event_bus.drain sub in
  check int "count" (List.length variants) (List.length received);
  List.iter
    (fun (e : Event_bus.event) ->
       check string "correlation_id preserved" corr e.meta.correlation_id;
       check string "run_id preserved" run_id e.meta.run_id;
       check bool "ts populated" true (e.meta.ts > 0.0))
    received
;;

(* ── payload_kind mapping is stable ────────────────────────────── *)

let test_payload_kind_mapping () =
  let cases : (Event_bus.payload * string) list =
    [ AgentStarted { agent_name = "a"; task_id = "t" }, "agent_started"
    ; ( AgentCompleted
          { agent_name = "a"
          ; task_id = "t"
          ; result = Ok stub_api_response
          ; elapsed = 0.0
          }
      , "agent_completed" )
    ; ( AgentFailed
          { agent_name = "a"
          ; task_id = "t"
          ; error = Error.Config (Error.InvalidConfig { field = "f"; detail = "x" })
          ; elapsed = 0.0
          }
      , "agent_failed" )
    ; TurnStarted { agent_name = "a"; turn = 0 }, "turn_started"
    ; TurnCompleted { agent_name = "a"; turn = 0 }, "turn_completed"
    ; ( ToolCalled
          { invocation = invocation (); agent_name = "a"; tool_name = "t"; input = `Null }
      , "tool_called" )
    ; ( ToolCompleted
          { invocation = invocation ()
          ; agent_name = "a"
          ; tool_name = "t"
          ; output = stub_tool_result
          }
      , "tool_completed" )
    ; ( HandoffRequested { from_agent = "a"; to_agent = "b"; reason = "r" }
      , "handoff_requested" )
    ; ( HandoffCompleted { from_agent = "a"; to_agent = "b"; elapsed = 0.0 }
      , "handoff_completed" )
    ; ( ElicitationCompleted
          { agent_name = "a"; question = "?"; response = Hooks.Declined }
      , "elicitation_completed" )
    ; ( ToolApprovalCompleted
          { agent_name = "a"
          ; invocation = invocation ()
          ; tool_name = "t"
          ; approval = Hooks.Denied
          }
      , "tool_approval_completed" )
    ; Custom ("runtime.session_started", `Null), "custom:runtime.session_started"
    ; Custom ("durable.tool_called", `Null), "custom:durable.tool_called"
    ; ( Custom ("provider.anthropic.cache_hit", `Null)
      , "custom:provider.anthropic.cache_hit" )
    ; Custom ("myext.foo", `Null), "custom:myext.foo"
    ]
  in
  List.iter
    (fun (payload, expected) ->
       check
         string
         (Printf.sprintf "payload_kind for %s" expected)
         expected
         (Event_bus.payload_kind payload))
    cases
;;

(* ── Agent-scoped filter resolves correctly ───────────────────── *)

let test_filter_agent_covers_new_variants () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:8 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config ~filter:(Event_bus.filter_agent "alpha") bus in
  let mk p = Event_bus.mk_event p in
  (* HandoffRequested / HandoffCompleted are scoped by from_agent OR to_agent. *)
  Event_bus.publish
    bus
    (mk (HandoffRequested { from_agent = "alpha"; to_agent = "beta"; reason = "d" }));
  Event_bus.publish
    bus
    (mk (HandoffRequested { from_agent = "gamma"; to_agent = "alpha"; reason = "d" }));
  Event_bus.publish
    bus
    (mk (HandoffRequested { from_agent = "gamma"; to_agent = "delta"; reason = "d" }));
  Event_bus.publish
    bus
    (mk
       (AgentFailed
          { agent_name = "alpha"
          ; task_id = "t"
          ; error = Error.Config (Error.InvalidConfig { field = "f"; detail = "x" })
          ; elapsed = 0.0
          }));
  Event_bus.publish
    bus
    (mk
       (AgentFailed
          { agent_name = "beta"
          ; task_id = "t"
          ; error = Error.Config (Error.InvalidConfig { field = "f"; detail = "x" })
          ; elapsed = 0.0
          }));
  let received = Event_bus.drain sub in
  check int "alpha-scoped count" 3 (List.length received)
;;

(* ── Golden lifecycle transcript ───────────────────────────────── *)

let test_golden_lifecycle_transcript () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:8 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config bus in
  let corr = "golden" in
  let run_id = "g1" in
  let mk p = Event_bus.mk_event ~correlation_id:corr ~run_id p in
  (* Any provider that runs an agent with one tool call should produce
     exactly this sequence on Event_bus. *)
  Event_bus.publish bus (mk (AgentStarted { agent_name = "a"; task_id = "t" }));
  Event_bus.publish bus (mk (TurnStarted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (mk
       (ToolCalled
          { invocation = invocation ()
          ; agent_name = "a"
          ; tool_name = "echo"
          ; input = `Null
          }));
  Event_bus.publish
    bus
    (mk
       (ToolCompleted
          { invocation = invocation ()
          ; agent_name = "a"
          ; tool_name = "echo"
          ; output = stub_tool_result
          }));
  Event_bus.publish bus (mk (TurnCompleted { agent_name = "a"; turn = 0 }));
  Event_bus.publish
    bus
    (mk
       (AgentCompleted
          { agent_name = "a"
          ; task_id = "t"
          ; result = Ok stub_api_response
          ; elapsed = 0.1
          }));
  let names =
    Event_bus.drain sub
    |> List.map (fun (e : Event_bus.event) -> Event_bus.payload_kind e.payload)
  in
  check
    (list string)
    "golden transcript"
    [ "agent_started"
    ; "turn_started"
    ; "tool_called"
    ; "tool_completed"
    ; "turn_completed"
    ; "agent_completed"
    ]
    names
;;

(* ── Reserved Custom namespace grammar ────────────────────────── *)

let test_reserved_namespace_grammar () =
  (* runtime.*, durable.*, provider.*, oas.* are reserved per catalog.
     Any well-formed Custom name uses '.'-separated lowercase segments. *)
  let ok_names =
    [ "runtime.session_started"
    ; "durable.tool_called"
    ; "provider.anthropic.cache_hit"
    ; "provider.ollama.slot_busy"
    ; "oas.future"
    ; "myext.subsystem.event"
    ]
  in
  List.iter
    (fun name ->
       check
         string
         (Printf.sprintf "custom payload kind %s" name)
         ("custom:" ^ name)
         (Event_bus.payload_kind (Custom (name, `Null))))
    ok_names
;;

let () =
  run
    "Multivendor_events"
    [ ( "invariants"
      , [ test_case
            "envelope preserved across all variants"
            `Quick
            test_envelope_preserved_across_variants
        ; test_case "payload_kind mapping stable" `Quick test_payload_kind_mapping
        ; test_case
            "filter_agent scopes handoff + agent_failed"
            `Quick
            test_filter_agent_covers_new_variants
        ; test_case "golden lifecycle transcript" `Quick test_golden_lifecycle_transcript
        ; test_case "reserved namespace grammar" `Quick test_reserved_namespace_grammar
        ] )
    ]
;;

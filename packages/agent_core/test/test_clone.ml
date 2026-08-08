(** Tests for Agent.clone — independent agent duplication. *)

open Alcotest
open Agent_sdk

(* ── Helpers ──────────────────────────────────────────────────────── *)

let make_agent env =
  Agent.create
    ~net:env#net
    ~config:{ (Types.default_config ~model:"test-model") with name = "original" }
    ()
;;

let make_agent_with_context env =
  let ctx = Context.create_sync () in
  Context.set ctx "key1" (`String "val1");
  Context.set ctx "key2" (`Int 42);
  Agent.create
    ~net:env#net
    ~config:{ (Types.default_config ~model:"test-model") with name = "ctx-agent" }
    ~context:ctx
    ()
;;

(* ── 1. clone_fresh_context ──────────────────────────────────────── *)

let test_clone_fresh_context () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent_with_context env in
  let clone = Agent.clone agent in
  check (list string) "clone context is empty" [] (Context.keys (Agent.context clone));
  let orig_keys = List.sort String.compare (Context.keys (Agent.context agent)) in
  check (list string) "original unchanged" [ "key1"; "key2" ] orig_keys
;;

(* ── 2. clone_copy_context ───────────────────────────────────────── *)

let test_clone_copy_context () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent_with_context env in
  let clone = Agent.clone ~copy_context:true agent in
  check
    bool
    "key1 copied"
    true
    (Context.get (Agent.context clone) "key1" = Some (`String "val1"));
  check bool "key2 copied" true (Context.get (Agent.context clone) "key2" = Some (`Int 42))
;;

(* ── 3. clone_context_independence ───────────────────────────────── *)

let test_clone_context_independence () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent_with_context env in
  let clone = Agent.clone ~copy_context:true agent in
  Context.set (Agent.context clone) "key1" (`String "changed");
  check
    bool
    "original key1 unchanged"
    true
    (Context.get (Agent.context agent) "key1" = Some (`String "val1"))
;;

(* ── 4. clone_state_independence ─────────────────────────────────── *)

let test_clone_state_independence () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  let clone = Agent.clone agent in
  Agent.set_state clone { (Agent.state clone) with turn_count = 99 };
  check int "original turn_count unchanged" 0 (Agent.state agent).turn_count
;;

(* ── 5. clone_preserves_messages ─────────────────────────────────── *)

let test_clone_preserves_messages () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  Agent.set_state
    agent
    { (Agent.state agent) with
      messages =
        [ { Types.role = User
          ; content = [ Text "hello" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
    };
  let clone = Agent.clone agent in
  check int "clone has same messages" 1 (List.length (Agent.state clone).messages)
;;

(* ── 6. clone_preserves_turn_count ───────────────────────────────── *)

let test_clone_preserves_turn_count () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  Agent.set_state agent { (Agent.state agent) with turn_count = 7 };
  let clone = Agent.clone agent in
  check int "turn_count matches" 7 (Agent.state clone).turn_count
;;

(* ── 7. clone_preserves_usage ────────────────────────────────────── *)

let test_clone_preserves_usage () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  Agent.set_state
    agent
    { (Agent.state agent) with
      usage = { Types.empty_usage with total_input_tokens = 100; api_calls = 3 }
    };
  let clone = Agent.clone agent in
  check int "input tokens match" 100 (Agent.state clone).usage.total_input_tokens;
  check int "api calls match" 3 (Agent.state clone).usage.api_calls
;;

(* ── 8. clone_preserves_config ───────────────────────────────────── *)

let test_clone_preserves_config () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  let clone = Agent.clone agent in
  check string "name" "original" (Agent.state clone).config.name
;;

(* ── 9. clone_shares_tools ───────────────────────────────────────── *)

let test_clone_shares_tools () =
  Eio_main.run
  @@ fun env ->
  let tool =
    Tool.create ~name:"echo" ~description:"echo" ~parameters:[] (fun _ ->
      Ok { Types.content = "ok"; _meta = None })
  in
  let agent =
    Agent.create
      ~net:env#net
      ~config:(Types.default_config ~model:"test-model")
      ~tools:[ tool ]
      ()
  in
  let clone = Agent.clone agent in
  check bool "tools physically identical" true (Agent.tools agent == Agent.tools clone)
;;

(* ── 10. clone_shares_options ────────────────────────────────────── *)

let test_clone_shares_options () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  let clone = Agent.clone agent in
  check bool "options identical" true (Agent.options agent == Agent.options clone)
;;

(* ── 11. clone_state_divergence ──────────────────────────────────── *)

let test_clone_state_divergence () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  let clone = Agent.clone agent in
  (* Mutate original *)
  Agent.set_state
    agent
    { (Agent.state agent) with
      turn_count = 10
    ; messages =
        [ { Types.role = User
          ; content = [ Text "original only" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
    };
  (* Clone should be unaffected *)
  check int "clone turn_count unchanged" 0 (Agent.state clone).turn_count;
  check int "clone messages unchanged" 0 (List.length (Agent.state clone).messages)
;;

(* ── 12. clone_from_resumed_agent ────────────────────────────────── *)

let test_clone_from_resumed_agent () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent env in
  Agent.set_state
    agent
    { (Agent.state agent) with
      turn_count = 3
    ; messages =
        [ { Types.role = User
          ; content = [ Text "msg1" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ; { Types.role = Assistant
          ; content = [ Text "reply1" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
    };
  (* Simulate resume by creating checkpoint and restoring *)
  let cp = Agent.checkpoint ~session_id:"s1" agent in
  let resumed = Agent.resume ~net:env#net ~checkpoint:cp () in
  let clone = Agent.clone ~copy_context:true resumed in
  check int "clone turn_count from resumed" 3 (Agent.state clone).turn_count;
  check int "clone messages from resumed" 2 (List.length (Agent.state clone).messages);
  check string "clone config name" "original" (Agent.state clone).config.name
;;

(* ── Suite ────────────────────────────────────────────────────────── *)

let () =
  run
    "Agent.clone"
    [ ( "context"
      , [ test_case "fresh context" `Quick test_clone_fresh_context
        ; test_case "copy context" `Quick test_clone_copy_context
        ; test_case "context independence" `Quick test_clone_context_independence
        ] )
    ; ( "state"
      , [ test_case "state independence" `Quick test_clone_state_independence
        ; test_case "preserves messages" `Quick test_clone_preserves_messages
        ; test_case "preserves turn_count" `Quick test_clone_preserves_turn_count
        ; test_case "preserves usage" `Quick test_clone_preserves_usage
        ; test_case "preserves config" `Quick test_clone_preserves_config
        ] )
    ; ( "sharing"
      , [ test_case "shares tools" `Quick test_clone_shares_tools
        ; test_case "shares options" `Quick test_clone_shares_options
        ] )
    ; ( "divergence"
      , [ test_case "state divergence" `Quick test_clone_state_divergence
        ; test_case "from resumed agent" `Quick test_clone_from_resumed_agent
        ] )
    ]
;;

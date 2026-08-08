(** Tests for initial_messages — conversation history seeding.
    Issue #214: Agent.run should support injecting prior conversation
    history via agent_config.initial_messages. *)

open Alcotest
open Agent_sdk
open Types

(* ── Helper: build an agent with initial_messages ──── *)

let make_agent ~net ?(initial_messages = []) () =
  let config = { (default_config ~model:"test-model") with initial_messages } in
  Agent.create ~net ~config ()
;;

let msg role text =
  { role; content = [ Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

(* ── Tests ──────────────────────────────────────────── *)

let test_default_empty () =
  check
    int
    "default empty"
    0
    (List.length (default_config ~model:"test-model").initial_messages)
;;

let test_base_messages_fresh () =
  Eio_main.run
  @@ fun env ->
  let history =
    [ msg User "What is OCaml?"
    ; msg Assistant "OCaml is a functional programming language."
    ]
  in
  let agent = make_agent ~net:env#net ~initial_messages:history () in
  (* Fresh agent: base_messages returns initial_messages *)
  let base = Agent.base_messages agent in
  check int "returns initial_messages" 2 (List.length base);
  match (List.hd base).content with
  | [ Text t ] -> check string "first msg" "What is OCaml?" t
  | _ -> fail "unexpected content"
;;

let test_base_messages_after_run () =
  Eio_main.run
  @@ fun env ->
  let history = [ msg User "hi"; msg Assistant "hello" ] in
  let agent = make_agent ~net:env#net ~initial_messages:history () in
  (* Simulate what run_loop does: inject initial + user_msg *)
  let user_msg = msg User "new prompt" in
  let st = Agent.state agent in
  Agent.set_state
    agent
    { st with messages = Util.snoc (Agent.base_messages agent) user_msg };
  (* After first injection: base_messages returns existing messages, not initial *)
  let base = Agent.base_messages agent in
  check int "returns existing messages" 3 (List.length base);
  (* Verify initial_messages are NOT re-injected *)
  let second_user = msg User "follow up" in
  let st2 = Agent.state agent in
  Agent.set_state
    agent
    { st2 with messages = Util.snoc (Agent.base_messages agent) second_user };
  let final = (Agent.state agent).messages in
  check int "no duplication" 4 (List.length final)
;;

let test_base_messages_empty_initial () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent ~net:env#net () in
  let base = Agent.base_messages agent in
  check int "empty returns empty" 0 (List.length base)
;;

let test_empty_initial_preserves_behavior () =
  Eio_main.run
  @@ fun env ->
  let agent = make_agent ~net:env#net () in
  let st = Agent.state agent in
  check int "empty messages" 0 (List.length st.messages);
  check int "empty initial_messages" 0 (List.length st.config.initial_messages)
;;

let test_builder_initial_messages () =
  Eio_main.run
  @@ fun env ->
  let history = [ msg User "hi"; msg Assistant "hello" ] in
  let agent =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_initial_messages history
    |> Builder.build_safe
    |> Result.get_ok
  in
  let st = Agent.state agent in
  check int "config has 2 initial messages" 2 (List.length st.config.initial_messages);
  (* create initializes messages = config.initial_messages (agent_types.ml) *)
  check int "state messages seeded from initial" 2 (List.length st.messages)
;;

let test_config_show () =
  (* Verify [@@deriving show] works with initial_messages *)
  let config =
    { (default_config ~model:"test-model") with initial_messages = [ msg User "test" ] }
  in
  let s = show_agent_config config in
  check bool "show includes initial" true (String.length s > 0)
;;

(* ── Suite ──────────────────────────────────────────── *)

let () =
  run
    "Initial_messages"
    [ ( "config"
      , [ test_case "default is empty" `Quick test_default_empty
        ; test_case "show works" `Quick test_config_show
        ] )
    ; ( "base_messages"
      , [ test_case "fresh agent returns initial_messages" `Quick test_base_messages_fresh
        ; test_case "after injection returns existing" `Quick test_base_messages_after_run
        ; test_case "empty initial returns empty" `Quick test_base_messages_empty_initial
        ; test_case
            "empty preserves behavior"
            `Quick
            test_empty_initial_preserves_behavior
        ] )
    ; ( "builder"
      , [ test_case "with_initial_messages" `Quick test_builder_initial_messages ] )
    ]
;;

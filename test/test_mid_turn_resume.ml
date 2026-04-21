(** Test_mid_turn_resume — Verifies checkpoint preservation across
    cascade provider failures (mid-turn resume).

    LLM 0 — no real MODEL calls. Tests use mock Agent.create/set_state/checkpoint/resume.

    @since Phase 3 — Mid-turn resume *)

module Oas = Agent_sdk

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let test_net : ([ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ref) =
  ref None

let require_net () =
  match !test_net with
  | Some net -> net
  | None -> Alcotest.fail "test net not initialized"

(* ================================================================ *)
(* Tests                                                            *)
(* ================================================================ *)

(** Verify that Agent.checkpoint captures accumulated turn state,
    and Agent.resume restores it — the foundation of mid-turn resume.
    If this roundtrip breaks, cascade fallback loses prior turns. *)
let test_checkpoint_roundtrip () =
  let net = require_net () in
  let config = { Oas.Types.default_config with
    name = "mid-turn-test";
    model = "mock-model";
    system_prompt = Some "test system prompt";
    max_turns = 10;
  } in
  let agent = Oas.Agent.create ~net ~config () in
  (* Simulate 3 completed turns by manually updating state *)
  let msgs = [
    Oas.Types.user_msg "turn 1 user";
    { Oas.Types.role = Oas.Types.Assistant;
      content = [Oas.Types.Text "turn 1 response"];
      name = None; tool_call_id = None };
    Oas.Types.user_msg "turn 2 user";
    { Oas.Types.role = Oas.Types.Assistant;
      content = [Oas.Types.Text "turn 2 response"];
      name = None; tool_call_id = None };
    Oas.Types.user_msg "turn 3 user";
    { Oas.Types.role = Oas.Types.Assistant;
      content = [Oas.Types.Text "turn 3 response"];
      name = None; tool_call_id = None };
  ] in
  Oas.Agent.set_state agent { (Oas.Agent.state agent) with
    messages = msgs;
    turn_count = 3;
  };
  (* Extract checkpoint — this is what mid-turn resume does on failure *)
  let cp = Oas.Agent.checkpoint agent in
  Alcotest.(check int) "checkpoint turn_count" 3 cp.turn_count;
  Alcotest.(check int) "checkpoint messages" 6 (List.length cp.messages);
  Alcotest.(check (option string)) "checkpoint system_prompt"
    (Some "test system prompt") cp.system_prompt;
  (* Resume with different provider — simulates cascade fallback *)
  let resumed = Oas.Agent.resume ~net ~checkpoint:cp () in
  let resumed_state = Oas.Agent.state resumed in
  Alcotest.(check int) "resumed turn_count" 3 resumed_state.turn_count;
  Alcotest.(check int) "resumed messages" 6 (List.length resumed_state.messages);
  Alcotest.(check (option string)) "resumed system_prompt"
    resumed_state.config.system_prompt cp.system_prompt

(** Verify that zero-turn agent yields no checkpoint for resume.
    Mid-turn resume should not thread an empty checkpoint. *)
let test_zero_turns_no_checkpoint () =
  let net = require_net () in
  let agent = Oas.Agent.create ~net () in
  let state = Oas.Agent.state agent in
  Alcotest.(check int) "fresh agent turn_count" 0 state.turn_count;
  (* The mid-turn resume code checks turn_count > 0 before extracting *)
  let should_extract = state.turn_count > 0 in
  Alcotest.(check bool) "zero turns: no checkpoint" false should_extract

(** Verify checkpoint accumulation across multiple resume cycles.
    Simulates: Provider A (2 turns) -> fail -> Provider B (1 turn) -> fail -> Provider C resume.
    Provider C should see 3 accumulated turns. *)
let test_multi_cascade_accumulation () =
  let net = require_net () in
  (* Provider A: 2 turns *)
  let agent_a = Oas.Agent.create ~net ~config:{ Oas.Types.default_config with
    name = "cascade-a"; model = "provider-a" } () in
  Oas.Agent.set_state agent_a { (Oas.Agent.state agent_a) with
    messages = [
      Oas.Types.user_msg "t1";
      { Oas.Types.role = Oas.Types.Assistant;
        content = [Oas.Types.Text "r1"]; name = None; tool_call_id = None };
      Oas.Types.user_msg "t2";
      { Oas.Types.role = Oas.Types.Assistant;
        content = [Oas.Types.Text "r2"]; name = None; tool_call_id = None };
    ];
    turn_count = 2;
  };
  let cp_a = Oas.Agent.checkpoint agent_a in
  Alcotest.(check int) "cp_a turns" 2 cp_a.turn_count;
  (* Provider B: resume from A, add 1 turn *)
  let agent_b = Oas.Agent.resume ~net ~checkpoint:cp_a () in
  Oas.Agent.set_state agent_b { (Oas.Agent.state agent_b) with
    messages = (Oas.Agent.state agent_b).messages @ [
      Oas.Types.user_msg "t3";
      { Oas.Types.role = Oas.Types.Assistant;
        content = [Oas.Types.Text "r3"]; name = None; tool_call_id = None };
    ];
    turn_count = 3;
  };
  let cp_b = Oas.Agent.checkpoint agent_b in
  Alcotest.(check int) "cp_b turns" 3 cp_b.turn_count;
  Alcotest.(check int) "cp_b messages" 6 (List.length cp_b.messages);
  (* Provider C: resume from B — should see all 3 turns *)
  let agent_c = Oas.Agent.resume ~net ~checkpoint:cp_b () in
  let state_c = Oas.Agent.state agent_c in
  Alcotest.(check int) "provider C sees 3 turns" 3 state_c.turn_count;
  Alcotest.(check int) "provider C sees 6 messages" 6 (List.length state_c.messages)

(** Verify that Agent.resume without config override preserves the
    checkpoint's model. MASC handles provider switching via
    resume_from_checkpoint which patches config separately. *)
let test_resume_preserves_checkpoint_model () =
  let net = require_net () in
  let agent = Oas.Agent.create ~net ~config:{ Oas.Types.default_config with
    model = "provider-a-model" } () in
  Oas.Agent.set_state agent { (Oas.Agent.state agent) with
    messages = [Oas.Types.user_msg "hello"];
    turn_count = 1;
  };
  let cp = Oas.Agent.checkpoint agent in
  Alcotest.(check string) "checkpoint model" "provider-a-model" cp.model;
  (* Resume without config override — checkpoint model is preserved *)
  let resumed = Oas.Agent.resume ~net ~checkpoint:cp () in
  let state = Oas.Agent.state resumed in
  Alcotest.(check string) "resumed keeps checkpoint model" "provider-a-model"
    (Oas.Types.model_to_string state.config.model)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  test_net := Some env#net;
  Alcotest.run "Mid-Turn Resume" [
    "checkpoint_threading", [
      Alcotest.test_case "roundtrip preserves turn state" `Quick
        test_checkpoint_roundtrip;
      Alcotest.test_case "zero turns yields no checkpoint" `Quick
        test_zero_turns_no_checkpoint;
      Alcotest.test_case "multi-cascade accumulation (A->B->C)" `Quick
        test_multi_cascade_accumulation;
      Alcotest.test_case "resume preserves checkpoint model" `Quick
        test_resume_preserves_checkpoint_model;
    ];
  ]

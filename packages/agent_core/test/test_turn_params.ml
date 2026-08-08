(** Tests for turn_params, BeforeTurnParams hook, and related features. *)

open Agent_sdk

(* ── Turn params types ───────────────────────────────────────── *)

let test_default_turn_params () =
  let p = Hooks.default_turn_params in
  Alcotest.(check (option (float 0.01))) "no temperature" None p.temperature;
  Alcotest.(check (option int)) "no thinking_budget" None p.thinking_budget;
  Alcotest.(check (option bool)) "no enable_thinking" None p.enable_thinking;
  Alcotest.(check bool) "no extra context" true (p.extra_system_context = None);
  Alcotest.(check bool) "no system prompt override" true (p.system_prompt_override = None)
;;

let test_enable_thinking_override () =
  let p = { Hooks.default_turn_params with enable_thinking = Some false } in
  Alcotest.(check (option bool))
    "enable_thinking=false override"
    (Some false)
    p.enable_thinking;
  let q = { Hooks.default_turn_params with enable_thinking = Some true } in
  Alcotest.(check (option bool))
    "enable_thinking=true override"
    (Some true)
    q.enable_thinking
;;

(* ── Reasoning extraction ────────────────────────────────────── *)

let test_empty_reasoning () =
  let r = Hooks.extract_reasoning [] in
  Alcotest.(check bool) "no thinking" true (r.thinking_blocks = []);
  Alcotest.(check bool) "no uncertainty" false r.has_uncertainty;
  Alcotest.(check bool) "no rationale" true (r.tool_rationale = None)
;;

let test_reasoning_with_thinking () =
  let messages : Types.message list =
    [ { role = Assistant
      ; content =
          [ Types.Thinking
              { signature = None; content = "I'm not sure about this approach" }
          ; Types.Text "Here is my answer"
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let r = Hooks.extract_reasoning messages in
  Alcotest.(check int) "one thinking block" 1 (List.length r.thinking_blocks);
  Alcotest.(check bool) "no inferred uncertainty" false r.has_uncertainty
;;

let test_reasoning_tool_rationale () =
  let messages : Types.message list =
    [ { role = Assistant
      ; content =
          [ Types.Thinking
              { signature = None
              ; content = "I should use the search tool to find information"
              }
          ; Types.Text "Let me search for that"
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let r = Hooks.extract_reasoning messages in
  Alcotest.(check bool) "no inferred tool rationale" true (r.tool_rationale = None)
;;

(* ── Hook event types ────────────────────────────────────────── *)

let test_before_turn_params_event () =
  let params = Hooks.default_turn_params in
  let reasoning = Hooks.empty_reasoning_summary in
  let event =
    Hooks.BeforeTurnParams
      { turn = 0
      ; messages = []
      ; last_tool_results = []
      ; current_params = params
      ; reasoning
      }
  in
  (* Just verify the event constructs correctly *)
  match event with
  | Hooks.BeforeTurnParams { turn; _ } -> Alcotest.(check int) "turn 0" 0 turn
  | _ -> Alcotest.fail "wrong event type"
;;

let test_adjust_params_decision () =
  let params =
    { Hooks.default_turn_params with temperature = Some 0.9; thinking_budget = Some 8000 }
  in
  let decision = Hooks.AdjustParams params in
  match decision with
  | Hooks.AdjustParams p ->
    Alcotest.(check (option (float 0.01))) "temperature" (Some 0.9) p.temperature;
    Alcotest.(check (option int)) "thinking_budget" (Some 8000) p.thinking_budget
  | _ -> Alcotest.fail "wrong decision type"
;;

let test_adjust_params_system_prompt_override () =
  let params =
    { Hooks.default_turn_params with
      system_prompt_override = Some "You are a code reviewer."
    }
  in
  let decision = Hooks.AdjustParams params in
  match decision with
  | Hooks.AdjustParams p ->
    Alcotest.(check (option string))
      "system_prompt_override"
      (Some "You are a code reviewer.")
      p.system_prompt_override;
    (* Other fields remain default *)
    Alcotest.(check (option (float 0.01))) "temperature unchanged" None p.temperature;
    Alcotest.(check bool)
      "extra_system_context unchanged"
      true
      (p.extra_system_context = None)
  | _ -> Alcotest.fail "wrong decision type"
;;

(* ── Provider mock ───────────────────────────────────────────── *)

let test_provider_mock_basic () =
  let mock = Provider_mock.create ~responses:[ Provider_mock.text_response "hello" ] () in
  let result = Provider_mock.next_response mock [] in
  (match result with
   | Ok resp ->
     let text =
       List.filter_map
         (function
           | Types.Text s -> Some s
           | _ -> None)
         resp.content
       |> String.concat ""
     in
     Alcotest.(check string) "response text" "hello" text
   | Error _ -> Alcotest.fail "unexpected error");
  Alcotest.(check int) "call count" 1 (Provider_mock.call_count mock)
;;

let test_provider_mock_cycling () =
  let mock =
    Provider_mock.create
      ~responses:
        [ Provider_mock.text_response "first"; Provider_mock.text_response "second" ]
      ()
  in
  let _ = Provider_mock.next_response mock [] in
  let _ = Provider_mock.next_response mock [] in
  let result = Provider_mock.next_response mock [] in
  (match result with
   | Ok resp ->
     let text =
       List.filter_map
         (function
           | Types.Text s -> Some s
           | _ -> None)
         resp.content
       |> String.concat ""
     in
     Alcotest.(check string) "cycles back" "first" text
   | Error _ -> Alcotest.fail "unexpected error");
  Alcotest.(check int) "3 calls" 3 (Provider_mock.call_count mock)
;;

let test_provider_mock_reset () =
  let mock = Provider_mock.create ~responses:[ Provider_mock.text_response "hello" ] () in
  let _ = Provider_mock.next_response mock [] in
  Provider_mock.reset mock;
  Alcotest.(check int) "reset to 0" 0 (Provider_mock.call_count mock)
;;

let test_provider_mock_tool_use () =
  let mock =
    Provider_mock.create
      ~responses:
        [ Provider_mock.tool_use_response
            ~tool_name:"search"
            ~tool_input:(`Assoc [ "q", `String "test" ])
            ()
        ]
      ()
  in
  let result = Provider_mock.next_response mock [] in
  match result with
  | Ok resp ->
    (match resp.stop_reason with
     | Types.StopToolUse -> ()
     | _ -> Alcotest.fail "expected StopToolUse");
    let has_tool_use =
      List.exists
        (function
          | Types.ToolUse { name = "search"; _ } -> true
          | _ -> false)
        resp.content
    in
    Alcotest.(check bool) "has tool use" true has_tool_use
  | Error _ -> Alcotest.fail "unexpected error"
;;

(* ── Context scoped isolation ────────────────────────────────── *)

let test_context_scope_isolation () =
  let parent = Context.create_sync () in
  Context.set parent "shared_key" (`String "shared_value");
  Context.set parent "private_key" (`String "private_value");
  let scope =
    Context.create_scope
      ~parent
      ~propagate_down:[ "shared_key" ]
      ~propagate_up:[ "result_key" ]
  in
  (* Only shared_key should be in local *)
  Alcotest.(check bool)
    "shared_key inherited"
    true
    (Context.get scope.local "shared_key" <> None);
  Alcotest.(check bool)
    "private_key not inherited"
    true
    (Context.get scope.local "private_key" = None);
  (* Set a result in local *)
  Context.set scope.local "result_key" (`String "result");
  Context.set scope.local "local_only" (`String "local");
  (* Merge back *)
  Context.merge_back scope;
  (* Only result_key should be in parent *)
  Alcotest.(check bool)
    "result_key propagated"
    true
    (Context.get parent "result_key" <> None);
  Alcotest.(check bool)
    "local_only not propagated"
    true
    (Context.get parent "local_only" = None)
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "turn_params"
    [ ( "turn_params"
      , [ Alcotest.test_case "default" `Quick test_default_turn_params
        ; Alcotest.test_case
            "enable_thinking_override"
            `Quick
            test_enable_thinking_override
        ; Alcotest.test_case
            "before_turn_params_event"
            `Quick
            test_before_turn_params_event
        ; Alcotest.test_case "adjust_params_decision" `Quick test_adjust_params_decision
        ; Alcotest.test_case
            "system_prompt_override"
            `Quick
            test_adjust_params_system_prompt_override
        ] )
    ; ( "reasoning"
      , [ Alcotest.test_case "empty" `Quick test_empty_reasoning
        ; Alcotest.test_case "with_thinking" `Quick test_reasoning_with_thinking
        ; Alcotest.test_case "tool_rationale" `Quick test_reasoning_tool_rationale
        ] )
    ; ( "provider_mock"
      , [ Alcotest.test_case "basic" `Quick test_provider_mock_basic
        ; Alcotest.test_case "cycling" `Quick test_provider_mock_cycling
        ; Alcotest.test_case "reset" `Quick test_provider_mock_reset
        ; Alcotest.test_case "tool_use" `Quick test_provider_mock_tool_use
        ] )
    ; ( "context_scope"
      , [ Alcotest.test_case "isolation" `Quick test_context_scope_isolation ] )
    ]
;;

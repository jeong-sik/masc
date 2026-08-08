(** Deep coverage tests for pipeline/pipeline.ml (63 uncovered points).

    Pipeline.run_turn is the only public function (via .mli), so we test
    coverage indirectly through the functions pipeline calls:
    - Hooks.extract_reasoning (Stage 2: Parse)
    - Agent_turn.resolve_turn_params (Stage 2)
    - Agent_turn.apply_context_injection (Stage 5)
    - Error_domain.tag_error pattern (coordinator)
    - Pipeline.run_turn via mock HTTP (Stages 1-6) *)

open Agent_sdk

let invocation tool_use_id =
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  Tool_contract.Invocation.create
    ~tool_use_id
    ~turn:0
    ~schedule
    ~completion:Tool_contract.Continue_after_success
;;

let context_messages = function
  | Ok messages -> messages
  | Error error -> Alcotest.fail error.Agent_turn.detail
;;

(* ── Hooks.extract_reasoning: edge cases ──────────────────── *)

(** Multiple thinking blocks from multiple messages. *)
let test_reasoning_multiple_messages () =
  let messages : Types.message list =
    [ { role = Assistant
      ; content =
          [ Types.Thinking { signature = None; content = "First thought" }
          ; Types.Text "response 1"
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = User
      ; content = [ Text "follow-up" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content =
          [ Types.Thinking
              { signature = None; content = "Second thought, I'm not sure about this" }
          ; Types.Text "response 2"
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let r = Hooks.extract_reasoning messages in
  Alcotest.(check int) "2 thinking blocks" 2 (List.length r.thinking_blocks);
  Alcotest.(check bool) "no inferred uncertainty" false r.has_uncertainty
;;

(** No thinking blocks but has text messages. *)
let test_reasoning_no_thinking_blocks () =
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "question" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ Text "answer" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let r = Hooks.extract_reasoning messages in
  Alcotest.(check int) "0 thinking blocks" 0 (List.length r.thinking_blocks);
  Alcotest.(check bool) "no uncertainty" false r.has_uncertainty;
  Alcotest.(check bool) "no rationale" true (Option.is_none r.tool_rationale)
;;

(** Thinking prose mentioning tools does not produce inferred tool_rationale. *)
let test_reasoning_no_tool_rationale_inference () =
  let messages : Types.message list =
    [ { role = Assistant
      ; content =
          [ Types.Thinking
              { signature = None
              ; content = "I should use the search function to find info"
              }
          ; Types.Text "Searching now"
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let r = Hooks.extract_reasoning messages in
  Alcotest.(check bool) "no inferred rationale" true (Option.is_none r.tool_rationale)
;;

(** Thinking prose markers do not produce inferred uncertainty. *)
let test_reasoning_no_uncertainty_marker_inference () =
  let markers =
    [ "uncertain"
    ; "unclear"
    ; "might be wrong"
    ; "unsure"
    ; "probably"
    ; "I think"
    ; "I'm not confident"
    ]
  in
  List.iter
    (fun marker ->
       let messages : Types.message list =
         [ { role = Assistant
           ; content =
               [ Types.Thinking { signature = None; content = "Analysis: " ^ marker } ]
           ; name = None
           ; tool_call_id = None
           ; metadata = []
           }
         ]
       in
       let r = Hooks.extract_reasoning messages in
       Alcotest.(check bool)
         (Printf.sprintf "marker '%s' not inferred" marker)
         false
         r.has_uncertainty)
    markers
;;

(** Thinking block without uncertainty markers. *)
let test_reasoning_no_uncertainty () =
  let messages : Types.message list =
    [ { role = Assistant
      ; content =
          [ Types.Thinking { signature = None; content = "The answer is clearly 42" } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let r = Hooks.extract_reasoning messages in
  Alcotest.(check bool) "no uncertainty" false r.has_uncertainty
;;

(* ── Agent_turn.resolve_turn_params ───────────────────────── *)

let expect_turn_params = function
  | Ok params -> params
  | Error _ -> Alcotest.fail "expected resolved turn params"
;;

(** resolve_turn_params with no before_turn_params hook returns defaults. *)
let test_resolve_params_no_hook () =
  let hooks = Hooks.empty in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ _hook _event = Hooks.Continue in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check bool) "default temperature" true (Option.is_none params.temperature);
  Alcotest.(check bool)
    "default thinking_budget"
    true
    (Option.is_none params.thinking_budget);
  Alcotest.(check bool)
    "default extra_context"
    true
    (Option.is_none params.extra_system_context)
;;

(** resolve_turn_params with an explicit Continue decision returns defaults. *)
let test_resolve_params_continue () =
  let hooks = { Hooks.empty with before_turn_params = Some (fun _ -> Hooks.Continue) } in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ hook event =
    match hook with
    | Some h -> h event
    | None -> Hooks.Continue
  in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check bool) "default temperature" true (Option.is_none params.temperature);
  Alcotest.(check bool)
    "default thinking_budget"
    true
    (Option.is_none params.thinking_budget);
  Alcotest.(check bool)
    "default extra_context"
    true
    (Option.is_none params.extra_system_context)
;;

(** resolve_turn_params with AdjustParams decision applies params. *)
let test_resolve_params_adjust () =
  let adjusted : Hooks.turn_params =
    { temperature = Some 0.7
    ; thinking_budget = Some 1000
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; tool_choice = None
    ; extra_system_context = Some "Debug mode"
    ; system_prompt_override = None
    }
  in
  let hooks =
    { Hooks.empty with before_turn_params = Some (fun _ -> Hooks.AdjustParams adjusted) }
  in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ hook event =
    match hook with
    | Some h -> h event
    | None -> Hooks.Continue
  in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check (option (float 0.01)))
    "adjusted temperature"
    (Some 0.7)
    params.temperature;
  Alcotest.(check (option int))
    "adjusted thinking_budget"
    (Some 1000)
    params.thinking_budget;
  Alcotest.(check (option string))
    "adjusted context"
    (Some "Debug mode")
    params.extra_system_context
;;

(** resolve_turn_params with system_prompt_override preserves the override. *)
let test_resolve_params_system_prompt_override () =
  let adjusted =
    { Hooks.default_turn_params with
      system_prompt_override = Some "You are a code reviewer."
    }
  in
  let hooks =
    { Hooks.empty with before_turn_params = Some (fun _ -> Hooks.AdjustParams adjusted) }
  in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "review this" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ hook event =
    match hook with
    | Some h -> h event
    | None -> Hooks.Continue
  in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check (option string))
    "system_prompt_override applied"
    (Some "You are a code reviewer.")
    params.system_prompt_override;
  (* Original config fields remain default *)
  Alcotest.(check bool) "temperature unchanged" true (Option.is_none params.temperature)
;;

(** resolve_turn_params with system_prompt_override = None preserves original. *)
let test_resolve_params_no_system_prompt_override () =
  let hooks = Hooks.empty in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ _hook _event = Hooks.Continue in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check (option string))
    "no system_prompt_override"
    None
    params.system_prompt_override
;;

(** resolve_turn_params extracts last_tool_results from messages. *)
let test_resolve_params_with_tool_results () =
  let captured_results = ref [] in
  let hooks =
    { Hooks.empty with
      before_turn_params =
        Some
          (fun event ->
            (match event with
             | Hooks.BeforeTurnParams { last_tool_results; _ } ->
               captured_results := last_tool_results
             | _ -> ());
            Hooks.Continue)
    }
  in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "do something" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ ToolUse { id = "tu_1"; name = "search"; input = `Assoc [] } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "tu_1"
              ; content = "found it"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ hook event =
    match hook with
    | Some h -> h event
    | None -> Hooks.Continue
  in
  let _params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check int) "1 tool result captured" 1 (List.length !captured_results);
  match List.hd !captured_results with
  | Ok { content; _meta = _ } -> Alcotest.(check string) "content" "found it" content
  | Error _ -> Alcotest.fail "expected Ok result"
;;

(** resolve_turn_params with error tool results. *)
let test_resolve_params_error_tool_results () =
  let captured_results = ref [] in
  let hooks =
    { Hooks.empty with
      before_turn_params =
        Some
          (fun event ->
            (match event with
             | Hooks.BeforeTurnParams { last_tool_results; _ } ->
               captured_results := last_tool_results
             | _ -> ());
            Hooks.Continue)
    }
  in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "try this" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ ToolUse { id = "tu_e"; name = "risky"; input = `Assoc [] } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "tu_e"
              ; content = "permission denied"
              ; outcome =
                  Tool_failed
                    { failure_kind = Recoverable_tool_error
                    ; error_class = Some Deterministic
                    }
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let invoke_hook ~hook_name:_ hook event =
    match hook with
    | Some h -> h event
    | None -> Hooks.Continue
  in
  let _params =
    Agent_turn.resolve_turn_params ~hooks ~messages ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check int) "1 error result" 1 (List.length !captured_results);
  match List.hd !captured_results with
  | Error { message; recoverable; error_class } ->
    Alcotest.(check string) "error message" "permission denied" message;
    Alcotest.(check bool) "recoverable" true recoverable;
    Alcotest.(check bool) "error class" true (error_class = Some Types.Deterministic)
  | Ok _ -> Alcotest.fail "expected Error result"
;;

(* ── Agent_turn.apply_context_injection ───────────────────── *)

(** Context injection sets context values. *)
let test_context_injection_sets_values () =
  let context = Context.create_sync () in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "query" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ =
    Some
      { Hooks.context_updates = [ "key1", `String "val1"; "key2", `Int 42 ]
      ; extra_messages = []
      }
  in
  let tool_uses = [ Types.ToolUse { id = "tu_1"; name = "search"; input = `Assoc [] } ] in
  let results =
    [ { Agent_tools.invocation = invocation "tu_1"
      ; tool_name = "search"
      ; input = `Assoc []
      ; content = "result text"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let _new_messages =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  Alcotest.(check (option string))
    "key1 set"
    (Some "val1")
    (match Context.get context "key1" with
     | Some (`String s) -> Some s
     | _ -> None);
  Alcotest.(check (option int))
    "key2 set"
    (Some 42)
    (match Context.get context "key2" with
     | Some (`Int n) -> Some n
     | _ -> None)
;;

(** Context injection returns None (no injection). *)
let test_context_injection_none () =
  let context = Context.create_sync () in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "query" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ = None in
  let tool_uses = [ Types.ToolUse { id = "tu_n"; name = "tool"; input = `Assoc [] } ] in
  let results =
    [ { Agent_tools.invocation = invocation "tu_n"
      ; tool_name = "tool"
      ; input = `Assoc []
      ; content = "ok"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let new_messages =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  (* No extra messages appended *)
  Alcotest.(check int) "messages unchanged" 1 (List.length new_messages)
;;

(** Context injection with extra_messages. *)
let test_context_injection_extra_messages () =
  let context = Context.create_sync () in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "query" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Assistant
      ; content = [ ToolUse { id = "tu_m"; name = "tool"; input = `Assoc [] } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ =
    Some
      { Hooks.context_updates = []
      ; extra_messages =
          [ { Types.role = User
            ; content = [ Text "injected context" ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
          ]
      }
  in
  let tool_uses = [ Types.ToolUse { id = "tu_m"; name = "tool"; input = `Assoc [] } ] in
  let results =
    [ { Agent_tools.invocation = invocation "tu_m"
      ; tool_name = "tool"
      ; input = `Assoc []
      ; content = "ok"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let new_messages =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  (* Original 2 + injected 1 *)
  Alcotest.(check int) "messages with injection" 3 (List.length new_messages)
;;

(** Context injection with error tool result. *)
let test_context_injection_error_result () =
  let context = Context.create_sync () in
  let received_output = ref None in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "query" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output =
    received_output := Some output;
    None
  in
  let tool_uses = [ Types.ToolUse { id = "tu_err"; name = "tool"; input = `Assoc [] } ] in
  let results =
    [ { Agent_tools.invocation = invocation "tu_err"
      ; tool_name = "tool"
      ; input = `Assoc []
      ; content = "something went wrong"
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Recoverable_tool_error; error_class = None }
      }
    ]
  in
  let _new_messages =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  match !received_output with
  | Some (Error { message; recoverable; _ }) ->
    Alcotest.(check string) "error message" "something went wrong" message;
    Alcotest.(check bool) "recoverable" true recoverable
  | Some (Ok _) -> Alcotest.fail "expected Error output"
  | None -> Alcotest.fail "injector not called"
;;

(** Context injection: injector raises exception. *)
let test_context_injection_raises () =
  let context = Context.create_sync () in
  let messages : Types.message list =
    [ { role = User
      ; content = [ Text "query" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ = failwith "injector crash" in
  let tool_uses = [ Types.ToolUse { id = "tu_ex"; name = "tool"; input = `Assoc [] } ] in
  let results =
    [ { Agent_tools.invocation = invocation "tu_ex"
      ; tool_name = "tool"
      ; input = `Assoc []
      ; content = "ok"
      ; outcome = Tool_succeeded
      }
    ]
  in
  match
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
  with
  | Error { tool_name = Some "tool"; detail } ->
    Alcotest.(check bool)
      "exception detail"
      true
      (String.starts_with ~prefix:"Failure(\"injector crash\")" detail)
  | Error _ -> Alcotest.fail "expected failing tool name"
  | Ok _ -> Alcotest.fail "injector exception must be explicit"
;;

(* ── Error_domain: pipeline tag_error pattern ─────────────── *)

(** Verify Error_domain functions used by pipeline's tag_error. *)
let test_tag_error_pattern_internal () =
  let err = Error.Internal "pipeline failure" in
  let poly = Error_domain.of_sdk_error err in
  let ctx = Error_domain.with_stage "route" poly in
  let s = Error_domain.ctx_to_string ctx in
  Alcotest.(check bool)
    "stage prefix"
    true
    (let prefix = "[route]" in
     String.length s >= String.length prefix
     && String.sub s 0 (String.length prefix) = prefix)
;;

let test_tag_error_pattern_agent () =
  let err = Error.Agent (UnrecognizedStopReason { reason = "weird" }) in
  let poly = Error_domain.of_sdk_error err in
  let ctx = Error_domain.with_stage "output" poly in
  let s = Error_domain.ctx_to_string ctx in
  Alcotest.(check bool)
    "output stage"
    true
    (let prefix = "[output]" in
     String.length s >= String.length prefix
     && String.sub s 0 (String.length prefix) = prefix)
;;

let test_tag_error_pattern_collect () =
  let err = Error.Api (AuthError { message = "bad key" }) in
  let poly = Error_domain.of_sdk_error err in
  let ctx = Error_domain.with_stage "collect" poly in
  let s = Error_domain.ctx_to_string ctx in
  Alcotest.(check bool)
    "collect stage"
    true
    (let prefix = "[collect]" in
     String.length s >= String.length prefix
     && String.sub s 0 (String.length prefix) = prefix)
;;

(* ── Suite ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "pipeline_deep"
    [ ( "extract_reasoning"
      , [ Alcotest.test_case "multiple messages" `Quick test_reasoning_multiple_messages
        ; Alcotest.test_case "no thinking blocks" `Quick test_reasoning_no_thinking_blocks
        ; Alcotest.test_case
            "no tool rationale inference"
            `Quick
            test_reasoning_no_tool_rationale_inference
        ; Alcotest.test_case
            "no uncertainty marker inference"
            `Quick
            test_reasoning_no_uncertainty_marker_inference
        ; Alcotest.test_case "no uncertainty" `Quick test_reasoning_no_uncertainty
        ] )
    ; ( "resolve_turn_params"
      , [ Alcotest.test_case "no hook" `Quick test_resolve_params_no_hook
        ; Alcotest.test_case "continue uses defaults" `Quick test_resolve_params_continue
        ; Alcotest.test_case "adjust params" `Quick test_resolve_params_adjust
        ; Alcotest.test_case
            "system_prompt_override applied"
            `Quick
            test_resolve_params_system_prompt_override
        ; Alcotest.test_case
            "no system_prompt_override"
            `Quick
            test_resolve_params_no_system_prompt_override
        ; Alcotest.test_case
            "tool results captured"
            `Quick
            test_resolve_params_with_tool_results
        ; Alcotest.test_case
            "error tool results"
            `Quick
            test_resolve_params_error_tool_results
        ] )
    ; ( "context_injection"
      , [ Alcotest.test_case "sets values" `Quick test_context_injection_sets_values
        ; Alcotest.test_case "returns None" `Quick test_context_injection_none
        ; Alcotest.test_case "extra messages" `Quick test_context_injection_extra_messages
        ; Alcotest.test_case "error result" `Quick test_context_injection_error_result
        ; Alcotest.test_case "injector raises" `Quick test_context_injection_raises
        ] )
    ; ( "tag_error_pattern"
      , [ Alcotest.test_case "internal + route" `Quick test_tag_error_pattern_internal
        ; Alcotest.test_case "agent + output" `Quick test_tag_error_pattern_agent
        ; Alcotest.test_case "api + collect" `Quick test_tag_error_pattern_collect
        ] )
    ]
;;

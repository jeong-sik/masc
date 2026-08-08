(** Tests for Agent_turn module — turn preparation and usage. *)

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

let prepared_turn = function
  | Ok prep -> prep
  | Error detail -> Alcotest.fail detail
;;

(* ── prepare_turn tests ────────────────────────────────────── *)

let test_prepare_turn_empty_tools () =
  let prep =
    Agent_turn.prepare_turn
      ~tools:Tool_set.empty
      ~messages:[]
      ~turn_params:Hooks.default_turn_params
      ()
    |> prepared_turn
  in
  Alcotest.(check (option (list reject))) "no tools" None prep.tools_json
;;

let test_prepare_turn_with_tools () =
  let tool =
    Tool.create
      ~strict:true
      ~name:"echo"
      ~description:"Echo"
      ~parameters:
        [ { Types.name = "msg"
          ; description = "m"
          ; param_type = Types.String
          ; required = true
          }
        ]
      (fun _ -> Ok { Types.content = "ok"; _meta = None })
  in
  let prep =
    Agent_turn.prepare_turn
      ~tools:(Tool_set.of_list [ tool ])
      ~messages:[]
      ~turn_params:Hooks.default_turn_params
      ()
    |> prepared_turn
  in
  Alcotest.(check bool)
    "tools present"
    true
    (match prep.tools_json with
     | Some (_ :: _) -> true
     | _ -> false);
  Alcotest.(check bool)
    "strict reaches prepared provider input"
    true
    (match prep.tools_json with
     | Some [ json ] -> Yojson.Safe.Util.(json |> member "strict" |> to_bool)
     | _ -> false)
;;

let test_prepare_turn_preserves_supplied_tools () =
  let tool_a =
    Tool.create ~name:"a" ~description:"A" ~parameters:[] (fun _ ->
      Ok { Types.content = ""; _meta = None })
  in
  let tool_b =
    Tool.create ~name:"b" ~description:"B" ~parameters:[] (fun _ ->
      Ok { Types.content = ""; _meta = None })
  in
  let prep =
    Agent_turn.prepare_turn
      ~tools:(Tool_set.of_list [ tool_a; tool_b ])
      ~messages:[]
      ~turn_params:Hooks.default_turn_params
      ()
    |> prepared_turn
  in
  let count =
    match prep.tools_json with
    | Some l -> List.length l
    | None -> 0
  in
  Alcotest.(check int) "both tools" 2 count;
  Alcotest.(check (list string))
    "visible_tool_names matches caller input"
    [ "a"; "b" ]
    prep.visible_tool_names
;;

(* visible_tool_names mirrors the tool list the LLM actually sees this
   turn — exposed via Event_bus.TurnReady for substrate observability.
   Empty when the caller supplies no tools. *)
let test_prepare_turn_visible_tool_names_empty () =
  let prep =
    Agent_turn.prepare_turn
      ~tools:Tool_set.empty
      ~messages:[]
      ~turn_params:Hooks.default_turn_params
      ()
    |> prepared_turn
  in
  Alcotest.(check (list string)) "empty when no tools" [] prep.visible_tool_names
;;

let test_prepare_turn_visible_tool_names_preserves_order () =
  let make n =
    Tool.create ~name:n ~description:n ~parameters:[] (fun _ ->
      Ok { Types.content = ""; _meta = None })
  in
  let tools = Tool_set.of_list [ make "Bash"; make "Read"; make "Edit" ] in
  let prep =
    Agent_turn.prepare_turn ~tools ~messages:[] ~turn_params:Hooks.default_turn_params ()
    |> prepared_turn
  in
  Alcotest.(check (list string))
    "registry order preserved"
    [ "Bash"; "Read"; "Edit" ]
    prep.visible_tool_names
;;

(* ── prepare_messages tests ────────────────────────────────── *)

let test_prepare_messages_no_reducer () =
  let msgs =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let result =
    Agent_turn.prepare_messages ~messages:msgs ~turn_params:Hooks.default_turn_params ()
  in
  Alcotest.(check int) "same count" 1 (List.length result)
;;

let test_prepare_messages_extra_context () =
  let msgs =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let turn_params =
    { Hooks.default_turn_params with extra_system_context = Some "You are in test mode." }
  in
  let result = Agent_turn.prepare_messages ~messages:msgs ~turn_params () in
  Alcotest.(check int) "appended system context" 2 (List.length result);
  let carrier = List.nth result 1 in
  Alcotest.(check bool) "is User role" true (carrier.role = Types.User);
  Alcotest.(check bool)
    "typed provenance is present"
    true
    (Types.Extra_system_context_provenance.classify carrier.metadata
     = Types.Extra_system_context_provenance.Present);
  let provenance_key =
    match Types.Extra_system_context_provenance.metadata with
    | [ (key, `Bool true) ] -> key
    | _ -> Alcotest.fail "provenance metadata shape drifted"
  in
  Alcotest.(check bool)
    "missing provenance is explicit"
    true
    (Types.Extra_system_context_provenance.classify []
     = Types.Extra_system_context_provenance.Absent);
  Alcotest.(check bool)
    "malformed provenance is explicit"
    true
    (Types.Extra_system_context_provenance.classify [ provenance_key, `Bool false ]
     = Types.Extra_system_context_provenance.Invalid);
  Alcotest.(check bool)
    "duplicate provenance is explicit"
    true
    (Types.Extra_system_context_provenance.classify (carrier.metadata @ carrier.metadata)
     = Types.Extra_system_context_provenance.Duplicate);
  match carrier.content with
  | [ Types.Text "[system context] You are in test mode." ] -> ()
  | _ -> Alcotest.fail "expected single Text block"
;;

(* ── system_prompt_override does not affect prepare_messages ── *)

let test_prepare_messages_system_prompt_override_noop () =
  let msgs =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let turn_params =
    { Hooks.default_turn_params with
      system_prompt_override = Some "Custom system prompt"
    }
  in
  let result = Agent_turn.prepare_messages ~messages:msgs ~turn_params () in
  (* system_prompt_override is handled in pipeline stage_parse, not
     in prepare_messages. Message count should remain unchanged. *)
  Alcotest.(check int) "no extra message from override" 1 (List.length result)
;;

let test_prepare_messages_both_override_and_extra_context () =
  let msgs =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let turn_params =
    { Hooks.default_turn_params with
      extra_system_context = Some "Debug mode on."
    ; system_prompt_override = Some "You are a reviewer."
    }
  in
  let result = Agent_turn.prepare_messages ~messages:msgs ~turn_params () in
  (* extra_system_context injects a User message; system_prompt_override
     is applied separately in pipeline. So only extra_system_context
     adds a message here. *)
  Alcotest.(check int) "extra context adds 1 message" 2 (List.length result);
  let carrier = List.nth result 1 in
  Alcotest.(check bool) "injected msg is User" true (carrier.role = Types.User);
  Alcotest.(check bool)
    "typed provenance is present"
    true
    (Types.Extra_system_context_provenance.classify carrier.metadata
     = Types.Extra_system_context_provenance.Present);
  match carrier.content with
  | [ Types.Text _ ] -> ()
  | _ -> Alcotest.fail "expected single Text block"
;;

let starts_with ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0
    then true
    else if idx + needle_len > haystack_len
    then false
    else if String.sub haystack idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  loop 0
;;

let message_text_exn (msg : Types.message) =
  match msg.content with
  | [ Types.Text text ] -> text
  | _ -> Alcotest.fail "expected single text message"
;;

(* ── accumulate_usage tests ──────────────────────────────── *)

let test_accumulate_usage_with_response () =
  let current = Types.empty_usage in
  let response_usage : Types.api_usage =
    { input_tokens = 100
    ; output_tokens = 50
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:Anthropic
      ~provider_id:"anthropic"
      ~model_id:"claude-sonnet-4-6"
      ~base_url:"https://api.anthropic.com"
      ()
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:(Some provider_config)
      ~response_model:(Some "claude-sonnet-4-6")
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check int) "input tokens" 100 result.total_input_tokens;
  Alcotest.(check int) "output tokens" 50 result.total_output_tokens;
  Alcotest.(check bool) "cost > 0" true (result.estimated_cost_usd > 0.0)
;;

let test_accumulate_usage_none_response () =
  let current = { Types.empty_usage with api_calls = 2 } in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:None
      ~response_model:None
      ~response_usage:None
  in
  Alcotest.(check int) "api_calls incremented" 3 result.api_calls
;;

let test_accumulate_usage_local_pricing () =
  let current = Types.empty_usage in
  let response_usage : Types.api_usage =
    { input_tokens = 1000
    ; output_tokens = 500
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:OpenAI_compat
      ~provider_id:"local"
      ~model_id:"dashscope-3.5"
      ~base_url:"http://localhost:8085"
      ()
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:(Some provider_config)
      ~response_model:(Some "dashscope-3.5")
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check (float 0.001)) "local is free" 0.0 result.estimated_cost_usd
;;

let test_accumulate_usage_prefers_response_cost () =
  let current = Types.empty_usage in
  let response_usage : Types.api_usage =
    { input_tokens = 100
    ; output_tokens = 50
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = Some 0.4321
    }
  in
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:Anthropic
      ~provider_id:"anthropic"
      ~model_id:"claude-sonnet-4-6"
      ~base_url:"https://api.anthropic.com"
      ()
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:(Some provider_config)
      ~response_model:(Some "claude-sonnet-4-6")
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check (float 0.0001)) "uses response cost" 0.4321 result.estimated_cost_usd
;;

let test_accumulate_usage_uses_typed_provider_and_response_model () =
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:OpenAI_compat
      ~provider_id:"deepseek"
      ~model_id:"configured-model-before-provider-rotation"
      ~base_url:"https://api.deepseek.com"
      ()
  in
  let response_usage : Types.api_usage =
    { input_tokens = 1_000_000
    ; output_tokens = 1_000_000
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:Types.empty_usage
      ~provider_config:(Some provider_config)
      ~response_model:(Some "deepseek-v4-pro")
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check (float 0.0001))
    "exact provider and returned model price"
    1.305
    result.estimated_cost_usd;
  Alcotest.(check (option reject)) "no pricing gap" None result.pricing_gap
;;

let test_accumulate_usage_records_incomplete_cache_pricing () =
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:DashScope
      ~model_id:"dashscope-3.5"
      ~base_url:"https://dashscope.invalid"
      ()
  in
  let response_usage : Types.api_usage =
    { input_tokens = 100
    ; output_tokens = 10
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 50
    ; cost_usd = None
    }
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:Types.empty_usage
      ~provider_config:(Some provider_config)
      ~response_model:(Some "dashscope-3.5")
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check (float 0.0001)) "no invented cost" 0.0 result.estimated_cost_usd;
  match result.pricing_gap with
  | Some (Types.Pricing_unavailable "dashscope-3.5") -> ()
  | Some gap -> Alcotest.failf "unexpected pricing gap: %s" (Types.show_pricing_gap gap)
  | None -> Alcotest.fail "missing explicit pricing gap"
;;

(* ── make_tool_results tests ─────────────────────────────── *)

let test_make_tool_results () =
  let results =
    [ { Agent_tools.invocation = invocation "t1"
      ; tool_name = "tool-1"
      ; input = `Null
      ; content = "success output"
      ; outcome = Tool_succeeded
      }
    ; { invocation = invocation "t2"
      ; tool_name = "tool-2"
      ; input = `Null
      ; content = "error msg"
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Recoverable_tool_error
            ; error_class = Some Types.Deterministic
            }
      }
    ]
  in
  let blocks = Agent_turn.make_tool_results results in
  Alcotest.(check int) "2 results" 2 (List.length blocks);
  match List.hd blocks with
  | Types.ToolResult { tool_use_id; outcome; _ } ->
    Alcotest.(check string) "id" "t1" tool_use_id;
    Alcotest.(check bool) "not error" false (Types.tool_result_outcome_is_error outcome);
    (match List.nth blocks 1 with
     | Types.ToolResult
         { outcome =
             Tool_failed
               { failure_kind = Types.Recoverable_tool_error
               ; error_class = Some Types.Deterministic
               }
         ; _
         } -> ()
     | _ -> Alcotest.fail "expected second ToolResult")
  | _ -> Alcotest.fail "expected ToolResult"
;;

(* ── accumulate_usage: no provider ──────────────────────── *)

let test_accumulate_usage_no_provider () =
  let current = Types.empty_usage in
  let response_usage : Types.api_usage =
    { input_tokens = 200
    ; output_tokens = 100
    ; cache_creation_input_tokens = 10
    ; cache_read_input_tokens = 5
    ; cost_usd = None
    }
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:None
      ~response_model:None
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check int) "input" 200 result.total_input_tokens;
  Alcotest.(check int) "output" 100 result.total_output_tokens;
  Alcotest.(check int) "cache_create" 10 result.total_cache_creation_input_tokens;
  Alcotest.(check int) "cache_read" 5 result.total_cache_read_input_tokens
;;

(* ── accumulate_usage: cumulative ───────────────────────── *)

let test_accumulate_usage_cumulative () =
  let current =
    { Types.empty_usage with
      total_input_tokens = 100
    ; total_output_tokens = 50
    ; api_calls = 1
    }
  in
  let response_usage : Types.api_usage =
    { input_tokens = 200
    ; output_tokens = 100
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  let result =
    Agent_turn.accumulate_usage
      ~current_usage:current
      ~provider_config:None
      ~response_model:None
      ~response_usage:(Some response_usage)
  in
  Alcotest.(check int) "cumulative input" 300 result.total_input_tokens;
  Alcotest.(check int) "cumulative output" 150 result.total_output_tokens
;;

(* ── apply_context_injection ─────────────────────────────── *)

let make_tool_use name input =
  Types.ToolUse { id = "t1"; name; input = Yojson.Safe.from_string input }
;;

let test_apply_context_injection_no_injector () =
  let context = Context.create_sync () in
  let messages =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let tool_uses =
    [ Types.ToolUse { id = "t1"; name = "search"; input = `Assoc [ "q", `String "test" ] }
    ]
  in
  let results =
    [ { Agent_tools.invocation = invocation "t1"
      ; tool_name = "search"
      ; input = `Assoc [ "q", `String "test" ]
      ; content = "result"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ = None in
  let new_msgs =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  Alcotest.(check int) "unchanged" 1 (List.length new_msgs)
;;

let test_apply_context_injection_with_context_update () =
  let context = Context.create_sync () in
  let messages =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let tool_uses = [ make_tool_use "search" {|{"q":"test"}|} ] in
  let results =
    [ { Agent_tools.invocation = invocation "t1"
      ; tool_name = "search"
      ; input = `Assoc [ "q", `String "test" ]
      ; content = "found it"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ =
    Some
      { Hooks.context_updates = [ "last_result", `String "found it" ]
      ; extra_messages = []
      }
  in
  let _new_msgs =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  (* Check context was updated *)
  match Context.get context "last_result" with
  | Some (`String "found it") -> ()
  | _ -> Alcotest.fail "expected context update"
;;

let test_apply_context_injection_with_extra_messages () =
  let context = Context.create_sync () in
  let messages =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let tool_uses = [ make_tool_use "search" {|{"q":"test"}|} ] in
  let results =
    [ { Agent_tools.invocation = invocation "t1"
      ; tool_name = "search"
      ; input = `Assoc [ "q", `String "test" ]
      ; content = "result"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ =
    Some
      { Hooks.context_updates = []
      ; extra_messages =
          [ { Types.role = Types.User
            ; content = [ Types.Text "injected" ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
          ]
      }
  in
  let new_msgs =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  Alcotest.(check int) "same-role message preserved" 2 (List.length new_msgs)
;;

let test_apply_context_injection_exception_is_error () =
  let context = Context.create_sync () in
  let messages =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let tool_uses = [ make_tool_use "search" {|{"q":"test"}|} ] in
  let results =
    [ { Agent_tools.invocation = invocation "t1"
      ; tool_name = "search"
      ; input = `Assoc [ "q", `String "test" ]
      ; content = "result"
      ; outcome = Tool_succeeded
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output:_ = failwith "injector crashed" in
  match
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
  with
  | Error { tool_name = Some "search"; detail } ->
    Alcotest.(check bool)
      "exception detail"
      true
      (String.starts_with ~prefix:"Failure(\"injector crashed\")" detail)
  | Error _ -> Alcotest.fail "expected failing tool name"
  | Ok _ -> Alcotest.fail "injector exception must be explicit"
;;

let test_apply_context_injection_preserves_non_retryable_error () =
  let context = Context.create_sync () in
  let messages =
    [ { Types.role = Types.User
      ; content = [ Types.Text "hi" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let tool_uses = [ make_tool_use "search" {|{"q":"test"}|} ] in
  let received_output = ref None in
  let results =
    [ { Agent_tools.invocation = invocation "t1"
      ; tool_name = "search"
      ; input = `Assoc [ "q", `String "test" ]
      ; content = "fatal"
      ; outcome =
          Tool_failed
            { failure_kind = Agent_tools.Non_retryable_tool_error
            ; error_class = Some Types.Deterministic
            }
      }
    ]
  in
  let injector ~tool_name:_ ~input:_ ~output =
    received_output := Some output;
    None
  in
  let _new_msgs =
    Agent_turn.apply_context_injection ~context ~messages ~injector ~tool_uses ~results
    |> context_messages
  in
  match !received_output with
  | Some (Error { message; recoverable; error_class }) ->
    Alcotest.(check string) "message" "fatal" message;
    Alcotest.(check bool) "recoverable false" false recoverable;
    (match error_class with
     | Some Types.Deterministic -> ()
     | _ -> Alcotest.fail "expected deterministic error_class")
  | Some (Ok _) -> Alcotest.fail "expected Error output"
  | None -> Alcotest.fail "injector not called"
;;

(* ── resolve_turn_params ──────────────────────────────────── *)

let expect_turn_params = function
  | Ok params -> params
  | Error _ -> Alcotest.fail "expected resolved turn params"
;;

let test_resolve_turn_params_no_hook () =
  let hooks = Hooks.empty in
  let invoke_hook ~hook_name:_ _h _input = Hooks.Continue in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages:[] ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check (option reject)) "default temperature" None params.temperature
;;

let test_resolve_turn_params_with_hook () =
  let custom_params = { Hooks.default_turn_params with temperature = Some 0.5 } in
  let hook _input = Hooks.AdjustParams custom_params in
  let hooks = { Hooks.empty with before_turn_params = Some hook } in
  let invoke_hook ~hook_name:_ h input =
    match h with
    | Some f -> f input
    | None -> Hooks.Continue
  in
  let params =
    Agent_turn.resolve_turn_params ~hooks ~messages:[] ~turn:0 ~invoke_hook
    |> expect_turn_params
  in
  Alcotest.(check (option (float 0.01))) "custom temp" (Some 0.5) params.temperature
;;

(* ── Test runner ────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Agent_turn"
    [ ( "prepare_turn"
      , [ Alcotest.test_case "empty tools" `Quick test_prepare_turn_empty_tools
        ; Alcotest.test_case "with tools" `Quick test_prepare_turn_with_tools
        ; Alcotest.test_case
            "preserves supplied tools"
            `Quick
            test_prepare_turn_preserves_supplied_tools
        ; Alcotest.test_case
            "visible_tool_names empty"
            `Quick
            test_prepare_turn_visible_tool_names_empty
        ; Alcotest.test_case
            "visible_tool_names preserves order"
            `Quick
            test_prepare_turn_visible_tool_names_preserves_order
        ] )
    ; ( "prepare_messages"
      , [ Alcotest.test_case
            "preserves transcript"
            `Quick
            test_prepare_messages_no_reducer
        ; Alcotest.test_case "extra context" `Quick test_prepare_messages_extra_context
        ; Alcotest.test_case
            "system_prompt_override noop"
            `Quick
            test_prepare_messages_system_prompt_override_noop
        ; Alcotest.test_case
            "both override and extra_context"
            `Quick
            test_prepare_messages_both_override_and_extra_context
        ] )
    ; ( "accumulate_usage"
      , [ Alcotest.test_case "with response" `Quick test_accumulate_usage_with_response
        ; Alcotest.test_case "none response" `Quick test_accumulate_usage_none_response
        ; Alcotest.test_case "local pricing" `Quick test_accumulate_usage_local_pricing
        ; Alcotest.test_case
            "prefers response cost"
            `Quick
            test_accumulate_usage_prefers_response_cost
        ; Alcotest.test_case
            "typed provider and response model"
            `Quick
            test_accumulate_usage_uses_typed_provider_and_response_model
        ; Alcotest.test_case
            "incomplete cache pricing"
            `Quick
            test_accumulate_usage_records_incomplete_cache_pricing
        ; Alcotest.test_case "no provider" `Quick test_accumulate_usage_no_provider
        ; Alcotest.test_case "cumulative" `Quick test_accumulate_usage_cumulative
        ] )
    ; ( "make_tool_results"
      , [ Alcotest.test_case "tool results" `Quick test_make_tool_results ] )
    ; ( "apply_context_injection"
      , [ Alcotest.test_case "no injector" `Quick test_apply_context_injection_no_injector
        ; Alcotest.test_case
            "context update"
            `Quick
            test_apply_context_injection_with_context_update
        ; Alcotest.test_case
            "extra messages"
            `Quick
            test_apply_context_injection_with_extra_messages
        ; Alcotest.test_case
            "exception is explicit"
            `Quick
            test_apply_context_injection_exception_is_error
        ; Alcotest.test_case
            "preserves non-retryable error"
            `Quick
            test_apply_context_injection_preserves_non_retryable_error
        ] )
    ; ( "resolve_turn_params"
      , [ Alcotest.test_case "no hook" `Quick test_resolve_turn_params_no_hook
        ; Alcotest.test_case "with hook" `Quick test_resolve_turn_params_with_hook
        ] )
    ]
;;

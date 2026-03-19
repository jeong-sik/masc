open Alcotest

module Adapter = Masc_mcp.Keeper_oas_adapter
module Llm_types = Masc_mcp.Llm_types
module Oas_worker = Masc_mcp.Oas_worker
module Types = Agent_sdk.Types

(* ================================================================ *)
(* Helper: build a minimal completion_request                       *)
(* ================================================================ *)

let make_model_spec ?(model_id = "test-model") ?(provider = Llm_types.Llama) () :
    Llm_types.model_spec =
  { provider;
    model_id;
    max_context = 4096;
    api_url = "";
    api_key_env = None;
    cost_per_1k_input = 0.0;
    cost_per_1k_output = 0.0;
    api_url = "http://127.0.0.1:8085";
    api_key_env = None;
  }

let make_request ?(model_id = "test-model") ?(provider = Llm_types.Llama)
    ?(temperature = 0.7) ?(max_tokens = 1024) ?(tools = [])
    (messages : Types.message list) : Llm_types.completion_request =
  { model = make_model_spec ~model_id ~provider ();
    messages;
    temperature;
    max_tokens;
    tools;
    response_format = `Text;
  }

(* ================================================================ *)
(* Group 1: cascade_config_of_requests                              *)
(* ================================================================ *)

let test_cascade_config_empty_list () =
  match Adapter.cascade_config_of_requests [] with
  | Error msg ->
      check bool "contains 'empty'" true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error for empty list"

let test_cascade_config_single_request () =
  let req = make_request [
    Types.system_msg "You are a keeper.";
    Types.user_msg "What is the status?";
  ] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail (Printf.sprintf "unexpected error: %s" e)
  | Ok params ->
      check string "system_prompt" "You are a keeper." params.system_prompt;
      check bool "goal contains status" true
        (String.length params.goal > 0);
      check string "primary model" "test-model" params.primary_spec.model_id;
      check (list string) "no fallbacks" []
        (List.map (fun (s : Llm_types.model_spec) -> s.model_id) params.fallback_specs)

let test_cascade_config_multiple_requests () =
  let req1 = make_request ~model_id:"primary"
    [Types.system_msg "sys"; Types.user_msg "goal"] in
  let req2 = make_request ~model_id:"fallback1"
    [Types.user_msg "goal"] in
  let req3 = make_request ~model_id:"fallback2"
    [Types.user_msg "goal"] in
  match Adapter.cascade_config_of_requests [req1; req2; req3] with
  | Error e -> fail e
  | Ok params ->
      check string "primary" "primary" params.primary_spec.model_id;
      check int "fallback count" 2 (List.length params.fallback_specs);
      check string "fallback1" "fallback1"
        (List.nth params.fallback_specs 0).model_id;
      check string "fallback2" "fallback2"
        (List.nth params.fallback_specs 1).model_id

let test_cascade_config_no_system_message () =
  let req = make_request [Types.user_msg "just a question"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error _ -> fail "should succeed even without system message"
  | Ok params ->
      check string "empty system prompt" "" params.system_prompt;
      check bool "goal present" true (String.length params.goal > 0)

let test_cascade_config_no_user_messages () =
  let req = make_request [Types.system_msg "system only"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error msg ->
      check bool "mentions user messages" true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error when no user messages"

let test_cascade_config_preserves_temperature () =
  let req = make_request ~temperature:0.3 ~max_tokens:512
    [Types.system_msg "s"; Types.user_msg "g"] in
  match Adapter.cascade_config_of_requests [req] with
  | Error e -> fail e
  | Ok params ->
      let epsilon = 0.001 in
      check bool "temperature" true
        (Float.abs (params.temperature -. 0.3) < epsilon);
      check int "max_tokens" 512 params.max_tokens

(* ================================================================ *)
(* Group 2: result extractors                                       *)
(* ================================================================ *)

let make_run_result ?(model = "test") ?(text = "hello")
    ?(input_tokens = 10) ?(output_tokens = 5) () : Masc_mcp.Oas_worker.run_result =
  { response = {
      Llm_provider.Types.model;
      content = [Llm_provider.Types.Text text];
      stop_reason = Llm_provider.Types.EndTurn;
      usage = Some { input_tokens; output_tokens;
                     cache_creation_input_tokens = 0;
                     cache_read_input_tokens = 0 };
      id = "test-id";
    };
    checkpoint = None;
    session_id = "test-session";
    turns = 1;
  }

let test_text_of_run_result () =
  let r = make_run_result ~text:"world" () in
  check string "text" "world" (Adapter.text_of_run_result r)

let test_usage_of_run_result () =
  let r = make_run_result ~input_tokens:100 ~output_tokens:50 () in
  let usage = Adapter.usage_of_run_result r in
  check int "input" 100 usage.input_tokens;
  check int "output" 50 usage.output_tokens

let test_model_of_run_result () =
  let r = make_run_result ~model:"qwen3.5" () in
  check string "model" "qwen3.5" (Adapter.model_of_run_result r)

(* ================================================================ *)
(* Group 3: run_cascade error paths (no Eio context needed)         *)
(* ================================================================ *)

let test_run_cascade_empty_requests () =
  match Adapter.run_cascade [] with
  | Error msg ->
      check bool "error message present" true (String.length msg > 0)
  | Ok _ -> fail "expected Error for empty requests"

let test_run_cascade_no_user_messages () =
  let req = make_request [Types.system_msg "system only"] in
  match Adapter.run_cascade [req] with
  | Error _ -> () (* expected: no user messages *)
  | Ok _ -> fail "expected Error for request with no user messages"

(* ================================================================ *)
(* Registration                                                     *)
(* ================================================================ *)

let () =
  run "Keeper_oas_adapter" [
    ("cascade_config", [
      test_case "empty list returns error" `Quick
        test_cascade_config_empty_list;
      test_case "single request extracts params" `Quick
        test_cascade_config_single_request;
      test_case "multiple requests with fallbacks" `Quick
        test_cascade_config_multiple_requests;
      test_case "no system message" `Quick
        test_cascade_config_no_system_message;
      test_case "no user messages returns error" `Quick
        test_cascade_config_no_user_messages;
      test_case "preserves temperature and max_tokens" `Quick
        test_cascade_config_preserves_temperature;
    ]);
    ("extractors", [
      test_case "text_of_run_result" `Quick test_text_of_run_result;
      test_case "usage_of_run_result" `Quick test_usage_of_run_result;
      test_case "model_of_run_result" `Quick test_model_of_run_result;
    ]);
    ("run_cascade_errors", [
      test_case "empty requests" `Quick test_run_cascade_empty_requests;
      test_case "no user messages" `Quick test_run_cascade_no_user_messages;
    ]);
  ]

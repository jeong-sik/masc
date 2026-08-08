(** Tests for API dispatch: response parsing per provider and pricing. *)

open Alcotest
open Agent_sdk

(* ── Helpers ─────────────────────────────────────────────────── *)

let declared_pricing model_id =
  match Llm_provider.Pricing.pricing_for_model_opt model_id with
  | Some pricing -> pricing
  | None -> failf "expected catalog pricing for %S" model_id
;;

let require_estimated_cost = function
  | Llm_provider.Pricing.Estimated cost -> cost
  | Llm_provider.Pricing.Incomplete _ -> fail "expected an exact cost estimate"
;;

(* ── Anthropic parse_response ────────────────────────────────── *)

let test_anthropic_parse_response () =
  let mock_json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_test",
    "type": "message",
    "role": "assistant",
    "model": "claude-sonnet-4-6",
    "content": [{"type": "text", "text": "Hello back"}],
    "stop_reason": "end_turn",
    "usage": {"input_tokens": 10, "output_tokens": 5,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0}
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response mock_json in
  check string "id" "msg_test" resp.id;
  check string "model" "claude-sonnet-4-6" resp.model;
  (match resp.stop_reason with
   | Types.EndTurn -> ()
   | _ -> fail "expected EndTurn");
  match resp.content with
  | [ Types.Text "Hello back" ] -> ()
  | _ -> fail "expected single text block"
;;

(* ── Openai parse_response ───────────────────────────────────── *)

let test_openai_parse_response () =
  let mock_body =
    {|{
    "id": "chatcmpl-test",
    "object": "chat.completion",
    "model": "gpt",
    "choices": [{
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Openai response"
      },
      "finish_reason": "stop"
    }],
    "usage": {"prompt_tokens": 10, "completion_tokens": 5,
              "total_tokens": 15}
  }|}
  in
  let resp =
    match Llm_provider.Backend_openai_parse.parse_openai_response_result mock_body with
    | Ok r -> r
    | Error msg -> failwith (Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  in
  check string "model" "gpt" resp.model;
  (match resp.stop_reason with
   | Types.EndTurn -> ()
   | _ -> fail "expected EndTurn from stop");
  match resp.content with
  | [ Types.Text "Openai response" ] -> ()
  | _ -> fail "expected single text block"
;;

(* ── Pricing ─────────────────────────────────────────────────── *)

let test_pricing_known_models () =
  let p_opus = declared_pricing "claude-opus-4-6" in
  check (float 0.01) "opus input" 15.0 p_opus.input_per_million;
  let p_gpt4o = declared_pricing "gpt" in
  check (float 0.01) "gpt4o input" 2.5 p_gpt4o.input_per_million;
  let p_mini = declared_pricing "gpt-mini" in
  check (float 0.01) "mini input" 0.15 p_mini.input_per_million;
  check
    bool
    "catalog zero remains declared despite absent cache multipliers"
    true
    (match Llm_provider.Pricing.pricing_for_model_opt "dashscope-3.5-35b" with
     | Some
         { input_per_million = 0.0
         ; output_per_million = 0.0
         ; cache_write_multiplier = None
         ; cache_read_multiplier = None
         } -> true
     | Some _ | None -> false);
  check
    bool
    "undeclared local model remains unpriced"
    true
    (Option.is_none (Llm_provider.Pricing.pricing_for_model_opt "llama-3.1-70b"))
;;

let test_pricing_cost_estimation () =
  let pricing =
    { Llm_provider.Pricing.input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = Some 1.25
    ; cache_read_multiplier = Some 0.1
    }
  in
  let cost =
    Llm_provider.Pricing.estimate_cost
      ~pricing
      ~input_tokens:1_000_000
      ~output_tokens:100_000
      ()
    |> require_estimated_cost
  in
  check (float 0.01) "cost" 4.5 cost
;;

(* ── Adversarial: malformed usage JSON ────────────────────────── *)

let test_anthropic_missing_usage () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_001",
    "model": "claude-sonnet-4-6",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": "hello"}],
    "usage": null
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | None -> ()
  | Some _ -> fail "expected None usage"
;;

let test_anthropic_empty_content () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_002",
    "model": "claude-sonnet-4-6",
    "stop_reason": "end_turn",
    "content": [],
    "usage": {"input_tokens": 10, "output_tokens": 5,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0}
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  check int "empty content" 0 (List.length resp.content)
;;

let test_anthropic_cache_usage_parsing () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_003",
    "model": "claude-sonnet-4-6",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": "cached"}],
    "usage": {
      "input_tokens": 1000,
      "output_tokens": 200,
      "cache_creation_input_tokens": 500,
      "cache_read_input_tokens": 300
    }
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | None -> fail "expected usage"
  | Some u ->
    check int "input" 1000 u.input_tokens;
    check int "output" 200 u.output_tokens;
    check int "cache write" 500 u.cache_creation_input_tokens;
    check int "cache read" 300 u.cache_read_input_tokens
;;

(* ── Cache-aware cost estimation ─────────────────────────────── *)

let test_cache_cost_calculation () =
  let pricing = declared_pricing "claude-sonnet-4-6" in
  (* Sonnet: 3.0/M input, 15.0/M output, cache_write=1.25x, cache_read=0.1x *)
  let cost =
    Llm_provider.Pricing.estimate_cost
      ~pricing
      ~input_tokens:1_000_000
      ~output_tokens:0
      ~cache_creation_input_tokens:500_000
      ~cache_read_input_tokens:300_000
      ()
    |> require_estimated_cost
  in
  (* regular = 1M - 500K - 300K = 200K -> 200K * 3.0/1M = 0.6
     cache_write = 500K * 3.0/1M * 1.25 = 1.875
     cache_read  = 300K * 3.0/1M * 0.1  = 0.09
     total = 0.6 + 1.875 + 0.09 = 2.565 *)
  check (float 0.001) "cache cost" 2.565 cost
;;

let test_cache_cost_no_cache_tokens () =
  let pricing = declared_pricing "claude-sonnet-4-6" in
  let cost_with =
    Llm_provider.Pricing.estimate_cost
      ~pricing
      ~input_tokens:1_000_000
      ~output_tokens:100_000
      ()
    |> require_estimated_cost
  in
  let cost_explicit =
    Llm_provider.Pricing.estimate_cost
      ~pricing
      ~input_tokens:1_000_000
      ~output_tokens:100_000
      ~cache_creation_input_tokens:0
      ~cache_read_input_tokens:0
      ()
    |> require_estimated_cost
  in
  check (float 0.0001) "zero cache same as default" cost_with cost_explicit
;;

let test_cache_multipliers_for_non_anthropic () =
  let pricing = declared_pricing "gpt" in
  (* Openai: no cache pricing, multipliers are 1.0 *)
  check
    (option (float 0.001))
    "no cache write discount"
    (Some 1.0)
    pricing.cache_write_multiplier;
  check
    (option (float 0.001))
    "no cache read discount"
    (Some 1.0)
    pricing.cache_read_multiplier
;;

(* ── Test runner ─────────────────────────────────────────────── *)

let () =
  run
    "api_dispatch"
    [ "anthropic", [ test_case "parse response" `Quick test_anthropic_parse_response ]
    ; "openai", [ test_case "parse response" `Quick test_openai_parse_response ]
    ; ( "pricing"
      , [ test_case "known models" `Quick test_pricing_known_models
        ; test_case "cost estimation" `Quick test_pricing_cost_estimation
        ; test_case "cache cost calculation" `Quick test_cache_cost_calculation
        ; test_case "cache cost zero default" `Quick test_cache_cost_no_cache_tokens
        ; test_case
            "non-anthropic cache multipliers"
            `Quick
            test_cache_multipliers_for_non_anthropic
        ] )
    ; ( "adversarial"
      , [ test_case "missing usage" `Quick test_anthropic_missing_usage
        ; test_case "empty content" `Quick test_anthropic_empty_content
        ; test_case "cache usage parsing" `Quick test_anthropic_cache_usage_parsing
        ] )
    ]
;;

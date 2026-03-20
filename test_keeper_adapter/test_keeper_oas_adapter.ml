open Alcotest

module Adapter = Masc_mcp.Keeper_oas_adapter
module Cascade = Masc_mcp.Cascade
module Types = Agent_sdk.Types

(* ================================================================ *)
(* Helper: build a minimal completion_request                       *)
(* ================================================================ *)

(* ================================================================ *)
(* Group 1: result extractors                                       *)
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
(* Registration                                                     *)
(* ================================================================ *)

let () =
  run "Keeper_oas_adapter" [
    ("extractors", [
      test_case "text_of_run_result" `Quick test_text_of_run_result;
      test_case "usage_of_run_result" `Quick test_usage_of_run_result;
      test_case "model_of_run_result" `Quick test_model_of_run_result;
    ]);
  ]

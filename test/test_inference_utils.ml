open Alcotest
open Masc

let test_elapsed_duration_ms_rounds_positive_sub_ms_to_one () =
  check int "positive sub-ms" 1 (Inference_utils.elapsed_duration_ms 0.0004)

let test_elapsed_duration_ms_preserves_integer_floor () =
  check int "floor larger interval" 12
    (Inference_utils.elapsed_duration_ms 0.0129)

let test_elapsed_duration_ms_keeps_non_positive_zero () =
  check int "zero" 0 (Inference_utils.elapsed_duration_ms 0.0);
  check int "negative" 0 (Inference_utils.elapsed_duration_ms (-0.001))

let test_elapsed_duration_ms_rejects_non_finite () =
  check int "nan" 0 (Inference_utils.elapsed_duration_ms nan);
  check int "infinity" 0 (Inference_utils.elapsed_duration_ms infinity)

(* Canonical-projection consumption drift-guards (oas roadmap F4 / F12).
   MASC delegates its zero-usage markers and token arithmetic to OAS so the
   api_usage SSOT lives in one place. These trip if a divergent re-spelled
   literal is ever re-introduced on the MASC side. *)

let test_zero_usage_tracks_oas_canonical () =
  check bool "Inference_utils.zero_usage = OAS zero_api_usage" true
    (Inference_utils.zero_usage = Agent_sdk.Types.zero_api_usage);
  check bool "Keeper_hooks_oas_types.zero_usage = OAS zero_api_usage" true
    (Keeper_hooks_oas_types.zero_usage = Agent_sdk.Types.zero_api_usage)

let test_total_tokens_parity_and_excludes_cache () =
  let sample : Agent_sdk.Types.api_usage =
    {
      Agent_sdk.Types.input_tokens = 7;
      output_tokens = 5;
      cache_creation_input_tokens = 3;
      cache_read_input_tokens = 2;
      cost_usd = Some 0.01;
    }
  in
  (* input + output only — cache tokens are excluded by the projection. *)
  check int "total_tokens excludes cache tokens" 12
    (Inference_utils.total_tokens sample);
  check int "total_tokens parity with OAS projection"
    (Agent_sdk.Types.total_tokens sample)
    (Inference_utils.total_tokens sample)

let test_utf8_sanitization_preserves_tool_failure_provenance () =
  let open Agent_sdk.Types in
  let message : message =
    {
      role = Tool;
      content =
        [
          ToolResult
            {
              tool_use_id = "tool-\255";
              content = "failure-\255";
              outcome =
                Tool_failed
                  {
                    failure_kind = Validation_error;
                    error_class = Some Deterministic;
                  };
              json = None;
              content_blocks = None;
            };
        ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  match (Inference_utils.sanitize_message_utf8 message).content with
  | [ ToolResult { outcome; _ } ] ->
      check bool "failure provenance preserved" true
        (outcome
         = Tool_failed
             {
               failure_kind = Validation_error;
               error_class = Some Deterministic;
             })
  | _ -> fail "expected one ToolResult"

let () =
  Alcotest.run "Inference_utils"
    [
      ( "timing",
        [
          test_case "positive sub-ms intervals round up" `Quick
            test_elapsed_duration_ms_rounds_positive_sub_ms_to_one;
          test_case "larger intervals use integer floor" `Quick
            test_elapsed_duration_ms_preserves_integer_floor;
          test_case "non-positive intervals stay zero" `Quick
            test_elapsed_duration_ms_keeps_non_positive_zero;
          test_case "non-finite intervals stay zero" `Quick
            test_elapsed_duration_ms_rejects_non_finite;
        ] );
      ( "canonical projection consumption",
        [
          test_case "zero_usage markers track OAS canonical" `Quick
            test_zero_usage_tracks_oas_canonical;
          test_case "total_tokens parity, excludes cache tokens" `Quick
            test_total_tokens_parity_and_excludes_cache;
        ] );
      ( "tool result sanitation",
        [
          test_case "typed failure provenance survives UTF-8 sanitation" `Quick
            test_utf8_sanitization_preserves_tool_failure_provenance;
        ] );
    ]

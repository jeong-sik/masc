(** oas#2621 end-to-end regression: an empty completion whose OpenAI/GLM wire
    [finish_reason] is the overflow token must classify as
    [Retry.ContextOverflow], not provider-unavailability.

    The pre-existing attribution suite injected a PRE-TYPED
    [Types.ContextWindowExceeded] straight into [empty_completion_error], so it
    never exercised the wire decoder ([Stop_reason_wire]) or the OpenAI/GLM
    parsers that actually produce that stop_reason from a raw provider response.
    That left the wire root untested: [wire_finish_of_string] mapped the
    overflow token to [Other _ -> Types.Unknown], and GLM dropped the
    stop_reason entirely, so the #2659/#2696 [overflow_of_empty_completion]
    classifier was unreachable on the real path while the suite stayed green.

    This suite drives the raw wire [finish_reason] string through the real
    parse paths (both OpenAI-compatible and GLM) and asserts the resulting
    typed [stop_reason] reaches the classifier as [ContextOverflow]. *)

open Agent_sdk
module Http = Llm_provider.Http_client
module Types = Llm_provider.Types
module Wire = Llm_provider.Stop_reason_wire
module Parse = Llm_provider.Backend_openai_parse
module Glm = Llm_provider.Backend_glm
module Retry = Llm_provider.Retry
module Attribution = Provider_failure_attribution

(* Canonical overflow wire token — the same string [Types.stop_reason_of_string]
   already decodes; the OpenAI/GLM finish-reason decoder must now agree. *)
let overflow_token = "model_context_window_exceeded"

(* Minimal OpenAI/GLM chat-completion 200 body: an all-empty assistant message
   carrying the given wire finish_reason. This is the empty-turn shape the
   parsers fail closed on ([content = []]). *)
let empty_completion_body ~finish_reason =
  Printf.sprintf
    {|{"id":"resp-1","model":"glm-4","choices":[{"index":0,"finish_reason":%S,"message":{"role":"assistant","content":""}}]}|}
    finish_reason
;;

let stop_reason_testable =
  Alcotest.testable
    (fun fmt r -> Format.pp_print_string fmt (Types.show_stop_reason r))
    ( = )
;;

(* Extract the typed stop_reason from a parser result, failing the test with a
   descriptive message on any non-empty-completion outcome. *)
let empty_completion_stop_reason label = function
  | Error (Parse.Empty_completion e) -> e.Parse.stop_reason
  | Error (Parse.Provider_error msg) ->
    Alcotest.failf "%s: expected Empty_completion, got Provider_error %s" label msg
  | Ok _ -> Alcotest.failf "%s: expected Empty_completion, got Ok (non-empty turn)" label
;;

(* --- Wire decoder: parse-time and streaming paths both decode the token --- *)
let test_wire_decodes_overflow () =
  Alcotest.check
    stop_reason_testable
    "provisional_of_string (streaming) decodes overflow token"
    Types.ContextWindowExceeded
    (Wire.provisional_of_string overflow_token);
  Alcotest.check
    stop_reason_testable
    "of_finish (parse-time) decodes overflow token"
    Types.ContextWindowExceeded
    (Wire.of_finish (Wire.wire_finish_of_string overflow_token) ~has_tool_blocks:false)
;;

(* --- OpenAI-compatible parser: empty overflow completion carries the token --- *)
let test_openai_parse_overflow () =
  let body = empty_completion_body ~finish_reason:overflow_token in
  Alcotest.check
    stop_reason_testable
    "OpenAI parse of overflow empty completion"
    Types.ContextWindowExceeded
    (empty_completion_stop_reason "openai" (Parse.parse_openai_response_result body))
;;

(* --- GLM parser: same, via the P1#2-fixed [parse_response_result] seam --- *)
let test_glm_parse_overflow () =
  let body = empty_completion_body ~finish_reason:overflow_token in
  Alcotest.check
    stop_reason_testable
    "GLM parse of overflow empty completion"
    Types.ContextWindowExceeded
    (empty_completion_stop_reason "glm" (Glm.parse_response_result body))
;;

(* --- Classifier reachability driven from the WIRE-decoded stop_reason --- *)
let test_classifier_reachable_from_wire () =
  let body = empty_completion_body ~finish_reason:overflow_token in
  let stop_reason = empty_completion_stop_reason "glm" (Glm.parse_response_result body) in
  match Retry.overflow_of_empty_completion ~stop_reason ~message:"e2e" with
  | Some (Retry.ContextOverflow { limit = None; _ }) -> ()
  | Some other ->
    Alcotest.failf "expected ContextOverflow, got %s" (Retry.error_message other)
  | None ->
    Alcotest.fail "overflow_of_empty_completion did not fire on wire-decoded overflow"
;;

(* --- Full boundary: empty_completion_error -> Api ContextOverflow. Mirrors the
       existing attribution test but sources the stop_reason from the GLM parse
       of a raw wire body instead of a literal [Types.ContextWindowExceeded]. --- *)
let test_attribution_end_to_end () =
  let body = empty_completion_body ~finish_reason:overflow_token in
  let stop_reason = empty_completion_stop_reason "glm" (Glm.parse_response_result body) in
  match
    Attribution.sdk_error_of_http_error (Http.empty_completion_error ~stop_reason)
  with
  | Error.Api (Retry.ContextOverflow { limit = None; _ }) -> ()
  | other -> Alcotest.failf "expected Api ContextOverflow, got %s" (Error.to_string other)
;;

(* --- Negative control: a non-overflow finish_reason on an empty turn must stay
       provider-unavailable (the arm the overflow used to be misrouted to). --- *)
let test_non_overflow_control () =
  let body = empty_completion_body ~finish_reason:"stop" in
  let stop_reason = empty_completion_stop_reason "glm" (Glm.parse_response_result body) in
  Alcotest.check
    stop_reason_testable
    "non-overflow finish_reason parses as EndTurn"
    Types.EndTurn
    stop_reason;
  match
    Attribution.sdk_error_of_http_error (Http.empty_completion_error ~stop_reason)
  with
  | Error.Provider (Llm_provider.Error.ProviderUnavailable _) -> ()
  | other ->
    Alcotest.failf
      "expected Provider unavailable for non-overflow empty turn, got %s"
      (Error.to_string other)
;;

let () =
  Alcotest.run
    "overflow wire e2e"
    [ ( "wire decoder"
      , [ Alcotest.test_case "decodes overflow token" `Quick test_wire_decodes_overflow ]
      )
    ; ( "parse paths"
      , [ Alcotest.test_case "openai empty overflow" `Quick test_openai_parse_overflow
        ; Alcotest.test_case "glm empty overflow" `Quick test_glm_parse_overflow
        ] )
    ; ( "classifier reachability"
      , [ Alcotest.test_case
            "classifier fires from wire-decoded stop_reason"
            `Quick
            test_classifier_reachable_from_wire
        ; Alcotest.test_case "attribution end to end" `Quick test_attribution_end_to_end
        ; Alcotest.test_case "non-overflow control" `Quick test_non_overflow_control
        ] )
    ]
;;

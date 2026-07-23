(** Unit tests for [Oas_diag_sink] — the routing of OAS [Llm_provider.Diag]
    diagnostics into MASC's structured log (#25148).

    [route] is written as dependency injection so the level-to-emitter mapping
    and the [\[oas:ctx\]] message prefix are verifiable without capturing the
    global log sink. [masc.server] (an unwrapped library) and
    [agent_sdk.llm_provider] are re-exported by [masc_test_deps], so
    [Oas_diag_sink] and [Llm_provider] are bound directly. *)

module Sink = Oas_diag_sink

let test_format_line_prefixes_ctx () =
  Alcotest.(check string)
    "ctx is prefixed as [oas:ctx]"
    "[oas:http_client] boom"
    (Sink.format_line ~ctx:"http_client" "boom")

let test_format_line_preserves_oas_secret_redaction () =
  Alcotest.(check string)
    "custom sink redacts before durable logging"
    "[oas:http_client] Authorization: Bearer [REDACTED]"
    (Sink.format_line
       ~ctx:"http_client"
       "Authorization: Bearer provider-secret")

let capture () =
  let seen = ref [] in
  let record tag message = seen := (tag, message) :: !seen in
  ( seen
  , Sink.route
      ~debug:(record "debug")
      ~info:(record "info")
      ~warn:(record "warn")
      ~error:(record "error") )

let test_route_dispatches_each_level () =
  let seen, sink = capture () in
  sink Llm_provider.Diag.Debug ~ctx:"a" "m1";
  sink Llm_provider.Diag.Info ~ctx:"b" "m2";
  sink Llm_provider.Diag.Warn ~ctx:"http_client" "m3";
  sink Llm_provider.Diag.Error ~ctx:"retry" "m4";
  Alcotest.(check (list (pair string string)))
    "each level routes to its emitter with a formatted message"
    [ "error", "[oas:retry] m4"
    ; "warn", "[oas:http_client] m3"
    ; "info", "[oas:b] m2"
    ; "debug", "[oas:a] m1"
    ]
    !seen

let test_route_only_calls_matching_emitter () =
  let seen, sink = capture () in
  sink Llm_provider.Diag.Warn ~ctx:"http_client" "only-warn";
  Alcotest.(check (list (pair string string)))
    "a single warn does not spill into other emitters"
    [ "warn", "[oas:http_client] only-warn" ]
    !seen

let () =
  Alcotest.run
    "oas_diag_sink"
    [ ( "routing"
      , [ Alcotest.test_case "format_line prefixes ctx" `Quick
            test_format_line_prefixes_ctx
        ; Alcotest.test_case "format_line redacts provider secrets" `Quick
            test_format_line_preserves_oas_secret_redaction
        ; Alcotest.test_case "dispatches each level" `Quick
            test_route_dispatches_each_level
        ; Alcotest.test_case "only matching emitter fires" `Quick
            test_route_only_calls_matching_emitter
        ] )
    ]

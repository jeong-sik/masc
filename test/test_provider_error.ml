open Alcotest

module P = Provider_error
module Oas = Agent_sdk
module Prom = Masc_mcp.Prometheus
module Retry = Llm_provider.Retry
module OWN = Masc_mcp.Oas_worker_named

let check_json name expected error =
  check string name expected (Yojson.Safe.to_string (P.to_yojson error))

let expect_some = function
  | Some value -> value
  | None -> fail "expected provider_error"

let counter_for ~kind ~provider ~cascade_name ~capacity_scope =
  Prom.metric_value_or_zero OWN.provider_error_total_metric
    ~labels:
      [
        ("kind", kind);
        ("provider", provider);
        ("cascade_name", cascade_name);
        ("capacity_scope", capacity_scope);
      ]
    ()

let test_rate_limit_maps_retry_after () =
  let error =
    Retry.RateLimited { retry_after = Some 1.5; message = "too many requests" }
    |> OWN.retry_api_error_to_provider_error ~provider:" anthropic "
         ~capacity_exhausted:false
    |> expect_some
  in
  match error with
  | P.RateLimit { retry_after; provider } ->
      check string "provider normalized" "anthropic" provider;
      check (option (float 0.001)) "retry_after" (Some 1.5) retry_after;
      check string "kind" "rate_limit" (P.to_error_kind error);
      check_json "json"
        {|{"kind":"rate_limit","retry_after":1.5,"provider":"anthropic"}|}
        error
  | _ -> fail "expected RateLimit"

let test_rate_limit_can_be_capacity_exhausted () =
  let error =
    Retry.RateLimited { retry_after = None; message = "resource exhausted" }
    |> OWN.retry_api_error_to_provider_error
         ~provider:"claude_code:auto" ~capacity_exhausted:true
    |> expect_some
  in
  match error with
  | P.CapacityExhausted { scope = `Provider; affected } ->
      check (list string) "affected" [ "claude_code:auto" ] affected;
      check bool "capacity" true (P.is_capacity_exhausted error);
      check_json "json"
        {|{"kind":"capacity_exhausted","scope":"provider","affected":["claude_code:auto"]}|}
        error
  | _ -> fail "expected provider CapacityExhausted"

let test_anthropic_invalid_request_specified_limit_body_pins_capacity () =
  let message =
    "You have reached your specified API usage limits. You will regain access \
     on 2026-05-01 at 00:00 UTC."
  in
  let api_error = Retry.InvalidRequest { message } in
  let sdk_error = Oas.Error.Api api_error in
  check bool "existing OAS hard-quota classifier pins production body" true
    (OWN.sdk_error_is_hard_quota sdk_error);
  let error =
    OWN.sdk_error_to_provider_error ~provider:"anthropic" sdk_error
    |> expect_some
  in
  match error with
  | P.CapacityExhausted { scope = `Provider; affected } ->
      check (list string) "affected" [ "anthropic" ] affected
  | _ -> fail "expected specified-limit InvalidRequest to become capacity"

let test_server_and_auth_errors_are_closed_variants () =
  let server =
    Retry.ServerError { status = 503; message = "overloaded" }
    |> OWN.retry_api_error_to_provider_error ~provider:"openai"
         ~capacity_exhausted:false
    |> expect_some
  in
  let auth =
    Retry.AuthError { message = "invalid key" }
    |> OWN.retry_api_error_to_provider_error ~provider:"kimi"
         ~capacity_exhausted:false
    |> expect_some
  in
  match server, auth with
  | P.ServerError { code = 503; transient = true }, P.AuthError { provider } ->
      check string "auth provider" "kimi" provider;
      check (list string) "server has no provider owner" []
        (P.affected_providers server)
  | _ -> fail "expected ServerError/AuthError"

let test_non_capacity_invalid_request_preserves_reason () =
  let reason = {|{"detail":"Bad Request"}|} in
  let error =
    Retry.InvalidRequest { message = reason }
    |> OWN.retry_api_error_to_provider_error
         ~provider:"anthropic" ~capacity_exhausted:false
    |> expect_some
  in
  match error with
  | P.InvalidRequest { provider; reason = actual } ->
      check string "provider" "anthropic" provider;
      check string "reason" reason actual;
      check bool "not capacity" false (P.is_capacity_exhausted error)
  | _ -> fail "expected InvalidRequest"

let test_provider_error_metric_name_stable () =
  check string "metric name" "masc_provider_error_total"
    OWN.provider_error_total_metric

let test_emit_sdk_provider_error_metric_rate_limit () =
  let before =
    counter_for ~kind:"rate_limit" ~provider:"anthropic"
      ~cascade_name:"big_three" ~capacity_scope:"none"
  in
  let emitted =
    Oas.Error.Api
      (Retry.RateLimited { retry_after = Some 2.0; message = "too many" })
    |> OWN.emit_sdk_provider_error_metric ~cascade_name:"big_three"
         ~provider:"anthropic"
    |> expect_some
  in
  check string "emitted kind" "rate_limit" (P.to_error_kind emitted);
  check (float 0.0001) "counter +1" (before +. 1.0)
    (counter_for ~kind:"rate_limit" ~provider:"anthropic"
       ~cascade_name:"big_three" ~capacity_scope:"none")

let test_emit_sdk_provider_error_metric_capacity_scope () =
  let before =
    counter_for ~kind:"capacity_exhausted" ~provider:"anthropic"
      ~cascade_name:"big_three" ~capacity_scope:"provider"
  in
  let emitted =
    Oas.Error.Api
      (Retry.InvalidRequest
         {
           message =
             "You have reached your specified API usage limits. You will \
              regain access on 2026-05-01 at 00:00 UTC.";
         })
    |> OWN.emit_sdk_provider_error_metric ~cascade_name:"big_three"
         ~provider:"anthropic"
    |> expect_some
  in
  check string "emitted kind" "capacity_exhausted" (P.to_error_kind emitted);
  check (float 0.0001) "counter +1" (before +. 1.0)
    (counter_for ~kind:"capacity_exhausted" ~provider:"anthropic"
       ~cascade_name:"big_three" ~capacity_scope:"provider")

let test_emit_sdk_provider_error_metric_skips_non_api () =
  let before =
    counter_for ~kind:"invalid_request" ~provider:"anthropic"
      ~cascade_name:"big_three" ~capacity_scope:"none"
  in
  let emitted =
    Oas.Error.Internal "structural failure"
    |> OWN.emit_sdk_provider_error_metric ~cascade_name:"big_three"
         ~provider:"anthropic"
  in
  check bool "no provider error emitted" true (Option.is_none emitted);
  check (float 0.0001) "counter unchanged" before
    (counter_for ~kind:"invalid_request" ~provider:"anthropic"
       ~cascade_name:"big_three" ~capacity_scope:"none")

let () =
  Alcotest.run "provider_error"
    [
      ( "mapping",
        [
          test_case "rate limit maps retry_after" `Quick
            test_rate_limit_maps_retry_after;
          test_case "rate limit can become capacity" `Quick
            test_rate_limit_can_be_capacity_exhausted;
          test_case "Anthropic specified-limit body maps to capacity" `Quick
            test_anthropic_invalid_request_specified_limit_body_pins_capacity;
          test_case "server and auth closed variants" `Quick
            test_server_and_auth_errors_are_closed_variants;
          test_case "invalid request preserves reason" `Quick
            test_non_capacity_invalid_request_preserves_reason;
          test_case "metric name stable" `Quick
            test_provider_error_metric_name_stable;
          test_case "emit metric for rate limit" `Quick
            test_emit_sdk_provider_error_metric_rate_limit;
          test_case "emit metric for capacity" `Quick
            test_emit_sdk_provider_error_metric_capacity_scope;
          test_case "skip metric for non-api" `Quick
            test_emit_sdk_provider_error_metric_skips_non_api;
        ] );
    ]

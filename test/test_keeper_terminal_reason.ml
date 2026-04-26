(* Tests for keeper_agent_error.terminal_reason_code_of_sdk_error.

   Before this change, every Agent_sdk.Error.Api variant collapsed to a single
   "api_error" string, so the dashboard chip + the operator broadcast
   payload could not differentiate rate-limit / overload / auth / server
   faults. These tests pin down the per-variant terminal reason code so a
   future refactor cannot silently re-collapse the enum (memory:
   no-collapse-richer-enum-at-sdk-boundary). *)

open Alcotest

module KAE = Masc_mcp.Keeper_agent_error

let mk_api err = Agent_sdk.Error.Api err
let code = KAE.terminal_reason_code_of_sdk_error

let test_rate_limited () =
  check string "rate_limited" "api_error_rate_limited"
    (code (mk_api (Agent_sdk.Retry.RateLimited
                     { retry_after = None; message = "x" })))

let test_overloaded () =
  check string "overloaded" "api_error_overloaded"
    (code (mk_api (Agent_sdk.Retry.Overloaded { message = "x" })))

let test_server_error_includes_status () =
  check string "server 503" "api_error_server:503"
    (code (mk_api (Agent_sdk.Retry.ServerError { status = 503; message = "x" })));
  check string "server 500" "api_error_server:500"
    (code (mk_api (Agent_sdk.Retry.ServerError { status = 500; message = "x" })))

let test_auth_error () =
  check string "auth" "api_error_auth"
    (code (mk_api (Agent_sdk.Retry.AuthError { message = "x" })))

let test_invalid_request () =
  check string "invalid_request" "api_error_invalid_request"
    (code (mk_api (Agent_sdk.Retry.InvalidRequest { message = "x" })))

let test_not_found () =
  check string "not_found" "api_error_not_found"
    (code (mk_api (Agent_sdk.Retry.NotFound { message = "x" })))

let test_context_overflow () =
  check string "context_overflow" "api_error_context_overflow"
    (code (mk_api (Agent_sdk.Retry.ContextOverflow
                     { message = "x"; limit = Some 200_000 })))

let test_network_error () =
  check string "network" "api_error_network"
    (code (mk_api (Agent_sdk.Retry.NetworkError
                     { message = "x"
                     ; kind = Llm_provider.Http_client.Connection_refused })))

let test_timeout () =
  check string "timeout" "api_error_timeout"
    (code (mk_api (Agent_sdk.Retry.Timeout { message = "x" })))

(* Other variants kept their existing codes — guard against accidental
   churn in adjacent branches. *)

let test_other_variants_unchanged () =
  check string "agent" "agent_error"
    (code (Agent_sdk.Error.Agent
             (Agent_sdk.Error.MaxTurnsExceeded { turns = 1; limit = 1 })));
  check string "mcp" "mcp_error"
    (code (Agent_sdk.Error.Mcp
             (Agent_sdk.Error.InitializeFailed { detail = "x" })));
  check string "config" "config_error"
    (code (Agent_sdk.Error.Config
             (Agent_sdk.Error.MissingEnvVar { var_name = "X" })));
  check string "io" "io_error"
    (code (Agent_sdk.Error.Io (Agent_sdk.Error.ValidationFailed { detail = "x" })));
  check string "internal" "internal_error"
    (code (Agent_sdk.Error.Internal "x"))

(* No two distinct API variants share a code — that's the whole point.
   Encode it as a property: the 9 returned codes are pairwise distinct. *)

let test_all_api_codes_distinct () =
  let codes =
    [
      code (mk_api (Agent_sdk.Retry.RateLimited
                      { retry_after = None; message = "" }));
      code (mk_api (Agent_sdk.Retry.Overloaded { message = "" }));
      code (mk_api (Agent_sdk.Retry.ServerError { status = 503; message = "" }));
      code (mk_api (Agent_sdk.Retry.AuthError { message = "" }));
      code (mk_api (Agent_sdk.Retry.InvalidRequest { message = "" }));
      code (mk_api (Agent_sdk.Retry.NotFound { message = "" }));
      code (mk_api (Agent_sdk.Retry.ContextOverflow
                      { message = ""; limit = None }));
      code (mk_api (Agent_sdk.Retry.NetworkError
                      { message = ""
                      ; kind = Llm_provider.Http_client.Connection_refused }));
      code (mk_api (Agent_sdk.Retry.Timeout { message = "" }));
    ]
  in
  let unique =
    List.sort_uniq String.compare codes |> List.length
  in
  check int "9 variants -> 9 distinct codes" 9 unique

let () =
  run "keeper_terminal_reason"
    [
      ( "api_error variants",
        [
          test_case "RateLimited" `Quick test_rate_limited;
          test_case "Overloaded" `Quick test_overloaded;
          test_case "ServerError carries status" `Quick
            test_server_error_includes_status;
          test_case "AuthError" `Quick test_auth_error;
          test_case "InvalidRequest" `Quick test_invalid_request;
          test_case "NotFound" `Quick test_not_found;
          test_case "ContextOverflow" `Quick test_context_overflow;
          test_case "NetworkError" `Quick test_network_error;
          test_case "Timeout" `Quick test_timeout;
        ] );
      ( "regression",
        [
          test_case "non-Api variants unchanged" `Quick
            test_other_variants_unchanged;
          test_case "all 9 api codes are pairwise distinct" `Quick
            test_all_api_codes_distinct;
        ] );
    ]

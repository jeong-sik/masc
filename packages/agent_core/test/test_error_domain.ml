(** Error_domain tests — roundtrip conversion and retryability. *)

open Agent_core
module Http_client = Llm_provider.Http_client
module Retry = Llm_provider.Retry

(* ── Roundtrip: core_error -> poly -> core_error ───────────── *)

let test_roundtrip_api_rate_limited () =
  let orig =
    Error.Api (Retry.RateLimited { retry_after = Some 1.5; message = "slow down" })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Rate_limited (Some 1.5, "slow down") -> ()
   | _ -> Alcotest.fail "expected Rate_limited (Some 1.5, \"slow down\")");
  let back = Error_domain.to_core_error poly in
  Alcotest.(check bool) "roundtrip is exact" true (orig = back)
;;

(* agent_core 429 typed completion (2026-07): incident context — Ollama's actual
   429 body ("too many concurrent requests") was collapsed into the
   hardcoded literal "rate limited" by [provider_to_error] (the [to_core_error]
   path for provider errors) because the [`Rate_limited] poly variant only
   carried [float option], discarding the message on the way into
   [Error_domain]. Counterfactual: reverting the payload back to a bare
   [float option] makes this test fail to compile (the message field would
   not exist to check). *)
let test_provider_to_error_preserves_rate_limit_message () =
  let poly : Error_domain.core_error_poly =
    `Rate_limited (Some 3.0, "too many concurrent requests")
  in
  match Error_domain.to_core_error poly with
  | Error.Api (Retry.RateLimited { retry_after; message }) ->
    Alcotest.(check (option (float 0.001))) "retry_after preserved" (Some 3.0) retry_after;
    Alcotest.(check string)
      "provider message preserved (not the hardcoded literal)"
      "too many concurrent requests"
      message
  | _ -> Alcotest.fail "expected Error.Api (Retry.RateLimited _)"
;;

let test_roundtrip_config_missing_env () =
  let orig = Error.Config (MissingEnvVar { var_name = "API_KEY" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Missing_env_var "API_KEY" -> ()
   | _ -> Alcotest.fail "expected Missing_env_var");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Config (MissingEnvVar { var_name = "API_KEY" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for MissingEnvVar"
;;

let test_roundtrip_mcp_tool_call_failed () =
  let orig = Error.Mcp (ToolCallFailed { tool_name = "search"; detail = "timeout" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Mcp_tool_call_failed ("search", "timeout") -> ()
   | _ -> Alcotest.fail "expected Mcp_tool_call_failed");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Mcp (ToolCallFailed { tool_name = "search"; detail = "timeout" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for ToolCallFailed"
;;

let test_roundtrip_internal () =
  let orig = Error.Internal "something broke" in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Internal "something broke" -> ()
   | _ -> Alcotest.fail "expected Internal");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Internal "something broke" -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for Internal"
;;

(* ── to_string ───────────────────────────────────────────── *)

let test_to_string_nonempty () =
  let s = Error_domain.to_string (`Auth_error "bad key") in
  Alcotest.(check bool) "nonempty" true (String.length s > 0)
;;

let test_to_string_each_variant () =
  (* Verify to_string produces non-empty strings for every variant *)
  let variants : Error_domain.core_error_poly list =
    [ `Rate_limited (Some 2.0, "slow down")
    ; `Rate_limited (None, "no retry hint")
    ; `Auth_error "forbidden"
    ; `Authorization_error "permission refused"
    ; `Server_error (503, "unavailable")
    ; `Network_error "connection refused"
    ; `Provider_timeout (None, "3s elapsed")
    ; `Streaming_timeout (Http_client.Stream_body, "stream body elapsed")
    ; `Overloaded
    ; `Invalid_request (Llm_provider.Retry.Unknown_invalid_request, "bad body")
    ; `Tool_exec_failed ("search", "crash")
    ; `Tool_timeout ("calc", 30.0)
    ; `Guardrail_violation ("typed-input", "rejected")
    ; `Unrecognized_stop_reason "weird"
    ; `Missing_env_var "SECRET"
    ; `Unsupported_provider "unknown_llm"
    ; `Invalid_config ("model", "empty")
    ; `Mcp_server_start_failed ("/bin/x", "not found")
    ; `Mcp_init_failed "handshake fail"
    ; `Mcp_tool_list_failed "timeout"
    ; `Mcp_tool_call_failed ("run", "error")
    ; `Mcp_http_failed ("http://x", "502")
    ; `Serialization "bad json"
    ; `Io "file missing"
    ; `Orchestration "routing failed"
    ; `Internal "bug"
    ]
  in
  List.iter
    (fun v ->
       let s = Error_domain.to_string v in
       Alcotest.(check bool) "nonempty" true (String.length s > 0))
    variants
;;

(* ── Exhaustiveness check: all core_error_poly variants ───── *)

let test_all_variants_convert () =
  let all_polys : Error_domain.core_error_poly list =
    [ `Rate_limited (None, "x")
    ; `Auth_error "x"
    ; `Authorization_error "x"
    ; `Server_error (500, "x")
    ; `Network_error "x"
    ; `Provider_timeout (None, "x")
    ; `Streaming_timeout (Http_client.Stream_idle Http_client.Streaming_thinking, "idle")
    ; `Overloaded
    ; `Invalid_request (Llm_provider.Retry.Unknown_invalid_request, "x")
    ; `Tool_exec_failed ("t", "d")
    ; `Tool_timeout ("t", 1.0)
    ; `Guardrail_violation ("typed-input", "rejected")
    ; `Unrecognized_stop_reason "x"
    ; `Missing_env_var "X"
    ; `Unsupported_provider "x"
    ; `Invalid_config ("f", "d")
    ; `Mcp_server_start_failed ("c", "d")
    ; `Mcp_init_failed "x"
    ; `Mcp_tool_list_failed "x"
    ; `Mcp_tool_call_failed ("t", "d")
    ; `Mcp_http_failed ("u", "d")
    ; `Serialization "x"
    ; `Io "x"
    ; `Orchestration "x"
    ; `Internal "x"
    ]
  in
  List.iter
    (fun poly ->
       let core_error = Error_domain.to_core_error poly in
       let s = Error.to_string core_error in
       Alcotest.(check bool) "to_string nonempty" true (String.length s > 0))
    all_polys
;;

(* ── Roundtrip: remaining of_core_error branches ─────────── *)

let test_roundtrip_api_auth_error () =
  let orig = Error.Api (Retry.AuthError { message = "forbidden" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Auth_error "forbidden" -> ()
   | _ -> Alcotest.fail "expected Auth_error");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.AuthError { message = "forbidden" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for AuthError"
;;

let test_roundtrip_api_authorization_error () =
  let orig = Error.Api (Retry.AuthorizationError { message = "permission refused" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Authorization_error "permission refused" -> ()
   | _ -> Alcotest.fail "expected Authorization_error");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.AuthorizationError { message = "permission refused" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for AuthorizationError"
;;

let test_roundtrip_api_server_error () =
  let orig = Error.Api (Retry.ServerError { status = 503; message = "down" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Server_error (503, "down") -> ()
   | _ -> Alcotest.fail "expected Server_error");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.ServerError { status = 503; message = "down" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for ServerError"
;;

let test_roundtrip_api_network_error () =
  let orig =
    Error.Api (Retry.NetworkError { message = "conn refused"; kind = Unknown })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Network_error "conn refused" -> ()
   | _ -> Alcotest.fail "expected Network_error");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.NetworkError _) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for NetworkError"
;;

let test_roundtrip_api_timeout () =
  let orig = Error.Api (Retry.Timeout { message = "3s"; phase = None }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Provider_timeout (None, "3s") -> ()
   | _ -> Alcotest.fail "expected Provider_timeout");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.Timeout _) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for Timeout"
;;

let test_roundtrip_api_timeout_preserves_phase () =
  let orig =
    Error.Api
      (Retry.Timeout { message = "prefill"; phase = Some Http_client.First_token })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Streaming_timeout (Http_client.First_token, "prefill") -> ()
   | _ -> Alcotest.fail "expected Streaming_timeout with First_token");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Provider
      (Llm_provider.Error.Timeout { timeout_phase = Some Http_client.First_token; _ }) ->
    ()
  | _ -> Alcotest.fail "roundtrip lost timeout phase"
;;

let test_roundtrip_api_timeout_preserves_non_streaming_phase () =
  let orig =
    Error.Api
      (Retry.Timeout { message = "headers"; phase = Some Http_client.Http_operation })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Provider_timeout (Some Http_client.Http_operation, "headers") -> ()
   | _ -> Alcotest.fail "expected Provider_timeout with Http_operation phase");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.Timeout { phase = Some Http_client.Http_operation; message }) ->
    Alcotest.(check string) "message" "headers" message
  | _ -> Alcotest.fail "roundtrip lost non-streaming timeout phase"
;;

let test_roundtrip_provider_streaming_timeout () =
  let orig =
    Error.Provider
      (Llm_provider.Error.Timeout
         { provider = "openai"
         ; timeout_phase = Some Http_client.Stream_body
         ; detail = "stream body cap"
         })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Streaming_timeout (Http_client.Stream_body, "stream body cap") -> ()
   | _ -> Alcotest.fail "expected Streaming_timeout");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Provider
      (Llm_provider.Error.Timeout
         { timeout_phase = Some Http_client.Stream_body; detail = "stream body cap"; _ })
    ->
    let first_token =
      Error.Provider
        (Llm_provider.Error.Timeout
           { provider = "openai"
           ; timeout_phase = Some Http_client.First_token
           ; detail = "awaiting first token"
           })
      |> Error_domain.of_core_error
    in
    (match first_token with
     | `Streaming_timeout (Http_client.First_token, "awaiting first token") -> ()
     | _ -> Alcotest.fail "expected First_token Streaming_timeout")
  | _ -> Alcotest.fail "roundtrip mismatch for streaming Timeout"
;;

let test_roundtrip_api_overloaded () =
  let orig = Error.Api (Retry.Overloaded { message = "busy" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Overloaded -> ()
   | _ -> Alcotest.fail "expected Overloaded");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.Overloaded _) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for Overloaded"
;;

let test_roundtrip_api_invalid_request () =
  let orig =
    Error.Api (Retry.InvalidRequest { message = "bad"; reason = Unknown_invalid_request })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Invalid_request (_, "bad") -> ()
   | _ -> Alcotest.fail "expected Invalid_request");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.InvalidRequest _) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for InvalidRequest"
;;

let test_roundtrip_api_invalid_request_does_not_infer_malformed_json () =
  let message = "Unexpected token } in JSON at position 12" in
  let orig =
    Error.Api (Retry.InvalidRequest { message; reason = Retry.Json_parse_error })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Invalid_request (_, msg) -> Alcotest.(check string) "message preserved" message msg
   | _ -> Alcotest.fail "expected Invalid_request");
  (* The reason a caller supplied now survives the roundtrip. That is not inference
     from prose — it is carrying a typed value that was already present. The
     no-inference property is asserted separately below, starting from
     Unknown_invalid_request with the same malformed-JSON message. *)
  match Error_domain.to_core_error poly with
  | Error.Api (Retry.InvalidRequest { reason = Retry.Json_parse_error; _ }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for InvalidRequest"
;;

(* The original property this file pinned: malformed-JSON prose must not be promoted
   to Json_parse_error. Before the reason was carried, every roundtrip returned
   Unknown_invalid_request and satisfied this trivially; now it needs a case that
   starts there. *)
let test_roundtrip_api_invalid_request_keeps_unknown_reason_unknown () =
  let message = "Unexpected token } in JSON at position 12" in
  let orig =
    Error.Api (Retry.InvalidRequest { message; reason = Retry.Unknown_invalid_request })
  in
  match Error_domain.to_core_error (Error_domain.of_core_error orig) with
  | Error.Api (Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; _ }) -> ()
  | _ -> Alcotest.fail "an unknown reason must stay unknown"
;;

let test_roundtrip_api_context_overflow () =
  let orig =
    Error.Api (Retry.ContextOverflow { message = "too big"; limit = Some 8192 })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Context_overflow ("too big", Some 8192) -> ()
   | _ -> Alcotest.fail "expected Context_overflow");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.ContextOverflow { message = "too big"; limit = Some 8192 }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for ContextOverflow"
;;

let test_roundtrip_api_context_overflow_no_limit () =
  let orig = Error.Api (Retry.ContextOverflow { message = "overflow"; limit = None }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Context_overflow ("overflow", None) -> ()
   | _ -> Alcotest.fail "expected Context_overflow None");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.ContextOverflow { limit = None; _ }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for ContextOverflow None"
;;

let test_roundtrip_api_payment_required () =
  let orig = Error.Api (Retry.PaymentRequired { message = "Insufficient Balance" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Payment_required "Insufficient Balance" -> ()
   | _ -> Alcotest.fail "expected Payment_required");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Api (Retry.PaymentRequired { message = "Insufficient Balance" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for PaymentRequired"
;;

let test_roundtrip_agent_unrecognized_stop () =
  let orig = Error.Agent (UnrecognizedStopReason { reason = "weird" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Unrecognized_stop_reason "weird" -> ()
   | _ -> Alcotest.fail "expected Unrecognized_stop_reason");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Agent (UnrecognizedStopReason { reason = "weird" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for UnrecognizedStopReason"
;;

let test_roundtrip_agent_hook_execution_failed () =
  let orig =
    Error.Agent
      (HookExecutionFailed
         { hook_name = "post_tool_use"
         ; stage = "post_tool_use"
         ; tool_name = Some "write"
         ; tool_use_id = Some "tool-1"
         ; detail = "observer failed"
         })
  in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Hook_execution_failed
       ("post_tool_use", "post_tool_use", Some "write", Some "tool-1", "observer failed")
     -> ()
   | _ -> Alcotest.fail "expected Hook_execution_failed");
  match Error_domain.to_core_error poly with
  | Error.Agent
      (HookExecutionFailed
         { hook_name = "post_tool_use"
         ; stage = "post_tool_use"
         ; tool_name = Some "write"
         ; tool_use_id = Some "tool-1"
         ; detail = "observer failed"
         }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for HookExecutionFailed"
;;

let test_roundtrip_config_unsupported_provider () =
  let orig = Error.Config (UnsupportedProvider { detail = "xyz" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Unsupported_provider "xyz" -> ()
   | _ -> Alcotest.fail "expected Unsupported_provider");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Config (UnsupportedProvider { detail = "xyz" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for UnsupportedProvider"
;;

let test_roundtrip_config_invalid_config () =
  let orig = Error.Config (InvalidConfig { field = "model"; detail = "empty" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Invalid_config ("model", "empty") -> ()
   | _ -> Alcotest.fail "expected Invalid_config");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Config (InvalidConfig { field = "model"; detail = "empty" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for InvalidConfig"
;;

let test_roundtrip_mcp_server_start_failed () =
  let orig = Error.Mcp (ServerStartFailed { command = "/bin/x"; detail = "not found" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Mcp_server_start_failed ("/bin/x", "not found") -> ()
   | _ -> Alcotest.fail "expected Mcp_server_start_failed");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Mcp (ServerStartFailed { command = "/bin/x"; detail = "not found" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for ServerStartFailed"
;;

let test_roundtrip_mcp_init_failed () =
  let orig = Error.Mcp (InitializeFailed { detail = "handshake" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Mcp_init_failed "handshake" -> ()
   | _ -> Alcotest.fail "expected Mcp_init_failed");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Mcp (InitializeFailed { detail = "handshake" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for InitializeFailed"
;;

let test_roundtrip_mcp_tool_list_failed () =
  let orig = Error.Mcp (ToolListFailed { detail = "timeout" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Mcp_tool_list_failed "timeout" -> ()
   | _ -> Alcotest.fail "expected Mcp_tool_list_failed");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Mcp (ToolListFailed { detail = "timeout" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for ToolListFailed"
;;

let test_roundtrip_mcp_http_failed () =
  let orig = Error.Mcp (HttpTransportFailed { url = "http://x"; detail = "502" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Mcp_http_failed ("http://x", "502") -> ()
   | _ -> Alcotest.fail "expected Mcp_http_failed");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Mcp (HttpTransportFailed { url = "http://x"; detail = "502" }) -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for HttpTransportFailed"
;;

let test_roundtrip_serialization () =
  let orig = Error.Serialization (JsonParseError { detail = "bad json" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Serialization _ -> ()
   | _ -> Alcotest.fail "expected Serialization");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Serialization _ -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for Serialization"
;;

let test_roundtrip_io () =
  let orig = Error.Io (ValidationFailed { detail = "bad data" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Io _ -> ()
   | _ -> Alcotest.fail "expected Io");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Io _ -> ()
  | _ -> Alcotest.fail "roundtrip mismatch for Io"
;;

let test_roundtrip_orchestration () =
  let orig = Error.Orchestration (UnknownAgent { name = "ghost" }) in
  let poly = Error_domain.of_core_error orig in
  (match poly with
   | `Orchestration _ -> ()
   | _ -> Alcotest.fail "expected Orchestration");
  let back = Error_domain.to_core_error poly in
  match back with
  | Error.Internal _ -> () (* Orchestration roundtrips to Internal *)
  | _ -> Alcotest.fail "roundtrip mismatch for Orchestration"
;;

(* ── with_stage / ctx_to_string ─────────────────────────── *)

let test_with_stage () =
  let ctx = Error_domain.with_stage "route" (`Auth_error "bad") in
  Alcotest.(check (option string)) "stage" (Some "route") ctx.stage;
  Alcotest.(check (option string)) "backtrace" None ctx.backtrace;
  match ctx.error with
  | `Auth_error "bad" -> ()
  | _ -> Alcotest.fail "wrong error in ctx"
;;

let test_ctx_to_string_with_stage () =
  let ctx = Error_domain.with_stage "collect" (`Internal "oops") in
  let s = Error_domain.ctx_to_string ctx in
  (* Should start with "[collect]" *)
  Alcotest.(check bool)
    "starts with stage"
    true
    (String.length s >= 9 && String.sub s 0 9 = "[collect]")
;;

let test_ctx_to_string_without_stage () =
  let ctx : Error_domain.error_ctx =
    { error = `Internal "oops"; stage = None; backtrace = None }
  in
  let s = Error_domain.ctx_to_string ctx in
  (* Should not have brackets prefix *)
  Alcotest.(check bool) "no stage prefix" true (String.length s > 0 && s.[0] <> '[')
;;

(* ── to_core_error: tool_exec_failed / tool_timeout ───────── *)

let test_to_core_error_tool_exec_failed () =
  let core_error = Error_domain.to_core_error (`Tool_exec_failed ("search", "crash")) in
  match core_error with
  | Error.Internal s -> Alcotest.(check bool) "mentions detail" true (String.length s > 0)
  | _ -> Alcotest.fail "expected Internal for tool_exec_failed"
;;

let test_to_core_error_tool_timeout () =
  let core_error = Error_domain.to_core_error (`Tool_timeout ("calc", 30.0)) in
  match core_error with
  | Error.Internal s -> Alcotest.(check bool) "mentions name" true (String.length s > 0)
  | _ -> Alcotest.fail "expected Internal for tool_timeout"
;;

(* ── provider_error roundtrip via to_core_error ───────────── *)

let test_provider_roundtrip_all_via_to_sdk () =
  (* Test that all provider_error variants roundtrip through to_core_error *)
  let variants : Error_domain.provider_error list =
    [ `Rate_limited (Some 1.0, "slow down")
    ; `Rate_limited (None, "no retry hint")
    ; `Auth_error "x"
    ; `Authorization_error "x"
    ; `Server_error (500, "x")
    ; `Network_error "x"
    ; `Provider_timeout (None, "x")
    ; `Streaming_timeout (Http_client.Stream_body, "x")
    ; `Overloaded
    ; `Invalid_request (Llm_provider.Retry.Unknown_invalid_request, "x")
    ]
  in
  List.iter
    (fun v ->
       let core_error = Error_domain.to_core_error (v :> Error_domain.core_error_poly) in
       let s = Error.to_string core_error in
       Alcotest.(check bool) "nonempty to_string" true (String.length s > 0);
       match v, core_error with
       | `Streaming_timeout _, Error.Provider _ -> ()
       | `Streaming_timeout _, _ ->
         Alcotest.fail "expected Provider for streaming_timeout"
       | _, Error.Api _ -> ()
       | _ -> Alcotest.fail "expected Api for provider_error")
    variants
;;

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Error_domain"
    [ ( "roundtrip"
      , [ Alcotest.test_case "api rate_limited" `Quick test_roundtrip_api_rate_limited
        ; Alcotest.test_case
            "provider_to_error preserves rate limit message"
            `Quick
            test_provider_to_error_preserves_rate_limit_message
        ; Alcotest.test_case "api auth_error" `Quick test_roundtrip_api_auth_error
        ; Alcotest.test_case
            "api authorization_error"
            `Quick
            test_roundtrip_api_authorization_error
        ; Alcotest.test_case "api server_error" `Quick test_roundtrip_api_server_error
        ; Alcotest.test_case "api network_error" `Quick test_roundtrip_api_network_error
        ; Alcotest.test_case "api timeout" `Quick test_roundtrip_api_timeout
        ; Alcotest.test_case
            "api timeout preserves phase"
            `Quick
            test_roundtrip_api_timeout_preserves_phase
        ; Alcotest.test_case
            "api timeout preserves non-streaming phase"
            `Quick
            test_roundtrip_api_timeout_preserves_non_streaming_phase
        ; Alcotest.test_case
            "provider streaming timeout"
            `Quick
            test_roundtrip_provider_streaming_timeout
        ; Alcotest.test_case "api overloaded" `Quick test_roundtrip_api_overloaded
        ; Alcotest.test_case
            "api invalid_request"
            `Quick
            test_roundtrip_api_invalid_request
        ; Alcotest.test_case
            "api invalid_request malformed JSON retryability"
            `Quick
            test_roundtrip_api_invalid_request_does_not_infer_malformed_json
        ; Alcotest.test_case
            "api invalid_request keeps an unknown reason unknown"
            `Quick
            test_roundtrip_api_invalid_request_keeps_unknown_reason_unknown
        ; Alcotest.test_case
            "api context_overflow"
            `Quick
            test_roundtrip_api_context_overflow
        ; Alcotest.test_case
            "api context_overflow_no_limit"
            `Quick
            test_roundtrip_api_context_overflow_no_limit
        ; Alcotest.test_case
            "api payment_required"
            `Quick
            test_roundtrip_api_payment_required
        ; Alcotest.test_case
            "agent unrecognized_stop"
            `Quick
            test_roundtrip_agent_unrecognized_stop
        ; Alcotest.test_case
            "agent hook_execution_failed"
            `Quick
            test_roundtrip_agent_hook_execution_failed
        ; Alcotest.test_case "config missing_env" `Quick test_roundtrip_config_missing_env
        ; Alcotest.test_case
            "config unsupported_provider"
            `Quick
            test_roundtrip_config_unsupported_provider
        ; Alcotest.test_case
            "config invalid_config"
            `Quick
            test_roundtrip_config_invalid_config
        ; Alcotest.test_case
            "mcp tool_call_failed"
            `Quick
            test_roundtrip_mcp_tool_call_failed
        ; Alcotest.test_case
            "mcp server_start_failed"
            `Quick
            test_roundtrip_mcp_server_start_failed
        ; Alcotest.test_case "mcp init_failed" `Quick test_roundtrip_mcp_init_failed
        ; Alcotest.test_case
            "mcp tool_list_failed"
            `Quick
            test_roundtrip_mcp_tool_list_failed
        ; Alcotest.test_case "mcp http_failed" `Quick test_roundtrip_mcp_http_failed
        ; Alcotest.test_case "serialization" `Quick test_roundtrip_serialization
        ; Alcotest.test_case "io" `Quick test_roundtrip_io
        ; Alcotest.test_case "orchestration" `Quick test_roundtrip_orchestration
        ; Alcotest.test_case "internal" `Quick test_roundtrip_internal
        ] )
    ; ( "context"
      , [ Alcotest.test_case "with_stage" `Quick test_with_stage
        ; Alcotest.test_case
            "ctx_to_string with stage"
            `Quick
            test_ctx_to_string_with_stage
        ; Alcotest.test_case
            "ctx_to_string without stage"
            `Quick
            test_ctx_to_string_without_stage
        ] )
    ; ( "to_core_error_edges"
      , [ Alcotest.test_case
            "provider roundtrip all"
            `Quick
            test_provider_roundtrip_all_via_to_sdk
        ; Alcotest.test_case "tool_exec_failed" `Quick test_to_core_error_tool_exec_failed
        ; Alcotest.test_case "tool_timeout" `Quick test_to_core_error_tool_timeout
        ] )
    ; ( "coverage"
      , [ Alcotest.test_case "to_string nonempty" `Quick test_to_string_nonempty
        ; Alcotest.test_case "to_string each variant" `Quick test_to_string_each_variant
        ; Alcotest.test_case "all variants convert" `Quick test_all_variants_convert
        ] )
    ]
;;

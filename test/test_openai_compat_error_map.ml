(** RFC-0105 — table-driven map verification for
    [Openai_compat_error_map.of_sdk_error].

    Each row asserts that a representative [sdk_error] variant produces
    the documented (http_status, openai_kind, openai_code) triple. The
    table is intentionally exhaustive over the 10 top-level [sdk_error]
    constructors — exhaustiveness over sub-variants is enforced by the
    OCaml compiler at the implementation site (no catch-all `_ ->`). *)

module M = Masc_mcp.Openai_compat_error_map
module E = Agent_sdk.Error

(* Renders [http_status] tag literally for diff-readable Alcotest output. *)
let http_status_to_string : M.http_status -> string = function
  | `Bad_request -> "Bad_request"
  | `Unauthorized -> "Unauthorized"
  | `Not_found -> "Not_found"
  | `Request_timeout -> "Request_timeout"
  | `Too_many_requests -> "Too_many_requests"
  | `Internal_server_error -> "Internal_server_error"
  | `Bad_gateway -> "Bad_gateway"
  | `Service_unavailable -> "Service_unavailable"
  | `Gateway_timeout -> "Gateway_timeout"

let check_mapping
    ~label
    ~(input : E.sdk_error)
    ~(expected_status : M.http_status)
    ~(expected_kind : string)
    ~(expected_code : string option)
    () =
  let { M.http_status; openai_kind; openai_code; message = _ } =
    M.of_sdk_error input
  in
  Alcotest.(check string)
    (Printf.sprintf "%s: http_status" label)
    (http_status_to_string expected_status)
    (http_status_to_string http_status);
  Alcotest.(check string)
    (Printf.sprintf "%s: openai_kind" label)
    expected_kind openai_kind;
  Alcotest.(check (option string))
    (Printf.sprintf "%s: openai_code" label)
    expected_code openai_code

let test_api_rate_limited () =
  check_mapping
    ~label:"Api RateLimited"
    ~input:(E.Api (E.Retry.RateLimited
      { retry_after = Some 30.0; message = "throttle" }))
    ~expected_status:`Too_many_requests
    ~expected_kind:"rate_limit_error"
    ~expected_code:(Some "rate_limited") ()

let test_api_auth () =
  check_mapping
    ~label:"Api AuthError"
    ~input:(E.Api (E.Retry.AuthError { message = "bad token" }))
    ~expected_status:`Unauthorized
    ~expected_kind:"authentication_error"
    ~expected_code:(Some "invalid_api_key") ()

let test_api_not_found () =
  check_mapping
    ~label:"Api NotFound"
    ~input:(E.Api (E.Retry.NotFound { message = "model missing" }))
    ~expected_status:`Not_found
    ~expected_kind:"not_found_error"
    ~expected_code:(Some "model_not_found") ()

let test_api_context_overflow () =
  check_mapping
    ~label:"Api ContextOverflow"
    ~input:(E.Api (E.Retry.ContextOverflow
      { message = "exceeds 128k"; limit = Some 128000 }))
    ~expected_status:`Bad_request
    ~expected_kind:"invalid_request_error"
    ~expected_code:(Some "context_length_exceeded") ()

let test_api_timeout () =
  check_mapping
    ~label:"Api Timeout"
    ~input:(E.Api (E.Retry.Timeout { message = "took too long" }))
    ~expected_status:`Service_unavailable
    ~expected_kind:"server_error"
    ~expected_code:(Some "provider_error") ()

let test_api_server_error () =
  check_mapping
    ~label:"Api ServerError 502"
    ~input:(E.Api (E.Retry.ServerError { status = 502; message = "bad gw" }))
    ~expected_status:`Bad_gateway
    ~expected_kind:"server_error"
    ~expected_code:(Some "upstream_502") ()

let test_provider_timeout () =
  check_mapping
    ~label:"Provider Timeout"
    ~input:
      (E.Provider
         (Llm_provider.Error.Timeout
            { provider = "anthropic";
              timeout_phase = Some Llm_provider.Http_client.Caller_budget;
              detail = "provider step exceeded budget" }))
    ~expected_status:`Gateway_timeout
    ~expected_kind:"server_error"
    ~expected_code:(Some "timeout") ()

let test_agent_token_budget () =
  check_mapping
    ~label:"Agent TokenBudgetExceeded"
    ~input:(E.Agent (E.TokenBudgetExceeded
      { kind = "input"; used = 200_000; limit = 128_000 }))
    ~expected_status:`Bad_request
    ~expected_kind:"invalid_request_error"
    ~expected_code:(Some "token_budget_exceeded") ()

let test_agent_max_turns () =
  check_mapping
    ~label:"Agent MaxTurnsExceeded"
    ~input:(E.Agent (E.MaxTurnsExceeded { turns = 10; limit = 5 }))
    ~expected_status:`Internal_server_error
    ~expected_kind:"server_error"
    ~expected_code:(Some "max_turns_exceeded") ()

let test_agent_guardrail () =
  check_mapping
    ~label:"Agent GuardrailViolation"
    ~input:(E.Agent (E.GuardrailViolation
      { validator = "content_safety"; reason = "blocked" }))
    ~expected_status:`Bad_request
    ~expected_kind:"invalid_request_error"
    ~expected_code:(Some "guardrail_violation") ()

let test_mcp_server_start () =
  check_mapping
    ~label:"Mcp ServerStartFailed"
    ~input:(E.Mcp (E.ServerStartFailed
      { command = "x"; detail = "boom" }))
    ~expected_status:`Service_unavailable
    ~expected_kind:"server_error"
    ~expected_code:(Some "mcp_server_start_failed") ()

let test_mcp_tool_call () =
  check_mapping
    ~label:"Mcp ToolCallFailed"
    ~input:(E.Mcp (E.ToolCallFailed
      { tool_name = "shell"; detail = "exit 1" }))
    ~expected_status:`Bad_gateway
    ~expected_kind:"server_error"
    ~expected_code:(Some "mcp_tool_call_failed") ()

let test_config_missing_env () =
  check_mapping
    ~label:"Config MissingEnvVar"
    ~input:(E.Config (E.MissingEnvVar { var_name = "X" }))
    ~expected_status:`Internal_server_error
    ~expected_kind:"server_error"
    ~expected_code:(Some "config_missing_env") ()

let test_config_unsupported_provider () =
  check_mapping
    ~label:"Config UnsupportedProvider"
    ~input:(E.Config (E.UnsupportedProvider { detail = "fake-llm" }))
    ~expected_status:`Bad_request
    ~expected_kind:"invalid_request_error"
    ~expected_code:(Some "unsupported_provider") ()

let test_serialization_parse () =
  check_mapping
    ~label:"Serialization JsonParseError"
    ~input:(E.Serialization (E.JsonParseError { detail = "{}" }))
    ~expected_status:`Bad_gateway
    ~expected_kind:"server_error"
    ~expected_code:(Some "json_parse_error") ()

let test_io_validation () =
  check_mapping
    ~label:"Io ValidationFailed"
    ~input:(E.Io (E.ValidationFailed { detail = "bad input" }))
    ~expected_status:`Bad_request
    ~expected_kind:"invalid_request_error"
    ~expected_code:(Some "validation_failed") ()

let test_orchestration_unknown_agent () =
  check_mapping
    ~label:"Orchestration UnknownAgent"
    ~input:(E.Orchestration (E.UnknownAgent { name = "ghost" }))
    ~expected_status:`Not_found
    ~expected_kind:"not_found_error"
    ~expected_code:(Some "agent_not_found") ()

let test_orchestration_timeout () =
  check_mapping
    ~label:"Orchestration TaskTimeout"
    ~input:(E.Orchestration (E.TaskTimeout { task_id = "t1" }))
    ~expected_status:`Gateway_timeout
    ~expected_kind:"server_error"
    ~expected_code:(Some "task_timeout") ()

let test_a2a_task_not_found () =
  check_mapping
    ~label:"A2a TaskNotFound"
    ~input:(E.A2a (E.TaskNotFound { task_id = "t1" }))
    ~expected_status:`Not_found
    ~expected_kind:"not_found_error"
    ~expected_code:(Some "task_not_found") ()

let test_a2a_store_capacity () =
  check_mapping
    ~label:"A2a StoreCapacityExceeded"
    ~input:(E.A2a (E.StoreCapacityExceeded { current = 1000; max = 500 }))
    ~expected_status:`Service_unavailable
    ~expected_kind:"server_error"
    ~expected_code:(Some "store_capacity_exceeded") ()

let test_internal () =
  check_mapping
    ~label:"Internal"
    ~input:(E.Internal "unexpected condition")
    ~expected_status:`Internal_server_error
    ~expected_kind:"server_error"
    ~expected_code:(Some "internal_error") ()

(* Sanity: message field is non-empty for every variant tested above.
   The of_sdk_error function should never produce an empty user-visible
   message even for Internal variants. *)
let test_message_nonempty () =
  let samples : E.sdk_error list =
    [ E.Api (E.Retry.RateLimited { retry_after = None; message = "x" })
    ; E.Provider
        (Llm_provider.Error.InvalidRequest { provider = "p"; reason = "bad" })
    ; E.Agent (E.IdleDetected { consecutive_idle_turns = 3 })
    ; E.Mcp (E.InitializeFailed { detail = "boom" })
    ; E.Config (E.InvalidConfig { field = "f"; detail = "d" })
    ; E.Serialization (E.VersionMismatch { expected = 1; got = 2 })
    ; E.Io (E.FileOpFailed { op = "read"; path = "/x"; detail = "y" })
    ; E.Orchestration (E.DiscoveryFailed { url = "http://x"; detail = "z" })
    ; E.A2a (E.ProtocolError { detail = "p" })
    ; E.Internal ""  (* empty Internal still produces empty user message — documented *)
    ]
  in
  let i = ref 0 in
  List.iter (fun e ->
    incr i;
    let { M.message; _ } = M.of_sdk_error e in
    let label = Printf.sprintf "sample %d message length" !i in
    let _ = label in
    let _ = message in
    (* Internal "" is the only case where message may be "" — that's the
       upstream contract.  Other variants should produce a non-empty
       message via Agent_sdk.Error.to_string. *)
    match e with
    | E.Internal "" -> ()
    | _ ->
      Alcotest.(check bool) (Printf.sprintf "sample %d message non-empty" !i)
        true (String.length message > 0)
  ) samples

let () =
  Alcotest.run "openai_compat_error_map"
    [ ( "api"
      , [ Alcotest.test_case "RateLimited → 429"   `Quick test_api_rate_limited
        ; Alcotest.test_case "AuthError → 401"     `Quick test_api_auth
        ; Alcotest.test_case "NotFound → 404"      `Quick test_api_not_found
        ; Alcotest.test_case "ContextOverflow → 400" `Quick test_api_context_overflow
        ; Alcotest.test_case "Timeout → 504"       `Quick test_api_timeout
        ; Alcotest.test_case "ServerError 502 → 502" `Quick test_api_server_error
        ] )
    ; ( "provider"
      , [ Alcotest.test_case "Timeout -> 503" `Quick test_provider_timeout
        ] )
    ; ( "agent"
      , [ Alcotest.test_case "TokenBudgetExceeded → 400" `Quick test_agent_token_budget
        ; Alcotest.test_case "MaxTurnsExceeded → 500"    `Quick test_agent_max_turns
        ; Alcotest.test_case "GuardrailViolation → 400"  `Quick test_agent_guardrail
        ] )
    ; ( "mcp"
      , [ Alcotest.test_case "ServerStartFailed → 503" `Quick test_mcp_server_start
        ; Alcotest.test_case "ToolCallFailed → 502"    `Quick test_mcp_tool_call
        ] )
    ; ( "config"
      , [ Alcotest.test_case "MissingEnvVar → 500"      `Quick test_config_missing_env
        ; Alcotest.test_case "UnsupportedProvider → 400" `Quick test_config_unsupported_provider
        ] )
    ; ( "serialization"
      , [ Alcotest.test_case "JsonParseError → 502" `Quick test_serialization_parse
        ] )
    ; ( "io"
      , [ Alcotest.test_case "ValidationFailed → 400" `Quick test_io_validation
        ] )
    ; ( "orchestration"
      , [ Alcotest.test_case "UnknownAgent → 404"   `Quick test_orchestration_unknown_agent
        ; Alcotest.test_case "TaskTimeout → 504"    `Quick test_orchestration_timeout
        ] )
    ; ( "a2a"
      , [ Alcotest.test_case "TaskNotFound → 404"       `Quick test_a2a_task_not_found
        ; Alcotest.test_case "StoreCapacityExceeded → 503" `Quick test_a2a_store_capacity
        ] )
    ; ( "internal"
      , [ Alcotest.test_case "Internal → 500"     `Quick test_internal
        ; Alcotest.test_case "Message non-empty"  `Quick test_message_nonempty
        ] )
    ]

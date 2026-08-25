(** Mapping tests for [Keeper_runtime_failure_route].

    Totality over [Agent_core.Error.t] is compiler-enforced (the
    route function has no catch-all); these tests pin the mapping opinion
    per class and the typed retry_after extraction so a refactor cannot
    silently move a class between routes. *)

module KFR = Keeper_runtime_failure_route

let route_of_agent_core_error = KFR.route_of_error ~boundary:KFR.Agent_core_execution
let route_of_masc_error = KFR.route_of_error ~boundary:KFR.Masc_execution

let route = Alcotest.testable (fun fmt r -> Format.pp_print_string fmt (KFR.route_kind_label r ^ ":" ^ KFR.route_class_label r)) ( = )

let check_route name expected err =
  Alcotest.check route name expected (route_of_agent_core_error err)

let check_masc_route name expected err =
  Alcotest.check route name expected (route_of_masc_error err)

let internal_err masc_internal =
  Keeper_internal_error.core_error_of_masc_internal_error masc_internal

let test_api_rate_limited_threads_hint () =
  check_route
    "soft 429 preserves provider retry-after"
    (KFR.Retry_after_observed { retry_class = KFR.Rate_limited; retry_after = Some 30.0 })
    (Agent_core.Error.Api
       (Llm_provider.Retry.RateLimited
          { retry_after = Some 30.0; message = "slow down" }))

let test_api_quota_message_does_not_override_rate_limit () =
  let err =
    Agent_core.Error.Api
      (Llm_provider.Retry.RateLimited
         { retry_after = None; message = "You have exceeded your current quota." })
  in
  check_route
    "rate-limit prose cannot invent hard quota"
    (KFR.Retry_after_observed { retry_class = KFR.Rate_limited; retry_after = None })
    err;
  check_route
    "PaymentRequired is the typed API hard-quota signal"
    (KFR.Retry_after_observed { retry_class = KFR.Hard_quota; retry_after = None })
    (Agent_core.Error.Api
       (Llm_provider.Retry.PaymentRequired { message = "billing required" }))

let test_api_overloaded_is_backpressure () =
  check_route
    "typed Overloaded stays transient backpressure (#23483)"
    (KFR.Retry_after_observed
       { retry_class = KFR.Capacity_backpressure; retry_after = None })
    (Agent_core.Error.Api (Llm_provider.Retry.Overloaded { message = "overloaded" }))

let test_api_server_error_uses_typed_variant () =
  check_route
    "ServerError does not reinterpret status codes"
    (KFR.Retry_after_observed { retry_class = KFR.Server_error; retry_after = None })
    (Agent_core.Error.Api
       (Llm_provider.Retry.ServerError { status = 524; message = "timeout" }));
  check_route
    "typed ServerError remains a server error for an unusual status"
    (KFR.Retry_after_observed { retry_class = KFR.Server_error; retry_after = None })
    (Agent_core.Error.Api
       (Llm_provider.Retry.ServerError { status = 418; message = "teapot" }))

let test_api_auth_rotates_invalid_request_judges () =
  check_route
    "auth error rotates (credentials differ per runtime)"
    (KFR.Rotate_now { rotate = KFR.Auth_failed })
    (Agent_core.Error.Api (Llm_provider.Retry.AuthError { message = "401" }));
  check_route
    "authorization error rotates (credential scopes differ per runtime)"
    (KFR.Rotate_now { rotate = KFR.Auth_failed })
    (Agent_core.Error.Api
       (Llm_provider.Retry.AuthorizationError { message = "403" }));
  check_route
    "provider authorization error rotates"
    (KFR.Rotate_now { rotate = KFR.Auth_failed })
    (Agent_core.Error.Provider
       (Llm_provider.Error.AuthorizationError
          { provider = "provider"; detail = "403" }));
  match
    route_of_agent_core_error
      (Agent_core.Error.Api
         (Llm_provider.Retry.InvalidRequest
            { message = "bad body"
            ; reason = Llm_provider.Retry.Unknown_invalid_request
            }))
  with
  | KFR.Exhausted_visible_alive { terminal = KFR.Deterministic_request; _ } -> ()
  | other ->
    Alcotest.failf "invalid request should exhaust, got %s"
      (KFR.route_kind_label other)

let test_api_input_capacity_is_terminal_judgment () =
  let constraint_ =
    Llm_provider.Serving_constraint.make
      ~source_kind:Llm_provider.Serving_constraint.Probe
      ~source_ref:"probe://incident/2793"
      ~checked_at_unix_s:0
      ~confidence:Llm_provider.Serving_constraint.High
      ~expires_at_unix_s:200
      ~accepted_through:524298
      ~rejected_from:524299
      ()
    |> Result.get_ok
  in
  let error reason =
    Agent_core.Error.Api
      (Llm_provider.Retry.InputCapacity
         { message = "typed capacity"; constraint_; reason })
  in
  check_route
    "accepted bound remains a deterministic terminal observation"
    (KFR.Exhausted_visible_alive
       { terminal = KFR.Deterministic_request
       ; provenance = KFR.Agent_core_api_error
       ; detail =
           Agent_core.Error.to_string
             (error
                (Llm_provider.Retry.Serving_constraint_rejected
                   (Llm_provider.Serving_constraint.Input_rejected
                      { input_tokens = 524299
                      ; accepted_through = 524298
                      ; rejected_from = 524299
                      })))
           |> Keeper_internal_error.cap_blocker_detail
       })
    (error
       (Llm_provider.Retry.Serving_constraint_rejected
          (Llm_provider.Serving_constraint.Input_rejected
             { input_tokens = 524299
             ; accepted_through = 524298
             ; rejected_from = 524299
             })));
  let measurement_unavailable =
    error
      (Llm_provider.Retry.Token_measurement_unavailable
         Llm_provider.Input_token_count.Anthropic_messages_count_tokens)
  in
  check_route
    "measurement-unavailable remains a terminal observation"
    (KFR.Exhausted_visible_alive
       { terminal = KFR.Deterministic_request
       ; provenance = KFR.Agent_core_api_error
       ; detail =
           Agent_core.Error.to_string measurement_unavailable
           |> Keeper_internal_error.cap_blocker_detail
       })
    measurement_unavailable

let test_provider_quota_family_threads_hint () =
  check_route
    "provider HardQuota preserves retry-after"
    (KFR.Retry_after_observed { retry_class = KFR.Hard_quota; retry_after = Some 3600.0 })
    (Agent_core.Error.Provider
       (Llm_provider.Error.HardQuota
          { provider = "glm"; retry_after = Some 3600.0; detail = "balance 0" }));
  check_route
    "provider CapacityExhausted stays typed"
    (KFR.Retry_after_observed
       { retry_class = KFR.Capacity_backpressure; retry_after = None })
    (Agent_core.Error.Provider
       (Llm_provider.Error.CapacityExhausted
          { scope = Llm_provider.Error.CapacityUnknown
          ; affected = []
          ; retry_after = None
          ; detail = "pool saturated"
          }))

let test_provider_config_judges () =
  match
    route_of_agent_core_error
      (Agent_core.Error.Provider
         (Llm_provider.Error.MissingApiKey { var_name = "GLM_API_KEY" }))
  with
  | KFR.Exhausted_visible_alive { terminal = KFR.Config_mismatch; _ } -> ()
  | other ->
    Alcotest.failf "missing api key should exhaust config, got %s"
      (KFR.route_kind_label other)

let test_provider_wire_error_is_provider_integration () =
  match
    route_of_agent_core_error
      (Agent_core.Error.Provider
         (Llm_provider.Error.ProviderWireError
            { provider = "glm"
            ; format = Llm_provider.Http_client.Sse
            ; kind = Llm_provider.Http_client.Malformed_payload
            ; detail = "malformed JSON"
            }))
  with
  | KFR.Exhausted_visible_alive
      { terminal = KFR.Provider_integration
      ; provenance = KFR.Agent_core_provider_error
      ; _
      } -> ()
  | other ->
    Alcotest.failf "provider wire error should exhaust provider integration, got %s"
      (KFR.route_kind_label other)

let test_masc_internal_backpressure_hint () =
  let err =
    internal_err
      (Keeper_internal_error.Capacity_backpressure
         { runtime_id = "glm-coding.glm-5-turbo"
         ; source = Keeper_internal_error.Provider_capacity
         ; detail = "429 burst"
         ; retry_after = Keeper_internal_error.Explicit 45.0
         })
  in
  check_masc_route
    "masc backpressure carries typed Explicit hint"
    (KFR.Retry_after_observed
       { retry_class = KFR.Capacity_backpressure; retry_after = Some 45.0 })
    err;
  Alcotest.(check (option (float 1e-6)))
    "retry_after_of_route extracts the hint"
    (Some 45.0)
    (KFR.retry_after_of_route (route_of_masc_error err))

let test_masc_internal_terminal_classes () =
  (match
     route_of_masc_error
       (internal_err
          (Keeper_internal_error.Internal_contract_rejected { reason = "empty" }))
   with
   | KFR.Exhausted_visible_alive
       { terminal = KFR.Internal_opaque
       ; provenance = KFR.Masc_internal_error
       ; _
       } ->
     ()
   | other ->
     Alcotest.failf "internal contract rejection should remain opaque, got %s"
       (KFR.route_kind_label other));
  check_masc_route
    "capacity-exhausted runtime stays typed"
    (KFR.Retry_after_observed
       { retry_class = KFR.Capacity_backpressure; retry_after = None })
    (internal_err
       (Keeper_internal_error.Runtime_exhausted
          { runtime_id = "r"; reason = Keeper_internal_error.Capacity_exhausted }));
  check_masc_route
    "session conflict rotates"
    (KFR.Rotate_now { rotate = KFR.Runtime_exhausted })
    (internal_err
       (Keeper_internal_error.Runtime_exhausted
          { runtime_id = "r"; reason = Keeper_internal_error.Session_conflict }))

let test_non_provider_families_judge () =
  let raw_internal = Agent_core.Error.Internal "boom" in
  (match route_of_agent_core_error raw_internal with
   | KFR.Exhausted_visible_alive
       { terminal = KFR.Internal_opaque; provenance = KFR.Agent_core_internal_error; _ } ->
     ()
   | other ->
     Alcotest.failf "raw Internal should exhaust, got %s" (KFR.route_kind_label other));
  (match route_of_masc_error raw_internal with
   | KFR.Exhausted_visible_alive
       { terminal = KFR.Internal_opaque; provenance = KFR.Masc_internal_error; _ } ->
     ()
   | other ->
     Alcotest.failf
       "MASC-produced raw Internal must preserve its actual boundary, got %s"
       (KFR.route_kind_label other));
  match
    route_of_agent_core_error
      (Agent_core.Error.Mcp (Agent_core.Error.InitializeFailed { detail = "handshake" }))
  with
  | KFR.Exhausted_visible_alive { terminal = KFR.Protocol_error; _ } -> ()
  | other ->
    Alcotest.failf "mcp error should exhaust protocol, got %s"
      (KFR.route_kind_label other)

let () =
  Alcotest.run
    "keeper_runtime_failure_route"
    [ ( "api"
      , [ Alcotest.test_case "rate limited hint" `Quick test_api_rate_limited_threads_hint
        ; Alcotest.test_case
            "quota prose stays rate limited"
            `Quick
            test_api_quota_message_does_not_override_rate_limit
        ; Alcotest.test_case "overloaded backpressure" `Quick test_api_overloaded_is_backpressure
        ; Alcotest.test_case
            "server error typed variant"
            `Quick
            test_api_server_error_uses_typed_variant
        ; Alcotest.test_case "auth rotates, invalid exhausts" `Quick test_api_auth_rotates_invalid_request_judges
        ; Alcotest.test_case
            "input capacity is terminal observation"
            `Quick
            test_api_input_capacity_is_terminal_judgment
        ] )
    ; ( "provider"
      , [ Alcotest.test_case "quota family hints" `Quick test_provider_quota_family_threads_hint
        ; Alcotest.test_case "config exhausts" `Quick test_provider_config_judges
        ; Alcotest.test_case
            "wire error is provider integration"
            `Quick
            test_provider_wire_error_is_provider_integration
        ] )
    ; ( "masc_internal"
      , [ Alcotest.test_case "backpressure hint" `Quick test_masc_internal_backpressure_hint
        ; Alcotest.test_case "terminal classes" `Quick test_masc_internal_terminal_classes
        ] )
    ; ( "families"
      , [ Alcotest.test_case "non-provider terminal" `Quick test_non_provider_families_judge ] )
    ]

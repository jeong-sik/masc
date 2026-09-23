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
            ; reason = Llm_provider.Retry.Json_parse_error
            }))
  with
  | KFR.Exhausted_visible_alive { terminal = KFR.Deterministic_request; _ } -> ()
  | other ->
    Alcotest.failf "an unparsed request should exhaust, got %s"
      (KFR.route_kind_label other)

(* #33057: the driver already moves a lane to its next candidate when masc's
   own pre-wire policy refuses the attempt, but the route labelled that
   failure a deterministic terminal one. The label now says rotate. A
   provider's own refusal of the body rotates too, because the walk moves on
   it (#37631); only a JSON parse failure stays terminal. *)
let test_api_attempt_rejected_routes_as_rotation () =
  check_route
    "pre-wire policy refusal rotates"
    (KFR.Rotate_now { rotate = KFR.Attempt_rejected })
    (Agent_core.Error.Api
       (Llm_provider.Retry.InvalidRequest
          { message = "reasoning effort 'xhigh' is outside the ladder for this model"
          ; reason = Llm_provider.Retry.Attempt_rejected
          }));
  List.iter
    (fun (label, reason) ->
      match
        route_of_agent_core_error
          (Agent_core.Error.Api
             (Llm_provider.Retry.InvalidRequest { message = label; reason }))
      with
      | KFR.Exhausted_visible_alive { terminal = KFR.Deterministic_request; _ } -> ()
      | other ->
        Alcotest.failf "%s should stay terminal, got %s:%s" label
          (KFR.route_kind_label other) (KFR.route_class_label other))
    [ "json parse error", Llm_provider.Retry.Json_parse_error ];
  List.iter
    (fun (label, reason) ->
      check_route
        (label ^ " rotates to the next candidate")
        (KFR.Rotate_now { rotate = KFR.Request_refused })
        (Agent_core.Error.Api
           (Llm_provider.Retry.InvalidRequest { message = label; reason })))
    [ "unknown 400", Llm_provider.Retry.Unknown_invalid_request
    ; ( "413"
      , Llm_provider.Retry.Request_body_refused_by_provider { status = 413 } )
    ]

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

let empty_completion stop_reason = KFR.Empty_completion { stop_reason }

let empty_completion_error stop_reason =
  Agent_core.Error.Provider
    (Llm_provider.Error.EmptyCompletion
       { provider = "openrouter"
       ; stop_reason
       ; detail = "empty assistant turn"
       })
;;

let test_empty_completion_keeps_answer_observation () =
  List.iter
    (fun stop_reason ->
       let error = empty_completion_error stop_reason in
       let route = route_of_agent_core_error error in
       check_route
         "typed empty completion keeps its stop reason"
         (KFR.Retry_after_observed
            { retry_class = empty_completion stop_reason; retry_after = None })
         error;
       Alcotest.(check bool)
         "the provider completed the request, so the input was observed"
         true
         (KFR.response_observed route);
       Alcotest.(check string)
         "the low-cardinality class label keeps the typed reason"
         ("empty_completion_"
          ^ Llm_provider.Types.stop_reason_to_metric_label stop_reason)
         (KFR.route_class_label route))
    [ Agent_core.Types.EndTurn
    ; Agent_core.Types.StopToolUse
    ; Agent_core.Types.MaxTokens
    ; Agent_core.Types.StopSequence
    ; Agent_core.Types.Refusal
    ; Agent_core.Types.ContentFilter
    ; Agent_core.Types.RepetitionTruncation
    ; Agent_core.Types.PauseTurn
    ; Agent_core.Types.Compaction
    ; Agent_core.Types.ContextWindowExceeded
    ; Agent_core.Types.UnmatchedToolCalls
    ; Agent_core.Types.Unknown "future_provider_reason"
    ]
;;

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


(* RFC last-path-resumes-after-progress §4: the stream ended before the
   completion contract's stop. The provider took the request and the bytes
   that would have said why never came, so the failure passes with time, as a
   dropped transport does. The other wire kinds are defects in what did
   arrive: the same path sends them again, so they rotate rather than wait. *)
let test_wire_error_kinds_split_on_what_arrived () =
  let wire kind =
    route_of_agent_core_error
      (Agent_core.Error.Provider
         (Llm_provider.Error.ProviderWireError
            { provider = "openrouter"
            ; format = Llm_provider.Http_client.Sse
            ; kind
            ; detail = "stream_terminated_without_stop_reason"
            }))
  in
  (match wire Llm_provider.Http_client.Incomplete_stream with
   | KFR.Retry_after_observed { retry_class = KFR.Network_transient; retry_after = None } -> ()
   | other ->
     Alcotest.failf "an incomplete stream should observe a transient failure, got %s:%s"
       (KFR.route_kind_label other) (KFR.route_class_label other));
  List.iter
    (fun kind ->
       match wire kind with
       | KFR.Rotate_now { rotate = KFR.Provider_wire_defect } -> ()
       | other ->
         Alcotest.failf "%s should rotate as a wire defect, got %s:%s"
           (Llm_provider.Http_client.provider_wire_error_kind_to_string kind)
           (KFR.route_kind_label other) (KFR.route_class_label other))
    [ Llm_provider.Http_client.Malformed_payload
    ; Llm_provider.Http_client.Unknown_event
    ; Llm_provider.Http_client.Oversized_payload
    ]

(* A generation the provider ended without saying why reads as the provider
   failing to serve the call, the same class its documented shape carries when
   the provider does attach its object. *)
let test_an_interrupted_generation_observes_a_server_failure () =
  match
    Llm_provider.Error.of_http_error
      ~provider:"openrouter"
      (Llm_provider.Http_client.ProviderFailure
         { kind = Llm_provider.Http_client.Provider_interrupted
         ; message =
             "SSE stream error: the provider ended the choice with finish_reason error"
         })
  with
  | Llm_provider.Error.ProviderUnavailable _ as provider_error ->
    (match route_of_agent_core_error (Agent_core.Error.Provider provider_error) with
     | KFR.Retry_after_observed { retry_class = KFR.Server_error; retry_after = None } -> ()
     | other ->
       Alcotest.failf "an interrupted generation should observe a server failure, got %s:%s"
         (KFR.route_kind_label other) (KFR.route_class_label other))
  | other ->
    Alcotest.failf "an interruption should read as the provider failing, got %s"
      (Llm_provider.Error.to_string other)

let test_provider_wire_error_rotates () =
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
  | KFR.Rotate_now { rotate = KFR.Provider_wire_defect } -> ()
  | other ->
    Alcotest.failf "provider wire error should rotate, got %s"
      (KFR.route_kind_label other)

(* A 5xx the provider marked as permanent: the walk rotates on every 5xx, so
   the route says rotate. A non-transient code outside the 5xx class is not a
   server failure and stays a provider integration defect. *)
let test_non_transient_server_error_rotates_on_5xx () =
  let server code =
    Agent_core.Error.Provider
      (Llm_provider.Error.ServerError
         { provider = "p"; code; transient = false; detail = "fatal" })
  in
  check_route
    "non-transient 500 rotates"
    (KFR.Rotate_now { rotate = KFR.Server_error_not_transient })
    (server 500);
  match route_of_agent_core_error (server 418) with
  | KFR.Exhausted_visible_alive { terminal = KFR.Provider_integration; _ } -> ()
  | other ->
    Alcotest.failf "a non-5xx server error should exhaust, got %s:%s"
      (KFR.route_kind_label other) (KFR.route_class_label other)

(* A generation that repeated itself arrived intact: it is the model's
   failure, so the lane rotates to another model instead of exhausting the
   turn as a provider integration defect (which counted toward the crash
   threshold). The model did answer, so the input was observed. *)
let test_repeating_generation_rotates_the_model () =
  let route =
    route_of_agent_core_error
      (Agent_core.Error.Provider
         (Llm_provider.Error.RepeatingGeneration
            { provider = "ollama_cloud"
            ; shape = Llm_provider.Types.Repeated_reasoning_cycle
            ; occurrences = 3
            ; unit_bytes = 749
            ; detail = "reasoning repeated one 749-byte unit 3 times verbatim"
            }))
  in
  (match route with
   | KFR.Rotate_now { rotate = KFR.Generation_repeated } -> ()
   | other ->
     Alcotest.failf "a repeating generation should rotate the model, got %s"
       (KFR.route_kind_label other));
  Alcotest.(check string) "the rotate class has its own label" "generation_repeated"
    (KFR.route_class_label route);
  Alcotest.(check bool) "the model answered, so the input was observed" true
    (KFR.response_observed route)

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

(* #32956: the heartbeat settles a Gate continuation on a failed turn only
   when the provider answered the request. Every class is named on one side
   so a new class has to be placed. *)
let test_response_observed_per_class () =
  let retry retry_class =
    KFR.Retry_after_observed { retry_class; retry_after = None }
  in
  let rotate rotate = KFR.Rotate_now { rotate } in
  let terminal terminal =
    KFR.Exhausted_visible_alive
      { terminal; provenance = KFR.Masc_internal_error; detail = "" }
  in
  let check_observed expected route =
    Alcotest.(check bool)
      (KFR.route_kind_label route ^ ":" ^ KFR.route_class_label route)
      expected
      (KFR.response_observed route)
  in
  List.iter
    (check_observed false)
    [ retry KFR.Rate_limited
    ; retry KFR.Hard_quota
    ; retry KFR.Capacity_backpressure
    ; retry KFR.Server_error
    ; retry KFR.Network_transient
    ; retry KFR.Provider_timeout
    ; rotate KFR.Auth_failed
    ; rotate KFR.Model_unavailable
    ; rotate KFR.Resumable_cli_session
    ; rotate KFR.Candidates_filtered
    ; rotate KFR.Attempt_rejected
    ; rotate KFR.Refusal_body_not_received
    ; rotate KFR.Runtime_exhausted
    ; rotate KFR.Request_refused
    ; rotate KFR.Provider_wire_defect
    ; rotate KFR.Server_error_not_transient
    ; terminal KFR.Deterministic_request
    ; terminal KFR.Context_overflow
    ; terminal KFR.Session_claim_refused
    ; terminal KFR.Protocol_error
    ; terminal KFR.Config_mismatch
    ; terminal KFR.Provider_integration
    ; terminal KFR.Internal_opaque
    ; terminal (KFR.Provider_attempt_effect_fenced KFR.Fenced_observation_unavailable)
    ; terminal (KFR.Tool_correction_lost KFR.Fenced_observation_unavailable)
    ];
  List.iter
    (check_observed true)
    [ retry (empty_completion Agent_core.Types.EndTurn)
    ; rotate KFR.No_progress_empty
    ; rotate KFR.No_progress_thinking_only
    ; rotate KFR.No_progress_truncated
    ; rotate KFR.Generation_repeated
    ; terminal KFR.Contract_violation
    ; terminal KFR.Terminal_effect_dependency_unavailable
    ; terminal KFR.Terminal_effect_policy_rejection
    ; terminal KFR.Terminal_effect_runtime_failure
    ; terminal KFR.Terminal_effect_workflow_rejection
    ; terminal KFR.Terminal_effect_operator_cancelled
    ; terminal (KFR.Provider_attempt_effect_fenced KFR.Fenced_effect_attempted)
    ; terminal (KFR.Tool_correction_lost KFR.Fenced_effect_attempted)
    ]

(* Through production routing: the MaxTokens accept rejection the #32956
   turns ended on is an observed answer; a provider timeout is not. *)
let test_response_observed_through_route_of_error () =
  let truncated =
    internal_err
      (Keeper_internal_error.Accept_rejected
         { scope = "ollama_cloud.deepseek-v4-flash-0731"
         ; model = Some "deepseek-v4-flash-0731"
         ; reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
         ; response_shape = None
         ; stop_reason = Some Agent_core.Types.MaxTokens
         ; reason = "response rejected by accept"
         })
  in
  Alcotest.(check bool)
    "a MaxTokens accept rejection is an observed answer"
    true
    (KFR.response_observed (route_of_masc_error truncated));
  Alcotest.(check bool)
    "a provider timeout is not"
    false
    (KFR.response_observed
       (route_of_agent_core_error
          (Agent_core.Error.Api
             (Llm_provider.Retry.Timeout { message = "deadline"; phase = None }))))

(* The two effect fences carry what the lane had observed. The codex lane
   fences with [Observation_unavailable] when the turn input could not be
   written ([Keeper_codex_runtime] Turn_input_write_failed) and the
   claude-code lane sets it when the process is spawned ([on_spawned]), so a
   spawn-only failure arrives the same way: no answer is on record. A fence
   after a tool handler was entered is an answer. *)
let test_response_observed_fences_follow_the_disposition () =
  let fenced effect_disposition ~runtime_id ~diagnostic =
    internal_err
      (Keeper_internal_error.Provider_attempt_effect_fenced
         { runtime_id
         ; effect_disposition
         ; cause =
             Keeper_internal_error.Fenced_core
               (Keeper_request_failure_core.of_core_error
                  (Agent_core.Error.Internal diagnostic))
         })
  in
  let lost effect_disposition ~runtime_id =
    internal_err
      (Keeper_internal_error.Tool_correction_lost
         { runtime_id
         ; effect_disposition
         ; reject_count = 2
         ; cause =
             Keeper_internal_error.Fenced_core
               (Keeper_request_failure_core.of_core_error
                  (Agent_core.Error.Internal
                     "turn died after two corrective tool rejections"))
         })
  in
  let observed label err =
    Alcotest.(check bool) label true (KFR.response_observed (route_of_masc_error err))
  in
  let unobserved label err =
    Alcotest.(check bool) label false (KFR.response_observed (route_of_masc_error err))
  in
  unobserved
    "codex: the turn input could not be written, so no answer exists"
    (fenced
       Keeper_provider_attempt_effect_core.Observation_unavailable
       ~runtime_id:"codex_app_server.gpt-5.5"
       ~diagnostic:"Turn_input_write_failed");
  unobserved
    "claude-code: the process was spawned and failed before any answer"
    (fenced
       Keeper_provider_attempt_effect_core.Observation_unavailable
       ~runtime_id:"claude_code.opus"
       ~diagnostic:"Process_exited before a turn result");
  unobserved
    "a lost correction with no observation is not an answer either"
    (lost
       Keeper_provider_attempt_effect_core.Observation_unavailable
       ~runtime_id:"codex_app_server.gpt-5.5");
  observed
    "a fence after a tool handler was entered is an answer"
    (fenced
       Keeper_provider_attempt_effect_core.Effect_attempted
       ~runtime_id:"antigravity_subscription.gemini-3-6-flash-high"
       ~diagnostic:"stream closed after a tool effect");
  observed
    "a lost correction after a tool handler was entered is an answer"
    (lost
       Keeper_provider_attempt_effect_core.Effect_attempted
       ~runtime_id:"antigravity_subscription.gemini-3-6-flash-high");
  Alcotest.(check string)
    "the unavailable observation keeps its own label"
    "provider_attempt_effect_fenced_observation_unavailable"
    (KFR.route_class_label
       (route_of_masc_error
          (fenced
             Keeper_provider_attempt_effect_core.Observation_unavailable
             ~runtime_id:"codex_app_server.gpt-5.5"
             ~diagnostic:"Turn_input_write_failed")))


(* RFC last-path-resumes-after-progress §3.3: which failures pass with time on
   the path that answered them. A quota resumes only with a reset it named. *)
let test_route_resumes_on_same_path_per_class () =
  let retry ?retry_after retry_class =
    KFR.Retry_after_observed { retry_class; retry_after }
  in
  let rotate rotate = KFR.Rotate_now { rotate } in
  let terminal terminal =
    KFR.Exhausted_visible_alive
      { terminal; provenance = KFR.Masc_internal_error; detail = "" }
  in
  let check_resumes expected (label, route) =
    Alcotest.(check bool)
      (label ^ " " ^ KFR.route_kind_label route ^ ":" ^ KFR.route_class_label route)
      expected
      (KFR.route_resumes_on_same_path route)
  in
  List.iter
    (check_resumes true)
    [ "", retry KFR.Rate_limited
    ; "with a hint", retry ~retry_after:30.0 KFR.Rate_limited
    ; "", retry KFR.Capacity_backpressure
    ; "end turn", retry (empty_completion Agent_core.Types.EndTurn)
    ; "max tokens", retry (empty_completion Agent_core.Types.MaxTokens)
    ; "stop sequence", retry (empty_completion Agent_core.Types.StopSequence)
    ; "", retry KFR.Server_error
    ; "", retry KFR.Network_transient
    ; "", retry KFR.Provider_timeout
    ; "with a reset", retry ~retry_after:3600.0 KFR.Hard_quota
    ];
  List.iter
    (check_resumes false)
    [ "without a reset", retry KFR.Hard_quota
    ; "refusal", retry (empty_completion Agent_core.Types.Refusal)
    ; "content filter", retry (empty_completion Agent_core.Types.ContentFilter)
    ; ( "repetition truncation"
      , retry (empty_completion Agent_core.Types.RepetitionTruncation) )
    ; "tool use", retry (empty_completion Agent_core.Types.StopToolUse)
    ; "pause turn", retry (empty_completion Agent_core.Types.PauseTurn)
    ; "compaction", retry (empty_completion Agent_core.Types.Compaction)
    ; ( "context window exceeded"
      , retry (empty_completion Agent_core.Types.ContextWindowExceeded) )
    ; "unmatched tool calls", retry (empty_completion Agent_core.Types.UnmatchedToolCalls)
    ; ( "unknown"
      , retry (empty_completion (Agent_core.Types.Unknown "future_provider_reason")) )
    ; "with a zero reset", retry ~retry_after:0.0 KFR.Hard_quota
    ; "with a negative reset", retry ~retry_after:(-5.0) KFR.Hard_quota
    ; "with a NaN reset", retry ~retry_after:Float.nan KFR.Hard_quota
    ; "", rotate KFR.Auth_failed
    ; "", rotate KFR.Model_unavailable
    ; "", rotate KFR.Resumable_cli_session
    ; "", rotate KFR.Candidates_filtered
    ; "", rotate KFR.Runtime_exhausted
    ; "", rotate KFR.No_progress_empty
    ; "", rotate KFR.No_progress_thinking_only
    ; "", rotate KFR.No_progress_truncated
    ; "", rotate KFR.Refusal_body_not_received
    ; "", rotate KFR.Generation_repeated
    ; "", rotate KFR.Attempt_rejected
    ; "", rotate KFR.Provider_reported_failure
    ; "", rotate KFR.Request_refused
    ; "", rotate KFR.Provider_wire_defect
    ; "", rotate KFR.Server_error_not_transient
    ; "", terminal KFR.Deterministic_request
    ; "", terminal KFR.Context_overflow
    ; "", terminal KFR.Session_claim_refused
    ; "", terminal KFR.Contract_violation
    ; "", terminal KFR.Protocol_error
    ; "", terminal KFR.Config_mismatch
    ; "", terminal KFR.Provider_integration
    ; "", terminal KFR.Terminal_effect_dependency_unavailable
    ; "", terminal KFR.Terminal_effect_policy_rejection
    ; "", terminal KFR.Terminal_effect_runtime_failure
    ; "", terminal KFR.Terminal_effect_workflow_rejection
    ; "", terminal KFR.Terminal_effect_operator_cancelled
    ; "", terminal (KFR.Provider_attempt_effect_fenced KFR.Fenced_effect_attempted)
    ; "", terminal (KFR.Provider_attempt_effect_fenced KFR.Fenced_observation_unavailable)
    ; "", terminal (KFR.Tool_correction_lost KFR.Fenced_effect_attempted)
    ; "", terminal (KFR.Tool_correction_lost KFR.Fenced_observation_unavailable)
    ; "", terminal KFR.Internal_opaque
    ]

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
            "attempt rejected routes as rotation"
            `Quick
            test_api_attempt_rejected_routes_as_rotation
        ; Alcotest.test_case
            "input capacity is terminal observation"
            `Quick
            test_api_input_capacity_is_terminal_judgment
        ] )
    ; ( "provider"
      , [ Alcotest.test_case "quota family hints" `Quick test_provider_quota_family_threads_hint
        ; Alcotest.test_case "config exhausts" `Quick test_provider_config_judges
        ; Alcotest.test_case
            "wire error rotates"
            `Quick
            test_provider_wire_error_rotates
        ; Alcotest.test_case
            "non-transient 5xx rotates"
            `Quick
            test_non_transient_server_error_rotates_on_5xx
        ; Alcotest.test_case
            "empty completion keeps answer observation"
            `Quick
            test_empty_completion_keeps_answer_observation
        ; Alcotest.test_case
            "wire error kinds split on what arrived"
            `Quick
            test_wire_error_kinds_split_on_what_arrived
        ; Alcotest.test_case
            "an interrupted generation observes a server failure"
            `Quick
            test_an_interrupted_generation_observes_a_server_failure
        ; Alcotest.test_case
            "repeating generation rotates the model"
            `Quick
            test_repeating_generation_rotates_the_model
        ] )
    ; ( "masc_internal"
      , [ Alcotest.test_case "backpressure hint" `Quick test_masc_internal_backpressure_hint
        ; Alcotest.test_case "terminal classes" `Quick test_masc_internal_terminal_classes
        ] )
    ; ( "families"
      , [ Alcotest.test_case "non-provider terminal" `Quick test_non_provider_families_judge ] )
    ; ( "response_observed"
      , [ Alcotest.test_case
            "every class is placed"
            `Quick
            test_response_observed_per_class
        ; Alcotest.test_case
            "through route_of_error"
            `Quick
            test_response_observed_through_route_of_error
        ; Alcotest.test_case
            "fences follow the lane's observation"
            `Quick
            test_response_observed_fences_follow_the_disposition
        ] )
    ; ( "route_resumes_on_same_path"
      , [ Alcotest.test_case
            "every class is placed"
            `Quick
            test_route_resumes_on_same_path_per_class
        ] )
    ]

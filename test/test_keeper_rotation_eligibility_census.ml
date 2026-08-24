(* Census of runtime-candidate rotation eligibility, per agent-core error class.

   [Keeper_turn_driver.attempt_runtime_candidates] owns the decision "does this
   lane move to its next declared candidate". The decision is reached through a
   chain — [lane_should_retry] -> [core_error_to_http_error] ->
   [Runtime_attempt_fsm.should_try_next] — where two of the three links can
   answer [false] for reasons that are invisible at the call site. Reading the
   chain predicts the outcome; this test measures it.

   Each case drives the real loop with two candidates: the first fails with the
   error under test, the second would succeed. Reaching the second candidate is
   rotation; stopping at the first is not. The recorded attempt list is the
   observation, so a change anywhere in the chain shows up here as a changed
   census row rather than as silently lost failover.

   Error classes are the ones observed on the live fleet, so each row carries
   the class's share of one day of keeper cycle failures (system_log
   2026-08-11, 284 [keeper cycle FAILED] lines). That count is context for
   which rows matter, not an assertion. *)

module Driver = Masc.Keeper_turn_driver

let first_candidate = "first.model"
let second_candidate = "second.model"

let emit_manifest_ignored ?status:_ ?decision:_ _event = ()

(* Attempted candidate ids, in order, for a lane whose first candidate fails
   with [error]. *)
let attempted_candidates error =
  let attempts = ref [] in
  let _result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"census"
      ~runtime_id_of:(fun candidate -> candidate)
      ~emit_runtime_manifest:emit_manifest_ignored
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        if String.equal candidate first_candidate
        then
          Error error, None, Masc.Keeper_provider_attempt_effect.No_effect_observed
        else if String.equal candidate second_candidate
        then
          Ok runtime_id, None, Masc.Keeper_provider_attempt_effect.No_effect_observed
        else Alcotest.failf "unexpected candidate %s" candidate)
      [ first_candidate; second_candidate ]
  in
  !attempts

let rotates error =
  match attempted_candidates error with
  | [ _first ] -> false
  | [ _first; _second ] -> true
  | other ->
    Alcotest.failf
      "census expects one or two attempts, got %d"
      (List.length other)

(* --- error class constructors, one per observed production failure --- *)

let provider_hard_quota =
  Agent_core.Error.Provider
    (Llm_provider.Error.HardQuota
       { provider = "claude_code"
       ; retry_after = None
       ; detail = "Claude Code subscription quota blocked"
       })

let provider_rate_limit =
  Agent_core.Error.Provider
    (Llm_provider.Error.RateLimit
       { provider = "claude_code"; retry_after = None; detail = "throttled" })

let provider_unavailable =
  Agent_core.Error.Provider
    (Llm_provider.Error.ProviderUnavailable
       { provider = "ollama_cloud"; detail = "provider unavailable" })

let provider_network_error =
  Agent_core.Error.Provider
    (Llm_provider.Error.NetworkError
       { provider = "ollama_cloud"
       ; kind = Llm_provider.Http_client.Unknown
       ; timeout_phase = None
       ; detail = "failed to resolve hostname: ollama.com"
       })

let provider_server_error_transient =
  Agent_core.Error.Provider
    (Llm_provider.Error.ServerError
       { provider = "ollama_cloud"
       ; code = 503
       ; transient = true
       ; detail = "upstream unavailable"
       })

let provider_reported_error =
  Agent_core.Error.Provider
    (Llm_provider.Error.ProviderReportedError
       { provider = "claude_code"
       ; error_type = Some "turn_failed"
       ; detail = "terminal subtype"
       })

let api_network_error =
  Agent_core.Error.Api
    (Agent_core.Retry.NetworkError
       { message = "failed to resolve hostname: ollama.com"
       ; kind = Llm_provider.Http_client.Unknown
       })

let api_payment_required =
  Agent_core.Error.Api
    (Agent_core.Retry.PaymentRequired { message = "quota exhausted" })

let api_rate_limited =
  Agent_core.Error.Api
    (Agent_core.Retry.RateLimited { message = "429"; retry_after = None })

let api_server_error =
  Agent_core.Error.Api
    (Agent_core.Retry.ServerError { status = 503; message = "unavailable" })

let api_context_overflow =
  Agent_core.Error.Api
    (Agent_core.Retry.ContextOverflow
       { message = "context window exceeded"; limit = Some 128_000 })

(* What a model-input projection returns when this candidate's declared
   ceiling cannot carry the turn. Built through the production constructor so
   the census measures the real path, not a hand-written copy of it. On
   2026-08-23 this refusal was reported as [Config (InvalidConfig _)] and the
   lane stopped at its first candidate for eight hours (#29676). *)
let projection_capacity_refusal =
  Runtime_model_input_tail_window.budget_error_to_core_error
    (Runtime_model_input_tail_window.Reservation_exceeds_capacity
       { capacity_bytes = 131_072
       ; reserved_bytes = 3_116
       ; undroppable_bytes = 141_937
       })

let api_invalid_request_unknown_model =
  Agent_core.Error.Api
    (Agent_core.Retry.InvalidRequest
       { message = "model not found"
       ; reason = Agent_core.Retry.Unknown_invalid_request
       })

let api_attempt_rejected =
  Agent_core.Provider_failure_attribution.core_error_of_http_error
    (Llm_provider.Http_client.AcceptRejected
       { reason = "selected runtime cannot encode the request" })

(* Until RFC-0370 §3.1, the Codex app-server boundary folded provider- and
   transport-side failures into [Internal] strings (the catch-all in
   [codex_error_to_core_error]); these three verbatim live-log classes
   document what that wire looked like, and that [Internal] itself remains
   non-rotating for genuine MASC defects. The typed rows below them are what
   the same failures carry after the boundary fix (mirroring the claude_code
   and antigravity conversions, which were already typed). *)
let internal_app_server_timeout =
  Agent_core.Error.Internal
    "Codex app-server turn timed out after 300.000s"

let internal_stream_disconnected =
  Agent_core.Error.Internal
    "Codex app-server turn failed: stream disconnected before completion"

let internal_remote_command_failed =
  Agent_core.Error.Internal
    "Codex app-server turn failed: Error running remote command"

(* Post-RFC-0370 typed forms of the same boundary failures. *)
let api_turn_budget_timeout =
  Agent_core.Error.Api
    (Agent_core.Retry.Timeout
       { message = "Codex app-server turn timed out after 300.000s"
       ; phase = None
       })

let provider_parse_error =
  Agent_core.Error.Provider
    (Llm_provider.Error.ParseError
       { detail = "turn: unsupported stream message type" })

let provider_unknown_variant =
  Agent_core.Error.Provider
    (Llm_provider.Error.UnknownVariant
       { type_name = "codex_app_server.server_request"; value = "applyPatch" })

let serialization_parse_error =
  Agent_core.Error.Serialization
    (Agent_core.Error.JsonParseError { detail = "result event: field missing" })

let config_invalid =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "model"; detail = "unknown model id" })

(* label, error, observed count of [keeper cycle FAILED] on 2026-08-11 *)
let census_rows =
  [ "provider:hard_quota", provider_hard_quota, 103
  ; "provider:network_error", provider_network_error, 62
  ; "internal:stream_disconnected", internal_stream_disconnected, 28
  ; "serialization:parse_error", serialization_parse_error, 29
  ; "internal:app_server_timeout", internal_app_server_timeout, 22
  ; "provider:reported_error", provider_reported_error, 14
  ; "api:context_overflow", api_context_overflow, 9
  ; "internal:remote_command_failed", internal_remote_command_failed, 4
  ; "api:invalid_request", api_invalid_request_unknown_model, 2
  ; "api:attempt_rejected", api_attempt_rejected, 0
  ; "api:turn_budget_timeout", api_turn_budget_timeout, 0
  ; "provider:parse_error", provider_parse_error, 0
  ; "provider:unknown_variant", provider_unknown_variant, 0
  ; "provider:rate_limit", provider_rate_limit, 0
  ; "provider:unavailable", provider_unavailable, 0
  ; "provider:server_error_transient", provider_server_error_transient, 0
  ; "api:network_error", api_network_error, 0
  ; "api:payment_required", api_payment_required, 0
  ; "api:rate_limited", api_rate_limited, 0
  ; "api:server_error", api_server_error, 0
  ; "config:invalid", config_invalid, 0
  ; "projection:capacity_refusal", projection_capacity_refusal, 0
  ]

let test_census_report () =
  Printf.printf
    "\n%-34s %-9s %s\n"
    "error class"
    "rotates"
    "cycle FAILED 2026-08-11";
  Printf.printf "%s\n" (String.make 72 '-');
  let rotating, blocked =
    List.fold_left
      (fun (rotating, blocked) (label, error, count) ->
        let rotated = rotates error in
        Printf.printf
          "%-34s %-9s %d\n"
          label
          (if rotated then "yes" else "NO")
          count;
        if rotated
        then rotating + count, blocked
        else rotating, blocked + count)
      (0, 0)
      census_rows
  in
  Printf.printf "%s\n" (String.make 72 '-');
  Printf.printf
    "failures in a class that can fail over: %d\n\
     failures in a class that cannot:        %d\n\n"
    rotating
    blocked

(* Measured baseline. A row flipping here means the rotation chain changed:
   confirm the new value is intended before updating the expectation.

   Two properties of this baseline are worth naming, because neither is
   predictable from reading [lane_should_retry] alone:

   - Every [Internal] row is [false]. [core_error_to_runtime_outcome] returns
     [None] for [Internal _], so [lane_should_retry] short-circuits before any
     status is consulted. The official-client runtimes (Codex app-server,
     Claude Code, Antigravity) carry provider- and transport-side failures in
     [Internal] because that is the constructor their subscription clients
     have, so a per-runtime transport failure on those three reaches the same
     decision as a MASC defect.

   - Quota reaches opposite decisions depending on which constructor carries
     it: [Provider (HardQuota _)] rotates, [Api (PaymentRequired _)] does not.
     The condition is the same; the routing differs. *)
let expected_rotation =
  [ "provider:hard_quota", true
  ; "provider:network_error", true
  ; "internal:stream_disconnected", false
  ; "serialization:parse_error", false
  ; "internal:app_server_timeout", false
  ; "provider:reported_error", true
  ; "api:context_overflow", true
  ; "internal:remote_command_failed", false
  ; "api:invalid_request", false
  ; "api:attempt_rejected", true
  ; "api:turn_budget_timeout", true
  ; "provider:parse_error", false
  ; "provider:unknown_variant", false
  ; "provider:rate_limit", true
  ; "provider:unavailable", true
  ; "provider:server_error_transient", true
  ; "api:network_error", true
  ; "api:payment_required", false
  ; "api:rate_limited", true
  ; "api:server_error", true
  ; "config:invalid", false
  ; "projection:capacity_refusal", true
  ]

let test_rotation_matches_baseline () =
  List.iter
    (fun (label, error, _count) ->
      let expected =
        match List.assoc_opt label expected_rotation with
        | Some expected -> expected
        | None -> Alcotest.failf "census row %S has no baseline entry" label
      in
      Alcotest.(check bool)
        (Printf.sprintf "%s rotates" label)
        expected
        (rotates error))
    census_rows

(* Every census row must carry a baseline entry and vice versa, so adding a row
   without a baseline (or leaving a stale baseline behind) fails instead of
   silently shrinking the census. *)
let test_census_and_baseline_agree_on_rows () =
  let census_labels =
    List.map (fun (label, _, _) -> label) census_rows |> List.sort compare
  in
  let baseline_labels =
    List.map fst expected_rotation |> List.sort compare
  in
  Alcotest.(check (list string))
    "census rows and baseline rows match"
    census_labels
    baseline_labels

let () =
  Alcotest.run
    "keeper_rotation_eligibility_census"
    [ ( "census"
      , [ Alcotest.test_case "report" `Quick test_census_report
        ; Alcotest.test_case
            "rows match baseline"
            `Quick
            test_census_and_baseline_agree_on_rows
        ; Alcotest.test_case
            "rotation matches measured baseline"
            `Quick
            test_rotation_matches_baseline
        ] )
    ]

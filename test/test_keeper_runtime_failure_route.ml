(** Mapping tests for [Keeper_runtime_failure_route] (RFC-0313 W2).

    Totality over [Agent_sdk.Error.sdk_error] is compiler-enforced (the
    route function has no catch-all); these tests pin the mapping opinion
    per class and the typed retry_after extraction so a refactor cannot
    silently move a class between routes. *)

module KFR = Keeper_runtime_failure_route

let route = Alcotest.testable (fun fmt r -> Format.pp_print_string fmt (KFR.route_kind_label r ^ ":" ^ KFR.route_class_label r)) ( = )

let check_route name expected err =
  Alcotest.check route name expected (KFR.route_of_error err)

let internal_err masc_internal =
  Keeper_internal_error.sdk_error_of_masc_internal_error masc_internal

let test_api_rate_limited_threads_hint () =
  check_route
    "soft 429 paces with hint"
    (KFR.Retry_after_pacing { pacing = KFR.Rate_limited; retry_after = Some 30.0 })
    (Agent_sdk.Error.Api
       (Llm_provider.Retry.RateLimited
          { retry_after = Some 30.0; message = "slow down" }))

let test_api_hard_quota_message_wins () =
  (* The message must be one [Retry.hard_quota_indicators] actually lists —
     "monthly quota reached" is not an indicator, so the original fixture
     asserted a classification the OAS predicate never made (surfaced on
     main once #23495's cancelled PR run finally executed this exe). *)
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.RateLimited
         { retry_after = None; message = "You have exceeded your current quota." })
  in
  match KFR.route_of_error err with
  | KFR.Retry_after_pacing { pacing = KFR.Hard_quota; _ } -> ()
  | (KFR.Retry_after_pacing _ | KFR.Rotate_now _ | KFR.Escalate_judgment _) as other ->
    (* Guards against OAS predicate drift: [Retry.is_hard_quota] owns the
       message classification; the route must stay a hard-quota pace. *)
    Alcotest.failf
      "hard-quota message must pace as hard quota, got %s:%s"
      (KFR.route_kind_label other)
      (KFR.route_class_label other)

let test_api_overloaded_is_backpressure () =
  check_route
    "typed Overloaded stays transient backpressure (#23483)"
    (KFR.Retry_after_pacing
       { pacing = KFR.Capacity_backpressure; retry_after = None })
    (Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded { message = "overloaded" }))

let test_api_server_error_status_split () =
  check_route
    "524 is gateway backpressure"
    (KFR.Retry_after_pacing
       { pacing = KFR.Capacity_backpressure; retry_after = None })
    (Agent_sdk.Error.Api
       (Llm_provider.Retry.ServerError { status = 524; message = "timeout" }));
  check_route
    "503 is transient server error"
    (KFR.Retry_after_pacing { pacing = KFR.Server_error; retry_after = None })
    (Agent_sdk.Error.Api
       (Llm_provider.Retry.ServerError { status = 503; message = "unavailable" }));
  match
    KFR.route_of_error
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.ServerError { status = 418; message = "teapot" }))
  with
  | KFR.Escalate_judgment { judgment = KFR.Provider_integration; _ } -> ()
  | other ->
    Alcotest.failf "sub-500 server error should judge, got %s"
      (KFR.route_kind_label other)

let test_api_auth_rotates_invalid_request_judges () =
  check_route
    "auth error rotates (credentials differ per runtime)"
    (KFR.Rotate_now { rotate = KFR.Auth_failed })
    (Agent_sdk.Error.Api (Llm_provider.Retry.AuthError { message = "401" }));
  match
    KFR.route_of_error
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.InvalidRequest
            { message = "bad body"
            ; reason = Llm_provider.Retry.Unknown_invalid_request
            }))
  with
  | KFR.Escalate_judgment { judgment = KFR.Deterministic_request; _ } -> ()
  | other ->
    Alcotest.failf "invalid request should judge, got %s"
      (KFR.route_kind_label other)

let test_provider_quota_family_threads_hint () =
  check_route
    "provider HardQuota paces with hint"
    (KFR.Retry_after_pacing { pacing = KFR.Hard_quota; retry_after = Some 3600.0 })
    (Agent_sdk.Error.Provider
       (Llm_provider.Error.HardQuota
          { provider = "glm"; retry_after = Some 3600.0; detail = "balance 0" }));
  check_route
    "provider CapacityExhausted paces"
    (KFR.Retry_after_pacing
       { pacing = KFR.Capacity_backpressure; retry_after = None })
    (Agent_sdk.Error.Provider
       (Llm_provider.Error.CapacityExhausted
          { scope = Llm_provider.Error.CapacityUnknown
          ; affected = []
          ; retry_after = None
          ; detail = "pool saturated"
          }))

let test_provider_config_judges () =
  match
    KFR.route_of_error
      (Agent_sdk.Error.Provider
         (Llm_provider.Error.MissingApiKey { var_name = "GLM_API_KEY" }))
  with
  | KFR.Escalate_judgment { judgment = KFR.Config_mismatch; _ } -> ()
  | other ->
    Alcotest.failf "missing api key should judge config, got %s"
      (KFR.route_kind_label other)

let test_masc_internal_backpressure_hint () =
  let err =
    internal_err
      (Keeper_internal_error.Capacity_backpressure
         { runtime_id = "glm-coding.glm-5-turbo"
         ; source = Keeper_internal_error.Provider_capacity
         ; detail = "429 burst"
         ; retry_after = Keeper_internal_error.Explicit 45.0
         ; cooldown_cause = None
         })
  in
  check_route
    "masc backpressure carries typed Explicit hint"
    (KFR.Retry_after_pacing
       { pacing = KFR.Capacity_backpressure; retry_after = Some 45.0 })
    err;
  Alcotest.(check (option (float 1e-6)))
    "retry_after_of_route extracts the hint"
    (Some 45.0)
    (KFR.retry_after_of_route (KFR.route_of_error err))

let test_masc_internal_judgment_classes () =
  (match
     KFR.route_of_error
       (internal_err
          (Keeper_internal_error.Ambiguous_post_commit
             { is_timeout = false; tools = [ "masc_done" ]; original_error = "eio" }))
   with
   | KFR.Escalate_judgment { judgment = KFR.Mutating_ambiguity; _ } -> ()
   | other ->
     Alcotest.failf "ambiguous post-commit should judge, got %s"
       (KFR.route_kind_label other));
  (match
     KFR.route_of_error
       (internal_err
          (Keeper_internal_error.Internal_contract_rejected { reason = "empty" }))
   with
   | KFR.Escalate_judgment
       { judgment = KFR.Contract_violation
       ; provenance = KFR.Masc_internal_error
       ; _
       } ->
     ()
   | other ->
     Alcotest.failf "contract rejection should judge, got %s"
       (KFR.route_kind_label other));
  check_route
    "admission rejection paces (lane backpressure)"
    (KFR.Retry_after_pacing
       { pacing = KFR.Admission_backpressure; retry_after = None })
    (internal_err
       (Keeper_internal_error.Admission_queue_rejected
          { keeper_name = "k"; reason = "lane full" }));
  check_route
    "capacity-exhausted runtime paces"
    (KFR.Retry_after_pacing
       { pacing = KFR.Capacity_backpressure; retry_after = None })
    (internal_err
       (Keeper_internal_error.Runtime_exhausted
          { runtime_id = "r"; reason = Keeper_internal_error.Capacity_exhausted }))

let test_non_provider_families_judge () =
  (match KFR.route_of_error (Agent_sdk.Error.Internal "boom") with
   | KFR.Escalate_judgment { judgment = KFR.Internal_opaque; _ } -> ()
   | other ->
     Alcotest.failf "raw Internal should judge, got %s" (KFR.route_kind_label other));
  (* RFC-0313 W3: an idle loop is a behavioral contract judgment, not an
     opaque internal error (it was the legacy ladder's manual-resume pause
     class). *)
  (match
     KFR.route_of_error
       (Agent_sdk.Error.Agent
          (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 3 }))
   with
   | KFR.Escalate_judgment
       { judgment = KFR.Contract_violation
       ; provenance = KFR.Oas_agent_idle_detected { consecutive_idle_turns = 3 }
       ; _
       } ->
     ()
   | other ->
     Alcotest.failf "idle loop should judge contract, got %s"
       (KFR.route_kind_label other));
  match
    KFR.route_of_error
      (Agent_sdk.Error.Mcp (Agent_sdk.Error.InitializeFailed { detail = "handshake" }))
  with
  | KFR.Escalate_judgment { judgment = KFR.Protocol_error; _ } -> ()
  | other ->
    Alcotest.failf "mcp error should judge protocol, got %s"
      (KFR.route_kind_label other)

let test_judgment_label_roundtrip () =
  List.iter
    (fun judgment ->
      let label = KFR.judgment_class_label judgment in
      match KFR.judgment_class_of_label label with
      | Some parsed when parsed = judgment -> ()
      | Some _ | None -> Alcotest.failf "label %s does not round-trip" label)
    [ KFR.Deterministic_request
    ; KFR.Context_overflow
    ; KFR.Contract_violation
    ; KFR.Mutating_ambiguity
    ; KFR.Protocol_error
    ; KFR.Config_mismatch
    ; KFR.Provider_integration
    ; KFR.Internal_opaque
    ];
  Alcotest.(check (option reject))
    "unknown label is fail-closed"
    None
    (KFR.judgment_class_of_label "totally_new_class")

let test_judgment_provenance_codec () =
  let values =
    [ KFR.Oas_api_error
    ; KFR.Oas_provider_error
    ; KFR.Oas_agent_idle_detected { consecutive_idle_turns = 3 }
    ; KFR.Oas_agent_error
    ; KFR.Oas_mcp_error
    ; KFR.Oas_config_error
    ; KFR.Oas_serialization_error
    ; KFR.Oas_io_error
    ; KFR.Oas_orchestration_error
    ; KFR.Oas_internal_error
    ; KFR.Masc_internal_error
    ; KFR.Completion_contract
    ; KFR.Legacy_unattributed
    ]
  in
  List.iter
    (fun provenance ->
       match
         KFR.judgment_provenance_to_yojson provenance
         |> KFR.judgment_provenance_of_yojson
       with
       | Ok parsed ->
         Alcotest.(check bool)
           (KFR.judgment_provenance_label provenance ^ " roundtrip")
           true
           (parsed = provenance)
       | Error detail -> Alcotest.fail detail)
    values;
  (match
     KFR.judgment_provenance_of_yojson
       (`Assoc
         [ "kind", `String "oas_agent_idle_detected"
         ; "consecutive_idle_turns", `Int 0
         ])
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "zero idle count decoded");
  (match
     KFR.judgment_provenance_of_yojson
       (`Assoc
         [ "kind", `String "oas_mcp_error"
         ; "unexpected", `String "ignored"
         ])
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "extra provenance field was silently ignored");
  (match
     KFR.judgment_provenance_of_yojson
       (`Assoc
         [ "kind", `String "oas_agent_idle_detected"
         ; "consecutive_idle_turns", `Int 3
         ; "unexpected", `Bool true
         ])
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "extra idle provenance field was silently ignored");
  match
    KFR.judgment_provenance_of_yojson
      (`Assoc [ "kind", `String "future_unregistered_boundary" ])
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown provenance decoded"

let test_queue_stimulus_roundtrip () =
  let fj : Keeper_event_queue.failure_judgment =
    { fj_runtime_id = "glm-coding.glm-5-turbo"
    ; fj_judgment = KFR.Protocol_error
    ; fj_provenance = KFR.Oas_mcp_error
    ; fj_detail = "mcp handshake failed"
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.failure_judgment_post_id fj
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 1000.0
    ; payload = Keeper_event_queue.Failure_judgment fj
    }
  in
  Alcotest.(check string)
    "post_id stable per (runtime, class, provenance)"
    "failure-judgment:glm-coding.glm-5-turbo:protocol_error:oas_mcp_error"
    stimulus.post_id;
  match
    Keeper_event_queue.stimulus_of_yojson
      (Keeper_event_queue.stimulus_to_yojson stimulus)
  with
  | Ok parsed ->
    Alcotest.(check bool)
      "roundtrip preserves identity"
      true
      (Keeper_event_queue.stimulus_identity_equal stimulus parsed);
    let legacy_json =
      match Keeper_event_queue.stimulus_to_yojson stimulus with
      | `Assoc stimulus_fields ->
        let payload =
          match List.assoc_opt "payload" stimulus_fields with
          | Some (`Assoc payload_fields) ->
            `Assoc
              (List.filter
                 (fun (name, _) -> not (String.equal name "provenance"))
                 payload_fields)
          | _ -> Alcotest.fail "fixture payload is not an object"
        in
        `Assoc
          (("payload", payload)
           :: List.remove_assoc "payload" stimulus_fields)
      | _ -> Alcotest.fail "fixture stimulus is not an object"
    in
    (match Keeper_event_queue.stimulus_of_yojson legacy_json with
     | Ok
         { payload =
             Keeper_event_queue.Failure_judgment
               { fj_provenance = KFR.Legacy_unattributed; _ }
         ; _
         } ->
       ()
     | Ok _ -> Alcotest.fail "legacy stimulus invented a provenance"
     | Error detail -> Alcotest.failf "legacy stimulus did not decode: %s" detail)
  | Error msg -> Alcotest.failf "roundtrip failed: %s" msg

let failure_judgment_stimulus ~detail : Keeper_event_queue.stimulus =
  let fj : Keeper_event_queue.failure_judgment =
    { fj_runtime_id = "glm-coding.glm-5-turbo"
    ; fj_judgment = KFR.Deterministic_request
    ; fj_provenance = KFR.Oas_api_error
    ; fj_detail = detail
    }
  in
  { post_id = Keeper_event_queue.failure_judgment_post_id fj
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1000.0
  ; payload = Keeper_event_queue.Failure_judgment fj
  }

(* RFC-0313 W2 loop-safety: the same deterministic failure class repeats
   with volatile provider text (token counts, addresses) in [fj_detail];
   the queue must stay bounded to one pending judgment per
   (runtime, class, provenance kind), or repeated failures self-stimulate judgment turns.
   Pins the identity semantics that
   [Keeper_registry_event_queue.enqueue_if_missing] relies on. *)
let test_queue_bounded_across_detail_variants () =
  let first = failure_judgment_stimulus ~detail:"chat template token missing (request 1281 tokens)" in
  let second = failure_judgment_stimulus ~detail:"chat template token missing (request 4096 tokens)" in
  Alcotest.(check bool)
    "differing detail is the same durable event"
    true
    (Keeper_event_queue.stimulus_identity_equal first second);
  let queue =
    Keeper_event_queue.enqueue (Keeper_event_queue.enqueue Keeper_event_queue.empty first) second
  in
  Alcotest.(check int)
    "identity dedup bounds the queue to one entry"
    1
    (Keeper_event_queue.length (Keeper_event_queue.dedup_by_identity queue));
  let other_class =
    let fj : Keeper_event_queue.failure_judgment =
      { fj_runtime_id = "glm-coding.glm-5-turbo"
      ; fj_judgment = KFR.Protocol_error
      ; fj_provenance = KFR.Oas_mcp_error
      ; fj_detail = "mcp handshake failed"
      }
    in
    { first with
      post_id = Keeper_event_queue.failure_judgment_post_id fj
    ; payload = Keeper_event_queue.Failure_judgment fj
    }
  in
  Alcotest.(check bool)
    "a different judgment class is a distinct durable event"
    false
    (Keeper_event_queue.stimulus_identity_equal first other_class);
  let idle_stimulus count =
    let fj : Keeper_event_queue.failure_judgment =
      { fj_runtime_id = "glm-coding.glm-5-turbo"
      ; fj_judgment = KFR.Contract_violation
      ; fj_provenance =
          KFR.Oas_agent_idle_detected { consecutive_idle_turns = count }
      ; fj_detail = "idle loop"
      }
    in
    { first with
      post_id = Keeper_event_queue.failure_judgment_post_id fj
    ; payload = Keeper_event_queue.Failure_judgment fj
    }
  in
  Alcotest.(check bool)
    "idle observation count is evidence, not event identity"
    true
    (Keeper_event_queue.stimulus_identity_equal
       (idle_stimulus 3)
       (idle_stimulus 4))

let () =
  Alcotest.run
    "keeper_runtime_failure_route"
    [ ( "api"
      , [ Alcotest.test_case "rate limited hint" `Quick test_api_rate_limited_threads_hint
        ; Alcotest.test_case "hard quota message" `Quick test_api_hard_quota_message_wins
        ; Alcotest.test_case "overloaded backpressure" `Quick test_api_overloaded_is_backpressure
        ; Alcotest.test_case "server error split" `Quick test_api_server_error_status_split
        ; Alcotest.test_case "auth rotates, invalid judges" `Quick test_api_auth_rotates_invalid_request_judges
        ] )
    ; ( "provider"
      , [ Alcotest.test_case "quota family hints" `Quick test_provider_quota_family_threads_hint
        ; Alcotest.test_case "config judges" `Quick test_provider_config_judges
        ] )
    ; ( "masc_internal"
      , [ Alcotest.test_case "backpressure hint" `Quick test_masc_internal_backpressure_hint
        ; Alcotest.test_case "judgment classes" `Quick test_masc_internal_judgment_classes
        ] )
    ; ( "families"
      , [ Alcotest.test_case "non-provider judge" `Quick test_non_provider_families_judge ] )
    ; ( "labels"
      , [ Alcotest.test_case "judgment roundtrip" `Quick test_judgment_label_roundtrip
        ; Alcotest.test_case
            "provenance codec"
            `Quick
            test_judgment_provenance_codec
        ] )
    ; ( "queue"
      , [ Alcotest.test_case "stimulus roundtrip" `Quick test_queue_stimulus_roundtrip
        ; Alcotest.test_case
            "bounded across detail variants"
            `Quick
            test_queue_bounded_across_detail_variants
        ] )
    ]

open Agent_sdk
module Attribution = Provider_failure_attribution
module Http = Llm_provider.Http_client
module PC = Llm_provider.Provider_config

let check_bool label expected actual = Alcotest.(check bool) label expected actual
let check_string label expected actual = Alcotest.(check string) label expected actual

let require_identity = function
  | Ok identity -> identity
  | Error detail -> Alcotest.fail detail
;;

let require_redacted_snapshot = function
  | Ok snapshot -> snapshot
  | Error detail -> Alcotest.fail detail
;;

let config
      ?(base_url = "https://example.test/api")
      ?(request_path = "/v1/messages")
      ?(api_key = "")
      ()
  =
  PC.make ~kind:PC.OpenAI_compat ~model_id:"model-a" ~base_url ~request_path ~api_key ()
;;

let identity ?base_url ?request_path ?api_key () =
  Binding_identity.of_provider_config
    ~transport:Binding_identity.Http
    (config ?base_url ?request_path ?api_key ())
  |> require_identity
;;

let test_identity_is_structural () =
  let key_a = "credential-a" in
  let key_b = "credential-b" in
  let first = identity ~api_key:key_a () in
  let equivalent = identity ~base_url:"https://EXAMPLE.test:443/api" ~api_key:key_a () in
  let other_path = identity ~request_path:"/v1/responses" ~api_key:key_a () in
  let other_credential = identity ~api_key:key_b () in
  let other_transport =
    Binding_identity.of_provider_config
      ~transport:Binding_identity.Injected
      (config ~api_key:key_a ())
    |> require_identity
  in
  check_bool "RFC canonical configs equal" true (Binding_identity.equal first equivalent);
  Alcotest.(check int)
    "equal identities hash equally"
    (Binding_identity.hash first)
    (Binding_identity.hash equivalent);
  check_bool "request path participates" false (Binding_identity.equal first other_path);
  check_bool
    "opaque credential participates"
    false
    (Binding_identity.equal first other_credential);
  check_bool "transport participates" false (Binding_identity.equal first other_transport)
;;

let test_identity_observation_is_redacted () =
  let raw_key = "raw-api-secret" in
  let identity =
    config
      ~base_url:"https://user:password@example.test/api?secret-query-key=base-secret"
      ~request_path:"/v1/messages?key=path-secret"
      ~api_key:raw_key
      ()
    |> Binding_identity.of_provider_config ~transport:Binding_identity.Http
    |> require_identity
  in
  let rendered = Binding_identity.to_redacted_yojson identity |> Yojson.Safe.to_string in
  List.iter
    (fun secret ->
       check_bool
         ("redacts " ^ secret)
         false
         (Util.string_contains ~needle:secret rendered))
    [ raw_key; "password"; "secret-query-key"; "base-secret"; "path-secret" ];
  check_bool
    "query values visibly redacted"
    true
    (Util.string_contains ~needle:"redacted" rendered)
;;

let test_redacted_snapshot_closed_codec () =
  let first = identity ~api_key:"credential-a" () in
  let snapshot = Binding_identity.redacted_snapshot first in
  let json = Binding_identity.Redacted_snapshot.to_yojson snapshot in
  let decoded =
    Binding_identity.Redacted_snapshot.of_yojson json |> require_redacted_snapshot
  in
  check_bool
    "redacted snapshot roundtrips"
    true
    (Binding_identity.Redacted_snapshot.equal snapshot decoded);
  Alcotest.(check string)
    "convenience observation API is the snapshot codec"
    (Yojson.Safe.to_string json)
    (Binding_identity.to_redacted_yojson first |> Yojson.Safe.to_string);
  let other = identity ~api_key:"credential-b" () |> Binding_identity.redacted_snapshot in
  check_bool
    "snapshot observes a different credential fingerprint"
    false
    (Binding_identity.Redacted_snapshot.equal snapshot other)
;;

let test_redacted_snapshot_rejects_noncanonical_input () =
  let snapshot =
    identity ~api_key:"credential-a" () |> Binding_identity.redacted_snapshot
  in
  let json = Binding_identity.Redacted_snapshot.to_yojson snapshot in
  let fields =
    match json with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "redacted snapshot encoder did not return an object"
  in
  let replace name value = `Assoc ((name, value) :: List.remove_assoc name fields) in
  let reject label json =
    match Binding_identity.Redacted_snapshot.of_yojson json with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (label ^ " was accepted")
  in
  reject "unknown field" (`Assoc (("legacy", `Bool true) :: fields));
  reject "duplicate field" (`Assoc (("model", `String "other") :: fields));
  reject "missing field" (`Assoc (List.remove_assoc "model" fields));
  reject "unknown transport" (replace "transport" (`String "HTTP"));
  reject "unknown auth scheme" (replace "auth_scheme" (`String "bearer"));
  reject "padded model" (replace "model" (`String " model-a "));
  reject
    "unredacted endpoint query"
    (replace "endpoint" (`String "https://example.test/api?secret=value"));
  reject
    "endpoint userinfo"
    (replace "endpoint" (`String "https://user:password@example.test/api"));
  reject
    "ambiguous provider shape"
    (replace
       "provider"
       (`Assoc
           [ "registration", `String "unregistered"
           ; "kind", `String "openai_compat"
           ; "id", `String "also-registered"
           ]));
  reject "blank credential fingerprint" (replace "credential_fingerprint" (`String " "));
  reject
    "raw credential fingerprint"
    (replace "credential_fingerprint" (`String "credential-a"));
  reject
    "full digest fingerprint"
    (replace "credential_fingerprint" (`String (String.make 64 'a')));
  reject "uppercase fingerprint" (replace "credential_fingerprint" (`String "ABCDEF01"));
  reject "short fingerprint" (replace "credential_fingerprint" (`String "abcdef0"))
;;

let test_binding_identity_rejects_invalid_model_identity () =
  let invalid = { (config ()) with model_id = "  " } in
  match Binding_identity.of_provider_config ~transport:Binding_identity.Http invalid with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "blank model identity was accepted"
;;

let ownership binding error =
  match Attribution.of_http_error ~binding error with
  | { provider_failure = Some attribution; _ } -> attribution.ownership
  | { provider_failure = None; _ } -> Alcotest.fail "missing provider attribution"
;;

let ownership_testable =
  Alcotest.testable
    (fun fmt ownership ->
       Format.pp_print_string fmt (Attribution.failure_ownership_to_string ownership))
    ( = )
;;

let check_ownership label expected binding error =
  Alcotest.check ownership_testable label expected (ownership binding error)
;;

let check_detailed_ownership label expected detailed =
  match detailed.Attribution.provider_failure with
  | Some attribution ->
    Alcotest.check ownership_testable label expected attribution.ownership
  | None -> Alcotest.fail (label ^ ": missing provider attribution")
;;

let check_retains_binding label expected_binding error =
  match Attribution.of_http_error ~binding:expected_binding error with
  | { provider_failure = Some { binding = Some actual_binding; _ }; _ } ->
    check_bool label true (Binding_identity.equal expected_binding actual_binding)
  | { provider_failure = Some { binding = None; _ } | None; _ } ->
    Alcotest.fail (label ^ ": missing attempted binding")
;;

let test_closed_ownership_matrix () =
  let with_credential = identity ~api_key:"credential-a" () in
  let without_credential = identity () in
  check_ownership
    "401 with identity is credential pool"
    Attribution.Credential_pool
    with_credential
    (Http.HttpError { code = 401; body = "auth"; retry_after_header = None });
  check_ownership
    "401 without identity fails local"
    Attribution.Unclassified
    without_credential
    (Http.HttpError { code = 401; body = "auth"; retry_after_header = None });
  check_ownership
    "402 with identity is credential pool"
    Attribution.Credential_pool
    with_credential
    (Http.HttpError { code = 402; body = "payment"; retry_after_header = None });
  check_ownership
    "402 without identity fails local"
    Attribution.Unclassified
    without_credential
    (Http.HttpError { code = 402; body = "payment"; retry_after_header = None });
  (* 429 is handled by its own dedicated test below (test_429_capacity_evidence):
     it is no longer part of the generic "ambiguous" catch-all — it now routes
     through the typed capacity vocabulary instead of [Http_status]. *)
  List.iter
    (fun code ->
       check_ownership
         (Printf.sprintf "ambiguous HTTP %d" code)
         Attribution.Unclassified
         with_credential
         (Http.HttpError { code; body = "ambiguous"; retry_after_header = None }))
    [ 403 ];
  check_ownership
    "binding HTTP 404"
    Attribution.Runtime_binding
    with_credential
    (Http.HttpError { code = 404; body = "binding"; retry_after_header = None });
  List.iter
    (fun code ->
       check_ownership
         (Printf.sprintf "ambiguous server HTTP %d" code)
         Attribution.Unclassified
         with_credential
         (Http.HttpError
            { code; body = "ambiguous server failure"; retry_after_header = None }))
    [ 500; 503 ];
  List.iter
    (fun kind ->
       check_ownership
         "endpoint network evidence"
         Attribution.Endpoint
         with_credential
         (Http.NetworkError { message = "network detail"; kind }))
    [ Http.Connection_refused; Http.Dns_failure; Http.Tls_error; Http.End_of_file ];
  check_ownership
    "local resource exhaustion is attempt local"
    Attribution.Attempt_local
    with_credential
    (Http.NetworkError
       { message = "local resource detail"; kind = Http.Local_resource_exhaustion });
  check_ownership
    "provider first-token timeout is not widened"
    Attribution.Unclassified
    with_credential
    (Http.TimeoutError { message = "first token"; phase = Http.First_token });
  let capacity scope =
    Http.ProviderFailure
      { kind = Http.Capacity_exhausted { scope; retry_after = None; model = None }
      ; message = "capacity"
      }
  in
  check_ownership
    "model capacity"
    Attribution.Runtime_binding
    with_credential
    (capacity Http.Failure_scope_model);
  check_ownership
    "account capacity"
    Attribution.Credential_pool
    with_credential
    (capacity Http.Failure_scope_account);
  check_ownership
    "account capacity without identity fails local"
    Attribution.Unclassified
    without_credential
    (capacity Http.Failure_scope_account);
  check_ownership
    "region capacity"
    Attribution.Provider_region
    with_credential
    (capacity Http.Failure_scope_region);
  check_ownership
    "provider capacity"
    Attribution.Provider
    with_credential
    (capacity Http.Failure_scope_provider);
  check_ownership
    "parse is attempt local"
    Attribution.Attempt_local
    with_credential
    (Http.ProviderFailure
       { kind = Http.Provider_parse_error { parser = Some "fixture" }
       ; message = "parse detail"
       });
  check_ownership
    "provider-reported envelope is not attributed locally"
    Attribution.Unclassified
    with_credential
    (Http.ProviderFailure
       { kind = Http.Provider_reported_error { error_type = Some "rate_limit_exceeded" }
       ; message = "provider-reported detail"
       });
  check_ownership
    "terminal is session local"
    Attribution.Session_local
    with_credential
    (Http.ProviderTerminal { kind = Http.Session_conflict; message = "session detail" });
  check_ownership
    "typed CLI startup auth"
    Attribution.Credential_pool
    with_credential
    (Http.ProviderFailure
       { kind = Http.Cli_startup_failed { reason = Http.Authentication_unavailable }
       ; message = "startup detail"
       });
  check_detailed_ownership
    "request validation is attempt local"
    Attribution.Attempt_local
    (Attribution.of_request_validation_error
       ~binding:with_credential
       (Error.Api
          (Llm_provider.Retry.InvalidRequest
             { message = "invalid request"
             ; reason = Llm_provider.Retry.Unknown_invalid_request
             })));
  check_detailed_ownership
    "response parse is attempt local"
    Attribution.Attempt_local
    (Attribution.of_response_parse_error
       ~binding:with_credential
       (Error.Provider (Llm_provider.Error.ParseError { detail = "parse detail" })));
  check_retains_binding
    "session conflict retains attempted binding"
    with_credential
    (Http.ProviderTerminal { kind = Http.Session_conflict; message = "session detail" });
  check_retains_binding
    "CLI startup retains attempted binding"
    with_credential
    (Http.ProviderFailure
       { kind = Http.Cli_startup_failed { reason = Http.Authentication_unavailable }
       ; message = "startup detail"
       })
;;

(* oas 429 typed completion (2026-07): a raw HTTP 429 used to fall into the
   generic [Http_status] evidence via [ownership_of_http_status]'s [_ ->
   Unclassified] catch-all, discarding any retry_after evidence. It must
   now route through the typed capacity vocabulary — [Provider_failure
   (Capacity_exhausted { scope = Failure_scope_unknown; retry_after; _ })]
   — carrying retry_after and staying distinguishable from the [Http_status]
   evidence produced for genuinely unclassifiable statuses (e.g. 403). The
   ownership is still [Unclassified] (honest: a raw 429 carries no
   provider-specific evidence of which lane is exhausted), but it is now
   reached deliberately through [ownership_of_capacity ~scope:Failure_scope_unknown]
   instead of the blind catch-all. *)
let test_429_capacity_evidence () =
  let with_credential = identity ~api_key:"credential-a" () in
  let body_only =
    Http.HttpError
      { code = 429
      ; body = {|{"error":{"retry_after":7.0,"message":"slow down"}}|}
      ; retry_after_header = None
      }
  in
  (match Attribution.of_http_error ~binding:with_credential body_only with
   | { provider_failure =
         Some
           { ownership = Attribution.Unclassified
           ; evidence =
               Attribution.Provider_failure
                 (Http.Capacity_exhausted
                    { scope = Http.Failure_scope_unknown
                    ; retry_after = Some ra
                    ; model = None
                    })
           ; _
           }
     ; _
     } -> check_bool "body retry_after carried" true (Float.equal ra 7.0)
   | _ -> Alcotest.fail "expected typed capacity evidence with body retry_after");
  let header_fallback =
    Http.HttpError
      { code = 429
      ; body = {|{"error":"too many concurrent requests"}|}
      ; retry_after_header = Some 15.0
      }
  in
  match Attribution.of_http_error ~binding:with_credential header_fallback with
  | { provider_failure =
        Some
          { ownership = Attribution.Unclassified
          ; evidence =
              Attribution.Provider_failure
                (Http.Capacity_exhausted
                   { scope = Http.Failure_scope_unknown
                   ; retry_after = Some ra
                   ; model = None
                   })
          ; _
          }
    ; _
    } ->
    check_bool "header retry_after carried when body has none" true (Float.equal ra 15.0)
  | _ -> Alcotest.fail "expected typed capacity evidence with header retry_after"
;;

let test_coarse_sdk_provider_errors_fail_closed () =
  let errors =
    [ Error.Provider
        (Llm_provider.Error.ProviderUnavailable
           { provider = "coarse"; detail = "unavailable detail" })
    ; Error.Provider (Llm_provider.Error.ParseError { detail = "parse detail" })
    ]
  in
  List.iter
    (fun error ->
       match Attribution.of_sdk_error error with
       | { provider_failure = Some attribution; _ } ->
         Alcotest.check
           ownership_testable
           "coarse provider error is never widened"
           Attribution.Unclassified
           attribution.ownership;
         check_bool
           "coarse error has no invented binding"
           true
           (Option.is_none attribution.binding);
         (match attribution.evidence with
          | Attribution.Coarse_provider_error -> ()
          | _ -> Alcotest.fail "expected coarse provider evidence")
       | { provider_failure = None; _ } ->
         Alcotest.fail "coarse provider error must remain explicit")
    errors
;;

let provider_config () =
  Provider_mock.local_provider_config
    ~base_url:"https://provider.test"
    ~model_id:"model-a"
    ~request_path:"/v1/chat/completions"
    ()
;;

let transport_error : Http.http_error =
  Http.NetworkError { message = "dns fixture"; kind = Http.Dns_failure }
;;

let failing_transport error : Llm_provider.Llm_transport.t =
  { complete_sync = (fun _ -> { response = Error error; latency_ms = None })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> Error error)
  }
;;

let empty_response : Types.api_response =
  { id = "empty"
  ; model = "model-a"
  ; stop_reason = Types.EndTurn
  ; content = []
  ; usage = None
  ; telemetry = None
  }
;;

let empty_transport : Llm_provider.Llm_transport.t =
  { complete_sync = (fun _ -> { response = Ok empty_response; latency_ms = None })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> Ok empty_response)
  }
;;

let make_agent ~net ~transport name =
  let options =
    { Agent.default_options with
      provider_config = Some (provider_config ())
    ; transport = Some transport
    }
  in
  Agent.create
    ~net
    ~config:{ (Types.default_config ~model:"test-model") with name; model = "model-a" }
    ~options
    ()
;;

let require_detailed_error (result : ('response, Agent.detailed_error) result) =
  match result with
  | Error detailed ->
    (match detailed.provider_failure with
     | Some attribution -> detailed, attribution
     | None -> Alcotest.fail "missing detailed attribution")
  | Ok _ -> Alcotest.fail "expected detailed failure"
;;

let require_legacy_error = function
  | Error error -> error
  | Ok _ -> Alcotest.fail "expected legacy failure"
;;

let test_agent_sync_stream_and_legacy_projection () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let sync_detailed, sync_attribution =
    make_agent ~net ~transport:(failing_transport transport_error) "sync-detailed"
    |> fun agent -> Agent.run_detailed ~sw agent "ping" |> require_detailed_error
  in
  let stream_detailed, stream_attribution =
    make_agent ~net ~transport:(failing_transport transport_error) "stream-detailed"
    |> fun agent ->
    Agent.run_stream_detailed ~sw ~on_event:(fun _ -> ()) agent "ping"
    |> require_detailed_error
  in
  Alcotest.check
    ownership_testable
    "sync ownership"
    Attribution.Endpoint
    sync_attribution.ownership;
  Alcotest.check
    ownership_testable
    "stream ownership"
    Attribution.Endpoint
    stream_attribution.ownership;
  let sync_binding = Option.get sync_attribution.binding in
  let stream_binding = Option.get stream_attribution.binding in
  check_bool
    "sync and stream binding identity equal"
    true
    (Binding_identity.equal sync_binding stream_binding);
  let sync_legacy =
    make_agent ~net ~transport:(failing_transport transport_error) "sync-legacy"
    |> fun agent -> Agent.run ~sw agent "ping" |> require_legacy_error
  in
  let stream_legacy =
    make_agent ~net ~transport:(failing_transport transport_error) "stream-legacy"
    |> fun agent ->
    Agent.run_stream ~sw ~on_event:(fun _ -> ()) agent "ping" |> require_legacy_error
  in
  check_bool "sync exact legacy projection" true (sync_legacy = sync_detailed.error);
  check_bool "stream exact legacy projection" true (stream_legacy = stream_detailed.error)
;;

let test_empty_completion_overflow_types_as_context_overflow () =
  match
    Attribution.sdk_error_of_http_error
      (Http.ProviderFailure
         { kind = Http.Empty_completion { stop_reason = Types.ContextWindowExceeded }
         ; message = "provider returned an empty assistant turn"
         })
  with
  | Error.Api (Llm_provider.Retry.ContextOverflow { limit = None; _ }) -> ()
  | other -> Alcotest.failf "expected Api ContextOverflow, got %s" (Error.to_string other)
;;

(* oas#2947: a provider-reported overflow (glm 1261) must reach the same
   typed [Api ContextOverflow] as the empty-completion overflow above — the
   consumer's compaction/shrink recovery branches on that constructor. *)
let test_provider_reported_overflow_types_as_context_overflow () =
  match
    Attribution.sdk_error_of_http_error
      (Http.ProviderFailure
         { kind = Http.Context_overflow { limit = None }
         ; message = "Prompt exceeds max length"
         })
  with
  | Error.Api (Llm_provider.Retry.ContextOverflow { limit = None; _ } as api) ->
    check_bool
      "overflow is not transport-retryable"
      false
      (Llm_provider.Retry.is_retryable api)
  | other -> Alcotest.failf "expected Api ContextOverflow, got %s" (Error.to_string other)
;;

let test_request_body_limit_preserves_typed_capacity_evidence () =
  match
    Attribution.sdk_error_of_http_error
      (Http.request_body_too_large_error ~actual_bytes:2048 ~limit_bytes:1024)
  with
  | Error.Api
      (Llm_provider.Retry.InvalidRequest
         { reason =
             Llm_provider.Retry.Request_body_too_large { actual_bytes; limit_bytes }
         ; _
         } as api) ->
    Alcotest.(check int) "actual serialized bytes" 2048 actual_bytes;
    Alcotest.(check int) "resolved target limit" 1024 limit_bytes;
    check_bool
      "deterministic admission is not retried"
      false
      (Llm_provider.Retry.is_retryable api)
  | other ->
    Alcotest.failf
      "expected typed Api InvalidRequest request-body evidence, got %s"
      (Error.to_string other)
;;

let test_empty_completion_end_turn_stays_provider_unavailable () =
  match
    Attribution.sdk_error_of_http_error
      (Http.ProviderFailure
         { kind = Http.Empty_completion { stop_reason = Types.EndTurn }
         ; message = "provider returned an empty assistant turn"
         })
  with
  | Error.Provider (Llm_provider.Error.ProviderUnavailable _) -> ()
  | other ->
    Alcotest.failf "expected Provider unavailable, got %s" (Error.to_string other)
;;

(* Regression guard: an empty turn whose stop_reason token the SDK does not
   model must not be attributed to provider unavailability. That attribution is
   retried / rotated with the identical prompt, so an overflow reported with an
   unmodeled token would loop without ever raising an error or reaching the
   consumer's compaction path. The failure must name the token and must not be
   retryable. *)
let test_empty_completion_unmodeled_stop_reason_fails_loud () =
  let token = "provider_specific_overflow" in
  match
    Attribution.sdk_error_of_http_error
      (Http.ProviderFailure
         { kind = Http.Empty_completion { stop_reason = Types.Unknown token }
         ; message = "provider returned an empty assistant turn"
         })
  with
  | Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message; reason = Llm_provider.Retry.Unknown_invalid_request } as api) ->
    check_bool
      "names the unmodeled stop_reason token"
      true
      (Util.string_contains ~needle:token message);
    check_bool "not retryable" false (Llm_provider.Retry.is_retryable api)
  | other ->
    Alcotest.failf
      "expected Api InvalidRequest naming the unmodeled token, got %s"
      (Error.to_string other)
;;

(* The SDK error boundary is the second promotion site for the same rule. If it
   keeps rendering an unmodeled empty completion as provider unavailability, the
   retry loop reappears one layer below the attribution fix. *)
let test_error_boundary_unmodeled_stop_reason_is_invalid_request () =
  let token = "provider_specific_overflow" in
  match
    Llm_provider.Error.of_http_error
      (Http.ProviderFailure
         { kind = Http.Empty_completion { stop_reason = Types.Unknown token }
         ; message = "provider returned an empty assistant turn"
         })
  with
  | Llm_provider.Error.InvalidRequest { reason; _ } ->
    check_bool
      "names the unmodeled stop_reason token"
      true
      (Util.string_contains ~needle:token reason)
  | other ->
    Alcotest.failf
      "expected InvalidRequest naming the unmodeled token, got %s"
      (Llm_provider.Error.to_string other)
;;

let test_stream_finalization_keeps_empty_completion_evidence () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let agent = make_agent ~net:(Eio.Stdenv.net env) ~transport:empty_transport "empty" in
  let _detailed, attribution =
    Agent.run_stream_detailed ~sw ~on_event:(fun _ -> ()) agent "ping"
    |> require_detailed_error
  in
  Alcotest.check
    ownership_testable
    "empty completion is attempt local"
    Attribution.Attempt_local
    attribution.ownership;
  match attribution.evidence with
  | Attribution.Provider_failure (Http.Empty_completion { stop_reason = Types.EndTurn })
    -> ()
  | _ -> Alcotest.fail "expected typed empty-completion evidence"
;;

let test_attribution_json_omits_diagnostics () =
  let binding = identity ~api_key:"credential-a" () in
  let detailed =
    Attribution.of_http_error
      ~binding
      (Http.NetworkError
         { message = "sensitive diagnostic body"; kind = Http.Dns_failure })
  in
  let attribution = Option.get detailed.provider_failure in
  let rendered = Attribution.to_yojson attribution |> Yojson.Safe.to_string in
  check_bool
    "diagnostic omitted"
    false
    (Util.string_contains ~needle:"sensitive diagnostic body" rendered);
  check_string
    "ownership serialized"
    "endpoint"
    (Yojson.Safe.Util.member "ownership" (Attribution.to_yojson attribution)
     |> Yojson.Safe.Util.to_string);
  let unknown_stop = "sensitive-provider-stop-reason" in
  let empty =
    Attribution.of_http_error
      ~binding
      (Http.ProviderFailure
         { kind = Http.Empty_completion { stop_reason = Types.Unknown unknown_stop }
         ; message = "sensitive empty detail"
         })
  in
  let rendered =
    Option.get empty.provider_failure |> Attribution.to_yojson |> Yojson.Safe.to_string
  in
  check_bool
    "unknown wire stop reason omitted"
    false
    (Util.string_contains ~needle:unknown_stop rendered)
;;

let () =
  Alcotest.run
    "provider failure attribution"
    [ ( "binding identity"
      , [ Alcotest.test_case "structural equality" `Quick test_identity_is_structural
        ; Alcotest.test_case
            "redacted observation"
            `Quick
            test_identity_observation_is_redacted
        ; Alcotest.test_case
            "redacted snapshot closed codec"
            `Quick
            test_redacted_snapshot_closed_codec
        ; Alcotest.test_case
            "redacted snapshot strict boundary"
            `Quick
            test_redacted_snapshot_rejects_noncanonical_input
        ; Alcotest.test_case
            "invalid model identity"
            `Quick
            test_binding_identity_rejects_invalid_model_identity
        ] )
    ; ( "ownership"
      , [ Alcotest.test_case "closed matrix" `Quick test_closed_ownership_matrix
        ; Alcotest.test_case
            "429 typed capacity evidence"
            `Quick
            test_429_capacity_evidence
        ; Alcotest.test_case
            "coarse provider fail-closed"
            `Quick
            test_coarse_sdk_provider_errors_fail_closed
        ; Alcotest.test_case
            "redacted attribution JSON"
            `Quick
            test_attribution_json_omits_diagnostics
        ] )
    ; ( "empty completion classification"
      , [ Alcotest.test_case
            "request-body admission preserves typed capacity evidence"
            `Quick
            test_request_body_limit_preserves_typed_capacity_evidence
        ; Alcotest.test_case
            "ContextWindowExceeded types as Api ContextOverflow"
            `Quick
            test_empty_completion_overflow_types_as_context_overflow
        ; Alcotest.test_case
            "provider-reported overflow types as context overflow (oas#2947)"
            `Quick
            test_provider_reported_overflow_types_as_context_overflow
        ; Alcotest.test_case
            "EndTurn stays provider unavailable"
            `Quick
            test_empty_completion_end_turn_stays_provider_unavailable
        ; Alcotest.test_case
            "unmodeled stop_reason fails loud instead of retrying"
            `Quick
            test_empty_completion_unmodeled_stop_reason_fails_loud
        ; Alcotest.test_case
            "error boundary renders unmodeled stop_reason as invalid request"
            `Quick
            test_error_boundary_unmodeled_stop_reason_is_invalid_request
        ] )
    ; ( "agent detailed API"
      , [ Alcotest.test_case
            "sync stream and legacy projection"
            `Quick
            test_agent_sync_stream_and_legacy_projection
        ; Alcotest.test_case
            "stream finalization"
            `Quick
            test_stream_finalization_keeps_empty_completion_evidence
        ] )
    ]
;;

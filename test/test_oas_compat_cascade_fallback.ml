(* test/test_oas_compat_cascade_fallback.ml

   #9932: kimi_cli permanent failure blocks 5 keepers (409 BDI blockers) —
   big_three cascade fallback was not firing because
   [Oas_compat.Http_client.should_cascade] classified per-provider CLI
   rejections as non-cascadable. The correct policy: a permanent error
   specific to one provider (kimi auth/config, gemini startup crash) still
   cascades because the NEXT hop is a different provider that may succeed.

   This test pins the should_cascade policy for AcceptRejected reasons. The
   FSM call site is [lib/cascade/cascade_fsm.ml:43-48]: Call_err -> Try_next
   iff should_cascade_to_next returns true; otherwise Exhausted.  A false
   return here terminates the cascade at the first hop, producing
   fallback_applied=None in the observation.

   Structured error codes (M04/M05):
   [Oas_compat.Http_client.retryable_error] and [classify_accept_rejected]
   replace the previous [accept_rejected_cascadable_markers] string list
   and [accept_rejected_is_cascadable] string-scan (anti-patterns M04/M05).
   String matching is quarantined in [classify_accept_rejected] and
   [is_http_body_parse_error]; all cascade-decision code branches on the
   enum variants instead of raw strings. *)

module Http_client = Llm_provider.Http_client

let test_kimi_cli_exit_1_cascades () =
  let reason =
    "kimi_cli rejected the request (exit 1). "
    ^ "This is usually a permanent auth/config/model error rather "
    ^ "than a transient transport failure. "
    ^ "kimi exited with code 1: To resume this session…"
  in
  let err = Http_client.AcceptRejected { reason } in
  Alcotest.(check bool)
    "kimi_cli exit 1 must cascade — permanent error is Moonshot-specific, \
     next cascade hop (claude/gpt/ollama) unaffected"
    true
    (Oas_compat.Http_client.should_cascade err)

let test_gemini_cli_startup_crash_cascades () =
  let reason =
    "gemini_cli startup crash detected (unsettled top-level await / \
     yoga_wasm). Known bad CLI runtime; rejecting without retry so the \
     cascade can move on."
  in
  let err = Http_client.AcceptRejected { reason } in
  Alcotest.(check bool)
    "gemini_cli startup crash must cascade — OAS source labels intent \
     explicitly ('so the cascade can move on')"
    true
    (Oas_compat.Http_client.should_cascade err)

let test_kimi_cli_startup_crash_cascades () =
  let reason =
    "kimi_cli startup crash while setting process title \
     (UnicodeDecodeError). This is a local CLI/runtime failure, not \
     keeper auth or sandbox failure; rejecting without retry so the \
     cascade can move on."
  in
  let err = Http_client.AcceptRejected { reason } in
  Alcotest.(check bool)
    "kimi_cli startup crash must cascade — next provider may still succeed"
    true
    (Oas_compat.Http_client.should_cascade err)

let test_does_not_support_still_cascades () =
  (* Regression pin for #9850: the provider-capability-mismatch marker
     added by codex_cli runtime_mcp_auth / tool_support must keep
     cascading. *)
  let err =
    Http_client.AcceptRejected
      {
        reason =
          "codex_cli does not support runtime_mcp_auth headers for \
           masc_plan_set_task, masc_claim_next, masc_transition";
      }
  in
  Alcotest.(check bool)
    "'does not support' cascades (pre-existing behaviour, #9850)"
    true
    (Oas_compat.Http_client.should_cascade err)

let test_unknown_reason_does_not_cascade () =
  (* The whitelist is additive — reasons that do not match any marker
     stay non-cascadable. This pins that the fix is narrow and does
     not accidentally cascade every AcceptRejected. *)
  let err =
    Http_client.AcceptRejected
      { reason = "output_schema violation: value is not a string" }
  in
  Alcotest.(check bool)
    "AcceptRejected with no marker does not cascade"
    false
    (Oas_compat.Http_client.should_cascade err)

let test_http_429_cascades () =
  (* Smoke test: HTTP-level cascadable codes are untouched by this fix. *)
  let err = Http_client.HttpError { code = 429; body = "rate limited" } in
  Alcotest.(check bool)
    "HTTP 429 cascades (baseline)"
    true
    (Oas_compat.Http_client.should_cascade err)

(* --- ProviderTerminal: pin classify, should_cascade, and the new
       error_message helper. The variant arrived in agent_sdk without
       a sweep, so [warn-error +8] flipped 5 [partial-match] warnings
       to hard errors on main (#oas-providerterminal-sweep
       2026-04-26). The new helper [Oas_compat.Http_client.error_message]
       centralises the per-variant rendering so the next OAS variant
       addition fails to compile *only* in this adapter. *)

let test_provider_terminal_max_turns () =
  let err =
    Http_client.ProviderTerminal
      { kind = Max_turns { turns = 10; limit = 10 };
        message = "agent reached max_turns" }
  in
  Alcotest.(check bool)
    "ProviderTerminal Max_turns must NOT cascade — agent-level terminal"
    false
    (Oas_compat.Http_client.should_cascade err);
  (match Oas_compat.Http_client.classify err with
   | Provider_terminal -> ()
   | _ -> Alcotest.fail "Max_turns must classify as Provider_terminal");
  let rendered = Oas_compat.Http_client.error_message err in
  Alcotest.(check bool)
    "error_message renders kind + turns/limit + message"
    true
    (String.length rendered > 0
     && Astring.String.is_infix ~affix:"max turns exceeded" rendered
     && Astring.String.is_infix ~affix:"10/10" rendered)

let test_provider_terminal_other () =
  let err =
    Http_client.ProviderTerminal
      { kind = Other "structured_terminal_subtype";
        message = "provider signalled terminal condition" }
  in
  Alcotest.(check bool)
    "ProviderTerminal Other must NOT cascade"
    false
    (Oas_compat.Http_client.should_cascade err);
  (match Oas_compat.Http_client.classify err with
   | Provider_terminal -> ()
   | _ -> Alcotest.fail "Other must classify as Provider_terminal");
  let rendered = Oas_compat.Http_client.error_message err in
  Alcotest.(check bool)
    "error_message renders subtype + message"
    true
    (Astring.String.is_infix ~affix:"structured_terminal_subtype" rendered
     && Astring.String.is_infix ~affix:"provider signalled" rendered)

let test_provider_failure_capacity_cascades () =
  let err =
    Http_client.ProviderFailure
      {
        kind =
          Capacity_exhausted
            {
              scope = Failure_scope_model;
              retry_after = Some 3.0;
              model = Some "gemini-2.5-pro";
            };
        message = "model overloaded";
      }
  in
  Alcotest.(check bool)
    "ProviderFailure Capacity_exhausted must cascade"
    true
    (Oas_compat.Http_client.should_cascade err);
  match Oas_compat.Http_client.classify err with
  | Provider_capacity_exhausted -> ()
  | _ ->
      Alcotest.fail
        "Capacity_exhausted must classify as Provider_capacity_exhausted"

let test_provider_failure_hard_quota_cascades () =
  let err =
    Http_client.ProviderFailure
      {
        kind = Hard_quota { retry_after = Some 60.0 };
        message = "monthly quota exhausted";
      }
  in
  Alcotest.(check bool)
    "ProviderFailure Hard_quota cascades as a provider-local skip condition"
    true
    (Oas_compat.Http_client.should_cascade err);
  (match Oas_compat.Http_client.classify err with
   | Provider_hard_quota -> ()
   | _ -> Alcotest.fail "Hard_quota must classify as Provider_hard_quota");
  Alcotest.(check bool)
    "error_message renders typed provider failure"
    true
    (Astring.String.is_infix ~affix:"hard_quota"
       (Oas_compat.Http_client.error_message err))

let test_provider_failure_capability_mismatch_cascades () =
  let err =
    Http_client.ProviderFailure
      {
        kind = Capability_mismatch { capability = Some "runtime_mcp_tools" };
        message = "gemini_cli cannot receive runtime MCP tools";
      }
  in
  Alcotest.(check bool)
    "ProviderFailure Capability_mismatch cascades without string markers"
    true
    (Oas_compat.Http_client.should_cascade err);
  (match Oas_compat.Http_client.classify err with
   | Provider_capability_mismatch -> ()
   | _ ->
       Alcotest.fail
         "Capability_mismatch must classify as Provider_capability_mismatch")

let test_error_message_baseline () =
  (* Smoke check that the new helper preserves existing semantics for
     the variants that already had inline matches at the call sites. *)
  let net = Http_client.NetworkError
              { message = "boom"; kind = Llm_provider.Http_client.Unknown } in
  Alcotest.(check string) "NetworkError -> message"
    "boom" (Oas_compat.Http_client.error_message net);
  let cli = Http_client.CliTransportRequired { kind = "claude" } in
  Alcotest.(check string) "CliTransportRequired -> humanised"
    "claude provider requires a CLI transport"
    (Oas_compat.Http_client.error_message cli);
  let acc = Http_client.AcceptRejected { reason = "x" } in
  Alcotest.(check string) "AcceptRejected -> reason"
    "x" (Oas_compat.Http_client.error_message acc)

(* ── Structured error codes (M04 / M05) ───────────────────────────
   Pin that [classify_accept_rejected] maps each string marker to the
   correct [retryable_error] variant and that unknown reasons return
   [None].  These tests are independent of cascade policy: they verify
   the structured-code layer that replaced the marker list. *)

let retryable_error_to_string = function
  | None -> "None"
  | Some Oas_compat.Http_client.Parse_error -> "Parse_error"
  | Some Oas_compat.Http_client.Model_unsupported -> "Model_unsupported"
  | Some Oas_compat.Http_client.Request_rejected -> "Request_rejected"
  | Some Oas_compat.Http_client.Startup_crash -> "Startup_crash"
  (* Adding a new [retryable_error] variant will produce a [warn-error +8]
     compile error here, ensuring this helper stays synchronised. *)

let test_classify_accept_rejected_model_unsupported () =
  let reason = "codex_cli does not support runtime_mcp_auth headers" in
  (match Oas_compat.Http_client.classify_accept_rejected reason with
   | Some Oas_compat.Http_client.Model_unsupported -> ()
   | other ->
       Alcotest.failf
         "expected Model_unsupported, got %s"
         (retryable_error_to_string other))

let test_classify_accept_rejected_request_rejected () =
  let reason =
    "kimi_cli rejected the request (exit 1). Permanent auth/config/model error"
  in
  (match Oas_compat.Http_client.classify_accept_rejected reason with
   | Some Oas_compat.Http_client.Request_rejected -> ()
   | other ->
       Alcotest.failf
         "expected Request_rejected, got %s"
         (retryable_error_to_string other))

let test_classify_accept_rejected_startup_crash () =
  let reason =
    "gemini_cli startup crash detected (unsettled top-level await / yoga_wasm)"
  in
  (match Oas_compat.Http_client.classify_accept_rejected reason with
   | Some Oas_compat.Http_client.Startup_crash -> ()
   | other ->
       Alcotest.failf
         "expected Startup_crash, got %s"
         (retryable_error_to_string other))

let test_classify_accept_rejected_unknown_returns_none () =
  let reason = "output_schema violation: value is not a string" in
  (match Oas_compat.Http_client.classify_accept_rejected reason with
   | None -> ()
   | Some _ ->
       Alcotest.fail
         "expected None for unrecognised reason, not a retryable_error code")

let test_is_http_body_parse_error_matches_ollama () =
  let body = {|{"error": "can't find closing '}' in the object"}|} in
  Alcotest.(check bool)
    "Ollama 'can't find closing' body is a parse error"
    true
    (Oas_compat.Http_client.is_http_body_parse_error body)

let test_is_http_body_parse_error_no_match () =
  let body = {|{"error": "context length exceeded"}|} in
  Alcotest.(check bool)
    "Context-overflow body is not a parse error"
    false
    (Oas_compat.Http_client.is_http_body_parse_error body)

let test_is_http_body_parse_error_case_insensitive () =
  (* Marker matching must be case-insensitive per spec. *)
  let body = "CAN'T FIND CLOSING '}'" in
  Alcotest.(check bool)
    "is_http_body_parse_error is case-insensitive"
    true
    (Oas_compat.Http_client.is_http_body_parse_error body)

let () =
  Alcotest.run "oas_compat_cascade_fallback"
    [
      ( "AcceptRejected — per-provider failure cascades (#9932)",
        [
          Alcotest.test_case "kimi_cli exit 1 cascades"
            `Quick test_kimi_cli_exit_1_cascades;
          Alcotest.test_case "gemini_cli startup crash cascades"
            `Quick test_gemini_cli_startup_crash_cascades;
          Alcotest.test_case "kimi_cli startup crash cascades"
            `Quick test_kimi_cli_startup_crash_cascades;
        ] );
      ( "AcceptRejected — capability mismatch still cascades (#9850)",
        [
          Alcotest.test_case "'does not support' cascades"
            `Quick test_does_not_support_still_cascades;
        ] );
      ( "AcceptRejected — unrelated reasons do not cascade",
        [
          Alcotest.test_case "unknown reason stays non-cascadable"
            `Quick test_unknown_reason_does_not_cascade;
        ] );
      ( "Baseline: HTTP errors unaffected",
        [
          Alcotest.test_case "HTTP 429 cascades" `Quick test_http_429_cascades;
        ] );
      ( "ProviderTerminal — agent-level terminal does not cascade",
        [
          Alcotest.test_case "Max_turns classify + cascade + message"
            `Quick test_provider_terminal_max_turns;
          Alcotest.test_case "Other classify + cascade + message"
            `Quick test_provider_terminal_other;
        ] );
      ( "ProviderFailure — typed provider-local skips cascade",
        [
          Alcotest.test_case "Capacity_exhausted classify + cascade"
            `Quick test_provider_failure_capacity_cascades;
          Alcotest.test_case "Hard_quota classify + cascade + message"
            `Quick test_provider_failure_hard_quota_cascades;
          Alcotest.test_case "Capability_mismatch classify + cascade"
            `Quick test_provider_failure_capability_mismatch_cascades;
        ] );
      ( "error_message helper baseline",
        [
          Alcotest.test_case "preserves existing variants"
            `Quick test_error_message_baseline;
        ] );
      ( "Structured error codes — classify_accept_rejected (M05)",
        [
          Alcotest.test_case "does not support → Model_unsupported"
            `Quick test_classify_accept_rejected_model_unsupported;
          Alcotest.test_case "rejected the request → Request_rejected"
            `Quick test_classify_accept_rejected_request_rejected;
          Alcotest.test_case "startup crash → Startup_crash"
            `Quick test_classify_accept_rejected_startup_crash;
          Alcotest.test_case "unrecognised reason → None"
            `Quick test_classify_accept_rejected_unknown_returns_none;
        ] );
      ( "Structured error codes — is_http_body_parse_error (M04)",
        [
          Alcotest.test_case "Ollama closing-brace body → true"
            `Quick test_is_http_body_parse_error_matches_ollama;
          Alcotest.test_case "context-overflow body → false"
            `Quick test_is_http_body_parse_error_no_match;
          Alcotest.test_case "case-insensitive match"
            `Quick test_is_http_body_parse_error_case_insensitive;
        ] );
    ]

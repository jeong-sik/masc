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
   fallback_applied=None in the observation. *)

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

let () =
  Alcotest.run "oas_compat_cascade_fallback"
    [
      ( "AcceptRejected — per-provider failure cascades (#9932)",
        [
          Alcotest.test_case "kimi_cli exit 1 cascades"
            `Quick test_kimi_cli_exit_1_cascades;
          Alcotest.test_case "gemini_cli startup crash cascades"
            `Quick test_gemini_cli_startup_crash_cascades;
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
    ]

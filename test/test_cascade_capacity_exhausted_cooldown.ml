(** Pins the typed extraction of [Provider.CapacityExhausted] retry_after
    from an [Agent_sdk.Error.sdk_error] via
    [Cascade_attempt_fsm.sdk_error_capacity_exhausted_retry_after_s].

    Without this helper, [Capacity_exhausted] events fall through to
    [record_failure] (threshold-based) instead of [record_soft_rate_limited]
    (immediate). One capacity-exhausted event is sufficient evidence to
    deprioritize a provider — the same reasoning
    [Cascade_health_tracker.soft_rate_limit_cooldown_sec] documents for a 429.

    Closes §6 R2 (admission pre-check wiring) from the 2026-05-20
    consolidated state report. *)

module FSM = Masc_mcp.Cascade_attempt_fsm
module ErrSdk = Agent_sdk.Error

let pp_extract fmt = function
  | None -> Format.fprintf fmt "None"
  | Some None -> Format.fprintf fmt "Some(None)"
  | Some (Some f) -> Format.fprintf fmt "Some(Some(%g))" f

let extract_testable =
  Alcotest.testable pp_extract ( = )

let mk_capacity_exhausted ?retry_after ?(scope = Llm_provider.Error.CapacityProvider)
    ?(affected = []) ?(detail = "capacity exhausted") () : ErrSdk.sdk_error =
  ErrSdk.Provider
    (Llm_provider.Error.CapacityExhausted
       { scope; affected; retry_after; detail })

let test_capacity_with_retry_after_extracted () =
  let err = mk_capacity_exhausted ~retry_after:7.5 () in
  Alcotest.check extract_testable
    "CapacityExhausted with retry_after=7.5 → Some(Some 7.5)"
    (Some (Some 7.5))
    (FSM.sdk_error_capacity_exhausted_retry_after_s err)

let test_capacity_without_retry_after_extracted () =
  let err = mk_capacity_exhausted () in
  Alcotest.check extract_testable
    "CapacityExhausted without retry_after → Some(None)"
    (Some None)
    (FSM.sdk_error_capacity_exhausted_retry_after_s err)

let test_non_capacity_error_returns_none () =
  let err =
    ErrSdk.Provider
      (Llm_provider.Error.RateLimit
         { provider = "test"; retry_after = Some 3.0; detail = "" })
  in
  Alcotest.check extract_testable
    "RateLimit is not CapacityExhausted → None"
    None
    (FSM.sdk_error_capacity_exhausted_retry_after_s err)

let test_hard_quota_returns_none () =
  let err =
    ErrSdk.Provider
      (Llm_provider.Error.HardQuota
         { provider = "test"; retry_after = Some 600.0; detail = "" })
  in
  Alcotest.check extract_testable
    "HardQuota is not CapacityExhausted → None"
    None
    (FSM.sdk_error_capacity_exhausted_retry_after_s err)

let test_soft_rate_limited_helper_does_not_match_capacity () =
  (* Without the new helper, callers reaching only sdk_error_soft_rate_limited
     would miss CapacityExhausted entirely — that's the bug this PR fixes.
     This regression-pin keeps the two helpers semantically distinct. *)
  let err = mk_capacity_exhausted ~retry_after:7.5 () in
  Alcotest.check extract_testable
    "soft_rate_limited helper does NOT swallow CapacityExhausted"
    None
    (FSM.sdk_error_soft_rate_limited err)

let () =
  Alcotest.run "cascade_capacity_exhausted_cooldown"
    [ ( "typed extraction"
      , [ Alcotest.test_case
            "CapacityExhausted with retry_after" `Quick
            test_capacity_with_retry_after_extracted
        ; Alcotest.test_case
            "CapacityExhausted without retry_after" `Quick
            test_capacity_without_retry_after_extracted
        ; Alcotest.test_case
            "non-capacity error → None" `Quick test_non_capacity_error_returns_none
        ; Alcotest.test_case
            "HardQuota is distinct" `Quick test_hard_quota_returns_none
        ; Alcotest.test_case
            "soft_rate_limited does not subsume CapacityExhausted"
            `Quick
            test_soft_rate_limited_helper_does_not_match_capacity
        ] )
    ]

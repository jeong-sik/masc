(** D12 — Synthetic typed backoff for [Capacity_backpressure] with
    [retry_after_sec = None].

    Pre-fix behaviour: a MASC-internal [Capacity_backpressure] classification
    with [retry_after_sec = null] arriving via the keeper turn driver fell
    through to [Cascade_health_tracker.record_failure] (3-failure threshold).
    The cascade then rotated immediately onto the same degraded provider
    because no cooldown had been applied.

    Post-fix behaviour: when [retry_after_sec = None], the consumer injects
    a typed synthetic backoff
    ([Cascade_health_tracker.default_capacity_backpressure_backoff_sec],
    default 5.0s) so the cooldown path applies.  An explicit value is honored
    verbatim. *)

module FSM = Masc_mcp.Cascade_attempt_fsm
module Classify = Masc_mcp.Cascade_error_classify
module HT = Masc_mcp.Cascade_health_tracker

let pp_hint fmt = function
  | None -> Format.fprintf fmt "None"
  | Some (FSM.Cbr_explicit s) -> Format.fprintf fmt "Cbr_explicit(%g)" s
  | Some (FSM.Cbr_synthetic_default s) ->
      Format.fprintf fmt "Cbr_synthetic_default(%g)" s

let hint_testable = Alcotest.testable pp_hint ( = )

let mk_capacity_backpressure ?retry_after_sec
    ?(cascade_name = "test-cascade")
    ?(source = Classify.Provider_capacity)
    ?(detail = "provider capacity full") () =
  let err =
    Classify.Capacity_backpressure
      {
        cascade_name = Classify.cascade_name_of_string cascade_name;
        source;
        detail;
        retry_after_sec;
      }
  in
  Classify.sdk_error_of_masc_internal_error err

let test_explicit_retry_after_honored () =
  let err = mk_capacity_backpressure ~retry_after_sec:10.0 () in
  Alcotest.check hint_testable
    "Capacity_backpressure retry_after_sec=Some 10.0 → Cbr_explicit 10.0"
    (Some (FSM.Cbr_explicit 10.0))
    (FSM.sdk_error_capacity_backpressure_retry_hint err)

let test_missing_retry_after_uses_synthetic_default () =
  let err = mk_capacity_backpressure ?retry_after_sec:None () in
  let expected_default = HT.default_capacity_backpressure_backoff_sec in
  Alcotest.check hint_testable
    "Capacity_backpressure retry_after_sec=None → Cbr_synthetic_default 5.0"
    (Some (FSM.Cbr_synthetic_default expected_default))
    (FSM.sdk_error_capacity_backpressure_retry_hint err)

let test_synthetic_default_is_positive_and_within_sane_bounds () =
  (* Sanity bounds: synthetic default should be > 0 (else cascade rotates
     immediately) and <= soft_rate_limit_max_clamp_sec (so that the default
     and any explicit retry_after hint share the same upper bound). *)
  let default = HT.default_capacity_backpressure_backoff_sec in
  Alcotest.(check bool)
    "default_capacity_backpressure_backoff_sec > 0"
    true
    (default > 0.0);
  Alcotest.(check bool)
    "default_capacity_backpressure_backoff_sec <= soft_rate_limit_max_clamp_sec"
    true
    (default <= HT.soft_rate_limit_max_clamp_sec)

let test_non_positive_retry_after_falls_back_to_synthetic () =
  (* retry_after_sec=Some 0.0 or negative is semantically equivalent to
     None — upstream gave no usable backoff hint, so the consumer must
     inject the synthetic default rather than rotating immediately. *)
  let err_zero = mk_capacity_backpressure ~retry_after_sec:0.0 () in
  let expected_default = HT.default_capacity_backpressure_backoff_sec in
  Alcotest.check hint_testable
    "retry_after_sec=Some 0.0 → Cbr_synthetic_default (treat as missing)"
    (Some (FSM.Cbr_synthetic_default expected_default))
    (FSM.sdk_error_capacity_backpressure_retry_hint err_zero);
  let err_neg = mk_capacity_backpressure ~retry_after_sec:(-1.0) () in
  Alcotest.check hint_testable
    "retry_after_sec=Some -1.0 → Cbr_synthetic_default (treat as missing)"
    (Some (FSM.Cbr_synthetic_default expected_default))
    (FSM.sdk_error_capacity_backpressure_retry_hint err_neg)

let test_non_capacity_backpressure_returns_none () =
  (* A Provider.RateLimit error is distinct — it must NOT be subsumed
     by the new helper.  The two helpers
     (capacity_backpressure_retry_after_s vs capacity_backpressure_retry_hint)
     target different sdk_error shapes and must remain orthogonal. *)
  let err =
    Agent_sdk.Error.Provider
      (Llm_provider.Error.RateLimit
         { provider = "test"; retry_after = Some 3.0; detail = "" })
  in
  Alcotest.check hint_testable
    "non-Capacity_backpressure → None"
    None
    (FSM.sdk_error_capacity_backpressure_retry_hint err)

let () =
  Alcotest.run "cascade_capacity_backpressure_synthetic_backoff"
    [
      ( "typed retry hint",
        [
          Alcotest.test_case "explicit retry_after honored" `Quick
            test_explicit_retry_after_honored;
          Alcotest.test_case "missing retry_after uses synthetic default" `Quick
            test_missing_retry_after_uses_synthetic_default;
          Alcotest.test_case "synthetic default within sane bounds" `Quick
            test_synthetic_default_is_positive_and_within_sane_bounds;
          Alcotest.test_case "non-positive retry_after falls back" `Quick
            test_non_positive_retry_after_falls_back_to_synthetic;
          Alcotest.test_case "non-Capacity_backpressure → None" `Quick
            test_non_capacity_backpressure_returns_none;
        ] );
    ]

(** Standalone Alcotest suite for [Cascade_preflight_state].

    Built outside of [dune] to avoid contention on the workspace-wide
    [dune] / [opam] locks (see CLAUDE.md token-miser §5 — dune build is
    blocked while a 5+ process queue holds the locks). Compile with:

    {[
    ocamlfind ocamlc -package alcotest -linkpkg \
      prometheus.ml ../../lib/cascade/cascade_preflight_state.mli \
      ../../lib/cascade/cascade_preflight_state.ml \
      test_cascade_preflight_state.ml -o run_test
    ./run_test
    ]}

    Covered properties:

    - First record returns [`First]; subsequent records of same
      fingerprint advance the count.
    - Same (tier_group, provider, reason) reaching [threshold]
      returns [`Threshold_disable n] exactly once. Subsequent same
      records return [`Already_disabled].
    - Different reasons for the same provider count independently
      until any one reaches threshold (provider is disabled at
      provider-level, not fingerprint-level).
    - [reset_on_health_recovery] clears fingerprints and removes
      provider from disabled list; returns [true] iff it was
      previously disabled.
    - [reason_slug] stable for log/metric interpolation. *)

module S = Cascade_preflight_state

let outcome_pp fmt = function
  | `First -> Format.fprintf fmt "First"
  | `Repeated n -> Format.fprintf fmt "Repeated %d" n
  | `Threshold_disable n -> Format.fprintf fmt "Threshold_disable %d" n
  | `Already_disabled -> Format.fprintf fmt "Already_disabled"
;;

let outcome_eq (a : S.record_outcome) (b : S.record_outcome) =
  match a, b with
  | `First, `First -> true
  | `Repeated x, `Repeated y -> x = y
  | `Threshold_disable x, `Threshold_disable y -> x = y
  | `Already_disabled, `Already_disabled -> true
  | (`First | `Repeated _ | `Threshold_disable _ | `Already_disabled), _ -> false
;;

let outcome = Alcotest.testable outcome_pp outcome_eq

(* ── First / Repeated / Threshold ────────────────────────────── *)

let test_first_call_returns_first () =
  let t = S.create ~threshold:5 () in
  let o =
    S.record t ~tier_group:"strict_tool_candidates" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check outcome) "first" `First o
;;

let test_second_call_returns_repeated_2 () =
  let t = S.create ~threshold:5 () in
  let _ =
    S.record t ~tier_group:"strict_tool_candidates" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  let o =
    S.record t ~tier_group:"strict_tool_candidates" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check outcome) "second is repeated=2" (`Repeated 2) o
;;

let test_threshold_disable_at_exact_count () =
  let t = S.create ~threshold:5 () in
  let group = "strict_tool_candidates" in
  let prov = "http://a" in
  let reason = S.Health_check_failed_repeatedly in
  let r1 = S.record t ~tier_group:group ~provider:prov ~reason in
  let r2 = S.record t ~tier_group:group ~provider:prov ~reason in
  let r3 = S.record t ~tier_group:group ~provider:prov ~reason in
  let r4 = S.record t ~tier_group:group ~provider:prov ~reason in
  let r5 = S.record t ~tier_group:group ~provider:prov ~reason in
  Alcotest.(check outcome) "1=First" `First r1;
  Alcotest.(check outcome) "2=Repeated 2" (`Repeated 2) r2;
  Alcotest.(check outcome) "3=Repeated 3" (`Repeated 3) r3;
  Alcotest.(check outcome) "4=Repeated 4" (`Repeated 4) r4;
  Alcotest.(check outcome) "5=Threshold_disable 5" (`Threshold_disable 5) r5
;;

let test_after_threshold_returns_already_disabled () =
  let t = S.create ~threshold:3 () in
  let group = "g" in
  let prov = "http://a" in
  let reason = S.Health_check_failed_repeatedly in
  let _ = S.record t ~tier_group:group ~provider:prov ~reason in
  let _ = S.record t ~tier_group:group ~provider:prov ~reason in
  let _ = S.record t ~tier_group:group ~provider:prov ~reason in
  let r4 = S.record t ~tier_group:group ~provider:prov ~reason in
  let r5 = S.record t ~tier_group:group ~provider:prov ~reason in
  Alcotest.(check outcome) "after threshold = Already_disabled" `Already_disabled r4;
  Alcotest.(check outcome) "still already-disabled" `Already_disabled r5
;;

(* ── Reason isolation (provider-level disable) ───────────────── *)

let test_different_reasons_count_independently () =
  let t = S.create ~threshold:5 () in
  let group = "g" in
  let prov = "http://a" in
  let r1 =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Health_check_failed_repeatedly
  in
  let r2 =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Permanent_unhealthy
  in
  let r3 =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Transient_unhealthy
  in
  let r4 =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Rate_limited_long_window
  in
  Alcotest.(check outcome) "reason1 First" `First r1;
  Alcotest.(check outcome) "reason2 First (different fingerprint)" `First r2;
  Alcotest.(check outcome) "reason3 First" `First r3;
  Alcotest.(check outcome) "reason4 First" `First r4
;;

let test_provider_disabled_by_any_reason_blocks_other_reasons () =
  (* Once a provider is disabled (via threshold on reason A), records
     for the same provider under reason B also return Already_disabled
     — disable is provider-level not fingerprint-level. *)
  let t = S.create ~threshold:3 () in
  let group = "g" in
  let prov = "http://a" in
  let _ =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Health_check_failed_repeatedly
  in
  let _ =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Health_check_failed_repeatedly
  in
  let r =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check outcome) "threshold reached on reason A" (`Threshold_disable 3) r;
  let cross =
    S.record t ~tier_group:group ~provider:prov ~reason:S.Permanent_unhealthy
  in
  Alcotest.(check outcome) "reason B blocked too" `Already_disabled cross
;;

(* ── is_disabled membership ──────────────────────────────────── *)

let test_is_disabled_membership () =
  let t = S.create ~threshold:2 () in
  Alcotest.(check bool) "not disabled initially" false
    (S.is_disabled t ~provider:"http://a");
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check bool) "not disabled after 1" false
    (S.is_disabled t ~provider:"http://a");
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check bool) "disabled after threshold" true
    (S.is_disabled t ~provider:"http://a");
  Alcotest.(check bool) "other provider unaffected" false
    (S.is_disabled t ~provider:"http://b")
;;

(* ── reset_on_health_recovery ────────────────────────────────── *)

let test_reset_on_health_recovery_clears_disabled () =
  let t = S.create ~threshold:2 () in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check bool) "disabled" true (S.is_disabled t ~provider:"http://a");
  let was_disabled = S.reset_on_health_recovery t ~provider:"http://a" in
  Alcotest.(check bool) "reset returns previously-disabled=true" true was_disabled;
  Alcotest.(check bool) "no longer disabled" false
    (S.is_disabled t ~provider:"http://a")
;;

let test_reset_after_clear_restarts_count () =
  (* After reset, fingerprints are gone — the next record should be
     First again, not Already_disabled or some leftover count. *)
  let t = S.create ~threshold:2 () in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  let _ = S.reset_on_health_recovery t ~provider:"http://a" in
  let r =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  Alcotest.(check outcome) "post-reset is First again" `First r
;;

let test_reset_when_not_disabled_returns_false () =
  let t = S.create () in
  let was_disabled = S.reset_on_health_recovery t ~provider:"http://nope" in
  Alcotest.(check bool) "reset when never-disabled = false" false was_disabled
;;

(* ── disabled_providers snapshot ─────────────────────────────── *)

let test_disabled_providers_snapshot () =
  let t = S.create ~threshold:2 () in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://a"
      ~reason:S.Health_check_failed_repeatedly
  in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://b"
      ~reason:S.Permanent_unhealthy
  in
  let _ =
    S.record t ~tier_group:"g" ~provider:"http://b"
      ~reason:S.Permanent_unhealthy
  in
  let snap = List.sort String.compare (S.disabled_providers t) in
  Alcotest.(check (list string)) "both providers disabled" [ "http://a"; "http://b" ] snap
;;

(* ── reason_slug stability ───────────────────────────────────── *)

let test_reason_slug_stable () =
  Alcotest.(check string)
    "Health_check_failed_repeatedly"
    "health-check-failed-repeatedly"
    (S.reason_slug S.Health_check_failed_repeatedly);
  Alcotest.(check string)
    "Permanent_unhealthy"
    "permanent-unhealthy"
    (S.reason_slug S.Permanent_unhealthy);
  Alcotest.(check string)
    "Transient_unhealthy"
    "transient-unhealthy"
    (S.reason_slug S.Transient_unhealthy);
  Alcotest.(check string)
    "Rate_limited_long_window"
    "rate-limited-long-window"
    (S.reason_slug S.Rate_limited_long_window)
;;

(* ── default_threshold sanity ────────────────────────────────── *)

let test_default_threshold_is_5 () =
  Alcotest.(check int) "default threshold matches spec (5)" 5 S.default_threshold
;;

let () =
  Alcotest.run "cascade_preflight_state"
    [ ( "first / repeated / threshold"
      , [ Alcotest.test_case "first call returns First" `Quick
            test_first_call_returns_first
        ; Alcotest.test_case "second call returns Repeated 2" `Quick
            test_second_call_returns_repeated_2
        ; Alcotest.test_case "exact count triggers Threshold_disable" `Quick
            test_threshold_disable_at_exact_count
        ; Alcotest.test_case "post-threshold returns Already_disabled" `Quick
            test_after_threshold_returns_already_disabled
        ] )
    ; ( "reason isolation"
      , [ Alcotest.test_case "different reasons count independently" `Quick
            test_different_reasons_count_independently
        ; Alcotest.test_case "provider-level disable blocks other reasons too"
            `Quick
            test_provider_disabled_by_any_reason_blocks_other_reasons
        ] )
    ; ( "is_disabled membership"
      , [ Alcotest.test_case "membership tracks threshold" `Quick
            test_is_disabled_membership
        ] )
    ; ( "reset_on_health_recovery"
      , [ Alcotest.test_case "clears disabled and reports prior state" `Quick
            test_reset_on_health_recovery_clears_disabled
        ; Alcotest.test_case "post-reset restarts count" `Quick
            test_reset_after_clear_restarts_count
        ; Alcotest.test_case "reset on never-disabled returns false" `Quick
            test_reset_when_not_disabled_returns_false
        ] )
    ; ( "snapshot"
      , [ Alcotest.test_case "disabled_providers returns set" `Quick
            test_disabled_providers_snapshot
        ] )
    ; ( "reason slug"
      , [ Alcotest.test_case "stable kebab-case mapping" `Quick
            test_reason_slug_stable
        ] )
    ; ( "constants"
      , [ Alcotest.test_case "default threshold = 5" `Quick
            test_default_threshold_is_5
        ] )
    ]
;;

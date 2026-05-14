(** #10318 — pin the cost ledger source-attribution contract.

    Pre-fix [costs.jsonl] showed 100% [cost_usd=0] across 1697
    entries.  Each silent path (untrusted usage, missing usage,
    OAS cost omission, structurally-unmetered runtime, actual
    zero-token call) collapsed to the same [0.0] field with no
    way for an operator to distinguish "tracking is broken" from
    "this runtime is unmetered" from "OAS did not report cost".
    Without that distinction the operator
    can't pick the right next action: A (audit) vs C (pricing
    SSOT) vs E (cross-link to #9959) all need different evidence.

    These tests pin
    [Keeper_hooks_oas.classify_cost_usd_source]'s bounded
    classification:

    | path                | source string         |
    |---------------------|-----------------------|
    | usage_missing       | missing_usage         |
    | not usage_trusted   | untrusted_usage       |
    | structurally_unmetered runtime | unmetered_provider |
    | trusted + cost > 0  | computed              |
    | trusted + tokens + 0 cost | oas_cost_unreported |
    | trusted + 0 cost and not free | oas_cost_unreported |

    Precedence is fixed (top-down) so a missing-usage call on a
    pricing-known model still labels [missing_usage], not
    [oas_cost_unreported] — the upstream gate is the more
    actionable failure mode. *)

open Alcotest

module H = Masc_mcp.Keeper_hooks_oas

let check_source ~msg ~usage_missing ~usage_trusted ~runtime_unmetered
    ~cost_usd expected =
  let actual =
    H.classify_cost_usd_source ~usage_missing ~usage_trusted
      ~runtime_unmetered ~cost_usd
  in
  check string msg expected actual

(* --- precedence: top-down ordering ------------------------------ *)

let test_missing_usage_wins_over_everything () =
  (* Even with a known-priced model and a positive cost number, an
     upstream missing-usage signal must dominate — that's the
     more-actionable failure mode (provider adapter didn't surface
     usage at all). *)
  check_source
    ~msg:"missing_usage even with priced model + positive cost"
    ~usage_missing:true ~usage_trusted:false
    ~runtime_unmetered:false
    ~cost_usd:0.42
    "missing_usage"

let test_untrusted_wins_over_unmetered_and_catalog () =
  check_source
    ~msg:"untrusted_usage wins over unmetered_provider"
    ~usage_missing:false ~usage_trusted:false
    ~runtime_unmetered:true
    ~cost_usd:0.0
    "untrusted_usage"

(* --- canonical paths --------------------------------------------- *)

let test_unmetered_provider_when_trusted () =
  (* ollama is structurally unmetered; trusted+0 should label as
     [unmetered_provider], without MASC inspecting provider/model pricing. *)
  check_source
    ~msg:"trusted ollama => unmetered_provider"
    ~usage_missing:false ~usage_trusted:true
    ~runtime_unmetered:true
    ~cost_usd:0.0
    "unmetered_provider"

let test_computed_when_trusted_and_positive () =
  check_source
    ~msg:"trusted + paid + cost > 0 => computed"
    ~usage_missing:false ~usage_trusted:true
    ~runtime_unmetered:false
    ~cost_usd:0.0042
    "computed"

let test_oas_cost_unreported_for_zero_cost_tokens () =
  (* Trusted call with tokens but no positive OAS-reported cost falls
     through to [oas_cost_unreported]. MASC must not inspect a local
     provider/model pricing catalog to guess why. *)
  check_source
    ~msg:"trusted tokens without OAS cost => oas_cost_unreported"
    ~usage_missing:false ~usage_trusted:true
    ~runtime_unmetered:false
    ~cost_usd:0.0
    "oas_cost_unreported"

let test_preview_runtime_without_oas_cost_is_unreported () =
  check_source
    ~msg:"preview runtime without OAS cost => oas_cost_unreported"
    ~usage_missing:false ~usage_trusted:true
    ~runtime_unmetered:false
    ~cost_usd:0.0
    "oas_cost_unreported"

(* --- counter wiring (only non-computed sources tick) ------------- *)

let counter_for source =
  Masc_mcp.Prometheus.metric_value_or_zero
    H.cost_emit_source_metric
    ~labels:[ ("source", source) ]
    ()

let test_record_emit_skips_computed () =
  let before = counter_for "computed" in
  H.record_cost_emit_source "computed";
  check (float 0.0001)
    "computed source does not increment counter"
    before
    (counter_for "computed")

let test_record_emit_increments_named_source () =
  let before = counter_for "oas_cost_unreported" in
  H.record_cost_emit_source "oas_cost_unreported";
  check (float 0.0001)
    "oas_cost_unreported +1"
    (before +. 1.0)
    (counter_for "oas_cost_unreported")

let test_counter_isolation_between_sources () =
  (* Bumping oas_cost_unreported must NOT move missing_usage.
     Each source has its own series so dashboards split cleanly. *)
  let other_before = counter_for "missing_usage" in
  H.record_cost_emit_source "oas_cost_unreported";
  check (float 0.0001)
    "missing_usage unchanged when oas_cost_unreported bumps"
    other_before
    (counter_for "missing_usage")

let () =
  run "cost_usd_source_attribution_10318"
    [
      ( "precedence",
        [
          test_case "missing_usage wins over everything" `Quick
            test_missing_usage_wins_over_everything;
          test_case
            "untrusted_usage wins over unmetered + catalog" `Quick
            test_untrusted_wins_over_unmetered_and_catalog;
        ] );
      ( "canonical-paths",
        [
          test_case "unmetered provider when trusted" `Quick
            test_unmetered_provider_when_trusted;
          test_case "computed when trusted and positive" `Quick
            test_computed_when_trusted_and_positive;
          test_case "OAS cost unreported for token usage" `Quick
            test_oas_cost_unreported_for_zero_cost_tokens;
          test_case "preview runtime without OAS cost" `Quick
            test_preview_runtime_without_oas_cost_is_unreported;
        ] );
      ( "counter",
        [
          test_case "computed source does not tick counter" `Quick
            test_record_emit_skips_computed;
          test_case "named source increments counter" `Quick
            test_record_emit_increments_named_source;
          test_case "sources isolated by label" `Quick
            test_counter_isolation_between_sources;
        ] );
    ]

(** #10318 — pin the cost ledger source-attribution contract.

    Pre-fix [costs.jsonl] showed 100% [cost_usd=0] across 1697
    entries.  Each silent path (untrusted usage, missing usage,
    pricing catalog miss, structurally-unmetered provider, actual
    zero-token call) collapsed to the same [0.0] field with no
    way for an operator to distinguish "tracking is broken" from
    "this provider is free" from "this model is missing from the
    pricing catalog".  Without that distinction the operator
    can't pick the right next action: A (audit) vs C (pricing
    SSOT) vs E (cross-link to #9959) all need different evidence.

    These tests pin
    [Keeper_hooks_oas.classify_cost_usd_source]'s 6-way
    classification:

    | path                | source string         |
    |---------------------|-----------------------|
    | usage_missing       | missing_usage         |
    | not usage_trusted   | untrusted_usage       |
    | structurally_unmetered_provider | unmetered_provider |
    | trusted + cost > 0  | computed              |
    | trusted + 0 + no catalog entry | pricing_catalog_miss |
    | trusted + 0 + catalog hit | zero_token_call |

    Precedence is fixed (top-down) so a missing-usage call on a
    pricing-known model still labels [missing_usage], not
    [pricing_catalog_miss] — the upstream gate is the more
    actionable failure mode. *)

open Alcotest

module H = Masc_mcp.Keeper_hooks_oas

let with_known_non_catalog_pricing_models models f =
  let env = "MASC_KNOWN_NON_CATALOG_PRICING_MODELS" in
  let previous = Sys.getenv_opt env in
  Unix.putenv env (String.concat "," models);
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some prior -> Unix.putenv env prior
      | None -> Unix.putenv env "")
    f

let check_source ~msg ~usage_missing ~usage_trusted ~provider ~model
    ~cost_usd expected =
  let actual =
    H.classify_cost_usd_source ~usage_missing ~usage_trusted ~provider
      ~model ~cost_usd
  in
  check string msg expected actual

(* --- precedence: top-down ordering ------------------------------ *)

let test_missing_usage_wins_over_everything () =
  (* Even with a known-priced model and a positive cost number, an
     upstream missing-usage signal must dominate — that's the
     more-actionable failure mode (runtime bridge didn't surface
     usage at all). *)
  check_source
    ~msg:"missing_usage even with priced model + positive cost"
    ~usage_missing:true ~usage_trusted:false
    ~provider:"openai" ~model:"gpt-5-mini"
    ~cost_usd:0.42
    "missing_usage"

let test_untrusted_wins_over_unmetered_and_catalog () =
  check_source
    ~msg:"untrusted_usage wins over unmetered_provider"
    ~usage_missing:false ~usage_trusted:false
    ~provider:"ollama" ~model:"llama3"
    ~cost_usd:0.0
    "untrusted_usage"

(* --- canonical paths --------------------------------------------- *)

let test_unmetered_provider_when_trusted () =
  (* ollama is structurally unmetered; trusted+0 should label as
     [unmetered_provider], NOT [pricing_catalog_miss]. *)
  check_source
    ~msg:"trusted ollama => unmetered_provider"
    ~usage_missing:false ~usage_trusted:true
    ~provider:"ollama" ~model:"llama3"
    ~cost_usd:0.0
    "unmetered_provider"

let test_computed_when_trusted_and_positive () =
  check_source
    ~msg:"trusted + paid + cost > 0 => computed"
    ~usage_missing:false ~usage_trusted:true
    ~provider:"openai" ~model:"gpt-5-mini"
    ~cost_usd:0.0042
    "computed"

let test_pricing_catalog_miss_for_unknown_model () =
  (* Trusted call on a paid provider whose model is NOT in the
     pricing catalog. cost=0 falls through to [pricing_catalog_miss]
     — the actionable signal that says "add upstream OAS entry". *)
  check_source
    ~msg:"unknown model on paid provider => pricing_catalog_miss"
    ~usage_missing:false ~usage_trusted:true
    ~provider:"openai"
    ~model:"this-model-is-not-in-the-pricing-catalog-10318"
    ~cost_usd:0.0
    "pricing_catalog_miss"

let test_unresolved_model_alias_for_auto_alias () =
  (* The OAS catalog may carry zero-price fallback entries for selector
     aliases, but "auto" is not a billable model id. Treating it as
     free or a real catalog miss would hide missing canonical telemetry. *)
  check_source
    ~msg:"auto alias on paid provider => unresolved_model_alias"
    ~usage_missing:false ~usage_trusted:true
    ~provider:"openai"
    ~model:"auto"
    ~cost_usd:0.0
    "unresolved_model_alias"

let test_known_unpriced_model_from_config () =
  with_known_non_catalog_pricing_models
    [ "fixture-known-unpriced-model-10318" ]
    (fun () ->
      check_source
        ~msg:"configured non-catalog model => known_unpriced_model"
        ~usage_missing:false ~usage_trusted:true
        ~provider:"openai"
        ~model:"fixture-known-unpriced-model-10318"
        ~cost_usd:0.0
        "known_unpriced_model")

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
  let before = counter_for "pricing_catalog_miss" in
  H.record_cost_emit_source "pricing_catalog_miss";
  check (float 0.0001)
    "pricing_catalog_miss +1"
    (before +. 1.0)
    (counter_for "pricing_catalog_miss")

let test_counter_isolation_between_sources () =
  (* Bumping pricing_catalog_miss must NOT move missing_usage.
     Each source has its own series so dashboards split cleanly. *)
  let other_before = counter_for "missing_usage" in
  H.record_cost_emit_source "pricing_catalog_miss";
  check (float 0.0001)
    "missing_usage unchanged when pricing_catalog_miss bumps"
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
          test_case "pricing_catalog_miss for unknown model" `Quick
            test_pricing_catalog_miss_for_unknown_model;
          test_case "unresolved_model_alias for auto alias" `Quick
            test_unresolved_model_alias_for_auto_alias;
          test_case "known_unpriced_model from config" `Quick
            test_known_unpriced_model_from_config;
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

(* test/test_keeper_hooks_oas_pricing.ml

   #9868 — [estimate_usage_cost_usd] must NOT silently claim $0 for
   unknown paid-provider models. The previous implementation used
   [pricing_for_model] which returns [zero_pricing] on miss; the fix
   switches to [pricing_for_model_opt] + explicit [None] handling that
   fires the [masc_pricing_catalog_miss_total] metric.

   Known-model cases exercise the happy path (pricing catalog hit →
   non-zero cost for non-zero tokens). *)

module Hooks = Masc_mcp.Keeper_hooks_oas
module Oas = Masc_mcp.Oas
module Pricing = Llm_provider.Pricing
module Prom = Masc_mcp.Prometheus

let mk_usage
    ?(cache_creation = 0) ?(cache_read = 0) ?(cost_usd = None)
    ~input ~output () : Oas.Types.api_usage =
  {
    input_tokens = input;
    output_tokens = output;
    cache_creation_input_tokens = cache_creation;
    cache_read_input_tokens = cache_read;
    cost_usd;
  }

let catalog_miss_for model =
  Prom.metric_value_or_zero
    "masc_pricing_catalog_miss_total"
    ~labels:[("model", model)] ()

let test_known_model_returns_nonzero_cost () =
  let usage = mk_usage ~input:1_000_000 ~output:100_000 () in
  let cost = Hooks.estimate_usage_cost_usd
    ~model:"claude-sonnet-4-6" usage in
  (* $3/M input + $15/M output = $3 + $1.5 = $4.5. Exact arithmetic;
     any pricing regression in the catalog will shift this. *)
  Alcotest.(check bool)
    "sonnet-4-6 priced > 0"
    true (cost > 0.0);
  Alcotest.(check (float 0.01))
    "sonnet-4-6 exact"
    4.5 cost

let test_unknown_model_emits_catalog_miss () =
  let sentinel_model = "pricing-test-unknown-xyz-2026-04-24" in
  let before = catalog_miss_for sentinel_model in
  let usage = mk_usage ~input:1_000_000 ~output:500_000 () in
  let cost = Hooks.estimate_usage_cost_usd ~model:sentinel_model usage in
  let after = catalog_miss_for sentinel_model in
  Alcotest.(check (float 0.0001))
    "unknown model falls through to 0.0 (not a genuine free price)"
    0.0 cost;
  (* The critical assertion: the miss must be observable. Raw $0 with
     no signal is the #9868 failure mode. *)
  Alcotest.(check (float 0.0001))
    "catalog miss metric incremented by exactly 1"
    1.0 (after -. before)

let test_unknown_model_repeated_calls_accumulate () =
  let sentinel_model = "pricing-test-unknown-accum-2026-04-24" in
  let before = catalog_miss_for sentinel_model in
  let usage = mk_usage ~input:100 ~output:50 () in
  for _ = 1 to 3 do
    let _ = Hooks.estimate_usage_cost_usd ~model:sentinel_model usage in
    ()
  done;
  let after = catalog_miss_for sentinel_model in
  Alcotest.(check (float 0.0001))
    "3 calls → delta 3"
    3.0 (after -. before)

let test_ollama_model_known_free_no_catalog_miss () =
  (* Ollama is in the catalog as free ($0/M). This must NOT be treated
     as a miss — the classifier is "unknown catalog entry", not "zero
     cost". Without this check, the metric would flood on every local
     turn. *)
  let model = "qwen3.6:35b-a3b-mlx-bf16-64k" in
  let before = catalog_miss_for model in
  let usage = mk_usage ~input:10_000 ~output:2_000 () in
  let cost = Hooks.estimate_usage_cost_usd ~model usage in
  let after = catalog_miss_for model in
  Alcotest.(check (float 0.0001)) "known-free → 0.0" 0.0 cost;
  Alcotest.(check (float 0.0001))
    "known-free → NO catalog miss"
    0.0 (after -. before)

let test_pricing_for_model_opt_contract () =
  (* Direct contract check against the upstream API we now rely on.
     If OAS changes [pricing_for_model_opt] semantics, this test
     catches it before the silent $0 re-regresses. *)
  Alcotest.(check bool)
    "sonnet-4-6 in catalog"
    true (Option.is_some (Pricing.pricing_for_model_opt "claude-sonnet-4-6"));
  Alcotest.(check bool)
    "totally-unknown not in catalog"
    true (Option.is_none
            (Pricing.pricing_for_model_opt "totally-unknown-pricing-probe"))

let () =
  Alcotest.run "keeper_hooks_oas_pricing"
    [
      ( "pricing_for_model_opt contract",
        [
          Alcotest.test_case "upstream opt-API semantics"
            `Quick test_pricing_for_model_opt_contract;
        ] );
      ( "estimate_usage_cost_usd",
        [
          Alcotest.test_case "known model → non-zero cost"
            `Quick test_known_model_returns_nonzero_cost;
          Alcotest.test_case "unknown model → catalog miss metric"
            `Quick test_unknown_model_emits_catalog_miss;
          Alcotest.test_case "repeated miss accumulates"
            `Quick test_unknown_model_repeated_calls_accumulate;
          Alcotest.test_case "known free (ollama) does NOT trip miss"
            `Quick test_ollama_model_known_free_no_catalog_miss;
        ] );
    ]

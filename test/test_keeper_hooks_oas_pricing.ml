(* test/test_keeper_hooks_oas_pricing.ml

   #9868 — [estimate_usage_cost_usd] must NOT silently claim $0 for
   unknown paid-provider models. The previous implementation used
   [pricing_for_model] which returns [zero_pricing] on miss; the fix
   switches to [pricing_for_model_opt] + explicit [None] handling that
   fires the [masc_pricing_catalog_miss_total] metric.

   Known-model cases exercise the happy path (pricing catalog hit →
   non-zero cost for non-zero tokens). *)

module Hooks = Masc_mcp.Keeper_hooks_oas
module Pricing = Llm_provider.Pricing
module Prom = Masc_mcp.Prometheus
module Trust = Masc_mcp.Keeper_usage_trust
module Json = Yojson.Safe.Util

let mk_usage
    ?(cache_creation = 0) ?(cache_read = 0) ?(cost_usd = None)
    ~input ~output () : Agent_sdk.Types.api_usage =
  {
    input_tokens = input;
    output_tokens = output;
    cache_creation_input_tokens = cache_creation;
    cache_read_input_tokens = cache_read;
    cost_usd;
  }

let check_json_string name expected json =
  Alcotest.(check string)
    name expected
    (json |> Json.member name |> Json.to_string)

let check_json_float name expected json =
  Alcotest.(check (float 0.000_001))
    name expected
    (json |> Json.member name |> Json.to_float)

let check_json_int name expected json =
  Alcotest.(check int)
    name expected
    (json |> Json.member name |> Json.to_int)

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

let test_cache_tokens_use_provider_cache_rates () =
  let usage =
    mk_usage ~input:1_000_000 ~output:0
      ~cache_creation:100_000 ~cache_read:200_000 ()
  in
  let cost = Hooks.estimate_usage_cost_usd
    ~model:"claude-sonnet-4-6" usage
  in
  (* regular input 700k * $3/M + cache write 100k * $3/M * 1.25
     + cache read 200k * $3/M * 0.1 = $2.535 *)
  Alcotest.(check (float 0.001))
    "cache tokens use Anthropic cache multipliers"
    2.535 cost

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

(* ── cost_status_for_event ─────────────────────────────────────── *)

let test_unpriced_model_with_trusted_usage_gives_unpriced () =
  (* The core "fake success" scenario: usage_trusted=true, but the model
     has no pricing catalog entry. cost_status must be unpriced_model,
     NOT reported_or_estimated. *)
  let status =
    Hooks.cost_status_for_event
      ~provider:"some-provider"
      ~pricing_model:"unpriced-model-xyz-2026"
      ~usage_missing:false
      ~usage_trusted:true
      ~input_tokens:10_000
      ~output_tokens:2_000
      ~cost_usd:0.0
  in
  Alcotest.(check string)
    "unpriced model → Cost_unpriced_model"
    "unpriced_model" (Hooks.cost_status_to_string status)

let test_known_model_with_trusted_usage_gives_priced () =
  let status =
    Hooks.cost_status_for_event
      ~provider:"anthropic"
      ~pricing_model:"claude-sonnet-4-6"
      ~usage_missing:false
      ~usage_trusted:true
      ~input_tokens:10_000
      ~output_tokens:2_000
      ~cost_usd:0.045
  in
  Alcotest.(check string)
    "known model with cost > 0 → priced"
    "priced" (Hooks.cost_status_to_string status)

let test_positive_cost_zero_tokens_gives_priced () =
  let status =
    Hooks.cost_status_for_event
      ~provider:"openai"
      ~pricing_model:"openai:fixed-fee-zero-token-probe-2026"
      ~usage_missing:false
      ~usage_trusted:true
      ~input_tokens:0
      ~output_tokens:0
      ~cost_usd:0.031
  in
  Alcotest.(check string)
    "positive cost with zero tokens → priced"
    "priced" (Hooks.cost_status_to_string status)

let test_known_model_zero_cost_with_tokens_gives_known_free () =
  (* Known model, trusted usage, but cost_usd=0 (e.g. catalog hit but
     input/output are both zero-cost tiers). Still classified as
     "known_free" because the catalog was found and its computed price is
     zero. *)
  let status =
    Hooks.cost_status_for_event
      ~provider:"ollama"
      ~pricing_model:"qwen3.6:35b-a3b-mlx-bf16-64k"
      ~usage_missing:false
      ~usage_trusted:true
      ~input_tokens:10_000
      ~output_tokens:2_000
      ~cost_usd:0.0
  in
  Alcotest.(check string)
    "known-free model → known_free"
    "known_free" (Hooks.cost_status_to_string status)

let test_missing_usage_gives_usage_missing () =
  let status =
    Hooks.cost_status_for_event
      ~provider:"anthropic"
      ~pricing_model:"claude-sonnet-4-6"
      ~usage_missing:true
      ~usage_trusted:false
      ~input_tokens:0
      ~output_tokens:0
      ~cost_usd:0.0
  in
  Alcotest.(check string)
    "missing usage → usage_missing"
    "usage_missing" (Hooks.cost_status_to_string status)

(* ── cost_event_payload ────────────────────────────────────────── *)

let test_cost_event_payload_masks_unpriced_model () =
  let payload =
    Hooks.cost_event_payload
      ~agent_name:"keeper-a"
      ~task_id:(Some "task-a")
      ~model:"openai:unpriced-cost-event-probe-2026"
      ~input_tokens:500
      ~output_tokens:200
      ~cost_usd:0.0
      ~usage_trust:Trust.Usage_trusted
      ()
  in
  check_json_string "unpriced status" "unpriced_model" payload;
  check_json_string "unpriced reason" "pricing_catalog_miss" payload;
  check_json_string "unpriced source" "pricing_catalog_miss" payload;
  check_json_float "unpriced cost masked" 0.0 payload

let test_cost_event_payload_preserves_positive_zero_token_cost () =
  let payload =
    Hooks.cost_event_payload
      ~agent_name:"keeper-a"
      ~task_id:None
      ~model:"openai:fixed-fee-zero-token-probe-2026"
      ~input_tokens:0
      ~output_tokens:0
      ~cost_usd:0.031
      ~usage_trust:Trust.Usage_trusted
      ()
  in
  check_json_string "positive zero-token status" "priced" payload;
  check_json_string "positive zero-token source" "computed" payload;
  check_json_float "positive zero-token cost preserved" 0.031 payload;
  check_json_int "positive zero-token input tokens" 0 payload;
  check_json_int "positive zero-token output tokens" 0 payload

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
          Alcotest.test_case "cache tokens use provider cache rates"
            `Quick test_cache_tokens_use_provider_cache_rates;
          Alcotest.test_case "unknown model → catalog miss metric"
            `Quick test_unknown_model_emits_catalog_miss;
          Alcotest.test_case "repeated miss accumulates"
            `Quick test_unknown_model_repeated_calls_accumulate;
          Alcotest.test_case "known free (ollama) does NOT trip miss"
            `Quick test_ollama_model_known_free_no_catalog_miss;
        ] );
      ( "cost_status_for_event",
        [
          Alcotest.test_case
            "unpriced model + trusted usage → unpriced_model"
            `Quick test_unpriced_model_with_trusted_usage_gives_unpriced;
          Alcotest.test_case
            "known model + cost > 0 → priced"
            `Quick test_known_model_with_trusted_usage_gives_priced;
          Alcotest.test_case
            "positive cost + zero tokens → priced"
            `Quick test_positive_cost_zero_tokens_gives_priced;
          Alcotest.test_case
            "known-free model + zero cost → known_free"
            `Quick test_known_model_zero_cost_with_tokens_gives_known_free;
          Alcotest.test_case
            "missing usage → usage_missing"
            `Quick test_missing_usage_gives_usage_missing;
        ] );
      ( "cost_event_payload",
        [
          Alcotest.test_case
            "unpriced model status + mask"
            `Quick test_cost_event_payload_masks_unpriced_model;
          Alcotest.test_case
            "positive cost + zero tokens preserved"
            `Quick test_cost_event_payload_preserves_positive_zero_token_cost;
        ] );
    ]

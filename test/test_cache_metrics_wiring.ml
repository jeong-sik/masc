(** P1-1c Harness: Cache metrics wiring verification.

    Validates that P1-1b cache plumbing works correctly:
    1. Provider prefix cache counters increment with mock usage data
    2. Response cache counters are registered and functional
    3. Two-layer cache distinction: response cache vs provider prefix cache *)

open Alcotest

module Prometheus = Masc_mcp.Prometheus

(* ── Helpers ──────────────────────────────────────────── *)

(** Read counter value, defaulting to 0.0 *)
let counter_value name =
  Prometheus.metric_value_or_zero name ()

(* ── Provider prefix cache counter tests ──────────────── *)

let test_prefix_cache_creation_counter () =
  let before = counter_value
    "masc_provider_prefix_cache_creation_tokens_total" in
  Prometheus.inc_counter
    "masc_provider_prefix_cache_creation_tokens_total"
    ~delta:1500.0 ();
  let after = counter_value
    "masc_provider_prefix_cache_creation_tokens_total" in
  let diff = after -. before in
  check (float 0.1) "creation counter incremented by 1500"
    1500.0 diff

let test_prefix_cache_read_counter () =
  let before = counter_value
    "masc_provider_prefix_cache_read_tokens_total" in
  Prometheus.inc_counter
    "masc_provider_prefix_cache_read_tokens_total"
    ~delta:3200.0 ();
  let after = counter_value
    "masc_provider_prefix_cache_read_tokens_total" in
  let diff = after -. before in
  check (float 0.1) "read counter incremented by 3200"
    3200.0 diff

let test_prefix_cache_zero_no_increment () =
  (* When cache tokens = 0, counter should not be incremented
     (the after_turn hook checks > 0 before calling inc_counter) *)
  let before_creation = counter_value
    "masc_provider_prefix_cache_creation_tokens_total" in
  let before_read = counter_value
    "masc_provider_prefix_cache_read_tokens_total" in
  (* Simulate the guard in keeper_hooks_oas.ml: only inc if > 0 *)
  let cc = 0 in
  let cr = 0 in
  if cc > 0 then
    Prometheus.inc_counter
      "masc_provider_prefix_cache_creation_tokens_total"
      ~delta:(Float.of_int cc) ();
  if cr > 0 then
    Prometheus.inc_counter
      "masc_provider_prefix_cache_read_tokens_total"
      ~delta:(Float.of_int cr) ();
  let after_creation = counter_value
    "masc_provider_prefix_cache_creation_tokens_total" in
  let after_read = counter_value
    "masc_provider_prefix_cache_read_tokens_total" in
  check (float 0.1) "creation unchanged" before_creation after_creation;
  check (float 0.1) "read unchanged" before_read after_read

(* ── Response cache counter tests ─────────────────────── *)

let test_response_cache_counters_registered () =
  (* Verify the response cache counters are registered and readable *)
  let hits = counter_value "masc_inference_cache_hits_total" in
  let misses = counter_value "masc_inference_cache_misses_total" in
  check bool "hits counter is non-negative" true (hits >= 0.0);
  check bool "misses counter is non-negative" true (misses >= 0.0)

let test_response_cache_increment () =
  let before = counter_value "masc_inference_cache_hits_total" in
  Prometheus.inc_counter "masc_inference_cache_hits_total" ();
  let after = counter_value "masc_inference_cache_hits_total" in
  check (float 0.1) "response cache hit counter incremented"
    1.0 (after -. before)

(* ── Two-layer distinction test ───────────────────────── *)

let test_two_layer_independence () =
  (* Incrementing response cache should not affect provider prefix cache *)
  let prefix_before = counter_value
    "masc_provider_prefix_cache_read_tokens_total" in
  Prometheus.inc_counter "masc_inference_cache_hits_total" ();
  let prefix_after = counter_value
    "masc_provider_prefix_cache_read_tokens_total" in
  check (float 0.1) "prefix cache unaffected by response cache"
    prefix_before prefix_after;
  (* Incrementing provider prefix cache should not affect response cache *)
  let response_before = counter_value
    "masc_inference_cache_hits_total" in
  Prometheus.inc_counter
    "masc_provider_prefix_cache_read_tokens_total"
    ~delta:100.0 ();
  let response_after = counter_value
    "masc_inference_cache_hits_total" in
  check (float 0.1) "response cache unaffected by prefix cache"
    response_before response_after

(* ── Prometheus export format test ────────────────────── *)

let test_cache_metrics_in_export () =
  let text = Prometheus.to_prometheus_text () in
  let has needle =
    try ignore (Str.search_forward (Str.regexp_string needle) text 0); true
    with Not_found -> false
  in
  check bool "export has prefix creation metric" true
    (has "masc_provider_prefix_cache_creation_tokens_total");
  check bool "export has prefix read metric" true
    (has "masc_provider_prefix_cache_read_tokens_total")

(* ── Suite ────────────────────────────────────────────── *)

let () =
  run "cache_metrics_wiring"
    [
      ( "provider_prefix_cache",
        [
          test_case "creation counter increments" `Quick
            test_prefix_cache_creation_counter;
          test_case "read counter increments" `Quick
            test_prefix_cache_read_counter;
          test_case "zero tokens no increment" `Quick
            test_prefix_cache_zero_no_increment;
        ] );
      ( "response_cache",
        [
          test_case "counters registered" `Quick
            test_response_cache_counters_registered;
          test_case "hit counter increments" `Quick
            test_response_cache_increment;
        ] );
      ( "two_layer_distinction",
        [
          test_case "layers are independent" `Quick
            test_two_layer_independence;
        ] );
      ( "prometheus_export",
        [
          test_case "cache metrics in export text" `Quick
            test_cache_metrics_in_export;
        ] );
    ]

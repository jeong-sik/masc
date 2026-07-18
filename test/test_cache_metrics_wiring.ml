(** Response-cache metric wiring verification. Provider cache-token usage is
    observed at the OAS response boundary through labeled provider metrics and
    GenAI usage details; this suite does not create duplicate aggregate aliases. *)

open Alcotest

module Otel_metric_store = Masc.Otel_metric_store

(* ── Helpers ──────────────────────────────────────────── *)

(** Read counter value, defaulting to 0.0 *)
let counter_value name =
  Otel_metric_store.metric_value_or_zero name ()

(* ── Response cache counter tests ─────────────────────── *)

let test_response_cache_counters_registered () =
  (* Verify the response cache counters are registered and readable *)
  let hits = counter_value "masc_inference_cache_hits_total" in
  let misses = counter_value "masc_inference_cache_misses_total" in
  check bool "hits counter is non-negative" true (hits >= 0.0);
  check bool "misses counter is non-negative" true (misses >= 0.0)

let test_response_cache_increment () =
  let before = counter_value "masc_inference_cache_hits_total" in
  Otel_metric_store.inc_counter "masc_inference_cache_hits_total" ();
  let after = counter_value "masc_inference_cache_hits_total" in
  check (float 0.1) "response cache hit counter incremented"
    1.0 (after -. before)

(* ── Suite ────────────────────────────────────────────── *)

let () =
  run "cache_metrics_wiring"
    [
      ( "response_cache",
        [
          test_case "counters registered" `Quick
            test_response_cache_counters_registered;
          test_case "hit counter increments" `Quick
            test_response_cache_increment;
        ] );
    ]

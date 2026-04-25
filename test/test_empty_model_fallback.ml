(* #10083: [observed_model_label_of_response] normalizes empty
   [response.model] through a 3-tier fallback
   (response.model -> canonical_model_id -> "unknown_provider") so metric
   labels stay searchable and [pricing_catalog_miss] carries a
   diagnostic label instead of the silent empty string. *)

module KH = Masc_mcp.Keeper_hooks_oas
module Prometheus = Masc_mcp.Prometheus

(* Construct a minimal [Agent_sdk.Types.api_response].  We cannot
   introspect the full record definition here, so we build the
   fields we need through the public-facing [api_response] type
   defined in [agent_sdk]. *)

let empty_usage : Agent_sdk.Types.api_usage =
  { input_tokens = 0;
    output_tokens = 0;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd = None }

let empty_telemetry : Agent_sdk.Types.inference_telemetry =
  { system_fingerprint = None;
    timings = None;
    reasoning_tokens = None;
    request_latency_ms = 0;
    peak_memory_gb = None;
    provider_kind = None;
    reasoning_effort = None;
    canonical_model_id = None;
    effective_context_window = None;
    provider_internal_action_count = None }

let make_response ?(model = "") ?telemetry ?usage () : Agent_sdk.Types.api_response =
  {
    id = "";
    model;
    content = [];
    stop_reason = Agent_sdk.Types.EndTurn;
    usage;
    telemetry;
  }

let test_non_empty_model_passes_through () =
  let before =
    Prometheus.metric_total Prometheus.metric_after_turn_empty_model
  in
  let r = make_response ~model:"claude_code:auto" () in
  Alcotest.(check string)
    "model returned verbatim"
    "claude_code:auto"
    (KH.observed_model_label_of_response ~keeper_name:"test-nonempty" r);
  Alcotest.(check (float 0.01))
    "non-empty path does not increment fallback metric"
    before
    (Prometheus.metric_total Prometheus.metric_after_turn_empty_model)

let test_empty_model_falls_back_to_telemetry () =
  let labels =
    [ ("keeper_name", "test-telemetry");
      ("source", "telemetry_resolved") ]
  in
  let before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_after_turn_empty_model ~labels ()
  in
  let telemetry =
    { empty_telemetry with
      canonical_model_id = Some "gpt-5.4-codex-spark" }
  in
  let r = make_response ~model:"" ~telemetry () in
  Alcotest.(check string)
    "telemetry canonical id used when response.model empty"
    "gpt-5.4-codex-spark"
    (KH.observed_model_label_of_response ~keeper_name:"test-telemetry" r);
  Alcotest.(check (float 0.01))
    "telemetry fallback increments source metric"
    (before +. 1.0)
    (Prometheus.metric_value_or_zero
       Prometheus.metric_after_turn_empty_model ~labels ())

let test_empty_and_no_telemetry_returns_sentinel () =
  let labels =
    [ ("keeper_name", "test-sentinel");
      ("source", "unknown_sentinel") ]
  in
  let before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_after_turn_empty_model ~labels ()
  in
  let r = make_response ~model:"" () in
  Alcotest.(check string)
    "sentinel used when both channels empty"
    "unknown_provider"
    (KH.observed_model_label_of_response ~keeper_name:"test-sentinel" r);
  Alcotest.(check (float 0.01))
    "sentinel fallback increments source metric"
    (before +. 1.0)
    (Prometheus.metric_value_or_zero
       Prometheus.metric_after_turn_empty_model ~labels ())

let test_empty_and_empty_telemetry_canonical_returns_sentinel () =
  let telemetry =
    { empty_telemetry with canonical_model_id = Some "   " }
  in
  let r = make_response ~model:"" ~telemetry () in
  Alcotest.(check string)
    "whitespace-only canonical id still falls through to sentinel"
    "unknown_provider"
    (KH.observed_model_label_of_response ~keeper_name:"test-whitespace" r)

let () =
  Alcotest.run "empty_model_fallback" [
    "observed_model_label", [
      Alcotest.test_case "non-empty passes through" `Quick
        test_non_empty_model_passes_through;
      Alcotest.test_case "empty -> telemetry canonical id" `Quick
        test_empty_model_falls_back_to_telemetry;
      Alcotest.test_case "empty + no telemetry -> sentinel" `Quick
        test_empty_and_no_telemetry_returns_sentinel;
      Alcotest.test_case "empty + whitespace canonical -> sentinel" `Quick
        test_empty_and_empty_telemetry_canonical_returns_sentinel;
    ];
  ]

(* test/test_response_model_empty_10083.ml

   #10083: pin the three-way fallback for empty [response.model]
   in [Keeper_hooks_oas.resolve_after_turn_model].  When an OAS
   transport delivers [response.model = ""] (observed on kimi_cli
   silent-failure and on CompletionContractViolation synthetic
   responses), the hook used to emit empty-string labels into every
   per-model counter, contaminating per-provider aggregates and
   silently wiping pricing attribution.

   The resolver applies a three-tier fallback and counts every
   recovery so the operator can attribute each leak:

     raw non-empty            -> use raw
     raw empty + telemetry    -> use [canonical_model_id], source="telemetry_resolved"
     raw empty + no telemetry -> use [unknown_model_sentinel], source="unknown_sentinel"

   The test asserts:
     - the resolved string matches the tier documented above;
     - [masc_after_turn_response_model_empty_total] is NOT emitted
       on the raw-non-empty path (avoids false-positive alerts); and
     - it IS emitted with the correct [(keeper, source)] label pair
       on each fallback tier. *)

module Hooks = Masc_mcp.Keeper_hooks_oas
module Prom = Masc_mcp.Prometheus

let metric_name = Hooks.empty_response_model_metric
let alias_metric_name = Hooks.alias_response_model_metric

let counter_for ~keeper ~source =
  Prom.metric_value_or_zero
    metric_name
    ~labels:[ ("keeper", keeper); ("source", source) ]
    ()

let alias_counter_for ~keeper ~alias ~source =
  Prom.metric_value_or_zero
    alias_metric_name
    ~labels:[ ("keeper", keeper); ("alias", alias); ("source", source) ]
    ()

let make_zero_usage : Agent_sdk.Types.api_usage =
  { input_tokens = 0; output_tokens = 0;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd = None }

let make_response ?(model = "") ?telemetry () : Agent_sdk.Types.api_response =
  {
    id = "msg-test-10083";
    model;
    stop_reason = EndTurn;
    content = [];
    usage = Some make_zero_usage;
    telemetry;
  }

let make_telemetry ?canonical_model_id () : Agent_sdk.Types.inference_telemetry =
  {
    system_fingerprint = None;
    timings = None;
    reasoning_tokens = None;
    reasoning_tokens_estimated = false;
    request_latency_ms = Some 0;
    peak_memory_gb = None;
    provider_kind = None;
    reasoning_effort = None;
    canonical_model_id;
    effective_context_window = None;
    provider_internal_action_count = None;
  }

(* Raw model is non-empty — resolver must return it verbatim and
   must NOT emit the fallback counter. *)
let test_non_empty_raw_is_returned_verbatim () =
  let keeper = "test-keeper-raw-ok-10083" in
  let before_telemetry = counter_for ~keeper ~source:"telemetry_resolved" in
  let before_unknown = counter_for ~keeper ~source:"unknown_sentinel" in
  let response = make_response ~model:"claude-opus-4-7" () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "raw passed through" "claude-opus-4-7" resolved;
  Alcotest.(check (float 0.0001))
    "telemetry_resolved counter unchanged"
    before_telemetry
    (counter_for ~keeper ~source:"telemetry_resolved");
  Alcotest.(check (float 0.0001))
    "unknown_sentinel counter unchanged"
    before_unknown
    (counter_for ~keeper ~source:"unknown_sentinel")

(* Raw empty, telemetry carries canonical_model_id — resolver
   returns the canonical id and emits source="telemetry_resolved". *)
let test_empty_raw_falls_back_to_telemetry () =
  let keeper = "test-keeper-telemetry-fallback-10083" in
  let before = counter_for ~keeper ~source:"telemetry_resolved" in
  let telemetry =
    make_telemetry ~canonical_model_id:"anthropic:claude-opus-4-7" ()
  in
  let response = make_response ~model:"" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string)
    "resolver returned canonical_model_id"
    "anthropic:claude-opus-4-7" resolved;
  Alcotest.(check (float 0.0001))
    "telemetry_resolved counter +1"
    (before +. 1.0)
    (counter_for ~keeper ~source:"telemetry_resolved")

(* Raw empty, telemetry also lacks canonical_model_id — resolver
   returns [unknown_model_sentinel] and emits
   source="unknown_sentinel".  This keeps downstream counter labels
   explicit rather than ambiguous empty strings. *)
let test_empty_everywhere_uses_sentinel () =
  let keeper = "test-keeper-sentinel-10083" in
  let before = counter_for ~keeper ~source:"unknown_sentinel" in
  let response = make_response ~model:"" () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string)
    "sentinel returned"
    Hooks.unknown_model_sentinel resolved;
  Alcotest.(check string)
    "sentinel is the canonical unknown-provider string"
    "unknown_provider" resolved;
  Alcotest.(check (float 0.0001))
    "unknown_sentinel counter +1"
    (before +. 1.0)
    (counter_for ~keeper ~source:"unknown_sentinel")

(* Telemetry present but canonical_model_id is the empty string —
   resolver must treat that the same as None and fall through to
   the sentinel, not propagate the empty string. *)
let test_empty_canonical_id_falls_through_to_sentinel () =
  let keeper = "test-keeper-empty-canonical-10083" in
  let before_sentinel = counter_for ~keeper ~source:"unknown_sentinel" in
  let before_telemetry = counter_for ~keeper ~source:"telemetry_resolved" in
  let telemetry = make_telemetry ~canonical_model_id:"" () in
  let response = make_response ~model:"" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string)
    "falls through to sentinel"
    "unknown_provider" resolved;
  Alcotest.(check (float 0.0001))
    "unknown_sentinel counter +1"
    (before_sentinel +. 1.0)
    (counter_for ~keeper ~source:"unknown_sentinel");
  Alcotest.(check (float 0.0001))
    "telemetry_resolved counter unchanged (empty canonical doesn't count as resolution)"
    before_telemetry
    (counter_for ~keeper ~source:"telemetry_resolved")

(* Raw model [auto] is non-empty, but it is not a billable model ID.
   When OAS supplies [canonical_model_id], use that for downstream
   metrics and pricing attribution instead of poisoning costs.jsonl with
   model="auto". *)
let test_auto_raw_falls_back_to_canonical_model_id () =
  let keeper = "test-keeper-auto-canonical-10318" in
  let before =
    alias_counter_for ~keeper ~alias:"auto" ~source:"telemetry_canonical"
  in
  let telemetry = make_telemetry ~canonical_model_id:"gpt-4.1" () in
  let response = make_response ~model:"auto" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "auto resolved to canonical" "gpt-4.1" resolved;
  Alcotest.(check (float 0.0001))
    "alias fallback counter +1"
    (before +. 1.0)
    (alias_counter_for ~keeper ~alias:"auto" ~source:"telemetry_canonical")

let test_provider_prefixed_auto_falls_back_to_canonical_model_id () =
  let keeper = "test-keeper-prefixed-auto-canonical-10318" in
  let before =
    alias_counter_for ~keeper ~alias:"auto" ~source:"telemetry_canonical"
  in
  let telemetry = make_telemetry ~canonical_model_id:"claude-sonnet-4-6" () in
  let response = make_response ~model:"claude_code:auto" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string)
    "provider-prefixed auto resolved to canonical"
    "claude-sonnet-4-6" resolved;
  Alcotest.(check (float 0.0001))
    "prefixed alias fallback counter +1"
    (before +. 1.0)
    (alias_counter_for ~keeper ~alias:"auto" ~source:"telemetry_canonical")

let () =
  Alcotest.run "response_model_empty_10083"
    [
      ( "fallback_tiers",
        [
          Alcotest.test_case "raw non-empty verbatim" `Quick
            test_non_empty_raw_is_returned_verbatim;
          Alcotest.test_case "empty raw -> telemetry canonical" `Quick
            test_empty_raw_falls_back_to_telemetry;
          Alcotest.test_case "empty everywhere -> sentinel" `Quick
            test_empty_everywhere_uses_sentinel;
          Alcotest.test_case "empty canonical_model_id falls through" `Quick
            test_empty_canonical_id_falls_through_to_sentinel;
          Alcotest.test_case "raw auto -> telemetry canonical" `Quick
            test_auto_raw_falls_back_to_canonical_model_id;
          Alcotest.test_case "provider-prefixed auto -> telemetry canonical"
            `Quick
            test_provider_prefixed_auto_falls_back_to_canonical_model_id;
        ] );
    ]

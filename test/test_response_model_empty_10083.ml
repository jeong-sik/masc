(* test/test_response_model_empty_10083.ml

   #10083: pin the keeper-facing response.model normalization contract.
   OAS owns concrete provider/model identity; MASC keeps only the neutral
   runtime lane while still counting transport quality issues.

   The resolver returns ["runtime"] for every path and counts every
   recovery/selector shape so operators can see missing or aliased OAS output
   without MASC reconstructing canonical model IDs:

     raw non-empty            -> runtime, no missing-model counter
     raw empty + telemetry    -> runtime, source="telemetry_resolved"
     raw empty + no telemetry -> runtime, source="unknown_sentinel"
     raw selector alias       -> runtime, alias="runtime"

   The test asserts that concrete raw/canonical labels never become the
   returned keeper-facing model string or metric alias label. *)

module Hooks = Masc_mcp.Keeper_hooks_oas
module Prom = Masc_mcp.Prometheus

let runtime_lane = "runtime"
let metric_name = Prom.metric_after_turn_response_model_empty
let alias_metric_name = Prom.metric_after_turn_response_model_alias

let counter_for ~keeper ~source =
  Prom.metric_value_or_zero metric_name
    ~labels:[ "keeper", keeper; "source", source ]
    ()
;;

let alias_counter_for ~keeper ~alias ~source =
  Prom.metric_value_or_zero alias_metric_name
    ~labels:[ "keeper", keeper; "alias", alias; "source", source ]
    ()
;;

let make_zero_usage : Agent_sdk.Types.api_usage =
  { input_tokens = 0
  ; output_tokens = 0
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

let make_response ?(model = "") ?telemetry () : Agent_sdk.Types.api_response =
  { id = "msg-test-10083"
  ; model
  ; stop_reason = EndTurn
  ; content = []
  ; usage = Some make_zero_usage
  ; telemetry
  }
;;

let make_telemetry ?canonical_model_id () : Agent_sdk.Types.inference_telemetry =
  { system_fingerprint = None
  ; timings = None
  ; reasoning_tokens = None
  ; reasoning_tokens_estimated = false
  ; request_latency_ms = Some 0
  ; peak_memory_gb = None
  ; provider_kind = None
  ; reasoning_effort = None
  ; canonical_model_id
  ; effective_context_window = None
  ; provider_internal_action_count = None
  ; ttfrc_ms = None
  ; prefill_ms = None
  }
;;

let test_non_empty_raw_is_redacted () =
  let keeper = "test-keeper-raw-ok-10083" in
  let before_telemetry = counter_for ~keeper ~source:"telemetry_resolved" in
  let before_unknown = counter_for ~keeper ~source:"unknown_sentinel" in
  let response = make_response ~model:"oas-owned-model-id" () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "raw redacted to runtime lane" runtime_lane resolved;
  Alcotest.(check (float 0.0001))
    "telemetry_resolved counter unchanged"
    before_telemetry
    (counter_for ~keeper ~source:"telemetry_resolved");
  Alcotest.(check (float 0.0001))
    "unknown_sentinel counter unchanged"
    before_unknown
    (counter_for ~keeper ~source:"unknown_sentinel")
;;

let test_empty_raw_records_telemetry_presence () =
  let keeper = "test-keeper-telemetry-fallback-10083" in
  let before = counter_for ~keeper ~source:"telemetry_resolved" in
  let telemetry =
    make_telemetry ~canonical_model_id:"oas-owned-canonical-id" ()
  in
  let response = make_response ~model:"" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "resolver returned runtime lane" runtime_lane resolved;
  Alcotest.(check (float 0.0001))
    "telemetry_resolved counter +1"
    (before +. 1.0)
    (counter_for ~keeper ~source:"telemetry_resolved")
;;

let test_empty_everywhere_records_unknown_source () =
  let keeper = "test-keeper-sentinel-10083" in
  let before = counter_for ~keeper ~source:"unknown_sentinel" in
  let response = make_response ~model:"" () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "runtime lane returned" runtime_lane resolved;
  Alcotest.(check (float 0.0001))
    "unknown_sentinel counter +1"
    (before +. 1.0)
    (counter_for ~keeper ~source:"unknown_sentinel")
;;

let test_empty_canonical_id_records_unknown_source () =
  let keeper = "test-keeper-empty-canonical-10083" in
  let before_sentinel = counter_for ~keeper ~source:"unknown_sentinel" in
  let before_telemetry = counter_for ~keeper ~source:"telemetry_resolved" in
  let telemetry = make_telemetry ~canonical_model_id:"" () in
  let response = make_response ~model:"" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "runtime lane returned" runtime_lane resolved;
  Alcotest.(check (float 0.0001))
    "unknown_sentinel counter +1"
    (before_sentinel +. 1.0)
    (counter_for ~keeper ~source:"unknown_sentinel");
  Alcotest.(check (float 0.0001))
    "telemetry_resolved counter unchanged"
    before_telemetry
    (counter_for ~keeper ~source:"telemetry_resolved")
;;

let test_auto_raw_records_redacted_alias () =
  let keeper = "test-keeper-auto-canonical-10318" in
  let before =
    alias_counter_for ~keeper ~alias:runtime_lane ~source:"telemetry_canonical"
  in
  let telemetry =
    make_telemetry ~canonical_model_id:"oas-owned-canonical-id" ()
  in
  let response = make_response ~model:"auto" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "auto redacted to runtime lane" runtime_lane resolved;
  Alcotest.(check (float 0.0001))
    "alias fallback counter +1"
    (before +. 1.0)
    (alias_counter_for ~keeper ~alias:runtime_lane ~source:"telemetry_canonical")
;;

let test_prefixed_auto_records_redacted_alias () =
  let keeper = "test-keeper-prefixed-auto-canonical-10318" in
  let before =
    alias_counter_for ~keeper ~alias:runtime_lane ~source:"telemetry_canonical"
  in
  let telemetry =
    make_telemetry ~canonical_model_id:"oas-owned-canonical-id" ()
  in
  let response = make_response ~model:"opaque_runtime:auto" ~telemetry () in
  let resolved = Hooks.resolve_after_turn_model ~keeper_name:keeper ~response in
  Alcotest.(check string) "prefixed auto redacted" runtime_lane resolved;
  Alcotest.(check (float 0.0001))
    "prefixed alias fallback counter +1"
    (before +. 1.0)
    (alias_counter_for ~keeper ~alias:runtime_lane ~source:"telemetry_canonical")
;;

let () =
  Alcotest.run
    "response_model_empty_10083"
    [ ( "runtime_lane"
      , [ Alcotest.test_case
            "raw non-empty redacted"
            `Quick
            test_non_empty_raw_is_redacted
        ; Alcotest.test_case
            "empty raw -> telemetry presence"
            `Quick
            test_empty_raw_records_telemetry_presence
        ; Alcotest.test_case
            "empty everywhere -> unknown source"
            `Quick
            test_empty_everywhere_records_unknown_source
        ; Alcotest.test_case
            "empty canonical_model_id records unknown source"
            `Quick
            test_empty_canonical_id_records_unknown_source
        ; Alcotest.test_case
            "raw auto -> redacted alias"
            `Quick
            test_auto_raw_records_redacted_alias
        ; Alcotest.test_case
            "prefixed auto -> redacted alias"
            `Quick
            test_prefixed_auto_records_redacted_alias
        ] )
    ]
;;

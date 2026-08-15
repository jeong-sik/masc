(** Usage validity is observational: provider counters and cost are retained.

    Before this decoupling, an invalid *token count* (e.g. a negative provider
    counter) forced the accounted [cost_usd] to 0.0 and the
    source label to an invalid-usage bucket, even when the provider reported a positive
    authoritative cost. That coupling could silently drop a provider observation
    from the primary ledger fields.

    These tests pin the decoupled contract on the assembled cost-ledger payload:

    - untrusted token usage + positive cost_usd => the positive cost is accounted
      ([cost_usd] field), [cost_status="reported"], [cost_usd_source="computed"],
      WHILE [usage_trust="untrusted"] is still surfaced (token-trust visibility
      preserved — only the COST coupling was removed).
    - invalid negative counters remain in the primary fields and carry anomaly
      provenance; they are not replaced with zero/null.
    - zero and arbitrarily large counters remain ordinary reported values. *)

open Alcotest

module H = Masc.Keeper_hooks_agent_core
module Trust = Keeper_usage_trust

let string_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | Some other -> Alcotest.failf "%s not a string: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let float_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Float f) -> f
      | Some (`Int i) -> float_of_int i
      | Some other -> Alcotest.failf "%s not a number: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let int_field payload key =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int n) -> n
      | Some other -> Alcotest.failf "%s not an int: %s" key (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let check_null_field payload key =
  match payload with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some `Null -> ()
     | Some other ->
       Alcotest.failf "%s not null: %s" key (Yojson.Safe.to_string other)
     | None -> Alcotest.failf "%s absent from payload" key)
  | _ -> Alcotest.fail "payload not an object"

let check_absent_field payload key =
  match payload with
  | `Assoc fields ->
    check bool (key ^ " absent") true (Option.is_none (List.assoc_opt key fields))
  | _ -> Alcotest.fail "payload not an object"
;;

(* Objective invalid-token signal used to prove cost remains independent. *)
let invalid_tokens : Trust.t =
  Trust.Usage_untrusted [ "negative_input_tokens" ]

let payload
    ?(input_tokens = 0)
    ?(output_tokens = 0)
    ?(cache_creation_input_tokens = 0)
    ?(cache_read_input_tokens = 0)
    ?(usage_missing = false)
    ~cost_usd
    ~usage_trust
    () =
  H.cost_event_payload
    ~agent_name:"test_agent"
    ~task_id:None
    ~trace_id:"test-trace"
    ~keeper_turn_id:1
    ~agent_core_turn_ordinal:0
    ~model:"test-model"
    ~input_tokens
    ~output_tokens
    ~cost_usd
    ~cache_creation_input_tokens
    ~cache_read_input_tokens
    ~usage_missing
    ~usage_trust
    ()

(* --- the decoupling: untrusted tokens must not drop a real reported cost --- *)

let test_untrusted_tokens_positive_cost_is_accounted () =
  let p =
    payload ~input_tokens:(-1) ~cost_usd:0.0123 ~usage_trust:invalid_tokens ()
  in
  check (float 1e-9) "positive cost_usd is accounted, not masked to 0.0" 0.0123
    (float_field p "cost_usd");
  check string "cost_status reflects the reported cost" "reported"
    (string_field p "cost_status");
  check string "cost_usd_source labels the accounted cost as computed" "computed"
    (string_field p "cost_usd_source")

let test_untrusted_tokens_still_surface_trust () =
  (* Token-trust visibility is preserved: decoupling cost does NOT silence the
     usage_trust signal that operators alert on. *)
  let p =
    payload ~input_tokens:(-1) ~cost_usd:0.0123 ~usage_trust:invalid_tokens ()
  in
  check string "usage_trust still surfaces untrusted" "untrusted"
    (string_field p "usage_trust")

(* --- invalid counters do not influence cost-source attribution --- *)

let test_untrusted_tokens_zero_cost_stays_zero () =
  let p =
    payload ~input_tokens:(-1) ~cost_usd:0.0 ~usage_trust:invalid_tokens ()
  in
  check (float 1e-9) "zero cost stays 0.0" 0.0 (float_field p "cost_usd");
  check string "cost source is independent of token validity"
    "agent_core_cost_unreported" (string_field p "cost_usd_source");
  check string "usage_trust still untrusted" "untrusted"
    (string_field p "usage_trust");
  check int "negative input remains visible" (-1) (int_field p "input_tokens")

let test_trusted_tokens_positive_cost_unchanged () =
  (* Regression guard: the always-trusted path is unaffected. *)
  let p =
    H.cost_event_payload ~agent_name:"test_agent" ~task_id:None
      ~trace_id:"test-trace" ~keeper_turn_id:1 ~agent_core_turn_ordinal:0
      ~model:"test-model"
      ~input_tokens:100 ~output_tokens:50 ~cost_usd:0.0042
      ~usage_trust:Trust.Usage_trusted ()
  in
  check (float 1e-9) "trusted positive cost accounted" 0.0042
    (float_field p "cost_usd");
  check string "trusted positive cost => computed" "computed"
    (string_field p "cost_usd_source");
  check string "trusted positive cost => reported" "reported"
    (string_field p "cost_status");
  check int "zero-based AGENT_CORE ordinal is retained" 0
    (int_field p "agent_core_turn_ordinal")

let test_trusted_tokens_include_cache_delta () =
  let p =
    payload
      ~input_tokens:100
      ~output_tokens:50
      ~cache_creation_input_tokens:10
      ~cache_read_input_tokens:20
      ~cost_usd:0.0042
      ~usage_trust:Trust.Usage_trusted
      ()
  in
  check int "cache creation tokens are recorded" 10
    (int_field p "cache_creation_tokens");
  check int "cache read tokens are recorded" 20
    (int_field p "cache_read_tokens");
  check int "cache miss is derived from input minus read/write cache tokens" 70
    (int_field p "cache_miss_input_tokens")

let test_invalid_tokens_retain_cache_delta () =
  let p =
    payload
      ~input_tokens:(-1)
      ~output_tokens:50
      ~cache_creation_input_tokens:10
      ~cache_read_input_tokens:20
      ~cost_usd:0.0
      ~usage_trust:invalid_tokens
      ()
  in
  check int "cache creation remains visible" 10
    (int_field p "cache_creation_tokens");
  check int "cache read remains visible" 20
    (int_field p "cache_read_tokens");
  check int "negative cache delta is not clamped" (-31)
    (int_field p "cache_miss_input_tokens")

let test_zero_and_large_counts_are_retained () =
  let zero =
    payload ~input_tokens:0 ~output_tokens:0 ~cost_usd:0.0
      ~usage_trust:Trust.Usage_trusted ()
  in
  check int "zero input retained" 0 (int_field zero "input_tokens");
  check int "zero output retained" 0 (int_field zero "output_tokens");
  let large =
    payload ~input_tokens:2_000_000 ~output_tokens:3_000_000 ~cost_usd:0.0
      ~usage_trust:Trust.Usage_trusted ()
  in
  check int "large input retained" 2_000_000 (int_field large "input_tokens");
  check int "large output retained" 3_000_000 (int_field large "output_tokens")

let test_missing_usage_is_explicit_null () =
  let missing =
    payload ~input_tokens:123 ~output_tokens:456 ~cost_usd:7.89
      ~usage_missing:true ~usage_trust:Trust.Usage_missing ()
  in
  check_null_field missing "input_tokens";
  check_null_field missing "output_tokens";
  check_null_field missing "cost_usd";
  check_null_field missing "cache_creation_tokens";
  check_null_field missing "cache_read_tokens"

let test_native_decode_rate_uses_current_field_only () =
  let timings : Agent_core.Types.inference_timings =
    { prompt_n = None
    ; prompt_ms = None
    ; prompt_per_second = None
    ; predicted_n = Some 5
    ; predicted_ms = Some 100.0
    ; predicted_per_second = Some 50.0
    ; cache_n = None
    }
  in
  let telemetry : Agent_core.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = Some timings
    ; reasoning_tokens = None
    ; request_latency_ms = None
    ; peak_memory_gb = None
    ; provider_kind = None
    ; reasoning_effort = None
    ; canonical_model_id = None
    ; reasoning_source = None
    ; effective_context_window = None
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  let payload =
    H.cost_event_payload
      ~agent_name:"test_agent"
      ~task_id:None
      ~trace_id:"test-trace"
      ~keeper_turn_id:1
      ~agent_core_turn_ordinal:0
      ~model:"test-model"
      ~input_tokens:10
      ~output_tokens:5
      ~cost_usd:0.0
      ~telemetry
      ()
  in
  check
    (float 1e-9)
    "current hardware decode field"
    50.0
    (float_field payload "hw_decode_tokens_per_second");
  check_absent_field payload "provider_tokens_per_second"
;;

(* RFC-0382: llama-server/Ollama wire timings carry [cache_n] (KV-cache
   reused prompt tokens) and [prompt_n] (freshly prefilled prompt tokens).
   Both must land on the cost-ledger payload so the per-turn KV reuse ratio
   is reconstructible from the ledger alone. *)
let test_timings_cache_fields_land_on_payload () =
  let timings : Agent_core.Types.inference_timings =
    { prompt_n = Some 26
    ; prompt_ms = Some 709.5
    ; prompt_per_second = Some 36.6
    ; predicted_n = Some 512
    ; predicted_ms = Some 54893.4
    ; predicted_per_second = Some 9.3
    ; cache_n = Some 1741
    }
  in
  let telemetry : Agent_core.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = Some timings
    ; reasoning_tokens = None
    ; request_latency_ms = None
    ; peak_memory_gb = None
    ; provider_kind = None
    ; reasoning_effort = None
    ; canonical_model_id = None
    ; reasoning_source = None
    ; effective_context_window = None
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  let payload =
    H.cost_event_payload
      ~agent_name:"test_agent"
      ~task_id:None
      ~trace_id:"test-trace"
      ~keeper_turn_id:1
      ~agent_core_turn_ordinal:0
      ~model:"qwen3.8-27b"
      ~input_tokens:26
      ~output_tokens:512
      ~cost_usd:0.0
      ~telemetry
      ()
  in
  check int "cache_n" 1741 (int_field payload "cache_n");
  check int "prompt_n" 26 (int_field payload "prompt_n")
;;

let () =
  run "cost_token_decouple"
    [
      ( "decouple",
        [
          test_case "untrusted tokens + positive cost is accounted" `Quick
            test_untrusted_tokens_positive_cost_is_accounted;
          test_case "untrusted tokens still surface usage_trust" `Quick
            test_untrusted_tokens_still_surface_trust;
        ] );
      ( "no-op-leg",
        [
          test_case "untrusted tokens + zero cost stays 0.0/untrusted" `Quick
            test_untrusted_tokens_zero_cost_stays_zero;
          test_case "trusted tokens + positive cost unchanged" `Quick
            test_trusted_tokens_positive_cost_unchanged;
        ] );
      ( "cache-delta",
        [
          test_case "trusted tokens include cache delta" `Quick
            test_trusted_tokens_include_cache_delta;
          test_case "invalid tokens retain cache delta" `Quick
            test_invalid_tokens_retain_cache_delta;
          test_case "zero and large counts are retained" `Quick
            test_zero_and_large_counts_are_retained;
          test_case "missing usage is explicit null" `Quick
            test_missing_usage_is_explicit_null;
          test_case "native decode rate uses current field only" `Quick
            test_native_decode_rate_uses_current_field_only;
          test_case "timings cache_n/prompt_n land on payload" `Quick
            test_timings_cache_fields_land_on_payload;
        ] );
    ]

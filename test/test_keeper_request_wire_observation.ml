(** The admitted request-body size is recorded per keeper.

    These tests pin that the observer records the exact [body_bytes] AGENT_CORE
    reports after provider-specific serialization, attributes it to the right
    keeper, runtime and admitted cap, emits byte-scale histogram buckets, and
    admits every observation — a rejection would turn measurement into typed
    failure evidence on the provider path. Typed body-size refusals are
    projected separately at the provider-attempt result boundary. *)

open Alcotest

module Observation = Masc.Keeper_request_wire_observation
module Wire = Llm_provider.Request_wire_observer

let observation ~body_bytes : Wire.observation =
  { phase = Wire.Pre_dispatch_serialization
  ; capture_id = None
  ; provider = "ollama_cloud"
  ; model = "deepseek-v4-flash"
  ; http_codec = "openai_compat"
  ; stream = true
  ; body_bytes
  ; body_sha256 = String.make 64 '0'
  }
;;

let metric_name = Keeper_metrics.to_string Observation.metric

type metric_series =
  { keeper_name : string
  ; runtime_id : string
  ; max_request_body_bytes : int
  }

let observe series body_bytes =
  Observation.observer
    ~keeper_name:series.keeper_name
    ~runtime_id:series.runtime_id
    ~max_request_body_bytes:series.max_request_body_bytes
    (observation ~body_bytes)
;;

(* [observe_histogram] accumulates the observed sum under the bare metric key
   and the observation count under [name ^ "_count"]. *)
let labels series =
  [ "keeper", series.keeper_name
  ; "runtime_id", series.runtime_id
  ; "max_request_body_bytes", string_of_int series.max_request_body_bytes
  ]
;;

let recorded series =
  Otel_metric_store_core.metric_value_or_zero
    metric_name
    ~labels:(labels series)
    ()
;;

let observation_count series =
  Otel_metric_store_core.metric_value_or_zero
    (metric_name ^ "_count")
    ~labels:(labels series)
    ()
;;

let test_records_admitted_bytes_for_the_keeper () =
  let series =
    { keeper_name = "wire-observation-alpha"
    ; runtime_id = "wire-runtime-alpha"
    ; max_request_body_bytes = 2_097_152
    }
  in
  let before = recorded series in
  check
    (result unit reject)
    "the observation is admitted"
    (Ok ())
    (observe series 524_288);
  check
    (float 0.5)
    "the exact admitted byte count is recorded"
    (before +. 524_288.)
    (recorded series);
  check
    (result unit reject)
    "a second observation is also admitted"
    (Ok ())
    (observe series 1_730_708);
  check
    (float 0.5)
    "observations accumulate"
    (before +. 524_288. +. 1_730_708.)
    (recorded series);
  check
    (float 0.5)
    "both observations are counted"
    2.
    (observation_count series)
;;

let test_attributes_bytes_to_the_observing_keeper () =
  let alpha =
    { keeper_name = "wire-observation-attribution-alpha"
    ; runtime_id = "wire-runtime-attribution"
    ; max_request_body_bytes = 524_288
    }
  in
  let beta =
    { alpha with keeper_name = "wire-observation-attribution-beta" }
  in
  let beta_before = recorded beta in
  ignore (observe alpha 262_144);
  check
    (float 0.5)
    "another keeper's histogram is untouched"
    beta_before
    (recorded beta)
;;

let test_separates_runtimes_for_the_same_keeper () =
  let alpha =
    { keeper_name = "wire-observation-runtime-attribution"
    ; runtime_id = "wire-runtime-attribution-alpha"
    ; max_request_body_bytes = 524_288
    }
  in
  let beta = { alpha with runtime_id = "wire-runtime-attribution-beta" } in
  let alpha_before = recorded alpha in
  let beta_before = recorded beta in
  ignore (observe alpha 262_144);
  check
    (float 0.5)
    "the observing runtime receives the exact byte count"
    (alpha_before +. 262_144.)
    (recorded alpha);
  check
    (float 0.5)
    "another runtime's histogram is untouched"
    beta_before
    (recorded beta)
;;

let test_separates_changed_caps_for_the_same_runtime () =
  let old_cap =
    { keeper_name = "wire-observation-cap-attribution"
    ; runtime_id = "wire-runtime-cap-attribution"
    ; max_request_body_bytes = 262_144
    }
  in
  let new_cap = { old_cap with max_request_body_bytes = 524_288 } in
  let old_before = recorded old_cap in
  let new_before = recorded new_cap in
  ignore (observe old_cap 131_072);
  check
    (float 0.5)
    "a different cap series stays untouched"
    new_before
    (recorded new_cap);
  ignore (observe new_cap 262_144);
  check
    (float 0.5)
    "the previous cap series retains only its own sample"
    (old_before +. 131_072.)
    (recorded old_cap)
;;

let test_records_byte_scale_histogram_buckets () =
  let series =
    { keeper_name = "wire-observation-buckets"
    ; runtime_id = "wire-runtime-buckets"
    ; max_request_body_bytes = 2_097_152
    }
  in
  let bucket le =
    Otel_metric_store_core.metric_value_or_zero
      (metric_name ^ "_bucket")
      ~labels:(("le", le) :: labels series)
      ()
  in
  let before_524288 = bucket "524288" in
  let before_1048576 = bucket "1048576" in
  let before_rounded_1048576 = bucket "1.04858e+06" in
  let before_inf = bucket "+Inf" in
  ignore (observe series 1_048_576);
  check
    (float 0.5)
    "smaller bucket excludes observation"
    before_524288
    (bucket "524288");
  check
    (float 0.5)
    "exact MiB bucket includes observation"
    (before_1048576 +. 1.)
    (bucket "1048576");
  check
    (float 0.5)
    "rounded MiB label is not emitted"
    before_rounded_1048576
    (bucket "1.04858e+06");
  check
    (float 0.5)
    "+Inf bucket includes observation"
    (before_inf +. 1.)
    (bucket "+Inf")
;;

let test_admits_a_zero_byte_observation () =
  (* AGENT_CORE owns admission; a measurement path must not invent a rejection for an
     unusual-looking value. *)
  let series =
    { keeper_name = "wire-observation-zero"
    ; runtime_id = "wire-runtime-zero"
    ; max_request_body_bytes = 262_144
    }
  in
  check
    (result unit reject)
    "a zero-byte observation is still admitted"
    (Ok ())
    (observe series 0)
;;

let test_forwards_exact_observation () =
  let observed = ref None in
  let observation_result =
    Observation.observer
      ~on_observation:(fun ~runtime_id ~body_bytes ->
        observed := Some (runtime_id, body_bytes))
      ~keeper_name:"wire-observation-callback"
      ~runtime_id:"wire-runtime-callback"
      ~max_request_body_bytes:524_288
      (observation ~body_bytes:333_777)
  in
  check
    (result unit reject)
    "callback observation admitted"
    (Ok ())
    observation_result;
  check
    (option (pair string int))
    "callback receives exact runtime and pre-dispatch bytes"
    (Some ("wire-runtime-callback", 333_777))
    !observed
;;

let test_metric_name_is_stable () =
  check
    string
    "dashboards and alerts key off this name"
    "masc_keeper_runtime_request_wire_bytes"
    metric_name
;;

let () =
  run
    "keeper request wire observation"
    [ ( "admitted bytes"
      , [ test_case
            "records the admitted byte count"
            `Quick
            test_records_admitted_bytes_for_the_keeper
        ; test_case
            "attributes bytes to the observing keeper"
            `Quick
            test_attributes_bytes_to_the_observing_keeper
        ; test_case
            "separates runtimes for the same keeper"
            `Quick
            test_separates_runtimes_for_the_same_keeper
        ; test_case
            "separates changed caps for the same runtime"
            `Quick
            test_separates_changed_caps_for_the_same_runtime
        ; test_case
            "records byte-scale histogram buckets"
            `Quick
            test_records_byte_scale_histogram_buckets
        ; test_case
            "admits a zero-byte observation"
            `Quick
            test_admits_a_zero_byte_observation
        ; test_case
            "forwards exact observation"
            `Quick
            test_forwards_exact_observation
        ; test_case "metric name is stable" `Quick test_metric_name_is_stable
        ] )
    ]
;;

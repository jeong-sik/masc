(** The admitted request-body size is recorded per keeper.

    Only a refused request reports its size today, so nothing could compare a
    keeper's real serialized wire size against its runtime's
    [max_request_body_bytes]. These tests pin that the observer records the
    exact [body_bytes] OAS reports, attributes it to the right keeper, and
    admits every observation — a rejection would turn measurement into typed
    failure evidence on the provider path. *)

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

(* [observe_histogram] accumulates the observed sum under the bare metric key
   and the observation count under [name ^ "_count"]. *)
let recorded ~keeper_name =
  Otel_metric_store_core.metric_value_or_zero
    metric_name
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let observation_count ~keeper_name =
  Otel_metric_store_core.metric_value_or_zero
    (metric_name ^ "_count")
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let test_records_admitted_bytes_for_the_keeper () =
  let keeper_name = "wire-observation-alpha" in
  let before = recorded ~keeper_name in
  check
    (result unit reject)
    "the observation is admitted"
    (Ok ())
    (Observation.observer ~keeper_name (observation ~body_bytes:524_288));
  check
    (float 0.5)
    "the exact admitted byte count is recorded"
    (before +. 524_288.)
    (recorded ~keeper_name);
  check
    (result unit reject)
    "a second observation is also admitted"
    (Ok ())
    (Observation.observer ~keeper_name (observation ~body_bytes:1_730_708));
  check
    (float 0.5)
    "observations accumulate"
    (before +. 524_288. +. 1_730_708.)
    (recorded ~keeper_name);
  check
    (float 0.5)
    "both observations are counted"
    2.
    (observation_count ~keeper_name)
;;

let test_attributes_bytes_to_the_observing_keeper () =
  let alpha = "wire-observation-attribution-alpha" in
  let beta = "wire-observation-attribution-beta" in
  let beta_before = recorded ~keeper_name:beta in
  ignore (Observation.observer ~keeper_name:alpha (observation ~body_bytes:262_144));
  check
    (float 0.5)
    "another keeper's histogram is untouched"
    beta_before
    (recorded ~keeper_name:beta)
;;

let test_admits_a_zero_byte_observation () =
  (* OAS owns admission; a measurement path must not invent a rejection for an
     unusual-looking value. *)
  check
    (result unit reject)
    "a zero-byte observation is still admitted"
    (Ok ())
    (Observation.observer
       ~keeper_name:"wire-observation-zero"
       (observation ~body_bytes:0))
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
            "admits a zero-byte observation"
            `Quick
            test_admits_a_zero_byte_observation
        ; test_case "metric name is stable" `Quick test_metric_name_is_stable
        ] )
    ]
;;

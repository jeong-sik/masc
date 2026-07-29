(** The admitted request-body size is recorded per keeper.

    Only a refused request reports its size today, so nothing could compare a
    keeper's real serialized wire size against its runtime's
    [max_request_body_bytes]. These tests pin that the observer records the
    exact [body_bytes] OAS reports, attributes it to the right keeper and
    runtime, emits byte-scale histogram buckets, and admits every observation
    — a rejection would turn measurement into typed failure evidence on the
    provider path. *)

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

let observe ~keeper_name ~runtime_id body_bytes =
  Observation.observer ~keeper_name ~runtime_id (observation ~body_bytes)
;;

(* [observe_histogram] accumulates the observed sum under the bare metric key
   and the observation count under [name ^ "_count"]. *)
let labels ~keeper_name ~runtime_id =
  [ "keeper", keeper_name; "runtime_id", runtime_id ]
;;

let recorded ~keeper_name ~runtime_id =
  Otel_metric_store_core.metric_value_or_zero
    metric_name
    ~labels:(labels ~keeper_name ~runtime_id)
    ()
;;

let observation_count ~keeper_name ~runtime_id =
  Otel_metric_store_core.metric_value_or_zero
    (metric_name ^ "_count")
    ~labels:(labels ~keeper_name ~runtime_id)
    ()
;;

let test_records_admitted_bytes_for_the_keeper () =
  let keeper_name = "wire-observation-alpha" in
  let runtime_id = "wire-runtime-alpha" in
  let before = recorded ~keeper_name ~runtime_id in
  check
    (result unit reject)
    "the observation is admitted"
    (Ok ())
    (observe ~keeper_name ~runtime_id 524_288);
  check
    (float 0.5)
    "the exact admitted byte count is recorded"
    (before +. 524_288.)
    (recorded ~keeper_name ~runtime_id);
  check
    (result unit reject)
    "a second observation is also admitted"
    (Ok ())
    (observe ~keeper_name ~runtime_id 1_730_708);
  check
    (float 0.5)
    "observations accumulate"
    (before +. 524_288. +. 1_730_708.)
    (recorded ~keeper_name ~runtime_id);
  check
    (float 0.5)
    "both observations are counted"
    2.
    (observation_count ~keeper_name ~runtime_id)
;;

let test_attributes_bytes_to_the_observing_keeper () =
  let alpha = "wire-observation-attribution-alpha" in
  let beta = "wire-observation-attribution-beta" in
  let runtime_id = "wire-runtime-attribution" in
  let beta_before = recorded ~keeper_name:beta ~runtime_id in
  ignore (observe ~keeper_name:alpha ~runtime_id 262_144);
  check
    (float 0.5)
    "another keeper's histogram is untouched"
    beta_before
    (recorded ~keeper_name:beta ~runtime_id)
;;

let test_separates_runtimes_for_the_same_keeper () =
  let keeper_name = "wire-observation-runtime-attribution" in
  let alpha = "wire-runtime-attribution-alpha" in
  let beta = "wire-runtime-attribution-beta" in
  let alpha_before = recorded ~keeper_name ~runtime_id:alpha in
  let beta_before = recorded ~keeper_name ~runtime_id:beta in
  ignore (observe ~keeper_name ~runtime_id:alpha 262_144);
  check
    (float 0.5)
    "the observing runtime receives the exact byte count"
    (alpha_before +. 262_144.)
    (recorded ~keeper_name ~runtime_id:alpha);
  check
    (float 0.5)
    "another runtime's histogram is untouched"
    beta_before
    (recorded ~keeper_name ~runtime_id:beta)
;;

let test_records_byte_scale_histogram_buckets () =
  let keeper_name = "wire-observation-buckets" in
  let runtime_id = "wire-runtime-buckets" in
  let bucket le =
    Otel_metric_store_core.metric_value_or_zero
      (metric_name ^ "_bucket")
      ~labels:(("le", le) :: labels ~keeper_name ~runtime_id)
      ()
  in
  let before_131072 = bucket "131072" in
  let before_262144 = bucket "262144" in
  let before_inf = bucket "+Inf" in
  ignore (observe ~keeper_name ~runtime_id 262_144);
  check
    (float 0.5)
    "smaller bucket excludes observation"
    before_131072
    (bucket "131072");
  check
    (float 0.5)
    "matching cap bucket includes observation"
    (before_262144 +. 1.)
    (bucket "262144");
  check
    (float 0.5)
    "+Inf bucket includes observation"
    (before_inf +. 1.)
    (bucket "+Inf")
;;

let test_admits_a_zero_byte_observation () =
  (* OAS owns admission; a measurement path must not invent a rejection for an
     unusual-looking value. *)
  check
    (result unit reject)
    "a zero-byte observation is still admitted"
    (Ok ())
    (observe
       ~keeper_name:"wire-observation-zero"
       ~runtime_id:"wire-runtime-zero"
       0)
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
            "records byte-scale histogram buckets"
            `Quick
            test_records_byte_scale_histogram_buckets
        ; test_case
            "admits a zero-byte observation"
            `Quick
            test_admits_a_zero_byte_observation
        ; test_case "metric name is stable" `Quick test_metric_name_is_stable
        ] )
    ]
;;

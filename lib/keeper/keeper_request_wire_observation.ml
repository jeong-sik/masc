let metric = Keeper_metrics.RuntimeRequestWireBytes

(* Powers-of-two byte-scale measurement buckets. These are histogram schema,
   not admission thresholds: AGENT_CORE and each runtime's provider configuration
   remain the only request-size authorities. The finite bounds cover the
   current 64 KiB, 256 KiB and 1 MiB declared-cap fixtures exactly and retain
   useful resolution through 8 MiB; the metric store adds +Inf. *)
let bucket_upper_bounds_bytes =
  [ 65_536.
  ; 131_072.
  ; 262_144.
  ; 524_288.
  ; 1_048_576.
  ; 2_097_152.
  ; 4_194_304.
  ; 8_388_608.
  ]
;;

let () =
  Otel_metric_store.register_histogram_buckets
    (Keeper_metrics.to_string metric)
    bucket_upper_bounds_bytes
;;

let record ~keeper_name ~runtime_id ~max_request_body_bytes ~body_bytes =
  Otel_metric_store.observe_histogram
    (Keeper_metrics.to_string metric)
    ~labels:
      [ "keeper", keeper_name
      ; "runtime_id", runtime_id
      ; "max_request_body_bytes", string_of_int max_request_body_bytes
      ]
    (Float.of_int body_bytes)
;;

let observer ?on_observation ~keeper_name ~runtime_id ~max_request_body_bytes
  : Agent_core.Agent.pre_dispatch_serialization_observer
  =
  fun observation ->
  let body_bytes = observation.Llm_provider.Request_wire_observer.body_bytes in
  Option.iter (fun observe -> observe ~runtime_id ~body_bytes) on_observation;
  record ~keeper_name ~runtime_id ~max_request_body_bytes ~body_bytes;
  Ok ()
;;

let metric = Keeper_metrics.RuntimeRequestWireBytes

let observer ~keeper_name
  : Agent_sdk.Agent.pre_dispatch_serialization_observer
  =
  fun observation ->
  Otel_metric_store.observe_histogram
    (Keeper_metrics.to_string metric)
    ~labels:[ "keeper", keeper_name ]
    (Float.of_int observation.Llm_provider.Request_wire_observer.body_bytes);
  Ok ()
;;

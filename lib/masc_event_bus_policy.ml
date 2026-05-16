type backpressure_policy = Agent_sdk.Event_bus.backpressure_policy =
  | Block
  | Drop_oldest
  | Drop_newest

type t = {
  bus_name : string;
  buffer_size : int;
  policy : backpressure_policy;
  rationale : string;
}

let to_policy_label = function
  | Block -> "block"
  | Drop_oldest -> "drop_oldest"
  | Drop_newest -> "drop_newest"
;;

let oas_runtime =
  {
    bus_name = "oas_runtime";
    buffer_size = 256;
    policy = Block;
    rationale =
      "Block + 256 buffer: turn-pipeline events must not be dropped; \
       slow subscriber back-pressures publishers so the keeper hold \
       state surfaces as observable back-pressure rather than silent \
       loss.";
  }
;;

let masc_domain =
  {
    bus_name = "masc_domain";
    buffer_size = 256;
    policy = Block;
    rationale =
      "Block + 256 buffer: broadcast/heartbeat/keeper/autonomy/harness/ \
       trust events carry coordination invariants; dropping any would \
       silently break MASC's task hand-off semantics.";
  }
;;

let () =
  Prometheus.register_gauge
    ~name:Prometheus.metric_oas_bus_capacity
    ~help:
      "Configured [Eio.Stream] buffer size per subscriber on each MASC \
       event bus.  Labels: [bus] (oas_runtime | masc_domain | ...) and \
       [policy] (block | drop_oldest | drop_newest).  Read alongside \
       [masc_oas_bus_subscriber_stream_depth] to interpret depth as a \
       fraction of capacity."
    ()
;;

let create_bus (t : t) : Agent_sdk.Event_bus.t =
  let bus =
    Agent_sdk.Event_bus.create
      ~buffer_size:t.buffer_size
      ~policy:t.policy
      ()
  in
  Prometheus.set_gauge
    Prometheus.metric_oas_bus_capacity
    ~labels:
      [ ("bus", t.bus_name)
      ; ("policy", to_policy_label t.policy)
      ]
    (float_of_int t.buffer_size);
  bus
;;

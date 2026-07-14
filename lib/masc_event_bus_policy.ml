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
    policy = Drop_oldest;
    rationale =
      "Drop_oldest + 256 buffer: oas_runtime carries OBSERVATIONAL \
       turn-pipeline events (telemetry counter [Keeper_telemetry_consumer], \
       SSE dashboard relay [Keeper_event_bridge], metrics \
       [Agent_sdk_metrics_bridge]). \
       Durable turn/event replay reads the JSONL telemetry surface \
       (dashboard_oas_bridge.durable_replay_surface, \
       /api/v1/dashboard/telemetry?source=oas_event), NOT this live bus, so \
       no subscriber requires completeness. Under [Block] a slow subscriber \
       fills the 256 buffer and back-pressure freezes EVERY keeper publisher \
       inside Event_bus.publish with no timeout, suspending the whole fleet \
       until restart (RCA 2026-06-10: sustained multi-minute keeper freeze, \
       keepers wedged in turn-pipeline publish; not the HTTP/idle path). \
       Drop_oldest sheds the stalest observational event instead of freezing \
       the fleet; the durable surface retains the data. \
       masc_domain keeps Block (workspace-invariant events).";
  }
;;

let masc_domain =
  {
    bus_name = "masc_domain";
    buffer_size = 256;
    policy = Block;
    rationale =
      "Block + 256 buffer: broadcast/heartbeat/keeper/autonomy/harness/ \
       trust events carry workspace invariants; dropping any would \
       silently break MASC's task hand-off semantics.";
  }
;;

let () =
  Otel_metric_store.register_gauge
    ~name:Otel_metric_store.metric_oas_bus_capacity
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
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_oas_bus_capacity
    ~labels:
      [ ("bus", t.bus_name)
      ; ("policy", to_policy_label t.policy)
      ]
    (float_of_int t.buffer_size);
  bus
;;

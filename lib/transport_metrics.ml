(** Transport Observability Metrics for 50-agent monitoring.

    Collects SSE, gRPC, and agent-health transport metrics in
    Prometheus text format via the existing Prometheus module.

    Metric naming follows Prometheus conventions:
    - masc_sse_* for SSE transport
    - masc_grpc_* for gRPC transport
    - masc_agent_heartbeat_* for agent liveness *)

(** {1 SSE Metrics} *)

let register_sse_metrics () =
  Prometheus.register_gauge ~name:"masc_sse_sessions_total"
    ~help:"Active SSE sessions by kind" ();
  Prometheus.register_histogram ~name:"masc_sse_broadcast_duration_seconds"
    ~help:"Time to fan-out a broadcast to all SSE clients" ();
  Prometheus.register_counter ~name:"masc_sse_broadcast_events_total"
    ~help:"Total SSE broadcast events emitted" ();
  Prometheus.register_gauge ~name:"masc_sse_stream_queue_depth"
    ~help:"Per-session SSE event stream queue depth" ()

let set_sse_sessions ~kind count =
  Prometheus.set_gauge "masc_sse_sessions_total"
    ~labels:[("kind", kind)] (float_of_int count)

let observe_broadcast_duration seconds =
  Prometheus.observe_histogram "masc_sse_broadcast_duration_seconds" seconds;
  Prometheus.inc_counter "masc_sse_broadcast_events_total" ()

let set_sse_queue_depth ~session_id depth =
  Prometheus.set_gauge "masc_sse_stream_queue_depth"
    ~labels:[("session_id", session_id)] (float_of_int depth)

(** {1 gRPC Metrics} *)

let register_grpc_metrics () =
  Prometheus.register_gauge ~name:"masc_grpc_active_streams_total"
    ~help:"Active gRPC bidirectional streams" ();
  Prometheus.register_histogram ~name:"masc_grpc_heartbeat_latency_seconds"
    ~help:"gRPC heartbeat round-trip latency" ();
  Prometheus.register_gauge ~name:"masc_grpc_subscribers_total"
    ~help:"Active gRPC Subscribe stream subscribers" ();
  Prometheus.register_counter ~name:"masc_grpc_events_delivered_total"
    ~help:"Total events delivered via gRPC streams" ()

let set_grpc_active_streams count =
  Prometheus.set_gauge "masc_grpc_active_streams_total" (float_of_int count)

let observe_grpc_heartbeat_latency seconds =
  Prometheus.observe_histogram "masc_grpc_heartbeat_latency_seconds" seconds

let set_grpc_subscribers count =
  Prometheus.set_gauge "masc_grpc_subscribers_total" (float_of_int count)

let inc_grpc_events_delivered ?(delta=1) () =
  Prometheus.inc_counter "masc_grpc_events_delivered_total"
    ~delta:(float_of_int delta) ()

(** {1 Agent Health Metrics} *)

let register_agent_metrics () =
  Prometheus.register_gauge ~name:"masc_agent_heartbeat_age_seconds"
    ~help:"Seconds since last heartbeat per agent" ();
  Prometheus.register_counter ~name:"masc_agent_stale_total"
    ~help:"Total agents that became stale (heartbeat age exceeded threshold)" ()

let set_agent_heartbeat_age ~agent_name age_seconds =
  Prometheus.set_gauge "masc_agent_heartbeat_age_seconds"
    ~labels:[("agent_name", agent_name)] age_seconds

let inc_agent_stale () =
  Prometheus.inc_counter "masc_agent_stale_total" ()

(** {1 Initialization} *)

let init () =
  register_sse_metrics ();
  register_grpc_metrics ();
  register_agent_metrics ()

(** {1 Transport Health JSON Snapshot} *)

let transport_health_json () =
  let v name ?(labels=[]) () =
    Prometheus.metric_value_or_zero name ~labels ()
  in
  let sse_observer = v "masc_sse_sessions_total" ~labels:[("kind", "observer")] () in
  let sse_coordinator = v "masc_sse_sessions_total" ~labels:[("kind", "coordinator")] () in
  let sse_total = int_of_float (sse_observer +. sse_coordinator) in
  let broadcast_sum = v "masc_sse_broadcast_duration_seconds" () in
  let broadcast_count = v "masc_sse_broadcast_duration_seconds_count" () in
  let broadcast_avg =
    if broadcast_count > 0.0 then broadcast_sum /. broadcast_count else 0.0
  in
  let grpc_streams = v "masc_grpc_active_streams_total" () in
  let grpc_subscribers = v "masc_grpc_subscribers_total" () in
  let grpc_heartbeat_sum = v "masc_grpc_heartbeat_latency_seconds" () in
  let grpc_heartbeat_count = v "masc_grpc_heartbeat_latency_seconds_count" () in
  let grpc_heartbeat_avg =
    if grpc_heartbeat_count > 0.0 then grpc_heartbeat_sum /. grpc_heartbeat_count
    else 0.0
  in
  let grpc_events = v "masc_grpc_events_delivered_total" () in
  let stale_agents = v "masc_agent_stale_total" () in
  `Assoc [
    ("sse", `Assoc [
      ("sessions_observer", `Int (int_of_float sse_observer));
      ("sessions_coordinator", `Int (int_of_float sse_coordinator));
      ("sessions_total", `Int sse_total);
      ("broadcast_avg_seconds", `Float broadcast_avg);
      ("broadcast_count", `Int (int_of_float broadcast_count));
    ]);
    ("grpc", `Assoc [
      ("active_streams", `Int (int_of_float grpc_streams));
      ("subscribers", `Int (int_of_float grpc_subscribers));
      ("heartbeat_avg_seconds", `Float grpc_heartbeat_avg);
      ("events_delivered", `Int (int_of_float grpc_events));
    ]);
    ("agent_health", `Assoc [
      ("stale_total", `Int (int_of_float stale_agents));
    ]);
    ("generated_at", `String (Types.now_iso ()));
  ]

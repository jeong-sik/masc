(** OTel Chain Subscriber — maps Chain_telemetry events to OTel spans.

    Subscribes to {!Chain_telemetry.emit} and creates OTel spans that form
    a parent-child tree: chain span -> node spans.

    Spans are constructed retroactively when Complete/Error events arrive,
    using the recorded start_time from Start events.

    @since 2.160.0 *)

module OT = Opentelemetry

(** In-flight chain state: stored between ChainStart and ChainComplete. *)
type chain_in_flight = {
  trace_id : OT.Trace_id.t;
  span_id : OT.Span_id.t;
  start_ns : int64;
}

(** In-flight node state: stored between NodeStart and NodeComplete. *)
type node_in_flight = {
  chain_trace_id : OT.Trace_id.t;
  chain_span_id : OT.Span_id.t;
  node_span_id : OT.Span_id.t;
  node_start_ns : int64;
}

(** Active chains keyed by chain_id, and the most recently started chain
    for associating node events (which lack chain_id in the telemetry API). *)
let active_chains : (string, chain_in_flight) Hashtbl.t = Hashtbl.create 8
let active_nodes : (string, node_in_flight) Hashtbl.t = Hashtbl.create 32
let current_chain : chain_in_flight option ref = ref None
let mu = Eio.Mutex.create ()

let with_mu f = Eio_guard.with_mutex mu f

(** Convert Unix.gettimeofday (seconds) to nanoseconds int64. *)
let timestamp_to_ns (t : float) : int64 =
  Int64.of_float (t *. 1_000_000_000.0)

(** Handle a single chain telemetry event. *)
let on_event (event : Chain_telemetry.chain_event) =
  if not Otel_config.enabled then ()
  else match event with
  | ChainStart p ->
    let trace_id = OT.Trace_id.create () in
    let span_id = OT.Span_id.create () in
    let start_ns = timestamp_to_ns p.start_timestamp in
    let cf = { trace_id; span_id; start_ns } in
    with_mu (fun () ->
      Hashtbl.replace active_chains p.start_chain_id cf;
      current_chain := Some cf)

  | NodeStart p ->
    let now_ns = OT.Timestamp_ns.now_unix_ns () in
    let node_span_id = OT.Span_id.create () in
    with_mu (fun () ->
      (* Associate node with the current running chain.
         NodeStart events don't carry chain_id in the telemetry API,
         so we link to the most recently started chain (LIFO). *)
      let chain_ctx = !current_chain in
      let nf = match chain_ctx with
        | Some chain ->
          { chain_trace_id = chain.trace_id;
            chain_span_id = chain.span_id;
            node_span_id;
            node_start_ns = now_ns }
        | None ->
          (* Orphan node — no active chain. Create standalone trace. *)
          { chain_trace_id = OT.Trace_id.create ();
            chain_span_id = OT.Span_id.create ();
            node_span_id;
            node_start_ns = now_ns }
      in
      Hashtbl.replace active_nodes p.node_start_id nf)

  | NodeComplete p ->
    let end_ns = OT.Timestamp_ns.now_unix_ns () in
    let node_opt = with_mu (fun () ->
      let v = Hashtbl.find_opt active_nodes p.node_complete_id in
      Hashtbl.remove active_nodes p.node_complete_id;
      v) in
    (match node_opt with
     | None -> ()
     | Some nf ->
       let attrs : OT.Span.key_value list = [
         ("chain.node.id", `String p.node_complete_id);
         ("chain.node.duration_ms", `Int p.node_duration_ms);
         ("chain.node.tokens", `Int p.node_tokens.total_tokens);
         ("chain.node.confidence", `Float p.node_confidence);
       ] in
       let span, _id = OT.Span.create
         ~trace_id:nf.chain_trace_id
         ~parent:nf.chain_span_id
         ~id:nf.node_span_id
         ~start_time:nf.node_start_ns
         ~end_time:end_ns
         ~attrs
         ("chain.node/" ^ p.node_complete_id)
       in
       OT.Trace.emit [span])

  | ChainComplete p ->
    let end_ns = OT.Timestamp_ns.now_unix_ns () in
    let chain_opt = with_mu (fun () ->
      let v = Hashtbl.find_opt active_chains p.complete_chain_id in
      Hashtbl.remove active_chains p.complete_chain_id;
      current_chain := None;
      v) in
    (match chain_opt with
     | None -> ()
     | Some cf ->
       let attrs : OT.Span.key_value list = [
         ("chain.id", `String p.complete_chain_id);
         ("chain.duration_ms", `Int p.complete_duration_ms);
         ("chain.tokens", `Int p.complete_tokens.total_tokens);
         ("chain.nodes_executed", `Int p.nodes_executed);
         ("chain.nodes_skipped", `Int p.nodes_skipped);
       ] in
       let span, _id = OT.Span.create
         ~trace_id:cf.trace_id
         ~id:cf.span_id
         ~start_time:cf.start_ns
         ~end_time:end_ns
         ~attrs
         ("chain/" ^ p.complete_chain_id)
       in
       OT.Trace.emit [span])

  | Error p ->
    let end_ns = OT.Timestamp_ns.now_unix_ns () in
    let node_opt = with_mu (fun () ->
      let v = Hashtbl.find_opt active_nodes p.error_node_id in
      Hashtbl.remove active_nodes p.error_node_id;
      v) in
    (match node_opt with
     | None -> ()
     | Some nf ->
       let attrs : OT.Span.key_value list = [
         ("chain.node.id", `String p.error_node_id);
         ("chain.error.message", `String p.error_message);
         ("chain.error.retries", `Int p.error_retries);
         ("otel.status_code", `String "ERROR");
       ] in
       let status = OT.Proto.Trace.default_status
         ~code:OT.Proto.Trace.Status_code_error
         ~message:p.error_message () in
       let span, _id = OT.Span.create
         ~trace_id:nf.chain_trace_id
         ~parent:nf.chain_span_id
         ~id:nf.node_span_id
         ~start_time:nf.node_start_ns
         ~end_time:end_ns
         ~attrs
         ~status
         ("chain.node.error/" ^ p.error_node_id)
       in
       OT.Trace.emit [span])

(** Subscription handle — kept to allow future unsubscription. *)
let subscription : Chain_telemetry.subscription option ref = ref None

(** Install the OTel chain subscriber. Idempotent. *)
let install () =
  if Otel_config.enabled then
    match !subscription with
    | Some _ -> ()
    | None ->
      subscription := Some (Chain_telemetry.subscribe on_event);
      Log.info ~ctx:"otel" "chain telemetry subscriber installed"

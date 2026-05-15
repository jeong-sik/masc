(* RFC-0084 §2.1 Tool dispatch telemetry 4-tuple emission SSOT.
   See tool_telemetry.mli for the contract. *)

type trace_id = string

let counter_name = "tool_dispatch_total"
let counter_registered = ref false

let register_metrics () =
  if not !counter_registered
  then begin
    Prometheus.register_counter
      ~name:counter_name
      ~help:
        "Total tool dispatches by tool name and outcome label (RFC-0084 §2.1 \
         4-tuple emission invariant)."
      ~labels:[ "tool", ""; "outcome", "" ]
      ();
    counter_registered := true
  end
;;

let with_span ~tool_name f =
  let span_name = "tool_dispatch." ^ tool_name in
  Otel_spans.with_span ~name:span_name (fun trace_id_thunk ->
    let result, outcome = f trace_id_thunk in
    Prometheus.inc_counter
      counter_name
      ~labels:[ "tool", tool_name; "outcome", outcome ]
      ();
    result, outcome)
;;

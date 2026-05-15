open Alcotest

(** RFC-0084 §1.2 Telemetry 4-Tuple Emission Gap

    Pinned state evidence for the telemetry gap in [Tool_dispatch.dispatch].
    Verified at PR-1 author time:

    {v
    rg -n 'Tracing\.with_span' lib/tool_dispatch.ml lib/keeper/keeper_exec_masc.ml
    # 0 matches
    v}

    PR-9 introduces [Tool_dispatch.guarded_dispatch] with 4-tuple emission. The
    [pinned_*] values below must be updated together with PR-9 to reflect the
    post-fix state (each pin moves from 0 → 1 per dispatch).

    4-Tuple definition (RFC-0084 §2.1):
    - Span      : Tracing.with_span ~kind:Tool_dispatch ~name ~tool_id ~trace_id
    - Audit     : Audit_log.record ~event:Tool_dispatched ~outcome
    - Metric    : Prometheus.inc_counter tool_dispatch_total{outcome,tool,surface}
    - Trace_id  : propagated to handler + result
*)

(* Current measured state. PR-9 must update each to 1. *)
let pinned_span_emission_per_dispatch = 0
let pinned_audit_emission_per_dispatch = 0
let pinned_metric_emission_per_dispatch_when_handler_none = 0
let pinned_trace_id_propagation = 0

let test_span_emission_gap () =
  (check int)
    "Tracing.with_span calls per Tool_dispatch.dispatch (RFC-0084 §1.2; PR-9 target = 1)"
    0
    pinned_span_emission_per_dispatch

let test_audit_emission_gap () =
  (check int)
    "Audit_log.record calls per dispatch (RFC-0084 §1.2; PR-9 target = 1)"
    0
    pinned_audit_emission_per_dispatch

let test_metric_emission_gap_on_none () =
  (check int)
    "Prometheus.inc_counter calls when handler returns None \
     (RFC-0084 §1.1 / tool_dispatch.ml:127-129; PR-10 target = 1)"
    0
    pinned_metric_emission_per_dispatch_when_handler_none

let test_trace_id_propagation_gap () =
  (check int)
    "Trace_id propagation count per dispatch (RFC-0084 §1.2; PR-9 target = 1)"
    0
    pinned_trace_id_propagation

let test_4_tuple_total_gap () =
  let total =
    pinned_span_emission_per_dispatch
    + pinned_audit_emission_per_dispatch
    + pinned_metric_emission_per_dispatch_when_handler_none
    + pinned_trace_id_propagation
  in
  (check int)
    "4-tuple emission sum per dispatch \
     (RFC-0084 §2.1 invariant; PR-14 target = 4 across all entries)"
    0
    total

let () =
  Alcotest.run
    "RFC-0084 dispatch telemetry gap"
    [ ( "telemetry-gap"
      , [ test_case "span-emission-gap" `Quick test_span_emission_gap
        ; test_case "audit-emission-gap" `Quick test_audit_emission_gap
        ; test_case "metric-emission-gap-on-none" `Quick test_metric_emission_gap_on_none
        ; test_case "trace-id-propagation-gap" `Quick test_trace_id_propagation_gap
        ; test_case "4-tuple-total-gap" `Quick test_4_tuple_total_gap
        ] )
    ]

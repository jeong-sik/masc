(** RFC-0084 §2.1 — Tool dispatch telemetry 4-tuple emission SSOT.

    Every tool dispatch must emit a 4-tuple [(Span, Audit, Metric, Trace_id)].
    This module wraps the three existing emission surfaces in masc-mcp:

    - [Otel_spans.with_span] for the OTel trace span
    - [Prometheus.inc_counter "tool_dispatch_total"] for the metric
    - [Otel_spans.current_trace_id] (passed as a thunk) for trace_id propagation

    The audit emission slot is filled by callers via [Audit_log.log_action]
    using the [outcome] string returned from [with_span]. PR-10 will unify
    audit emission into a typed [Dispatch_outcome.t].

    PR-3 establishes the wrapper skeleton; no callers migrate to
    [Tool_dispatch.guarded_dispatch] in this PR. Migration:
    - PR-7: keeper turn loop [keeper_exec_masc.ml:164,218]
    - PR-8: MCP server [mcp_server_eio_execute.ml:817,999]
    - PR-9: tag-dispatch fallback [keeper_tag_dispatch.ml] *)

type trace_id = string

(** [with_span ~tool_name f] opens an OTel span named
    {v tool_dispatch.<tool_name> v}, invokes [f] inside the span, and
    increments [tool_dispatch_total] with labels [tool = tool_name] and
    [outcome = <outcome returned by f>].

    [f] receives a thunk that returns [Some trace_id_hex] when an OTel
    span is active, [None] otherwise (e.g. when the exporter is disabled).

    [f] returns a pair [(result, outcome)] where [outcome] is the metric
    label. PR-10 will replace the [string] outcome with a typed
    [Dispatch_outcome.t]. *)
val with_span
  :  tool_name:string
  -> ((unit -> trace_id option) -> 'a * string)
  -> 'a * string

(** Register the [tool_dispatch_total] Prometheus counter with labels
    [tool] and [outcome]. Call once at server startup. Subsequent calls
    are idempotent (no-op). *)
val register_metrics : unit -> unit

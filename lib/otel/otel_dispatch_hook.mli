(** OTel Dispatch Hook — registers a [Tool_dispatch] post-hook that
    records each tool call as both a Prometheus histogram observation
    (always active) and an OpenTelemetry span (gated by
    {!Otel_config.enabled}).

    Span attributes are dual-emitted: legacy [tool.*] keys for
    existing custom dashboards, and OpenTelemetry GenAI semantic
    convention keys ([gen_ai.tool.name], [gen_ai.operation.name]) so
    Datadog v1.37+/Grafana auto-categorise these spans as AI/LLM
    activity. The dual-emit also hedges against semconv churn while
    GenAI fields remain Stability.Experimental.

    Internal helper [on_tool_result] is intentionally hidden — the
    hook is registered through {!install} once at startup, after
    which dispatch invokes it implicitly.

    @since 2.103.0 *)

val install : unit -> unit
(** Register {!on_tool_result} as a [Tool_dispatch] post-hook.
    Idempotent at the call site (calling twice would register the
    callback twice — server bootstrap calls it exactly once). *)

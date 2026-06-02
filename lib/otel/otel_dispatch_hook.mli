(** OTel Dispatch Hook — registers a [Tool_dispatch] observer that
    records each tool call as both a Prometheus histogram observation
    (always active) and an OpenTelemetry span (gated by
    {!Otel_config.enabled}).

    Span attributes use OpenTelemetry GenAI semantic-convention keys
    ([gen_ai.tool.name], [gen_ai.operation.name]) so Datadog
    v1.37+/Grafana auto-categorise these spans as AI/LLM activity.

    Internal helper [on_tool_result] is intentionally hidden — the
    hook is registered through {!install} once at startup, after
    which dispatch invokes it implicitly.

    @since 2.103.0 *)

val with_test_span_emitter :
  enabled:bool ->
  emit_span:(name:string -> attrs:Opentelemetry.key_value list -> unit) ->
  (unit -> 'a) ->
  'a
(** Temporarily override OTel enablement and span emission for focused
    observer tests. Restores the previous emitter after [f] returns/raises. *)

val install : unit -> unit
(** Register {!on_tool_result} as a [Tool_dispatch] observer.
    Idempotent at the call site (calling twice would register the
    callback twice — server bootstrap calls it exactly once). *)

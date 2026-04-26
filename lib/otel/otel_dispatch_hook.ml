(** OTel Dispatch Hook — records tool call spans via Tool_dispatch post-hook.

    Creates an OTel span for each tool call using data from [Tool_result.t].
    Also records a Prometheus histogram observation for tool call duration.

    Span attributes are dual-emitted: the legacy [tool.*] keys stay so
    existing custom dashboards keep working, and the OpenTelemetry GenAI
    semantic-convention keys ([gen_ai.tool.name],
    [gen_ai.operation.name]) are added so vendors that auto-categorise
    on [gen_ai.*] (Datadog v1.37+, Grafana, etc.) classify these spans
    as AI/LLM activity instead of generic tool calls. See #7461 Step 1.

    Note: as of 2026-04 most GenAI semconv attributes are
    Stability.Experimental, so dual-emit also acts as a hedge against
    spec changes — only the legacy keys would survive a rename event.

    @since 2.103.0 *)

module OT = Opentelemetry

(** Record a tool call as an OTel span and Prometheus histogram observation. *)
let on_tool_result (result : Tool_result.t) : Tool_result.t =
  (* Prometheus histogram: always active regardless of MASC_OTEL_ENABLED *)
  Prometheus.observe_histogram
    "masc_tool_call_duration_seconds"
    ~labels:[ "tool_name", result.tool_name ]
    (result.duration_ms /. 1000.0);
  (* OTel span: only when enabled *)
  if Otel_config.enabled
  then (
    let status_attrs =
      if result.success
      then [ "otel.status_code", `String "OK" ]
      else [ "otel.status_code", `String "ERROR" ]
    in
    let legacy_attrs =
      [ "tool.name", `String result.tool_name
      ; "tool.success", `Bool result.success
      ; "tool.duration_ms", `Int (int_of_float result.duration_ms)
      ]
    in
    (* OpenTelemetry GenAI semantic conventions
       (https://opentelemetry.io/docs/specs/semconv/gen-ai/). Tool execution
       within an agent run is the [execute_tool] operation per the spec.
       [gen_ai.system] / [gen_ai.request.model] are intentionally omitted —
       those belong on the parent agent / chat span (Step 2 of #7461),
       not on the inner tool span which is provider-agnostic. *)
    let gen_ai_attrs =
      [ "gen_ai.operation.name", `String "execute_tool"
      ; "gen_ai.tool.name", `String result.tool_name
      ]
    in
    let attrs = legacy_attrs @ gen_ai_attrs @ status_attrs in
    ignore (OT.Trace.with_ ("tool/" ^ result.tool_name) ~attrs (fun _scope -> ())));
  result
;;

let install () = Tool_dispatch.register_post_hook on_tool_result

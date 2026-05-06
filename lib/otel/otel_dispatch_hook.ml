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

(** PR-0.2.C: process startup timestamp captured at module load. Used to
    classify tool calls into [phase=cold] (within first
    [cold_phase_seconds] after startup) or [phase=warm] (after).
    Cold/warm split lets dashboards distinguish first-call overhead
    (provider warmup, JIT, prefix-cache miss) from steady-state cost
    without changing the histogram's underlying observation. *)
let startup_time = Unix.gettimeofday ()
let cold_phase_seconds = 60.0
let cold_warm_phase () =
  if Unix.gettimeofday () -. startup_time < cold_phase_seconds then "cold"
  else "warm"

(** Record a tool call as an OTel span and Prometheus histogram observation. *)
let on_tool_result (result : Tool_result.t) : Tool_result.t =
  (* Prometheus histogram: always active regardless of MASC_OTEL_ENABLED *)
  Prometheus.observe_histogram "masc_tool_call_duration_seconds"
    ~labels:[("tool_name", result.tool_name);
             ("phase", cold_warm_phase ())]
    (result.duration_ms /. 1000.0);
  (* OTel span: only when enabled *)
  if Otel_config.enabled then begin
    let status_attrs =
      if result.success then
        [("otel.status_code", `String "OK")]
      else
        [("otel.status_code", `String "ERROR")]
    in
    let legacy_attrs =
      [ (Otel_genai.Attr_key.tool_name, `String result.tool_name);
        (Otel_genai.Attr_key.tool_success, `Bool result.success);
        (Otel_genai.Attr_key.tool_duration_ms, `Int (int_of_float result.duration_ms)) ]
    in
    (* OpenTelemetry GenAI semantic conventions
       (https://opentelemetry.io/docs/specs/semconv/gen-ai/). Tool execution
       within an agent run is the [execute_tool] operation per the spec.
       provider/model keys are intentionally omitted — those belong on the
       parent agent / model span, not on the inner tool span which is
       provider-agnostic. *)
    let gen_ai_attrs =
      Otel_genai.tool_execution_attrs ~tool_name:result.tool_name
      |> List.map (fun (key, value) -> key, (value :> OT.value))
    in
    let attrs = legacy_attrs @ gen_ai_attrs @ status_attrs in
    ignore (OT.Trace.with_ ("tool/" ^ result.tool_name) ~attrs
      (fun _scope -> ()))
  end;
  result

let install () =
  Tool_dispatch.register_post_hook on_tool_result

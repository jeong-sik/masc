(** OTel Dispatch Hook — records tool call spans via Tool_dispatch post-hook.

    Creates an OTel span for each tool call using data from [Tool_result.result].
    Also records a Prometheus histogram observation for tool call duration.

    Span attributes use OpenTelemetry GenAI semantic-convention keys
    ([gen_ai.tool.name], [gen_ai.operation.name]) so vendors that
    auto-categorise on [gen_ai.*] classify these spans as AI/LLM activity
    instead of generic tool calls. See #7461 Step 1.

    @since 2.103.0 *)

module OT = Opentelemetry

let enabled_override : bool option ref = ref None

let span_emitter_override : (name:string -> attrs:OT.key_value list -> unit) option ref =
  ref None
;;

let enabled () =
  match !enabled_override with
  | Some value -> value
  | None -> Otel_config.enabled
;;

let emit_span ~name ~attrs =
  match !span_emitter_override with
  | Some emit -> emit ~name ~attrs
  | None -> ignore (OT.Trace.with_ name ~attrs (fun _scope -> ()))
;;

let with_test_span_emitter ~enabled:enabled_value ~emit_span:emit f =
  let prev_enabled = !enabled_override in
  let prev_emitter = !span_emitter_override in
  enabled_override := Some enabled_value;
  span_emitter_override := Some emit;
  Eio_guard.protect
    ~finally:(fun () ->
      enabled_override := prev_enabled;
      span_emitter_override := prev_emitter)
    f
;;

(** PR-0.2.C: process startup timestamp captured at module load. Used to
    classify tool calls into [phase=cold] (within first
    [cold_phase_seconds] after startup) or [phase=warm] (after).
    Cold/warm split lets dashboards distinguish first-call overhead
    (provider warmup, JIT, prefix-cache miss) from steady-state cost
    without changing the histogram's underlying observation. *)
let startup_time = Unix.gettimeofday ()

let cold_phase_seconds = 60.0

let cold_warm_phase () =
  if Unix.gettimeofday () -. startup_time < cold_phase_seconds then "cold" else "warm"
;;

let tool_span_attrs (result : Tool_result.result) =
  let status_attrs =
    if Tool_result.is_success result
    then [ "otel.status_code", `String "OK" ]
    else [ "otel.status_code", `String "ERROR" ]
  in
  (* OpenTelemetry GenAI semantic conventions
     (https://opentelemetry.io/docs/specs/semconv/gen-ai/). Tool execution
     within an agent run is the [execute_tool] operation per the spec.
     provider/model keys are intentionally omitted — those belong on the
     parent agent / model span, not on the inner tool span which is
     provider-agnostic. *)
  let gen_ai_attrs =
    Otel_genai.tool_execution_attrs ~tool_name:(Tool_result.tool_name result)
    |> List.map (fun (key, value) -> key, (value :> OT.value))
  in
  gen_ai_attrs @ status_attrs
;;

(** Record a tool call as an OTel span and Prometheus histogram observation. *)
let on_tool_result (result : Tool_result.result) : unit =
  (* Prometheus histogram: always active regardless of MASC_OTEL_ENABLED *)
  Prometheus.observe_histogram
    "masc_tool_call_duration_seconds"
    ~labels:[ "tool_name", Tool_result.tool_name result; "phase", cold_warm_phase () ]
    (Tool_result.duration_ms result /. 1000.0);
  (* OTel span: only when enabled *)
  if enabled ()
  then emit_span ~name:("tool/" ^ Tool_result.tool_name result) ~attrs:(tool_span_attrs result)
;;

(* RFC-0084 PR-I-2.c — migrate to typed post-hook surface.
   Behaviour-preserving: the histogram + span emission fires only on
   (Handled, Some r), matching the legacy hook semantics (legacy
   register_post_hook fired only when [dispatch] returned [Some
   _]).  Non-Handled outcomes already get their 4-tuple emission
   from [Tool_telemetry.with_span] in guarded_dispatch — they do
   NOT need an additional masc_tool_call_duration_seconds observation
   here. *)
let install () =
  Tool_dispatch.register_typed_post_hook (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some r -> on_tool_result r
    | _ -> ())

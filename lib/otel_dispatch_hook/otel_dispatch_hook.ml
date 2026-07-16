(** OTel Dispatch Hook — records tool call spans via a Tool_dispatch observer.

    Creates an OTel span for each tool call using data from [Tool_result.result].

    Span attributes use OpenTelemetry GenAI + MCP semantic-convention keys
    ([gen_ai.tool.name], [gen_ai.operation.name], [mcp.method.name]) so vendors
    that auto-categorise on [gen_ai.*] classify these spans as AI/LLM activity
    while still seeing the underlying MCP [tools/call] method. MCP
    CallToolResult payload failures use [error.type=tool_error]; the MASC
    failure taxonomy is preserved separately under
    [masc.mcp.tool.failure_class].

    @since 2.103.0 *)

module OT = Opentelemetry

type transport_context =
  { network_protocol_name : string option
  ; network_protocol_version : string option
  ; network_transport : string option
  }

type request_context =
  { jsonrpc_request_id : string option
  ; mcp_session_id : string option
  ; mcp_protocol_version : string option
  ; transport : transport_context option
  }

let request_context_key : request_context Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let enabled_override : bool option Atomic.t = Atomic.make None

let span_emitter_override
      : (name:string ->
         attrs:OT.key_value list ->
         kind:OT.Span_kind.t ->
         status:OT.Span_status.t option ->
         unit)
          option
          Atomic.t
  =
  Atomic.make None
;;

let enabled () =
  match Atomic.get enabled_override with
  | Some value -> value
  | None -> Otel_config.enabled
;;

let current_request_context () =
  try Eio.Fiber.get request_context_key with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None
;;

let in_eio_fiber_context () =
  try
    match Eio.Fiber.get request_context_key with
    | Some _ | None -> true
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> false
;;

let with_request_context context f =
  if in_eio_fiber_context ()
  then Eio.Fiber.with_binding request_context_key context f
  else f ()
;;

let tool_call_span_kind () =
  match current_request_context () with
  | Some _ -> OT.Span_kind.Span_kind_server
  | None -> OT.Span_kind.Span_kind_client
;;

let emit_span ~name ~attrs ?status () =
  let kind = tool_call_span_kind () in
  match Atomic.get span_emitter_override with
  | Some emit -> emit ~name ~attrs ~kind ~status
  | None ->
    ignore
      (OT.Trace.with_
         ~kind
         name
         ~attrs
         (fun scope ->
            Option.iter (OT.Scope.set_status scope) status))
;;

let with_test_span_emitter ~enabled:enabled_value ~emit_span:emit f =
  let prev_enabled = Atomic.get enabled_override in
  let prev_emitter = Atomic.get span_emitter_override in
  Atomic.set enabled_override (Some enabled_value);
  Atomic.set span_emitter_override (Some emit);
  Eio_guard.protect
    ~finally:(fun () ->
      Atomic.set enabled_override prev_enabled;
      Atomic.set span_emitter_override prev_emitter)
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

let tool_call_span_name ~tool_name =
  Otel_genai.Mcp_value.tools_call_method ^ " " ^ tool_name
;;

let tool_failure_class_attrs (result : Tool_result.result) =
  match Tool_result.failure_class result with
  | None -> []
  | Some class_ ->
    [ ( Otel_genai.Mcp_attr_key.masc_mcp_tool_failure_class
      , `String (Tool_result.tool_failure_class_to_string class_) )
    ]
;;

let string_attr key = function
  | Some value when String.trim value <> "" -> [ key, `String value ]
  | Some _ | None -> []
;;

let transport_context_attrs = function
  | None -> []
  | Some context ->
    string_attr
      Otel_genai.Mcp_attr_key.network_protocol_name
      context.network_protocol_name
    @ string_attr
        Otel_genai.Mcp_attr_key.network_protocol_version
        context.network_protocol_version
    @ string_attr
        Otel_genai.Mcp_attr_key.network_transport
        context.network_transport
;;

let http_transport_context ~protocol_version =
  { network_protocol_name = Some "http"
  ; network_protocol_version = Some protocol_version
  ; network_transport = Some "tcp"
  }
;;

let request_context_attrs () =
  match current_request_context () with
  | None -> []
  | Some context ->
    string_attr
      Otel_genai.Mcp_attr_key.jsonrpc_request_id
      context.jsonrpc_request_id
    @ string_attr Otel_genai.Mcp_attr_key.mcp_session_id context.mcp_session_id
    @ string_attr
        Otel_genai.Mcp_attr_key.mcp_protocol_version
        context.mcp_protocol_version
    @ transport_context_attrs context.transport
;;

let tool_span_attrs (result : Tool_result.result) =
  let status_attrs =
    if not (Tool_result.is_failed result)
    then []
    else
      [ ( Otel_genai.Mcp_attr_key.error_type
        , `String Otel_genai.Mcp_value.tool_error_type )
      ]
      @ tool_failure_class_attrs result
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
  gen_ai_attrs @ request_context_attrs () @ status_attrs
;;

(** Record a tool call as an OTel span or attach to the ambient dispatch span.

    When an ambient dispatch span exists (e.g. [Tool_telemetry.with_span]),
    attributes and status are attached to that span so the trace stays at
    [spans=1].  Only falls back to creating a standalone span when no ambient
    scope is present. *)
let on_tool_result (result : Tool_result.result) : unit =
  if enabled ()
  then (
    let status =
      if not (Tool_result.is_failed result)
      then None
      else
        Some
          (OT.Span_status.make
             ~message:(Tool_result.message result)
             ~code:OT.Span_status.Status_code_error)
    in
    match OT.Scope.get_ambient_scope () with
    | Some scope ->
      (* Attach to the ambient dispatch span instead of creating a nested
         child span.  Keeps per-tool traces at spans=1. *)
      OT.Scope.add_attrs scope (fun () -> tool_span_attrs result);
      Option.iter (OT.Scope.set_status scope) status
    | None ->
      emit_span
        ~name:(tool_call_span_name ~tool_name:(Tool_result.tool_name result))
        ~attrs:(tool_span_attrs result)
        ?status
        ())
;;

(* Histogram + span emission fires only for handled results. Non-handled
   outcomes already get their 4-tuple emission from [Tool_telemetry.with_span]
   in guarded_dispatch. *)
let install () =
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some r -> on_tool_result r
    | _ -> ())

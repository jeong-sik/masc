(** OTel Dispatch Hook — records tool call spans via Tool_dispatch post-hook.

    Creates an OTel span for each tool call using data from [Tool_result.t].
    Also records a Prometheus histogram observation for tool call duration.

    @since 2.103.0 *)

module OT = Opentelemetry

(** Record a tool call as an OTel span and Prometheus histogram observation. *)
let on_tool_result (result : Tool_result.t) : Tool_result.t =
  (* Prometheus histogram: always active regardless of MASC_OTEL_ENABLED *)
  Prometheus.observe_histogram "masc_tool_call_duration_seconds"
    ~labels:[("tool_name", result.tool_name)]
    (result.duration_ms /. 1000.0);
  (* OTel span: only when enabled *)
  if Otel_config.enabled then begin
    let status_attrs =
      if result.success then
        [("otel.status_code", `String "OK")]
      else
        [("otel.status_code", `String "ERROR")]
    in
    let attrs =
      [ ("tool.name", `String result.tool_name);
        ("tool.success", `Bool result.success);
        ("tool.duration_ms", `Int (int_of_float result.duration_ms)) ]
      @ status_attrs
    in
    ignore (OT.Trace.with_ ("tool/" ^ result.tool_name) ~attrs
      (fun _scope -> ()))
  end;
  result

let install () =
  Tool_dispatch.register_post_hook on_tool_result

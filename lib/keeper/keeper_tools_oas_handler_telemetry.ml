(** Telemetry helpers for keeper tool OAS handler execution.

    SSE broadcast, decision-log append, and event JSON construction.
    Isolated to keep the handler skeleton focused on control flow. *)

let keeper_tool_call_event_json
      ~keeper_name
      ~tool_name
      ~duration_ms
      ~success
      ?error_text
      ?(extra_fields = [])
      ~ts
      ()
  =
  let fields =
    [ "type", `String "keeper_tool_call"
    ; "name", `String keeper_name
    ; "tool_name", `String tool_name
    ; "duration_ms", `Int duration_ms
    ; "success", `Bool success
    ; "ts_unix", `Float ts
    ]
  in
  let fields =
    match error_text with
    | Some error_text -> fields @ [ "error_text", `String error_text ]
    | None -> fields
  in
  `Assoc (fields @ extra_fields)
;;

let string_preview_field key = function
  | Some value when String.trim value <> "" -> [ key, `String value ]
  | Some _ | None -> []
;;

let json_field key = function
  | Some value -> [ key, value ]
  | None -> []
;;

let tool_io_preview_fields ~tool_name ~input ?output () =
  let input_preview = Observability_redact.redact_tool_input ~tool_name input in
  let output_preview =
    match output with
    | Some output -> Observability_redact.redact_tool_output ~tool_name output
    | None -> None
  in
  let input_json = Observability_redact.redacted_tool_input_json ~tool_name input in
  let output_json =
    match output with
    | Some output -> Observability_redact.redacted_tool_output_json ~tool_name output
    | None -> None
  in
  json_field "tool_args" input_json
  @ json_field "tool_result" output_json
  @ string_preview_field "tool_args_preview" input_preview
  @ string_preview_field "tool_output_preview" output_preview
;;

let broadcast_keeper_tool_call_event
      ~keeper_name
      ~tool_name
      ~duration_ms
      ~success
      ?error_text
      ?(extra_fields = [])
      ~site
      ~ts
      ()
  =
  try
    Sse.broadcast
      (keeper_tool_call_event_json
         ~keeper_name
         ~tool_name
         ~duration_ms
         ~success
         ?error_text
         ~extra_fields
         ~ts
         ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name ]
      ();
    Log.Keeper.warn
      "keeper tool-call SSE broadcast failed: keeper=%s tool=%s site=%s err=%s"
      keeper_name
      tool_name
      site
      (Printexc.to_string exn)
;;

let append_tool_exec_decision_log ~config ~keeper_name ~site entry =
  try
    Keeper_types_support.append_jsonl_line
      (Keeper_types_support.keeper_decision_log_path config keeper_name)
      entry
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DecisionAuditFlushFailures)
      ~labels:[ "keeper", keeper_name ]
      ();
    Log.Keeper.warn
      "keeper tool execution decision-log append failed: keeper=%s site=%s err=%s"
      keeper_name
      site
      (Printexc.to_string exn)
;;

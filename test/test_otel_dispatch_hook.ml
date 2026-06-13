module Hook = Otel_dispatch_hook
module Genai = Otel_genai
module OT = Opentelemetry

type captured_span =
  { name : string
  ; attrs : OT.key_value list
  ; kind : OT.Span_kind.t
  ; status : OT.Span_status.t option
  }

let assoc_string key attrs =
  match List.assoc_opt key attrs with
  | Some (`String value) -> value
  | Some _ -> Alcotest.failf "expected string attr %s" key
  | None -> Alcotest.failf "missing attr %s" key
;;

let check_no_attr key attrs =
  Alcotest.(check bool)
    (key ^ " absent")
    true
    (List.assoc_opt key attrs |> Option.is_none)
;;

let capture f =
  let captured = ref None in
  let emit_span ~name ~attrs ~kind ~status =
    captured := Some { name; attrs; kind; status }
  in
  Hook.with_test_span_emitter ~enabled:true ~emit_span f;
  match !captured with
  | Some span -> span
  | None -> Alcotest.fail "expected OTel dispatch span"
;;

let test_success_span_uses_mcp_tool_call_semconv () =
  let result =
    Tool_result.make_ok
      ~tool_name:"get-weather"
      ~start_time:(Unix.gettimeofday ())
      ~data:(`Assoc [ "ok", `Bool true ])
      ()
  in
  let span =
    capture (fun () ->
      Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some result))
  in
  Alcotest.(check string)
    "span name"
    "tools/call get-weather"
    span.name;
  Alcotest.(check bool)
    "span kind CLIENT"
    true
    (span.kind = OT.Span_kind.Span_kind_client);
  Alcotest.(check bool)
    "successful tool call leaves status unset"
    true
    (Option.is_none span.status);
  Alcotest.(check string)
    "gen_ai.operation.name"
    "execute_tool"
    (assoc_string Genai.Attr_key.gen_ai_operation_name span.attrs);
  Alcotest.(check string)
    "gen_ai.tool.name"
    "get-weather"
    (assoc_string Genai.Attr_key.gen_ai_tool_name span.attrs);
  Alcotest.(check string)
    "mcp.method.name"
    "tools/call"
    (assoc_string Genai.Mcp_attr_key.mcp_method_name span.attrs);
  check_no_attr Genai.Mcp_attr_key.jsonrpc_request_id span.attrs;
  check_no_attr Genai.Mcp_attr_key.mcp_session_id span.attrs;
  check_no_attr Genai.Mcp_attr_key.mcp_protocol_version span.attrs;
  check_no_attr Genai.Mcp_attr_key.network_protocol_name span.attrs;
  check_no_attr Genai.Mcp_attr_key.network_protocol_version span.attrs;
  check_no_attr Genai.Mcp_attr_key.network_transport span.attrs;
  check_no_attr "otel.status_code" span.attrs
;;

let test_request_context_span_records_mcp_server_attrs () =
  let result =
    Tool_result.make_ok
      ~tool_name:"get-weather"
      ~start_time:(Unix.gettimeofday ())
      ~data:(`Assoc [ "ok", `Bool true ])
      ()
  in
  let context : Hook.request_context =
    { jsonrpc_request_id = Some "42"
    ; mcp_session_id = Some "session-otel"
    ; mcp_protocol_version = Some "2026-07-28"
    ; transport = Some (Hook.http_transport_context ~protocol_version:"1.1")
    }
  in
  let span =
    Eio_main.run (fun _env ->
      capture (fun () ->
        Hook.with_request_context context (fun () ->
          Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some result))))
  in
  Alcotest.(check bool)
    "MCP request tool call span kind SERVER"
    true
    (span.kind = OT.Span_kind.Span_kind_server);
  Alcotest.(check string)
    "jsonrpc.request.id"
    "42"
    (assoc_string Genai.Mcp_attr_key.jsonrpc_request_id span.attrs);
  Alcotest.(check string)
    "mcp.session.id"
    "session-otel"
    (assoc_string Genai.Mcp_attr_key.mcp_session_id span.attrs);
  Alcotest.(check string)
    "mcp.protocol.version"
    "2026-07-28"
    (assoc_string Genai.Mcp_attr_key.mcp_protocol_version span.attrs);
  Alcotest.(check string)
    "network.protocol.name"
    "http"
    (assoc_string Genai.Mcp_attr_key.network_protocol_name span.attrs);
  Alcotest.(check string)
    "network.protocol.version"
    "1.1"
    (assoc_string Genai.Mcp_attr_key.network_protocol_version span.attrs);
  Alcotest.(check string)
    "network.transport"
    "tcp"
    (assoc_string Genai.Mcp_attr_key.network_transport span.attrs)
;;

let test_failure_span_records_typed_error_status () =
  let result =
    Tool_result.make_err
      ~tool_name:"keeper_board_post"
      ~class_:Tool_result.Policy_rejection
      ~start_time:(Unix.gettimeofday ())
      "blocked by policy"
  in
  let span =
    capture (fun () ->
      Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some result))
  in
  Alcotest.(check string)
    "span name"
    "tools/call keeper_board_post"
    span.name;
  Alcotest.(check string)
    "error.type"
    "tool_error"
    (assoc_string Genai.Mcp_attr_key.error_type span.attrs);
  Alcotest.(check string)
    "masc.mcp.tool.failure_class"
    "policy_rejection"
    (assoc_string Genai.Mcp_attr_key.masc_mcp_tool_failure_class span.attrs);
  check_no_attr "otel.status_code" span.attrs;
  match span.status with
  | None -> Alcotest.fail "failed tool call should set ERROR span status"
  | Some status ->
    Alcotest.(check string) "status message" "blocked by policy" status.message;
    Alcotest.(check bool)
      "status code ERROR"
      true
      (status.code = OT.Span_status.Status_code_error)
;;

let () =
  Hook.install ();
  Alcotest.run
    "otel_dispatch_hook"
    [ ( "mcp-tool-call-semconv"
      , [ Alcotest.test_case
            "success span uses MCP tool-call semantic convention"
            `Quick
            test_success_span_uses_mcp_tool_call_semconv
        ; Alcotest.test_case
            "request context records MCP server attributes"
            `Quick
            test_request_context_span_records_mcp_server_attrs
        ; Alcotest.test_case
            "failure span records typed error status"
            `Quick
            test_failure_span_records_typed_error_status
        ] )
    ]
;;

(** GenAI semantic-convention helpers for MASC OTel spans.

    Emits canonical [gen_ai.*] attributes plus MASC-owned extension keys for
    fields that are outside the OpenTelemetry GenAI semantic convention. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

module Attr_key = struct
  type boundary =
    | Official_gen_ai
    | Masc_extension
    | Legacy

  let registry_ref = ref []

  let register boundary key =
    registry_ref := (key, boundary) :: !registry_ref;
    key
  ;;

  let gen_ai_operation_name =
    register Official_gen_ai "gen_ai.operation.name"
  ;;

  let gen_ai_provider_name = register Official_gen_ai "gen_ai.provider.name"
  let gen_ai_agent_name = register Official_gen_ai "gen_ai.agent.name"
  let gen_ai_agent_id = register Official_gen_ai "gen_ai.agent.id"

  let gen_ai_conversation_id =
    register Official_gen_ai "gen_ai.conversation.id"
  ;;

  let gen_ai_tool_name = register Official_gen_ai "gen_ai.tool.name"
  let gen_ai_request_model = register Official_gen_ai "gen_ai.request.model"
  let gen_ai_request_stream = register Official_gen_ai "gen_ai.request.stream"
  let gen_ai_response_model = register Official_gen_ai "gen_ai.response.model"
  let gen_ai_token_type = register Official_gen_ai "gen_ai.token.type"
  let gen_ai_usage_input_tokens =
    register Official_gen_ai "gen_ai.usage.input_tokens"
  ;;

  let gen_ai_usage_output_tokens =
    register Official_gen_ai "gen_ai.usage.output_tokens"
  ;;

  let gen_ai_usage_cache_creation_input_tokens =
    register Official_gen_ai "gen_ai.usage.cache_creation.input_tokens"
  ;;

  let gen_ai_usage_cache_read_input_tokens =
    register Official_gen_ai "gen_ai.usage.cache_read.input_tokens"
  ;;

  let gen_ai_usage_reasoning_output_tokens =
    register Official_gen_ai "gen_ai.usage.reasoning.output_tokens"
  ;;

  let gen_ai_response_time_to_first_chunk =
    register Official_gen_ai "gen_ai.response.time_to_first_chunk"
  ;;

  let masc_gen_ai_keeper_name =
    register Masc_extension "masc.gen_ai.keeper.name"
  ;;

  let masc_gen_ai_runtime_id =
    register Masc_extension "masc.gen_ai.runtime_id"
  ;;

  let masc_gen_ai_response_finish_reason =
    register Masc_extension "masc.gen_ai.response.finish_reason"
  ;;

  (* RFC-0233 §2.3 - per-turn TurnRecord projection onto the turn span. *)
  let masc_turn_blocks = register Masc_extension "masc.turn.blocks"
  let masc_turn_profile = register Masc_extension "masc.turn.profile"

  let masc_turn_execution_ids =
    register Masc_extension "masc.turn.execution_ids"
  ;;

  let keeper_name = register Legacy "keeper.name"
  let keeper_agent_name = register Legacy "keeper.agent_name"
  let keeper_trace_id = register Legacy "keeper.trace_id"
  let keeper_generation = register Legacy "keeper.generation"
  let keeper_max_context = register Legacy "keeper.max_context"
  let keeper_channel = register Legacy "keeper.channel"
  let keeper_is_retry = register Legacy "keeper.is_retry"
  let keeper_current_task_id = register Legacy "keeper.current_task_id"

  let registry = List.rev !registry_ref

  let keys_for boundary =
    registry
    |> List.filter_map (fun (key, registered_boundary) ->
      if registered_boundary = boundary then Some key else None)
  ;;

  let all_known = List.map fst registry
  let official_gen_ai = keys_for Official_gen_ai
  let masc_extensions = keys_for Masc_extension
  let legacy = keys_for Legacy

  let is_official_gen_ai key = List.mem key official_gen_ai
  let is_masc_extension key = List.mem key masc_extensions
end

module Metric_name = struct
  let client_token_usage = "gen_ai.client.token.usage"
  let client_operation_duration = "gen_ai.client.operation.duration"
  let client_operation_time_to_first_chunk =
    "gen_ai.client.operation.time_to_first_chunk"
  ;;

  let client_operation_time_per_output_chunk =
    "gen_ai.client.operation.time_per_output_chunk"
  ;;
end

module Mcp_attr_key = struct
  let mcp_method_name = "mcp.method.name"
  let jsonrpc_request_id = "jsonrpc.request.id"
  let jsonrpc_protocol_version = "jsonrpc.protocol.version"
  let mcp_protocol_version = "mcp.protocol.version"
  let mcp_session_id = "mcp.session.id"
  let network_protocol_name = "network.protocol.name"
  let network_protocol_version = "network.protocol.version"
  let network_transport = "network.transport"
  let error_type = "error.type"
  let rpc_response_status_code = "rpc.response.status_code"
  let server_address = "server.address"
  let server_port = "server.port"
  let masc_mcp_tool_failure_class = "masc.mcp.tool.failure_class"
end

module Mcp_value = struct
  let tools_call_method = "tools/call"
  let tool_error_type = "tool_error"
end

module Mcp_metric_name = struct
  let client_operation_duration = "mcp.client.operation.duration"
  let server_operation_duration = "mcp.server.operation.duration"
  let client_session_duration = "mcp.client.session.duration"
  let server_session_duration = "mcp.server.session.duration"
end

module Event_name = struct
  let client_inference_operation_details =
    "gen_ai.client.inference.operation.details"
  ;;

  let client_operation_exception = "gen_ai.client.operation.exception"
end

let keeper_turn_span_name ~keeper_name = "invoke_agent " ^ keeper_name

let keeper_turn_attrs
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~max_context
      ~channel
      ~is_retry
      ~current_task_id
  =
  let runtime_id = runtime_id in
  let optional_attrs =
    match current_task_id with
    | None -> []
    | Some task_id -> [ Attr_key.keeper_current_task_id, `String task_id ]
  in
  [ Attr_key.keeper_name, `String keeper_name
  ; Attr_key.keeper_agent_name, `String agent_name
  ; Attr_key.keeper_trace_id, `String trace_id
  ; Attr_key.keeper_generation, `Int generation
  ; Attr_key.keeper_max_context, `Int max_context
  ; Attr_key.keeper_channel, `String channel
  ; Attr_key.keeper_is_retry, `Bool is_retry
  ; Attr_key.gen_ai_operation_name, `String "invoke_agent"
  ; Attr_key.gen_ai_provider_name, `String "masc"
  ; Attr_key.gen_ai_agent_name, `String keeper_name
  ; Attr_key.gen_ai_agent_id, `String agent_name
  ; Attr_key.gen_ai_conversation_id, `String trace_id
  ; Attr_key.masc_gen_ai_keeper_name, `String keeper_name
  ; Attr_key.masc_gen_ai_runtime_id, `String runtime_id
  ]
  @ optional_attrs
;;

let tool_execution_attrs ~tool_name =
  [ Attr_key.gen_ai_operation_name, `String "execute_tool"
  ; Attr_key.gen_ai_tool_name, `String tool_name
  ; Mcp_attr_key.mcp_method_name, `String Mcp_value.tools_call_method
  ]
;;

let with_keeper_turn_span
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
      ~generation
      ~max_context
      ~channel
      ~is_retry
      ~current_task_id
      f
  =
  if not Otel_config.enabled
  then f (fun () -> None)
  else (
    let attrs =
      keeper_turn_attrs
        ~keeper_name
        ~agent_name
        ~runtime_id
        ~trace_id
        ~generation
        ~max_context
        ~channel
        ~is_retry
        ~current_task_id
    in
    Otel_spans.with_span
      ~name:(keeper_turn_span_name ~keeper_name)
      ~attrs
      (* Force a fresh trace root per keeper turn. Without this the keeper-turn
         span inherits the ambient trace context, and many turns from different
         keepers accumulate under one trace. Observed on a production trace:
         19 invoke_agent spans in a single trace, with mixed structure (some a
         real root, others referencing a parent span absent from the trace).
         Mirrors the tool-dispatch boundary fix (one trace root per operation,
         #20581). Tool dispatches already start their own trace, so this does
         not lose a parent/child link that previously existed. *)
      ~force_new_trace_id:true
      (fun trace_link -> f trace_link))
;;

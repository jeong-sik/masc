(** GenAI semantic-convention helpers for MASC OTel spans.

    Emits canonical [gen_ai.*] attributes plus MASC-owned extension keys for
    fields that are outside the OpenTelemetry GenAI semantic convention. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

module Attr_key = struct
  let gen_ai_operation_name = "gen_ai.operation.name"
  let gen_ai_provider_name = "gen_ai.provider.name"
  let gen_ai_agent_name = "gen_ai.agent.name"
  let gen_ai_agent_id = "gen_ai.agent.id"
  let gen_ai_conversation_id = "gen_ai.conversation.id"
  let gen_ai_tool_name = "gen_ai.tool.name"
  let gen_ai_request_model = "gen_ai.request.model"
  let gen_ai_request_stream = "gen_ai.request.stream"
  let gen_ai_response_model = "gen_ai.response.model"
  let gen_ai_token_type = "gen_ai.token.type"
  let gen_ai_usage_input_tokens = "gen_ai.usage.input_tokens"
  let gen_ai_usage_output_tokens = "gen_ai.usage.output_tokens"

  let gen_ai_usage_cache_creation_input_tokens =
    "gen_ai.usage.cache_creation.input_tokens"
  ;;

  let gen_ai_usage_cache_read_input_tokens = "gen_ai.usage.cache_read.input_tokens"
  let gen_ai_usage_reasoning_output_tokens = "gen_ai.usage.reasoning.output_tokens"
  let gen_ai_response_time_to_first_chunk = "gen_ai.response.time_to_first_chunk"
  let masc_gen_ai_keeper_name = "masc.gen_ai.keeper.name"
  let masc_gen_ai_runtime_id = "masc.gen_ai.runtime_id"
  let masc_gen_ai_response_finish_reason = "masc.gen_ai.response.finish_reason"

  (* RFC-0233 §2.3 - per-turn TurnRecord projection onto the turn span. *)
  let masc_turn_blocks = "masc.turn.blocks"
  let masc_turn_profile = "masc.turn.profile"
  let masc_turn_execution_ids = "masc.turn.execution_ids"
  let keeper_name = "keeper.name"
  let keeper_agent_name = "keeper.agent_name"
  let keeper_trace_id = "keeper.trace_id"
  let keeper_max_context = "keeper.max_context"
  let keeper_channel = "keeper.channel"
  let keeper_is_retry = "keeper.is_retry"
  let keeper_current_task_id = "keeper.current_task_id"
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
  let mcp_protocol_version = "mcp.protocol.version"
  let mcp_session_id = "mcp.session.id"
  let network_protocol_name = "network.protocol.name"
  let network_protocol_version = "network.protocol.version"
  let network_transport = "network.transport"
  let error_type = "error.type"
  let masc_mcp_tool_failure_class = "masc.mcp.tool.failure_class"
end

module Mcp_value = struct
  let tools_call_method = "tools/call"
  let tool_error_type = "tool_error"
end

module Mcp_metric_name = struct
  let server_operation_duration = "mcp.server.operation.duration"
  let server_session_duration = "mcp.server.session.duration"
end

module Event_name = struct
  let client_inference_operation_details =
    "gen_ai.client.inference.operation.details"
  ;;

end

let keeper_turn_span_name ~keeper_name = "invoke_agent " ^ keeper_name

let keeper_turn_attrs
      ~keeper_name
      ~agent_name
      ~runtime_id
      ~trace_id
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

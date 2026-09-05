(** GenAI semantic-convention helpers for MASC OTel spans. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

module Attr_key : sig
  val gen_ai_operation_name : string
  val gen_ai_provider_name : string
  val gen_ai_tool_name : string
  val gen_ai_request_model : string
  val gen_ai_request_stream : string
  val gen_ai_response_model : string
  val gen_ai_token_type : string
  val gen_ai_usage_input_tokens : string
  val gen_ai_usage_output_tokens : string
  val gen_ai_usage_cache_creation_input_tokens : string
  val gen_ai_usage_cache_read_input_tokens : string
  val gen_ai_usage_reasoning_output_tokens : string
  val gen_ai_response_time_to_first_chunk : string
  val masc_gen_ai_response_finish_reason : string
  val masc_turn_blocks : string
  val masc_turn_profile : string
  val masc_turn_execution_ids : string
  val keeper_name : string
  val keeper_agent_name : string
end

module Mcp_attr_key : sig
  val mcp_method_name : string
  val jsonrpc_request_id : string
  val mcp_protocol_version : string
  val mcp_session_id : string
  val network_protocol_name : string
  val network_protocol_version : string
  val network_transport : string
  val error_type : string
  val server_address : string
  val server_port : string
  val masc_mcp_tool_failure_class : string
end

module Mcp_value : sig
  val tools_call_method : string
  val tool_error_type : string
end

module Mcp_metric_name : sig
  val client_operation_duration : string
  val server_operation_duration : string
  val server_session_duration : string
end

module Metric_name : sig
  val client_token_usage : string
  val client_operation_duration : string
  val client_operation_time_to_first_chunk : string
  val client_operation_time_per_output_chunk : string
end

module Event_name : sig
  val client_inference_operation_details : string
end

val tool_execution_attrs : tool_name:string -> attr list

val with_keeper_turn_span
  :  keeper_name:string
  -> agent_name:string
  -> runtime_id:string
  -> trace_id:string
  -> max_context:int
  -> channel:string
  -> is_retry:bool
  -> current_task_id:string option
  -> ((unit -> (string * string) option) -> 'a)
  -> 'a

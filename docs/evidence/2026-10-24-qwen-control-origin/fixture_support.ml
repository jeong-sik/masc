(* Isolated fixture dependencies. These are NOT the production Types/config or
   serializer modules. They permit executing the unchanged production lowerer
   without building/linking MASC. The fixture reports that boundary explicitly. *)
module Types = struct
  type role = System | User | Assistant | Tool
  type message_origin = Conversation | System_context | Historical_system_context
    | Recovery_instruction | Tool_result_followup | Agent_instruction
  type content_block =
    | Text of string | Thinking of string | ReasoningDetails of string
    | RedactedThinking of string | ToolUse of string | ToolResult of string
    | Image of string | Document of string | Audio of string
  type message = {role:role; origin:message_origin; content:content_block list;
    name:string option; tool_call_id:string option; metadata:(string * Yojson.Safe.t) list}
  let role_to_string = function
    | System -> "system" | User -> "user" | Assistant -> "assistant" | Tool -> "tool"
  let make_message ?name ?tool_call_id ?(origin=Conversation) ?(metadata=[]) ~role content =
    {role; origin; content; name; tool_call_id; metadata}
end

module Capabilities = struct
  type reasoning_replay_override = Default_reasoning_replay
    | Force_initial_system_latest_user_turn_tool_calls
    | Force_turn_scoped_system_context_preserve_always
    | Force_no_replay | Force_drop_without_tool_preserve_with_tool
    | Force_latest_user_turn_tool_calls | Force_preserve_always
    | Force_preserve_with_request_tools
  type capabilities = {reasoning_replay_override:reasoning_replay_override}
end

module Provider_config = struct
  type codec = Openai_chat | Glm_chat | Ollama_chat | Anthropic_messages
    | Gemini_generate_content | Openai_responses
  type t = {codec:codec; capabilities:Capabilities.capabilities option}
  let capabilities_for_config_model config = config.capabilities
end

module Provider_http_codec = struct
  type t = Provider_config.codec = Openai_chat | Glm_chat | Ollama_chat
    | Anthropic_messages | Gemini_generate_content | Openai_responses
  let of_config (config:Provider_config.t) = config.codec
end

module Api_common = struct
  let string_is_blank text = String.trim text = ""
end

module Utf8_sanitize = struct
  (* All fixture text is valid UTF-8. This is not a sanitizer test. *)
  let sanitize text = text
end

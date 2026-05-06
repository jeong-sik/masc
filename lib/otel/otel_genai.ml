(** GenAI semantic-convention helpers for MASC OTel spans.

    GenAI semantic conventions are still Development as of 2026-05-06, so these
    helpers dual-emit MASC legacy [keeper.*] attributes with [gen_ai.*]
    attributes. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

module Attr_key = struct
  let gen_ai_operation_name = "gen_ai.operation.name"
  let gen_ai_provider_name = "gen_ai.provider.name"
  let gen_ai_agent_name = "gen_ai.agent.name"
  let gen_ai_agent_id = "gen_ai.agent.id"
  let gen_ai_conversation_id = "gen_ai.conversation.id"
  let gen_ai_tool_name = "gen_ai.tool.name"
  let masc_gen_ai_keeper_name = "masc.gen_ai.keeper.name"
  let masc_gen_ai_cascade_name = "masc.gen_ai.cascade.name"
  let keeper_name = "keeper.name"
  let keeper_agent_name = "keeper.agent_name"
  let keeper_cascade_name = "keeper.cascade.name"
  let keeper_trace_id = "keeper.trace_id"
  let keeper_generation = "keeper.generation"
  let keeper_max_context = "keeper.max_context"
  let keeper_max_turns = "keeper.max_turns"
  let keeper_max_idle_turns = "keeper.max_idle_turns"
  let keeper_channel = "keeper.channel"
  let keeper_is_retry = "keeper.is_retry"
  let keeper_current_task_id = "keeper.current_task_id"
  let tool_name = "tool.name"
  let tool_success = "tool.success"
  let tool_duration_ms = "tool.duration_ms"

  let official_gen_ai =
    [ gen_ai_operation_name
    ; gen_ai_provider_name
    ; gen_ai_agent_name
    ; gen_ai_agent_id
    ; gen_ai_conversation_id
    ; gen_ai_tool_name
    ]
  ;;

  let masc_extensions = [ masc_gen_ai_keeper_name; masc_gen_ai_cascade_name ]

  let legacy =
    [ keeper_name
    ; keeper_agent_name
    ; keeper_cascade_name
    ; keeper_trace_id
    ; keeper_generation
    ; keeper_max_context
    ; keeper_max_turns
    ; keeper_max_idle_turns
    ; keeper_channel
    ; keeper_is_retry
    ; keeper_current_task_id
    ; tool_name
    ; tool_success
    ; tool_duration_ms
    ]
  ;;

  let all_known = official_gen_ai @ masc_extensions @ legacy

  let is_official_gen_ai key = List.mem key official_gen_ai
  let is_masc_extension key = List.mem key masc_extensions
end

let keeper_turn_span_name ~keeper_name = "invoke_agent " ^ keeper_name

let keeper_turn_attrs
      ~keeper_name
      ~agent_name
      ~cascade_name
      ~trace_id
      ~generation
      ~max_context
      ~max_turns
      ~max_idle_turns
      ~channel
      ~is_retry
      ~current_task_id
  =
  let cascade_name = Keeper_cascade_profile.runtime_name_to_string cascade_name in
  let optional_attrs =
    match current_task_id with
    | None -> []
    | Some task_id -> [ Attr_key.keeper_current_task_id, `String task_id ]
  in
  [ Attr_key.keeper_name, `String keeper_name
  ; Attr_key.keeper_agent_name, `String agent_name
  ; Attr_key.keeper_cascade_name, `String cascade_name
  ; Attr_key.keeper_trace_id, `String trace_id
  ; Attr_key.keeper_generation, `Int generation
  ; Attr_key.keeper_max_context, `Int max_context
  ; Attr_key.keeper_max_turns, `Int max_turns
  ; Attr_key.keeper_max_idle_turns, `Int max_idle_turns
  ; Attr_key.keeper_channel, `String channel
  ; Attr_key.keeper_is_retry, `Bool is_retry
  ; Attr_key.gen_ai_operation_name, `String "invoke_agent"
  ; Attr_key.gen_ai_provider_name, `String "masc"
  ; Attr_key.gen_ai_agent_name, `String keeper_name
  ; Attr_key.gen_ai_agent_id, `String agent_name
  ; Attr_key.gen_ai_conversation_id, `String trace_id
  ; Attr_key.masc_gen_ai_keeper_name, `String keeper_name
  ; Attr_key.masc_gen_ai_cascade_name, `String cascade_name
  ]
  @ optional_attrs
;;

let tool_execution_attrs ~tool_name =
  [ Attr_key.gen_ai_operation_name, `String "execute_tool"
  ; Attr_key.gen_ai_tool_name, `String tool_name
  ]
;;

let with_keeper_turn_span
      ~keeper_name
      ~agent_name
      ~cascade_name
      ~trace_id
      ~generation
      ~max_context
      ~max_turns
      ~max_idle_turns
      ~channel
      ~is_retry
      ~current_task_id
      f
  =
  if not Otel_config.enabled
  then f ()
  else (
    let attrs =
      keeper_turn_attrs
        ~keeper_name
        ~agent_name
        ~cascade_name
        ~trace_id
        ~generation
        ~max_context
        ~max_turns
        ~max_idle_turns
        ~channel
        ~is_retry
        ~current_task_id
    in
    Otel_spans.with_span
      ~name:(keeper_turn_span_name ~keeper_name)
      ~attrs
      (fun _trace_id -> f ()))
;;

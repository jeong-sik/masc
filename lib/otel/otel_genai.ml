(** GenAI semantic-convention helpers for MASC OTel spans.

    GenAI semantic conventions are still Development as of 2026-04, so these
    helpers dual-emit MASC legacy [keeper.*] attributes with [gen_ai.*]
    attributes. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

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
  let optional_attrs =
    match current_task_id with
    | None -> []
    | Some task_id -> [ "keeper.current_task_id", `String task_id ]
  in
  [ "keeper.name", `String keeper_name
  ; "keeper.agent_name", `String agent_name
  ; "keeper.cascade.name", `String cascade_name
  ; "keeper.trace_id", `String trace_id
  ; "keeper.generation", `Int generation
  ; "keeper.max_context", `Int max_context
  ; "keeper.max_turns", `Int max_turns
  ; "keeper.max_idle_turns", `Int max_idle_turns
  ; "keeper.channel", `String channel
  ; "keeper.is_retry", `Bool is_retry
  ; "gen_ai.operation.name", `String "invoke_agent"
  ; "gen_ai.provider.name", `String "masc"
  ; "gen_ai.agent.name", `String keeper_name
  ; "gen_ai.agent.id", `String agent_name
  ; "gen_ai.conversation.id", `String trace_id
  ]
  @ optional_attrs
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

(** GenAI semantic-convention helpers for MASC OTel spans. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

module Attr_key : sig
  val gen_ai_operation_name : string
  val gen_ai_provider_name : string
  val gen_ai_agent_name : string
  val gen_ai_agent_id : string
  val gen_ai_conversation_id : string
  val gen_ai_tool_name : string
  val masc_gen_ai_keeper_name : string
  val masc_gen_ai_cascade_name : string
  val keeper_name : string
  val keeper_agent_name : string
  val keeper_cascade_name : string
  val keeper_trace_id : string
  val keeper_generation : string
  val keeper_max_context : string
  val keeper_max_turns : string
  val keeper_max_idle_turns : string
  val keeper_channel : string
  val keeper_is_retry : string
  val keeper_current_task_id : string
  val tool_name : string
  val tool_success : string
  val tool_duration_ms : string

  (** Every registered Attr_key constant exported by this module.

      Exported constants are created through the internal registration helper,
      and this list is derived from that registry. Tests assert that exported
      string constants are registered and that the boundary lists form a
      disjoint partition of the registry. *)
  val all_known : string list

  val official_gen_ai : string list
  val masc_extensions : string list
  val legacy : string list
  val is_official_gen_ai : string -> bool
  val is_masc_extension : string -> bool
end

val keeper_turn_span_name : keeper_name:string -> string

val keeper_turn_attrs
  :  keeper_name:string
  -> agent_name:string
  -> cascade_name:Keeper_cascade_profile.runtime_name
  -> trace_id:string
  -> generation:int
  -> max_context:int
  -> max_turns:int
  -> max_idle_turns:int
  -> channel:string
  -> is_retry:bool
  -> current_task_id:string option
  -> attr list

val tool_execution_attrs : tool_name:string -> attr list

val with_keeper_turn_span
  :  keeper_name:string
  -> agent_name:string
  -> cascade_name:Keeper_cascade_profile.runtime_name
  -> trace_id:string
  -> generation:int
  -> max_context:int
  -> max_turns:int
  -> max_idle_turns:int
  -> channel:string
  -> is_retry:bool
  -> current_task_id:string option
  -> (unit -> 'a)
  -> 'a

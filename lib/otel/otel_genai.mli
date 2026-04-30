(** GenAI semantic-convention helpers for MASC OTel spans. *)

type attr = string * [ `Bool of bool | `Int of int | `String of string ]

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

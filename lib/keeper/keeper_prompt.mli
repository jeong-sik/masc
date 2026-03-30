(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

val exact_direct_mention_present : targets:string list -> string -> bool

val keeper_constitution : unit -> string

val build_keeper_system_prompt :
  goal:string ->
  short_goal:string ->
  mid_goal:string ->
  long_goal:string ->
  soul_profile:string ->
  will:string ->
  needs:string ->
  desires:string ->
  instructions:string ->
  ?persona_extended:string ->
  unit ->
  string

val append_direct_reply_mode_prompt :
  base_prompt:string ->
  string

val append_trait_clause : base:string -> clause:string -> string

val apply_self_model_drift :
  meta:Keeper_types.keeper_meta ->
  user_message:string ->
  work_kind:string ->
  Keeper_types.keeper_meta * bool * string option

val proactive_prompt_for_keeper :
  meta:Keeper_types.keeper_meta ->
  idle_seconds:int ->
  Keeper_memory.keeper_state_snapshot option ->
  string ->
  string

type proactive_generation_result = {
  reply: string;
  usage: Agent_sdk.Types.api_usage;
  model_used: string;
  latency_ms: int;
  attempts: int;
  total_cost_usd: float;
  fallback_applied: bool;
  tools_used: string list;
}

val proactive_retry_instruction : int -> reason:string -> string

val proactive_temperature : cascade_name:string -> int -> float

(** {1 Text Processing and Proactive Quality Checks}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing

(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

val exact_direct_mention_present : targets:string list -> string -> bool

val keeper_constitution : string

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
  usage: Masc_model.token_usage;
  model_used: string;
  latency_ms: int;
  attempts: int;
  total_cost_usd: float;
  fallback_applied: bool;
  tools_used: string list;
}

val proactive_retry_instruction : int -> reason:string -> string

val proactive_temperature : int -> float

val strip_state_blocks_text : string -> string

val trim_to_option : string -> string option

val state_snapshot_reply_fallback :
  Keeper_memory.keeper_state_snapshot option -> string option

val strip_internal_reply_markup : string -> string

val user_visible_reply_text : ?fallback:string -> string -> string

val normalize_proactive_text : string -> string

val extract_checkin_text : string -> string option

val proactive_has_terminal_ending : string -> bool

val proactive_looks_fragmentary : string -> bool

val proactive_fallback_reply :
  meta:Keeper_types.keeper_meta -> idle_seconds:int -> string

val proactive_quality_check : string -> (string, string) result

val looks_fragmentary_history_text : string -> bool

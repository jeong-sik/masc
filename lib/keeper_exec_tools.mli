open Keeper_types

val ensure_keeper_board_post_args :
  author:string -> source:string -> Yojson.Safe.t -> Yojson.Safe.t

val keeper_allowed_tool_names : ?write_done:bool -> keeper_meta -> string list
val keeper_allowed_llm_tools :
  ?write_done:bool -> keeper_meta -> Llm.tool_def list

val execute_keeper_tool_call :
  config:Room.config ->
  meta:keeper_meta ->
  ctx_work:Context_manager.working_context ->
  Llm.tool_call ->
  string

val keeper_tool_loop_system_prompt : character_context:string -> string

val keeper_tool_followup_prompt :
  user_message:string ->
  draft_reply:string ->
  tool_outputs:(Llm.tool_call * string) list ->
  already_executed:string list ->
  string

val memory_correction_prompt :
  user_message:string ->
  first_reply:string ->
  candidate_user_msgs:string list ->
  expected_topic:string option ->
  string

val memory_forced_grounding_prompt :
  user_message:string ->
  first_reply:string ->
  candidate_user_msgs:string list ->
  expected_topic:string option ->
  string

val contains_korean_text : string -> bool
val is_recent_question_query : string -> bool
val has_weather_keyword : string -> bool
val select_recall_candidate :
  user_message:string ->
  expected_topic:string option ->
  best_match:string option ->
  string list ->
  string option
val recall_fallback_reply :
  meta:keeper_meta ->
  user_message:string ->
  selected_question:string ->
  expected_topic:string option ->
  string

val deterministic_recall_fallback :
  meta:keeper_meta ->
  user_message:string ->
  eval:Keeper_memory.memory_recall_eval ->
  candidates:string list ->
  (string * Keeper_memory.memory_recall_eval) option

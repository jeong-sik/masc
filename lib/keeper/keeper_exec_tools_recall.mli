open Keeper_types

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

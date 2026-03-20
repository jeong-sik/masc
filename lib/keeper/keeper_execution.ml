(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, proactive/explicit room behavior, and keepalive runtime.

    Delegates to sub-modules:
    - Keeper_coordination: checkpoint, room presence, compaction
    - Keeper_prompt: system prompts, mention detection, text processing
    - Keeper_exec_autonomy: autonomous goal evaluation and execution
    - Keeper_exec_proactive: proactive emission and deliberation
    - Keeper_exec_social: social board events and explicit room replies *)

[@@@warning "-33"]

open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_tools

include Keeper_coordination
include Keeper_prompt

(* Types re-exported from Keeper_exec_context for .mli compatibility *)
type social_board_event = Keeper_exec_context.social_board_event = {
  kind : [ `Board_post | `Board_comment ];
  post_id : string;
  comment_id : string option;
  author : string;
  post_author : string option;
  content : string;
  created_at : float;
}

type social_turn_outcome = Keeper_exec_context.social_turn_outcome = {
  outcome : [ `Acted | `Passed ];
  summary : string;
  reason : string;
  action_kind : string;
  tools_used : string list;
  decision_reason : string option;
  failure_reason : string option;
}

let memory_check_default_json = Keeper_exec_context.memory_check_default_json

include Keeper_exec_autonomy
include Keeper_exec_proactive
include Keeper_exec_social

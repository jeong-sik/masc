module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_name — Compile-time verified tool identifiers.

    Replaces stringly-typed tool dispatch with exhaustive variant matching.
    Parse boundary: [of_string] at MCP/JSON ingress only.
    Internal code uses [t] directly — typos become compile errors.

    PR-S1 (tool-domain decouple): the Task/Board/Goal/Operator tool *names*
    are owned by domain-scoped submodules ([Task_name], [Board_name],
    [Goal_name], [Operator_name]) instead of being enumerated flat in
    [Masc.t]. The substrate ([Tool_name], [tool_dispatch]) no longer
    hard-codes those domain operation names in a god-enum + static routing
    table. Every MCP tool-name STRING is preserved exactly — each domain
    submodule owns the complete [masc_*] string and [Masc.to_string]/
    [Masc.of_string] compose over the submodules. *)

module Task_name = struct
  type t =
    | Add_task
    | Batch_add_tasks
    | Claim_next
    | Task_history
    | Tasks
    | Transition
    | Update_priority

  let to_string = function
    | Add_task -> "masc_add_task"
    | Batch_add_tasks -> "masc_batch_add_tasks"
    | Claim_next -> "masc_claim_next"
    | Task_history -> "masc_task_history"
    | Tasks -> "masc_tasks"
    | Transition -> "masc_transition"
    | Update_priority -> "masc_update_priority"
  ;;

  let of_string = function
    | "masc_add_task" -> Some Add_task
    | "masc_batch_add_tasks" -> Some Batch_add_tasks
    | "masc_claim_next" -> Some Claim_next
    | "masc_task_history" -> Some Task_history
    | "masc_tasks" -> Some Tasks
    | "masc_transition" -> Some Transition
    | "masc_update_priority" -> Some Update_priority
    | _ -> None
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Board_name = struct
  type t =
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_get
    | Board_hearths
    | Board_list
    | Board_post
    | Board_profile
    | Board_reaction
    | Board_search
    | Board_stats
    | Board_sub_board_create
    | Board_sub_board_delete
    | Board_sub_board_get
    | Board_sub_board_list
    | Board_sub_board_update
    | Board_vote

  let to_string = function
    | Board_cleanup -> "masc_board_cleanup"
    | Board_comment -> "masc_board_comment"
    | Board_comment_vote -> "masc_board_comment_vote"
    | Board_curation_read -> "masc_board_curation_read"
    | Board_curation_submit -> "masc_board_curation_submit"
    | Board_delete -> "masc_board_delete"
    | Board_get -> "masc_board_get"
    | Board_hearths -> "masc_board_hearths"
    | Board_list -> "masc_board_list"
    | Board_post -> "masc_board_post"
    | Board_profile -> "masc_board_profile"
    | Board_reaction -> "masc_board_reaction"
    | Board_search -> "masc_board_search"
    | Board_stats -> "masc_board_stats"
    | Board_sub_board_create -> "masc_board_sub_board_create"
    | Board_sub_board_delete -> "masc_board_sub_board_delete"
    | Board_sub_board_get -> "masc_board_sub_board_get"
    | Board_sub_board_list -> "masc_board_sub_board_list"
    | Board_sub_board_update -> "masc_board_sub_board_update"
    | Board_vote -> "masc_board_vote"
  ;;

  let of_string = function
    | "masc_board_cleanup" -> Some Board_cleanup
    | "masc_board_comment" -> Some Board_comment
    | "masc_board_comment_vote" -> Some Board_comment_vote
    | "masc_board_curation_read" -> Some Board_curation_read
    | "masc_board_curation_submit" -> Some Board_curation_submit
    | "masc_board_delete" -> Some Board_delete
    | "masc_board_get" -> Some Board_get
    | "masc_board_hearths" -> Some Board_hearths
    | "masc_board_list" -> Some Board_list
    | "masc_board_post" -> Some Board_post
    | "masc_board_profile" -> Some Board_profile
    | "masc_board_reaction" -> Some Board_reaction
    | "masc_board_search" -> Some Board_search
    | "masc_board_stats" -> Some Board_stats
    | "masc_board_vote" -> Some Board_vote
    | "masc_board_sub_board_create" -> Some Board_sub_board_create
    | "masc_board_sub_board_delete" -> Some Board_sub_board_delete
    | "masc_board_sub_board_get" -> Some Board_sub_board_get
    | "masc_board_sub_board_list" -> Some Board_sub_board_list
    | "masc_board_sub_board_update" -> Some Board_sub_board_update
    | _ -> None
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Goal_name = struct
  type t =
    | Goal_list
    | Goal_transition
    | Goal_upsert
    | Goal_verify

  let to_string = function
    | Goal_list -> "masc_goal_list"
    | Goal_transition -> "masc_goal_transition"
    | Goal_upsert -> "masc_goal_upsert"
    | Goal_verify -> "masc_goal_verify"
  ;;

  let of_string = function
    | "masc_goal_list" -> Some Goal_list
    | "masc_goal_transition" -> Some Goal_transition
    | "masc_goal_upsert" -> Some Goal_upsert
    | "masc_goal_verify" -> Some Goal_verify
    | _ -> None
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Operator_name = struct
  type t =
    | Operator_action
    | Operator_confirm
    | Operator_digest
    | Operator_snapshot

  let to_string = function
    | Operator_action -> "masc_operator_action"
    | Operator_confirm -> "masc_operator_confirm"
    | Operator_digest -> "masc_operator_digest"
    | Operator_snapshot -> "masc_operator_snapshot"
  ;;

  let of_string = function
    | "masc_operator_action" -> Some Operator_action
    | "masc_operator_confirm" -> Some Operator_confirm
    | "masc_operator_digest" -> Some Operator_digest
    | "masc_operator_snapshot" -> Some Operator_snapshot
    | _ -> None
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

(** Domain_tool — the single domain-owned grouping of Task/Board/Goal/Operator
    tool names, together with the substrate classifications each domain attaches
    to its members.

    PR-S2 (tool⊥domain cut): the Tool substrate must not enumerate domain
    constructors. This module is the ONLY place that destructures
    [Task]/[Board]/[Goal]/[Operator]; [Masc.t] carries it behind one neutral
    arm ([Domain of Domain_tool.t]), and [Tool_dispatch]/[Tool_catalog_inference]
    consume it through [module_tag]/[effect_domain] without spelling any domain
    constructor. The [module_tag] / [effect_domain] result types live in the
    zero-dep leaf [Tool_tag_types], re-exported by the substrate by
    type-equality so external call sites and [.mli] contracts are unchanged.

    Every [masc_*] wire string is preserved: [to_string]/[of_string] delegate to
    the domain submodules, which own the complete strings. *)
module Domain_tool = struct
  type t =
    | Task of Task_name.t
    | Board of Board_name.t
    | Goal of Goal_name.t
    | Operator of Operator_name.t

  let to_string = function
    | Task t -> Task_name.to_string t
    | Board b -> Board_name.to_string b
    | Goal g -> Goal_name.to_string g
    | Operator o -> Operator_name.to_string o
  ;;

  let of_string s =
    (* Domain submodules are tried in turn; each returns [None] for names it
       does not own. The string namespaces are disjoint, so order is
       irrelevant for correctness. *)
    match Task_name.of_string s with
    | Some t -> Some (Task t)
    | None ->
      match Board_name.of_string s with
      | Some b -> Some (Board b)
      | None ->
        match Goal_name.of_string s with
        | Some g -> Some (Goal g)
        | None ->
          match Operator_name.of_string s with
          | Some o -> Some (Operator o)
          | None -> None
  ;;

  let is_board = function
    | Board _ -> true
    | Task _ | Goal _ | Operator _ -> false
  ;;

  (* Dispatch routing tag. Uniform per domain: every member of a domain maps to
     the same tag (Tag alignment proof, PR-S1):
       Task     -> Mod_task     (was 7 arms, all Mod_task)
       Board    -> Mod_inline   (was 20 Board_* arms, all Mod_inline)
       Goal     -> Mod_state    (was 4 Goal_* arms, all Mod_state)
       Operator -> Mod_operator (was 4 Operator_* arms, all Mod_operator) *)
  let module_tag : t -> Tool_tag_types.module_tag = function
    | Task _ -> Tool_tag_types.Mod_task
    | Board _ -> Tool_tag_types.Mod_inline
    | Goal _ -> Tool_tag_types.Mod_state
    | Operator _ -> Tool_tag_types.Mod_operator
  ;;

  (* Inferred effect classification. NON-uniform within Board (Read_only vs
     Masc_workspace) and Operator (three ways), so the mapping is per-member.
     Transcribed member-for-member from the prior flat match in
     [tool_catalog_inference]; exhaustiveness is compiler-enforced. *)
  let effect_domain : t -> Tool_tag_types.effect_domain = function
    | Operator Operator_name.Operator_action -> Tool_tag_types.Host_repo_write
    | Board Board_name.Board_get
    | Board Board_name.Board_curation_read
    | Board Board_name.Board_hearths
    | Board Board_name.Board_list
    | Board Board_name.Board_profile
    | Board Board_name.Board_search
    | Board Board_name.Board_stats
    | Board Board_name.Board_sub_board_get
    | Board Board_name.Board_sub_board_list
    | Goal Goal_name.Goal_list
    | Operator Operator_name.Operator_digest
    | Operator Operator_name.Operator_snapshot
    | Task Task_name.Task_history
    | Task Task_name.Tasks -> Tool_tag_types.Read_only
    | Task Task_name.Add_task
    | Task Task_name.Batch_add_tasks
    | Task Task_name.Claim_next
    | Task Task_name.Transition
    | Task Task_name.Update_priority
    | Board Board_name.Board_cleanup
    | Board Board_name.Board_comment
    | Board Board_name.Board_comment_vote
    | Board Board_name.Board_curation_submit
    | Board Board_name.Board_delete
    | Board Board_name.Board_post
    | Board Board_name.Board_reaction
    | Board Board_name.Board_sub_board_create
    | Board Board_name.Board_sub_board_delete
    | Board Board_name.Board_sub_board_update
    | Board Board_name.Board_vote
    | Goal Goal_name.Goal_transition
    | Goal Goal_name.Goal_upsert
    | Goal Goal_name.Goal_verify
    | Operator Operator_name.Operator_confirm -> Tool_tag_types.Masc_workspace
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Masc = struct
  (* Domain tool-NAME operations (Task/Board/Goal/Operator) are owned by
     [Domain_tool]; [Masc.t] carries them behind one neutral [Domain] arm so
     the Tool substrate never enumerates domain constructors. The remaining
     variants are admin/lifecycle/misc tool names that have no domain owner
     and stay flat here. *)
  type t =
    | Domain of Domain_tool.t
    | Agent_fitness
    | Agent_update
    | Agent_card
    | Agents
    | Broadcast
    | Check
    | Cleanup_zombies
    | Dashboard
    | Deliver
    | Heartbeat
    | Messages
    | Note_add
    | Plan_clear_task
    | Plan_get
    | Plan_get_task
    | Plan_init
    | Plan_set_task
    | Plan_update
    | Reset
    | Status
    | Tool_help
    | Web_fetch
    | Web_search
    | Config
    | Gc
    | Get_metrics
    | Mcp_session
    | Pause
    | Resume
    | Start
    | Tool_admin_snapshot
    | Tool_admin_update
    | Tool_stats

  let to_string = function
    | Domain d -> Domain_tool.to_string d
    | Agent_fitness -> "masc_agent_fitness"
    | Agent_update -> "masc_agent_update"
    | Agent_card -> "masc_agent_card"
    | Agents -> "masc_agents"
    | Broadcast -> "masc_broadcast"
    | Check -> "masc_check"
    | Cleanup_zombies -> "masc_cleanup_zombies"
    | Dashboard -> "masc_dashboard"
    | Deliver -> "masc_deliver"
    | Heartbeat -> "masc_heartbeat"
    | Messages -> "masc_messages"
    | Note_add -> "masc_note_add"
    | Plan_clear_task -> "masc_plan_clear_task"
    | Plan_get -> "masc_plan_get"
    | Plan_get_task -> "masc_plan_get_task"
    | Plan_init -> "masc_plan_init"
    | Plan_set_task -> "masc_plan_set_task"
    | Plan_update -> "masc_plan_update"
    | Reset -> "masc_reset"
    | Status -> "masc_status"
    | Tool_help -> "masc_tool_help"
    | Web_fetch -> "masc_web_fetch"
    | Web_search -> "masc_web_search"
    | Config -> "masc_config"
    | Gc -> "masc_gc"
    | Get_metrics -> "masc_get_metrics"
    | Mcp_session -> "masc_session"
    | Pause -> "masc_pause"
    | Resume -> "masc_resume"
    | Start -> "masc_start"
    | Tool_admin_snapshot -> "masc_tool_admin_snapshot"
    | Tool_admin_update -> "masc_tool_admin_update"
    | Tool_stats -> "masc_tool_stats"
  ;;

  let of_string s =
    (* Domain names resolve through [Domain_tool]; its [of_string] returns
       [None] for non-domain names, so the flat fallthrough resolves the
       remainder. The string namespaces are disjoint, so order is irrelevant
       for correctness. *)
    match Domain_tool.of_string s with
    | Some d -> Some (Domain d)
    | None ->
            match s with
            | "masc_agent_fitness" -> Some Agent_fitness
            | "masc_agent_update" -> Some Agent_update
            | "masc_agent_card" -> Some Agent_card
            | "masc_agents" -> Some Agents
            | "masc_broadcast" -> Some Broadcast
            | "masc_check" -> Some Check
            | "masc_cleanup_zombies" -> Some Cleanup_zombies
            | "masc_dashboard" -> Some Dashboard
            | "masc_deliver" -> Some Deliver
            | "masc_heartbeat" -> Some Heartbeat
            | "masc_messages" -> Some Messages
            | "masc_note_add" -> Some Note_add
            | "masc_plan_clear_task" -> Some Plan_clear_task
            | "masc_plan_get" -> Some Plan_get
            | "masc_plan_get_task" -> Some Plan_get_task
            | "masc_plan_init" -> Some Plan_init
            | "masc_plan_set_task" -> Some Plan_set_task
            | "masc_plan_update" -> Some Plan_update
            | "masc_reset" -> Some Reset
            | "masc_status" -> Some Status
            | "masc_tool_help" -> Some Tool_help
            | "masc_web_fetch" -> Some Web_fetch
            | "masc_web_search" -> Some Web_search
            | "masc_config" -> Some Config
            | "masc_gc" -> Some Gc
            | "masc_get_metrics" -> Some Get_metrics
            | "masc_session" -> Some Mcp_session
            | "masc_pause" -> Some Pause
            | "masc_resume" -> Some Resume
            | "masc_start" -> Some Start
            | "masc_tool_admin_snapshot" -> Some Tool_admin_snapshot
            | "masc_tool_admin_update" -> Some Tool_admin_update
            | "masc_tool_stats" -> Some Tool_stats
            | _ -> None
  ;;

  let is_board = function
    | Domain d -> Domain_tool.is_board d
    (* Flat admin/lifecycle/misc tool names are never board tools. The [Domain]
       arm above is explicit, so this wildcard covers only the non-domain
       admin variants — it does not mask a domain constructor. *)
    | _ -> false
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

type t =
  | Masc of Masc.t

let to_string = function
  | Masc m -> Masc.to_string m
;;

let of_string s =
  match Masc.of_string s with
  | Some m -> Some (Masc m)
  | None -> None
;;

let pp fmt t = Format.pp_print_string fmt (to_string t)

let is_masc = function
  | Masc _ -> true
;;

let is_board = function
  | Masc m -> Masc.is_board m
;;

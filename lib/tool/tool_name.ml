(** Tool_name — the tool-name vocabularies, one closed type per domain.

    Each submodule owns the complete [masc_*] string for its operations:
    [all] is derived by [@@deriving enumerate], [to_string] is an exhaustive
    match, and [of_string] is derived from [all] so it can never fall behind
    a constructor.

    Routing parses the wire string once with the owning domain's [of_string]
    and then matches the constructors, so a constructor added here is a
    compile error at the site that must handle it:

    - [Task_name]     — [Tool_task.dispatch_task_name]
    - [Board_name]    — [Board_tool_dispatch.handle_tool]
    - [Goal_name]     — [Tool_workspace.goal_handler]
    - [Operator_name] — [Operator_tool.dispatch]

    Non-domain [masc_*] names are owned by their schema/descriptor modules,
    not by this substrate. *)

module Task_name = struct
  type t =
    | Add_task
    | Batch_add_tasks
    | Task_history
    | Task_set_goal
    | Tasks
    | Transition
    | Update_priority
  [@@deriving enumerate]

  let to_string = function
    | Add_task -> "masc_add_task"
    | Batch_add_tasks -> "masc_batch_add_tasks"
    | Task_history -> "masc_task_history"
    | Task_set_goal -> "masc_task_set_goal"
    | Tasks -> "masc_tasks"
    | Transition -> "masc_transition"
    | Update_priority -> "masc_update_priority"
  ;;

  let of_string value =
    List.find_opt (fun name -> String.equal value (to_string name)) all
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Board_name = struct
  type t =
    | Board_post
    | Board_post_update
    | Board_list
    | Board_post_get
    | Board_comment
    | Board_vote
    | Board_stats
    | Board_search
    | Board_comment_vote
    | Board_reaction
    | Board_profile
    | Board_hearths
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_cleanup
    | Board_sub_board_create
    | Board_sub_board_list
    | Board_sub_board_get
    | Board_sub_board_update
    | Board_sub_board_delete
  [@@deriving enumerate]

  let operation_name = function
    | Board_cleanup -> "cleanup"
    | Board_comment -> "comment"
    | Board_comment_vote -> "comment_vote"
    | Board_curation_read -> "curation_read"
    | Board_curation_submit -> "curation_submit"
    | Board_delete -> "delete"
    | Board_post_get -> "post_get"
    | Board_hearths -> "hearths"
    | Board_list -> "list"
    | Board_post -> "post"
    | Board_post_update -> "post_update"
    | Board_profile -> "profile"
    | Board_reaction -> "reaction"
    | Board_search -> "search"
    | Board_stats -> "stats"
    | Board_sub_board_create -> "sub_board_create"
    | Board_sub_board_delete -> "sub_board_delete"
    | Board_sub_board_get -> "sub_board_get"
    | Board_sub_board_list -> "sub_board_list"
    | Board_sub_board_update -> "sub_board_update"
    | Board_vote -> "vote"
  ;;

  let to_string name = "masc_board_" ^ operation_name name

  let of_string value =
    List.find_opt (fun name -> String.equal value (to_string name)) all
  ;;

  let is_resource_write = function
    | Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_curation_submit
    | Board_delete
    | Board_post
    | Board_post_update
    | Board_reaction
    | Board_sub_board_create
    | Board_sub_board_delete
    | Board_sub_board_update
    | Board_vote -> true
    | Board_curation_read
    | Board_post_get
    | Board_hearths
    | Board_list
    | Board_profile
    | Board_search
    | Board_stats
    | Board_sub_board_get
    | Board_sub_board_list -> false
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Goal_name = struct
  type t =
    | Goal_list
    | Goal_transition
    | Goal_upsert
  [@@deriving enumerate]

  let to_string = function
    | Goal_list -> "masc_goal_list"
    | Goal_transition -> "masc_goal_transition"
    | Goal_upsert -> "masc_goal_upsert"
  ;;

  let of_string value =
    List.find_opt (fun name -> String.equal value (to_string name)) all
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Keeper_name = struct
  type t =
    | Keeper_audit
    | Keeper_clear
    | Keeper_delegate
    | Keeper_delegate_cancel
    | Keeper_delegate_list
    | Keeper_delegate_status
    | Keeper_down
    | Keeper_list
    | Keeper_msg
    | Keeper_reset
    | Keeper_sandbox_start
    | Keeper_sandbox_stop
    | Keeper_status
    | Keeper_up
  [@@deriving enumerate]

  let to_string = function
    | Keeper_audit -> "masc_keeper_audit"
    | Keeper_clear -> "masc_keeper_clear"
    | Keeper_delegate -> "masc_keeper_delegate"
    | Keeper_delegate_cancel -> "masc_keeper_delegate_cancel"
    | Keeper_delegate_list -> "masc_keeper_delegate_list"
    | Keeper_delegate_status -> "masc_keeper_delegate_status"
    | Keeper_down -> "masc_keeper_down"
    | Keeper_list -> "masc_keeper_list"
    | Keeper_msg -> "masc_keeper_msg"
    | Keeper_reset -> "masc_keeper_reset"
    | Keeper_sandbox_start -> "masc_keeper_sandbox_start"
    | Keeper_sandbox_stop -> "masc_keeper_sandbox_stop"
    | Keeper_status -> "masc_keeper_status"
    | Keeper_up -> "masc_keeper_up"
  ;;

  let of_string value =
    List.find_opt (fun name -> String.equal value (to_string name)) all
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Operator_name = struct
  type t =
    | Operator_action
    | Operator_board_attention_quarantine_requeue
    | Operator_confirm
    | Operator_digest
    | Operator_judgment_write
    | Operator_snapshot
    | Operator_task_recovery_resolve
  [@@deriving enumerate]

  let to_string = function
    | Operator_action -> "masc_operator_action"
    | Operator_board_attention_quarantine_requeue ->
      "masc_operator_board_attention_quarantine_requeue"
    | Operator_confirm -> "masc_operator_confirm"
    | Operator_digest -> "masc_operator_digest"
    | Operator_judgment_write -> "masc_operator_judgment_write"
    | Operator_snapshot -> "masc_operator_snapshot"
    | Operator_task_recovery_resolve -> "masc_operator_task_recovery_resolve"
  ;;

  let of_string value =
    List.find_opt (fun name -> String.equal value (to_string name)) all
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end


(** Domain_tool — the single domain-owned grouping of Task/Board/Goal/Operator
    tool names.

    This module owns only name construction and string round-tripping. Dispatch
    and execution decisions are supplied by their explicit boundaries instead
    of being inferred from this typed name carrier. *)

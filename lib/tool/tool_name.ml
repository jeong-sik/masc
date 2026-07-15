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
    | Task_history
    | Tasks
    | Transition
    | Update_priority

  let to_string = function
    | Add_task -> "masc_add_task"
    | Batch_add_tasks -> "masc_batch_add_tasks"
    | Task_history -> "masc_task_history"
    | Tasks -> "masc_tasks"
    | Transition -> "masc_transition"
    | Update_priority -> "masc_update_priority"
  ;;

  let of_string = function
    | "masc_add_task" -> Some Add_task
    | "masc_batch_add_tasks" -> Some Batch_add_tasks
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

  let to_string = function
    | Goal_list -> "masc_goal_list"
    | Goal_transition -> "masc_goal_transition"
    | Goal_upsert -> "masc_goal_upsert"
  ;;

  let of_string = function
    | "masc_goal_list" -> Some Goal_list
    | "masc_goal_transition" -> Some Goal_transition
    | "masc_goal_upsert" -> Some Goal_upsert
    | _ -> None
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Operator_name = struct
  type t =
    | Operator_action
    | Operator_chat_recovery_resolve
    | Operator_confirm
    | Operator_digest
    | Operator_snapshot

  let to_string = function
    | Operator_action -> "masc_operator_action"
    | Operator_chat_recovery_resolve -> "masc_operator_chat_recovery_resolve"
    | Operator_confirm -> "masc_operator_confirm"
    | Operator_digest -> "masc_operator_digest"
    | Operator_snapshot -> "masc_operator_snapshot"
  ;;

  let of_string = function
    | "masc_operator_action" -> Some Operator_action
    | "masc_operator_chat_recovery_resolve" -> Some Operator_chat_recovery_resolve
    | "masc_operator_confirm" -> Some Operator_confirm
    | "masc_operator_digest" -> Some Operator_digest
    | "masc_operator_snapshot" -> Some Operator_snapshot
    | _ -> None
  ;;

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Operator_remote_name = struct
  type t = Operator_tool of Operator_name.t

  let to_string = function
    | Operator_tool tool -> Operator_name.to_string tool
  ;;

  let of_string value =
    match Operator_name.of_string value with
    | Some tool -> Some (Operator_tool tool)
    | None -> None
  ;;

  let all =
    [ Operator_tool Operator_name.Operator_snapshot
    ; Operator_tool Operator_name.Operator_digest
    ; Operator_tool Operator_name.Operator_action
    ; Operator_tool Operator_name.Operator_chat_recovery_resolve
    ; Operator_tool Operator_name.Operator_confirm
    ]
  ;;

  let all_strings = List.map to_string all
  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

(** Domain_tool — the single domain-owned grouping of Task/Board/Goal/Operator
    tool names.

    This module owns only name construction and string round-tripping. Dispatch
    and execution decisions are supplied by their explicit boundaries instead
    of being inferred from this typed name carrier. *)
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

  let pp fmt t = Format.pp_print_string fmt (to_string t)
end

module Masc = struct
  (* Domain tool-NAME operations (Task/Board/Goal/Operator) are owned by
     [Domain_tool]; [Masc.t] carries them behind one neutral [Domain] arm so
     the Tool substrate never enumerates domain constructors. Non-domain
     public masc_* names are owned by their schema/descriptor modules instead
     of this typed substrate. *)
  type t =
    | Domain of Domain_tool.t

  let to_string = function
    | Domain d -> Domain_tool.to_string d
  ;;

  let of_string s =
    match Domain_tool.of_string s with
    | Some d -> Some (Domain d)
    | None -> None
  ;;

  let is_board = function
    | Domain d -> Domain_tool.is_board d
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

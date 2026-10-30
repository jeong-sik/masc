(* Typed vocabulary for Keeper task runtime adapters.

   This lives outside the central [Tool_name] module so the tool dispatch
   substrate stays keeper-agnostic: the substrate routes
   opaque tool names and the keeper subsystem owns the typed vocabulary of its
   own tools. Dependency direction is keeper -> tool, never the reverse.

   The SSOT is on the keeper side of the Tool/Keeper boundary. Board names are
   owned by [Tool_name.Board_name]. *)

type t =
  | Broadcast
  | Task_claim
  | Task_create
  | Task_done
  | Task_cancel
  | Task_release
  | Tasks_audit
  | Tasks_list

let to_string = function
  | Broadcast -> "keeper_broadcast"
  | Task_claim -> "keeper_task_claim"
  | Task_create -> "keeper_task_create"
  | Task_done -> "keeper_task_done"
  | Task_cancel -> "keeper_task_cancel"
  | Task_release -> "keeper_task_release"
  | Tasks_audit -> "keeper_tasks_audit"
  | Tasks_list -> "keeper_tasks_list"
;;

let of_string = function
  | "keeper_broadcast" -> Some Broadcast
  | "keeper_task_claim" -> Some Task_claim
  | "keeper_task_create" -> Some Task_create
  | "keeper_task_done" -> Some Task_done
  | "keeper_task_cancel" -> Some Task_cancel
  | "keeper_task_release" -> Some Task_release
  | "keeper_tasks_audit" -> Some Tasks_audit
  | "keeper_tasks_list" -> Some Tasks_list
  | _ -> None
;;

let pp fmt t = Format.pp_print_string fmt (to_string t)
;;

(** RFC-0267 Phase 1 — registry goal_id projection onto the /execution wire.

    The task record carries no goal_id (the goal_task_links registry is SSOT).
    [Dashboard_execution.task_json] projects a canonical goal_id per task from
    the task→goals index so the Work board can nest jobs under goals. These
    tests pin that projection without booting Eio. *)

open Alcotest
open Masc_domain

module DE = Dashboard_execution
module WGI = Workspace_goal_index

let make_task ~id =
  { id
  ; title = "Task " ^ id
  ; description = ""
  ; task_status = Todo
  ; priority = 3
  ; files = []
  ; created_at = "2026-06-20T00:00:00Z"
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let index pairs =
  let h = Hashtbl.create 8 in
  List.iter (fun (k, v) -> Hashtbl.replace h k v) pairs;
  h
;;

let index_from_registry goal_task_links =
  WGI.build_task_goal_index ~goal_task_links ()
;;

(* Extract the projected goal_id field from a serialized task. *)
let goal_id_of json =
  let open Yojson.Safe.Util in
  match json |> member "goal_id" with
  | `Null -> None
  | `String s -> Some s
  | _ -> Some "<non-string>"
;;

let test_linked_task_projects_goal_id () =
  let idx = index_from_registry [ "goal-a", [ "task-1" ] ] in
  let j = DE.task_json ~goal_task_index:idx (make_task ~id:"task-1") in
  check (option string) "linked task carries its goal_id" (Some "goal-a") (goal_id_of j)
;;

let test_unlinked_task_projects_null () =
  let idx = index_from_registry [ "goal-a", [ "task-1" ] ] in
  let j = DE.task_json ~goal_task_index:idx (make_task ~id:"task-2") in
  check (option string) "task absent from index -> goal_id null" None (goal_id_of j)
;;

let test_empty_link_list_projects_null () =
  let idx = index [ "task-1", [] ] in
  let j = DE.task_json ~goal_task_index:idx (make_task ~id:"task-1") in
  check (option string) "empty link list -> goal_id null" None (goal_id_of j)
;;

let test_multi_goal_projects_first () =
  (* Legacy registry rows may link a task to >1 goal; the projection is
     deterministic (first registry match) and the board adopts a single-goal
     model. This must go through the production index builder so the test pins
     the persisted link-order semantics rather than a hand-built list. *)
  let idx =
    index_from_registry
      [ "goal-a", [ "task-1" ]; "goal-b", [ "task-1" ]; "goal-c", [ "task-1" ] ]
  in
  let j = DE.task_json ~goal_task_index:idx (make_task ~id:"task-1") in
  check
    (option string)
    "multi-goal task -> deterministic first registry goal"
    (Some "goal-a")
    (goal_id_of j)
;;

(* Several goals is ordinary data, not a defect: a goal is a north-star
   measure and a task may relate to none, one, or several. The board still
   nests under one heading, so the projection stays stable across refreshes;
   it just has nothing to report. *)
let test_multi_goal_projection_is_stable () =
  let idx = index_from_registry [ "goal-a", [ "task-9" ]; "goal-b", [ "task-9" ] ] in
  let task = make_task ~id:"task-9" in
  let first = DE.task_json ~goal_task_index:idx task in
  let second = DE.task_json ~goal_task_index:idx task in
  check (option string) "first projection" (Some "goal-a") (goal_id_of first);
  check (option string) "second projection" (Some "goal-a") (goal_id_of second)
;;

let () =
  run
    "dashboard_goal_id_projection"
    [ ( "RFC-0267 Phase 1"
      , [ test_case "linked task projects goal_id" `Quick test_linked_task_projects_goal_id
        ; test_case "unlinked task projects null" `Quick test_unlinked_task_projects_null
        ; test_case "empty link list projects null" `Quick test_empty_link_list_projects_null
        ; test_case
            "multi-goal projects deterministic first registry goal"
            `Quick
            test_multi_goal_projects_first
        ; test_case "multi-goal projection is stable" `Quick
            test_multi_goal_projection_is_stable
        ] )
    ]
;;

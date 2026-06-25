(** Workspace_task_create — Dedup logic, add_task, batch_add_tasks.

    Extracted from Workspace_task to separate task creation from classification,
    claiming, and transitions.  All bindings are re-exported by [Workspace_task]
    via [include Workspace_task_create]. *)

open Masc_domain
include Workspace_utils
include Workspace_state
open Workspace_backlog
open Workspace_task_id
include Workspace_broadcast
open Workspace_backlog
open Workspace_task_id

(** Normalize title for deduplication: lowercase, keep only alphanumeric+space.
    Deterministic string transform — no LLM involved. *)
let normalize_title_for_dedup (title : string) : string =
  let buf = Buffer.create (String.length title) in
  String.iter
    (fun c ->
       let lc = Char.lowercase_ascii c in
       if (lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9') || lc = ' '
       then Buffer.add_char buf lc)
    title;
  Buffer.contents buf |> String.trim
;;

(** Check if a task with a similar title already exists in the backlog.
    Returns [Some existing_task_id] if a duplicate is found, [None] otherwise.
    Uses normalized title comparison — deterministic, no fuzzy matching. *)
let find_duplicate_task (backlog : backlog) ~(title : string)
  : string option
  =
  let norm = normalize_title_for_dedup title in
  if norm = ""
  then None
  else
    List.find_opt
      (fun (t : task) ->
         let t_norm = normalize_title_for_dedup t.title in
         t_norm = norm
         && not (Masc_domain.task_status_is_terminal t.task_status))
      backlog.tasks
    |> Option.map (fun (t : task) -> t.id)
;;

type add_task_success =
  { task_id : string
  ; summary : string
  ; title : string
  ; priority : int
  ; description : string
  ; goal_id : string option
  }

type add_task_error =
  | Backlog_read_failed of string
  | Rejected of string
  | Duplicate of { title : string; existing_id : string }
  | Unexpected_error of string

type batch_add_tasks_success =
  { task_ids : string list
  ; summary : string
  ; count : int
  }

type batch_add_tasks_error =
  | Batch_backlog_read_failed of string
  | Batch_unexpected_error of string

let add_task_error_to_string = function
  | Backlog_read_failed msg -> Printf.sprintf "Error: %s" msg
  | Rejected msg -> Printf.sprintf "Error: %s" msg
  | Duplicate { title; existing_id } ->
    Printf.sprintf
      "Duplicate rejected: '%s' matches existing %s. Use that task instead."
      title
      existing_id
  | Unexpected_error msg -> Printf.sprintf "Error: %s" msg
;;

let batch_add_tasks_error_to_string = function
  | Batch_backlog_read_failed msg -> Printf.sprintf "Error adding batch tasks: %s" msg
  | Batch_unexpected_error msg -> Printf.sprintf "Error adding batch tasks: %s" msg
;;

(** Add task — file-locked to prevent task ID collision under concurrency.
    Rejects tasks with duplicate titles (exact match after normalization)
    to prevent the same work from being created multiple times. *)
let add_task_with_result
      ?contract
      ?goal_id
      ?created_by
      ?reject_if
      config
      ~title
      ~priority
      ~description
  =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  let goal_id = Workspace_task_classify.trim_opt goal_id in
  try
    with_file_lock config backlog_path (fun () ->
      match read_backlog_r config with
      | Error msg -> Error (Backlog_read_failed msg)
      | Ok backlog ->
        (match reject_if with
         | Some reject_if -> reject_if backlog
         | None -> None)
        |> (function
          | Some msg -> Error (Rejected msg)
          | None ->
            (* Dedup guard: reject if an active task with the same normalized title exists *)
            (match find_duplicate_task backlog ~title with
             | Some existing_id -> Error (Duplicate { title; existing_id })
             | None ->
               let task_id =
                 Printf.sprintf "task-%03d" (next_task_number config backlog)
               in
               let contract =
                 Some
                   (Workspace_task_classify.ensure_task_contract_for_verification
                      ?contract
                      ~title
                      ~description
                      ())
               in
               let new_task =
                 { id = task_id
                 ; title
                 ; description
                 ; task_status = Todo
                 ; priority
                 ; files = []
                 ; created_at = now_iso ()
                 ; created_by
                 ; contract
                 ; handoff_context = None
                 ; cycle_count = 0
                 ; reclaim_policy = None
                 ; do_not_reclaim_reason = None
                 }
               in
               let new_backlog =
                 { tasks = backlog.tasks @ [ new_task ]
                 ; last_updated = now_iso ()
                 ; version = backlog.version + 1
                 }
               in
               write_backlog config new_backlog;
               let link_result =
                 match goal_id with
                 | None -> Ok ()
                 | Some goal_id ->
                   Workspace_goal_index.link_task_to_goal_result
                     config
                     ~goal_id
                     ~task_id
               in
               let rollback_link_error msg =
                 write_backlog config backlog;
                 Error (Unexpected_error msg)
               in
               (match link_result with
                | Error (Workspace_goal_index.Link_registry_unreadable msg) ->
                  rollback_link_error
                    (Printf.sprintf
                       "Error: goal_task_links update failed after task create; \
                        rolled back %s: %s"
                       task_id
                       msg)
                | Error (Workspace_goal_index.Link_already_assigned existing_goal_ids) ->
                  rollback_link_error
                    (Printf.sprintf
                       "Error: goal_task_links update failed after task create; \
                        rolled back %s because it is already linked to [%s]"
                       task_id
                       (String.concat ", " existing_goal_ids))
                | Error Workspace_goal_index.Link_unknown_task ->
                  rollback_link_error
                    (Printf.sprintf
                       "Error: goal_task_links update failed after task create; \
                        rolled back %s because the task was unknown"
                       task_id)
                | Error Workspace_goal_index.Link_unknown_goal ->
                  rollback_link_error
                    (Printf.sprintf
                       "Error: goal_task_links update failed after task create; \
                        rolled back %s because the goal was unknown"
                       task_id)
                | Ok () ->
                  let created_by_json = Json_util.string_opt_to_json created_by in
                  Workspace_task_classify.emit_task_activity
                    config
                    ~agent_name:actor
                    ~task_id
                    ~kind:(Event_kind.Task.to_string Event_kind.Task.Created)
                    ~payload:
                      (`Assoc
                          [ "task_id", `String task_id
                          ; "title", `String title
                          ; "goal_id", Json_util.string_opt_to_json goal_id
                          ; "priority", `Int priority
                          ; "created_by", created_by_json
                          ; ( "strict_contract"
                            , `Bool
                                (match contract with
                                 | Some contract -> contract.strict
                                 | None -> false) )
                          ]);
                  (Atomic.get Workspace_hooks.on_task_mutation_fn) ();
                  let _ =
                    broadcast
                      config
                      ~from_agent:actor
                      ~content:(Printf.sprintf "New quest: %s" title)
                  in
                  let summary = Printf.sprintf "Added %s: %s" task_id title in
                  Ok { task_id; summary; title; priority; description; goal_id }))))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Unexpected_error (Printexc.to_string e))
;;

let add_task ?contract ?goal_id ?created_by ?reject_if config ~title ~priority
    ~description =
  match
    add_task_with_result
      ?contract
      ?goal_id
      ?created_by
      ?reject_if
      config
      ~title
      ~priority
      ~description
  with
  | Ok created -> created.summary
  | Error err -> add_task_error_to_string err
;;

(** Add multiple tasks in a batch *)
let batch_add_tasks_internal_with_result ?created_by config tasks =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg -> Error (Batch_backlog_read_failed msg)
    | Ok backlog ->
      (try
         let next_num = ref (next_task_number config backlog) in
         let added_tasks_with_goal_ids =
           List.map
             (fun (title, priority, description, contract, goal_id) ->
                let task_id = Printf.sprintf "task-%03d" !next_num in
                incr next_num;
                let contract =
                  Some
                    (Workspace_task_classify.ensure_task_contract_for_verification
                       ?contract
                       ~title
                       ~description
                       ())
                in
                let task =
                  { id = task_id
                  ; title
                  ; description
                  ; task_status = Todo
                  ; priority
                  ; files = []
                  ; created_at = now_iso ()
                  ; created_by
                  ; contract
                  ; handoff_context = None
                  ; cycle_count = 0
                  ; reclaim_policy = None
                  ; do_not_reclaim_reason = None
                  }
                in
                (task, goal_id))
             tasks
         in
         let added_tasks = List.map fst added_tasks_with_goal_ids in
         let new_backlog =
           { tasks = backlog.tasks @ added_tasks
           ; last_updated = now_iso ()
           ; version = backlog.version + 1
           }
         in
         write_backlog config new_backlog;
         let link_result =
           Workspace_goal_index.link_tasks_to_goals_result
             config
             (List.map
                (fun ((task : Masc_domain.task), goal_id) -> task.id, goal_id)
                added_tasks_with_goal_ids)
         in
         let rollback_link_error msg =
           write_backlog config backlog;
           Error (Batch_unexpected_error msg)
         in
         (match link_result with
          | Error (Workspace_goal_index.Link_registry_unreadable msg) ->
            rollback_link_error
              (Printf.sprintf
                 "Error adding batch tasks: goal_task_links update failed after \
                  task create; rolled back batch: %s"
                 msg)
          | Error (Workspace_goal_index.Link_already_assigned existing_goal_ids) ->
            rollback_link_error
              (Printf.sprintf
                 "Error adding batch tasks: goal_task_links update failed after \
                  task create; rolled back batch because a task is already linked \
                  to [%s]"
                 (String.concat ", " existing_goal_ids))
          | Error Workspace_goal_index.Link_unknown_task ->
            rollback_link_error
              "Error adding batch tasks: goal_task_links update failed after task \
               create; rolled back batch because a task was unknown"
          | Error Workspace_goal_index.Link_unknown_goal ->
            rollback_link_error
              "Error adding batch tasks: goal_task_links update failed after task \
               create; rolled back batch because a goal was unknown"
          | Ok () ->
         List.iter
           (fun ((task : Masc_domain.task), goal_id) ->
              let created_by_json = Json_util.string_opt_to_json task.created_by in
              Workspace_task_classify.emit_task_activity
                config
                ~agent_name:actor
                ~task_id:task.id
                ~kind:(Event_kind.Task.to_string Event_kind.Task.Created)
                ~payload:
                  (`Assoc
                      [ "task_id", `String task.id
                      ; "title", `String task.title
                      ; "goal_id", Json_util.string_opt_to_json goal_id
                      ; "priority", `Int task.priority
                      ; "created_by", created_by_json
                      ; ( "strict_contract"
                        , `Bool
                            (match task.contract with
                             | Some contract -> contract.strict
                             | None -> false) )
                      ]))
           added_tasks_with_goal_ids;
         let summary =
           String.concat ", " (List.map (fun (t : Masc_domain.task) -> t.id) added_tasks)
         in
         (Atomic.get Workspace_hooks.on_task_mutation_fn) ();
         let msg =
           Printf.sprintf
             "New batch of %d quests added: %s"
             (List.length added_tasks)
             summary
         in
         let _ = broadcast config ~from_agent:actor ~content:msg in
         let count = List.length added_tasks in
         let task_ids = List.map (fun (task : Masc_domain.task) -> task.id) added_tasks in
         let summary = Printf.sprintf "Added %d tasks: %s" count summary in
         Ok { task_ids; summary; count })
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Error (Batch_unexpected_error (Printexc.to_string e)))
  )
;;

let batch_add_tasks_internal ?created_by config tasks =
  match batch_add_tasks_internal_with_result ?created_by config tasks with
  | Ok created -> created.summary
  | Error err -> batch_add_tasks_error_to_string err
;;

let batch_add_tasks ?created_by config tasks =
  batch_add_tasks_internal
    ?created_by
    config
    (List.map
       (fun (title, priority, description, goal_id) ->
          title, priority, description, None, goal_id)
       tasks)
;;

let batch_add_tasks_with_contracts ?created_by config tasks =
  batch_add_tasks_internal ?created_by config tasks
;;

let batch_add_tasks_with_contracts_result ?created_by config tasks =
  batch_add_tasks_internal_with_result ?created_by config tasks
;;

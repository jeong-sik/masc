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
  }

type add_task_error =
  | Backlog_read_failed of string
  | Rejected of string
  | Duplicate of { title : string; existing_id : string }
  | Backlog_write_failed of string
  | Unexpected_error of string
  | Unknown_predecessor of string
  | Predecessor_not_terminal of { predecessor_task_id : string; status : string }

type batch_add_tasks_success =
  { task_ids : string list
  ; summary : string
  ; count : int
  }

type batch_add_tasks_error =
  | Batch_backlog_read_failed of string
  | Batch_backlog_write_failed of string
  | Batch_unexpected_error of string

let add_task_error_to_string = function
  | Backlog_read_failed msg -> Printf.sprintf "Error: %s" msg
  | Rejected msg -> Printf.sprintf "Error: %s" msg
  | Duplicate { title; existing_id } ->
    Printf.sprintf
      "Duplicate rejected: '%s' matches existing %s. Use that task instead."
      title
      existing_id
  | Backlog_write_failed msg -> Printf.sprintf "Error writing backlog: %s" msg
  | Unexpected_error msg -> Printf.sprintf "Error: %s" msg
  | Unknown_predecessor id ->
    Printf.sprintf
      "Unknown predecessor_task_id '%s': not in the backlog (terminal tasks \
       past the archive cutoff are not linkable)"
      id
  | Predecessor_not_terminal { predecessor_task_id; status } ->
    Printf.sprintf
      "predecessor_task_id '%s' is %s — a re-run link requires a terminal \
       (done/cancelled) predecessor"
      predecessor_task_id
      status
;;

let batch_add_tasks_error_to_string = function
  | Batch_backlog_read_failed msg -> Printf.sprintf "Error adding batch tasks: %s" msg
  | Batch_backlog_write_failed msg -> Printf.sprintf "Error writing batch backlog: %s" msg
  | Batch_unexpected_error msg -> Printf.sprintf "Error adding batch tasks: %s" msg
;;

(** Add task — file-locked to prevent task ID collision under concurrency.
    Rejects tasks with duplicate titles (exact match after normalization)
    to prevent the same work from being created multiple times. *)
let add_task_with_result
      ?contract
      ?created_by
      ?predecessor_task_id
      ?reject_if
      config
      ~title
      ~priority
      ~description
  =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  let predecessor_task_id = Workspace_task_classify.trim_opt predecessor_task_id in
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
        (* RFC-0323 W2: a re-run link must point at an existing, terminal task.
           Validated inside the lock against the same backlog snapshot the new
           task is appended to, so the check cannot race a concurrent write. *)
        (match
           match predecessor_task_id with
           | None -> Ok ()
           | Some pid ->
             (match
                List.find_opt (fun (t : task) -> String.equal t.id pid) backlog.tasks
              with
              | None -> Error (Unknown_predecessor pid)
              | Some p ->
                if task_status_is_terminal p.task_status
                then Ok ()
                else
                  Error
                    (Predecessor_not_terminal
                       { predecessor_task_id = pid
                       ; status = task_status_to_string p.task_status
                       }))
         with
         | Error e -> Error e
         | Ok () ->
        (* Dedup guard: reject if an active task with the same normalized title exists *)
        (match find_duplicate_task backlog ~title with
         | Some existing_id ->
           Error (Duplicate { title; existing_id })
         | None ->
           let task_id = Printf.sprintf "task-%03d" (next_task_number config backlog) in
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
             ; predecessor_task_id
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
           (match write_backlog_result config new_backlog with
              | Error msg -> Error (Backlog_write_failed msg)
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
                          ; "priority", `Int priority
                          ; "created_by", created_by_json
                          ; ( "predecessor_task_id"
                            , Json_util.string_opt_to_json predecessor_task_id )
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
                  Ok { task_id; summary; title; priority; description })))))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Unexpected_error (Printexc.to_string e))
;;

let add_task ?contract ?created_by ?reject_if config ~title ~priority
    ~description =
  match
    add_task_with_result
      ?contract
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
         let added_tasks =
           List.map
             (fun (title, priority, description, contract) ->
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
                  (* batch add does not carry re-run links (RFC-0323 W2 scopes
                     the arg to masc_add_task) *)
                  ; predecessor_task_id = None
                  ; contract
                  ; handoff_context = None
                  ; cycle_count = 0
                  ; reclaim_policy = None
                  ; do_not_reclaim_reason = None
                  }
                in
                task)
             tasks
         in
         let new_backlog =
           { tasks = backlog.tasks @ added_tasks
           ; last_updated = now_iso ()
           ; version = backlog.version + 1
           }
         in
         (match write_backlog_result config new_backlog with
            | Error msg -> Error (Batch_backlog_write_failed msg)
            | Ok () ->
                List.iter
                  (fun (task : Masc_domain.task) ->
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
                             ; "priority", `Int task.priority
                             ; "created_by", created_by_json
                             ; ( "strict_contract"
                               , `Bool
                                   (match task.contract with
                                    | Some contract -> contract.strict
                                    | None -> false) )
                             ]))
                  added_tasks;
                let summary =
                  String.concat
                    ", "
                    (List.map (fun (t : Masc_domain.task) -> t.id) added_tasks)
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
       | e -> Error (Batch_unexpected_error (Printexc.to_string e))))
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
       (fun (title, priority, description) ->
          title, priority, description, None)
       tasks)
;;

let batch_add_tasks_with_contracts ?created_by config tasks =
  batch_add_tasks_internal ?created_by config tasks
;;

let batch_add_tasks_with_contracts_result ?created_by config tasks =
  batch_add_tasks_internal_with_result ?created_by config tasks
;;

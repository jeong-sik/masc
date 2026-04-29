(** Coord_task_create — Dedup logic, add_task, batch_add_tasks.

    Extracted from Coord_task to separate task creation from classification,
    claiming, and transitions.  All bindings are re-exported by [Coord_task]
    via [include Coord_task_create]. *)

open Types
include Coord_utils
include Coord_state
include Coord_broadcast

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
let find_duplicate_task (backlog : backlog) ~(title : string) ~(goal_id : string option)
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
         && Option.equal String.equal t.goal_id goal_id
         && not (Types.task_status_is_terminal t.task_status))
      backlog.tasks
    |> Option.map (fun (t : task) -> t.id)
;;

(** Add task — file-locked to prevent task ID collision under concurrency.
    Rejects tasks with duplicate titles (exact match after normalization)
    to prevent the same work from being created multiple times. *)
let add_task
      ?contract
      ?goal_id
      ?created_by
      config
      ~title
      ~priority
      ~description
  =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  let goal_id = Coord_task_classify.trim_opt goal_id in
  try
    with_file_lock config backlog_path (fun () ->
      match read_backlog_r config with
      | Error msg -> Printf.sprintf "❌ Error: %s" msg
      | Ok backlog ->
        (* Dedup guard: reject if an active task with the same normalized title exists *)
        (match find_duplicate_task backlog ~title ~goal_id with
         | Some existing_id ->
           Printf.sprintf
             "⚠️ Duplicate rejected: '%s' matches existing %s. Use that task instead."
             title
             existing_id
         | None ->
           let task_id = Printf.sprintf "task-%03d" (next_task_number config backlog) in
           let contract =
             Some
               (Coord_task_classify.ensure_task_contract_for_verification
                  ?contract
                  ~title
                  ~description
                  ())
           in
           let new_task =
             { id = task_id
             ; title
             ; description
             ; goal_id
             ; task_status = Todo
             ; priority
             ; files = []
             ; created_at = now_iso ()
             ; created_by
             ; worktree = None
             ; stage = None
             ; contract
             ; handoff_context = None
             ; cycle_count = 0
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
           let created_by_json =
             match created_by with
             | Some value -> `String value
             | None -> `Null
           in
           Coord_task_classify.emit_task_activity
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
           (Atomic.get Coord_hooks.on_task_mutation_fn) ();
           let _ =
             broadcast
               config
               ~from_agent:actor
               ~content:(Printf.sprintf "📋 New quest: %s" title)
           in
           Printf.sprintf "✅ Added %s: %s" task_id title))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
;;

(** Add multiple tasks in a batch *)
let batch_add_tasks_internal ?created_by config tasks =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  let actor = Option.value ~default:"system" created_by in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg -> Printf.sprintf "❌ Error adding batch tasks: %s" msg
    | Ok backlog ->
      (try
         let next_num = ref (next_task_number config backlog) in
         let added_tasks =
           List.map
             (fun (title, priority, description, contract, goal_id) ->
                let task_id = Printf.sprintf "task-%03d" !next_num in
                incr next_num;
                let contract =
                  Some
                    (Coord_task_classify.ensure_task_contract_for_verification
                       ?contract
                       ~title
                       ~description
                       ())
                in
                { id = task_id
                ; title
                ; description
                ; goal_id
                ; task_status = Todo
                ; priority
                ; files = []
                ; created_at = now_iso ()
                ; created_by
                ; worktree = None
                ; stage = None
                ; contract
                ; handoff_context = None
                ; cycle_count = 0
                ; do_not_reclaim_reason = None
                })
             tasks
         in
         let new_backlog =
           { tasks = backlog.tasks @ added_tasks
           ; last_updated = now_iso ()
           ; version = backlog.version + 1
           }
         in
         write_backlog config new_backlog;
         List.iter
           (fun (task : Types.task) ->
              let created_by_json =
                match task.created_by with
                | Some value -> `String value
                | None -> `Null
              in
              Coord_task_classify.emit_task_activity
                config
                ~agent_name:actor
                ~task_id:task.id
                ~kind:(Event_kind.Task.to_string Event_kind.Task.Created)
                ~payload:
                  (`Assoc
                      [ "task_id", `String task.id
                      ; "title", `String task.title
                      ; "goal_id", Json_util.string_opt_to_json task.goal_id
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
           String.concat ", " (List.map (fun (t : Types.task) -> t.id) added_tasks)
         in
         (Atomic.get Coord_hooks.on_task_mutation_fn) ();
         let msg =
           Printf.sprintf
             "📋 New batch of %d quests added: %s"
             (List.length added_tasks)
             summary
         in
         let _ = broadcast config ~from_agent:actor ~content:msg in
         Printf.sprintf "✅ Added %d tasks: %s" (List.length added_tasks) summary
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Printf.sprintf "❌ Error adding batch tasks: %s" (Printexc.to_string e)))
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

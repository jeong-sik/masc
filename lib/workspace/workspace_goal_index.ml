(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Eliminates O(n) linear scans in [validate_goal_completion_ready]
    (workspace_goals.ml) and [open_task_count_for_goal]
    (workspace_task_capacity.ml) by building a Hashtbl-based reverse
    index on demand from explicit goal-task link mappings.

    The index is rebuilt from the current task list and a small persistent
    goal-task link registry. *)

open Masc_domain
open Workspace_utils

let goal_task_links_path config =
  Filename.concat (tasks_dir config) "goal_task_links.json"
;;

let goal_task_links_recovery_path config =
  goal_task_links_path config ^ ".last-good"
;;

let normalize_link_set links =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (goal_id, task_ids) ->
       let goal_id = String.trim goal_id in
       if not (String.equal goal_id "") then (
         let existing = try Hashtbl.find tbl goal_id with Not_found -> [] in
         let merged =
           List.fold_left
             (fun acc task_id ->
                let task_id = String.trim task_id in
                if String.equal task_id "" || List.mem task_id acc then acc
                else task_id :: acc)
             existing
             task_ids
         in
         Hashtbl.replace tbl goal_id merged))
    links;
  Hashtbl.fold
    (fun goal_id task_ids acc -> (goal_id, List.rev task_ids) :: acc)
    tbl
    []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

let link_to_yojson (goal_id, task_ids) =
  `Assoc
    [ "goal_id", `String goal_id
    ; "task_ids", `List (List.map (fun task_id -> `String task_id) task_ids)
    ]
;;

let links_to_yojson links =
  `Assoc
    [ "version", `Int 1
    ; "last_updated", `String (now_iso ())
    ; "links", `List (List.map link_to_yojson (normalize_link_set links))
    ]
;;

let link_of_yojson = function
  | `Assoc fields ->
    let goal_id =
      match List.assoc_opt "goal_id" fields with
      | Some (`String value) -> String.trim value
      | _ -> ""
    in
    let task_ids =
      match List.assoc_opt "task_ids" fields with
      | Some (`List values) ->
        List.filter_map
          (function
            | `String value ->
              let value = String.trim value in
              if String.equal value "" then None else Some value
            | _ -> None)
          values
      | _ -> []
    in
    if String.equal goal_id "" then None else Some (goal_id, task_ids)
  | _ -> None
;;

let links_of_yojson = function
  | `Assoc fields ->
    (match List.assoc_opt "links" fields with
     | Some (`List values) -> normalize_link_set (List.filter_map link_of_yojson values)
     | _ -> [])
  | _ -> []
;;

let read_goal_task_links_r config =
  let primary_path = goal_task_links_path config in
  match read_json_result config primary_path with
  | Ok json -> Ok (links_of_yojson json)
  | Error primary_msg ->
    let recovery_path = goal_task_links_recovery_path config in
    if path_exists config recovery_path
    then
      match read_json_result config recovery_path with
      | Ok json ->
        Log.Misc.warn
          "read_goal_task_links: primary unreadable, recovered from %s (%s)"
          recovery_path
          primary_msg;
        Ok (links_of_yojson json)
      | Error recovery_msg ->
        Error
          (Printf.sprintf
             "%s; recovery read failed for %s: %s"
             primary_msg
             recovery_path
             recovery_msg)
    else if not (path_exists config primary_path)
    then Ok []
    else
      Error
        (Printf.sprintf
           "%s; recovery missing for %s"
           primary_msg
           recovery_path)
;;

let read_goal_task_links config =
  match read_goal_task_links_r config with
  | Ok links -> links
  | Error msg ->
    Log.Misc.warn "read_goal_task_links failed: %s" msg;
    []
;;

let write_goal_task_links config links =
  let json = links_to_yojson links in
  write_json config (goal_task_links_path config) json;
  write_json config (goal_task_links_recovery_path config) json
;;

let write_goal_task_links_result config ~operation links =
  try
    write_goal_task_links config links;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    let msg =
      Printf.sprintf
        "%s: failed to write goal_task_links; caller must compensate: %s"
        operation
        (Printexc.to_string e)
    in
    Log.Misc.warn "%s" msg;
    Error msg
;;

let read_goal_task_links_for_mutation config ~operation =
  match read_goal_task_links_r config with
  | Ok links -> Ok links
  | Error msg ->
    let msg =
      Printf.sprintf
        "%s: failed to read goal_task_links; refusing to overwrite registry: %s"
        operation
        msg
    in
    Log.Misc.warn "%s" msg;
    Error msg
;;

let goal_task_links_lock_path config =
  Filename.concat (tasks_dir config) ".goal-task-links"
;;

let backlog_lock_path config =
  Filename.concat (tasks_dir config) ".backlog"
;;

let goal_ids_for_task links ~task_id =
  List.fold_left
    (fun acc (goal_id, task_ids) ->
       if List.mem task_id task_ids then goal_id :: acc else acc)
    []
    links
  |> List.sort_uniq String.compare
;;

let add_link_to_links links ~goal_id ~task_id =
  let updated = ref false in
  let links =
    List.map
      (fun (candidate_goal_id, task_ids) ->
         if String.equal candidate_goal_id goal_id then (
           updated := true;
           if List.mem task_id task_ids then candidate_goal_id, task_ids
           else candidate_goal_id, task_ids @ [ task_id ])
         else candidate_goal_id, task_ids)
      links
  in
  if !updated then links else links @ [ goal_id, [ task_id ] ]
;;

type link_goalless_task_checked_error =
  | Link_unknown_task
  | Link_unknown_goal
  | Link_registry_unreadable of string
  | Link_already_assigned of string list

let prune_links_for_goal_result config ~goal_id =
  let goal_id = String.trim goal_id in
  if String.equal goal_id ""
  then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match
        read_goal_task_links_for_mutation
          config
          ~operation:"prune_links_for_goal_result"
      with
      | Error msg -> Error msg
      | Ok links ->
        let links = List.filter (fun (gid, _) -> not (String.equal gid goal_id)) links in
        write_goal_task_links_result
          config
          ~operation:"prune_links_for_goal_result"
          links)
;;

let prune_links_for_goal config ~goal_id =
  (* fire-and-forget: pruning is best-effort cleanup; later reads repair stale goal links. *)
  ignore (prune_links_for_goal_result config ~goal_id)
;;

let link_task_to_goal_result config ~goal_id ~task_id =
  let goal_id = String.trim goal_id in
  let task_id = String.trim task_id in
  if String.equal goal_id "" || String.equal task_id ""
  then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match
        read_goal_task_links_for_mutation
          config
          ~operation:"link_task_to_goal_result"
      with
      | Error msg -> Error (Link_registry_unreadable msg)
      | Ok links ->
        (match
           write_goal_task_links_result
             config
             ~operation:"link_task_to_goal_result"
             (add_link_to_links links ~goal_id ~task_id)
         with
         | Ok () -> Ok ()
         | Error msg -> Error (Link_registry_unreadable msg)))
;;

let link_task_to_goal config ~goal_id ~task_id =
  match link_task_to_goal_result config ~goal_id ~task_id with
  | Ok () | Error _ -> ()
;;

let link_goalless_task_to_goal config ~goal_id ~task_id =
  let goal_id = String.trim goal_id in
  let task_id = String.trim task_id in
  if String.equal goal_id "" || String.equal task_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match
        read_goal_task_links_for_mutation
          config
          ~operation:"link_goalless_task_to_goal"
      with
      | Error msg -> Error (Link_registry_unreadable msg)
      | Ok links ->
        (match goal_ids_for_task links ~task_id with
         | [] ->
           (match
              write_goal_task_links_result
                config
                ~operation:"link_goalless_task_to_goal"
                (add_link_to_links links ~goal_id ~task_id)
            with
            | Ok () -> Ok ()
            | Error msg -> Error (Link_registry_unreadable msg))
         | existing_goal_ids -> Error (Link_already_assigned existing_goal_ids)))
;;

let link_goalless_task_to_goal_checked
      config
      ~goal_id
      ~task_id
      ~task_exists
      ~goal_exists
  =
  let goal_id = String.trim goal_id in
  let task_id = String.trim task_id in
  with_file_lock config (goal_task_links_lock_path config) (fun () ->
    if (not (task_exists ~task_id)) || String.equal task_id ""
    then Error Link_unknown_task
    else if (not (goal_exists ~goal_id)) || String.equal goal_id ""
    then Error Link_unknown_goal
    else
      match
        read_goal_task_links_for_mutation
          config
          ~operation:"link_goalless_task_to_goal_checked"
      with
      | Error msg -> Error (Link_registry_unreadable msg)
      | Ok links ->
        (match goal_ids_for_task links ~task_id with
         | [] ->
           (match
              write_goal_task_links_result
                config
                ~operation:"link_goalless_task_to_goal_checked"
                (add_link_to_links links ~goal_id ~task_id)
            with
            | Ok () -> Ok ()
            | Error msg -> Error (Link_registry_unreadable msg))
         | existing_goal_ids -> Error (Link_already_assigned existing_goal_ids)))
;;

let link_tasks_to_goals_result config task_goal_links =
  let normalized =
    task_goal_links
    |> List.filter_map (fun (task_id, goal_id_opt) ->
      match goal_id_opt with
      | None -> None
      | Some goal_id ->
        let task_id = String.trim task_id in
        let goal_id = String.trim goal_id in
        if String.equal task_id "" || String.equal goal_id ""
        then None
        else Some (task_id, goal_id))
  in
  match normalized with
  | [] -> Ok ()
  | _ ->
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match
        read_goal_task_links_for_mutation
          config
          ~operation:"link_tasks_to_goals_result"
      with
      | Error msg -> Error (Link_registry_unreadable msg)
      | Ok links ->
        let links =
          List.fold_left
            (fun acc (task_id, goal_id) ->
               add_link_to_links acc ~goal_id ~task_id)
            links
            normalized
        in
        (match
           write_goal_task_links_result
             config
             ~operation:"link_tasks_to_goals_result"
             links
         with
         | Ok () -> Ok ()
         | Error msg -> Error (Link_registry_unreadable msg)))
;;

let link_tasks_to_goals config links =
  match link_tasks_to_goals_result config links with
  | Ok () | Error _ -> ()
;;

(** Build a reverse index from goal_id to its linked tasks.

    [goal_task_links] is the authoritative source of goal-task
    associations. Each entry is [(goal_id, [task_id; ...])]. Task IDs
    are resolved against the supplied [tasks] list.

    When [goal_task_links] is omitted, the index is empty. The old
    fallback of deriving links from [task.goal_id] was removed as part
    of the task↔goal boundary refactor. *)
let build_goal_task_index
      ?(goal_task_links : (string * string list) list = [])
      (tasks : task list)
      : (string, task list) Hashtbl.t
  =
  let tbl = Hashtbl.create 16 in
  let task_by_id = Hashtbl.create (List.length tasks) in
  List.iter (fun (task : task) -> Hashtbl.replace task_by_id task.id task) tasks;
  List.iter
    (fun (goal_id, task_ids) ->
       let linked_tasks =
         List.filter_map
           (fun task_id ->
              try Some (Hashtbl.find task_by_id task_id) with Not_found -> None)
           task_ids
       in
       Hashtbl.replace tbl goal_id linked_tasks)
    goal_task_links;
  tbl
;;

let build_goal_task_index_for_config_checked config =
  with_file_lock config (backlog_lock_path config) (fun () ->
    match Workspace_backlog.read_backlog_r config with
    | Error msg ->
      Error ("build_goal_task_index_for_config_checked: backlog unreadable: " ^ msg)
    | Ok backlog ->
      with_file_lock config (goal_task_links_lock_path config) (fun () ->
        match
          read_goal_task_links_for_mutation
            config
            ~operation:"build_goal_task_index_for_config_checked"
        with
        | Error msg -> Error msg
        | Ok goal_task_links ->
          Ok (build_goal_task_index backlog.tasks ~goal_task_links)))
;;

(** Find all tasks linked to a specific goal.
    Returns [[]] when no tasks are linked to the given [goal_id]. *)
let tasks_for_goal (index : (string, task list) Hashtbl.t) ~goal_id : task list =
  try Hashtbl.find index goal_id with Not_found -> []
;;

(** Count open (non-terminal) tasks for a goal using a pre-built index.
    O(k) where k = tasks linked to the goal, instead of O(n) full scan. *)
let open_task_count_for_goal_indexed
      (index : (string, task list) Hashtbl.t)
      ~goal_id
      : int
  =
  let linked = tasks_for_goal index ~goal_id in
  List.fold_left
    (fun count (task : task) ->
       if not (task_status_is_terminal task.task_status)
       then count + 1
       else count)
    0
    linked
;;

(** Build a reverse-reverse index from task_id to the list of goal_ids it is
    linked to. This is the complement of [build_goal_task_index] and is
    useful for keeper-side lookups that need to answer “which goals does this
    task belong to?” without storing [goal_id] on the task record. *)
let build_task_goal_index
      ?(goal_task_links : (string * string list) list = [])
      ()
      : (string, string list) Hashtbl.t
  =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (goal_id, task_ids) ->
       List.iter
         (fun task_id ->
            let existing = try Hashtbl.find tbl task_id with Not_found -> [] in
            (* Preserve registry order for consumers that need a canonical
               first-linked goal for a task. Multi-goal task links are legacy
               invariant violations, but the projection must still be stable
               and match the persisted link order. *)
            Hashtbl.replace tbl task_id (existing @ [ goal_id ]))
         task_ids)
    goal_task_links;
  tbl
;;

let build_goal_task_index_for_config config tasks =
  build_goal_task_index tasks ~goal_task_links:(read_goal_task_links config)
;;

let build_task_goal_index_for_config config =
  build_task_goal_index ~goal_task_links:(read_goal_task_links config) ()
;;

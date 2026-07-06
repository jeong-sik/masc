(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Eliminates O(n) linear scans in [validate_goal_completion_ready]
    (workspace_goals.ml) and [open_task_count_for_goal]
    (workspace_task_capacity.ml) by building a Hashtbl-based reverse
    index on demand from explicit goal-task link mappings.

    The index is rebuilt from the current task list and a small persistent
    goal-task link registry. *)

open Masc_domain
open Workspace_utils

type goal_task_links_write_error = string

type link_goalless_task_to_goal_error =
  | Already_linked_to_goals of string list
  | Link_write_failed of goal_task_links_write_error

let goal_task_links_read_failed_prefix = "goal_task_links_read_failed"

let goal_task_links_read_failed_message msg =
  Printf.sprintf "%s: %s" goal_task_links_read_failed_prefix msg
;;

let goal_task_links_write_error_to_string msg = msg

let link_goalless_task_to_goal_error_to_string = function
  | Already_linked_to_goals existing_goal_ids ->
    Printf.sprintf "task already linked to goal(s): %s" (String.concat ", " existing_goal_ids)
  | Link_write_failed msg -> msg
;;

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
    (match read_json_result config recovery_path with
     | Ok json ->
       Log.Misc.warn
         "read_goal_task_links: primary unreadable, recovered from %s (%s)"
         recovery_path
         primary_msg;
       Ok (links_of_yojson json)
     | Error recovery_msg ->
       if not (path_exists config primary_path) then Ok []
       else
         Error
           (Printf.sprintf
              "%s; recovery read failed for %s: %s"
              primary_msg
              recovery_path
              recovery_msg))
;;

let read_goal_task_links config =
  match read_goal_task_links_r config with
  | Ok links -> links
  | Error msg ->
    Log.Misc.warn "read_goal_task_links failed: %s" msg;
    []
;;

let verify_goal_task_links_write config ~path ~json ~expected_links ~label =
  match write_json_result config path json with
  | Error msg ->
    Error
      (Printf.sprintf
         "write_goal_task_links: %s write failed for %s: %s"
         label
         path
         msg)
  | Ok () ->
    (match read_json_result config path with
    | Ok written when links_of_yojson written = expected_links -> Ok ()
    | Ok _ ->
      Error
        (Printf.sprintf
           "write_goal_task_links: %s readback mismatch for %s"
           label
           path)
    | Error msg ->
      Error
        (Printf.sprintf
           "write_goal_task_links: %s write/readback failed for %s: %s"
           label
           path
           msg))
;;

let write_goal_task_links_result ?(rollback_on_recovery_failure = true) ?previous_links config links =
  let json = links_to_yojson links in
  let primary_path = goal_task_links_path config in
  let recovery_path = goal_task_links_recovery_path config in
  let expected_links = normalize_link_set links in
  let write_primary () =
    verify_goal_task_links_write
      config
      ~path:primary_path
      ~json
      ~expected_links
      ~label:"primary"
  in
  let write_recovery () =
    verify_goal_task_links_write
      config
      ~path:recovery_path
      ~json
      ~expected_links
      ~label:"recovery"
  in
  let rollback () =
    match previous_links with
    | None -> ()
    | Some previous_links ->
      let previous_json = links_to_yojson previous_links in
      let previous_expected = normalize_link_set previous_links in
      (match
         verify_goal_task_links_write
           config
           ~path:primary_path
           ~json:previous_json
           ~expected_links:previous_expected
           ~label:"primary-rollback"
       with
       | Ok () -> ()
       | Error rollback_msg ->
         Log.Misc.warn
           "write_goal_task_links_result: primary rollback failed after write failure: %s"
           rollback_msg);
      (match
         verify_goal_task_links_write
           config
           ~path:recovery_path
           ~json:previous_json
           ~expected_links:previous_expected
           ~label:"recovery-rollback"
       with
       | Ok () -> ()
       | Error rollback_msg ->
         Log.Misc.warn
           "write_goal_task_links_result: recovery rollback failed after write failure: %s"
           rollback_msg)
  in
  match write_primary () with
  | Error _ as error ->
    rollback ();
    error
  | Ok () ->
    (match write_recovery () with
     | Ok () -> Ok ()
     | Error _ as error ->
       if rollback_on_recovery_failure then rollback ();
       error)
;;

let write_goal_task_links config links =
  match write_goal_task_links_result config links with
  | Ok () -> ()
  | Error msg -> raise (Sys_error msg)
;;

let goal_task_links_lock_path config =
  Filename.concat (tasks_dir config) ".goal-task-links"
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

let remove_link_from_links links ~goal_id ~task_id =
  List.filter_map
    (fun (candidate_goal_id, task_ids) ->
       if String.equal candidate_goal_id goal_id then
         let filtered = List.filter (fun id -> not (String.equal id task_id)) task_ids in
         if filtered = [] then None else Some (candidate_goal_id, filtered)
       else Some (candidate_goal_id, task_ids))
    links
;;

let read_goal_task_links_for_mutation config =
  match read_goal_task_links_r config with
  | Ok links -> Ok links
  | Error msg ->
    Error (Printf.sprintf "goal_task_links read failed before mutation: %s" msg)
;;

let prune_links_for_goal_result config ~goal_id =
  let goal_id = String.trim goal_id in
  if String.equal goal_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error _ as error -> error
      | Ok links ->
        let new_links = List.filter (fun (gid, _) -> not (String.equal gid goal_id)) links in
        write_goal_task_links_result
          config
          ~rollback_on_recovery_failure:false
          ~previous_links:links
          new_links)
;;

let prune_links_for_goal config ~goal_id =
  match prune_links_for_goal_result config ~goal_id with
  | Ok () -> ()
  | Error msg -> raise (Sys_error msg)
;;

let link_task_to_goal_result config ~goal_id ~task_id =
  let goal_id = String.trim goal_id in
  let task_id = String.trim task_id in
  if String.equal goal_id "" || String.equal task_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error _ as error -> error
      | Ok links ->
        let new_links = add_link_to_links links ~goal_id ~task_id in
        write_goal_task_links_result config ~previous_links:links new_links)
;;

let link_task_to_goal config ~goal_id ~task_id =
  match link_task_to_goal_result config ~goal_id ~task_id with
  | Ok () -> ()
  | Error msg -> raise (Sys_error msg)
;;

let before_unlink_task_from_goal_for_testing = Atomic.make None

let unlink_task_from_goal_result_impl config ~goal_id ~task_id =
  let goal_id = String.trim goal_id in
  let task_id = String.trim task_id in
  if String.equal goal_id "" || String.equal task_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error _ as error -> error
      | Ok links ->
        let new_links = remove_link_from_links links ~goal_id ~task_id in
        write_goal_task_links_result
          config
          ~rollback_on_recovery_failure:false
          ~previous_links:links
          new_links)
;;

let unlink_task_from_goal_result config ~goal_id ~task_id =
  (match Atomic.get before_unlink_task_from_goal_for_testing with
   | None -> ()
   | Some before_unlink -> before_unlink config ~goal_id ~task_id);
  unlink_task_from_goal_result_impl config ~goal_id ~task_id
;;

module For_testing = struct
  let with_before_unlink_task_from_goal before_unlink f =
    let previous = Atomic.get before_unlink_task_from_goal_for_testing in
    Fun.protect
      ~finally:(fun () -> Atomic.set before_unlink_task_from_goal_for_testing previous)
      (fun () ->
         Atomic.set before_unlink_task_from_goal_for_testing (Some before_unlink);
         f ())
  ;;
end

let link_goalless_task_to_goal config ~goal_id ~task_id =
  let goal_id = String.trim goal_id in
  let task_id = String.trim task_id in
  if String.equal goal_id "" || String.equal task_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error msg -> Error (Link_write_failed msg)
      | Ok links ->
        (match goal_ids_for_task links ~task_id with
         | [] ->
           (match
              write_goal_task_links_result
                config
                ~previous_links:links
                (add_link_to_links links ~goal_id ~task_id)
            with
            | Ok () -> Ok ()
            | Error msg -> Error (Link_write_failed msg))
         | existing_goal_ids -> Error (Already_linked_to_goals existing_goal_ids)))
;;

let link_tasks_to_goals_result config links =
  let trimmed_links =
    List.filter_map
      (fun (task_id, goal_id_opt) ->
         let task_id = String.trim task_id in
         match goal_id_opt with
         | None -> None
         | Some goal_id ->
           let goal_id = String.trim goal_id in
           if String.equal goal_id "" || String.equal task_id ""
           then None
           else Some (task_id, goal_id))
      links
  in
  if trimmed_links = [] then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error _ as error -> error
      | Ok existing_links ->
        let updated_links =
          List.fold_left
            (fun acc (task_id, goal_id) -> add_link_to_links acc ~goal_id ~task_id)
            existing_links
            trimmed_links
        in
        write_goal_task_links_result config ~previous_links:existing_links updated_links)
;;

let link_tasks_to_goals config links =
  match link_tasks_to_goals_result config links with
  | Ok () -> ()
  | Error msg -> raise (Sys_error msg)
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

let build_goal_task_index_for_config_result config tasks =
  match read_goal_task_links_r config with
  | Ok goal_task_links -> Ok (build_goal_task_index tasks ~goal_task_links)
  | Error msg -> Error msg
;;

let build_goal_task_index_for_config config tasks =
  match build_goal_task_index_for_config_result config tasks with
  | Ok index -> index
  | Error msg ->
    Log.Misc.warn "build_goal_task_index_for_config failed: %s" msg;
    build_goal_task_index tasks ~goal_task_links:[]
;;

let build_task_goal_index_for_config_result config =
  match read_goal_task_links_r config with
  | Ok goal_task_links -> Ok (build_task_goal_index ~goal_task_links ())
  | Error msg -> Error msg
;;

let build_task_goal_index_for_config config =
  match build_task_goal_index_for_config_result config with
  | Ok index -> index
  | Error msg ->
    Log.Misc.warn "build_task_goal_index_for_config failed: %s" msg;
    build_task_goal_index ~goal_task_links:[] ()
;;

(** Workspace_goal_index — Reverse index from goal_id to linked tasks.

    Eliminates repeated O(n) linear scans in Goal/task projections and
    observations by building an immutable Map.Make-based reverse index on
    demand from explicit goal-task link mappings.

    The index is rebuilt from the current task list and a small persistent
    goal-task link registry. *)

open Masc_domain
open Workspace_utils

type goal_task_links_write_error = string

type link_goalless_task_to_goal_error =
  | Already_linked_to_goals of string list
  | Link_write_failed of goal_task_links_write_error

let goal_task_links_path config =
  Filename.concat (tasks_dir config) "goal_task_links.json"
;;

let goal_task_links_recovery_path config =
  goal_task_links_path config ^ ".last-good"
;;

(* [Goal_id_map] is defined locally because [masc_workspace] is an upstream
   dependency of [masc_goal] ([Goal_store]); [Task_id_map] and [Task_id_set]
   are shared directly from [Workspace_backlog]. *)
module Goal_id_map = Map.Make (String)
module Task_id_map = Workspace_backlog.Task_id_map
module Task_id_set = Workspace_backlog.Task_id_set

(* This is the link registry's lossy historical key, not an identity check. *)
let normalize_link_id = String.trim

let normalize_link_set links =
  let by_goal =
    List.fold_left
      (fun acc (goal_id, task_ids) ->
         let goal_id = normalize_link_id goal_id in
         if String.equal goal_id ""
         then acc
         else (
           let seen, rev_ids =
             match Goal_id_map.find_opt goal_id acc with
             | Some existing -> existing
             | None -> Task_id_set.empty, []
           in
           let seen, rev_ids =
             List.fold_left
               (fun (seen_acc, rev_acc) task_id ->
                  let task_id = normalize_link_id task_id in
                  if String.equal task_id "" || Task_id_set.mem task_id seen_acc
                  then seen_acc, rev_acc
                  else Task_id_set.add task_id seen_acc, task_id :: rev_acc)
               (seen, rev_ids)
               task_ids
           in
           Goal_id_map.add goal_id (seen, rev_ids) acc))
      Goal_id_map.empty
      links
  in
  Goal_id_map.fold
    (fun goal_id (_seen, rev_ids) acc -> (goal_id, List.rev rev_ids) :: acc)
    by_goal
    []
  |> List.rev
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
    (match List.assoc_opt "goal_id" fields, List.assoc_opt "task_ids" fields with
     | Some (`String goal_id), Some (`List values) ->
       let goal_id = normalize_link_id goal_id in
       let rec collect acc = function
         | [] -> Some (goal_id, List.rev acc)
         | `String value :: rest ->
           let task_id = normalize_link_id value in
           if String.equal task_id "" then None
           else collect (task_id :: acc) rest
         | _ -> None
       in
       if String.equal goal_id "" then None else collect [] values
     | _ -> None)
  | _ -> None
;;

let links_of_yojson = function
  | `Assoc fields ->
    (match List.assoc_opt "links" fields with
     | Some (`List values) ->
       (* [filter_map] used to drop a row [link_of_yojson] refused, so a
          damaged row read as one fewer link instead of a damaged file — the
          same fold this guard exists to stop, one element in. *)
       let rec collect acc = function
         | [] -> Ok (normalize_link_set (List.rev acc))
         | value :: rest ->
           (match link_of_yojson value with
            | Some link -> collect (link :: acc) rest
            | None -> Error "goal_task_links: a link row does not decode")
       in
       collect [] values
     | Some _ -> Error "goal_task_links: \"links\" is present but not a list"
     | None -> Error "goal_task_links: missing links collection")
  | _ -> Error "goal_task_links: top level is not an object"
;;

(* Mutations need keys before [links_of_yojson] folds them. Duplicate
   structural members can hide links, so they make the observation unreadable
   without changing the regular link reader's existing behavior. *)
type prepared_link_ambiguity =
  { has_padded_key : bool
  }

let link_ambiguity_of_yojson json =
  let ( let* ) = Result.bind in
  let one_member name fields =
    match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
    | [value] -> Ok value
    | [] -> Error ("goal_task_links: missing " ^ name)
    | _ :: _ :: _ -> Error ("goal_task_links: duplicate " ^ name)
  in
  let rec rows ambiguous = function
    | [] -> Ok ambiguous
    | `Assoc fields :: rest ->
        let* goal = one_member "goal_id" fields in
        let* tasks = one_member "task_ids" fields in
        (match goal, tasks with
         | `String goal_id, `List values ->
             let goal_changed = not (String.equal goal_id (normalize_link_id goal_id)) in
             let ambiguous = { has_padded_key = ambiguous.has_padded_key || goal_changed } in
             let rec add_tasks ambiguous = function
               | [] -> rows ambiguous rest
               | `String task_id :: remaining ->
                   let task_changed = not (String.equal task_id (normalize_link_id task_id)) in
                   let ambiguous = { has_padded_key = ambiguous.has_padded_key || task_changed } in
                   add_tasks ambiguous remaining
               | _ -> Error "goal_task_links: invalid task ID in link observation"
             in
             add_tasks ambiguous values
         | _ -> Error "goal_task_links: invalid row in link observation")
    | _ :: _ -> Error "goal_task_links: invalid row in link observation"
  in
  match json with
  | `Assoc fields ->
      let* links = one_member "links" fields in
      (match links with
       | `List values -> rows { has_padded_key = false } values
       | _ -> Error "goal_task_links: invalid links in link observation")
  | _ -> Error "goal_task_links: invalid link observation"
;;

(* Content-addressed cache keyed by file path -> (raw_content, prepared_link_registry).
   Comparing exact [raw_content] avoids heuristic mtime checks while eliminating
   repeated JSON parsing, link-set normalization, and reverse task->goals map
   construction when [goal_task_links.json] is unchanged.
   [Stdlib.Mutex] is used intentionally because the critical section performs
   only in-memory [Hashtbl] lookups/updates and [String.equal] with zero Eio
   fiber yields, and [Workspace_goal_index] is called from both Eio fibers and
   non-Eio contexts. *)
type prepared_link_registry =
  { links : (string * string list) list
  ; goals_by_task_id : string list Task_id_map.t
  ; link_ambiguity : (prepared_link_ambiguity, string) result
  }

let build_task_goal_map
      ?(goal_task_links : (string * string list) list = [])
      ()
      : string list Task_id_map.t
  =
  let rev_by_task =
    List.fold_left
      (fun acc (goal_id, task_ids) ->
         List.fold_left
           (fun inner_acc task_id ->
              let existing =
                Option.value (Task_id_map.find_opt task_id inner_acc) ~default:[]
              in
              Task_id_map.add task_id (goal_id :: existing) inner_acc)
           acc
           task_ids)
      Task_id_map.empty
      goal_task_links
  in
  Task_id_map.map List.rev rev_by_task
;;

let prepare_link_registry links json =
  { links
  ; goals_by_task_id = build_task_goal_map ~goal_task_links:links ()
  ; link_ambiguity = link_ambiguity_of_yojson json
  }
;;

let link_registry_cache : (string, string * prepared_link_registry) Hashtbl.t =
  Hashtbl.create 8
;;

let link_registry_cache_mu = Stdlib.Mutex.create ()

let clear_link_registry_cache_for path =
  Stdlib.Mutex.lock link_registry_cache_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock link_registry_cache_mu)
    (fun () -> Hashtbl.remove link_registry_cache path)
;;

type link_registry_read_error =
  | Read_or_parse_error of string
  | Schema_decode_error of string

let link_registry_read_error_to_string = function
  | Read_or_parse_error msg | Schema_decode_error msg -> msg
;;

let read_link_registry_prepared_typed config path =
  match key_of_path config path with
  | None ->
    Error
      (Read_or_parse_error
         (Printf.sprintf "goal_task_links: path is outside backend root: %s" path))
  | Some key ->
    (match backend_get config ~key with
     | Error error ->
       clear_link_registry_cache_for path;
       Error (Read_or_parse_error (Backend_types.show_error error))
     | Ok None ->
       clear_link_registry_cache_for path;
       Ok None
     | Ok (Some content) ->
       let cached =
         Stdlib.Mutex.lock link_registry_cache_mu;
         Fun.protect
           ~finally:(fun () -> Stdlib.Mutex.unlock link_registry_cache_mu)
           (fun () ->
              match Hashtbl.find_opt link_registry_cache path with
              | Some (cached_content, prepared)
                when String.equal cached_content content ->
                Some prepared
              | Some _ | None -> None)
       in
       (match cached with
        | Some prepared -> Ok (Some prepared)
        | None ->
          (match Safe_ops.parse_json_safe ~context:path content with
           | Error detail ->
             clear_link_registry_cache_for path;
             Error (Read_or_parse_error detail)
           | Ok json ->
             (match links_of_yojson json with
              | Error detail ->
                clear_link_registry_cache_for path;
                Error (Schema_decode_error detail)
              | Ok links ->
                let prepared = prepare_link_registry links json in
                Stdlib.Mutex.lock link_registry_cache_mu;
                Fun.protect
                  ~finally:(fun () -> Stdlib.Mutex.unlock link_registry_cache_mu)
                  (fun () ->
                     Hashtbl.replace link_registry_cache path (content, prepared));
                Ok (Some prepared)))))
;;

let read_link_registry_typed config path =
  Result.map (Option.map (fun p -> p.links)) (read_link_registry_prepared_typed config path)
;;

let read_link_registry config path =
  Result.map_error link_registry_read_error_to_string (read_link_registry_typed config path)
;;

let read_authoritative_link_registry config =
  let read path =
    Result.map_error link_registry_read_error_to_string
      (read_link_registry_prepared_typed config path)
  in
  match read (goal_task_links_path config) with
  | Error _ as error -> error
  | Ok (Some prepared) -> Ok (Some prepared)
  | Ok None ->
    (match read (goal_task_links_recovery_path config) with
     | Error _ as error -> error
     | Ok (Some _) ->
       Error "goal_task_links: primary registry is missing; recovery is non-authoritative"
     | Ok None -> Ok None)
;;

let read_goal_task_links_authoritative_r config =
  Result.map (function None -> [] | Some prepared -> prepared.links)
    (read_authoritative_link_registry config)
;;

type goal_task_link_observation =
  { normalized_links : (string * string list) list
  ; padded_key_present : bool
  }

let read_goal_task_links_observed_r config =
  match read_authoritative_link_registry config with
  | Error _ as error -> error
  | Ok None -> Ok { normalized_links = []; padded_key_present = false }
  | Ok (Some prepared) ->
      Result.map (fun ambiguity ->
        { normalized_links = prepared.links
        ; padded_key_present = ambiguity.has_padded_key })
        prepared.link_ambiguity
;;

let read_goal_task_links_r config =
  match read_link_registry_typed config (goal_task_links_path config) with
  | Ok (Some links) -> Ok links
  | Ok None -> read_goal_task_links_authoritative_r config
  | Error (Schema_decode_error detail) -> Error detail
  | Error (Read_or_parse_error primary_msg) ->
    let recovery_path = goal_task_links_recovery_path config in
    (match read_link_registry config recovery_path with
     | Ok (Some links) ->
       Log.Misc.warn
         "read_goal_task_links: primary unreadable, recovered from %s (%s)"
         recovery_path primary_msg;
       Ok links
     | Ok None -> Error primary_msg
     | Error recovery_msg -> Error (primary_msg ^ "; " ^ recovery_msg))
;;

let read_goal_task_links config =
  match read_goal_task_links_r config with
  | Ok links -> links
  | Error msg ->
    Log.Misc.warn "read_goal_task_links failed: %s" msg;
    []
;;

let read_task_goal_map_r config =
  match read_link_registry_prepared_typed config (goal_task_links_path config) with
  | Ok (Some prepared) -> Ok prepared.goals_by_task_id
  | Ok None ->
    (match read_link_registry_prepared_typed config (goal_task_links_recovery_path config) with
     | Error err -> Error (link_registry_read_error_to_string err)
     | Ok (Some _) ->
       Error "goal_task_links: primary registry is missing; recovery is non-authoritative"
     | Ok None -> Ok Task_id_map.empty)
  | Error (Schema_decode_error detail) -> Error detail
  | Error (Read_or_parse_error primary_msg) ->
    let recovery_path = goal_task_links_recovery_path config in
    (match read_link_registry_prepared_typed config recovery_path with
     | Ok (Some prepared) ->
       Log.Misc.warn
         "read_goal_task_links: primary unreadable, recovered from %s (%s)"
         recovery_path primary_msg;
       Ok prepared.goals_by_task_id
     | Ok None -> Error primary_msg
     | Error recovery_err ->
       Error (primary_msg ^ "; " ^ link_registry_read_error_to_string recovery_err))
;;

let verify_goal_task_links_write config ~path ~json ~expected_links ~label =
  try
    clear_link_registry_cache_for path;
    write_json config path json;
    match read_json_doc config path with
    | Ok (Some written) when links_of_yojson written = Ok expected_links -> Ok ()
    | Ok (Some _) ->
      Error
        (Printf.sprintf
           "write_goal_task_links: %s readback mismatch for %s"
           label
           path)
    | Ok None ->
      Error
        (Printf.sprintf
           "write_goal_task_links: %s readback found no document at %s"
           label
           path)
    | Error error ->
      Error
        (Printf.sprintf
           "write_goal_task_links: %s write/readback failed for %s: %s"
           label
           path
           (json_doc_error_to_string error))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error
      (Printf.sprintf
         "write_goal_task_links: %s write failed for %s: %s"
         label
         path
         (Printexc.to_string exn))
;;

type task_mutation_notification =
  | Notify_on_failure
  | Notify_always

let protect_goal_link_settlement f =
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect f
  | Eio_guard.Non_eio -> f ()
;;

let notify_task_mutation () =
  try (Atomic.get Workspace_hooks.on_task_mutation_fn) () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.warn
      "goal-task link settlement observer failed: %s"
      (Printexc.to_string exn)
;;

let write_goal_task_links_result_internal
      ?(rollback_on_recovery_failure = true)
      ?previous_links
      ~task_mutation_notification
      config
      links
  =
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
  let notify_after_settlement ~failed =
    match task_mutation_notification, failed with
    | Notify_on_failure, false -> ()
    | Notify_on_failure, true | Notify_always, _ -> notify_task_mutation ()
  in
  protect_goal_link_settlement (fun () ->
    match write_primary () with
    | Error _ as error ->
      rollback ();
      notify_after_settlement ~failed:true;
      error
    | Ok () ->
      let recovery_result = write_recovery () in
      (match recovery_result with
       | Ok () ->
         notify_after_settlement ~failed:false;
         Ok ()
       | Error _ as error ->
         if rollback_on_recovery_failure then rollback ();
         notify_after_settlement ~failed:true;
         error))
;;

let write_goal_task_links_result
      ?rollback_on_recovery_failure
      ?previous_links
      config
      links
  =
  write_goal_task_links_result_internal
    ?rollback_on_recovery_failure
    ?previous_links
    ~task_mutation_notification:Notify_always
    config
    links
;;

let write_goal_task_links config links =
  match write_goal_task_links_result config links with
  | Ok () -> ()
  | Error msg -> Log.Misc.warn "%s" msg
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
  match read_goal_task_links_observed_r config with
  | Ok { normalized_links; padded_key_present = false; _ } -> Ok normalized_links
  | Ok { padded_key_present = true; _ } ->
    Error "goal_task_links has padded Goal or Task link IDs; repair the ambiguous links before mutation"
  | Error msg ->
    Error (Printf.sprintf "goal_task_links read failed before mutation: %s" msg)
;;

let prune_links_for_goal_result config ~goal_id =
  let goal_id = normalize_link_id goal_id in
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

let prune_links_for_task_result config ~task_id =
  match with_file_lock_r config (goal_task_links_lock_path config) (fun () ->
    match read_goal_task_links_for_mutation config with
    | Error _ as error -> error
    | Ok links ->
      let remaining = List.filter_map (fun (goal_id, task_ids) ->
        let ids = List.filter (fun id -> not (String.equal id task_id)) task_ids in
        if ids = [] then None else Some (goal_id, ids)) links in
      write_goal_task_links_result config ~rollback_on_recovery_failure:false
        ~previous_links:links remaining) with
  | Ok result -> result
  | Error error -> Error (Masc_domain.masc_error_to_string error)
;;

let link_task_to_goal_result config ~goal_id ~task_id =
  let goal_id = normalize_link_id goal_id in
  let task_id = normalize_link_id task_id in
  if String.equal goal_id "" || String.equal task_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error _ as error -> error
      | Ok links ->
        let new_links = add_link_to_links links ~goal_id ~task_id in
        write_goal_task_links_result_internal
          config
          ~previous_links:links
          ~task_mutation_notification:Notify_on_failure
          new_links)
;;

let before_unlink_task_from_goal_for_testing = Atomic.make None

let unlink_task_from_goal_result_impl config ~goal_id ~task_id =
  let goal_id = normalize_link_id goal_id in
  let task_id = normalize_link_id task_id in
  if String.equal goal_id "" || String.equal task_id "" then Ok ()
  else
    with_file_lock config (goal_task_links_lock_path config) (fun () ->
      match read_goal_task_links_for_mutation config with
      | Error _ as error -> error
      | Ok links ->
        let new_links = remove_link_from_links links ~goal_id ~task_id in
        write_goal_task_links_result_internal
          config
          ~rollback_on_recovery_failure:false
          ~previous_links:links
          ~task_mutation_notification:Notify_always
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
  let goal_id = normalize_link_id goal_id in
  let task_id = normalize_link_id task_id in
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
         let task_id = normalize_link_id task_id in
         match goal_id_opt with
         | None -> None
         | Some goal_id ->
           let goal_id = normalize_link_id goal_id in
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
        write_goal_task_links_result_internal
          config
          ~previous_links:existing_links
          ~task_mutation_notification:Notify_on_failure
          updated_links)
;;

(** Build a reverse index from goal_id to its linked tasks.

    [goal_task_links] is the authoritative source of goal-task
    associations. Each entry is [(goal_id, [task_id; ...])]. Task IDs
    are resolved against the supplied [tasks] list.

    When [goal_task_links] is omitted, the index is empty. *)
let build_goal_task_index
      ?(goal_task_links : (string * string list) list = [])
      (tasks : task list)
      : (string, task list) Hashtbl.t
  =
  let tbl = Hashtbl.create 16 in
  let task_by_id =
    List.fold_left
      (fun acc (task : task) ->
         Task_id_map.update
           task.id
           (function
            | Some _ as existing -> existing
            | None -> Some task)
           acc)
      Task_id_map.empty
      tasks
  in
  List.iter
    (fun (goal_id, task_ids) ->
       let linked_tasks =
         List.filter_map
           (fun task_id ->
              Task_id_map.find_opt task_id task_by_id)
           task_ids
       in
       Hashtbl.replace tbl goal_id linked_tasks)
    goal_task_links;
  tbl
;;

(** Find all tasks linked to a specific goal.
    Returns [[]] when no tasks are linked to the given [goal_id]. *)
let tasks_for_goal (index : (string, task list) Hashtbl.t) ~goal_id : task list =
  (* DET-OK: an absent bucket is the documented no-linked-tasks result; this
     is the same [] returned by the replaced [Not_found] handler. *)
  Option.value (Hashtbl.find_opt index goal_id) ~default:[]
;;

(** Find all goals linked to a specific task — the reverse of
    {!tasks_for_goal}, over the index {!build_task_goal_index_for_config}
    builds. Returns [[]] when no goals are linked to the given [task_id]. *)
let goals_for_task (index : (string, string list) Hashtbl.t) ~task_id :
  string list =
  (* DET-OK: an absent bucket is the documented no-linked-goals result, the
     mirror of [tasks_for_goal] over the same registry. *)
  Option.value (Hashtbl.find_opt index task_id) ~default:[]
;;

let goals_for_task_in_map (index : string list Task_id_map.t) ~task_id : string list =
  Option.value (Task_id_map.find_opt task_id index) ~default:[]
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
  let map = build_task_goal_map ~goal_task_links () in
  let tbl = Hashtbl.create (Task_id_map.cardinal map) in
  Task_id_map.iter (fun task_id goal_ids -> Hashtbl.replace tbl task_id goal_ids) map;
  tbl
;;

let build_goal_task_index_for_config config tasks =
  build_goal_task_index tasks ~goal_task_links:(read_goal_task_links config)
;;

let build_task_goal_map_for_config config =
  match read_task_goal_map_r config with
  | Ok map -> map
  | Error msg ->
    Log.Misc.warn "read_goal_task_links failed: %s" msg;
    Task_id_map.empty
;;

let build_task_goal_index_for_config config =
  let map = build_task_goal_map_for_config config in
  let tbl = Hashtbl.create (Task_id_map.cardinal map) in
  Task_id_map.iter (fun task_id goal_ids -> Hashtbl.replace tbl task_id goal_ids) map;
  tbl
;;

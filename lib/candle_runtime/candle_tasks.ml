(* See candle_tasks.mli. *)

let ( let* ) = Result.bind

let backlog_tasks config =
  match Workspace_backlog.read_backlog_r config with
  | Ok backlog -> Ok backlog.Masc_domain.tasks
  | Error detail -> Error (Printf.sprintf "the backlog could not be read: %s" detail)
;;

(* The archive is the {"tasks": [...]} document the collector appends to. Only
   the rows of the Tasks asked for are decoded, and those strictly: the archive
   grows for as long as the server runs, and a row this build cannot decode must
   not stop a payout that does not need it, where the collector's own readers
   skip such a row. A row whose id cannot be read is an error, because it may be
   the row that is wanted. *)
let row_id = function
  | `Assoc fields ->
    (match List.assoc_opt "id" fields with
     | Some (`String id) -> Some id
     | Some _ | None -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let archived_tasks config ~wanted =
  let context = "tasks-archive.json" in
  match
    Workspace_utils_ops.read_json_doc config (Workspace_utils_paths_backend.archive_path config)
  with
  | Error error ->
    Error
      (Printf.sprintf "%s could not be read: %s" context
         (Workspace_utils_ops.json_doc_error_to_string error))
  | Ok None -> Ok []
  | Ok (Some json) ->
    let* fields = Candle_json.object_fields ~context json in
    let* rows, (_ : Candle_json.fields) =
      Candle_json.field ~context "tasks" (Candle_json.as_list Result.ok) fields
    in
    let rec decode index found = function
      | [] -> Ok (List.rev found)
      | row :: rest ->
        (match row_id row with
         | None -> Error (Printf.sprintf "%s row %d has no readable id" context index)
         | Some id when List.mem id wanted ->
           (match Masc_domain.task_of_yojson row with
            | Ok task -> decode (index + 1) (task :: found) rest
            | Error detail ->
              Error
                (Printf.sprintf "%s row %d (task %s) does not decode: %s" context index id detail))
         | Some _ -> decode (index + 1) found rest)
    in
    decode 1 [] rows
;;

let linked_task_ids config ~goal_id =
  match Workspace_goal_index.read_goal_task_links_authoritative_r config with
  | Error detail -> Error (Printf.sprintf "the goal-task links could not be read: %s" detail)
  | Ok links ->
    (match List.assoc_opt goal_id links with
     | Some task_ids -> Ok task_ids
     | None -> Ok [])
;;

(* A claimed or completed Task must identify its performer. The shared Task
   decoder maps missing/non-string names to an empty string; that is unreadable
   payout evidence, not proof that nobody should be paid. *)
let assignee_of (task : Masc_domain.task) =
  match Masc_domain.task_performer_of_status task.task_status with
  | Some name when String.equal (String.trim name) "" ->
    Error (Printf.sprintf "task %s has no readable assignee" task.id)
  | Some name -> Ok (Some name)
  | None -> Ok None
;;

let status_of_task (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo -> Ok Candle_event.Todo
  | Masc_domain.Claimed _ -> Ok Candle_event.Claimed
  | Masc_domain.InProgress _ -> Ok Candle_event.In_progress
  | Masc_domain.AwaitingVerification _ -> Ok Candle_event.Awaiting_verification
  | Masc_domain.Done { completed_at; _ } ->
    let* completed_at =
      Candle_stamp.copied ~what:(Printf.sprintf "task %s completed_at" task.id) completed_at
    in
    Ok (Candle_event.Done { completed_at })
  | Masc_domain.Cancelled _ -> Ok Candle_event.Cancelled
;;

let found_of_task (task : Masc_domain.task) =
  let* status = status_of_task task in
  let* assignee = assignee_of task in
  Ok
    (Candle_event.Found
       { title = task.title; assignee; status })
;;

let find_task task_id tasks =
  List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id) tasks
;;

(* Read the backlog first, then the archive, then the links, and each only when
   an earlier read left a Task unfound. A Task that is in neither store while
   its links remain is an error, and the next read usually resolves it: the
   collector moved the Task between the first two reads. Three states do not
   resolve by themselves, because the writes involved are not atomic. The
   collector stopped between removing the Task from the backlog and appending
   it to the archive (#39963). A Task's creation stopped between its link and
   its backlog entry. A deletion could not remove its links, and the dashboard
   retries that one. Each leaves the payout waiting until someone repairs it. *)
let lookups config ~goal_id task_ids =
  match task_ids with
  | [] -> Ok []
  | _ :: _ ->
    let* backlog = backlog_tasks config in
    let missing =
      List.filter (fun task_id -> Option.is_none (find_task task_id backlog)) task_ids
    in
    let* archived, linked =
      match missing with
      | [] -> Ok ([], [])
      | _ :: _ ->
        let* archived = archived_tasks config ~wanted:missing in
        let* linked = linked_task_ids config ~goal_id in
        Ok (archived, linked)
    in
    let rec go found = function
      | [] -> Ok (List.rev found)
      | task_id :: rest ->
        (match find_task task_id backlog, find_task task_id archived with
         | Some task, _ | None, Some task ->
           let* lookup = found_of_task task in
           go ((task_id, lookup) :: found) rest
         | None, None ->
           if List.mem task_id linked
           then
             Error
               (Printf.sprintf
                  "task %s is linked to goal %s but neither the backlog nor tasks-archive.json has it"
                  task_id
                  goal_id)
           else go ((task_id, Candle_event.Deleted) :: found) rest)
    in
    go [] task_ids
;;

let is_keeper (config : Workspace_utils_backend_setup.config) =
  let base_path = config.base_path in
  let directory = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  match Sys.readdir directory with
  | exception Sys_error detail ->
    Error (Printf.sprintf "the keepers directory could not be listed: %s" detail)
  | entries ->
    Ok
      (fun name ->
        match Keeper_id.Keeper_name.of_string name with
        | Error _ -> false
        | Ok parsed ->
          let file =
            Filename.basename
              (Config_dir_resolver.keeper_toml_path_for_base_path
                 ~base_path
                 (Keeper_id.Keeper_name.to_string parsed))
          in
          Array.exists (String.equal file) entries)
;;

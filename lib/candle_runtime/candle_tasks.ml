(* See candle_tasks.mli. *)

open Result.Syntax

let backlog_source config =
  let path = Workspace_backlog.backlog_path config in
  let* json = match Workspace_utils_ops.read_json_doc config path with
    | Ok (Some json) -> Ok json
    | Ok None -> Error "the backlog could not be read: primary is absent"
    | Error error -> Error ("the backlog could not be read: " ^ Workspace_utils_ops.json_doc_error_to_string error) in
  let* backlog = Domain_pool_ref.submit_cpu_or_inline ~name:"candle_backlog_decode"
      (fun () -> Masc_domain.backlog_of_yojson json)
    |> Result.map_error (fun detail -> "the backlog could not be read: " ^ detail) in
  let* fields = Candle_json.object_fields ~context:"backlog" json in
  let* rows, _ = Candle_json.field ~context:"backlog" "tasks" (Candle_json.as_list Result.ok) fields in
  Ok (backlog, rows)
;;

(* The archive is the {"tasks": [...]} document the collector appends to. Only
   the rows of the Tasks asked for are decoded, and those strictly: the archive
   grows for as long as the server runs, and a row this build cannot decode must
   not stop a payout that does not need it, where the collector's own readers
   skip such a row. A row whose id cannot be read is an error, because it may be
   the row that is wanted. *)
let row_id = function
  | `Assoc fields ->
    (match List.filter (fun (name, _) -> String.equal name "id") fields with
     | [_, `String id] when String.trim id <> "" -> Some id
     | _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let possible_row_ids ~wanted = function
  | `Assoc fields -> List.filter_map (function
      | "id", `String id when String.trim id <> "" && List.mem id wanted -> Some id
      | _ -> None) fields |> List.sort_uniq String.compare
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
;;

let duplicate_payout_field = function
  | `Assoc fields -> List.exists (fun key ->
      List.length (List.filter (fun (name, _) -> String.equal name key) fields) > 1)
      ["id";"title";"status";"assignee";"completed_at"]
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> true
;;

(* A damaged row can still carry independently readable payout facts. Multiple
   values remain alternatives, never an eligible Task. In particular, keep
   every readable completion even if another copy of that field decodes first. *)
let fragments_of_damaged_row = function
  | `Assoc fields ->
    let values key = List.filter_map (fun (name, value) ->
      if String.equal name key then Some value else None) fields in
    let text key = match values key with [ `String value ] -> Some value | _ -> None in
    let completions = List.filter_map (function
      | `String raw ->
        (match Candle_stamp.copied ~what:"damaged task completed_at" raw with
         | Ok completed_at -> Some (Candle_event.Observed_status (Candle_event.Done {completed_at}))
         | Error _ -> None)
      | _ -> None) (values "completed_at") in
    let statuses = List.concat_map (function
      | `String "done" -> (match completions with [] -> [Candle_event.Unreadable_status] | _ -> completions)
      | `String "todo" -> [Candle_event.Observed_status Candle_event.Todo]
      | `String "claimed" -> [Candle_event.Observed_status Candle_event.Claimed]
      | `String "in_progress" -> [Candle_event.Observed_status Candle_event.In_progress]
      | `String "awaiting_verification" -> [Candle_event.Observed_status Candle_event.Awaiting_verification]
      | `String "cancelled" -> [Candle_event.Observed_status Candle_event.Cancelled]
      | _ -> [Candle_event.Unreadable_status]) (values "status") in
    let statuses = match statuses with [] -> [Candle_event.Unreadable_status] | _ -> statuses in
    let assignee_fields = values "assignee" in
    let possible_names = List.filter_map (function
      | `String name when String.trim name <> "" -> Some name
      | _ -> None) assignee_fields |> List.sort_uniq String.compare in
    let unassigned_statuses = List.for_all (function
      | Candle_event.Observed_status (Candle_event.Todo | Candle_event.Cancelled) -> true
      | _ -> false) statuses in
    let assignee, separate_names = match assignee_fields with
      | [`String name] when String.trim name <> "" -> Candle_event.Assigned name, []
      | [] when unassigned_statuses -> Candle_event.Unassigned, []
      | _ -> Candle_event.Unreadable_assignee, possible_names in
    let fragment assignee status : Candle_event.task_fragment =
      let keeper = match assignee with
        | Candle_event.Unassigned -> Candle_event.No_assignee
        | Candle_event.Assigned _ | Candle_event.Unreadable_assignee -> Candle_event.Keeper_unknown in
      {title=text "title";assignee;status;keeper} in
    List.map (fragment assignee) statuses
    @ List.map (fun name -> fragment (Candle_event.Assigned name) Candle_event.Unreadable_status) separate_names
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
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
  | Ok None -> Ok ([], [], None)
  | Ok (Some json) ->
    let* fields = Candle_json.object_fields ~context json in
    let* rows, (_ : Candle_json.fields) =
      Candle_json.field ~context "tasks" (Candle_json.as_list Result.ok) fields
    in
    let rec decode index found failures unidentified = function
      | [] -> Ok (List.rev found, List.rev failures, unidentified)
      | row :: rest ->
        (match row_id row with
         | None ->
           let detail = Printf.sprintf "%s row %d has no readable id" context index in
           (* Repeated/conflicting id fields cannot establish identity. Retain
              the row as uncertain for each requested id it could name. *)
           let possible_ids = possible_row_ids ~wanted row in
           let fragments = fragments_of_damaged_row row in
           let failures = List.fold_left (fun all id -> (id, (detail, fragments)) :: all) failures possible_ids in
           decode (index + 1) found failures (Some detail) rest
         | Some id when List.mem id wanted ->
           (match if duplicate_payout_field row then Error "duplicate payout field"
                  else Masc_domain.task_of_yojson row with
            | Ok task -> decode (index + 1) (task :: found) failures unidentified rest
            | Error detail ->
              let failure = Printf.sprintf "%s row %d (task %s) does not decode: %s" context index id detail in
              decode (index + 1) found ((id, (failure, fragments_of_damaged_row row)) :: failures) unidentified rest)
         | Some _ -> decode (index + 1) found failures unidentified rest)
    in
    decode 1 [] [] None rows
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

let fragment_of_task (task : Masc_domain.task) : Candle_event.task_fragment =
  let assignee = match assignee_of task with
    | Ok (Some name) -> Candle_event.Assigned name
    | Ok None -> Candle_event.Unassigned
    | Error _ -> Candle_event.Unreadable_assignee in
  let status = match status_of_task task with
    | Ok status -> Candle_event.Observed_status status
    | Error _ -> Candle_event.Unreadable_status in
  let keeper = match assignee with
    | Candle_event.Unassigned -> Candle_event.No_assignee
    | Candle_event.Assigned _ | Candle_event.Unreadable_assignee -> Candle_event.Keeper_unknown in
  {title=Some task.title;assignee;status;keeper}
;;

let observe_one task =
  match found_of_task task with
  | Ok lookup -> Ok (lookup, None)
  | Error detail -> Ok (Candle_event.Found_uncertain [fragment_of_task task], Some detail)
;;

let uncertain_rows ~detail rows =
  match rows with
  | [] -> Error detail
  | _ :: _ -> Ok (Candle_event.Found_uncertain (List.map fragment_of_task rows), Some detail)
;;

let uncertain_fragments ~detail fragments =
  match fragments with
  | [] -> Error detail
  | _ :: _ -> Ok (Candle_event.Found_uncertain fragments, Some detail)
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
let lookup_results config ~goal_id task_ids =
  match task_ids with
  | [] -> Ok []
  | _ :: _ ->
    let* backlog, raw_rows = backlog_source config in
    let tasks = backlog.Masc_domain.tasks in
    let unidentified = List.exists (fun row -> Option.is_none (row_id row)) raw_rows in
    let missing =
      List.filter (fun task_id -> Option.is_none (find_task task_id tasks)) task_ids
    in
    let archived, linked =
      match missing with
      | [] -> Ok ([], [], None), Ok []
      | _ :: _ ->
        let archived = archived_tasks config ~wanted:missing in
        let linked = match archived with
          | Ok _ -> linked_task_ids config ~goal_id
          | Error detail -> Error detail in
        archived, linked
    in
    let find task_id =
      let copies rows = List.filter (fun (task : Masc_domain.task) -> String.equal task.id task_id) rows in
      let raw_copies = List.filter (fun row -> List.mem task_id (possible_row_ids ~wanted:task_ids row)) raw_rows in
      let deleted = List.exists (fun (receipt : Masc_domain.task_deletion_receipt) ->
        String.equal receipt.deleted_task_id task_id) backlog.task_deletion_receipts in
      let deletion_detail = Printf.sprintf "task %s has a deletion receipt; remaining copies do not prove its original status" task_id in
      let duplicate_detail = Printf.sprintf "task %s has duplicate rows in a source" task_id in
      let raw_uncertain = unidentified || List.exists duplicate_payout_field raw_copies in
      let raw_fragments = List.concat_map fragments_of_damaged_row raw_copies in
      let raw_detail = Printf.sprintf "task %s belongs to a backlog with ambiguous payout fields or identities" task_id in
      match copies tasks, deleted with
      | (_ :: _), _ when raw_uncertain -> uncertain_fragments ~detail:raw_detail raw_fragments
      | [task], false -> observe_one task
      | (_ :: _ as rows), _ -> uncertain_rows ~detail:(if deleted then deletion_detail else duplicate_detail) rows
      | [], _ ->
        let* archived, failures, unidentified = archived in
        let rows = copies archived in
        let damaged = List.concat_map (fun (id, (_, fragments)) ->
          if String.equal id task_id then fragments else []) failures in
        let reason =
          if deleted then Some deletion_detail
          else if raw_uncertain then Some raw_detail
          else if List.length rows > 1 then Some duplicate_detail
          else match List.assoc_opt task_id failures with
            | Some (detail, _) -> Some detail
            | None -> unidentified in
        (match rows, reason with
         | rows, Some detail ->
           uncertain_fragments ~detail (raw_fragments @ List.map fragment_of_task rows @ damaged)
         | [task], None ->
           (match task.Masc_domain.task_status with
            | Masc_domain.Done _ | Cancelled _ -> observe_one task
            | Todo | Claimed _ | InProgress _ | AwaitingVerification _ ->
              uncertain_rows ~detail:(Printf.sprintf "task %s has only a nonterminal archive copy; current status is unavailable" task_id) rows)
         | [], None ->
           let* linked = linked in
           if List.mem task_id linked then
             Error (Printf.sprintf "task %s is linked to goal %s but neither the backlog nor tasks-archive.json has it" task_id goal_id)
           else Ok (Candle_event.Deleted, None)
         | _ :: _ :: _, None -> uncertain_rows ~detail:duplicate_detail rows)
    in
    Ok (List.map (fun task_id -> task_id, find task_id) task_ids)
;;

let lookups config ~goal_id task_ids =
  let* results = lookup_results config ~goal_id task_ids in
  let rec collect = function
    | [] -> Ok []
    | (id, result) :: rest ->
      let* lookup, detail = result in
      let* () = match detail with Some detail -> Error detail | None -> Ok () in
      let* tail = collect rest in
      Ok ((id, lookup) :: tail) in
  collect results
;;

(* A corrupt backlog is never candidate authority. If its JSON envelope and
   Task list are still readable, retain identifiable payout fragments so a
   separate boundary observation is not lost during later repair or deletion. *)
let damaged_backlog_observations config task_ids =
  let context = "damaged backlog" in
  let* document = match Workspace_utils_ops.read_json_doc config (Workspace_backlog.backlog_path config) with
    | Ok (Some json) -> Ok json
    | Ok None -> Error "backlog is absent"
    | Error error -> Error (Workspace_utils_ops.json_doc_error_to_string error) in
  let* fields = Candle_json.object_fields ~context document in
  let* rows, _ = Candle_json.field ~context "tasks" (Candle_json.as_list Result.ok) fields in
  Ok (List.map (fun task_id ->
    let fragments = List.concat_map (fun row ->
      if List.mem task_id (possible_row_ids ~wanted:task_ids row)
      then fragments_of_damaged_row row else []) rows in
    task_id, match fragments with
    | [] -> Candle_event.Unobserved
    | _ :: _ -> Candle_event.Found_uncertain fragments) task_ids)
;;

(* A broken backlog does not make a separately readable archive disappear.
   Neither store is authoritative while the backlog is unreadable, so retain
   every identifiable archive row only as a fragment. *)
let partial_observations config task_ids =
  let backlog = damaged_backlog_observations config task_ids in
  let archive = archived_tasks config ~wanted:task_ids in
  (match archive with
   | Error detail -> Log.Candle.warn "payout Task archive is uncertain: %s" detail
   | Ok _ -> ());
  match backlog, archive with
  | Error detail, Error _ -> Error detail
  | _ ->
    Ok (List.map (fun task_id ->
      let backlog_fragments = match backlog with
        | Ok observations ->
          (match List.assoc_opt task_id observations with
           | Some (Candle_event.Found_uncertain fragments) -> fragments
           | Some (Candle_event.Found _ | Candle_event.Deleted | Candle_event.Unobserved) | None -> [])
        | Error _ -> [] in
      let archive_fragments = match archive with
        | Error _ -> []
        | Ok (rows, failures, _) ->
          List.filter_map (fun (task : Masc_domain.task) ->
            if String.equal task.id task_id then Some (fragment_of_task task) else None) rows
          @ List.concat_map (fun (id, (_, fragments)) ->
              if String.equal id task_id then fragments else []) failures in
      task_id, match backlog_fragments @ archive_fragments with
      | [] -> Candle_event.Unobserved
      | fragments -> Candle_event.Found_uncertain fragments) task_ids)
;;

let observations config ~goal_id task_ids =
  match lookup_results config ~goal_id task_ids with
  | Error detail ->
    (match partial_observations config task_ids with
     | Ok fragments ->
       Log.Candle.warn "payout Task backlog is uncertain goal_id=%s: %s" goal_id detail;
       Ok fragments
     | Error _ -> Error detail)
  | Ok results ->
    Ok (List.map (fun (id, result) -> id,
      match result with
      | Ok (lookup, Some detail) ->
        Log.Candle.warn "payout Task observation uncertain goal_id=%s task_id=%s: %s" goal_id id detail;
        lookup
      | Ok (lookup, None) -> lookup
      | Error detail ->
        Log.Candle.warn "payout Task observation unavailable goal_id=%s task_id=%s: %s" goal_id id detail;
        Candle_event.Unobserved) results)
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

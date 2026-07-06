(** Workspace Task ID - Task ID parsing and archive management.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils
open Result.Syntax

let task_id_to_int id =
  let prefix = "task-" in
  let prefix_len = String.length prefix in
  if String.length id <= prefix_len then None
  else if String.sub id 0 prefix_len <> prefix then None
  else int_of_string_opt (String.sub id prefix_len (String.length id - prefix_len))

(** Extract the raw task-entry JSON list from a parsed archive document,
    tolerating both the bare-[`List] legacy shape and the current
    [{"tasks": [...]}] envelope.  Single source for the archive
    readers/writers so the shape cannot drift between them. *)
let archive_entries_of_json = function
  | `List tasks -> tasks
  | `Assoc _ as json -> begin
      match Json_util.assoc_member_opt "tasks" json with
      | Some (`List tasks) -> tasks
      | _ -> []
    end
  | _ -> []

let archive_entries_of_json_result ~path = function
  | `List tasks -> Ok tasks
  | `Assoc _ as json -> (
      match Json_util.assoc_member_opt "tasks" json with
      | Some (`List tasks) -> Ok tasks
      | Some _ ->
          Error
            (Printf.sprintf "archive %s has non-list tasks field" path)
      | None ->
          Error (Printf.sprintf "archive %s is missing tasks field" path))
  | _ -> Error (Printf.sprintf "archive %s has invalid JSON shape" path)

let read_archive_entries_result config =
  let path = archive_path config in
  if not (path_exists config path) then Ok []
  else
    let* json =
      read_json_result config path
      |> Result.map_error (fun msg ->
        Printf.sprintf "archive read failed for %s: %s" path msg)
    in
    archive_entries_of_json_result ~path json

let read_archive_entries config =
  match read_archive_entries_result config with
  | Ok entries -> entries
  | Error msg ->
      Log.TaskState.warn "read_archive_entries: %s" msg;
      []

let read_archive_task_ids_result config =
  read_archive_entries_result config
  |> Result.map (fun entries ->
    List.filter_map
      (fun task ->
         match Json_util.get_string task "id" with
         | Some id -> task_id_to_int id
         | None -> None)
      entries)

let read_archive_task_ids config =
  match read_archive_task_ids_result config with
  | Ok ids -> ids
  | Error msg ->
      Log.TaskState.warn "read_archive_task_ids: %s" msg;
      []

let read_archive_json_for_mutation config arch_path =
  if path_exists config arch_path then read_json_result config arch_path else Ok (`Assoc [])

(** Append tasks to archive file (tasks-archive.json).

    The read->merge->write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries. *)
let append_archive_tasks_result config (tasks : task list) =
  if tasks = [] then Ok ()
  else
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      match read_archive_json_for_mutation config arch_path with
      | Error msg ->
          Error
            (Printf.sprintf "append_archive_tasks: archive read failed for %s: %s" arch_path msg)
      | Ok existing ->
          let existing_tasks = archive_entries_of_json existing in
          let new_tasks = List.map task_to_yojson tasks in
          let seen = Hashtbl.create 64 in
          let keep_unseen_task_entry json =
            match Json_util.get_string json "id" with
            | Some id when Hashtbl.mem seen id -> false
            | Some id ->
                Hashtbl.add seen id ();
                true
            | None -> false
          in
          let dedup = List.filter keep_unseen_task_entry (existing_tasks @ new_tasks) in
          let archive_json =
            `Assoc [ "tasks", `List dedup; "last_updated", `String (now_iso ()) ]
          in
          write_json_result config arch_path archive_json)

let append_archive_tasks config tasks =
  match append_archive_tasks_result config tasks with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

(** RFC-0220 self-healing: read the archive and return every task whose status
    is non-terminal.  A non-terminal task in the archive is an obligation a
    prior buggy GC pass stranded (masc_transition and dashboard verification
    read only the live backlog); the GC restore path splices these back into
    the backlog.  Read-only — the caller rewrites the live backlog first, then
    calls {!drop_archive_tasks}, so a crash between the two leaves the task in
    both stores (recovered by dedup on the next pass) rather than losing it.
    Entries that fail to parse fail the read.  The GC restore path must not
    treat malformed archive content as "no orphaned tasks". *)
let read_orphaned_nonterminal_tasks_result config : (task list, string) result =
  let path = archive_path config in
  let* entries = read_archive_entries_result config in
  let rec collect index acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
        match task_of_yojson entry with
        | Ok task ->
            let acc =
              if task_status_is_terminal task.task_status then acc else task :: acc
            in
            collect (index + 1) acc rest
        | Error msg ->
            let id_note =
              match Json_util.get_string entry "id" with
              | Some id -> Printf.sprintf " (id=%s)" id
              | None -> ""
            in
            Error
              (Printf.sprintf
                 "archive %s task entry %d%s failed to parse: %s"
                 path
                 index
                 id_note
                 msg)
  in
  collect 0 [] entries

let read_orphaned_nonterminal_tasks config : task list =
  match read_orphaned_nonterminal_tasks_result config with
  | Ok tasks -> tasks
  | Error msg ->
      Log.TaskState.warn "read_orphaned_nonterminal_tasks: %s" msg;
      []

(** Remove archive entries whose task id is in [ids], under the archive lock.
    Entries without an [id] field are preserved — an unreadable archive line is
    never silently dropped.  No-op on []. *)
let drop_archive_tasks_result config ~ids =
  if ids = [] then Ok ()
  else
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      match read_archive_json_for_mutation config arch_path with
      | Error msg ->
          Error
            (Printf.sprintf "drop_archive_tasks: archive read failed for %s: %s" arch_path msg)
      | Ok existing ->
          let entries = archive_entries_of_json existing in
          let kept =
            List.filter
              (fun entry ->
                match Json_util.get_string entry "id" with
                | Some id -> not (List.mem id ids)
                | None -> true)
              entries
          in
          let archive_json =
            `Assoc [ "tasks", `List kept; "last_updated", `String (now_iso ()) ]
          in
          write_json_result config arch_path archive_json)

let drop_archive_tasks config ~ids =
  match drop_archive_tasks_result config ~ids with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

let next_task_number_result config (backlog : backlog) =
  let backlog_ids = List.filter_map (fun (task : task) -> task_id_to_int task.id) backlog.tasks in
  let* archive_ids = read_archive_task_ids_result config in
  let max_id = List.fold_left max 0 (backlog_ids @ archive_ids) in
  Ok (max_id + 1)

let next_task_number config (backlog : backlog) =
  match next_task_number_result config backlog with
  | Ok next -> next
  | Error msg ->
      Log.TaskState.warn "next_task_number: %s" msg;
      let backlog_ids = List.filter_map (fun (task : task) -> task_id_to_int task.id) backlog.tasks in
      List.fold_left max 0 backlog_ids + 1

(** Workspace Task ID - Task ID parsing and archive management.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils

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

let read_archive_entries config =
  if not (Sys.file_exists (archive_path config)) then []
  else archive_entries_of_json (read_json config (archive_path config))

let read_archive_task_ids config =
  List.filter_map (fun task ->
    match Json_util.get_string task "id" with
    | Some id -> task_id_to_int id
    | None -> None
  ) (read_archive_entries config)

(** Append tasks to archive file (tasks-archive.json).

    The read->merge->write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries. *)
let append_archive_tasks config (tasks : task list) =
  if tasks = [] then ()
  else
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      let existing = read_json config arch_path in
      let existing_tasks = archive_entries_of_json existing in
      let new_tasks = List.map task_to_yojson tasks in
      let seen = Hashtbl.create 64 in
      let dedup = List.filter (fun json ->
        match Json_util.get_string json "id" with
        | Some id ->
            if Hashtbl.mem seen id then false
            else (Hashtbl.add seen id (); true)
        | None -> false
      ) (existing_tasks @ new_tasks)
      in
      let archive_json = `Assoc [
        ("tasks", `List dedup);
        ("last_updated", `String (now_iso ()));
      ] in
      write_json config arch_path archive_json)

(** RFC-0220 self-healing: read the archive and return every task whose status
    is non-terminal.  A non-terminal task in the archive is an obligation a
    prior buggy GC pass stranded (masc_transition and dashboard verification
    read only the live backlog); the GC restore path splices these back into
    the backlog.  Read-only — the caller rewrites the live backlog first, then
    calls {!drop_archive_tasks}, so a crash between the two leaves the task in
    both stores (recovered by dedup on the next pass) rather than losing it.
    Entries that fail to parse are skipped here and preserved by
    {!drop_archive_tasks}. *)
let read_orphaned_nonterminal_tasks config : task list =
  List.filter_map (fun entry ->
    match task_of_yojson entry with
    | Ok task when not (task_status_is_terminal task.task_status) -> Some task
    | Ok _ | Error _ -> None
  ) (read_archive_entries config)

(** Remove archive entries whose task id is in [ids], under the archive lock.
    Entries without an [id] field are preserved — an unreadable archive line is
    never silently dropped.  No-op on []. *)
let drop_archive_tasks config ~ids =
  if ids = [] then ()
  else
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      let entries = archive_entries_of_json (read_json config arch_path) in
      let kept = List.filter (fun entry ->
        match Json_util.get_string entry "id" with
        | Some id -> not (List.mem id ids)
        | None -> true
      ) entries in
      let archive_json = `Assoc [
        ("tasks", `List kept);
        ("last_updated", `String (now_iso ()));
      ] in
      write_json config arch_path archive_json)

let next_task_number config (backlog : backlog) =
  let backlog_ids = List.filter_map (fun (task : task) -> task_id_to_int task.id) backlog.tasks in
  let archive_ids = read_archive_task_ids config in
  let max_id = List.fold_left max 0 (backlog_ids @ archive_ids) in
  max_id + 1

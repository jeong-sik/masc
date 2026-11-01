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

(** Extract the raw task-entry JSON list from a parsed archive document.
    The archive is the [{"tasks": [...]}] envelope; the bare-[`List] shape
    that predated it is no longer read.  Single source for the archive
    readers/writers so the shape cannot drift between them. *)
let archive_entries_of_json json =
  match Json_util.assoc_member_opt "tasks" json with
  | Some (`List tasks) -> tasks
  | _ -> []

let read_archive_entries config =
  if not (path_exists config (archive_path config)) then []
  else archive_entries_of_json (read_json config (archive_path config))

let read_archive_task_ids config =
  List.filter_map (fun task ->
    match Json_util.get_string task "id" with
    | Some id -> task_id_to_int id
    | None -> None
  ) (read_archive_entries config)

(* The archive rows a writer is about to rewrite. A missing file is an empty
   archive. A file that cannot be read, is blank, does not parse, or has no
   [tasks] list is an error: a writer that took any of those for an empty
   archive would replace the file and drop every row in it. *)
let read_archive_entries_for_write config =
  match read_json_doc config (archive_path config) with
  | Ok None -> Ok []
  | Error error -> Error (json_doc_error_to_string error)
  | Ok (Some json) ->
    (match Json_util.assoc_member_opt "tasks" json with
     | Some (`List tasks) -> Ok tasks
     | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
     | None -> Error "the document has no \"tasks\" list")

module Archive_ids = Map.Make (String)
type archive_identity = Unique of Yojson.Safe.t | Duplicate
type archive_index = { rows : archive_identity Archive_ids.t; unidentified : bool }

let archive_status_cache : archive_index File_version_cache.t = File_version_cache.create ()

let archive_index config =
  let decode () =
    let entries = match read_json_doc config (archive_path config) with
      | Ok None -> Ok []
      | Error error -> Error (json_doc_error_to_string error)
      | Ok (Some (`Assoc fields)) ->
          (match List.filter (fun (key, _) -> key = "tasks") fields with
           | [_, `List entries] -> Ok entries
           | _ -> Error "archive needs one tasks list")
      | Ok (Some _) -> Error "archive must be an object" in
    entries |> Result.map (fun entries ->
      List.fold_left (fun index row ->
        let identity = match row with
          | `Assoc fields ->
              (match List.filter (fun (key, _) -> key = "id") fields with
               | [_, `String id] when String.trim id <> "" -> Some id
               | _ -> None)
          | _ -> None in
        match identity with
        | None -> { index with unidentified = true }
        | Some id ->
            let entry = if Archive_ids.mem id index.rows then Duplicate else Unique row in
            { index with rows = Archive_ids.add id entry index.rows })
        { rows = Archive_ids.empty; unidentified = false } entries) in
  match config.backend with
  | Memory _ -> decode ()
  | FileSystem _ -> File_version_cache.load archive_status_cache (archive_path config) ~decode

let read_archived_task_row_r config ~task_id =
  let open Result.Syntax in
  let* index = archive_index config in
  match Archive_ids.find_opt task_id index.rows with
  | Some Duplicate -> Error "archive contains duplicate requested Task identities"
  | Some (Unique row) -> Ok (Some row)
  | None when index.unidentified -> Error "archive has unidentified rows; requested Task absence is unconfirmed"
  | None -> Ok None

let read_archived_task_r config ~task_id =
  Result.bind (read_archived_task_row_r config ~task_id) (function
    | None -> Ok None
    | Some row -> task_of_yojson row |> Result.map Option.some)

let read_archived_task_status_r config ~task_id =
  let open Result.Syntax in
  let* row = read_archived_task_row_r config ~task_id in
  match row with
  | None -> Ok None
  | Some row ->
      let* _task = task_of_yojson row in
      Task_status_observation.of_yojson row |> Result.map Option.some

(** Append tasks to archive file (tasks-archive.json).

    The read->merge->write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries. *)
let append_archive_tasks config (tasks : task list) =
  if tasks = [] then Ok ()
  else
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      match read_archive_entries_for_write config with
      | Error detail ->
        Error
          (Printf.sprintf
             "tasks-archive.json could not be read, so nothing was appended: %s"
             detail)
      | Ok existing_rows ->
        let new_rows = List.map task_to_yojson tasks in
        let id_of row = Json_util.get_string row "id" in
        let incoming = Hashtbl.create 64 in
        List.iter
          (fun row -> Option.iter (fun id -> Hashtbl.replace incoming id ()) (id_of row))
          new_rows;
        (* The rows given are the current copies, so each replaces the archive
           row with the same id, whatever that row holds: an older copy, or a
           row that does not decode as a Task. Every other row stays as it is,
           rows with no id and repeated ids included. This is not the place to
           drop them, the rule [drop_archive_tasks] applies to the same file. *)
        let kept =
          List.filter
            (fun row ->
              match id_of row with
              | Some id -> not (Hashtbl.mem incoming id)
              | None -> true)
            existing_rows
        in
        let seen = Hashtbl.create 64 in
        let appended =
          List.filter
            (fun row ->
              match id_of row with
              | Some id ->
                if Hashtbl.mem seen id then false else (Hashtbl.add seen id (); true)
              | None -> true)
            new_rows
        in
        let archive_json = `Assoc [
          ("tasks", `List (kept @ appended));
          ("last_updated", `String (now_iso ()));
        ] in
        Fun.protect ~finally:(fun () -> File_version_cache.forget archive_status_cache arch_path)
          (fun () -> write_json_result config arch_path archive_json)
        |> Result.map_error (fun detail ->
             Printf.sprintf "tasks-archive.json could not be written: %s" detail))

(** Read the archive and return every task whose status is non-terminal. A
    non-terminal task in the archive is an obligation a
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
    never silently dropped.  An archive that cannot be read is an [Error] and
    is left as it was, because rewriting it from what could not be read would
    erase every row.  No-op on []. *)
let drop_archive_tasks config ~ids =
  if ids = [] then Ok ()
  else
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      match read_archive_entries_for_write config with
      | Error detail ->
        Error
          (Printf.sprintf
             "tasks-archive.json could not be read, so nothing was dropped: %s"
             detail)
      | Ok entries ->
        let kept = List.filter (fun entry ->
          match Json_util.get_string entry "id" with
          | Some id -> not (List.mem id ids)
          | None -> true
        ) entries in
        let archive_json = `Assoc [
          ("tasks", `List kept);
          ("last_updated", `String (now_iso ()));
        ] in
        Fun.protect ~finally:(fun () -> File_version_cache.forget archive_status_cache arch_path)
          (fun () -> write_json_result config arch_path archive_json)
        |> Result.map_error (fun detail ->
             Printf.sprintf "tasks-archive.json could not be written: %s" detail))

type cached_event_max_id = {
  st_dev : int;
  st_ino : int;
  st_size : int;
  st_mtime : float;
  st_ctime : float;
  ended_with_newline : bool;
  prefix_digest : Digest.t;
  max_task_id : int;
  mutable last_access_tick : int;
}

let max_cached_event_id_files = 256
let event_max_id_cache : (string, cached_event_max_id) Hashtbl.t =
  Hashtbl.create 64
let event_max_id_cache_mutex = Mutex.create ()
let event_max_id_cache_tick = ref 0

let with_event_max_id_cache_lock f =
  Mutex.lock event_max_id_cache_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock event_max_id_cache_mutex) f

let touch_event_max_id_tick () =
  incr event_max_id_cache_tick;
  !event_max_id_cache_tick

let evict_oldest_event_max_id_locked () =
  let oldest_key = ref None in
  let oldest_tick = ref max_int in
  Hashtbl.iter
    (fun key (entry : cached_event_max_id) ->
       if entry.last_access_tick < !oldest_tick then begin
         oldest_tick := entry.last_access_tick;
         oldest_key := Some key
       end)
    event_max_id_cache;
  match !oldest_key with
  | Some key -> Hashtbl.remove event_max_id_cache key
  | None -> ()

let max_task_id_of_event_json acc json =
  let check acc = function
    | Some id ->
      (match task_id_to_int id with
       | Some n when n > acc -> n
       | Some _ | None -> acc)
    | None -> acc
  in
  let acc = check acc (Json_util.get_string json "task") in
  check acc (Json_util.get_string json "task_id")

let scan_max_task_id_range content ~start_pos ~end_pos ~init =
  let rec loop line_start acc =
    if line_start >= end_pos then acc
    else
      let line_end =
        match String.index_from_opt content line_start '\n' with
        | Some idx when idx < end_pos -> idx
        | _ -> end_pos
      in
      let line_len = line_end - line_start in
      let acc =
        if line_len <= 0 then acc
        else
          let line = String.sub content line_start line_len in
          match Yojson.Safe.from_string line with
          | json -> max_task_id_of_event_json acc json
          | exception Yojson.Json_error _ -> acc
      in
      loop (line_end + 1) acc
  in
  loop start_pos init

let same_event_file_stat (entry : cached_event_max_id) (st : Unix.stats) =
  entry.st_dev = st.st_dev
  && entry.st_ino = st.st_ino
  && entry.st_size = st.st_size
  && Float.equal entry.st_mtime st.st_mtime
  && Float.equal entry.st_ctime st.st_ctime

let load_event_file_max_task_id ~verify_content (st : Unix.stats) path =
  if st.st_kind = Unix.S_REG && st.st_perm land 0o444 = 0 then
    raise (Unix.Unix_error (Unix.EACCES, "open", path));
  Unix.access path [ Unix.R_OK ];
  if st.st_kind <> Unix.S_REG then
    let content = Fs_compat.load_file path in
    scan_max_task_id_range content ~start_pos:0 ~end_pos:(String.length content) ~init:0
  else
    let check_cached () =
      with_event_max_id_cache_lock (fun () ->
        match Hashtbl.find_opt event_max_id_cache path with
        | Some entry ->
          entry.last_access_tick <- touch_event_max_id_tick ();
          Some entry
        | None -> None)
    in
    let should_verify = verify_content && st.st_size <= 262_144 in
    match check_cached () with
    | Some entry when not should_verify && same_event_file_stat entry st ->
      entry.max_task_id
    | _ ->
      let content = Fs_compat.load_file path in
      let cached_opt = check_cached () in
      let len = String.length content in
      let full_digest = Digest.string content in
      let max_task_id, was_exact_digest_hit =
        match cached_opt with
        | Some entry
          when entry.st_dev = st.st_dev
               && entry.st_ino = st.st_ino
               && entry.st_size = len
               && Digest.equal full_digest entry.prefix_digest ->
          entry.max_task_id, true
        | Some entry
          when entry.st_dev = st.st_dev
               && entry.st_ino = st.st_ino
               && len > entry.st_size
               && entry.ended_with_newline
               && Digest.equal
                    (Digest.substring content 0 entry.st_size)
                    entry.prefix_digest ->
          scan_max_task_id_range content ~start_pos:entry.st_size ~end_pos:len
            ~init:entry.max_task_id,
          false
        | _ ->
          scan_max_task_id_range content ~start_pos:0 ~end_pos:len ~init:0,
          false
      in
      let stat_unchanged =
        match cached_opt with
        | Some entry -> same_event_file_stat entry st
        | None -> false
      in
      if not (was_exact_digest_hit && stat_unchanged) then
        (match Unix.stat path with
         | st_after
           when st_after.st_kind = Unix.S_REG
                && st_after.st_dev = st.st_dev
                && st_after.st_ino = st.st_ino
                && st_after.st_size = len
                && Float.equal st_after.st_mtime st.st_mtime
                && Float.equal st_after.st_ctime st.st_ctime ->
           let ended_with_newline =
             len > 0 && Char.equal content.[len - 1] '\n'
           in
           with_event_max_id_cache_lock (fun () ->
             while Hashtbl.length event_max_id_cache >= max_cached_event_id_files
                   && not (Hashtbl.mem event_max_id_cache path)
             do
               evict_oldest_event_max_id_locked ()
             done;
             let tick = touch_event_max_id_tick () in
             Hashtbl.replace event_max_id_cache path
               {
                 st_dev = st.st_dev;
                 st_ino = st.st_ino;
                 st_size = len;
                 st_mtime = st.st_mtime;
                 st_ctime = st.st_ctime;
                 ended_with_newline;
                 prefix_digest = full_digest;
                 max_task_id;
                 last_access_tick = tick;
               })
         | _ | exception Unix.Unix_error _ -> ());
      max_task_id

let compare_month_entries_desc a b =
  match
    Dated_jsonl.Layout.year_and_month_of_directory_name a,
    Dated_jsonl.Layout.year_and_month_of_directory_name b
  with
  | Some _, Some _ | None, None -> String.compare b a
  | Some _, None -> -1
  | None, Some _ -> 1

let event_history_max_task_id config =
  let events_dir = Filename.concat (masc_dir config) "events" in
  match Unix.stat events_dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> 0
  | _ ->
    let month_dirs =
      Sys.readdir events_dir
      |> Array.to_list
      |> List.sort compare_month_entries_desc
    in
    let is_first_file = ref true in
    let max_id = ref 0 in
    let visit_file path =
      let st = Unix.stat path in
      if st.st_kind <> Unix.S_DIR then begin
        let is_day_file =
          Option.is_some
            (Dated_jsonl.Layout.day_file_parts (Filename.basename path))
        in
        let verify_content = !is_first_file in
        if is_day_file then is_first_file := false;
        let file_max = load_event_file_max_task_id ~verify_content st path in
        if file_max > !max_id then max_id := file_max
      end
    in
    List.iter
      (fun month ->
         let month_path = Filename.concat events_dir month in
         let st = Unix.stat month_path in
         if st.st_kind = Unix.S_DIR then
           Sys.readdir month_path
           |> Array.to_list
           |> List.sort (fun a b -> Dated_jsonl.Layout.compare_day_files b a)
           |> List.iter (fun file -> visit_file (Filename.concat month_path file))
         else visit_file month_path)
      month_dirs;
    !max_id

let next_task_number config (backlog : backlog) =
  let backlog_ids = List.filter_map (fun (task : task) -> task_id_to_int task.id) backlog.tasks in
  let receipt_ids = List.filter_map (fun receipt -> task_id_to_int receipt.deleted_task_id) backlog.task_deletion_receipts in
  let creation_ids = List.filter_map (fun receipt -> task_id_to_int receipt.created_task_id) backlog.task_creation_receipts in
  let archive_ids = read_archive_task_ids config in
  (* Event history outlives both the live backlog and its archive after a
     workspace restore. Reusing an id that history still names aliases two
     unrelated task lifecycles in [masc_task_history]. *)
  let event_max_id = event_history_max_task_id config in
  let max_list acc l = List.fold_left max acc l in
  let max_id =
    event_max_id
    |> Fun.flip max_list backlog_ids
    |> Fun.flip max_list receipt_ids
    |> Fun.flip max_list creation_ids
    |> Fun.flip max_list archive_ids
  in
  max_id + 1

(** Coord Task ID - Task ID parsing and archive management.

    Extracted from room_state.ml. *)

open Types
open Coord_utils

let task_id_to_int id =
  let prefix = "task-" in
  let prefix_len = String.length prefix in
  if String.length id <= prefix_len
  then None
  else if String.sub id 0 prefix_len <> prefix
  then None
  else int_of_string_opt (String.sub id prefix_len (String.length id - prefix_len))
;;

let read_archive_task_ids config =
  if not (Sys.file_exists (archive_path config))
  then []
  else
    let open Yojson.Safe.Util in
    let json = read_json config (archive_path config) in
    let tasks =
      match json with
      | `List tasks -> tasks
      | `Assoc _ ->
        (match json |> member "tasks" with
         | `List tasks -> tasks
         | _ -> [])
      | _ -> []
    in
    List.filter_map
      (fun task ->
         match task |> member "id" |> to_string_option with
         | Some id -> task_id_to_int id
         | None -> None)
      tasks
;;

(** Append tasks to archive file (tasks-archive.json).

    The read->merge->write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries. *)
let append_archive_tasks config (tasks : task list) =
  if tasks = []
  then ()
  else (
    let arch_path = archive_path config in
    with_file_lock config arch_path (fun () ->
      let open Yojson.Safe.Util in
      let existing = read_json config arch_path in
      let existing_tasks =
        match existing with
        | `List items -> items
        | `Assoc _ ->
          (match existing |> member "tasks" with
           | `List items -> items
           | _ -> [])
        | _ -> []
      in
      let new_tasks = List.map task_to_yojson tasks in
      let seen = Hashtbl.create 64 in
      let dedup =
        List.filter
          (fun json ->
             match json |> member "id" |> to_string_option with
             | Some id ->
               if Hashtbl.mem seen id
               then false
               else (
                 Hashtbl.add seen id ();
                 true)
             | None -> false)
          (existing_tasks @ new_tasks)
      in
      let archive_json =
        `Assoc [ "tasks", `List dedup; "last_updated", `String (now_iso ()) ]
      in
      write_json config arch_path archive_json))
;;

let next_task_number config (backlog : backlog) =
  let backlog_ids =
    List.filter_map (fun (task : task) -> task_id_to_int task.id) backlog.tasks
  in
  let archive_ids = read_archive_task_ids config in
  let max_id = List.fold_left max 0 (backlog_ids @ archive_ids) in
  max_id + 1
;;

(** Planning_eio — the session current-task pointer.

    Historically this module also owned a per-task plan document store
    (task_plan / notes / errors / deliverable as Markdown under
    [planning/<task_id>/]); the five tools that wrote it
    (masc_plan_init/update/get, masc_note_add, masc_deliver) were retired
    together with that store, and only the current-task pointer the task
    claim chain maintains remains. Pure synchronous module — no Eio
    scheduling primitives despite the [_eio] suffix. *)

module Workspace = Workspace_core

let read_file_content path =
  if Fs_compat.file_exists path then
    Fs_compat.load_file path
  else ""

(** File write via Fs_compat (Eio-native when available, blocking fallback) *)
let write_file_content path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path content

let current_task_file (config : Workspace.config) =
  Filename.concat (Workspace_utils.masc_dir config) "current_task"

(* The planning [current_task] path must be a file, but runtime state can be
   corrupted by external writers. Keep these helpers total for directory-shaped
   corruption so one bad path cannot wedge owner claim/transition flows. *)

let is_directory_path path =
  try Sys.is_directory path with Sys_error _ -> false

let quarantine_dir_under_trash (config : Workspace.config) ~path ~op =
  let trash_dir = Filename.concat (Workspace_utils.masc_dir config) "_trash" in
  Fs_compat.mkdir_p trash_dir;
  let stamp =
    let t = Time_compat.now () in
    let ms = int_of_float (t *. 1000.) mod 1000 in
    let tm = Unix.gmtime t in
    Printf.sprintf "%04d%02d%02dT%02d%02d%02dZ-%03d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec ms
  in
  let dest =
    Filename.concat trash_dir
      (* NDT-OK: quarantine filenames only need per-process uniqueness for
         external filesystem recovery; planning state remains ledger-driven. *)
      (Printf.sprintf "current_task.%s.%d" stamp (Unix.getpid ()))
  in
  try
    Sys.rename path dest;
    Log.Task.warn
      "planning_eio.%s: current_task path was a directory; quarantined to %s"
      op dest;
    Ok dest
  with
  | Sys_error msg ->
    Log.Task.warn
      "planning_eio.%s: failed to quarantine directory at %s: %s"
      op path msg;
    Error msg

let remove_empty_current_task_dir ~path ~op =
  try
    match Sys.readdir path with
    | [||] ->
      (try
         Unix.rmdir path;
         true
       with
       | Unix.Unix_error _ as e ->
         Log.Task.warn
           "planning_eio.%s: rmdir %s failed: %s"
           op path (Printexc.to_string e);
         false)
    | _ ->
      Log.Task.warn
        "planning_eio.%s: %s is a non-empty directory; leaving it in place"
        op path;
      false
  with
  | Sys_error msg ->
    Log.Task.warn
      "planning_eio.%s: failed to inspect directory at %s: %s"
      op path msg;
    false

(** Get current task_id for session *)
let get_current_task (config : Workspace.config) : string option =
  let path = current_task_file config in
  if not (Sys.file_exists path) then None
  else if is_directory_path path then begin
    Log.Task.warn
      "planning_eio.get_current_task: %s is a directory; treating as cleared"
      path;
    None
  end
  else
    try Some (String.trim (read_file_content path)) with
    | Sys_error msg when is_directory_path path ->
      Log.Task.warn
        "planning_eio.get_current_task: %s became a directory during read: %s"
        path msg;
      None

(** Set current task_id for session *)
let set_current_task (config : Workspace.config) ~task_id : (unit, string) result =
  let path = current_task_file config in
  Fs_compat.mkdir_p (Filename.dirname path);
  let write_current_task () =
    try
      write_file_content path task_id;
      Ok ()
    with
    | Sys_error msg when is_directory_path path ->
      Log.Task.warn
        "planning_eio.set_current_task: %s became a directory during write: %s"
        path msg;
      Error
        (Printf.sprintf
           "current_task became a directory during write at %s: %s"
           path msg)
  in
  if is_directory_path path then
    match quarantine_dir_under_trash config ~path ~op:"set_current_task" with
    | Ok _ -> write_current_task ()
    | Error msg ->
      if remove_empty_current_task_dir ~path ~op:"set_current_task" then
        write_current_task ()
      else begin
        Log.Task.warn
          "planning_eio.set_current_task: leaving directory in place after \
           quarantine failure: %s"
          msg;
        Error
          (Printf.sprintf
             "failed to quarantine existing current_task directory at %s: %s"
             path msg)
      end
  else write_current_task ()

(** Clear current task *)
let clear_current_task (config : Workspace.config) : unit =
  let path = current_task_file config in
  if not (Sys.file_exists path) then ()
  else if is_directory_path path then
    ignore
      (remove_empty_current_task_dir ~path ~op:"clear_current_task" : bool)
  else
    try Sys.remove path with
    | Sys_error msg when is_directory_path path ->
      Log.Task.warn
        "planning_eio.clear_current_task: %s became a directory during remove: %s"
        path msg

(** Resolve task_id - use provided or fall back to current *)

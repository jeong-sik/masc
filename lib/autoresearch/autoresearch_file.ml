(** Autoresearch_file — Target file validation and code change application.

    Validates file paths (no traversal, no symlink escape), reads file contents,
    and applies code changes atomically.

    @since 2.80.0 *)

(** Check if path contains traversal components (../ or /.. or bare ..). *)
let has_path_traversal path =
  path = ".."
  || Autoresearch_metric.contains_substring path "../"
  ||
  let len = String.length path in
  len >= 3 && String.sub path (len - 3) 3 = "/.."
;;

let is_safe_subpath ~parent ~child =
  if child = parent
  then true
  else (
    let prefix = parent ^ "/" in
    String.length child >= String.length prefix
    && String.sub child 0 (String.length prefix) = prefix)
;;

let rec nearest_existing_path path =
  if Sys.file_exists path
  then path
  else (
    let parent = Filename.dirname path in
    if parent = path then path else nearest_existing_path parent)
;;

let safe_realpath path =
  try Result.ok (Unix.realpath path) with
  | Unix.Unix_error (code, _, _) ->
    Result.error
      (Printf.sprintf "realpath failed for %s: %s" path (Unix.error_message code))
;;

(** Resolve [target_file] to an absolute path within [workdir] without
    requiring the file to already exist. Existing parent directories are
    resolved via [realpath] so symlink escapes are rejected before callers
    create or seed files. *)
let resolve_target_file_path ~workdir target_file =
  if String.length target_file = 0
  then Result.error "target_file is empty"
  else if String.get target_file 0 = '/'
  then Result.error (Printf.sprintf "target_file must be relative: %s" target_file)
  else if has_path_traversal target_file
  then Result.error (Printf.sprintf "target_file contains '..': %s" target_file)
  else (
    let abs = Filename.concat workdir target_file in
    let parent = Filename.dirname abs in
    match safe_realpath workdir, safe_realpath (nearest_existing_path parent) with
    | Error message, _ -> Result.error message
    | _, Error message -> Result.error message
    | Ok real_workdir, Ok real_parent ->
      if is_safe_subpath ~parent:real_workdir ~child:real_parent
      then Result.ok abs
      else
        Result.error
          (Printf.sprintf "target_file escapes workdir via symlink: %s" target_file))
;;

(** Validate target_file: must be relative, no path traversal, must exist,
    must not escape workdir via symlink.
    Returns Ok absolute_path or Error reason. *)
let validate_target_file ~workdir target_file =
  match resolve_target_file_path ~workdir target_file with
  | Error _ as error -> error
  | Ok abs ->
    if not (Sys.file_exists abs)
    then Result.error (Printf.sprintf "target_file not found: %s" abs)
    else if Sys.is_directory abs
    then Result.error (Printf.sprintf "target_file is a directory: %s" target_file)
    else (
      match safe_realpath abs, safe_realpath workdir with
      | Error message, _ -> Result.error message
      | _, Error message -> Result.error message
      | Ok real_path, Ok real_workdir ->
        if is_safe_subpath ~parent:real_workdir ~child:real_path
        then Result.ok real_path
        else
          Result.error
            (Printf.sprintf "target_file escapes workdir via symlink: %s" target_file))
;;

(** Read entire file contents. *)
let read_file path = Fs_compat.load_file path

(** Apply code change: write new_content to target_file atomically.
    Writes to a temp file in the same directory, then renames.
    Returns Ok original_content (for rollback reference) or Error reason. *)
let apply_code_change ~workdir ~target_file ~new_content =
  match validate_target_file ~workdir target_file with
  | Result.Error _ as e -> e
  | Result.Ok abs_path ->
    let original = read_file abs_path in
    let dir = Filename.dirname abs_path in
    let tmp_path =
      Filename.concat dir (Printf.sprintf ".autoresearch_tmp_%d" (Unix.getpid ()))
    in
    (try
       Fs_compat.save_file tmp_path new_content;
       Unix.rename tmp_path abs_path;
       Result.ok original
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       (try Sys.remove tmp_path with
        | Sys_error _ -> ());
       Result.error
         (Printf.sprintf "Failed to write %s: %s" target_file (Printexc.to_string exn)))
;;

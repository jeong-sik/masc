(** Typed keeper path rejection contract and user-facing prefixes. *)

type keeper_path_rejection =
  | Path_required
  | Absolute_path_rejected of { raw : string }
  | Outside_project_root of { raw : string }
  | Allowed_paths_normalized_empty of { count : int }
  | Outside_sandbox of { raw : string }
  | Not_found_relative of { raw : string }
  | Ambiguous_relative_read_path of { raw : string; candidate_count : int }
  | Task_state_file_path_blocked of { raw : string }

let rejection_to_user_message = function
  | Path_required -> "path_required"
  | Absolute_path_rejected { raw } ->
    Printf.sprintf
      "path_outside_project_root: %s (absolute paths are not allowed; use \
       sandbox-relative paths like 'repos/X/lib/foo.ml')"
      raw
  | Outside_project_root { raw } ->
    Printf.sprintf "path_outside_project_root: %s" raw
  | Allowed_paths_normalized_empty { count } ->
    Printf.sprintf
      "allowed_paths_normalized_empty: %d entries provided, none resolved to a \
       valid path"
      count
  | Outside_sandbox { raw } ->
    Printf.sprintf "path_outside_sandbox: %s" raw
  | Not_found_relative { raw } ->
    Printf.sprintf
      "path_not_found_under_allowed_roots: %s (this path is outside your \
       allowed playground; check your_playground for available files)"
      raw
  | Ambiguous_relative_read_path { raw; candidate_count } ->
    Printf.sprintf
      "ambiguous_relative_read_path: %s (%d candidate matches; disambiguate the \
       relative segment)"
      raw
      candidate_count
  | Task_state_file_path_blocked { raw } ->
    Printf.sprintf
      "task_state_file_path_blocked: %s (use keeper_tasks_list for task/backlog \
       state, not direct file access)"
      raw
;;

let rejection_message_prefix = function
  | Path_required -> "path_required"
  | Absolute_path_rejected _ -> "path_outside_project_root:"
  | Outside_project_root _ -> "path_outside_project_root:"
  | Allowed_paths_normalized_empty _ -> "allowed_paths_normalized_empty:"
  | Outside_sandbox _ -> "path_outside_sandbox:"
  | Not_found_relative _ -> "path_not_found_under_allowed_roots:"
  | Ambiguous_relative_read_path _ -> "ambiguous_relative_read_path:"
  | Task_state_file_path_blocked _ -> "task_state_file_path_blocked:"
;;

let starts_with_ci ~prefix s =
  let pl = String.length prefix in
  String.length s >= pl
  && String.lowercase_ascii (String.sub s 0 pl) = prefix
;;

let parse_rejection_prefix msg =
  let trimmed = String.trim msg in
  if String.lowercase_ascii trimmed = "path_required"
  then Some Path_required
  else if starts_with_ci ~prefix:"path_outside_project_root:" trimmed
  then Some (Outside_project_root { raw = "" })
  else if starts_with_ci ~prefix:"allowed_paths_normalized_empty:" trimmed
  then Some (Allowed_paths_normalized_empty { count = 0 })
  else if starts_with_ci ~prefix:"path_outside_sandbox:" trimmed
  then Some (Outside_sandbox { raw = "" })
  else if starts_with_ci ~prefix:"path_not_found_under_allowed_roots:" trimmed
  then Some (Not_found_relative { raw = "" })
  else if starts_with_ci ~prefix:"ambiguous_relative_read_path:" trimmed
  then Some (Ambiguous_relative_read_path { raw = ""; candidate_count = 0 })
  else if starts_with_ci ~prefix:"task_state_file_path_blocked:" trimmed
  then Some (Task_state_file_path_blocked { raw = "" })
  else None
;;

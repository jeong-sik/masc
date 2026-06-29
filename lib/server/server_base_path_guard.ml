(** Shared server entrypoint guards for runtime base paths. *)

let implicit_base_path_resolution_source = "implicit_base_path"

let guard_self_repo_base_path base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let abs_base =
    try Unix.realpath base_path with
    | Unix.Unix_error _ -> base_path
  in
  let abs_exe =
    try Unix.realpath Sys.executable_name with
    | Unix.Unix_error _ -> ""
  in
  let build_prefix = abs_base ^ "/_build/" in
  let is_self_repo =
    abs_exe <> ""
    && String.length abs_exe > String.length build_prefix
    && String.sub abs_exe 0 (String.length build_prefix) = build_prefix
  in
  if is_self_repo
  then (
    Printf.eprintf
      "[FATAL] --base-path points to the server's own source repo: %s\n\
       (executable: %s)\n\
       Runtime state would pollute the repo. Use a workspace root instead:\n\
       \\  --base-path $MASC_BASE_PATH    (recommended)\n\
       \\  --base-path /path/to/workspace (explicit workspace root)\n\
       Or start via: sb mcp masc start\n"
      base_path
      abs_exe;
    exit 1)
;;

let guard_implicit_base_path ~resolution_source ~normalized_base_path =
  if String.equal resolution_source implicit_base_path_resolution_source
  then (
    Printf.eprintf
      "[FATAL] Server refused to start with an implicit base path.\n\
       Resolution source: %s\n\
       Resolved path: %s\n\n\
       Start the server with an explicit base path:\n\
       \\  --base-path /path/to/workspace     (CLI flag)\n\
       \\  MASC_BASE_PATH=/path/to/workspace  (environment variable)\n\n\
       Use a workspace root, not the repository checkout or $HOME directly.\n"
      resolution_source
      normalized_base_path;
    exit 1)
;;

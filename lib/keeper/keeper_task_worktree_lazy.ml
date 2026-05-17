type ensure_outcome =
  | Already_present
  | Created
  | Not_current_task_worktree

type candidate =
  { agent_name : string
  ; task_id : string
  ; repo_name : string
  ; worktree_path : string
  }

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let normalize path = Keeper_alerting_path.normalize_path_for_check_stripped path

let suffix_under ~prefix path =
  let prefix = Keeper_alerting_path.strip_trailing_slashes prefix in
  let path = Keeper_alerting_path.strip_trailing_slashes path in
  if String.equal path prefix
  then Some ""
  else (
    let prefix_with_sep = prefix ^ "/" in
    if String.starts_with ~prefix:prefix_with_sep path
    then
      Some
        (String.sub path (String.length prefix_with_sep)
           (String.length path - String.length prefix_with_sep))
    else None)
;;

let unique_nonempty values =
  List.fold_left
    (fun acc value ->
       let value = String.trim value in
       if value = "" || List.mem value acc then acc else acc @ [ value ])
    []
    values
;;

let current_task_id_string (meta : Keeper_types.keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id
;;

let candidate_of_path ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) path =
  match current_task_id_string meta with
  | None -> None
  | Some task_id ->
    let path = normalize path in
    unique_nonempty [ meta.agent_name; meta.name ]
    |> List.find_map (fun agent_name ->
      let repos_dir = Coord_worktree.repos_dir_of_keeper config agent_name |> normalize in
      match suffix_under ~prefix:repos_dir path with
      | None -> None
      | Some suffix ->
        (match Keeper_alerting_path.split_relative_components suffix with
         | repo_name :: ".worktrees" :: worktree_name :: _
           when Coord_worktree.safe_repo_name repo_name
                && String.equal
                     worktree_name
                     (Playground_paths.worktree_dir_name agent_name task_id) ->
           let worktree_path =
             Filename.concat
               repos_dir
               (Filename.concat
                  repo_name
                  (Filename.concat ".worktrees" worktree_name))
           in
           Some { agent_name; task_id; repo_name; worktree_path }
         | _ -> None))
;;

let observe ~(meta : Keeper_types.keeper_meta) ~site ~outcome =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_task_worktree_lazy_repair
    ~labels:[ "outcome", outcome; "site", site; "keeper", meta.name ]
    ()
;;

let inconsistent candidate msg =
  Printf.sprintf
    "sandbox_state_inconsistent: task worktree auto-create failed path=%s repo=%s \
     task_id=%s agent=%s: %s"
    candidate.worktree_path
    candidate.repo_name
    candidate.task_id
    candidate.agent_name
    msg
;;

let ensure_candidate ~site ~config ~meta candidate =
  observe ~meta ~site ~outcome:"attempt";
  Log.Keeper.info
    "keeper:%s lazy task worktree repair: site=%s agent=%s task=%s repo=%s path=%s"
    meta.name
    site
    candidate.agent_name
    candidate.task_id
    candidate.repo_name
    candidate.worktree_path;
  match
    Task_sandbox.create
      ~config
      ~task_id:candidate.task_id
      ~base_branch:"auto"
      ~repo_name:candidate.repo_name
      ~agent_name:candidate.agent_name
      ()
  with
  | Ok sandbox when safe_is_dir candidate.worktree_path ->
    observe ~meta ~site ~outcome:"created";
    Log.Keeper.info
      "keeper:%s lazy task worktree repair created path=%s returned_path=%s"
      meta.name
      candidate.worktree_path
      sandbox.Task_sandbox.worktree_path;
    Ok Created
  | Ok sandbox ->
    let msg =
      Printf.sprintf
        "created path mismatch; expected path still missing, returned_path=%s"
        sandbox.Task_sandbox.worktree_path
    in
    observe ~meta ~site ~outcome:"error";
    Error (inconsistent candidate msg)
  | Error msg when safe_is_dir candidate.worktree_path ->
    observe ~meta ~site ~outcome:"created_concurrently";
    Log.Keeper.info
      "keeper:%s lazy task worktree repair observed concurrent create path=%s after \
       error=%s"
      meta.name
      candidate.worktree_path
      msg;
    Ok Created
  | Error msg ->
    observe ~meta ~site ~outcome:"error";
    Log.Keeper.warn
      "keeper:%s lazy task worktree repair failed: site=%s agent=%s task=%s repo=%s \
       path=%s error=%s"
      meta.name
      site
      candidate.agent_name
      candidate.task_id
      candidate.repo_name
      candidate.worktree_path
      msg;
    Error (inconsistent candidate msg)
;;

let ensure_path ~site ~config ~meta ~path =
  let path = normalize path in
  if safe_is_dir path
  then Ok Already_present
  else (
    match candidate_of_path ~config ~meta path with
    | None -> Ok Not_current_task_worktree
    | Some candidate -> ensure_candidate ~site ~config ~meta candidate)
;;

let host_path_of_command_value ~cwd value =
  let value = String.trim value in
  if value = ""
  then value
  else if Filename.is_relative value
  then Filename.concat cwd value
  else value
;;

let ensure_command_existing_dirs ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta)
      ~cwd ~cmd =
  let rec loop = function
    | [] -> Ok ()
    | value :: rest ->
      let path = host_path_of_command_value ~cwd value in
      (match ensure_path ~site:"command_path" ~config ~meta ~path with
       | Error _ as err -> err
       | Ok _ -> loop rest)
  in
  loop (Worker_dev_tools.existing_dir_path_values cmd)
;;

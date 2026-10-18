(* git's porcelain protocol: one block per worktree, blank-line separated,
   and the block's first line is the literal keyword [worktree] followed by
   the checkout's absolute path. *)
let worktree_line_path line =
  match String.index_opt line ' ' with
  | Some idx when String.equal (String.sub line 0 idx) "worktree" ->
    Some (String.sub line (idx + 1) (String.length line - idx - 1))
  | Some _ | None -> None
;;

let worktree_paths_of_porcelain ~repo_path raw =
  let rec blocks acc current = function
    | [] -> List.rev (match current with [] -> acc | c -> List.rev c :: acc)
    | line :: rest ->
      if String.equal (String.trim line) ""
      then blocks (match current with [] -> acc | c -> List.rev c :: acc) [] rest
      else blocks acc (line :: current) rest
  in
  let blocks = blocks [] [] (String.split_on_char '\n' raw) in
  match
    List.fold_left
      (fun acc block ->
         match acc, block with
         | (Error _ as error), _ -> error
         | Ok paths, first :: _ ->
           (match worktree_line_path first with
            | Some path -> Ok (path :: paths)
            | None -> Error "git worktree list --porcelain block has no worktree line")
         | Ok paths, [] -> Ok paths)
      (Ok [])
      blocks
  with
  | Error _ as error -> error
  | Ok [] -> Error "git worktree list --porcelain named no worktrees"
  | Ok paths ->
    let repo_realpath =
      match Unix.realpath repo_path with
      | resolved -> Some resolved
      | exception Unix.Unix_error _ -> None
    in
    let is_main_checkout path =
      if String.equal path repo_path
      then true
      else (
        match repo_realpath with
        | None -> false
        | Some repo_resolved ->
          (match Unix.realpath path with
           | path_resolved -> String.equal path_resolved repo_resolved
           | exception Unix.Unix_error _ -> false))
    in
    Ok (List.filter (fun path -> not (is_main_checkout path)) paths)
;;

let worktree_list_argv ~repo_path =
  [ "git"; "-c"; "core.fsmonitor=false"; "-C"; repo_path; "worktree"; "list"
  ; "--porcelain"
  ]
;;

let worktree_remove_argv ~repo_path ~worktree_path =
  (* [--force] is what keeps the host from evaluating the keeper's repo
     configuration: without it [git worktree remove] spawns [git status] in
     the worktree to prove it clean, and that child runs the clone's
     filter.<name>.clean/.process commands, which [-c] cannot enumerate. *)
  [ "git"; "-c"; "core.fsmonitor=false"; "-C"; repo_path; "worktree"; "remove"
  ; "--force"; worktree_path
  ]
;;

(* Same containment shape as [Exec_shim.resolve_within]: resolve both sides
   so symlinks and [..] cannot bring a foreign path under the bundle root by
   spelling. *)
let within_bundle ~bundle_root path =
  try
    let root = Unix.realpath bundle_root in
    let resolved = Unix.realpath path in
    if String.equal resolved root || String.starts_with ~prefix:(root ^ "/") resolved
    then Ok ()
    else Error (Printf.sprintf "%s resolves to %s, outside bundle %s" path resolved root)
  with
  | Unix.Unix_error (error, _, _) ->
    Error
      (Printf.sprintf
         "%s is unresolvable (%s); treated as outside the bundle"
         path
         (Unix.error_message error))
;;

type repo_outcome =
  { removed : string list
  ; failed : (string * string) list
  ; skipped : string
  }

let prune_repo_worktrees ~run_argv ~timeout_sec ~repo_path ~bundle_root =
  match run_argv ~timeout_sec (worktree_list_argv ~repo_path) with
  | Unix.WEXITED 0, raw ->
    (match worktree_paths_of_porcelain ~repo_path raw with
     | Error detail -> { removed = []; failed = []; skipped = detail }
     | Ok [] -> { removed = []; failed = []; skipped = "" }
     | Ok paths ->
       let owned, foreign =
         List.partition_map
           (fun worktree_path ->
              match within_bundle ~bundle_root worktree_path with
              | Ok () -> Left worktree_path
              | Error detail -> Right detail)
           paths
       in
       let skipped =
         match foreign with
         | [] -> ""
         | _ :: _ ->
           Printf.sprintf
             "%d worktree(s) outside the bundle, left untouched: %s"
             (List.length foreign)
             (String.concat "; " foreign)
       in
       List.fold_left
         (fun acc worktree_path ->
            match run_argv ~timeout_sec (worktree_remove_argv ~repo_path ~worktree_path) with
            | Unix.WEXITED 0, _ -> { acc with removed = worktree_path :: acc.removed }
            | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), detail ->
              { acc with
                failed =
                  ( worktree_path
                  , Printf.sprintf
                      "%s: %s"
                      (Keeper_sandbox_exec_failure.status_label status)
                      detail )
                  :: acc.failed
              })
         { removed = []; failed = []; skipped }
         owned)
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), detail ->
    { removed = []
    ; failed = []
    ; skipped =
        Printf.sprintf "%s: %s" (Keeper_sandbox_exec_failure.status_label status) detail
    }
;;

let repo_dirs_of_bundle ~bundle_root =
  let repos_dir = Filename.concat bundle_root Playground_paths.bundle_repos_dirname in
  if not (Sys.file_exists repos_dir && Sys.is_directory repos_dir)
  then []
  else
    Sys.readdir repos_dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.map (Filename.concat repos_dir)
    |> List.filter Sys.is_directory
;;

let remove_keeper_worktrees ~run_argv ~timeout_sec ~base_path ~keeper_name ~profile =
  let bundle_root =
    Filename.concat base_path (Keeper_sandbox_config.host_root_rel_of_profile profile keeper_name)
  in
  let repo_dirs =
    Eio_guard.run_in_systhread ~label:"keeper-bundle-worktrees-scan" (fun () ->
      repo_dirs_of_bundle ~bundle_root)
  in
  List.map
    (fun repo_path ->
       repo_path, prune_repo_worktrees ~run_argv ~timeout_sec ~repo_path ~bundle_root)
    repo_dirs
;;

let log_outcomes ~keeper_name outcomes =
  List.iter
    (fun (repo_path, outcome) ->
       (* The fold accumulates with [::]; restore porcelain order for the log. *)
       (match List.rev outcome.removed with
        | [] -> ()
        | removed ->
          Log.Keeper.info
            ~keeper_name
            "dissolved keeper: removed %d worktree(s) of %s: %s"
            (List.length removed)
            repo_path
            (String.concat ", " removed));
       List.iter
         (fun (worktree_path, detail) ->
            Log.Keeper.warn
              ~keeper_name
              "dissolved keeper: worktree %s was not removed: %s"
              worktree_path
              detail)
         (List.rev outcome.failed);
       if not (String.equal outcome.skipped "")
       then
         Log.Keeper.warn
           ~keeper_name
           "dissolved keeper: worktrees of %s were not removed: %s"
           repo_path
           outcome.skipped)
    outcomes
;;

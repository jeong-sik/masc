open Keeper_meta_contract

type currency_cache_entry =
  { at : float
  ; outcome : Playground_repo_readiness.currency_outcome option
  }

(* Currency probe cache. [Playground_repo_readiness.ensure_current] may fetch
   and fast-forward the in-place sandbox clone, so Execute runs it only from
   this repo preflight layer, never from cwd/path resolution. *)
let currency_sync_cache : (string, currency_cache_entry) Hashtbl.t =
  Hashtbl.create 64

let currency_min_interval_sec = 30.0

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let log_currency_outcome ~repo_name = function
  | Playground_repo_readiness.Up_to_date -> ()
  | Advanced commits ->
    Log.Keeper.info
      "currency: advanced sandbox repo %s by %d commit(s)"
      repo_name
      commits
  | Preserved reason ->
    Log.Keeper.info "currency: preserved sandbox repo %s (%s)" repo_name reason
  | Skipped reason ->
    Log.Keeper.info "currency: skipped sandbox repo %s (%s)" repo_name reason

let repo_currency_outcome_best_effort ~config ~meta ~repo_name =
  let cpath = Playground_repo_readiness.clone_path ~config ~meta ~repo_name in
  let now = Unix.gettimeofday () in
  let cached = Hashtbl.find_opt currency_sync_cache cpath in
  let due =
    match cached with
    | Some { at; _ } -> now -. at >= currency_min_interval_sec
    | None -> true
  in
  if due
  then (
    try
      let outcome =
        Playground_repo_readiness.ensure_current ~config ~meta ~repo_name ()
      in
      log_currency_outcome ~repo_name outcome;
      Hashtbl.replace currency_sync_cache cpath { at = now; outcome = Some outcome };
      Some outcome
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ ->
      Hashtbl.replace currency_sync_cache cpath { at = now; outcome = None };
      None)
  else (
    match cached with
    | Some { outcome; _ } -> outcome
    | None -> None)

let invalidate_currency_cache ~config ~meta ~repo_name =
  let cpath = Playground_repo_readiness.clone_path ~config ~meta ~repo_name in
  Hashtbl.remove currency_sync_cache cpath
;;

let repo_currency_not_ready_error ~config ~meta ~repo_name ~reason ~cwd =
  let clone_path = Playground_repo_readiness.clone_path ~config ~meta ~repo_name in
  let hint_suffix =
    match Playground_repo_readiness.deleted_tracked_files_restore_hint ~clone_path with
    | Some hint -> " " ^ hint
    | None -> ""
  in
  Printf.sprintf
    "sandbox_repo_stale: sandbox repo root repos/%s is not current and was \
     preserved (%s). Direct repo-root Execute is blocked so the agent does not \
     run against stale local state. Use cwd=\"repos/%s/.worktrees/<task>\" for \
     task work, or run an allowed git diagnostic/recovery command before \
     retrying. Execute cwd resolution does not create directories or change \
     repo/worktree state.%s cwd=%s"
    repo_name
    reason
    repo_name
    hint_suffix
    cwd

let repo_currency_sync_disabled_error ~repo_name ~cwd =
  Printf.sprintf
    "sandbox_repo_currency_sync_disabled: readonly Execute will not fetch or \
     fast-forward direct sandbox repo root repos/%s. Use cwd=\"repos/%s/.worktrees/<task>\" \
     for task work, or run an allowed git diagnostic/recovery command before retrying. \
     Execute cwd resolution does not create directories or change repo/worktree state. \
     cwd=%s"
    repo_name
    repo_name
    cwd

let first_non_empty_line s =
  s
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun line -> not (String.equal line ""))

let git_probe_detail top =
  let git_toplevel = if top.Playground_repo_readiness.ok then Some top.output else None in
  let git_error =
    if top.Playground_repo_readiness.ok
    then None
    else first_non_empty_line top.Playground_repo_readiness.output
  in
  git_toplevel, git_error

let git_error_suffix = function
  | None -> ""
  | Some git_error -> Printf.sprintf "; git_error=%s" git_error

let repo_checkout_not_ready_error
      ~repo_name
      ~path_root
      ~path_is_worktree
      ~git_toplevel
      ~git_error
  =
  let git_toplevel = Option.value ~default:"<none>" git_toplevel in
  if path_is_worktree
  then
    Printf.sprintf
      "sandbox_worktree_not_ready: sandbox path is under \
       repos/%s/.worktrees, but %s is not a valid git worktree \
       (git_toplevel=%s%s). Execute cwd/path resolution does not create \
       directories or change repo/worktree state. Use an existing git \
       worktree under repos/%s/.worktrees/<task>, or provision the sandbox \
       worktree before retrying."
      repo_name
      path_root
      git_toplevel
      (git_error_suffix git_error)
      repo_name
  else
    Printf.sprintf
      "sandbox_repo_not_ready: sandbox path is under repos/%s, but %s is not \
       an independent git checkout (git_toplevel=%s%s). Execute cwd/path \
       resolution does not create directories or change repo/worktree state. \
       Use an existing repo path under repos/%s, or provision the sandbox repo \
       before retrying."
      repo_name
      path_root
      git_toplevel
      (git_error_suffix git_error)
      repo_name

let validate_repo_path_ready
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(probe_path : string)
      path
  =
  match Keeper_tool_execute_path.repo_path_context ~config ~meta ~path with
  | None -> Ok ()
  | Some
      { Keeper_tool_execute_path.path_repo_name = repo_name
      ; path_root
      ; path_is_worktree
      ; accepted_toplevels
      ; _
      } ->
    let top =
      Playground_repo_readiness.run_git
        ~timeout_sec:Playground_repo_readiness.read_only_probe_timeout_sec
        ~clone_path:probe_path
        [ "rev-parse"; "--show-toplevel" ]
    in
    let top_opt, git_error = git_probe_detail top in
    let top_matches =
      top.ok
      && List.exists
           (fun expected ->
              String.equal (normalize_path top.output) (normalize_path expected))
           accepted_toplevels
    in
    if top_matches
    then Ok ()
    else
      Error
        (repo_checkout_not_ready_error
           ~repo_name
           ~path_root
           ~path_is_worktree
           ~git_toplevel:top_opt
           ~git_error)

let validate_cwd_currency_ready
      ~allow_currency_sync
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~allow_stale_preserved_repo_context
  =
  match Keeper_tool_execute_path.repo_path_context ~config ~meta ~path:cwd with
  | None -> Ok ()
  | Some
      { Keeper_tool_execute_path.path_repo_name = repo_name
      ; path_repo_root = repo_root
      ; path_root
      ; _
      }
    when not (String.equal (normalize_path repo_root) (normalize_path path_root)) ->
    Ok ()
  | Some { Keeper_tool_execute_path.path_repo_name = repo_name; _ } ->
    if allow_stale_preserved_repo_context
    then Ok ()
    else if not allow_currency_sync
    then Error (repo_currency_sync_disabled_error ~repo_name ~cwd)
    else (
      match repo_currency_outcome_best_effort ~config ~meta ~repo_name with
      | Some Playground_repo_readiness.Up_to_date | Some (Advanced _) -> Ok ()
      | Some (Preserved reason) | Some (Skipped reason) ->
        Error (repo_currency_not_ready_error ~config ~meta ~repo_name ~reason ~cwd)
      | None ->
        Error
          (repo_currency_not_ready_error
             ~config
             ~meta
             ~repo_name
             ~reason:"currency probe failed"
             ~cwd))

let validate_cwd_ready
      ~allow_currency_sync
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~allow_stale_preserved_repo_context
  =
  match validate_repo_path_ready ~config ~meta ~probe_path:cwd cwd with
  | Error _ as err -> err
  | Ok () ->
    validate_cwd_currency_ready
      ~allow_currency_sync
      ~config
      ~meta
      ~cwd
      ~allow_stale_preserved_repo_context

let normalize_repo_command_name command_name =
  let command_name = String.lowercase_ascii command_name in
  if String.ends_with ~suffix:".exe" command_name
  then String.sub command_name 0 (String.length command_name - String.length ".exe")
  else command_name

let command_has_repo_path_args command_name =
  command_name = "git"
  || command_name = "gh"
  || Exec_policy_path_arg_descriptor.command_materializes_path_arg command_name

let path_args_of_simple simple =
  let command_name =
    Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin
    |> Filename.basename
    |> normalize_repo_command_name
  in
  if not (command_has_repo_path_args command_name)
  then []
  else (
    match Exec_policy.simple_literal_args simple with
    | None -> []
    | Some args -> Exec_policy.path_argument_values command_name args)

let path_args_of_effective_stage
      (stage : Masc_exec.Shell_ir_command_shape.stage)
  =
  let command_name =
    stage.bin |> Filename.basename |> normalize_repo_command_name
  in
  if command_has_repo_path_args command_name
  then Exec_policy.path_argument_values command_name stage.args
  else []

let rec path_args = function
  | Masc_exec.Shell_ir.Simple simple -> path_args_of_simple simple
  | Masc_exec.Shell_ir.Pipeline stages -> List.concat_map path_args stages

let validate_path_args_ready
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      (ir : Masc_exec.Shell_ir.t)
  =
  let all_path_args =
    path_args ir
    @ (Masc_exec.Shell_ir_command_shape.effective_stages ir
       |> List.concat_map path_args_of_effective_stage)
  in
  let validate_target seen raw =
    let trimmed = String.trim raw in
    if trimmed = ""
    then Ok seen
    else (
      let target =
        if Filename.is_relative trimmed then Filename.concat cwd trimmed else trimmed
      in
      match Keeper_tool_execute_path.repo_path_context ~config ~meta ~path:target with
      | None -> Ok seen
      | Some { Keeper_tool_execute_path.path_root; _ } ->
        let key = normalize_path path_root in
        if List.mem key seen
        then Ok seen
        else (
          match validate_repo_path_ready ~config ~meta ~probe_path:path_root target with
          | Ok () -> Ok (key :: seen)
          | Error _ as err -> err))
  in
  let validate_seen (expect_separated_path, seen) raw =
    let trimmed = String.trim raw in
    if expect_separated_path
    then Result.map (fun seen -> false, seen) (validate_target seen trimmed)
    else (
      match Exec_policy_path_arg_descriptor.path_value_of_flagged_token trimmed with
      | Some path -> Result.map (fun seen -> false, seen) (validate_target seen path)
      | None when Exec_policy_path_arg_descriptor.is_path_flag trimmed ->
        Ok (true, seen)
      | None -> Result.map (fun seen -> false, seen) (validate_target seen trimmed))
  in
  all_path_args
  |> List.fold_left
       (fun acc raw ->
          match acc with
          | Error _ as err -> err
          | Ok seen -> validate_seen seen raw)
       (Ok (false, []))
  |> Result.map (fun _ -> ())

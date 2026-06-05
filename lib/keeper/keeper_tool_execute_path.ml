open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let normalize_repo_cwd_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

type currency_cache_entry =
  { at : float
  ; outcome : Playground_repo_readiness.currency_outcome option
  }

(* Currency-sync fetch-rate cache. [Playground_repo_readiness.ensure_current]
   fetches origin before deciding whether to fast-forward, so calling it on
   every repo-targeting tool call would refetch many times per turn. This is a
   per-clone-path rate cache for an *idempotent* operation (not a failure
   cooldown): the fetch+advance runs at most once per [currency_min_interval_sec]
   per clone, which bounds the cost to roughly once per keeper turn. *)
let currency_sync_cache : (string, currency_cache_entry) Hashtbl.t =
  Hashtbl.create 64

let currency_min_interval_sec = 30.0

let log_currency_outcome ~repo_name = function
  | Playground_repo_readiness.Up_to_date -> ()
  | Advanced commits ->
    Log.Keeper.info "currency: advanced sandbox repo %s by %d commit(s)"
      repo_name commits
  | Preserved reason ->
    (* Local/divergent work kept. Keep this visible: otherwise a dirty or
       task-branch sandbox looks like the runtime simply forgot to update. *)
    Log.Keeper.info "currency: preserved sandbox repo %s (%s)" repo_name reason
  | Skipped reason ->
    (* Currency could not be established (missing/corrupt clone, no
       credential, or fetch failure). Visible by default so a recurring
       failure does not re-freeze the repo invisibly. *)
    Log.Keeper.info "currency: skipped sandbox repo %s (%s)" repo_name reason

(* Keep the keeper's sandbox clone current with origin/<default_branch> before
   code work. Best-effort: a failed advance never fails the turn, but
   [Eio.Cancel.Cancelled] is re-raised so turn cancellation is preserved. The
   advance is fast-forward-only and work-preserving (see [Playground_repo_readiness]).
   The typed outcome is logged rather than dropped: a [Skipped] sync is the very
   "repo silently frozen" failure this exists to fix, so it stays visible. *)
let repo_currency_outcome_best_effort ~config ~meta ~repo_name =
  let cpath = Playground_repo_readiness.clone_path ~config ~meta ~repo_name in
  let now = Unix.gettimeofday () in
  let cached = Hashtbl.find_opt currency_sync_cache cpath in
  let due =
    match cached with
    | Some { at; _ } -> now -. at >= currency_min_interval_sec
    | None -> true
  in
  if due then begin
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
      None
  end
  else
    match cached with
    | Some { outcome; _ } -> outcome
    | None -> None

let sync_repo_currency_best_effort ~config ~meta ~repo_name =
  let _outcome = repo_currency_outcome_best_effort ~config ~meta ~repo_name in
  ()

let repo_path_context ~(config : Workspace.config) ~(meta : keeper_meta) cwd =
  let playground =
    keeper_playground_root ~config ~meta
    |> normalize_repo_cwd_path
  in
  let repos_root = Filename.concat playground "repos" |> normalize_repo_cwd_path in
  let cwd = normalize_repo_cwd_path cwd in
  if String.equal cwd repos_root then None
  else
    let prefix = repos_root ^ "/" in
    if not (String.starts_with ~prefix cwd) then None
    else
      let suffix =
        String.sub cwd (String.length prefix) (String.length cwd - String.length prefix)
      in
      match String.split_on_char '/' suffix with
      | repo_name :: ".worktrees" :: task_name :: _
        when Playground_repo_readiness.safe_repo_component repo_name
             && Playground_repo_readiness.safe_repo_component task_name ->
        let repo_root = Filename.concat repos_root repo_name in
        let worktree_root =
          Filename.concat (Filename.concat repo_root ".worktrees") task_name
          |> normalize_repo_cwd_path
        in
        Some (repo_name, normalize_repo_cwd_path repo_root, worktree_root, [ worktree_root ])
      | repo_name :: _ when Playground_repo_readiness.safe_repo_component repo_name ->
        let repo_root = Filename.concat repos_root repo_name in
        let repo_root = normalize_repo_cwd_path repo_root in
        Some (repo_name, repo_root, repo_root, [ repo_root ])
      | _ -> None

type repo_cwd_context =
  { repo_name : string
  ; repo_root : string
  ; path_root : string
  ; is_direct_root : bool
  }

let repo_cwd_context ~config ~meta ~cwd =
  let cwd = normalize_repo_cwd_path cwd in
  match repo_path_context ~config ~meta cwd with
  | Some (repo_name, repo_root, path_root, _) ->
    Some { repo_name; repo_root; path_root; is_direct_root = String.equal repo_root cwd }
  | None -> None

let invalidate_repo_currency_cache ~config ~meta ~repo_name =
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
     task work, or run diagnostic git status/branch/log/diff/remote/rev-parse/\
     fetch/worktree and clean, stash, or repair the sandbox repo root before \
     retrying.%s cwd=%s"
    repo_name
    reason
    repo_name
    hint_suffix
    cwd

let validate_repo_cwd_currency_ready
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      ~allow_stale_preserved_repo_context
  =
  match repo_path_context ~config ~meta cwd with
  | None -> Ok ()
  | Some (repo_name, repo_root, path_root, _accepted_toplevels)
    when not
           (String.equal
              (normalize_repo_cwd_path repo_root)
              (normalize_repo_cwd_path path_root)) ->
    Ok ()
  | Some (repo_name, _repo_root, _path_root, _accepted_toplevels) ->
    if allow_stale_preserved_repo_context
    then Ok ()
    else
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
             ~cwd)

type execution_location_scope =
  | Playground_root
  | Playground_subpath
  | Repo_root
  | Repo_subpath
  | Repo_worktree_root
  | Repo_worktree_subpath
  | Outside_playground

let string_of_execution_location_scope = function
  | Playground_root -> "playground_root"
  | Playground_subpath -> "playground_subpath"
  | Repo_root -> "repo_root"
  | Repo_subpath -> "repo_subpath"
  | Repo_worktree_root -> "repo_worktree_root"
  | Repo_worktree_subpath -> "repo_worktree_subpath"
  | Outside_playground -> "outside_playground"

let path_segments path =
  path
  |> normalize_repo_cwd_path
  |> String.split_on_char '/'
  |> List.filter (fun segment -> not (String.equal segment ""))

let strip_segment_prefix ~prefix segments =
  let rec loop prefix segments =
    match prefix, segments with
    | [], rest -> Some rest
    | p :: ps, s :: ss when String.equal p s -> loop ps ss
    | _ -> None
  in
  loop prefix segments

let relative_path_of_segments = function
  | [] -> "."
  | segments -> String.concat "/" segments

let execution_location_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~(cwd : string)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let cwd_source =
    if String.equal raw_cwd "" then "default_playground_root" else "explicit_cwd"
  in
  let playground =
    keeper_playground_root ~config ~meta
    |> normalize_repo_cwd_path
  in
  let cwd = normalize_repo_cwd_path cwd in
  let playground_segments = path_segments playground in
  let cwd_segments = path_segments cwd in
  let scope, relative_segments, repo_name, repo_root, worktree_name, worktree_root =
    match strip_segment_prefix ~prefix:playground_segments cwd_segments with
    | None -> Outside_playground, [], None, None, None, None
    | Some [] -> Playground_root, [], None, None, None, None
    | Some ("repos" :: repo_name :: rest)
      when Playground_repo_readiness.safe_repo_component repo_name ->
      let repo_root =
        Filename.concat (Filename.concat playground "repos") repo_name
        |> normalize_repo_cwd_path
      in
      (match rest with
       | [] ->
         Repo_root, [ "repos"; repo_name ], Some repo_name, Some repo_root, None, None
       | ".worktrees" :: task_name :: tail
         when Playground_repo_readiness.safe_repo_component task_name ->
         let worktree_root =
           Filename.concat (Filename.concat repo_root ".worktrees") task_name
           |> normalize_repo_cwd_path
         in
         let scope =
           match tail with
           | [] -> Repo_worktree_root
           | _ -> Repo_worktree_subpath
         in
         ( scope
         , [ "repos"; repo_name; ".worktrees"; task_name ] @ tail
         , Some repo_name
         , Some repo_root
         , Some task_name
         , Some worktree_root )
       | _ ->
         Repo_subpath, [ "repos"; repo_name ] @ rest, Some repo_name, Some repo_root, None, None)
    | Some rest -> Playground_subpath, rest, None, None, None, None
  in
  let relative_cwd =
    match scope with
    | Outside_playground -> `Null
    | _ -> `String (relative_path_of_segments relative_segments)
  in
  let selected_worktree =
    match repo_name, repo_root, worktree_name, worktree_root with
    | Some repo_name, Some repo_root, Some worktree_name, Some worktree_root ->
      `Assoc
        [ "repo_name", `String repo_name
        ; "repo_root", `String repo_root
        ; "worktree_name", `String worktree_name
        ; "worktree_root", `String worktree_root
        ; "selection_source", `String "execution_cwd"
        ; "scope", `String (string_of_execution_location_scope scope)
        ; "relative_cwd", relative_cwd
        ]
    | _ -> `Null
  in
  `Assoc
    [ "cwd", `String cwd
    ; "cwd_source", `String cwd_source
    ; "scope", `String (string_of_execution_location_scope scope)
    ; "playground_root", `String playground
    ; "relative_cwd", relative_cwd
    ; "relative_path_base", `String cwd
    ; "argv_relative_paths_resolve_against_cwd", `Bool true
    ; "repo_name", Json_util.string_opt_to_json repo_name
    ; "repo_root", Json_util.string_opt_to_json repo_root
    ; "worktree_selected", `Bool (Option.is_some worktree_root)
    ; "worktree_name", Json_util.string_opt_to_json worktree_name
    ; "worktree_root", Json_util.string_opt_to_json worktree_root
    ; "selected_worktree", selected_worktree
    ]

let repo_cwd_not_ready_error ~repo_name ~path_root ~git_toplevel =
  Printf.sprintf
    "sandbox_repo_not_ready: sandbox path is under repos/%s, but %s is not an \
     independent git checkout (git_toplevel=%s). Repair or reclone the sandbox \
     repo under repos/%s, then retry with cwd=\"repos/%s\". If the call is \
     running inside a docker sandbox, ensure the docker playground mount \
     includes the worktree subdirectory (or set cwd to the in-place repo root \
     \"repos/%s\" if the keeper works directly in the clone)."
    repo_name
    path_root
    (Option.value ~default:"<none>" git_toplevel)
    repo_name
    repo_name
    repo_name

(** [extract_worktree_task_name cwd] extracts the task name if [cwd] is under a
    [.worktrees/<task>] path.  Returns [Some (repo_name, task_name, worktree_root)]
    or [None]. *)
let extract_worktree_task_name ~(config : Workspace.config) ~(meta : keeper_meta) cwd =
  let playground =
    keeper_playground_root ~config ~meta
    |> normalize_repo_cwd_path
  in
  let repos_root = Filename.concat playground "repos" |> normalize_repo_cwd_path in
  let cwd = normalize_repo_cwd_path cwd in
  let prefix = repos_root ^ "/" in
  if not (String.starts_with ~prefix cwd) then None
  else
    let suffix =
      String.sub cwd (String.length prefix) (String.length cwd - String.length prefix)
    in
    match String.split_on_char '/' suffix with
    | repo_name :: ".worktrees" :: task_name :: _
      when Playground_repo_readiness.safe_repo_component repo_name
           && Playground_repo_readiness.safe_repo_component task_name ->
      let worktree_root =
        Filename.concat (Filename.concat (Filename.concat repos_root repo_name) ".worktrees") task_name
        |> normalize_repo_cwd_path
      in
      Some (repo_name, task_name, worktree_root)
    | _ -> None

let validate_repo_path_ready
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(probe_path : string)
      cwd
  =
  match repo_path_context ~config ~meta cwd with
  | None -> Ok ()
  | Some (repo_name, _repo_root, path_root, accepted_toplevels) ->
    sync_repo_currency_best_effort ~config ~meta ~repo_name;
    let check_probe () =
      let top =
        Playground_repo_readiness.run_git
          ~timeout_sec:Playground_repo_readiness.read_only_probe_timeout_sec
          ~clone_path:probe_path
          [ "rev-parse"; "--show-toplevel" ]
      in
      let top_opt = if top.ok then Some top.output else None in
      let top_matches =
        top.ok
        && List.exists
             (fun expected ->
                String.equal
                  (normalize_repo_cwd_path top.output)
                  (normalize_repo_cwd_path expected))
             accepted_toplevels
      in
      if top_matches then Ok ()
      else
        Error
          (repo_cwd_not_ready_error ~repo_name ~path_root ~git_toplevel:top_opt)
    in
    match check_probe () with
    | Ok () -> Ok ()
    | Error _ as initial_err ->
      (* Auto-repair: for worktree paths, try worktree creation first;
         for direct repo paths, try reclone. *)
      let worktree_result =
        match extract_worktree_task_name ~config ~meta cwd with
        | Some (wt_repo_name, task_name, worktree_root) ->
          Playground_repo_readiness.ensure_worktree_ready
            ~config ~meta ~repo_name:wt_repo_name ~task_name
            ~worktree_path:worktree_root ()
        | None -> Error "not a worktree path"
      in
      match worktree_result with
      | Ok () -> check_probe ()
      | Error _ ->
        (* Fall back to repo-level reclone *)
        (match
           Playground_repo_readiness.ensure_ready ~config ~meta ~repo_name ()
         with
         | Ok () -> check_probe ()
         | Error _repair_err -> initial_err)

let validate_repo_cwd_ready ~(config : Workspace.config) ~(meta : keeper_meta) cwd =
  validate_repo_path_ready ~config ~meta ~probe_path:cwd cwd

let resolve_missing_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      cwd
  =
  match repo_path_context ~config ~meta cwd with
  | Some _ ->
    (match validate_repo_cwd_ready ~config ~meta cwd with
     | Ok () -> Ok cwd
     | Error _ as err -> err)
  | None ->
    let _created_path = Keeper_fs.ensure_dir cwd in
    Ok cwd

let resolve_tool_read_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_read_root ~config ~meta)
    else resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then
      resolve_missing_cwd ~config ~meta cwd
    else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

let validate_repo_path_args_ready
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      (ir : Masc_exec.Shell_ir.t)
  =
  let normalize_repo_command_name command_name =
    let command_name = String.lowercase_ascii command_name in
    if String.ends_with ~suffix:".exe" command_name
    then String.sub command_name 0 (String.length command_name - String.length ".exe")
    else command_name
  in
  let command_has_repo_path_args command_name =
    command_name = "git"
    || command_name = "gh"
    || Exec_policy_path_arg_descriptor.command_materializes_path_arg command_name
  in
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
  in
  let path_args_of_effective_stage
      (stage : Masc_exec.Shell_ir_command_shape.stage)
    =
    let command_name =
      stage.bin |> Filename.basename |> normalize_repo_command_name
    in
    if command_has_repo_path_args command_name
    then Exec_policy.path_argument_values command_name stage.args
    else []
  in
  let rec path_args = function
    | Masc_exec.Shell_ir.Simple simple ->
      path_args_of_simple simple
    | Masc_exec.Shell_ir.Pipeline stages ->
      List.concat_map path_args stages
  in
  let all_path_args =
    path_args ir
    @ (Masc_exec.Shell_ir_command_shape.effective_stages ir
       |> List.concat_map path_args_of_effective_stage)
  in
  let validate_target seen raw =
    let trimmed = String.trim raw in
    if trimmed = "" then Ok seen
    else
      let target =
        if Filename.is_relative trimmed then Filename.concat cwd trimmed else trimmed
      in
      match repo_path_context ~config ~meta target with
      | None -> Ok seen
      | Some (_repo_name, _repo_root, path_root, _accepted_toplevels) ->
        let key = normalize_repo_cwd_path path_root in
        if List.mem key seen then Ok seen
        else (
          match
            validate_repo_path_ready
              ~config
              ~meta
              ~probe_path:path_root
              target
          with
          | Ok () -> Ok (key :: seen)
          | Error _ as err -> err)
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

let resolve_tool_write_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let raw_cwd_is_own_container_path =
    if Filename.is_relative raw_cwd
       || meta.sandbox_profile <> Keeper_types_profile_sandbox.Docker
    then false
    else (
      let normalize path =
        Keeper_alerting_path.normalize_path_for_check path
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      let container_root = Keeper_sandbox.container_root meta.name |> normalize in
      let raw_norm = normalize raw_cwd in
      String.equal raw_norm container_root
      || String.starts_with ~prefix:(container_root ^ "/") raw_norm)
  in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_write_root ~config ~meta)
    else resolve_keeper_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd ->
    if raw_cwd_is_own_container_path
    then Ok cwd
    else (
      match validate_repo_cwd_ready ~config ~meta cwd with
      | Ok () -> Ok cwd
      | Error _ as err -> err)
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then
      resolve_missing_cwd ~config ~meta cwd
    else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

(* Docker playground path mapping: host → container.
   Host:      <base_path>/.masc/playground/<keeper>/repos/X
   Container: <container_playground_root>/<keeper>/repos/X
   The container-side root comes from
   [Env_config_sandbox.Runtime.docker_playground_container_root ()] so the
   mount point is configurable (default "/home/keeper/playground"). *)
let _docker_playground_cwd ~(config : Workspace.config) ~(meta : keeper_meta) host_cwd =
  let root = Keeper_alerting_path.project_root_of_config config in
  let playground_prefix =
    Filename.concat root Playground_paths.all_playgrounds_prefix
  in
  let container_root =
    Env_config_sandbox.Runtime.docker_playground_container_root ()
  in
  (* Boundary-safe prefix match: require either an exact match or a
     prefix ending at a path separator. Without this, host paths like
     "<root>/.masc/playgroundXYZ/..." would match "<root>/.masc/playground"
     and leak into the container playground. *)
  let prefix_with_sep = playground_prefix ^ "/" in
  let starts_at_boundary =
    host_cwd = playground_prefix
    || String.starts_with ~prefix:prefix_with_sep host_cwd
  in
  if starts_at_boundary then
    if host_cwd = playground_prefix then container_root
    else
      let raw_suffix =
        String.sub host_cwd (String.length prefix_with_sep)
          (String.length host_cwd - String.length prefix_with_sep)
      in
      (* A [host_cwd] like ".../.masc/playground//cheolsu/..." produces a
         [raw_suffix] that starts with "/". [Filename.concat] would then
         treat [raw_suffix] as an absolute path and drop [container_root],
         silently escaping the mount. Strip any leading slashes so the
         suffix is always a strict relative segment. *)
      let suffix =
        let n = String.length raw_suffix in
        let i = ref 0 in
        while !i < n && raw_suffix.[!i] = '/' do incr i done;
        if !i = 0 then raw_suffix
        else String.sub raw_suffix !i (n - !i)
      in
      if suffix = "" then container_root
      else Filename.concat container_root suffix
  else
    (* meta.name is sanitized through Playground_paths so a poisoned
       name cannot escape the container_root. *)
    Filename.concat container_root
      (Playground_paths.sanitize_keeper_name meta.name)

(* Common wrong path prefixes that keepers use.
   Maps wrong prefix → corrected relative path using the keeper
   playground SSOT ([Playground_paths]). [sanitize_keeper_name] in the
   SSOT rejects "", "." and ".." as whole-name segments (substituting
   "_", "_", "__" respectively), so a poisoned [meta.name] cannot
   produce a ".."/"." directory component and cannot escape the
   playground bundle via [Filename.concat]. *)
let auto_correct_path ~(meta : keeper_meta) (raw : string) : string option =
  (* bundle_root yields ".masc/playground/<safe>/" — strip the trailing
     slash so we can append "/repos/..." cleanly. *)
  let playground_bundle = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let playground =
    if String.ends_with ~suffix:"/" playground_bundle
    then String.sub playground_bundle 0 (String.length playground_bundle - 1)
    else playground_bundle
  in
  let try_strip prefix replacement =
    let plen = String.length prefix in
    if String.length raw >= plen
       && String.sub raw 0 plen = prefix
    then Some (replacement ^ String.sub raw plen (String.length raw - plen))
    else None
  in
  (* /repos/X → .masc/playground/<safe-name>/repos/X *)
  match try_strip "/repos/" (playground ^ "/repos/") with
  | Some _ as r -> r
  | None ->
  match try_strip "repos/" (playground ^ "/repos/") with
  | Some _ as r -> r
  | None ->
  match try_strip "playground/" (Playground_paths.all_playgrounds_prefix ^ "/") with
  | Some _ as r -> r
  | None -> None

let resolve_tool_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  let resolve_with_autocorrect raw_path_to_resolve =
    match resolve_keeper_read_path ~config ~meta ~raw_path:raw_path_to_resolve with
    | Ok _ as ok -> ok
    | Error original_err ->
      (* Try auto-correcting common wrong prefixes *)
      match auto_correct_path ~meta raw_path_to_resolve with
      | Some corrected ->
        (match resolve_keeper_read_path ~config ~meta ~raw_path:corrected with
         | Ok resolved ->
           Log.Keeper.info "%s: auto-corrected path %S → %S"
             meta.name raw_path_to_resolve resolved;
           Ok resolved
         | Error _ -> Error original_err)
      | None -> Error original_err
  in
  match resolve_tool_read_cwd ~config ~meta ~args with
  | Error _ as err when raw_path = "" -> err
  | Error _ ->
    let fallback_path = if raw_path = "" then "." else raw_path in
    resolve_with_autocorrect fallback_path
  | Ok cwd ->
    if raw_path = ""
    then Ok cwd
    else if
      (not (Filename.is_relative raw_path)) || is_playground_lane_relative_path raw_path
    then resolve_with_autocorrect raw_path
    else
      let projected_path = Filename.concat cwd raw_path in
      resolve_projected_keeper_read_path
        ~config
        ~meta
        ~raw_for_error:raw_path
        ~projected_path

let executable_file path =
  try
    let st = Unix.stat path in
    st.Unix.st_kind = Unix.S_REG
    &&
    (Unix.access path [ Unix.X_OK ];
     true)
  with
  | Unix.Unix_error _ | Sys_error _ -> false

let path_has_executable name =
  match Sys.getenv_opt "PATH" with
  | None -> false
  | Some path ->
    path
    |> String.split_on_char ':'
    |> List.exists (fun dir ->
      (* Do not mirror the shell's empty-PATH current-directory fallback
         for keeper probes; only explicit directories are trusted. *)
      dir <> "" && executable_file (Filename.concat dir name))

let shell_command_available name =
  let name = String.trim name in
  if name = "" then false
  else if String.contains name '/' then executable_file name
  else path_has_executable name

let normalize_for_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let in_playground ~root ~cwd ~meta =
  let cwd_canonical = normalize_for_containment cwd in
  let playground_rel = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let playground_abs = normalize_for_containment (Filename.concat root playground_rel) in
  String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
  || String.equal playground_abs cwd_canonical

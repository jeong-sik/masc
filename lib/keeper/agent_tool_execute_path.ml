open Keeper_types
open Agent_tool_shared_runtime

let resolve_tool_read_cwd
      ~(config : Coord.config)
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
    if not (Fs_compat.file_exists cwd) then begin
      (* Auto-create missing CWD under the sandbox.  The path has already
         passed [resolve_keeper_read_path] sandbox containment, so creating
         it is safe.  This handles stale worktree references and first-run
         repo directories that the LLM targets before clone. *)
      ignore (Keeper_fs.ensure_dir cwd);
      Ok cwd
    end else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

let normalize_repo_cwd_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let repo_path_context ~(config : Coord.config) ~(meta : keeper_meta) cwd =
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
        when Keeper_repo_readiness.safe_repo_component repo_name
             && Keeper_repo_readiness.safe_repo_component task_name ->
        let repo_root = Filename.concat repos_root repo_name in
        let worktree_root =
          Filename.concat (Filename.concat repo_root ".worktrees") task_name
        in
        Some (repo_name, repo_root, worktree_root, [ worktree_root ])
      | repo_name :: _ when Keeper_repo_readiness.safe_repo_component repo_name ->
        let repo_root = Filename.concat repos_root repo_name in
        Some (repo_name, repo_root, repo_root, [ repo_root ])
      | _ -> None

let repo_cwd_not_ready_error ~repo_name ~repo_root ~git_toplevel =
  Printf.sprintf
    "sandbox_repo_not_ready: sandbox path is under repos/%s, but %s is not an \
     independent git checkout (git_toplevel=%s). Repair or reclone the sandbox \
     repo under repos/%s, then retry with cwd=\"repos/%s\" or \
     cwd=\"repos/%s/.worktrees/<task>\"."
    repo_name
    repo_root
    (Option.value ~default:"<none>" git_toplevel)
    repo_name
    repo_name
    repo_name

let validate_repo_path_ready
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(probe_path : string)
      cwd
  =
  match repo_path_context ~config ~meta cwd with
  | None -> Ok ()
  | Some (repo_name, repo_root, _path_root, accepted_toplevels) ->
    if not (safe_is_dir probe_path) then
      Error
        (repo_cwd_not_ready_error ~repo_name ~repo_root ~git_toplevel:None)
    else
      let top =
        Keeper_repo_readiness.run_git
          ~timeout_sec:Keeper_repo_readiness.read_only_probe_timeout_sec
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
          (repo_cwd_not_ready_error ~repo_name ~repo_root ~git_toplevel:top_opt)

let validate_repo_cwd_ready ~(config : Coord.config) ~(meta : keeper_meta) cwd =
  validate_repo_path_ready ~config ~meta ~probe_path:cwd cwd

let validate_repo_path_args_ready
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(cwd : string)
      (ir : Masc_exec.Shell_ir.t)
  =
  let path_args_of_simple simple =
    let command_name =
      Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin
      |> Filename.basename
    in
    match Exec_policy.simple_literal_args simple with
    | None -> []
    | Some args -> Exec_policy.path_argument_values command_name args
  in
  let rec path_args = function
    | Masc_exec.Shell_ir.Simple simple ->
      path_args_of_simple simple
    | Masc_exec.Shell_ir.Pipeline stages ->
      List.concat_map path_args stages
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
      | Some (_repo_name, repo_root, path_root, _accepted_toplevels) ->
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
  path_args ir
  |> List.fold_left
       (fun acc raw ->
          match acc with
          | Error _ as err -> err
          | Ok seen -> validate_seen seen raw)
       (Ok (false, []))
  |> Result.map (fun _ -> ())

let resolve_tool_write_cwd
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (keeper_default_write_root ~config ~meta)
    else resolve_keeper_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd ->
    (match validate_repo_cwd_ready ~config ~meta cwd with
     | Ok () -> Ok cwd
     | Error _ as err -> err)
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then begin
      ignore (Keeper_fs.ensure_dir cwd);
      match validate_repo_cwd_ready ~config ~meta cwd with
      | Ok () -> Ok cwd
      | Error _ as err -> err
    end else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

(* Docker playground path mapping: host → container.
   Host:      <base_path>/.masc/playground/<keeper>/repos/X
   Container: <container_playground_root>/<keeper>/repos/X
   The container-side root comes from
   [Env_config_sandbox.Runtime.docker_playground_container_root ()] so the
   mount point is configurable (default "/home/keeper/playground"). *)
let _docker_playground_cwd ~(config : Coord.config) ~(meta : keeper_meta) host_cwd =
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
      ~(config : Coord.config)
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
    let resolved_raw_path =
      if raw_path = "" then
        cwd
      else if not (Filename.is_relative raw_path) then
        raw_path
      else
        (* Guard against playground path doubling: when cwd already
           contains a playground prefix (e.g. .../playground/keeper/)
           and raw_path also starts with a playground-relative segment
           (e.g. ".masc/playground/keeper/repos"), concatenating would
           produce a doubled path.  Detect and resolve against project
           root instead. *)
        let pg = Playground_paths.all_playgrounds_prefix in
        let contains s sub =
          let sl = String.length s and nl = String.length sub in
          if nl > sl then false
          else
            let rec scan i =
              if i + nl > sl then false
              else if String.sub s i nl = sub then true
              else scan (i + 1)
            in scan 0
        in
        let cwd_has_pg = contains cwd pg in
        let path_has_pg = contains raw_path pg in
        if cwd_has_pg && path_has_pg then
          raw_path
        else
          Filename.concat cwd raw_path
    in
    let resolver_path =
      if raw_path = "" || Filename.is_relative raw_path then
        Option.value ~default:resolved_raw_path
          (project_relative_host_path ~config resolved_raw_path)
      else
        resolved_raw_path
    in
    resolve_with_autocorrect resolver_path

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

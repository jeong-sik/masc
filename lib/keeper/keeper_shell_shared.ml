open Keeper_types
open Keeper_exec_shared

include Keeper_shell_variant
include Keeper_shell_timeout

let git_global_option_takes_value = function
  | "-c" | "-C" | "--exec-path" | "--git-dir" | "--work-tree"
  | "--namespace" | "--super-prefix" | "--config-env" -> true
  | _ -> false

let git_global_option_has_inline_value token =
  List.exists (fun prefix -> String.starts_with ~prefix token)
    [ "--exec-path="; "--git-dir="; "--work-tree="; "--namespace="; "--config-env=" ]

let rec first_git_subcommand = function
  | [] -> None
  | token :: rest when git_global_option_takes_value token ->
      (match rest with
       | _value :: tail -> first_git_subcommand tail
       | [] -> None)
  | token :: rest when git_global_option_has_inline_value token ->
      first_git_subcommand rest
  | token :: rest when String.starts_with ~prefix:"-" token ->
      first_git_subcommand rest
  | token :: _rest -> Some token

let process_status_is_timeout = function
  | Unix.WSIGNALED sig_num -> sig_num = Sys.sigterm
  | Unix.WEXITED 124 -> true  (* Process_eio returns 124 on Eio.Time.Timeout *)
  | _ -> false

let replace_all_substrings ~needle ~replacement text =
  let needle_len = String.length needle in
  if needle_len = 0 || not (String_util.contains_substring text needle) then text
  else
    let text_len = String.length text in
    let buf = Buffer.create text_len in
    let rec loop i =
      if i >= text_len then ()
      else if i + needle_len <= text_len
              && String.sub text i needle_len = needle then (
        Buffer.add_string buf replacement;
        loop (i + needle_len))
      else (
        Buffer.add_char buf text.[i];
        loop (i + 1))
    in
    loop 0;
    Buffer.contents buf

let rewrite_turn_runtime_paths_to_host
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      text
  =
  replace_all_substrings
    ~needle:(Keeper_sandbox.container_root meta.name)
    ~replacement:
      (Keeper_sandbox.host_root_abs_of_meta ~config meta
       |> Keeper_alerting_path.strip_trailing_slashes)
    text

let rewrite_docker_host_paths_to_container
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      text
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let container_root =
    Keeper_sandbox.container_root meta.name
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:raw_host_root ~container_root text
  in
  if String.equal raw_host_root normalized_host_root then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:normalized_host_root ~container_root rewritten

let run_argv_with_status_retry_eintr ?cwd ~timeout_sec argv =
  let max_eintr_retries = 8 in
  let rec loop attempts_left =
    let result =
      Masc_exec.Exec_gate.run_argv_with_status ~actor:`Keeper_shell
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper shell command" ?cwd ~timeout_sec argv
    in
    match result with
    | Unix.WEXITED 127, out
      when attempts_left > 0
           && String_util.contains_substring_ci out "interrupted system call" ->
        loop (attempts_left - 1)
    | _ -> result
  in
  loop max_eintr_retries

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

(** Write playground repo state cache after successful clone/pull.
    Reads git metadata from [repo_path] and upserts into
    [playground_dir/.playground_state.json]. Best-effort: failures are logged
    but do not propagate. *)
let update_playground_repo_cache
      ~(playground_dir : string) ~(repo_name : string) ~(repo_path : string)
      ~(action : string) ~(shallow : bool) : unit =
  Playground_repo_cache.update ~playground_dir ~repo_name ~repo_path ~action
    ~shallow

let resolve_keeper_shell_read_cwd
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
    let exists = Fs_compat.file_exists cwd in
    let detail =
      if not exists then "path_does_not_exist"
      else "path_is_file_not_directory"
    in
    Error (Printf.sprintf "cwd_not_directory: %s (%s)" cwd detail)

let resolve_keeper_shell_write_cwd
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
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    (match Keeper_task_worktree_lazy.ensure_path ~site:"write_cwd" ~config ~meta ~path:cwd with
     | Ok Keeper_task_worktree_lazy.Created
     | Ok Keeper_task_worktree_lazy.Already_present ->
       if Fs_compat.file_exists cwd && Sys.is_directory cwd
       then Ok cwd
       else Error (Printf.sprintf "cwd_not_directory: %s" cwd)
     | Ok Keeper_task_worktree_lazy.Not_current_task_worktree ->
       Error (Printf.sprintf "cwd_not_directory: %s" cwd)
     | Error msg -> Error msg)

(* Docker playground path mapping: host → container.
   Host:      <base_path>/.masc/playground/<keeper>/repos/X
   Container: <container_playground_root>/<keeper>/repos/X
   The container-side root comes from
   [Env_config_keeper.DockerPlayground.container_playground_root] so the
   mount point is configurable (default "/home/keeper/playground"). *)
let _docker_playground_cwd ~(config : Coord.config) ~(meta : keeper_meta) host_cwd =
  let root = Keeper_alerting_path.project_root_of_config config in
  let playground_prefix =
    Filename.concat root Playground_paths.all_playgrounds_prefix
  in
  let container_root =
    Env_config_keeper.DockerPlayground.container_playground_root
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

let resolve_keeper_shell_read_path
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
  match resolve_keeper_shell_read_cwd ~config ~meta ~args with
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

(* Sandbox infrastructure stays in Keeper_shell_docker; command-shape
   interpretation stays in Keeper_shell_command_semantics. *)
let effective_sandbox_profile = Keeper_shell_docker.effective_sandbox_profile
let stages_targets_git_or_gh = Keeper_shell_command_semantics.stages_targets_git_or_gh
let stages_targets_gh = Keeper_shell_command_semantics.stages_targets_gh

let ensure_keeper_sandbox_runtime = Keeper_shell_docker.ensure_keeper_sandbox_runtime
let command_uses_nested_container_runtime = Keeper_shell_docker.command_uses_nested_container_runtime
let run_docker_shell_command_with_status = Keeper_shell_docker.run_docker_shell_command_with_status
let run_docker_credentialed_bash = Keeper_shell_docker.run_docker_credentialed_bash
let run_docker_bash = Keeper_shell_docker.run_docker_bash

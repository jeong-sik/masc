open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let resolve_missing_cwd cwd =
  Error (Printf.sprintf "cwd_not_directory: %s (directory does not exist)" cwd)

let resolve_tool_read_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta)
    else resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then resolve_missing_cwd cwd
    else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

let resolve_tool_execute_cwd ~config ~meta ~write_enabled ~args =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then
      Ok
        (if write_enabled
         then keeper_default_write_root ~config ~meta
         else Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta)
    else resolve_keeper_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then resolve_missing_cwd cwd
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

let resolve_tool_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  match resolve_tool_read_cwd ~config ~meta ~args with
  | Error _ as error -> error
  | Ok cwd ->
    if raw_path = ""
    then Ok cwd
    else
      let projected_path =
        if Filename.is_relative raw_path then Filename.concat cwd raw_path else raw_path
      in
      resolve_projected_keeper_read_path
        ~config
        ~meta
        ~raw_for_error:raw_path
        ~projected_path

let shell_command_available name =
  Executable_path.command_available name

let normalize_for_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let in_playground ~root ~cwd ~meta =
  let cwd_canonical = normalize_for_containment cwd in
  let playground_rel = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let playground_abs = normalize_for_containment (Filename.concat root playground_rel) in
  String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
  || String.equal playground_abs cwd_canonical

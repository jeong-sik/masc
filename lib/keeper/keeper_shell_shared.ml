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

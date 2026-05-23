open Keeper_types
open Keeper_exec_shared

include Keeper_shell_variant
include Keeper_shell_timeout

let process_status_is_timeout = function
  | Unix.WSIGNALED sig_num -> sig_num = Sys.sigterm
  | Unix.WEXITED 124 -> true  (* Process_eio returns 124 on Eio.Time.Timeout *)
  | _ -> false

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
(** Docker exec failure formatting + recording.

    Extracted from [keeper_shell_docker.ml] (lines 16-120) as part of
    the godfile decomp campaign. Owns the failure-message pipeline:

    1. [docker_exec_status_label] — exit-status → wire label
    2. [docker_exec_failure_message_internal] — full message with
       optional context (base_path_hash, keeper_name, container_kind,
       network_label) + missing-cwd hint + mount-failure context
       suffix.
    3. [docker_exec_failure_message] — context-less convenience
       wrapper (kept for an existing external caller).
    4. [docker_exec_failure_message_with_context] — required-context
       wrapper used by [record_docker_exec_failure].
    5. [record_docker_exec_failure] — persists the failure on the
       keeper registry (via [Keeper_registry_error_recording.record])
       along with structured [docker_mount_failure_details]. *)

open Keeper_types

let docker_exec_status_label = function
  | Unix.WEXITED n -> Printf.sprintf "exit=%d" n
  | Unix.WSIGNALED n -> Printf.sprintf "signal=%d" n
  | Unix.WSTOPPED n -> Printf.sprintf "stopped=%d" n
;;

let docker_exec_failure_message_internal
      ?base_path_hash
      ?keeper_name
      ?container_kind
      ?network_label
      ~image
      ~status
      ~output
      ()
  =
  let truncated = Keeper_sandbox_runtime.docker_failure_output_for_log output in
  let output_label = if String.trim truncated = "" then "<no output>" else truncated in
  let missing_cwd_hint =
    if
      String_util.contains_substring output "cd:"
      && String_util.contains_substring output "No such file or directory"
    then
      " hint=cwd_not_directory: create or repair the sandbox repo/worktree first \
       (keeper_shell op=git_clone, then git_worktree/masc_worktree_create for \
       repos/<repo>/.worktrees/<task>)."
    else ""
  in
  let mount_failure_context =
    Keeper_sandbox_runtime.docker_mount_failure_context_suffix
      ?base_path_hash
      ?keeper_name
      ~image
      ~status_label:(docker_exec_status_label status)
      ?container_kind
      ?network_label
      output
  in
  Printf.sprintf
    "sandbox docker exec failed (%s, %s): %s%s%s"
    image
    (docker_exec_status_label status)
    output_label
    missing_cwd_hint
    mount_failure_context
;;

let docker_exec_failure_message ~image ~status ~output =
  docker_exec_failure_message_internal ~image ~status ~output ()
;;

let docker_exec_failure_message_with_context
      ~base_path_hash
      ~keeper_name
      ~container_kind
      ~network_label
      ~image
      ~status
      ~output
  =
  docker_exec_failure_message_internal
    ~base_path_hash
    ~keeper_name
    ~container_kind
    ~network_label
    ~image
    ~status
    ~output
    ()
;;

let record_docker_exec_failure
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~image
      ~container_kind
      ~network_label
      ~status
      ~output
  =
  let base_path_hash = Keeper_sandbox_runtime.base_path_hash config.base_path in
  let status_label = docker_exec_status_label status in
  let message =
    docker_exec_failure_message_with_context
      ~base_path_hash
      ~keeper_name:meta.name
      ~container_kind
      ~network_label
      ~image
      ~status
      ~output
  in
  let details =
    Keeper_sandbox_runtime.docker_mount_failure_details
      ~base_path_hash
      ~keeper_name:meta.name
      ~image
      ~status_label
      ~container_kind
      ~network_label
      ~output
      ()
  in
  Keeper_registry_error_recording.record ?details ~base_path:config.base_path meta.name message
;;

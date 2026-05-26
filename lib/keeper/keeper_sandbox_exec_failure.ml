(** Sandbox backend exec failure formatting + recording.

    Owns backend failure messages and keeper-registry recording. The
    command surface ([keeper_bash], [keeper_shell], PR tools, etc.) is
    intentionally not part of this module name because the same sandbox
    backend failure can be reached through multiple tools.

    1. [status_label] - exit-status -> wire label
    2. [docker_failure_message_internal] - full message with
       optional context (base_path_hash, keeper_name, container_kind,
       network_label) + missing-cwd hint + mount-failure context
       suffix.
    3. [docker_failure_message] - context-less convenience
       wrapper (kept for an existing external caller).
    4. [docker_failure_message_with_context] - required-context
       wrapper used by [record_docker_failure].
    5. [record_docker_failure] - persists the failure on the
       keeper registry (via [Keeper_registry_error_recording.record])
       along with structured [docker_mount_failure_details]. *)

open Keeper_types

let status_label = function
  | Unix.WEXITED n -> Printf.sprintf "exit=%d" n
  | Unix.WSIGNALED n -> Printf.sprintf "signal=%d" n
  | Unix.WSTOPPED n -> Printf.sprintf "stopped=%d" n
;;

let docker_failure_message_internal
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
    (* Previously matched the bare 3-char `"cd:"` substring, which fires
       on user output such as `git log --format="cd:%cd"`. Anchor to the
       bash error shape: `bash: cd:` followed by `No such file or
       directory`. Stress test 2026-05-26. *)
    if
      String_util.contains_substring output "bash: cd:"
      && String_util.contains_substring output "No such file or directory"
    then
      " hint=cwd_not_directory: create or repair the sandbox repo/worktree first, \
       then retry with cwd=repos/<repo>/.worktrees/<task>)."
    else ""
  in
  let mount_failure_context =
    Keeper_sandbox_runtime.docker_mount_failure_context_suffix
      ?base_path_hash
      ?keeper_name
      ~image
      ~status_label:(status_label status)
      ?container_kind
      ?network_label
      output
  in
  Printf.sprintf
    "sandbox docker exec failed (%s, %s): %s%s%s"
    image
    (status_label status)
    output_label
    missing_cwd_hint
    mount_failure_context
;;

let docker_failure_message ~image ~status ~output =
  docker_failure_message_internal ~image ~status ~output ()
;;

let docker_failure_message_with_context
      ~base_path_hash
      ~keeper_name
      ~container_kind
      ~network_label
      ~image
      ~status
      ~output
  =
  docker_failure_message_internal
    ~base_path_hash
    ~keeper_name
    ~container_kind
    ~network_label
    ~image
    ~status
    ~output
    ()
;;

let record_docker_failure
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~image
      ~container_kind
      ~network_label
      ~status
      ~output
  =
  let base_path_hash = Keeper_sandbox_runtime.base_path_hash config.base_path in
  let status_label = status_label status in
  let message =
    docker_failure_message_with_context
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

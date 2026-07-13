(** Docker output / status classifiers for the keeper sandbox runtime.

    Pure functions — no parent-local state. All callers are internal to
    the keeper sandbox (verified via grep across lib/keeper/ + test/).

    Classification results are returned as a typed variant rather than
    string tokens. String serialization is owned by
    {!docker_failure_class_to_string} so retry policy, telemetry, and
    the dashboard surface cannot drift when a class is added or renamed. *)

type docker_failure_class =
  | Docker_daemon_timeout
  | Docker_runtime_error
  | Docker_command_timeout
  | Image_inspect_timeout
  | Image_inspect_error
  | Docker_info_format_error
  | Image_config_missing
  | Docker_hardening_error

let docker_failure_class_to_string = function
  | Docker_daemon_timeout -> "docker_daemon_timeout"
  | Docker_runtime_error -> "docker_runtime_error"
  | Docker_command_timeout -> "docker_command_timeout"
  | Image_inspect_timeout -> "image_inspect_timeout"
  | Image_inspect_error -> "image_inspect_error"
  | Docker_info_format_error -> "docker_info_format_error"
  | Image_config_missing -> "image_config_missing"
  | Docker_hardening_error -> "docker_hardening_error"
;;

let process_status_is_timeout = function
  | Unix.WEXITED 124 -> true
  | Unix.WEXITED _
  | Unix.WSIGNALED _
  | Unix.WSTOPPED _ ->
    false
;;

(** Classify failures from daemon-probing commands such as [docker info].
    Only the typed process status is authoritative; free-form Docker stderr is
    retained as evidence and never parsed into a control-flow class. *)
let classify_docker_info_failure ~status =
  if process_status_is_timeout status then Docker_daemon_timeout
  else Docker_runtime_error
;;

(** Classify failures from [docker run ...] invocations that execute a
    keeper command inside a container. A timeout in this boundary can
    mean the sandbox command itself hung after the container started,
    so it is classified as [Command_timeout] rather than
    [Docker_daemon_timeout]. Only explicit Docker daemon unavailable
    messages are treated as daemon back-pressure. *)
let classify_docker_run_failure ~status =
  if process_status_is_timeout status then Docker_command_timeout
  else Docker_runtime_error
;;

let classify_image_inspect_failure ~status =
  if process_status_is_timeout status then Image_inspect_timeout
  else Image_inspect_error
;;

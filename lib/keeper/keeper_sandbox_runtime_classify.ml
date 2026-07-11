(** Docker output / status classifiers for the keeper sandbox runtime.

    Pure functions — no parent-local state. All callers are internal to
    the keeper sandbox (verified via grep across lib/keeper/ + test/).

    Classification results are returned as a typed variant rather than
    string tokens. String serialization is owned by
    {!docker_failure_class_to_string} so retry policy, telemetry, and
    the dashboard surface cannot drift when a class is added or renamed. *)

type docker_failure_class =
  | Docker_daemon_timeout
  | Docker_daemon_unavailable
  | Docker_runtime_error
  | Docker_command_timeout
  | Image_inspect_timeout
  | Image_missing
  | Image_inspect_error
  | Image_inventory_timeout
  | Oci_mount_failure
  | Image_inventory_error
  | Docker_info_format_error
  | Image_config_missing
  | Docker_hardening_error
  | Image_required_command_missing

type container_reference_failure =
  | Container_absent
  | Container_not_running
  | Container_reference_error

let docker_failure_class_to_string = function
  | Docker_daemon_timeout -> "docker_daemon_timeout"
  | Docker_daemon_unavailable -> "docker_daemon_unavailable"
  | Docker_runtime_error -> "docker_runtime_error"
  | Docker_command_timeout -> "docker_command_timeout"
  | Image_inspect_timeout -> "image_inspect_timeout"
  | Image_missing -> "image_missing"
  | Image_inspect_error -> "image_inspect_error"
  | Image_inventory_timeout -> "image_inventory_timeout"
  | Oci_mount_failure -> "oci_mount_failure"
  | Image_inventory_error -> "image_inventory_error"
  | Docker_info_format_error -> "docker_info_format_error"
  | Image_config_missing -> "image_config_missing"
  | Docker_hardening_error -> "docker_hardening_error"
  | Image_required_command_missing -> "image_required_command_missing"
;;

let process_status_is_timeout = function
  | Unix.WEXITED 124 -> true
  | Unix.WEXITED _
  | Unix.WSIGNALED _
  | Unix.WSTOPPED _ ->
    false
;;

let lower_contains output needle =
  String_util.contains_substring (String.lowercase_ascii output) needle
;;

(** The daemon-unavailable classifier is intentionally narrow: it only
    matches explicit Docker daemon messages. Generic network errors such
    as "connection refused" must not be classified as Docker daemon
    pressure, because they can come from the command inside the
    container or from unrelated network paths. *)
let output_looks_docker_daemon_unavailable output =
  lower_contains output "cannot connect to the docker daemon"
  || lower_contains output "is the docker daemon running"
  || lower_contains output "docker daemon is not running"
;;

let output_looks_object_missing output = lower_contains output "no such object"

let output_looks_image_missing output =
  lower_contains output "no such image" || output_looks_object_missing output
;;

let output_looks_timeout output =
  lower_contains output "timeout after"
  || lower_contains output "timed out"
  || lower_contains output "i/o timeout"
;;

let classify_container_reference_failure output =
  if lower_contains output "no such container"
     || output_looks_object_missing output
  then Container_absent
  else if lower_contains output "is not running"
  then Container_not_running
  else Container_reference_error
;;

let docker_output_looks_oci_mount_failure output =
  lower_contains output "oci runtime create failed"
  || lower_contains output "error during container init"
;;

(** Classify failures from daemon-probing commands such as [docker info].
    A timeout here means the Docker daemon did not respond, so it maps
    to [Docker_daemon_timeout]. *)
let classify_docker_info_failure ~status ~output =
  if process_status_is_timeout status || output_looks_timeout output
  then Docker_daemon_timeout
  else if output_looks_docker_daemon_unavailable output
  then Docker_daemon_unavailable
  else Docker_runtime_error
;;

(** Classify failures from [docker run ...] invocations that execute a
    keeper command inside a container. A timeout in this boundary can
    mean the sandbox command itself hung after the container started,
    so it is classified as [Command_timeout] rather than
    [Docker_daemon_timeout]. Only explicit Docker daemon unavailable
    messages are treated as daemon back-pressure. *)
let classify_docker_run_failure ~status ~output =
  if output_looks_docker_daemon_unavailable output
  then Docker_daemon_unavailable
  else if process_status_is_timeout status || output_looks_timeout output
  then Docker_command_timeout
  else Docker_runtime_error
;;

let classify_image_inspect_failure ~status ~output =
  if process_status_is_timeout status || output_looks_timeout output
  then Image_inspect_timeout
  else if output_looks_docker_daemon_unavailable output
  then Docker_daemon_unavailable
  else if output_looks_image_missing output
  then Image_missing
  else Image_inspect_error
;;

let classify_image_inventory_failure ~status ~output =
  if process_status_is_timeout status || output_looks_timeout output
  then Image_inventory_timeout
  else if docker_output_looks_oci_mount_failure output
  then Oci_mount_failure
  else if output_looks_docker_daemon_unavailable output
  then Docker_daemon_unavailable
  else Image_inventory_error
;;

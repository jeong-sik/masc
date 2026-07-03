(** Docker output / status classifiers for the keeper sandbox runtime.

    Pure functions — verbatim extraction of the substring-based
    failure-class triage used by [Keeper_sandbox_runtime]. No
    parent-local state. All callers are internal to the parent
    (verified via grep across lib/ + test/).

    The classifier now returns a typed variant instead of string
    tokens. String serialization is owned by
    {!docker_failure_class_to_string} so retry policy and telemetry
    cannot drift when a new class is added or renamed. *)

type docker_failure_class =
  | Docker_daemon_timeout
  | Docker_daemon_unavailable
  | Docker_runtime_error
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

let docker_failure_class_to_string = function
  | Docker_daemon_timeout -> "docker_daemon_timeout"
  | Docker_daemon_unavailable -> "docker_daemon_unavailable"
  | Docker_runtime_error -> "docker_runtime_error"
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

let output_looks_docker_daemon_unavailable output =
  lower_contains output "cannot connect to the docker daemon"
  || lower_contains output "is the docker daemon running"
  || lower_contains output "docker daemon is not running"
  || lower_contains output "connection refused"
;;

let output_looks_image_missing output =
  lower_contains output "no such image"
  || lower_contains output "no such object"
;;

let output_looks_timeout output =
  lower_contains output "timeout after"
  || lower_contains output "timed out"
  || lower_contains output "i/o timeout"
;;

let docker_output_looks_oci_mount_failure output =
  lower_contains output "oci runtime create failed"
  || lower_contains output "error during container init"
;;

let classify_docker_runtime_failure ~status ~output =
  if process_status_is_timeout status || output_looks_timeout output
  then Docker_daemon_timeout
  else if output_looks_docker_daemon_unavailable output
  then Docker_daemon_unavailable
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

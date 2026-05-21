(** Docker output / status classifiers for the keeper sandbox runtime.

    Pure functions — verbatim extraction of the substring-based
    failure-class triage used by [Keeper_sandbox_runtime]. No
    parent-local state. All callers are internal to the parent
    (verified via grep across lib/ + test/).

    Note: the [classify_*] functions return string failure-class tokens
    rather than a typed variant. This is verbatim with the
    pre-extraction code; a typed conversion is RFC-territory because
    the strings cross many call sites and the dashboard surface. *)

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
  then "docker_daemon_timeout"
  else if output_looks_docker_daemon_unavailable output
  then "docker_daemon_unavailable"
  else "docker_runtime_error"
;;

let classify_image_inspect_failure ~status ~output =
  if process_status_is_timeout status || output_looks_timeout output
  then "image_inspect_timeout"
  else if output_looks_docker_daemon_unavailable output
  then "docker_daemon_unavailable"
  else if output_looks_image_missing output
  then "image_missing"
  else "image_inspect_error"
;;

let classify_image_inventory_failure ~status ~output =
  if process_status_is_timeout status || output_looks_timeout output
  then "image_inventory_timeout"
  else if docker_output_looks_oci_mount_failure output
  then "oci_mount_failure"
  else if output_looks_docker_daemon_unavailable output
  then "docker_daemon_unavailable"
  else "image_inventory_error"
;;

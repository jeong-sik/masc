(** Docker output / status classifiers for keeper sandbox runtime. *)

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

(** Typed interpretation of a failed Docker command that references a
    container. Docker's human-readable output is parsed only in this boundary
    module; lifecycle callers branch on this closed variant. *)
type container_reference_failure =
  | Container_absent
  | Container_not_running
  | Container_reference_error

val docker_failure_class_to_string : docker_failure_class -> string
val process_status_is_timeout : Unix.process_status -> bool
val lower_contains : string -> string -> bool
val output_looks_docker_daemon_unavailable : string -> bool
val output_looks_image_missing : string -> bool
val output_looks_timeout : string -> bool
val docker_output_looks_oci_mount_failure : string -> bool

val classify_docker_info_failure :
  status:Unix.process_status -> output:string -> docker_failure_class

val classify_docker_run_failure :
  status:Unix.process_status -> output:string -> docker_failure_class

val classify_image_inspect_failure :
  status:Unix.process_status -> output:string -> docker_failure_class

val classify_image_inventory_failure :
  status:Unix.process_status -> output:string -> docker_failure_class

val classify_container_reference_failure : string -> container_reference_failure

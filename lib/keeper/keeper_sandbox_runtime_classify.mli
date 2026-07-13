(** Docker output / status classifiers for keeper sandbox runtime. *)

type docker_failure_class =
  | Docker_daemon_timeout
  | Docker_runtime_error
  | Docker_command_timeout
  | Image_inspect_timeout
  | Image_inspect_error
  | Docker_info_format_error
  | Image_config_missing
  | Docker_hardening_error

val docker_failure_class_to_string : docker_failure_class -> string
val process_status_is_timeout : Unix.process_status -> bool

val classify_docker_info_failure :
  status:Unix.process_status -> docker_failure_class

val classify_docker_run_failure :
  status:Unix.process_status -> docker_failure_class

val classify_image_inspect_failure :
  status:Unix.process_status -> docker_failure_class

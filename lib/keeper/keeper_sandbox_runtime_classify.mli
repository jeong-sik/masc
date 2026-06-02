(** Docker output / status classifiers for keeper sandbox runtime. *)

val process_status_is_timeout : Unix.process_status -> bool
val lower_contains : string -> string -> bool
val output_looks_docker_daemon_unavailable : string -> bool
val output_looks_image_missing : string -> bool
val output_looks_timeout : string -> bool
val docker_output_looks_oci_mount_failure : string -> bool
val classify_docker_runtime_failure : status:Unix.process_status -> output:string -> string
val classify_image_inspect_failure : status:Unix.process_status -> output:string -> string
val classify_image_inventory_failure : status:Unix.process_status -> output:string -> string

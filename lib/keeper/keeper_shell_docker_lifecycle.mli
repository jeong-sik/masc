(** Docker container lifecycle helpers — timeout constants,
    cleanup, and file-descriptor admission checks. *)

val docker_run_min_timeout_sec : float
val docker_cleanup_rm_timeout_sec : unit -> float
val docker_oneshot_ttl_sec : timeout_sec:float -> float
val docker_rm_no_such_container : string -> bool
val cleanup_oneshot_container : container_name:string -> unit
val fd_admission_error : config:Coord.config -> string option

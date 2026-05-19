(** Task-state probing detection for keeper_bash command-shape guidance. *)

val mentions_task_state_file : string -> bool
val looks_like_http_probe : string -> bool
val looks_like_discovery : string -> bool

val hint : string
val alternatives : string list

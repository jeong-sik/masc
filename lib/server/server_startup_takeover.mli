type acquire_result =
  | Acquired
  | Already_running of { pid : int }

type base_path_lease

type base_path_acquire_result =
  | Base_path_acquired of base_path_lease
  | Base_path_already_owned of { pid : int option }

val pid_lock_path : int -> string

val base_path_lock_path : string -> string

val status_line_is_healthy : string -> bool

val looks_like_server_command : string -> bool

val probe_liveness : ?timeout_sec:float -> ?path:string -> int -> bool

val wait_for_pid_exit :
  ?poll_interval_sec:float -> timeout_sec:float -> int -> bool

val acquire_pid_lock :
  ?lock_path:string ->
  ?probe_timeout_sec:float ->
  ?term_timeout_sec:float ->
  ?kill_wait_sec:float ->
  ?poll_interval_sec:float ->
  int ->
  acquire_result

val acquire_base_path_lock :
  ?lock_path:string ->
  string ->
  base_path_acquire_result

val release_base_path_lease : base_path_lease -> unit

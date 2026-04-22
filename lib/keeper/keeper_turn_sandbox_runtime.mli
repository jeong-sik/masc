(** Turn-scoped keeper Docker sandbox runtime.

    Lazily starts one hardened container for a keeper turn and reuses it across
    compatible tool calls. The runtime keeps the keeper playground mounted
    read-write while the root filesystem stays read-only. *)

type t

val create :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?network_mode:Keeper_types.network_mode ->
  t

val cleanup : t -> unit
(** Best-effort teardown. Safe to call multiple times. *)

val container_path_of_host :
  t -> host_path:string -> (string, string) result

val container_cwd_of_host :
  t -> host_cwd:string -> string

val run_command_with_status :
  ?ok_exit_codes:int list ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

val run_command :
  ?ok_exit_codes:int list ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string, string) result

val run_bash_with_status :
  t ->
  cwd:string ->
  cmd:string ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

val overwrite_file :
  t ->
  host_path:string ->
  content:string ->
  timeout_sec:float ->
  unit ->
  (unit, string) result

val append_file :
  t ->
  host_path:string ->
  content:string ->
  timeout_sec:float ->
  unit ->
  (unit, string) result

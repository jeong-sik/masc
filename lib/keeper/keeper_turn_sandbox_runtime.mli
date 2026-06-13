(** Turn-scoped keeper Docker sandbox runtime.

    Lazily starts one hardened container for a keeper turn and reuses it across
    compatible tool calls. The runtime keeps the keeper playground mounted
    read-write while the root filesystem stays read-only. *)

type t

val create :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?network_mode:Keeper_types_profile_sandbox.network_mode ->
  turn_id:int ->
  unit ->
  t

val turn_id : t -> int
val host_root : t -> string

val cleanup : t -> unit
(** Best-effort teardown. Safe to call multiple times. *)

val container_path_of_host :
  t -> host_path:string -> (string, string) result

val container_cwd_of_host :
  t -> host_cwd:string -> string

val host_cwd_of_container :
  t -> container_cwd:string -> (string, string) result

val run_command_with_status :
  ?ok_exit_codes:int list ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (Unix.process_status * string, string) result

val run_exec_with_status :
  ?stdin_content:string ->
  t ->
  timeout_sec:float ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string, string) result
(** Execute [command_argv] inside the turn-scoped container and return the raw
    process status and merged output without applying success-code policy.
    This is the argv-level entrypoint used by Shell IR dispatch. *)

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

val run_exec_pipeline_with_status :
  t ->
  timeout_sec:float ->
  cwd:string ->
  stages:exec_pipeline_stage list ->
  (Unix.process_status * string * string, string) result
(** Execute [stages] as a streaming argv pipeline inside the turn-scoped
    container. Each stage is a separate [docker exec -i] process and adjacent
    stages are connected by host-side process pipes. *)

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

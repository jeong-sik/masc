(** Turn-scoped keeper Docker sandbox runtime.

    Lazily starts one hardened container for a keeper turn and reuses it across
    compatible tool calls. The runtime keeps the keeper playground mounted
    read-write while the root filesystem stays read-only. *)

type t

type state =
  | Not_started
  | Running of { container_name : string }

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

module For_testing : sig
  val create_minimal
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> state:state
    -> t

  val get_state : t -> state
  val set_state : t -> state -> unit
end

val container_path_of_host :
  t -> host_path:string -> (string, string) result

val container_cwd_of_host :
  t -> host_cwd:string -> string

val host_cwd_of_container :
  t -> container_cwd:string -> (string, string) result

val run_argv_with_stdin_and_status_split :
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  stdin_content:string ->
  string list ->
  Unix.process_status * string * string
(** Run a sandbox-management argv with stdin through the owned Docker execution
    boundary exactly once. The returned status, stdout, and stderr are the
    subprocess result without text-based classification, retry, or output
    suppression. This is intentionally lower-level than the turn-scoped [t]
    operations because one-shot sandbox startup paths need the same execution
    boundary before a reusable container exists. *)

val run_command_with_status :
  ?ok_exit_codes:int list ->
  timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  unit ->
  (Unix.process_status * string, string) result

val run_exec_with_status :
  ?stdin_content:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string, string) result
(** Execute [command_argv] inside the turn-scoped container and return the raw
    process status and merged output without applying success-code policy.
    Existing read-backend callers use this for legacy merged-output behavior. *)

val run_exec_with_status_split :
  ?stdin_content:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (Unix.process_status * string * string, string) result
(** Execute [command_argv] inside the turn-scoped container and return split
    stdout/stderr without applying success-code policy. This is the argv-level
    entrypoint used by Shell IR dispatch. *)

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

val run_exec_pipeline_with_status :
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  ?timeout_sec:float ->
  t ->
  cwd:string ->
  stages:exec_pipeline_stage list ->
  (Unix.process_status * string * string, string) result
(** Execute [stages] as a streaming argv pipeline inside the turn-scoped
    container. Each stage is a separate [docker exec -i] process and adjacent
    stages are connected by host-side process pipes. *)

val run_command :
  ?ok_exit_codes:int list ->
  timeout_sec:float ->
  t ->
  cwd:string ->
  command_argv:string list ->
  max_bytes:int ->
  unit ->
  (string, string) result

val run_bash_with_status :
  timeout_sec:float ->
  t ->
  cwd:string ->
  cmd:string ->
  unit ->
  (Unix.process_status * string, string) result

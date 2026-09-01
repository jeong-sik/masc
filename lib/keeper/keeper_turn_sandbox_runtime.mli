(** Turn-scoped handle on a keeper-lifetime sandbox container.

    Lazily ensures one hardened container per keeper (adopting what a previous
    turn or server left running) and reuses it across compatible tool calls.
    The runtime keeps the keeper playground mounted read-write while the root
    filesystem stays read-only. Turn cleanup drops the handle without removing
    the container; the keeper's shutdown finalization removes it. *)

type t

type state =
  | Not_started
  | Running of { container_name : string }

val create :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?network_mode:Keeper_types_profile_sandbox.network_mode ->
  unit ->
  t

val host_root : t -> string
val prepare_github_identity_secret_files :
  ?timeout_sec:float -> t -> (string list, string) result
(** After authorization, observe and bind the container to the current GitHub
    identity, then return every credential file whose token must remain
    redacted. Docker: the bind is [ensure_started] itself and the redaction
    target is the stable [hosts.yml] the running container has mounted; a
    central login reaches it through the mount. Microvm: the guest's identity
    is its boot-time snapshot, and a drift from the central revision drops
    the handle so the next boot rebuilds it. *)

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
  val keeper_docker_container_name : t -> string
  (** The stable per-keeper container name, so the naming contract (stable
      across turns, split by network mode, bound to the base path) is
      testable without a docker daemon. *)
end

val container_path_of_host :
  t -> host_path:string -> (string, string) result

val container_cwd_of_host :
  t -> host_cwd:string -> string

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

val exec_argv :
  ?stdin:bool ->
  ?timeout_sec:float ->
  validate_cached_container:bool ->
  t ->
  cwd:string ->
  command_argv:string list ->
  (string list, string) result
(** The argv that runs [command_argv] inside the turn-scoped container.

    Exactly what {!run_exec_with_status_split} blocks on, handed over instead
    of run: a command that must not hold the turn is spawned, and it has to
    land in the same container as the same uid under the same rewritten paths.
    Building that argv twice would be building the boundary twice. *)

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

val teardown_keeper_sandbox_by_name :
  ?timeout_sec:float ->
  config:Workspace.config ->
  keeper_name:string ->
  backend:Keeper_sandbox.backend ->
  unit ->
  (unit, string) result
(** {!teardown_keeper_sandbox} for callers that hold the keeper's name and
    typed backend -- shutdown finalization, which runs after the registry
    entry is gone. Local and remote-SSH Keepers own no local container;
    Docker and microVM teardown target only their declared runtime. *)

val teardown_keeper_sandbox :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (unit, string) result
(** Remove the keeper-lifetime containers for [meta]: the microvm guest and
    the persistent Docker containers, if any. Turn cleanup deliberately
    leaves both running (the guest boot and the container start are paid
    once per keeper, not per turn); this is the remove path, run at keeper
    shutdown finalization. A missing container is a successful teardown.
    The MicroVM identity snapshot is released only after its guest has
    stopped and been deleted. *)

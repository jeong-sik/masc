(** Docker / sandbox shell execution infrastructure.

    Extracted from agent_tool_shell_runtime.ml — Docker container
    lifecycle, sandbox profile resolution, and container
    invocation. Pure infrastructure; generic command-shape policy lives
    in [Keeper_shell_command_semantics].

    Sandbox backend failure-message and failure-recording surfaces live
    in [Keeper_sandbox_exec_failure]. Call those qualified rather than
    relying on a re-export here. *)

(** Path of the per-keeper egress policy file
    [<sandbox_root>/egress.json]. *)
val egress_policy_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string

(** Check [cmd] against [Masc_exec.Egress_policy] for the keeper.
    Returns [Some blocked_json] when blocked, [None] when allowed. *)
val check_egress :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cmd:string ->
  string option

(** Per-invocation container name [masc-keeper-<safe>-<pid>-<ms>]. *)
val keeper_sandbox_container_name :
  Keeper_types.keeper_meta -> string

val keeper_private_container_root : Keeper_types.keeper_meta -> string

(** Translate a host cwd into the in-container path mirror,
    falling back to the container root when [host_cwd] is outside
    the keeper sandbox root. *)
val docker_private_workspace_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string

(** Translate keeper-private in-container absolute paths back to their host
    playground paths for host-side path validation. Actual Docker execution
    still receives the original container paths. *)
val rewrite_docker_command_paths_for_host_validation :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string

(** Resolve [(sandbox_profile, network_mode)] from the keeper's declared
    profile. The declared sandbox profile is the execution contract:
    [sandbox_profile=local] never becomes Docker because of call-site cwd. *)
val effective_sandbox_profile :
  meta:Keeper_types.keeper_meta ->
  Keeper_types.sandbox_profile * Keeper_types.network_mode

(** Tokens flagged as nested container-runtime invocations. *)
val nested_container_runtime_tokens : string list

(** Filesystem markers indicating host container-socket access
    (docker.sock, podman.sock, containerd.sock, ...). *)
val sandbox_socket_markers : string list

(** [true] iff [cmd] mentions a nested container runtime token or
    references a host container socket. *)
val command_uses_nested_container_runtime : string -> bool

(** Re-export of [Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime]. *)
val ensure_keeper_sandbox_runtime :
  timeout_sec:float -> (string list, string) result
(** Direct alias of [Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime];
    returns the [--security-opt seccomp=...] argv fragment on success. *)

(** [-v <host>:<container>:ro] mount list, or [[]] when [host] is
    blank or missing. *)
val optional_ro_mount :
  host:string -> container:string -> string list



(** Result envelope returned by [run_docker_shell_command_with_status]. *)
type docker_shell_result =
  { status : Unix.process_status
  ; output : string
  ; image : string
  ; network_label : string
  ; cwd : string
  ; semantic_status : Exec_core.semantic_status option
  ; semantic_ok : bool
  }

(** Cold-start floor (seconds) for [docker run --rm].  The wall-clock
    budget covers slot_wait + spawn + container cold start + actual
    cmd + drain; the default ([20.0]) matches the tool dispatch floor
    ([tool_dispatch_min_timeout_sec = 15s]) plus 5s headroom for image
    pull and container creation.  Operators can override via
    [MASC_KEEPER_DOCKER_RUN_MIN_TIMEOUT_SEC] (read once at module
    load, clamped to [Timeout_floor.Docker_run]). *)
val docker_run_min_timeout_sec : float

(** Run [cmd] inside the keeper Docker sandbox; clamps
    [timeout_sec] to [docker_run_min_timeout_sec], honours
    [git_creds_enabled] and [network_mode], records errors via
    [Keeper_registry]. *)
val run_docker_shell_command_with_status :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  git_creds_enabled:bool ->
  network_mode:Keeper_types.network_mode ->
  (docker_shell_result, string) result

(** Same as {!run_docker_shell_command_with_status}, but skips freeform
    command path syntax validation. Use only for commands generated from
    structured argv by a dedicated MASC tool; keeper-authored Execute must use
    the default validated entrypoint. *)
val run_trusted_docker_shell_command_with_status :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  git_creds_enabled:bool ->
  network_mode:Keeper_types.network_mode ->
  (docker_shell_result, string) result

(** Run [cmd] inside the Docker sandbox with host credential bindings
    forwarded (Network_inherit). Returns the JSON envelope surfaced to the LLM. *)
val run_docker_credentialed_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  unit ->
  string

(** Run [cmd] inside the Docker sandbox with the caller's
    [network_mode] and no git credentials. *)
val run_docker_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  network_mode:Keeper_types.network_mode ->
  string

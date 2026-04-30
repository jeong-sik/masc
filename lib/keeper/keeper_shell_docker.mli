(** Docker / sandbox shell execution infrastructure.

    Extracted from keeper_exec_shell.ml — Docker container
    lifecycle, sandbox profile resolution, and container
    invocation. Pure infrastructure; command dispatch remains in
    keeper_exec_shell.ml. *)

(** Diagnostic label for a [Unix.process_status]:
    [exit=N] / [signal=N] / [stopped=N]. *)
val docker_exec_status_label : Unix.process_status -> string

(** Build a structured failure message used by docker exec
    diagnostics, emphasising the exit/signal status and (when
    blank) flagging empty output explicitly. *)
val docker_exec_failure_message :
  image:string ->
  status:Unix.process_status ->
  output:string ->
  string

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

(** Resolve [(sandbox_profile, network_mode)] given the keeper's
    declared profile and whether the cwd is in-playground. Hard
    mode forces the keeper's declared profile; otherwise [Local]
    in playground may be auto-promoted to [Docker / Network_inherit]
    when [DockerPlayground.enabled]. *)
val effective_sandbox_profile :
  meta:Keeper_types.keeper_meta ->
  in_playground:bool ->
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

val cmd_targets_git_or_gh : string -> bool
val cmd_targets_gh : string -> bool

(** [#10855] LLM hallucinated [gh --repo X api Y] (108 events / 24h).
    Returns [Some (repo_arg, endpoint)] when the misuse pattern is
    detected, [None] otherwise — caller emits a self-correcting
    error pre-exec. *)
val detect_gh_repo_flag_with_api_misuse :
  string -> (string * string) option

(** Emit a [("gh_exit_class", ...)] JSON field when [cmd] targets
    gh (otherwise []), and bump the matching [Legendary_counters]
    bucket. Caller appends the returned list to its assoc payload
    unconditionally — the empty case keeps callsite shapes stable. *)
val gh_exit_class_field :
  cmd:string ->
  status:Unix.process_status ->
  output:string ->
  (string * Yojson.Safe.t) list

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
  }

(** Cold-start floor (seconds) for [docker run --rm]. *)
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

(** Run [cmd] inside the Docker sandbox with git credentials
    forwarded (Network_inherit). Returns the JSON envelope to
    surface to the LLM, including [gh_exit_class] when applicable. *)
val run_docker_with_git_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  unit ->
  string

(** Run [cmd] inside the hardened Docker sandbox with the caller's
    [network_mode] (no git creds). *)
val run_docker_hardened_bash :
  turn_sandbox_runtime:Keeper_turn_sandbox_runtime.t option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  timeout_sec:float ->
  cmd:string ->
  network_mode:Keeper_types.network_mode ->
  string

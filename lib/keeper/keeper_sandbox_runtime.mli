(** Keeper sandbox runtime preflight.

    Shared between [Keeper_tool_execute_runtime] and
    [Keeper_sandbox_read_backend]. Both surfaces need to verify
    the host docker runtime satisfies the configured hardening
    constraints (seccomp profile present, optional rootless / userns
    enforcement) before launching any containerised work.

    Pure leaf module — no upward dependencies on other [Keeper_*]
    modules. *)

type docker_preflight =
  { ok : bool
  ; image : string
  ; docker_runtime_ok : bool
  ; docker_runtime_error : string option
  ; hardening_ok : bool
  ; hardening_error : string option
  ; image_present : bool
  ; image_error : string option
  ; failure_classes : string list
  ; next_actions : string list
  }

type classified_error =
  { message : string
  ; failure_class : Keeper_sandbox_runtime_classify.docker_failure_class
  }

type live_container =
  { id : string
  ; name : string
  ; image : string
  ; status : string
  ; running : bool option
  ; created_at : string option
  ; keeper_name : string option
  ; container_kind : string option
  ; network_label : string option
  ; owner_pid : int option
  ; started_at : float option
  ; ttl_sec : float option
  }

type stop_result =
  { matched : int
  ; removed : int
  ; errors : string list
  }

type docker_container_state =
  | Docker_container_running
  | Docker_container_stopped
  | Docker_container_absent

(** Resolve the Docker CLI from the current [PATH]. This keeps Docker
    calls deterministic after the Eio process manager has been
    initialized and tests inject a fake [docker] binary. *)
val docker_command : unit -> string

(** Process argv prefix for invoking Docker. Tests may inject a shell
    script fake [docker] binary; this helper wraps that path via
    [/bin/sh] so direct script execution does not depend on host shebang
    handling. *)
val pid_alive : int -> bool
(** Whether a process id still names a live process. Exposed because guest
    sweeping decides abandonment on exactly this and must not carry its own
    copy of the rule. EPERM counts as alive: another user owns it. *)

val docker_command_argv : unit -> string list
(** Argv removing [container] together with the anonymous volumes it owns.

    The sandbox image declares VOLUME ["/tmp/keeper-creds"], so every container
    started from it carries a fresh anonymous volume. [-v] is inside this argv
    so a removal site cannot orphan that volume by leaving the flag out. *)
val docker_remove_argv : string -> string list


(** Docker [run] flag fragment that prevents implicit registry pulls. Keeper
    sandbox images are a local runtime prerequisite and must be built before
    execution. *)
val docker_run_pull_never_args : unit -> string list

(** Generic next action when Docker image inspection fails. *)
val docker_image_inspect_next_action : string

(** [docker_image_present ~image ~timeout_sec] checks whether the configured
    keeper sandbox image can be inspected locally. [Error message] includes
    daemon/socket access failures as well as missing-image failures. *)
val docker_image_present : image:string -> timeout_sec:float -> (unit, string) result
(** Docker [--label] argv fragment for containers owned by the keeper
    sandbox runtime. *)
val docker_label_args
  :  ?ttl_sec:float
  -> base_path:string
  -> keeper_name:string
  -> container_kind:string
  -> network_label:string
  -> unit
  -> string list

(** {2 Label building blocks (RFC-0070 Phase 3e — exposed so the
    *deterministic* subset of [docker_label_args] can be composed
    byte-identically without re-defining the keys and risking drift)} *)

val sandbox_component_label_key : string
val sandbox_base_path_hash_label_key : string
val sandbox_keeper_label_key : string
val sandbox_kind_label_key : string

val turn_container_kind : string
(** Value of the [masc.mcp.kind] label on a container that lives for one turn. *)

val persistent_container_kind : string
(** Companion of {!turn_container_kind} for keeper-lifetime containers:
    adopted across turns and server restarts, removed only when the keeper
    is. *)

val current_owner_pid : unit -> int
(** The pid written as [masc.mcp.owner_pid] and the one a filter must supply to
    select those containers again. *)

val sandbox_owner_pid_label_key : string
val sandbox_started_at_label_key : string
val sandbox_network_label_key : string
val sandbox_ttl_sec_label_key : string

(** Value of {!sandbox_component_label_key} ([= "keeper-sandbox"]). *)
val sandbox_component_label_value : string

(** [base_path_hash base_path] = the {!sandbox_base_path_hash_label_key}
    label value: hex MD5 of the normalised base path. Pure. *)
val base_path_hash : string -> string

(** [normalize_base_path_for_hash base_path] resolves relative base paths
    against the current working directory before hashing. Pure apart from
    [Sys.getcwd] for relative inputs. *)
val normalize_base_path_for_hash : string -> string

(** [sanitize_label_value v] maps any character outside
    [[A-Za-z0-9_.-]] to ['_']. Pure. *)
val sanitize_label_value : string -> string

(** Extract the failing host-side source path from Docker Desktop / OCI
    mount errors such as [error mounting "/host_mnt/..."].  Also accepts
    the [mount_path="..."] field emitted by MASC diagnostics.  Returned
    paths are bounded before they are logged or emitted as structured
    diagnostics. *)
val docker_mount_failure_path : string -> string option

(** Truncate Docker output for log storage.  Generic output keeps the
    normal compact budget; OCI mount failures get a larger budget so the
    mount source is not lost before [mount_path] is emitted. *)
val docker_failure_output_for_log : string -> string

(** Append stable key/value context for Docker mount failures.  Returns
    [""] when [output] is not a mount failure. *)
val docker_mount_failure_context_suffix :
  ?base_path_hash:string ->
  ?keeper_name:string ->
  ?image:string ->
  ?status_label:string ->
  ?container_kind:string ->
  ?network_label:string ->
  string ->
  string

(** Structured log payload for Docker mount failures.  Returns [None]
    when [output] is not a mount failure. *)
val docker_mount_failure_details :
  ?image:string ->
  ?status_label:string ->
  ?container_kind:string ->
  ?network_label:string ->
  base_path_hash:string ->
  keeper_name:string ->
  output:string ->
  unit ->
  Yojson.Safe.t option

(** Docker network argv fragment and the MASC network label.  In
    particular, [Network_inherit] maps to [--network host] so the
    container shares the host network namespace. The MASC label remains
    ["inherit"]. *)
val docker_network_args : Keeper_types_profile_sandbox.network_mode -> string list * string

(** Docker [--ulimit nofile=<soft>:<hard>] argv fragment for keeper
    sandbox containers. *)
val docker_nofile_args : unit -> string list

(** Container-visible MASC runtime base outside the keeper playground bind
    mount. *)
val container_masc_runtime_base : container_root:string -> string

(** Container-visible config root under {!container_masc_runtime_base}. *)
val container_masc_config_dir : container_root:string -> string

(** Host-side config root for a MASC base path. *)
val host_masc_config_dir : base_path:string -> string

(** Docker [-v ...] spec that exposes [<base_path>/.masc/config] read-only
    under {!container_masc_runtime_base}. *)
val docker_masc_config_mount_spec : base_path:string -> container_root:string -> string

(** Docker [-v ...] argv fragment for the MASC config bind mount. *)
val docker_masc_config_mount_args : base_path:string -> container_root:string -> string list

(** [MASC_BASE_PATH] and [MASC_CONFIG_DIR] values to pin inside the
    container. *)
val docker_masc_runtime_env_pairs : container_root:string -> (string * string) list

(** Docker [--env ...] argv fragment for the container-side MASC runtime
    paths. *)
val docker_masc_runtime_env_args : container_root:string -> string list

(** Docker [--env ...] argv fragment for the numeric keeper user. *)
val docker_user_env_args : unit -> string list

(** Host-side config root mounted into keeper containers. Honors
    [MASC_CONFIG_DIR] when set; otherwise uses
    [<base_path>/.masc/config]. *)
val docker_config_host_root : base_path:string -> string

(** Container-side config root under {!container_masc_runtime_base}. *)
val docker_config_container_root : container_root:string -> string

(** Docker [-v ...] argv fragment that exposes the active config root
    read-only under {!container_masc_runtime_base}. Returns [[]] when the host
    config root is absent. *)
val docker_config_mount_args
  :  base_path:string
  -> container_root:string
  -> string list

(** Docker [-v ...] specs for the read-only workspace-state subset that keeper
    task worktrees may read through their container-side runtime [.masc]
    projection. This intentionally excludes auth, credentials, locks,
    logs, metrics, and keeper private state. Existing paths are mounted
    outside [<container_root>] because that path is itself a bind-mounted
    playground; host-absolute [.masc] targets must never be used as Docker
    mount destinations. *)
val docker_workspace_state_mount_specs
  :  base_path:string
  -> container_root:string
  -> string list

(** Docker [-v ...] argv fragment for {!docker_workspace_state_mount_specs}. *)
val docker_workspace_state_mount_args
  :  base_path:string
  -> container_root:string
  -> string list

(** Docker [--env ...] argv fragment that points sandboxed processes at
    the mounted config root. Returns [[]] when the host config root is absent. *)
val docker_config_env_args
  :  base_path:string
  -> container_root:string
  -> string list

(** Standard keeper container env: sanitized user env plus the mounted
    MASC config env when available. *)
val docker_sandbox_env_args
  :  base_path:string
  -> container_root:string
  -> string list

(** The [--env] argv a keeper's exec carries, chosen by lane. An env may
    name only what was mounted: the microvm guest is given the config
    mount and nothing else, so it takes {!docker_config_env_args} alone,
    while the Docker lane takes the full {!docker_sandbox_env_args}. The
    microvm guest cannot go without it -- the config mount lands at the
    runtime base, outside the playground the guest works in, and nothing
    reaches it by walking up from the working directory. *)
val sandbox_exec_env_args
  :  microvm:bool
  -> base_path:string
  -> container_root:string
  -> string list

(** Docker [-v ...] argv fragment that supplies passwd/group entries for
    the numeric host uid/gid used inside the keeper container. *)
val docker_user_identity_mount_args
  :  host_root:string
  -> uid:int
  -> gid:int
  -> (string list, string) result

(** Rewrite occurrences of [host_root] as a path prefix to
    [container_root]. This is intentionally path-boundary aware so
    sibling paths such as [/root2] are left untouched. *)
val rewrite_host_root_to_container_root
  :  host_root:string
  -> container_root:string
  -> string
  -> string

(** List MASC keeper sandbox containers scoped to the same [base_path].
    Optional filters are implemented via Docker labels, not name matching. *)
val list_containers
  :  ?keeper_name:string
  -> ?container_kind:string
  -> base_path:string
  -> timeout_sec:float
  -> unit
  -> (live_container list, string) result

val live_container_to_yojson : live_container -> Yojson.Safe.t

(** Stop containers scoped to this base path and optional keeper/kind
    labels.  This never targets containers lacking MASC keeper labels. *)
val stop_containers
  :  ?keeper_name:string
  -> ?container_kind:string
  -> base_path:string
  -> timeout_sec:float
  -> unit
  -> stop_result

(** Query a named container through Docker's machine-oriented state and name
    inventory projections. Human-readable stderr is retained only as
    diagnostics and never determines the returned state. *)
val probe_container_state
  :  container_name:string
  -> timeout_sec:float
  -> (docker_container_state, string) result

val probe_container_state_optional
  :  container_name:string
  -> ?timeout_sec:float
  -> unit
  -> (docker_container_state, string) result

val remove_persistent_containers
  :  keeper_name:string
  -> base_path:string
  -> timeout_sec:float
  -> unit
  -> (unit, string) result
(** Remove this keeper's persistent ([masc.mcp.kind=persistent]) containers.
    Called at keeper shutdown finalization -- the one point that knows the
    keeper is gone for good rather than between turns; everything else adopts
    what is running. Selected by keeper and kind label across all network
    modes, so a container wired to a network config the keeper no longer uses
    is collected too. *)

(** Global keeper sandbox preflight used by sandbox diagnostics.
    Returns [None] when
    [MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false]. *)
val docker_preflight : timeout_sec:float -> unit -> docker_preflight option

val docker_preflight_to_yojson : docker_preflight -> Yojson.Safe.t
(** Lightweight image-presence check for the concrete execution path. Docker
    execution calls it immediately before [docker run] so an absent image is
    reported explicitly instead of triggering an implicit registry pull. It is
    not Keeper lifecycle authority. *)
val ensure_keeper_sandbox_image_present
  :  image:string
  -> timeout_sec:float
  -> (unit, string) result

val ensure_keeper_sandbox_image_present_with_class
  :  image:string
  -> timeout_sec:float
  -> (unit, classified_error) result

val ensure_keeper_sandbox_image_present_with_class_optional
  :  image:string
  -> ?timeout_sec:float
  -> unit
  -> (unit, classified_error) result

val docker_image_preflight_failure_message : prefix:string -> classified_error -> string

(** [docker_image_preflight_failure_message] applied with the
    ["docker_container_start_failed"] prefix, for callers that abort a
    container start because the image preflight returned
    [Error classified_error]. *)
val image_preflight_start_error : classified_error -> string

(** Returns the [--security-opt seccomp=...] argv fragment when the
    runtime passes; [Error _] when something is missing.

    The fragment is empty when the env config has no seccomp profile
    set; the caller should still concat it into the docker argv. *)
val ensure_keeper_sandbox_runtime : timeout_sec:float -> (string list, string) result
val ensure_keeper_sandbox_runtime_optional : ?timeout_sec:float -> unit -> (string list, string) result

(** Internals exposed for unit testing the docker inspect output
    parser (#10488 regression coverage).  The parser result is
    projected onto a tuple
    [(owner_pid, started_at, running, ttl_sec, container_kind)] so the test
    does not need a re-exported record type. *)
module For_testing : sig
  val nonempty_lines : string -> string list

  val parse_inspect_line
    :  string
    -> ( int option
       * float option
       * bool option
       * float option
       * string option
       , string )
       result
end

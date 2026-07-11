(** Keeper sandbox runtime preflight.

    Shared between [Keeper_tool_command_runtime] (bash sandbox) and
    [Keeper_sandbox_read_backend] (read sandbox). Both surfaces need to verify
    the host docker runtime satisfies the configured hardening
    constraints (seccomp profile present, optional rootless / userns
    enforcement) before launching any containerised work.

    Pure leaf module — no upward dependencies on other [Keeper_*]
    modules. *)

type required_command_check =
  { command : string
  ; available : bool
  }

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
  ; required_commands : required_command_check list
  ; missing_commands : string list
  ; next_actions : string list
  }

type cleanup_result =
  { scanned : int
  ; removed : int
  ; errors : string list
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

(** Resolve the Docker CLI from the current [PATH]. This keeps Docker
    calls deterministic after the Eio process manager has been
    initialized and tests inject a fake [docker] binary. *)
val docker_command : unit -> string

(** Process argv prefix for invoking Docker. Tests may inject a shell
    script fake [docker] binary; this helper wraps that path via
    [/bin/sh] so direct script execution does not depend on host shebang
    handling. *)
val docker_command_argv : unit -> string list

(** Docker [run] flag fragment that prevents implicit registry pulls. Keeper
    sandbox images are a local runtime prerequisite and must be built before
    execution. *)
val docker_run_pull_never_args : unit -> string list

(** Canonical operator action for a missing keeper sandbox image. *)
val docker_image_missing_next_action : string

(** [docker_image_present ~image ~timeout_sec] checks whether the configured
    keeper sandbox image can be inspected locally. [Error message] includes
    daemon/socket access failures as well as missing-image failures. *)
val docker_image_present : image:string -> timeout_sec:float -> (unit, string) result

(** [true] when a docker run result/status/output proves Docker daemon
    unavailability or back-pressure before command execution. Generic
    [docker run] timeouts are terminal because the container command may have
    already started and replaying it can duplicate side effects. *)
val docker_run_looks_daemon_pressure : status:Unix.process_status -> output:string -> bool

(** Docker [--label] argv fragment for containers owned by the keeper
    sandbox runtime. *)
val docker_label_args
  :  ?ttl_sec:float
  -> ?turn_id:int
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
val sandbox_owner_pid_label_key : string
val sandbox_started_at_label_key : string
val sandbox_network_label_key : string
val sandbox_ttl_sec_label_key : string
val sandbox_turn_id_label_key : string

(** Value of {!sandbox_component_label_key} ([= "keeper-sandbox"]). *)
val sandbox_component_label_value : string

(** [normalize_base_path_for_hash base_path] resolves relative base paths against
    {!Config_dir_resolver.current_working_dir} and strips trailing slashes before
    hashing. Pure apart from cwd resolution. *)
val normalize_base_path_for_hash : string -> string

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
    particular, [Network_host] maps to [--network host] so the
    container shares the host network namespace (needed for
    `git clone` / `gh push` from keepers running under this profile;
    see #10431).  The MASC label is the canonical ["host"]. *)
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

(** Best-effort cleanup for stale MASC keeper sandbox containers under the
    same base path. Only containers with the keeper sandbox labels are
    considered. *)
val cleanup_stale_containers
  :  ?now:float
  -> ?max_age_sec:float
  -> base_path:string
  -> timeout_sec:float
  -> unit
  -> cleanup_result

(** Interval-throttled wrapper used before launching keeper Docker
    containers. Concurrent fibers entering the same interval window are
    serialized by a CAS gate on the internal [last_cleanup_at] timestamp;
    losers receive [None] and skip the sweep. Failed cleanup sweeps also
    activate a longer daemon-failure backoff so an unhealthy Docker socket
    does not emit the same cleanup WARN every interval. See
    {!reset_last_cleanup_for_tests}. *)
val maybe_cleanup_stale_containers
  :  ?now:float
  -> base_path:string
  -> timeout_sec:float
  -> unit
  -> cleanup_result option

(** Reset the cleanup interval/backoff gates so the next call always runs a
    sweep. Test-only. *)
val reset_last_cleanup_for_tests : unit -> unit

(** Global keeper sandbox preflight used by sandbox diagnostics.
    Returns [None] when
    [MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false]. *)
val docker_preflight : timeout_sec:float -> unit -> docker_preflight option

val docker_preflight_to_yojson : docker_preflight -> Yojson.Safe.t
val docker_preflight_failure_message : docker_preflight -> string

(** Fail-fast keeper-up preflight for [sandbox_profile=docker].
    This stays on the lightweight request path: it checks runtime
    hardening and image presence, while the full required-command
    inventory remains in [docker_preflight] for diagnostic/status surfaces. *)
val ensure_keeper_startup_preflight
  :  timeout_sec:float
  -> sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile
  -> (unit, string) result

(** Lightweight image-presence gate for per-command execution paths. The
    startup preflight can pass and the image can later be pruned, so docker
    execution paths call this before [docker run] to fail locally rather than
    falling through to a registry pull. *)
val ensure_keeper_sandbox_image_present
  :  image:string
  -> timeout_sec:float
  -> (unit, string) result

val ensure_keeper_sandbox_image_present_with_class
  :  image:string
  -> timeout_sec:float
  -> (unit, classified_error) result

val docker_image_preflight_error_code : classified_error -> string
val docker_image_preflight_failure_message : prefix:string -> classified_error -> string

(** Returns the [--security-opt seccomp=...] argv fragment when the
    runtime passes; [Error _] when something is missing.

    The fragment is empty when the env config has no seccomp profile
    set; the caller should still concat it into the docker argv. *)
val ensure_keeper_sandbox_runtime : timeout_sec:float -> (string list, string) result

(** Internals exposed for unit testing the docker inspect output
    parser (#10488 regression coverage).  The parser result is
    projected onto a tuple
    [(owner_pid, started_at, running, ttl_sec)] so the test does
    not need a re-exported record type. *)
module For_testing : sig
  val nonempty_lines : string -> string list

  val parse_inspect_line
    :  string
    -> (int option * float option * bool option * float option, string) result
end

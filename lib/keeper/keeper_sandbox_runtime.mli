(** Keeper sandbox runtime preflight.

    Shared between [Keeper_exec_shell] (bash sandbox) and
    [Keeper_docker_read] (read sandbox). Both surfaces need to verify
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
  ; hard_mode : bool
  ; credential_fallbacks_disabled : bool
  ; git_egress : string
  ; image : string
  ; docker_runtime_ok : bool
  ; docker_runtime_error : string option
  ; hardening_ok : bool
  ; hardening_error : string option
  ; image_present : bool
  ; image_error : string option
  ; required_commands : required_command_check list
  ; missing_commands : string list
  ; next_actions : string list
  }

type cleanup_result =
  { scanned : int
  ; removed : int
  ; errors : string list
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

(** Docker network argv fragment and the MASC network label.  In
    particular, [Network_inherit] maps to [--network host] so the
    container shares the host network namespace (needed for
    `git clone` / `gh push` from keepers running under this profile;
    see #10431).  The MASC label remains ["inherit"]. *)
val docker_network_args : Keeper_types.network_mode -> string list * string

(** Docker [--ulimit nofile=<soft>:<hard>] argv fragment for keeper
    sandbox containers. *)
val docker_nofile_args : unit -> string list

(** Docker [--env ...] argv fragment for the numeric keeper user. *)
val docker_user_env_args : unit -> string list

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

(** Throttled wrapper used before launching keeper Docker containers. *)
val maybe_cleanup_stale_containers
  :  base_path:string
  -> timeout_sec:float
  -> unit
  -> cleanup_result option

(** Global keeper sandbox preflight used by [doctor], keeper startup,
    and diagnostics. Returns [None] when
    [MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false]. *)
val docker_preflight : timeout_sec:float -> unit -> docker_preflight option

val docker_preflight_to_yojson : docker_preflight -> Yojson.Safe.t
val docker_preflight_failure_message : docker_preflight -> string

(** Fail-fast keeper-up preflight for [sandbox_profile=docker]. *)
val ensure_keeper_startup_preflight
  :  timeout_sec:float
  -> sandbox_profile:Keeper_types.sandbox_profile
  -> (unit, string) result

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

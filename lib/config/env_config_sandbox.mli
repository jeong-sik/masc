(** Sandbox configuration SSOT.

    This module is the authoritative source for sandbox env settings + hardcoded
    constants used by keeper sandbox and docker playground execution
    paths — one typed surface so:

    1. Operators can read every effective sandbox setting + its
       provenance from a single JSON dump
       ({!effective_config_json}).
    2. Tests pin the default table once; drift is a compile or test
       failure rather than a silent budget shift.
    3. The {!Shell_timeout} sub-module exposes the typed-bucket
       pattern for shell timeout buckets. *)

(** {1 Hardening — security policy and resource limits} *)
module Hardening : sig
  val pids_limit : unit -> int
  (** Docker [--pids-limit].  Floored at 32.
      Env: [MASC_KEEPER_SANDBOX_PIDS_LIMIT].  Default: 128. *)

  val nofile_limit : unit -> int
  (** Soft and hard [nofile] inside the container.  Floored at 1024.
      Env: [MASC_KEEPER_SANDBOX_NOFILE_LIMIT].  Default: 245760. *)

  val memory : unit -> string
  (** Docker [--memory] string (e.g. ["2g"], ["512m"]).
      Env: [MASC_KEEPER_SANDBOX_MEMORY].  Default: ["2g"]. *)

  val tmpfs_size : unit -> string
  (** Writable [/tmp] tmpfs size inside the read-only rootfs.
      Env: [MASC_KEEPER_SANDBOX_TMPFS_SIZE].  Default: ["256m"]. *)

  val relax_fs : unit -> bool
  (** When true, omit [--read-only] and drop [/tmp]'s [noexec] bit.
      Env: [MASC_KEEPER_SANDBOX_RELAX_FS].  Default: [false]. *)

  val read_only_rootfs_args : unit -> string list
  (** Derived: [["--read-only"\]] when {!relax_fs} is false, else
      empty. *)

  val tmpfs_mount : unit -> string
  (** Derived: ["/tmp:rw,nosuid,nodev[,noexec],size=<tmpfs_size>"].
      The [noexec] bit is omitted when {!relax_fs} is true. *)

  val seccomp_profile : unit -> string
  (** Path to seccomp JSON profile.  Empty string disables seccomp
      enforcement.
      Env: [MASC_KEEPER_SANDBOX_SECCOMP_PROFILE].  Default: ["" ]. *)

  val require_rootless : unit -> bool
  (** Fail closed unless Docker reports rootless mode support.
      Env: [MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS].  Default: [false]. *)

  val require_userns : unit -> bool
  (** Fail closed unless Docker reports userns support.
      Env: [MASC_KEEPER_SANDBOX_REQUIRE_USERNS].  Default: [false]. *)
end

(** {1 Cleanup — stale container reaping} *)
module Cleanup : sig
  val enabled : unit -> bool
  (** Env: [MASC_KEEPER_SANDBOX_CLEANUP_ENABLED].  Default: [true]. *)

  val interval_sec : unit -> float
  (** Throttle interval between automatic cleanup sweeps in one
      server process.  Floored at 10 seconds.
      Env: [MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC].  Default: 300
      (5m). *)

  val managed_sleep_sec : unit -> int
  (** Marker sleep duration for the [managed] container init loop
      (currently [sleep 3600] in {!Keeper_sandbox_control}).
      Exposed here so a future PR can env-override; today this
      getter still returns the historical literal 3600 because no
      caller is wired yet.
      Env: not yet read.  Default: 3600. *)
end

(** {1 Runtime — image and execution mode} *)
module Runtime : sig
  val docker_image : unit -> string
  (** Env: [MASC_KEEPER_SANDBOX_DOCKER_IMAGE].  Default:
      ["masc-keeper-sandbox:local"]. *)

  val docker_playground_enabled : unit -> bool
  (** Route Execute through a Docker container instead of local
      subprocess.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND].  Default: [false]. *)

  val docker_playground_container_name : unit -> string
  (** Docker container name for keeper playground execution.
      Env: [MASC_KEEPER_DOCKER_CONTAINER].
      Default: ["keeper-playground"]. *)

  val docker_playground_container_root : unit -> string
  (** Container-side root under which keeper playground bundles are
      mounted.  Host [<base_path>/.masc/playground/<keeper>/…] maps to
      [<container_playground_root>/<keeper>/…] inside the container.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND_ROOT].
      Default: ["/home/keeper/playground"]. *)
end

(** {1 Preflight — runtime feasibility check} *)
module Preflight : sig
  val enabled : unit -> bool
  (** Master switch for keeper_up / diagnostics preflight.
      Env: [MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED].  Default: [true]. *)

end

(** {1 Shell_timeout — typed-bucket per-command timeout SSOT}

    Per-command-class timeout buckets for the keeper sandbox shell path.
    Each bucket names a class of shell commands that share a budget. *)
module Shell_timeout : sig
  type bucket =
    | Io
        (** I/O-bound commands. 30s. *)
    | Read
        (** Read-only commands. 15s. *)
    | User_max
        (** Upper bound for user-provided [timeout_sec] in
            Execute.  180s. *)
    | Cleanup_rm
        (** [docker rm -f] timeout used by turn-scoped cleanup.
            Currently hardcoded 5.0 in
            {!Keeper_turn_sandbox_runtime}.  5s. *)
    | Unknown of string

  val bucket_key : bucket -> string
  (** Lowercase token used in env var names. *)

  val known_buckets : unit -> bucket list
  (** Typed table for default-pinning tests. *)

  val known_default_sec : bucket -> float option
  (** Hardcoded default seconds for [bucket]. [None] for [Unknown _]. *)

  val per_bucket_env_var : bucket:bucket -> string
  (** [MASC_KEEPER_SHELL_TIMEOUT_<BUCKET>_SEC]. *)

  val global_env_var : string
  (** [MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC] — only consulted for
      [Unknown _]. *)

  val global_default_sec : float
  (** Final fallback (30.0s). *)

  val timeout_sec : bucket:bucket -> unit -> float
  (** Resolves the timeout for [bucket].  Lookup order:

      1. Per-bucket env [MASC_KEEPER_SHELL_TIMEOUT_<BUCKET>_SEC].
      2. {!known_default_sec}.
      3. Global env [MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC] — only
         for [Unknown _].
      4. {!global_default_sec}. *)
end

(** {1 Diagnostics / observability surface} *)

val effective_config_json : unit -> Yojson.Safe.t
(** Returns a snapshot of every sandbox setting under two top-level
    keys:

    - [raw.<section>.<key>] = [\{ value, source, env_var | null \}]
      where [source] is one of ["env"], ["default"], or ["hardcoded"]
      and [env_var] is [null] for non-overridable values.
    - [derived.<key>] = effective values after cross-cutting rules.

    Operators read [raw] to confirm "did my env override take?" and
    [derived] to see "what will Docker actually see?". *)

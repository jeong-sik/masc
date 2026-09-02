(** Sandbox configuration SSOT.

    This module is the authoritative source for sandbox env settings + hardcoded
    constants used by keeper sandbox and docker playground execution
    paths — one typed surface so:

    1. Tests pin the default table once; drift is a compile or test
       failure rather than a silent budget shift.
    2. The {!Shell_timeout} sub-module exposes the typed-bucket
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

(** {1 Runtime — image and execution mode} *)
module Runtime : sig
  val docker_image : unit -> string

  val microvm_remove_timeout_sec : unit -> float
  (** How long to wait for a microvm guest to be removed. Removing one is a
      VM shutdown: measured at 63-67s, against a Cleanup_rm bucket of 10s and
      an Io bucket of 30s that were both sized for docker. *)

  val microvm_dns : unit -> string
  (** Nameserver handed to a microvm guest on the default network.

      Defaults to the host's first [/etc/resolv.conf] nameserver so a guest
      resolves the way the host does; [MASC_KEEPER_MICROVM_DNS] overrides it.
      Empty -- an unreadable resolv.conf, or an explicit empty override --
      passes no [--dns]. *)

  val microvm_memory : unit -> string
  (** Memory for a keeper-lifetime microvm guest
      ([MASC_KEEPER_MICROVM_MEMORY], e.g. "8g"). Empty falls back to the
      shared sandbox cap [Hardening.memory], so raising only the guests
      does not touch the docker lane. The guest holds this allocation for
      its whole keeper lifetime — size it for the heaviest build the
      keeper runs, not the average turn. *)

  val microvm_cpus : unit -> string
  (** CPU count for a microvm guest ([MASC_KEEPER_MICROVM_CPUS], e.g.
      "8"). Empty passes no [--cpus] and takes the container CLI's
      default allocation. *)

  val microvm_build_volume_size : unit -> string

  val microvm_work_volume_size : unit -> string
  (** [MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE], default [256g]. Ceiling of the
      per-keeper work volume that holds the keeper's working tree (RFC-0400);
      the image is sparse. *)

  val microvm_payload_path : unit -> string
  (** [MASC_KEEPER_MICROVM_PAYLOAD_PATH]. The PATH the guest's shim hands
      every payload, written into the guest's shim config as [path=].
      Default names the keeper image's opam switch ahead of the system
      directories. *)
  (** Ceiling for a keeper's build volume
      ([MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE], e.g. "128g").

      The image is sparse -- 4 GiB nominal measured at 84 MB on disk -- so
      this reserves nothing and a generous default costs nothing until a
      build fills it. It is a ceiling rather than an allocation, and a build
      that exceeds it fails inside the guest with ENOSPC, so size it above
      the heaviest checkout set a keeper holds. The default is set against a
      measurement: one keeper's playground held three 29 GB [_build]
      directories, 87 GB together. *)
  (** Env: [MASC_KEEPER_SANDBOX_DOCKER_IMAGE].  Default:
      ["masc-keeper-sandbox:local"]. *)

  val docker_playground_enabled : unit -> bool
  (** Route Execute through a Docker container instead of local
      subprocess.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND].  Default: [false]. *)

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

  val ssh_ttl_sec : unit -> int
  (** Successful/failed SSH readiness observation TTL in seconds.
      Env: [MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC]. Default: [60]. [0] disables
      caching, which is useful for deterministic tests. *)

  val ssh_disk_free_min_kib : unit -> int
  (** Minimum available space under the endpoint remote root, in KiB.
      Env: [MASC_KEEPER_SSH_PREFLIGHT_DISK_FREE_MIN_KIB]. Default: [1048576]
      (1 GiB). *)
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

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
  val microvm_remove_timeout_sec : unit -> float
  (** How long to wait for a microvm guest to be removed. Removing one is a
      VM shutdown: measured at 63-67s, against a Cleanup_rm bucket of 10s and
      an Io bucket of 30s that were both sized for docker. *)

  (** Why a text cannot be a guest's nameserver. Each case is an address that
      means something on the host and nothing inside the guest. *)
  type nameserver_refusal =
    | Not_an_address
    | Zone_scoped
        (** [fe80::1%en0]: the zone names an interface of the host, and the
            guest has no such interface. *)
    | Unspecified
        (** [::], [0.0.0.0], or anything in [0.0.0.0/8]. *)
    | Loopback
        (** Inside the guest this is the guest itself. *)
    | Link_local
        (** [fe80::/10] or [169.254.0.0/16]: reachable only over the link the
            host is attached to. *)
    | Multicast

  val nameserver_of_string : string -> (Ipaddr.t, nameserver_refusal) result
  (** The address in [text] once surrounding blanks are dropped, or the reason
      it cannot be handed to a guest. Nothing else is accepted: a host name is
      [Not_an_address], because the guest would have to resolve it with the
      resolver it is being given. *)

  val nameserver_refusal_to_string : nameserver_refusal -> string
  (** A phrase that completes "<text> ...", for the operator. *)

  val first_nameserver_of : string -> string option
  (** The first [nameserver] line of a resolv.conf's text. Blanks and tabs
      separate the fields, and anything after the address is ignored. *)

  val microvm_dns_from :
    configured:string -> host:string option -> (Ipaddr.t, string) result
  (** The resolution rule behind {!microvm_dns}, with both inputs given.
      [configured] counts as unset when blank, and then [host] -- the host's
      first resolver -- decides. A [configured] value that is set and is not
      a usable address is [Error], never replaced by [host]: the operator
      named a resolver, and booting on another would say nothing. A [host]
      resolver the guest cannot use, or none at all, is [Error] naming
      [sandbox.microvm_dns] as the way out. *)

  val microvm_dns : unit -> (Ipaddr.t, string) result
  (** The nameserver a microvm guest on the default network is booted with:
      [MASC_KEEPER_MICROVM_DNS], which [runtime.toml] [sandbox.microvm_dns]
      seeds, else the host's first [/etc/resolv.conf] nameserver, through
      {!microvm_dns_from}. runtime.toml is read once at boot, so a change to
      the key takes a server restart. *)

  val microvm_dns_effective_from :
    configured:string -> host:string option -> (string, string) result
  (** What the settings surface shows for the setting. [Error] only for a
      [configured] value that is set and is not a usable address: that is the
      operator's input, and the surface reports it as a configuration error.
      An unset value shows the host's resolver, or [unusable: ...] when the
      host's cannot be used by a guest. It is not [Error] then: the surface
      is read for every setting before runtime.toml is applied, and a host
      whose resolver a guest cannot use must still let the file that names
      the fix load. The guest's boot refuses instead, through {!microvm_dns}. *)

  val microvm_dns_effective : unit -> (string, string) result
  (** {!microvm_dns_effective_from} over the process setting and the host's
      resolv.conf. *)

  val microvm_memory_default : string
  val microvm_cpus_default : int
  (** What a guest boots with when neither the keeper nor the workspace names
      a size. The registry row displays these rather than restating them. *)

  val microvm_memory : unit -> (Keeper_microvm_guest_size.memory, string) result
  (** The workspace's guest memory: [runtime.toml] [sandbox.microvm_memory],
      else {!microvm_memory_default}. The process environment is not read.
      Blank counts as unset. A set value that does not parse is [Error] naming
      the key, never the default. The guest holds this allocation for its
      whole keeper lifetime -- size it for the heaviest build the keeper runs,
      not the average turn. *)

  val microvm_cpus : unit -> (Keeper_microvm_guest_size.cpus, string) result
  (** The workspace's guest CPU count: [runtime.toml] [sandbox.microvm_cpus],
      else {!microvm_cpus_default}. The process environment is not read. Same
      blank and refusal rules as {!microvm_memory}. *)

  val microvm_guest_size :
    memory:Keeper_microvm_guest_size.memory option ->
    cpus:Keeper_microvm_guest_size.cpus option ->
    (Keeper_microvm_guest_size.t, string) result
  (** The size a keeper's guest boots with: the keeper's own [microvm_memory]
      and [microvm_cpus] where it set them, {!microvm_memory} and
      {!microvm_cpus} for the rest. The boot and the sandbox status both ask
      this, so what the dashboard shows is what the guest was given. *)

  val microvm_work_volume_size : unit -> string
  (** [MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE], default [256g]. Ceiling of the
      per-keeper work volume that holds the keeper's working tree (RFC-0400);
      the image is sparse. *)

  val microvm_build_volume_size : unit -> string
  (** [MASC_KEEPER_MICROVM_BUILD_VOLUME_SIZE], default [128g], sized against
      one keeper's measured 87 GB of [_build] across three checkouts.
      Ceiling of the per-keeper build volume that holds derived [_build]
      output (RFC-keeper-build-output-returns-to-a-disposable-volume),
      `Apple_container` only; the image is sparse. *)

  val microvm_payload_path : unit -> string
  (** [MASC_KEEPER_MICROVM_PAYLOAD_PATH]. The PATH the guest's shim hands
      every payload, written into the guest's shim config as [path=].
      Default names the keeper image's opam switch ahead of the system
      directories. *)

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
    | Cleanup_rm
        (** [docker rm -f] timeout used by turn-scoped cleanup.  10s. *)

  val bucket_key : bucket -> string
  (** Lowercase token used in env var names. *)



  val per_bucket_env_var : bucket:bucket -> string
  (** [MASC_KEEPER_SHELL_TIMEOUT_<BUCKET>_SEC]. *)


  val global_default_sec : float
  (** Used when the per-bucket env value is not a number (30.0s). *)

  val timeout_sec : bucket:bucket -> unit -> float
  (** Resolves the timeout for [bucket].  Lookup order:

      1. Per-bucket env [MASC_KEEPER_SHELL_TIMEOUT_<BUCKET>_SEC]; a value
         that is not a number reads as {!global_default_sec}.
      2. The bucket's own default. *)
end

(** {1 Diagnostics / observability surface} *)

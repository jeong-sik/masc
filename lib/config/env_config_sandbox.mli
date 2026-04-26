(** Sandbox configuration SSOT.

    Mirrors {!Env_config_exec_timeout} (#10426) and the
    {!Env_config_oas_bridge} precedent (#10094).  This module gathers
    the 25+ env-var settings + handful of hardcoded constants that
    today live across {!Env_config_keeper.KeeperSandbox},
    {!Env_config_keeper.DockerPlayground}, and several
    [lib/keeper/keeper_*.ml] sites — into one typed surface so:

    1. Operators can read every effective sandbox setting + its
       provenance from a single JSON dump
       ({!effective_config_json}).
    2. Tests pin the default table once; drift is a compile or test
       failure rather than a silent budget shift.
    3. The {!Shell_timeout} sub-module exposes the typed-bucket
       pattern from {!Env_config_exec_timeout} for the 6 (+1
       sentinel) shell timeout buckets currently scattered.

    This module is purely additive in the scaffold PR: every getter
    reads the same env var and returns the same default as the
    existing implementation.  Call sites are migrated in follow-ups
    (P2b alias delegation, P2c hardcoded constants, P2d doctor
    wiring). *)

(** {1 Hardening — security policy and resource limits} *)
module Hardening : sig
  (** Forces rootless/userns runtime checks, disables Docker-side
      git/gh credential dispatch, and clears host credential
      fallbacks.
      Env: [MASC_KEEPER_SANDBOX_HARD_MODE].  Default: [false]. *)
  val hard_mode : unit -> bool

  (** Docker [--pids-limit].  Floored at 32.
      Env: [MASC_KEEPER_SANDBOX_PIDS_LIMIT].  Default: 128. *)
  val pids_limit : unit -> int

  (** Soft and hard [nofile] inside the container.  Floored at 1024.
      Env: [MASC_KEEPER_SANDBOX_NOFILE_LIMIT].  Default: 245760. *)
  val nofile_limit : unit -> int

  (** Docker [--memory] string (e.g. ["2g"], ["512m"]).
      Env: [MASC_KEEPER_SANDBOX_MEMORY].  Default: ["2g"]. *)
  val memory : unit -> string

  (** Writable [/tmp] tmpfs size inside the read-only rootfs.
      Env: [MASC_KEEPER_SANDBOX_TMPFS_SIZE].  Default: ["256m"]. *)
  val tmpfs_size : unit -> string

  (** When true, omit [--read-only] and drop [/tmp]'s [noexec] bit.
      Returns the raw env value; the hard_mode interaction is
      enforced by callers reading {!read_only_rootfs_args} and
      {!tmpfs_mount} rather than by this getter.  Operators who set
      both should expect their explicit [relax_fs] to win against
      the implicit hard_mode default — change with care.
      Env: [MASC_KEEPER_SANDBOX_RELAX_FS].  Default: [false]. *)
  val relax_fs : unit -> bool

  (** Derived: [["--read-only"\]] when {!relax_fs} is false, else
      empty. *)
  val read_only_rootfs_args : unit -> string list

  (** Derived: ["/tmp:rw,nosuid,nodev[,noexec],size=<tmpfs_size>"].
      The [noexec] bit is omitted when {!relax_fs} is true. *)
  val tmpfs_mount : unit -> string

  (** Path to seccomp JSON profile.  Empty string disables seccomp
      enforcement.
      Env: [MASC_KEEPER_SANDBOX_SECCOMP_PROFILE].  Default: ["" ]. *)
  val seccomp_profile : unit -> string

  (** Fail closed unless Docker reports rootless mode support.
      Always true when {!hard_mode} is true.
      Env: [MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS].  Default: [false]. *)
  val require_rootless : unit -> bool

  (** Fail closed unless Docker reports userns support.
      Always true when {!hard_mode} is true.
      Env: [MASC_KEEPER_SANDBOX_REQUIRE_USERNS].  Default: [false]. *)
  val require_userns : unit -> bool
end

(** {1 Cleanup — stale container reaping} *)
module Cleanup : sig
  (** Env: [MASC_KEEPER_SANDBOX_CLEANUP_ENABLED].  Default: [true]. *)
  val enabled : unit -> bool

  (** Threshold age before a running container becomes eligible for
      cleanup.  Floored at 60 seconds.
      Env: [MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC].  Default:
      21600 (6h). *)
  val stale_after_sec : unit -> float

  (** Throttle interval between automatic cleanup sweeps in one
      server process.  Floored at 10 seconds.
      Env: [MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC].  Default: 300
      (5m). *)
  val interval_sec : unit -> float

  (** Sentinel sleep duration for the [managed] container init loop
      (currently [sleep 3600] in {!Keeper_sandbox_control}).
      Exposed here so a future PR can env-override; today this
      getter still returns the historical literal 3600 because no
      caller is wired yet.
      Env: not yet read.  Default: 3600. *)
  val managed_sleep_sec : unit -> int
end

(** {1 Runtime — image and execution mode} *)
module Runtime : sig
  (** Env: [MASC_KEEPER_SANDBOX_DOCKER_IMAGE].  Default:
      ["masc-keeper-sandbox:local"]. *)
  val docker_image : unit -> string

  (** When true, keeper_bash commands beginning with ["git "] or
      ["gh "] run in a dedicated container with [network_mode=host]
      and read-only credential mounts.  Effective value is [false]
      when {!Hardening.hard_mode} is true.
      Env: [MASC_KEEPER_SANDBOX_GIT_DISPATCH].  Default: [true]. *)
  val git_dispatch : unit -> bool

  (** Route keeper_bash through a Docker container instead of local
      subprocess.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND].  Default: [false]. *)
  val docker_playground_enabled : unit -> bool
end

(** {1 Auth_paths — credential mount points} *)
module Auth_paths : sig
  (** Host path for [/root/.config/gh] read-only mount.  Empty
      string disables the mount.  Effective value is [""] when
      {!Hardening.hard_mode}; otherwise default falls through to
      [$HOME/.config/gh].
      Env: [MASC_KEEPER_SANDBOX_GH_CREDS].  Default:
      [$HOME/.config/gh]. *)
  val gh_creds : unit -> string

  (** Host path for [/root/.gitconfig] read-only mount.  Empty
      string disables the mount.  [""] when hard_mode.
      Env: [MASC_KEEPER_SANDBOX_GITCONFIG].  Default:
      [$HOME/.gitconfig]. *)
  val gitconfig : unit -> string

  (** Host path for [~/.ssh] read-only mount.  Opt-in (default
      empty).  [""] when hard_mode.
      Env: [MASC_KEEPER_SANDBOX_SSH_DIR].  Default: [""]. *)
  val ssh_dir : unit -> string

  (** Wall-clock budget for the [gh auth token] keychain probe.
      Clamped to [[0.1, 10.0]].
      Env: [MASC_KEEPER_SANDBOX_GH_TOKEN_PROBE_TIMEOUT_SEC].
      Default: 2.0. *)
  val gh_token_probe_timeout_sec : unit -> float
end

(** {1 Preflight — runtime feasibility check} *)
module Preflight : sig
  (** Master switch for keeper_up / doctor preflight.
      Env: [MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED].  Default: [true]. *)
  val enabled : unit -> bool

  (** Lower bound applied via [max] on the caller-supplied timeout
      when running preflight commands.  Currently hardcoded 5.0 in
      {!Keeper_sandbox_runtime}; this getter exposes it for future
      env-override (P2c).
      Env: not yet read.  Default: 5.0. *)
  val min_timeout_sec : unit -> float

  (** Upper bound applied via [min] on the caller-supplied timeout.
      Currently hardcoded 20.0.
      Env: not yet read.  Default: 20.0. *)
  val max_timeout_sec : unit -> float

  (** The 18 CLI tools the keeper image contract guarantees
      ([sh; bash; cat; find; head; tail; wc; git; gh; rg; tree; jq;
      python3; node; npm; make; opam; dune; ssh]).

      INTENTIONALLY NOT env-overridable: an operator who removes
      [gh] from the list would make doctor falsely report green
      while runtime fails opaquely.  Exposed read-only so doctor
      and tests can iterate the canonical list. *)
  val required_commands : unit -> string list
end

(** {1 Shell_timeout — typed-bucket per-command timeout SSOT}

    Mirrors {!Env_config_exec_timeout} but for command-class buckets
    rather than per-call-site.  Each bucket names a class of shell
    commands that share a budget. *)
module Shell_timeout : sig
  type bucket =
    | Io (** I/O-bound commands (bash, git status, etc.).  30s. *)
    | Read
    (** Read-only commands (cat, rg, head, tail, find,
            git_log, tree).  15s. *)
    | Git_meta (** Lightweight git metadata (rev-parse, log --oneline).
            5s. *)
    | Gh_min
    (** Floor for gh CLI ops.  Read-only invariant — operators
            cannot lower this floor; sub-network-latency timeouts
            cause cascading 401 retries (see #8688).  15s. *)
    | User_max
    (** Upper bound for user-provided [timeout_sec] in
            keeper_bash.  180s. *)
    | Token_probe (** [gh auth token] keychain probe budget.  2s. *)
    | Cleanup_rm
    (** [docker rm -f] timeout used by turn-scoped cleanup.
            Currently hardcoded 5.0 in
            {!Keeper_turn_sandbox_runtime}.  5s. *)
    | Unknown of string

  (** Lowercase token used in env var names. *)
  val bucket_key : bucket -> string

  (** Typed table for default-pinning tests. *)
  val known_buckets : unit -> bucket list

  (** Hardcoded default seconds for [bucket].  [None] for [Unknown _]
      and [Gh_min] is returned as [Some 15.0] but the [timeout_sec]
      lookup ignores env overrides for that bucket (read-only
      floor). *)
  val known_default_sec : bucket -> float option

  (** [MASC_KEEPER_SHELL_TIMEOUT_<BUCKET>_SEC].  For [Gh_min] the
      function still returns the conventional name, but
      {!timeout_sec} ignores it. *)
  val per_bucket_env_var : bucket:bucket -> string

  (** [MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC] — only consulted for
      [Unknown _]. *)
  val global_env_var : string

  (** Final fallback (30.0s). *)
  val global_default_sec : float

  (** Resolves the timeout for [bucket].  Lookup order:

      1. [Gh_min] is resolved exclusively from {!known_default_sec}.
         The env override is ignored (read-only floor).
      2. Per-bucket env [MASC_KEEPER_SHELL_TIMEOUT_<BUCKET>_SEC].
      3. {!known_default_sec}.
      4. Global env [MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC] — only
         for [Unknown _].
      5. {!global_default_sec}. *)
  val timeout_sec : bucket:bucket -> unit -> float
end

(** {1 Doctor / observability surface} *)

(** Returns a snapshot of every sandbox setting under two top-level
    keys:

    - [raw.<section>.<key>] = [\{ value, source, env_var | null \}]
      where [source] is one of ["env"], ["default"], or
      ["load_bearing_floor"] (for [Gh_min] / [required_commands])
      and [env_var] is [null] for non-overridable values.
    - [derived.<key>] = effective values after cross-cutting rules
      (e.g. [hard_mode] coerces [relax_fs] to [false]).

    Operators read [raw] to confirm "did my env override take?" and
    [derived] to see "what will Docker actually see?". *)
val effective_config_json : unit -> Yojson.Safe.t

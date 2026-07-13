(** RFC-0084 §1.5 + §3.4 + RFC-0085 PR-1 — Typed host configuration for
    keeper-tool dispatch portability.

    Canonical accessor is [host ()].  RFC-0085 PR-1 removed the
    previous misnomer [legacy_macos_default ()] (the function was the
    *current* default accessor used by 62 callers, not a regression
    fixture).

    Fields cover the host-bound paths that keeper / dispatch / shell
    layers consume.  PR-1 introduces [log_dir], [run_dir], [policy_dir]
    so RFC-0085 PR-2 / PR-3 can drop host-local runtime path hardcodes at
    the call-sites.

    All record / variant types derive [show] and [eq] so callers can
    use the auto-generated [pp_t], [show_t], [equal] without writing
    bespoke formatters. *)

(** Resolved coreutils binary paths.  Each field is the absolute path
    discovered through [PATH] resolution (fallback to the
    [coreutils_defaults] record if [PATH] lookup fails — see [resolve]). *)
type coreutils =
  { ls : string
  ; cat : string
  ; pwd : string
  ; head : string
  ; tail : string
  ; wc : string
  }
[@@deriving show, eq]

(** Test-mode token (replaces [String.starts_with "test_" executable]
    at the historical 5 detection sites). *)
type test_mode_kind =
  | Test
  | Production
[@@deriving show, eq]

(** Top-level typed host configuration. *)
type t =
  { cred_root : string
        (** Credential bundle root (default [<tmp>/keeper-creds]). *)
  ; host_bash : string  (** Absolute path to [bash] binary. *)
  ; host_zsh : string  (** Absolute path to [zsh] binary. *)
  ; host_sh : string  (** Absolute path to POSIX [sh] binary. *)
  ; coreutils : coreutils
        (** ls / cat / pwd / head / tail / wc absolute paths. *)
  ; agent_runtime_root : string
        (** Runtime root for cross-process agent identity files.
            Maps to [<tmp>] from [host ()] and [<base_path>/.masc/runtime/agent]
            from [resolve]. *)
  ; sandbox_workspace_root : string
        (** Fleet sandbox root.  Defaults through [MASC_BASE_PATH], then
            [ME_ROOT], then [<tmp>/masc-fleet] from [host ()]. *)
  ; test_mode : test_mode_kind
        (** Typed test-mode boundary. *)
  ; log_dir : string
        (** Directory for runtime log files
            ([auto-responder.log], [auto_debug.log], ...).  Default [<tmp>]
            from [host ()]; configurable via env in [resolve]. *)
  ; run_dir : string
        (** Host-selected root for runtime state files (PID locks, sockets).
            Default [<tmp>] from [host ()]. BasePath ownership establishes its
            current-UID private lease directory below this root and rejects an
            unprotected group/world-writable root; callers do not select a
            fallback. *)
  ; policy_dir : string
        (** Directory for runtime policy files.  Default [<tmp>] from
            [host ()]. *)
  ; base_path : string option
        (** Resolved [MASC_BASE_PATH] in *normalised* form (path
            normalisation applied).  [None] when unset or empty after
            normalisation.  RFC-0085 PR-9 replaces
            [Env_config_core.base_path_opt]. *)
  ; base_path_raw : string option
        (** Raw base-path input as read from [MASC_BASE_PATH_INPUT] first,
            then [MASC_BASE_PATH], with whitespace trimmed but no path
            normalisation.  Used by routes / dashboard / config diagnostics
            inputs that surface the operator's literal input.  RFC-0085
            PR-9 replaces [Env_config_core.base_path_raw_opt]. *)
  ; config_dir : string option
        (** Resolved [MASC_CONFIG_DIR].  [None] when unset. *)
  ; data_dir : string option
        (** Resolved [MASC_DATA_DIR].  [None] when unset. *)
  ; personas_dir : string option
        (** Resolved [MASC_PERSONAS_DIR].  [None] when unset. *)
  ; home : string option
        (** Operator [$HOME] directory, trimmed.  [None] when unset or
            empty.  RFC-0085 PR-10 replaces
            [Env_config_core.home_dir_opt]. *)
  ; assets_dir : string option
        (** Resolved [MASC_ASSETS_DIR].  [None] when unset or empty.
            RFC-0085 PR-10 replaces [Env_config_core.assets_dir_opt]. *)
  }
[@@deriving show, eq]

(** [resolve ?base_path ()] builds a [t] by resolving each field
    against the host environment ([PATH] lookup for binaries,
    [base_path] for runtime roots).  [base_path] defaults to the host
    temp directory (typically [TMPDIR] or [/tmp]). *)
val resolve : ?base_path:string -> unit -> (t, string) result

(** [host ()] returns the canonical default [t].  Used by 60+ keeper /
    dispatch / shell call-sites.  Tmp-directory roots are resolved via
    [Filename.get_temp_dir_name ()] (honours [TMPDIR]).  Binary paths
    fall back to the [coreutils_defaults] record.

    The four [_dir]/[base_path]/etc env-var-derived fields are populated
    from [Sys.getenv_opt] at call time; [host ()] reflects the *current*
    process environment, not a snapshot from boot. *)
val host : unit -> t

(** [from_env ()] is an alias for [host ()] emphasising that the four
    [base_path]/[config_dir]/[data_dir]/[personas_dir] fields are
    populated by reading the corresponding [MASC_*] environment
    variables.  RFC-0085 PR-6 introduces this surface so callers (today
    in [Config_dir_resolver]) can route env-derived path decisions
    through [Host_config] instead of importing [Env_config_core]
    primitives. *)
val from_env : unit -> t

(** [is_test_mode token] returns [true] for [Test], [false] for
    [Production]. *)
val is_test_mode : test_mode_kind -> bool

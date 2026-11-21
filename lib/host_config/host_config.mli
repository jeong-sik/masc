(** Typed host configuration for keeper-tool dispatch portability.

    Canonical accessor is [host ()].

    Fields cover the host-bound paths that keeper / dispatch / shell
    layers consume.

    All record / variant types derive [show] and [eq] so callers can
    use the auto-generated [pp_t], [show_t], [equal] without writing
    bespoke formatters. *)

(** Test-mode token. [Test] when the executable basename starts with
    ["test_"], as [Env_config_core.running_under_test_executable] decides. *)
type test_mode_kind =
  | Test
  | Production
[@@deriving show, eq]

(** Where a BasePath's cross-process ownership lease lives. *)
type base_path_lease_root =
  | Beside_base_path
      (** [<base_path>/.masc-owner]. Every process that names the BasePath
          finds the same lease, whatever its [TMPDIR]. *)
  | Lease_dir_override of string
      (** [MASC_BASE_PATH_LEASE_DIR], for a BasePath on a filesystem whose
          locks cannot be trusted. Every process of the BasePath must be given
          the same value. *)
[@@deriving show, eq]

(** Top-level typed host configuration. *)
type t =
  { cred_root : string
        (** Credential bundle root (default [<tmp>/keeper-creds]). *)
  ; host_bash : string  (** Absolute path to [bash] binary. *)
  ; host_zsh : string  (** Absolute path to [zsh] binary. *)
  ; host_sh : string  (** Absolute path to POSIX [sh] binary. *)
  ; agent_runtime_root : string
        (** Runtime root for cross-process agent identity files.
            [<tmp>] from [host ()]. *)
  ; sandbox_workspace_root : string
        (** Fleet sandbox root.  [host ()] takes the base path
            ([MASC_BASE_PATH], else the one an install recorded), then
            [<tmp>/masc-fleet]. *)
  ; test_mode : test_mode_kind
        (** Typed test-mode boundary. *)
  ; log_dir : string
        (** Directory for runtime log files
            ([auto-responder.log], [auto_debug.log], ...).  [<tmp>] from
            [host ()]. *)
  ; run_dir : string
        (** Host-selected root for runtime state files (PID locks, sockets).
            Default [<tmp>]. This process-local root must not cross PID
            namespaces. *)
  ; base_path_lease_root : base_path_lease_root
        (** [Lease_dir_override] when [MASC_BASE_PATH_LEASE_DIR] is set,
            otherwise [Beside_base_path]. *)
  ; policy_dir : string
        (** Directory for runtime policy files.  Default [<tmp>] from
            [host ()]. *)
  ; base_path : string option
        (** Resolved [MASC_BASE_PATH] in *normalised* form (path
            normalisation applied).  [None] when unset or empty after
            normalisation. *)
  ; base_path_raw : string option
        (** Raw base-path value as read from [MASC_BASE_PATH], or the recorded
            default, with whitespace trimmed but no path normalisation. In a
            server this is the canonical owner it published; the operator's own
            spelling is {!Server_startup_state.input_base_path}. *)
  ; config_dir : string option
        (** Resolved [MASC_CONFIG_DIR].  [None] when unset. *)
  ; home : string option
        (** Operator [$HOME] directory, trimmed.  [None] when unset or
            empty. *)
  ; assets_dir : string option
        (** Resolved [MASC_ASSETS_DIR].  [None] when unset or empty. *)
  }
[@@deriving show, eq]

(** [host ()] returns the canonical default [t].  Used by 60+ keeper /
    dispatch / shell call-sites.  Tmp-directory roots are resolved via
    [Filename.get_temp_dir_name ()] (honours [TMPDIR]).

    The path env-var-derived fields, including [base_path_lease_root] from
    [MASC_BASE_PATH_LEASE_DIR], are populated from [Sys.getenv_opt] at call
    time; [host ()] reflects the *current* process environment, not a snapshot
    from boot. *)
val host : unit -> t

(** [from_env ()] is an alias for [host ()] emphasising that the
    [base_path]/[config_dir] fields are
    populated by reading the corresponding [MASC_*] environment
    variables.  This surface lets callers (such as [Config_dir_resolver])
    route env-derived path decisions through [Host_config] instead of
    importing [Env_config_core] primitives. *)
val from_env : unit -> t

(** [is_test_mode token] returns [true] for [Test], [false] for
    [Production]. *)
val is_test_mode : test_mode_kind -> bool

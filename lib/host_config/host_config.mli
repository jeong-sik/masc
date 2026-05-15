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
        (** Fleet sandbox root.  Default [<HOME>/me] when [HOME] is
            set, else [<tmp>/masc-fleet]. *)
  ; test_mode : test_mode_kind
        (** Typed test-mode boundary. *)
  ; log_dir : string
        (** Directory for runtime log files
            ([auto-responder.log], [auto_debug.log], ...).  Default [<tmp>]
            from [host ()]; configurable via env in [resolve]. *)
  ; run_dir : string
        (** Directory for runtime state files (PID locks, sockets).
            Default [<tmp>] from [host ()]. *)
  ; policy_dir : string
        (** Directory for runtime policy files.  Default [<tmp>] from
            [host ()]. *)
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
    fall back to the [coreutils_defaults] record. *)
val host : unit -> t

(** [is_test_mode token] returns [true] for [Test], [false] for
    [Production]. *)
val is_test_mode : test_mode_kind -> bool

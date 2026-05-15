(** RFC-0084 §1.5 + §3.4 — Typed host configuration for keeper-tool
    dispatch portability.

    Today's keeper→tool execution cycle is bound to the operator's
    macOS workstation layout via 11 hardcoded paths verified at PR-1
    author time (see RFC-0084 §1.5 + analysis report
    [~/me/.tmp/keeper-tool-cycle-audit/03-hardcode-path-audit.md]):

    - [/tmp/keeper-creds] (host_config_provider.ml:3, 4 refs)
    - [/bin/bash] (keeper_shell_bash.ml:745, 802)
    - [/bin/zsh] (5 gh-family sites)
    - [/usr/bin/head], [/usr/bin/tail], [/usr/bin/wc], [/bin/ls],
      [/bin/cat], [/bin/pwd] (6 coreutils sites)
    - [/tmp/.masc_agent[_mcp]_<sid>] (7 sites — Tool_inline_dispatch_coord
      + Mcp_server_eio_execute)
    - [Filename.concat home "me"] (worker_dev_tools.ml:85)
    - [String.starts_with "test_"] (5 test-mode detection sites — but
      PR-F audit found only 1 site reaches the typed surface today:
      [config_dir_resolver.ml:55] in [masc_mcp].  The remaining
      4 sites live in lower-level sub-libraries
      ([masc_config.env_config_core], [masc_coord.coord_utils_backend_setup],
      [fs_compat.fs_compat], plus [cdal/adversarial_eval] which is a
      *file-classification* sibling pattern unrelated to current-binary
      test-mode).  Migrating those requires extracting [Host_config]
      into a lower-level shared library — separate RFC scope.)

    PR-12 introduces the typed record + accessors. The 11 hardcode-site
    migrations are scoped to *follow-up cleanup PRs* (one per
    sub-domain: credential / shell / coreutils / agent-runtime /
    sandbox / test-mode) so each can ship with its own host-matrix
    smoke (macOS + Linux) without bundling 11 simultaneous changes
    into one high-risk PR.

    The same delegation-not-absorption pattern as PR-6 / PR-8 / PR-9 /
    PR-10 / PR-11. *)

(** Resolved coreutils binary paths.  Each field is the absolute path
    discovered through [PATH] resolution (fallback to a documented
    legacy hardcode if [PATH] lookup fails — see [resolve]). *)
type coreutils =
  { ls : string
  ; cat : string
  ; pwd : string
  ; head : string
  ; tail : string
  ; wc : string
  }

(** Test-mode token (replaces [String.starts_with "test_" executable]
    boundary at the 5 sites enumerated in §1.5).  PR-12 introduces the
    typed surface; PR-12 follow-up cleanup migrates the 5 callers. *)
type test_mode_kind =
  | Test
      (** Test binary or test-only environment.  Maps to today's
          [String.starts_with ~prefix:"test_" Sys.argv.(0)] check. *)
  | Production

(** Top-level typed host configuration. *)
type t =
  { cred_root : string
        (** Credential bundle root.  Today: hardcoded
            [/tmp/keeper-creds] at [host_config_provider.ml:3] (4 refs).
            Migration target: [resolve ~base_path]-relative. *)
  ; host_bash : string  (** [/bin/bash] today; PATH-resolved post-migration. *)
  ; host_zsh : string  (** [/bin/zsh] today; PATH-resolved post-migration. *)
  ; host_sh : string  (** [/bin/sh] today; PATH-resolved post-migration. *)
  ; coreutils : coreutils
        (** ls / cat / pwd / head / tail / wc absolute paths. *)
  ; agent_runtime_root : string
        (** Runtime root for cross-process agent identity files.
            Today: [/tmp/.masc_agent[_mcp]_<sid>] 7 sites.  Migration
            target: [<base_path>/.masc/runtime/agent/<sid>]. *)
  ; sandbox_workspace_root : string
        (** Fleet sandbox root.  Today: [Filename.concat home "me"]
            at [worker_dev_tools.ml:85].  Migration target:
            config-driven via [resolve ~base_path]. *)
  ; test_mode : test_mode_kind
        (** Typed test-mode boundary replacing [String.starts_with
            "test_"] at 5 sites. *)
  }

(** [resolve ?base_path ()] builds a [t] by resolving each field
    against the host environment ([PATH] lookup for binaries,
    [base_path] for runtime roots) with documented fallbacks to the
    legacy hardcoded values for compatibility during the migration
    window.

    [base_path] defaults to [Coord.masc_dir config] when available,
    else the legacy [/tmp] root.  Each field is documented in [t]. *)
val resolve : ?base_path:string -> unit -> (t, string) result

(** [legacy_macos_default ()] returns the values that match the 11
    hardcoded sites at PR-1 author time.  Useful as a regression
    fixture: any host on which [resolve] does not return this exact
    record has at least one path that differs from the operator's
    macOS workstation, which would have been a silent failure pre-PR-12. *)
val legacy_macos_default : unit -> t

(** [is_test_mode token] returns [true] for [Test], [false] for
    [Production].  Replaces the boolean output of
    [String.starts_with ~prefix:"test_" executable] at the 5 detection
    sites. *)
val is_test_mode : test_mode_kind -> bool

(** Pretty-print a [t] for diagnostic logging.  Does NOT redact
    secrets — [cred_root] etc. are path strings, not credential
    values; the credentials themselves live under the path tree. *)
val pp : Format.formatter -> t -> unit

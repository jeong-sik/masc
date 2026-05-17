(** Typed argv schema for the keeper_bash tool.

    Introduced by RFC-0091 PR-1 (§5.1.1) to replace the legacy
    [{cmd: string}] schema whose post-hoc lexer in [Worker_dev_tools]
    accounts for ~253 of the top-20 24h ERROR (single-site emission +
    4-layer amplification, see RFC-0091 §4).

    The legacy lexer is preserved during PR-1 (one caller swap +
    differential test) and removed in PR-2 (lexer 17-function purge,
    callers fully migrated).

    {2 Design constraints}

    - **No string parsing**.  Validation is membership against
      {!Dev_exec_allowlist} plus structural checks on argv/cwd.
    - **No shell metacharacters in argv**.  Each {!exec_stage}
      element is a single token; pipes between stages are explicit
      {!Pipeline} cases, not [|]-delimited strings.
    - **Cwd is a string for now**.  Path SSOT does not yet expose a
      [Path.t] type (RFC-0091 §2.3 mis-cited [Host_config.cwd_for_keeper]
      which does not exist).  Absolute-path enforcement happens in
      {!validate}.  PR-3 may revisit when a path SSOT module lands. *)

type exec_stage = {
  executable : string;
  argv : string list;
}

type bash_input =
  | Exec of {
      executable : string;
      argv : string list;
      cwd : string option;
      env : (string * string) list;
    }
  | Pipeline of {
      stages : exec_stage list;
      cwd : string option;
      env : (string * string) list;
    }

type allowlist_mode =
  | Dev_full
  | Readonly

type validation_error =
  | Executable_not_allowlisted of {
      name : string;
      mode : allowlist_mode;
    }
  | Empty_argv of { executable : string }
  | Argv_contains_shell_metachar of {
      executable : string;
      index : int;
      token : string;
    }
  | Cwd_not_absolute of string
  | Pipeline_empty
  | Env_key_invalid of string

val validate : mode:allowlist_mode -> bash_input -> (unit, validation_error) result
(** Run all structural checks against [input].  Returns [Ok ()] on
    success, or the first {!validation_error} encountered.  No side
    effects, no exceptions. *)

val pp_validation_error : Format.formatter -> validation_error -> unit
(** Human-readable formatter for {!validation_error}.  Stable across
    PR-1/PR-2 — callers may rely on the message structure for log
    classification.  ERROR text intentionally lacks the legacy
    "Path syntax blocked" prefix so the 4-layer log amplification
    is severed at PR-2 lexer deletion. *)

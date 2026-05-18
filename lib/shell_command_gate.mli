(** Parse-once facade for shell command validation.

    This module is the narrow bridge between raw shell strings and the
    Shell_ir authority path. It preserves pipelines as first-class stage
    lists so callers do not need local quote-aware pipe splitters. *)

(** Caller identity for telemetry partition.  RFC-0131 §10 PR-1a.

    Currently the optional [?caller] arg on {!parse} and
    {!validate_allowlist} is captured but does not change behavior — the
    field exists so the upcoming telemetry counter exposure (RFC-0131
    PR-3) can already emit per-caller rows before the actual counter
    plumbing lands.  When unset, the gate behaves identically to the
    pre-RFC-0131 facade. *)
type caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

type cannot_parse_kind =
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted
  | Too_complex of Masc_exec.Parsed.reason_too_complex

type shape =
  | Simple
  | Pipeline of { stages : int }

type parsed_context = {
  ast : Masc_exec.Shell_ir.t;
  shape : shape;
  stage_bins : string list;
}

type reject_reason =
  | Command_not_in_allowlist of { bin : string }
  | Pipeline_segment_disallowed of { stage : int; bin : string }
  | Pipes_not_allowed of { stages : int }
  | Redirect_disallowed_in_caller of { stage_index : int }
      (** RFC-0131 PR-1c.  A stage carries a file redirect (>, >>, <)
          but the caller passed [?redirect_allowed:false].
          [stage_index] is the 0-based position; [Fd_to_fd] redirects
          (e.g. [2>&1]) are intentionally excluded from this policy
          since they do not touch the file system.  The bash_subset
          grammar currently classifies redirect syntax as
          [Too_complex `Redirect], so this arm is reachable only via
          a typed-IR entry (RFC-0131 PR-1b adds
          [parsed_context_of_shell_ir]) until the grammar grows
          redirect support. *)

type decision =
  | Allow of parsed_context
  | Reject of {
      context : parsed_context;
      reason : reject_reason;
      diagnostic : string;
    }
  | Cannot_parse of { kind : cannot_parse_kind }

val parse : ?caller:caller -> string -> (parsed_context, cannot_parse_kind) result
(** Parse a raw command into a reusable Shell_ir context.  [?caller] is
    captured for the upcoming telemetry partition (RFC-0131 PR-3) and
    does not affect the parse result. *)

val validate_allowlist
  :  ?caller:caller
  -> ?allow_pipes:bool
  -> ?redirect_allowed:bool
  -> allowed_commands:string list
  -> string
  -> decision
(** Parse once, then enforce an exact binary-name allowlist over every
    stage.  [?allow_pipes] defaults to [true].  [?redirect_allowed]
    defaults to [true]; when [false], any stage carrying a file
    redirect ([>], [>>], [<]) is rejected with
    {!Redirect_disallowed_in_caller}.  [Fd_to_fd] redirects (e.g.
    [2>&1]) are not affected by this policy.  [?caller] is captured
    for the upcoming telemetry partition (RFC-0131 PR-3) and does not
    affect the verdict. *)

val validate_parsed_context
  :  ?allow_pipes:bool
  -> ?redirect_allowed:bool
  -> allowed_commands:string list
  -> parsed_context
  -> decision
(** Validate an already-parsed context.  Same policy as
    {!validate_allowlist}, but skips the parse step — used by typed-input
    callers (e.g. RFC-0091 typed argv lowering) and by tests that need
    to construct contexts with redirects directly, since the bash_subset
    grammar does not currently emit them through {!parse}. *)

val stage_count : parsed_context -> int
val last_stage_bin : parsed_context -> string option

val caller_tag : caller -> string
val cannot_parse_kind_tag : cannot_parse_kind -> string
val reject_reason_tag : reject_reason -> string
val decision_tag : decision -> string

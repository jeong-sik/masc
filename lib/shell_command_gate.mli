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
  -> allowed_commands:string list
  -> string
  -> decision
(** Parse once, then enforce an exact binary-name allowlist over every
    stage.  [?allow_pipes] defaults to [true].  [?caller] is captured
    for the upcoming telemetry partition (RFC-0131 PR-3) and does not
    affect the verdict. *)

val stage_count : parsed_context -> int
val last_stage_bin : parsed_context -> string option

val caller_tag : caller -> string
val cannot_parse_kind_tag : cannot_parse_kind -> string
val reject_reason_tag : reject_reason -> string
val decision_tag : decision -> string

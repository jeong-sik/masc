(** Parse-once facade for shell command validation.

    This module is the narrow bridge between raw shell strings and the
    Shell_ir authority path. It preserves pipelines as first-class stage
    lists so callers do not need local quote-aware pipe splitters. *)

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

val parse : string -> (parsed_context, cannot_parse_kind) result
(** Parse a raw command into a reusable Shell_ir context. *)

val validate_allowlist
  :  ?allow_pipes:bool
  -> allowed_commands:string list
  -> string
  -> decision
(** Parse once, then enforce an exact binary-name allowlist over every
    stage. [allow_pipes] defaults to [true]. *)

val stage_count : parsed_context -> int
val last_stage_bin : parsed_context -> string option

val cannot_parse_kind_tag : cannot_parse_kind -> string
val reject_reason_tag : reject_reason -> string
val decision_tag : decision -> string

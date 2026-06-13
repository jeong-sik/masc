(** Shell_ir_oracle — parser-oracle fact subset for Shell IR hardening.

    This module is intentionally data-only.  A non-production sidecar can
    emit this JSON shape from a real shell parser, while OCaml owns policy,
    descriptor parity, risk floors, and receipts. *)

type parse_status =
  | Parsed_ok
  | Parse_error
  | Incomplete
  | Timeout
  | Unavailable

val parse_status_of_string : string -> (parse_status, string) result
val string_of_parse_status : parse_status -> string

type features = {
  pipeline : bool;
  redirect : bool;
  heredoc : bool;
  subshell : bool;
  command_substitution : bool;
  variable : bool;
  glob : bool;
  env_assignment : bool;
  process_substitution : bool;
  unknown_enabled : string list;
}

type command = {
  name : string;
  argv : string list;
}

type t = {
  schema_version : int;
  parser : string option;
  command : string;
  parse_status : parse_status;
  features : features;
  commands : command list;
  error : string option;
}

val of_yojson : Yojson.Safe.t -> (t, string) result
val of_string : string -> (t, string) result
val feature_names : t -> string list

val descriptor_parity_blockers : t -> string list
(** Features that a read-only descriptor must not silently ignore.
    Non-[Parsed_ok] parser status is also a blocker. *)

val read_only_descriptor_compatible : t -> (unit, string) result
val syntax_floor : t -> Shell_ir_risk.risk_class
(** Conservative oracle-derived syntax floor.  This is not final policy:
    it exists so differential tests can prove parser facts never lower
    the existing Shell IR decision. *)

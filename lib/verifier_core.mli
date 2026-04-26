(** Verifier_core — Pure verification types, parsing, and read-only
    detection.

    No [Agent_sdk] or OAS dependency. Extracted from [verifier_oas.ml]
    to enforce the MASC-OAS boundary: core domain logic stays
    OAS-free.

    @since 2.61.0 (verifier core)
    @since 2.223.0 (structured verdict via [report_verdict] tool)
    @since 2.233.0 (extracted from [verifier_oas.ml]) *)

(** {1 Types} *)

type verification_request =
  { action_description : string
  ; action_result : string
  ; goal : string
  ; context_summary : string
  }

type verdict =
  | Pass
  | Warn of string
  | Fail of string

(** {1 Read-Only Detection} *)

(** [should_skip ~action_description] returns [true] when the
    description text contains a word-boundary match for any
    read-only keyword ([read], [glob], [grep], [search], [find],
    [list], [ls], [cat], [head], [tail], [git status], [git log],
    [git diff], [status], [view], [get], [fetch], [query]).
    Case-insensitive, word-boundary aware. *)
val should_skip : action_description:string -> bool

(** {1 Verdict Parsing} *)

(** ["PASS"] / ["WARN: <reason>"] / ["FAIL: <reason>"]. *)
val verdict_to_string : verdict -> string

(** Issue #8436: payload-free constructor names for schema enums:
    ["PASS"] / ["WARN"] / ["FAIL"]. Adding a 4th variant fails
    compilation here — the regression test [test_types.ml] asserts
    every variant appears in {!valid_verdict_strings}. *)
val verdict_constructor_name : verdict -> string

val valid_verdict_strings : string list

(** Parse a free-form verifier text line. Accepts [PASS | WARN | FAIL]
    followed optionally by [:] or [-] and a reason. Returns [Error]
    on empty input or unrecognised prefix; reason-less [Warn] /
    [Fail] fill in a default reason. *)
val parse_verdict : string -> (verdict, string) result

(** {1 Structured Verdict — report_verdict tool} *)

(** MCP tool schema for [report_verdict]: [verdict] (enum of
    {!valid_verdict_strings}) + optional [reason]. *)
val report_verdict_schema : Types.tool_schema

(** Parse a [report_verdict] JSON arg payload. Empty/missing [reason]
    on [Warn]/[Fail] fills in a default reason (same as
    {!parse_verdict}). Errors on type mismatch or unknown [verdict]
    values. *)
val parse_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

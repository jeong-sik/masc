(** Gate diff types — shared type definitions for shell command safety
    classification.

    Nominal variants for destructive command classification, legacy vs shadow
    gate verdicts, and their diff.  Extracted from worker_dev_tools.ml so
    that lightweight consumers (counters, telemetry) can reference the types
    without pulling in the full command-validation tool surface.

    Classification functions that depend on worker_dev_tools internals
    (validate_command, shadow_parse_outcome) remain in worker_dev_tools.ml
    and use these types via [Gate_diff_types.t].

    @since godsplit-safety — variant unification & godfile decomposition *)

(* ================================================================ *)
(* Destructive command classes                                       *)
(* ================================================================ *)

type destructive_class =
  | Recursive_delete        (* rm -rf / rm -r / rmdir *)
  | Sql_destructive         (* drop table, drop database, truncate, delete from *)
  | Forced_git_mutation     (* git push --force, git reset --hard, git clean -f *)
  | Privilege_escalation    (* chmod 777 *)
  | Filesystem_format       (* mkfs *)
  | Device_write            (* > /dev/, dd if= *)
  | Process_signal          (* kill -9, pkill *)
  | System_control          (* shutdown, reboot *)

let destructive_class_to_string = function
  | Recursive_delete -> "recursive_delete"
  | Sql_destructive -> "sql_destructive"
  | Forced_git_mutation -> "forced_git_mutation"
  | Privilege_escalation -> "privilege_escalation"
  | Filesystem_format -> "filesystem_format"
  | Device_write -> "device_write"
  | Process_signal -> "process_signal"
  | System_control -> "system_control"

type destructive_pattern = {
  class_ : destructive_class;
  pattern : string;
  description : string;
}

(* SSOT for destructive shell patterns. [Eval_gate.destructive_patterns]
   and [classify_destructive] both derive from this list — drift
   between the legacy gate and the shadow classifier is impossible by
   construction.

   Order matters: longer substrings come first so "rm -rf" matches
   before "rm -r" (both classify as Recursive_delete but the returned
   substring differs). *)
let destructive_patterns : destructive_pattern list = [
  { class_ = Recursive_delete;     pattern = "rm -rf";           description = "recursive forced deletion" };
  { class_ = Recursive_delete;     pattern = "rm -r";            description = "recursive deletion" };
  { class_ = Recursive_delete;     pattern = "rmdir";            description = "directory removal" };
  { class_ = Sql_destructive;      pattern = "drop table";       description = "SQL table drop" };
  { class_ = Sql_destructive;      pattern = "drop database";    description = "SQL database drop" };
  { class_ = Sql_destructive;      pattern = "truncate table";   description = "SQL table truncate" };
  { class_ = Sql_destructive;      pattern = "delete from";      description = "SQL bulk delete" };
  { class_ = Forced_git_mutation;  pattern = "git push --force"; description = "force push" };
  { class_ = Forced_git_mutation;  pattern = "git push -f";      description = "force push" };
  { class_ = Forced_git_mutation;  pattern = "git reset --hard"; description = "hard reset" };
  { class_ = Forced_git_mutation;  pattern = "git clean -f";     description = "forced clean" };
  { class_ = Privilege_escalation; pattern = "chmod 777";        description = "world-writable permissions" };
  { class_ = Filesystem_format;    pattern = "mkfs";             description = "filesystem format" };
  { class_ = Device_write;         pattern = "> /dev/";          description = "device write" };
  { class_ = Device_write;         pattern = "dd if=";           description = "raw disk operation" };
  { class_ = Process_signal;       pattern = "kill -9";          description = "forced process kill" };
  { class_ = Process_signal;       pattern = "pkill";            description = "pattern-based process kill" };
  { class_ = System_control;       pattern = "shutdown";         description = "system shutdown" };
  { class_ = System_control;       pattern = "reboot";           description = "system reboot" };
]

(* Delegates to [String_util.contains_substring_ci] (SSOT). Preserves
   the historical [sub = ""] -> true convention used by the original
   inline walker; the SSOT returns [false] for empty needle so we
   guard here. [destructive_patterns] never carries an empty
   pattern, but the guard keeps the invariant explicit. *)
let contains_sub_ci s sub =
  if sub = "" then true
  else String_util.contains_substring_ci s sub

(* Returns the matching class (first hit in declaration order) plus
   the literal substring that triggered.  [None] means "no known
   destructive pattern found". *)
let classify_destructive cmd : (destructive_class * string) option =
  List.find_map (fun { class_; pattern; description = _ } ->
    if contains_sub_ci cmd pattern then Some (class_, pattern) else None)
    destructive_patterns

(* ================================================================ *)
(* Legacy and shadow verdicts                                        *)
(* ================================================================ *)

type legacy_verdict =
  | Legacy_allow
  | Legacy_reject_by_allowlist
  | Legacy_reject_destructive of string
      (** The matching substring from [Eval_gate.destructive_patterns],
          NOT the description. *)

(* Closed sum mirroring [Masc_exec.Parsed.t] sans the [Parsed _] AST
   payload. Used as the typed dispatch value in [Legendary_counters]
   so the per-reason histogram is exhaustive over the parser's full
   variant surface. *)
type parse_outcome_kind =
  | Parsed_simple
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted
  | Too_complex of Masc_exec.Parsed.reason_too_complex

let reason_too_complex_to_tag (r : Masc_exec.Parsed.reason_too_complex) =
  match r with
  | `Heredoc -> "heredoc"
  | `Here_string -> "here_string"
  | `Cmd_subst -> "cmd_subst"
  | `Proc_subst -> "proc_subst"
  | `Subshell -> "subshell"
  | `Arith_expansion -> "arith_expansion"
  | `Control_flow -> "control_flow"
  | `Logic_op -> "logic_op"
  | `Function_def -> "function_def"
  | `Glob_brace -> "glob_brace"
  | `Background -> "background"
  | `Redirect -> "redirect"
  | `Unknown_construct s -> "unknown:" ^ s

let reason_aborted_to_tag (r : Masc_exec.Parsed.reason_aborted) =
  match r with
  | `Timeout_50ms -> "timeout_50ms"
  | `Depth_limit -> "depth_limit"
  | `Token_limit_50k -> "token_limit_50k"

let parse_outcome_kind_to_tag = function
  | Parsed_simple -> "parsed_simple"
  | Parse_error -> "parse_error"
  | Parse_aborted r -> "parse_aborted:" ^ reason_aborted_to_tag r
  | Too_complex r -> "too_complex:" ^ reason_too_complex_to_tag r

type shadow_verdict =
  | Shadow_allow
  | Shadow_parse_unsupported of { kind : parse_outcome_kind }
  | Shadow_deny_destructive of destructive_class * string

(* ================================================================ *)
(* Gate diff — comparison of legacy vs shadow verdicts               *)
(* ================================================================ *)

type gate_diff =
  | Agree
  | Legacy_allow_shadow_deny
  | Legacy_deny_shadow_allow
  | Shadow_cannot_parse

let gate_diff_to_string = function
  | Agree -> "agree"
  | Legacy_allow_shadow_deny -> "legacy_allow_shadow_deny"
  | Legacy_deny_shadow_allow -> "legacy_deny_shadow_allow"
  | Shadow_cannot_parse -> "shadow_cannot_parse"

let diff_of_verdicts ~legacy ~shadow : gate_diff =
  match legacy, shadow with
  | _, Shadow_parse_unsupported _ -> Shadow_cannot_parse
  | Legacy_allow, Shadow_allow -> Agree
  | Legacy_reject_by_allowlist, _ -> Agree
  | Legacy_reject_destructive _, Shadow_deny_destructive _ -> Agree
  | Legacy_allow, Shadow_deny_destructive _ -> Legacy_allow_shadow_deny
  | Legacy_reject_destructive _, Shadow_allow -> Legacy_deny_shadow_allow

let legacy_verdict_to_tag = function
  | Legacy_allow -> "legacy_allow"
  | Legacy_reject_by_allowlist -> "legacy_reject_by_allowlist"
  | Legacy_reject_destructive _ -> "legacy_reject_destructive"

let shadow_verdict_to_tag = function
  | Shadow_allow -> "shadow_allow"
  | Shadow_parse_unsupported _ -> "shadow_parse_unsupported"
  | Shadow_deny_destructive _ -> "shadow_deny_destructive"

(* Deterministic 12-hex-char digest of the command for log de-duplication. *)
let cmd_hash_for_log (cmd : string) : string =
  let hex = Digest.to_hex (Digest.string cmd) in
  if String.length hex >= 12 then String.sub hex 0 12 else hex

let shadow_diff_log_enabled () =
  match Sys.getenv_opt "MASC_BASH_AST_SHADOW_LOG" with
  | Some ("1" | "true" | "TRUE" | "yes" | "on" | "log") -> true
  | _ -> false

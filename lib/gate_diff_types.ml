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
  | Recursive_delete (* rm -rf / rm -r / rmdir *)
  | Sql_destructive (* drop table, drop database, truncate, delete from *)
  | Forced_git_mutation (* git push --force, git reset --hard, git clean -f *)
  | Privilege_escalation (* chmod 777 *)
  | Filesystem_format (* mkfs *)
  | Device_write (* > /dev/, dd if= *)
  | Process_signal (* kill -9, pkill *)
  | System_control (* shutdown, reboot *)

let destructive_class_to_string = function
  | Recursive_delete -> "recursive_delete"
  | Sql_destructive -> "sql_destructive"
  | Forced_git_mutation -> "forced_git_mutation"
  | Privilege_escalation -> "privilege_escalation"
  | Filesystem_format -> "filesystem_format"
  | Device_write -> "device_write"
  | Process_signal -> "process_signal"
  | System_control -> "system_control"
;;

(* Substring → class mapping.  Each entry mirrors one row in
   [Eval_gate.destructive_patterns].  Order matters: longer
   substrings come first so "rm -rf" matches before "rm -r". *)
let destructive_class_substrings : (string * destructive_class) list =
  [ "rm -rf", Recursive_delete
  ; "rm -r", Recursive_delete
  ; "rmdir", Recursive_delete
  ; "drop table", Sql_destructive
  ; "drop database", Sql_destructive
  ; "truncate table", Sql_destructive
  ; "delete from", Sql_destructive
  ; "git push --force", Forced_git_mutation
  ; "git push -f", Forced_git_mutation
  ; "git reset --hard", Forced_git_mutation
  ; "git clean -f", Forced_git_mutation
  ; "chmod 777", Privilege_escalation
  ; "mkfs", Filesystem_format
  ; "> /dev/", Device_write
  ; "dd if=", Device_write
  ; "kill -9", Process_signal
  ; "pkill", Process_signal
  ; "shutdown", System_control
  ; "reboot", System_control
  ]
;;

(* Delegates to [String_util.contains_substring_ci] (SSOT). Preserves
   the historical [sub = ""] -> true convention used by the original
   inline walker; the SSOT returns [false] for empty needle so we
   guard here. [destructive_class_substrings] never carries an empty
   pattern, but the guard keeps the invariant explicit. *)
let contains_sub_ci s sub =
  if sub = "" then true else String_util.contains_substring_ci s sub
;;

(* Returns the matching class (first hit in declaration order) plus
   the literal substring that triggered.  [None] means "no known
   destructive pattern found". *)
let classify_destructive cmd : (destructive_class * string) option =
  List.find_map
    (fun (sub, cls) -> if contains_sub_ci cmd sub then Some (cls, sub) else None)
    destructive_class_substrings
;;

(* ================================================================ *)
(* Legacy and shadow verdicts                                        *)
(* ================================================================ *)

type legacy_verdict =
  | Legacy_allow
  | Legacy_reject_by_allowlist
  | Legacy_reject_destructive of string
  (** The matching substring from [Eval_gate.destructive_patterns],
          NOT the description. *)

type shadow_verdict =
  | Shadow_allow of { parse_tag : string }
  | Shadow_parse_unsupported of { parse_tag : string }
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
;;

let diff_of_verdicts ~legacy ~shadow : gate_diff =
  match legacy, shadow with
  | _, Shadow_parse_unsupported _ -> Shadow_cannot_parse
  | Legacy_allow, Shadow_allow _ -> Agree
  | Legacy_reject_by_allowlist, _ -> Agree
  | Legacy_reject_destructive _, Shadow_deny_destructive _ -> Agree
  | Legacy_allow, Shadow_deny_destructive _ -> Legacy_allow_shadow_deny
  | Legacy_reject_destructive _, Shadow_allow _ -> Legacy_deny_shadow_allow
;;

let legacy_verdict_to_tag = function
  | Legacy_allow -> "legacy_allow"
  | Legacy_reject_by_allowlist -> "legacy_reject_by_allowlist"
  | Legacy_reject_destructive _ -> "legacy_reject_destructive"
;;

let shadow_verdict_to_tag = function
  | Shadow_allow _ -> "shadow_allow"
  | Shadow_parse_unsupported _ -> "shadow_parse_unsupported"
  | Shadow_deny_destructive _ -> "shadow_deny_destructive"
;;

(* Deterministic 12-hex-char digest of the command for log de-duplication. *)
let cmd_hash_for_log (cmd : string) : string =
  let hex = Digest.to_hex (Digest.string cmd) in
  if String.length hex >= 12 then String.sub hex 0 12 else hex
;;

let shadow_diff_log_enabled () =
  match Sys.getenv_opt "MASC_BASH_AST_SHADOW_LOG" with
  | Some ("1" | "true" | "TRUE" | "yes" | "on" | "log") -> true
  | _ -> false
;;

(** Shell safety helper types shared by worker tool validation and keeper
    logging.

    This module owns only the destructive-command taxonomy and the dynamic
    typed-shell feature predicates that are still live. The old legacy-vs-AST
    shadow diff observer was removed once it stopped being an authority path.

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
   and [classify_destructive] both derive from this list, so destructive
   substring/tag drift is impossible by construction.

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

(* Deterministic 12-hex-char digest of the command for log de-duplication. *)
let cmd_hash_for_log (cmd : string) : string =
  let hex = Digest.to_hex (Digest.string cmd) in
  if String.length hex >= 12 then String.sub hex 0 12 else hex

(* RFC-0092 Phase A advisor — typed parallel-validation log gate.
   Default off; operator opt-in for the parity-measurement window
   before the authority flip in Phase C. *)
let typed_advisor_log_enabled () =
  match Sys.getenv_opt "MASC_BASH_TYPED_ADVISOR" with
  | Some ("1" | "true" | "TRUE" | "yes" | "on" | "log") -> true
  | _ -> false

(* RFC-0092 Phase C authority — predicate-only stage of PR-4.

   Default off; no behavior change while unset.  Read each call (not
   lazy) so operators can flip the env var mid-process for ops drills
   and rollback without restarting the keeper fleet — same property
   the advisor predicate has.  The narrower truthy set (no "log"
   alias) is intentional: "log" only makes sense for measurement, not
   decisions. *)
let typed_authority_enabled () =
  match Sys.getenv_opt "MASC_BASH_TYPED_AUTHORITY" with
  | Some ("1" | "true" | "TRUE" | "yes" | "on") -> true
  | _ -> false

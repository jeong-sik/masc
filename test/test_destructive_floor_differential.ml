(** Differential-safety harness — legacy substring destructive classifier vs.
    the typed Shell IR keeper gate as it actually runs for an AUTONOMOUS keeper.

    Phase 1 of the substring-classifier retirement (see
    docs/rfc/RFC-eliminate-substring-destructive-classifier.md). The
    naive plan "delete [Eval_gate.detect_destructive], the typed path covers
    it" is only safe if the typed keeper gate blocks every command the
    substring catalogue blocks. This harness MEASURES that — it does not
    delete anything.

    Two verdicts per command:

    - substring: [Eval_gate.detect_destructive Destructive_ops_policy.default]
      over the command STRING — the legacy catalogue in
      config/destructive_ops.toml.

    - typed-autonomous: the two UNCONDITIONAL blocks an autonomous keeper
      applies to the parsed IR (RFC-0254 §5.2/§5.5: the keeper lane runs the
      [autonomous] overlay, so every non-catastrophic risk class is
      [Observe] => Allow; only these two deny):
        1. [Shell_ir_risk.is_destructive] (risk = [Destructive_protected]) —
           the hard block at keeper_tool_execute_runtime.ml:513;
        2. [Approval_policy.catastrophic_floor] (destructive-git / write-escape
           / catastrophic program) — the trust- and flag-independent floor in
           dispatch_classified (keeper_tool_execute_shell_ir.ml).

    Safety invariant for retirement:
      forall cmd. substring_blocks cmd  =>  typed_blocks cmd
    Every command the substring layer blocks must ALSO be blocked by the
    typed keeper path; a violation means deleting the substring layer lowers
    the autonomous-keeper safety floor (a regression).

    The invariant does NOT hold today — the gap is the Phase-2 work-list. To
    keep CI green while making the gap visible and preventing silent growth,
    [test_gap_baseline] pins the current gap set as a ratchet: it fails if a
    new uncovered pattern appears (regression) or if a gap closes without the
    baseline being updated (progress to record). Retirement (Phase 3) is
    gated on this baseline reaching empty. *)

open Masc
module Exec = Masc_exec
module IR = Exec.Shell_ir
module Risk = Exec.Shell_ir_risk

let policy = Destructive_ops_policy.default

(* IR construction mirrors lib/exec/test/test_shell_ir_differential.ml so the
   typed verdict is computed on the same Simple-IR shape the keeper classifies. *)
let bin s = Result.get_ok (Exec.Exec_program.of_string s)

let simple_ir bin_str args =
  IR.Simple
    { IR.bin = bin bin_str
    ; args = List.map (fun a -> IR.Lit (a, IR.default_meta)) args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Exec.Sandbox_target.host ()
    }
;;

(* An entry binds the substring view (the command string) to the typed view
   (the IR) from a single (bin, args) pair, so both verdicts see identical
   tokens — no drift between what the catalogue matches and what the typed
   classifier parses. *)
type entry =
  { cls : string
  ; bin_ : string
  ; args : string list
  }

let entry cls bin_ args = { cls; bin_; args }
let cmd_string e = String.concat " " (e.bin_ :: e.args)
let ir_of e = simple_ir e.bin_ e.args
let label e = Printf.sprintf "[%s] %s" e.cls (cmd_string e)
let substring_blocks e = Option.is_some (Eval_gate.detect_destructive policy (cmd_string e))

let classify e = Risk.classify (Risk.undecided (ir_of e))

let typed_blocks e =
  Risk.is_destructive (classify e)
  || Option.is_some
       (Exec.Approval_policy.catastrophic_floor (Exec.Capability_check.of_ir (ir_of e)))
;;

(* One representative command per pattern in config/destructive_ops.toml.
   Exhaustive over the catalogue's classes so the gap report covers every
   substring pattern. The redirect-shaped device_write pattern "> /dev/" is
   NOT represented here: building it needs a Redirect_scope value, and as a
   redirect write it is covered by [catastrophic_floor]'s find_write_escape
   on a separate path. [dd if=] represents the device_write class instead.
   This single omission is logged in the report (no silent cap). *)
let destructive_corpus =
  [ entry "recursive_delete" "rm" [ "-rf"; "/tmp/x" ]
  ; entry "recursive_delete" "rm" [ "-r"; "/tmp/x" ]
  ; entry "recursive_delete" "rmdir" [ "/tmp/x" ]
  ; entry "sql_destructive" "psql" [ "-c"; "drop table users" ]
  ; entry "sql_destructive" "psql" [ "-c"; "drop database prod" ]
  ; entry "sql_destructive" "psql" [ "-c"; "truncate table users" ]
  ; entry "sql_destructive" "psql" [ "-c"; "delete from users" ]
  ; entry "forced_git_mutation" "git" [ "push"; "--force"; "origin"; "main" ]
  ; entry "forced_git_mutation" "git" [ "push"; "-f"; "origin"; "main" ]
  ; entry "forced_git_mutation" "git" [ "reset"; "--hard"; "HEAD~1" ]
  ; entry "forced_git_mutation" "git" [ "clean"; "-f"; "-d" ]
  ; entry "privilege_escalation" "chmod" [ "777"; "/etc/passwd" ]
  ; entry "filesystem_format" "mkfs" [ "/dev/sda1" ]
  ; entry "device_write" "dd" [ "if=/dev/zero"; "of=/dev/sda" ]
  ; entry "process_signal" "kill" [ "-9"; "1234" ]
  ; entry "process_signal" "pkill" [ "-f"; "node" ]
  ; entry "system_control" "shutdown" [ "-h"; "now" ]
  ; entry "system_control" "reboot" []
  ]
;;

let safe_corpus =
  [ entry "read" "ls" [ "-la" ]
  ; entry "read" "cat" [ "file.txt" ]
  ; entry "read" "git" [ "status" ]
  ]
;;

(* The gap: commands the substring catalogue blocks but the autonomous keeper
   typed path allows. Deleting the substring layer would stop blocking these. *)
let gap () = List.filter (fun e -> substring_blocks e && not (typed_blocks e)) destructive_corpus

(* Baseline ratchet. Set to the gap observed on first run; shrink as Phase 2
   extends the typed floor. Retirement (Phase 3) requires this to be empty.
   Format: "[class] cmd string" (the [label]). *)
let expected_gap_baseline =
  (* Measured 2026-06-24 on origin/main (dfd344783c). 12 of 18 catalogue
     patterns are blocked by the substring layer but ALLOWED by the
     autonomous-keeper typed path. Each is a Phase-2 typed-floor work item.
     Already covered by typed (NOT in the gap): rm -rf, git push --force,
     git push -f, git reset --hard, git clean -f, mkfs. *)
  [ "[device_write] dd if=/dev/zero of=/dev/sda"
  ; "[privilege_escalation] chmod 777 /etc/passwd"
  ; "[process_signal] kill -9 1234"
  ; "[process_signal] pkill -f node"
  ; "[recursive_delete] rm -r /tmp/x"
  ; "[recursive_delete] rmdir /tmp/x"
  ; "[sql_destructive] psql -c delete from users"
  ; "[sql_destructive] psql -c drop database prod"
  ; "[sql_destructive] psql -c drop table users"
  ; "[sql_destructive] psql -c truncate table users"
  ; "[system_control] reboot"
  ; "[system_control] shutdown -h now"
  ]
;;

let test_safe_controls_not_blocked () =
  List.iter
    (fun e ->
       Alcotest.(check bool)
         (Printf.sprintf "%s: substring does not flag a safe read" (label e))
         false
         (substring_blocks e))
    safe_corpus
;;

let test_report () =
  let n = List.length destructive_corpus in
  let covered = List.filter typed_blocks destructive_corpus in
  let g = gap () in
  Printf.printf "\n=== substring -> typed-autonomous differential ===\n";
  Printf.printf "destructive corpus: %d patterns\n" n;
  Printf.printf "typed-autonomous also blocks: %d/%d\n" (List.length covered) n;
  Printf.printf "GAP (substring blocks, autonomous keeper ALLOWS): %d\n" (List.length g);
  List.iter
    (fun e ->
       Printf.printf
         "  - %s  (risk=%s)\n"
         (label e)
         (Risk.string_of_risk_class (Risk.risk_class (classify e))))
    g;
  Printf.printf
    "NOTE: device_write pattern \"> /dev/\" (redirect form) not in corpus; \
     covered separately by catastrophic_floor write-escape. dd represents the class.\n";
  Alcotest.(check bool) "harness ran over a non-empty corpus" true (n > 0)
;;

(* Ratchet: the gap must equal the recorded baseline. Fails on growth
   (new uncovered pattern = regression) or unrecorded shrink (Phase-2
   progress to capture). *)
let test_gap_baseline () =
  let actual = List.sort compare (List.map label (gap ())) in
  let expected = List.sort compare expected_gap_baseline in
  Alcotest.(check (list string)) "gap matches baseline ratchet" expected actual
;;

let () =
  Alcotest.run
    "destructive_floor_differential"
    [ ( "differential"
      , [ Alcotest.test_case "safe controls not blocked" `Quick test_safe_controls_not_blocked
        ; Alcotest.test_case "report" `Quick test_report
        ; Alcotest.test_case "gap baseline ratchet" `Quick test_gap_baseline
        ] )
    ]
;;

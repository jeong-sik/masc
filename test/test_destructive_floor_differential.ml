(** Differential-safety harness — legacy substring destructive classifier vs.
    the typed Shell IR COMMAND-SHAPE risk classifiers, as they decide for an
    AUTONOMOUS keeper.

    Phase 1 of the substring-classifier retirement (see
    docs/rfc/RFC-eliminate-substring-destructive-classifier.md).

    {1 What this harness measures — and what it deliberately excludes}

    An autonomous keeper has THREE unconditional block gates on an executed
    command:

      1. [Shell_ir_risk.is_destructive] (risk = [Destructive_protected]) —
         keeper_tool_execute_runtime.ml:513;
      2. [Approval_policy.catastrophic_floor] (destructive-git / redirect
         write-escape / catastrophic-by-identity program, e.g. mkfs) —
         approval_policy.ml:107; and
      3. the path jail [Exec_policy.validate_shell_ir_paths]
         (keeper_tool_execute_shell_ir.ml:82) — jails command ARGUMENT paths
         to the workspace whitelist.

    This harness models (1) and (2): the COMMAND-SHAPE classifiers (command
    identity / git op / redirect). It deliberately EXCLUDES the path jail (3),
    for two reasons:

      - The path jail is env-gated ([Shell_ir_path_jail.enabled]) and is an
        explicit "short-lived valve, not a steady state" with removal target
        RFC-0255 P5. A retirement that depends on it would rest on a defense
        scheduled for removal.
      - It only constrains the TARGET PATH, so it never covers path-
        independent destructive commands (kill, pkill, shutdown, reboot, or
        SQL passed as a psql/-c string), and it does not block in-workspace
        destructive targets (e.g. `rm -r ./src`).

    So the gap measured here is "destructiveness the command-shape classifiers
    do not capture" — the set that must be lifted into typed risk arms before
    the substring layer can be deleted WITHOUT depending on the temporary path
    jail. The gap is split into:

      - path-INDEPENDENT (irreducible): no path argument, so no path defense
        can ever cover them — the hard core of the work-list;
      - path-BEARING: targeted at an IN-WORKSPACE path here (the worst case the
        path jail cannot help); out-of-workspace variants are additionally
        covered TODAY by the path jail, but that coverage is temporary.

    Safety invariant for retirement: forall cmd. substring_blocks cmd =>
    command-shape typed_blocks cmd. It does NOT hold yet; the gap is the
    Phase-2 work-list, pinned by [test_gap_baseline] as a ratchet so it cannot
    grow silently. Retirement (Phase 3) is gated on the baseline reaching
    empty. *)

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
   (the IR) from one (bin, args) pair, so both verdicts see identical tokens.
   [path_independent] marks commands with no path argument: no path-based
   defense (write-escape or the path jail) can ever cover them, so they are the
   irreducible core of the gap. *)
type entry =
  { cls : string
  ; bin_ : string
  ; args : string list
  ; path_independent : bool
  }

let mk ?(path_independent = false) cls bin_ args = { cls; bin_; args; path_independent }
let cmd_string e = String.concat " " (e.bin_ :: e.args)
let ir_of e = simple_ir e.bin_ e.args
let label e = Printf.sprintf "[%s] %s" e.cls (cmd_string e)
let substring_blocks e = Option.is_some (Eval_gate.detect_destructive policy (cmd_string e))
let classify e = Risk.classify (Risk.undecided (ir_of e))

(* Command-shape typed verdict: the two UNCONDITIONAL command-shape blocks an
   autonomous keeper applies (path jail excluded by design — see header). Under
   the autonomous overlay every non-catastrophic risk class is Observe => Allow,
   so these two are the whole command-shape block set. *)
let typed_blocks e =
  Risk.is_destructive (classify e)
  || Option.is_some
       (Exec.Approval_policy.catastrophic_floor (Exec.Capability_check.of_ir (ir_of e)))
;;

(* One representative command per pattern in config/destructive_ops.toml.
   Path-bearing patterns target an IN-WORKSPACE relative path (./…): that is the
   worst case the path jail cannot help, so a gap here is a genuine command-shape
   gap, not an artifact of omitting the path jail. The redirect-shaped
   device_write pattern "> /dev/" is not represented (it needs a Redirect_scope
   value and is covered by catastrophic_floor write-escape on a separate path);
   [dd] represents the device_write class. Logged in the report (no silent cap). *)
let destructive_corpus =
  [ mk "recursive_delete" "rm" [ "-rf"; "./build" ]
  ; mk "recursive_delete" "rm" [ "-r"; "./build" ]
  ; mk "recursive_delete" "rmdir" [ "./build" ]
  ; mk "sql_destructive" "psql" [ "-c"; "drop table users" ] ~path_independent:true
  ; mk "sql_destructive" "psql" [ "-c"; "drop database prod" ] ~path_independent:true
  ; mk "sql_destructive" "psql" [ "-c"; "truncate table users" ] ~path_independent:true
  ; mk "sql_destructive" "psql" [ "-c"; "delete from users" ] ~path_independent:true
  ; mk "forced_git_mutation" "git" [ "push"; "--force"; "origin"; "main" ] ~path_independent:true
  ; mk "forced_git_mutation" "git" [ "push"; "-f"; "origin"; "main" ] ~path_independent:true
  ; mk "forced_git_mutation" "git" [ "reset"; "--hard"; "HEAD~1" ] ~path_independent:true
  ; mk "forced_git_mutation" "git" [ "clean"; "-f"; "-d" ] ~path_independent:true
  ; mk "privilege_escalation" "chmod" [ "777"; "./script.sh" ]
  ; mk "filesystem_format" "mkfs" [ "/dev/sda1" ]
  ; mk "device_write" "dd" [ "if=/dev/zero"; "of=./out.img" ]
  ; mk "process_signal" "kill" [ "-9"; "1234" ] ~path_independent:true
  ; mk "process_signal" "pkill" [ "-f"; "node" ] ~path_independent:true
  ; mk "system_control" "shutdown" [ "-h"; "now" ] ~path_independent:true
  ; mk "system_control" "reboot" [] ~path_independent:true
  ]
;;

let safe_corpus =
  [ mk "read" "ls" [ "-la" ]
  ; mk "read" "cat" [ "file.txt" ]
  ; mk "read" "git" [ "status" ]
  ]
;;

(* The gap: commands the substring catalogue blocks but the command-shape typed
   classifiers allow. *)
let gap () = List.filter (fun e -> substring_blocks e && not (typed_blocks e)) destructive_corpus

(* Baseline ratchet. Measured 2026-06-24 on origin/main. Shrinks as Phase 2
   lifts each class into a typed risk arm; retirement (Phase 3) requires it
   empty. Format: the [label] "[class] cmd string". Already covered by the
   command-shape classifiers (NOT in the gap): rm -rf, git push --force,
   git push -f, git reset --hard, git clean -f, mkfs. *)
let expected_gap_baseline =
  [ "[device_write] dd if=/dev/zero of=./out.img"
  ; "[privilege_escalation] chmod 777 ./script.sh"
  ; "[process_signal] kill -9 1234"
  ; "[process_signal] pkill -f node"
  ; "[recursive_delete] rm -r ./build"
  ; "[recursive_delete] rmdir ./build"
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
  let independent, bearing = List.partition (fun e -> e.path_independent) g in
  Printf.printf "\n=== substring -> command-shape typed differential ===\n";
  Printf.printf "destructive corpus: %d patterns\n" n;
  Printf.printf "command-shape typed also blocks: %d/%d\n" (List.length covered) n;
  Printf.printf "GAP (substring blocks, command-shape typed ALLOWS): %d\n" (List.length g);
  let print_group title entries =
    Printf.printf "%s: %d\n" title (List.length entries);
    List.iter
      (fun e ->
         Printf.printf
           "  - %s  (risk=%s)\n"
           (label e)
           (Risk.string_of_risk_class (Risk.risk_class (classify e))))
      entries
  in
  print_group "  path-INDEPENDENT (irreducible — no path defense possible)" independent;
  print_group "  path-BEARING (in-workspace worst case; out-of-workspace also path-jailed, temporary)" bearing;
  Printf.printf
    "NOTE: path jail (validate_shell_ir_paths, RFC-0255 P5 removal) excluded by \
     design; device_write \"> /dev/\" redirect form not in corpus (dd represents the class).\n";
  Alcotest.(check bool) "harness ran over a non-empty corpus" true (n > 0)
;;

(* Ratchet: the gap must equal the recorded baseline. Fails on growth (new
   uncovered pattern = regression) or unrecorded shrink (Phase-2 progress to
   capture). *)
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

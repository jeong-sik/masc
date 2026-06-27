(** Differential-safety harness — legacy substring destructive classifier vs.
    the typed Shell IR COMMAND-SHAPE risk classifiers, as they decide for an
    AUTONOMOUS keeper.

    Phase 1 of the substring-classifier retirement (see
    docs/rfc/RFC-eliminate-substring-destructive-classifier.md).

    {1 What this harness measures — and what it deliberately excludes}

    An autonomous keeper has FOUR unconditional block gates on an executed
    command:

      1. [Shell_ir_risk.is_destructive] (risk = [Destructive_protected]) —
         keeper_tool_execute_runtime.ml:513;
      2. [Approval_policy.catastrophic_floor] (destructive-git / redirect
         write-escape / catastrophic-by-identity program, e.g. mkfs) —
         approval_policy.ml:107; and
      3. privileged/unknown executable fail-closed in
         [Keeper_tool_execute_shell_ir.dispatch_classified] while no Shell IR
         approval resolver exists; and
      4. the path jail [Exec_policy.validate_shell_ir_paths]
         (keeper_tool_execute_shell_ir.ml:82) — jails command ARGUMENT paths
         to the workspace whitelist.

    This harness models (1), (2), and (3): the COMMAND-SHAPE classifiers (command
    identity / git op / redirect). It deliberately EXCLUDES the path jail (4),
    because the path jail is a SEPARATE, PERMANENT policy axis — not because it
    is temporary:

      - RFC-0255 §3 rejects removing the path jail (alternative C: "the jail is
        the only write-escape guard on Host"), and RFC-0255 P5 graduates it to
        the only path — i.e. makes it permanent. The former short-lived
        kill-switch was the temporary part; depending on the path jail is
        therefore depending on a permanent defense.
      - Command-shape (what binary / git op / redirect) and path-scope (where
        the argument points) are orthogonal axes. A command-shape differential
        that folded in the path jail would conflate the two and could never
        isolate "destructiveness the command identity alone implies".

    So the gap measured here is "destructiveness the command-shape classifiers
    do not capture". It is split by whether the permanent path jail can ever
    apply:

      - path-INDEPENDENT: the command has no path argument, so the path jail can
        NEVER constrain it (kill, pkill, shutdown, reboot, SQL passed as a
        psql/-c string). This was the genuine command-shape work-list. It is now
        resolved: shutdown/reboot lifted into the catastrophic floor (#22234);
        destructive SQL lifted into the typed DB-capability floor ([Db_op] +
        [Approval_policy.find_destructive_db], inside catastrophic_floor); and
        kill/pkill are unknown executables, therefore privileged and
        fail-closed until a Shell IR approval resolver exists. Literal
        destructive SQL on psql/mysql/mariadb/cockroach is covered by the typed
        DB floor; non-literal SQL ([Var]/[Concat]) is documented in the RFC
        because this all-literal corpus cannot express it.
      - path-BEARING: the command targets a path. The PERMANENT path jail covers
        an OUT-OF-WORKSPACE target. In-workspace privileged examples (e.g.
        [rm -r ./build], [chmod 777 ./script.sh], [dd of=./out.img]) are now
        blocked by the privileged-program floor until a Shell IR approval
        resolver exists. Non-privileged path-bearing coverage remains the path
        jail's job.

    Retirement (Phase 3) safety invariant: deleting the substring layer must not
    newly ALLOW anything dangerous. For each substring-blocked command the typed
    system must then either (a) command-shape-block it [path-independent
    catastrophic or privileged-without-resolver], (b) permanent-path-jail-block
    it [path-bearing, out-of-workspace], or (c) deliberately allow it because
    substring was over-broad. The baselines below are now empty and pin that no
    substring-blocked corpus entry escapes the typed command-shape floors. *)

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
   [path_independent] marks commands with no path argument: the permanent path
   jail can NEVER cover them, so any gap there must be closed or explicitly
   accepted by command-shape policy. *)
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

(* Command-shape typed verdict: the UNCONDITIONAL command-shape blocks an
   autonomous keeper applies before path jail: destructive risk, catastrophic
   floor, and privileged/unknown executable fail-closed while no Shell IR
   approval resolver exists. *)
let rec has_privileged_program = function
  | [] -> false
  | cap :: rest ->
    let current =
      match cap with
      | Exec.Capability.Exec_program (bin, _) ->
        Exec.Exec_program.risk_class bin = `Privileged
      | Exec.Capability.Read_path _ -> false
      | Exec.Capability.Write_path _ -> false
      | Exec.Capability.Git _ -> false
      | Exec.Capability.Env_set _ -> false
      | Exec.Capability.Pipeline_fold inner -> has_privileged_program inner
    in
    current || has_privileged_program rest
;;

let typed_blocks e =
  let caps = Exec.Capability_check.of_ir (ir_of e) in
  Risk.is_destructive (classify e)
  || Option.is_some (Exec.Approval_policy.catastrophic_floor caps)
  || has_privileged_program caps
;;

(* One representative command per pattern in config/destructive_ops.toml.
   Path-bearing patterns target an IN-WORKSPACE relative path (./…): that is the
   case where path jail alone would not help, so the privileged floor must catch
   privileged binaries and unknown executables. The redirect-shaped device_write
   pattern "> /dev/" is not represented (it needs a Redirect_scope value and is
   covered by catastrophic_floor write-escape on a separate path); [dd]
   represents the device_write class. Logged in the report (no silent cap). *)
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
    (* Cockroach is included so the DB floor proves coverage for the common
       [cockroach sql -e ...] producer shape, not just psql/mysql/mariadb. *)
  ; mk "sql_destructive" "cockroach" [ "sql"; "-e"; "drop table users" ] ~path_independent:true
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
let independent_gap () = List.filter (fun e -> e.path_independent) (gap ())
let bearing_gap () = List.filter (fun e -> not e.path_independent) (gap ())

(* Baseline ratchet 1 — the path-INDEPENDENT residual. No path argument, so the
   permanent path jail can never cover these. Two RFC §6 decisions emptied the
   command-shape WORK-LIST here, and the privileged fail-closed floor covers the
   remaining unknown/privileged executables:

   - system_control (shutdown/reboot): lifted into
     [Approval_policy.find_catastrophic_program] — now COVERED (Phase 2,
     #22234).
   - sql_destructive (DROP/TRUNCATE/DELETE on psql/mysql/mariadb/cockroach):
     lifted into the typed DB-capability floor ([Db_op] +
     [Approval_policy.find_destructive_db]) — now COVERED (this PR). It is
     therefore NOT in the gap anymore.
   - process_signal (kill/pkill): unknown binaries are privileged per
     [Exec_program.of_string], therefore they now hit the privileged fail-closed
     floor until a Shell IR approval resolver exists.

   A NEW path-independent destructive pattern appearing here is a red that
   demands a classify-or-decide — the ratchet's purpose. Already covered (NOT in
   the gap): rm -rf, git push --force/-f, git reset --hard, git clean -f,
   filesystem format, shutdown, reboot, destructive SQL on
   psql/mysql/mariadb/cockroach, and unknown privileged process-signal tools. *)
let expected_independent_gap = []

(* Baseline ratchet 2 — the path-BEARING gap. Each targets an in-workspace path.
   The PERMANENT path jail (validate_shell_ir_paths, default-on, graduated to
   the only path at RFC-0255 P5) covers the out-of-workspace variant. The
   in-workspace privileged forms shown here now hit the privileged fail-closed
   floor before path validation. Pinned so the set cannot grow. *)
let expected_bearing_gap = []

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
  let independent = independent_gap () in
  let bearing = bearing_gap () in
  Printf.printf "\n=== substring -> command-shape typed differential ===\n";
  Printf.printf "destructive corpus: %d patterns\n" n;
  Printf.printf "command-shape typed also blocks: %d/%d\n" (List.length covered) n;
  Printf.printf
    "GAP (substring blocks, command-shape typed ALLOWS): %d\n"
    (List.length independent + List.length bearing);
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
  print_group
    "  path-INDEPENDENT residual (should stay empty — see header)"
    independent;
  print_group
    "  path-BEARING residual (should stay empty; path jail remains separate)"
    bearing;
  Printf.printf
    "NOTE: path jail (validate_shell_ir_paths, default-on, graduated to the only \
     path at RFC-0255 P5) excluded as a separate permanent axis; device_write \
     \"> /dev/\" redirect form not in corpus (dd represents the class).\n";
  Alcotest.(check bool) "harness ran over a non-empty corpus" true (n > 0)
;;

(* Ratchet: each partition of the gap must equal its recorded baseline. Fails on
   growth (new uncovered pattern = regression). *)
let test_gap_baseline () =
  let actual_independent = List.sort compare (List.map label (independent_gap ())) in
  let actual_bearing = List.sort compare (List.map label (bearing_gap ())) in
  Alcotest.(check (list string))
    "path-independent gap matches work-list baseline"
    (List.sort compare expected_independent_gap)
    actual_independent;
  Alcotest.(check (list string))
    "path-bearing gap matches command-shape baseline"
    (List.sort compare expected_bearing_gap)
    actual_bearing
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

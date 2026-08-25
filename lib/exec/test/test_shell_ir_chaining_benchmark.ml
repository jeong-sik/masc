(** Shell IR Command Chaining & Semicolon Benchmark and Verification Suite. *)

open Masc_exec
open Masc_exec_bash_parser

(* NDT-OK: a benchmark measures wall clock, so reading it is the whole point
   rather than a decision taken on it. Nothing here branches on the number --
   it is printed for a person to read, and no assertion depends on it. *)
let time_it f =
  let t0 = Unix.gettimeofday () in
  let res = f () in
  (* NDT-OK: the closing read of the same measurement. *)
  let t1 = Unix.gettimeofday () in
  (res, (t1 -. t0) *. 1000.0)
;;

let test_correctness () =
  print_endline "=== [1] Correctness Verification ===";
  
  (* Case 1: Simple 2-command semicolon chain *)
  (match Bash.parse_string "echo 'first'; echo 'second'" with
   | Parsed.Parsed (Shell_ir.Sequence { head = Shell_ir.Simple s1; tail = [ (Shell_ir.Seq, Shell_ir.Simple s2) ] }) ->
     assert (Exec_program.to_string s1.bin = "echo");
     assert (Exec_program.to_string s2.bin = "echo");
     (match s1.args, s2.args with
      | [ Shell_ir.Lit ("first", _) ], [ Shell_ir.Lit ("second", _) ] -> ()
      | _ -> assert false);
     print_endline "  [OK] 2-stage semicolon AST structure"
   | _ -> assert false);

  (* Case 2: 3-command semicolon chain with dispatch *)
  (match Bash.parse_string "echo '=== store open PRs ==='; echo '=== store 825 branch? ==='; echo 'done'" with
   | Parsed.Parsed ir ->
     let result = Exec_dispatch.dispatch ir in
     assert (result.status = Unix.WEXITED 0);
     let expected = "=== store open PRs ===\n=== store 825 branch? ===\ndone\n" in
     assert (result.stdout = expected);
     print_endline "  [OK] 3-stage semicolon dispatch execution & stdout capture"
   | _ -> assert false);

  (* Case 3: Trailing semicolon *)
  (match Bash.parse_string "echo 'trailing semicolon test';" with
   | Parsed.Parsed (Shell_ir.Simple s) ->
     assert (Exec_program.to_string s.bin = "echo");
     print_endline "  [OK] Trailing semicolon support"
   | _ -> assert false);

  (* Case 4: Mixed connectors (&&, ||, ;) *)
  (match Bash.parse_string "echo 'step1' && echo 'step2'; echo 'step3'" with
   | Parsed.Parsed ir ->
     let result = Exec_dispatch.dispatch ir in
     assert (result.status = Unix.WEXITED 0);
     assert (result.stdout = "step1\nstep2\nstep3\n");
     print_endline "  [OK] Mixed connector (&& + ;) execution"
   | _ -> assert false);

  (* Case 5: Semicolon continues even on non-zero exit *)
  (match Bash.parse_string "false; echo 'continued after failure'" with
   | Parsed.Parsed ir ->
     let result = Exec_dispatch.dispatch ir in
     assert (result.status = Unix.WEXITED 0);
     assert (result.stdout = "continued after failure\n");
     print_endline "  [OK] Semicolon continues execution regardless of prior exit status"
   | _ -> assert false)
;;

let test_benchmark () =
  print_endline "\n=== [2] Performance & Latency Benchmark ===";

  (* Benchmark 1: Parsing Latency (10,000 iterations) *)
  let n_parse = 10_000 in
  let input = "echo '=== store open PRs ==='; gh pr list --repo kidsnote/web-store; echo '=== store 825 branch? ==='" in
  let (_, parse_total_ms) = time_it (fun () ->
    for _ = 1 to n_parse do
      match Bash.parse_string input with
      | Parsed.Parsed _ -> ()
      | _ -> assert false
    done
  ) in
  let parse_avg_us = (parse_total_ms *. 1000.0) /. (float_of_int n_parse) in
  Printf.printf "  - Parser Throughput: %d iterations in %.2f ms (%.3f us per parse)\n"
    n_parse parse_total_ms parse_avg_us;

  (* Benchmark 2: Real End-to-End Execution Latency *)
  let n_exec = 5 in
  let (_, exec_total_ms) = time_it (fun () ->
    for _ = 1 to n_exec do
      match Bash.parse_string "echo 'PR check start'; echo 'PR check end'" with
      | Parsed.Parsed ir ->
        let res = Exec_dispatch.dispatch ir in
        assert (res.status = Unix.WEXITED 0)
      | _ -> assert false
    done
  ) in
  let exec_avg_ms = exec_total_ms /. (float_of_int n_exec) in
  Printf.printf "  - Dispatch Latency (2-process sequence): %.2f ms total (avg %.2f ms / exec)\n"
    exec_total_ms exec_avg_ms;

  print_endline "\n[Benchmark Result] Semicolon chaining execution validated successfully."
;;

let () =
  test_correctness ();
  test_benchmark ()
;;

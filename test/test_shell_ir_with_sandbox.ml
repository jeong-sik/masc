(* with_sandbox (RFC-0422 fix): execution reads the dispatch target from
   the IR, not from a wrapper argument, so the observation stage must hand
   execution a rewritten IR. Before this existed the stage dispatched the
   keeper's effect-built IR unchanged — the "observation" was the real
   call, run with live network, and its exit became the gate's evidence
   (PR #33637, task-1375). *)

open Alcotest
module Shell_ir = Masc_exec.Shell_ir
module Target = Masc_exec.Sandbox_target

let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_
    ~env:_ ~cwd:_ =
  Target.Ran { status = Unix.WEXITED 0; stdout = ""; stderr = "" }
;;

(* A guest-shaped target with a mock runner, so a rewritten stage cannot
   accidentally compare equal to it: the replacement is the host, a
   different constructor. *)
let guest_target () =
  Target.ssh
    ~endpoint:
      { name = "with-sandbox-test"
      ; host = "with-sandbox-test.internal"
      ; user = "masc"
      ; port = 22
      ; identity_file = "/base/.masc/ssh/test.key"
      ; known_hosts_file = "/base/.masc/ssh/known_hosts.d/test"
      ; remote_root = "/srv/masc/playground/test"
      ; connect_timeout_sec = 10
      ; env_allowlist = [ "PATH" ]
      }
    ~runner:mock_runner
    ()
;;

let stage ~sandbox =
  let bin = Masc_exec.Exec_program.of_string "true" |> Result.get_ok in
  Shell_ir.Simple
    { bin
    ; args = [ Shell_ir.Lit ("x", Shell_ir.default_meta) ]
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox
    }
;;

let simple_sandboxes ir =
  let rec walk ir acc =
    match ir with
    | Shell_ir.Simple { sandbox; _ } -> sandbox :: acc
    | Shell_ir.Pipeline stages -> List.fold_left (fun acc s -> walk s acc) acc stages
    | Shell_ir.Sequence { head; tail } ->
      List.fold_left
        (fun acc (_, s) -> walk s acc)
        (walk head acc)
        tail
  in
  List.rev (walk ir [])
;;

let is_host = function Target.Host -> true | _ -> false;;

let test_every_stage_of_a_pipeline_is_rewritten () =
  let ir =
    Shell_ir.Pipeline [ stage ~sandbox:(guest_target ()); stage ~sandbox:(guest_target ()) ]
  in
  let rewritten = Shell_ir.with_sandbox Target.Host ir in
  check (list bool) "both stages now host" [ true; true ]
    (List.map is_host (simple_sandboxes rewritten))
;;

let test_sequence_head_and_tail_are_rewritten () =
  let ir =
    Shell_ir.Sequence
      { head = stage ~sandbox:(guest_target ())
      ; tail =
          [ (Shell_ir.Seq, stage ~sandbox:(guest_target ()))
          ; (Shell_ir.And_if, stage ~sandbox:(guest_target ()))
          ]
      }
  in
  let rewritten = Shell_ir.with_sandbox Target.Host ir in
  check (list bool) "head and both tail stages now host" [ true; true; true ]
    (List.map is_host (simple_sandboxes rewritten))
;;

let test_a_delegated_stage_keeps_its_own_target () =
  let delegated = Target.delegated ~caller:mock_runner () in
  let ir = stage ~sandbox:delegated in
  let rewritten = Shell_ir.with_sandbox Target.Host ir in
  (match simple_sandboxes rewritten with
  | [ sandbox ] ->
    check bool "the delegation still routes the stage" true (sandbox == delegated)
  | _ -> fail "expected exactly one stage")
;;

let () =
  run "shell ir with_sandbox"
    [ "rewrite", [ test_case "every stage of a pipeline" `Quick
                     test_every_stage_of_a_pipeline_is_rewritten
                 ; test_case "sequence head and tail" `Quick
                     test_sequence_head_and_tail_are_rewritten
                 ; test_case "a delegated stage keeps its own target" `Quick
                     test_a_delegated_stage_keeps_its_own_target ] ]
;;

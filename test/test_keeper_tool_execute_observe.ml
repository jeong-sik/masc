(* The observe stage of a tool_execute call (RFC-0422): what one boxed run
   becomes for the gate, and what the caller may read back afterwards. The
   route and the dispatch are fakes; the stage's own reading of a result is
   what is under test. *)

open Alcotest
module Stage = Masc.Keeper_tool_execute_observe
module Target = Masc.Keeper_sandbox_shell_ir_target
module Gate = Masc.Keeper_gate

let boxed () = Target.Boxed (Masc_exec.Sandbox_target.host ())

let result status =
  Ok { Masc_exec.Exec_dispatch.status; stdout = "out"; stderr = "err" }
;;

let observation_label = function
  | Gate.Observed_clean -> "clean"
  | Gate.Observed_refused { status = Unix.WEXITED code; stderr } ->
    Printf.sprintf "refused exit=%d stderr=%s" code stderr
  | Gate.Observed_refused { status = Unix.WSIGNALED signal; stderr } ->
    Printf.sprintf "refused signal=%d stderr=%s" signal stderr
  | Gate.Observed_refused { status = Unix.WSTOPPED signal; stderr } ->
    Printf.sprintf "refused stopped=%d stderr=%s" signal stderr
  | Gate.Observation_unavailable reason -> "unavailable " ^ reason
;;

let observation = testable (fun fmt o -> Format.pp_print_string fmt (observation_label o)) ( = )

(* Exit 0 is clean, and the result is kept for the caller: the gate that
   allows on it must not run the call again. *)
let test_a_clean_run_is_kept_for_the_caller () =
  let stage = Stage.create ~route:boxed ~dispatch:(fun _ -> result (Unix.WEXITED 0)) in
  check observation "clean" Gate.Observed_clean (Stage.observe stage ());
  match Stage.observed_result stage with
  | Some { Masc_exec.Exec_dispatch.stdout; _ } -> check string "the run's output" "out" stdout
  | None -> fail "a clean run left nothing for the caller"
;;

(* Anything else is refused with the status and the stderr the box wrote,
   and nothing is kept: there is no result to return without the judge. *)
let test_a_non_zero_run_is_refused_with_its_stderr () =
  let stage = Stage.create ~route:boxed ~dispatch:(fun _ -> result (Unix.WEXITED 2)) in
  check observation "refused"
    (Gate.Observed_refused { status = Unix.WEXITED 2; stderr = "err" })
    (Stage.observe stage ());
  check bool "nothing kept" true (Option.is_none (Stage.observed_result stage));
  (* The refusal is readable afterwards, so the deferred receipt can tell the
     keeper what the box refused. *)
  check (option observation) "the outcome is remembered"
    (Some (Gate.Observed_refused { status = Unix.WEXITED 2; stderr = "err" }))
    (Stage.outcome stage);
  let signalled = Stage.create ~route:boxed ~dispatch:(fun _ -> result (Unix.WSIGNALED 15)) in
  check observation "a signal is refused too"
    (Gate.Observed_refused { status = Unix.WSIGNALED 15; stderr = "err" })
    (Stage.observe signalled ())
;;

(* No box means no dispatch: the reason travels, the fake dispatch is never
   reached. *)
let test_no_box_is_unavailable_without_dispatching () =
  let stage =
    Stage.create
      ~route:(fun () -> Target.No_box "docker_observe_unsupported: no shim")
      ~dispatch:(fun _ -> fail "dispatched with no box")
  in
  check observation "unavailable, in the route's words"
    (Gate.Observation_unavailable "docker_observe_unsupported: no shim")
    (Stage.observe stage ())
;;

(* A dispatch the typed gate refused before anything ran is unavailable
   under the gate's own closed tag, never read as clean or refused. *)
let test_a_refused_dispatch_is_unavailable_under_its_tag () =
  let stage =
    Stage.create
      ~route:boxed
      ~dispatch:(fun _ -> Error (Keeper_tooling.Execute_shell_ir.Gate_reject "x"))
  in
  check observation "gate_reject" (Gate.Observation_unavailable "gate_reject") (Stage.observe stage ());
  let path =
    Stage.create
      ~route:boxed
      ~dispatch:(fun _ -> Error (Keeper_tooling.Execute_shell_ir.Path_reject "y"))
  in
  check observation "path_reject" (Gate.Observation_unavailable "path_reject") (Stage.observe path ())
;;

let () =
  run
    "keeper_tool_execute_observe"
    [ ( "stage"
      , [ test_case "a clean run is kept for the caller" `Quick test_a_clean_run_is_kept_for_the_caller
        ; test_case "a non-zero run is refused with its stderr" `Quick
            test_a_non_zero_run_is_refused_with_its_stderr
        ; test_case "no box is unavailable without dispatching" `Quick
            test_no_box_is_unavailable_without_dispatching
        ; test_case "a refused dispatch is unavailable under its tag" `Quick
            test_a_refused_dispatch_is_unavailable_under_its_tag
        ] )
    ]
;;

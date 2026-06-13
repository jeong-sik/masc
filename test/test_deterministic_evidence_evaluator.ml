(** RFC-0199 Phase B — Deterministic_evidence_evaluator unit tests.

    Pure evaluator: every probe is a stub, so these tests assert the
    branch logic (Satisfied / Unsatisfied / Indeterminate) without real I/O.
    Key invariants under test:
    - Unknown is never permissive: a [None] probe answer -> Indeterminate,
      never Satisfied.
    - [eval_all []] is never vacuously Satisfied (no claims -> no auto-complete).
    - Satisfied requires every claim Satisfied over a non-empty list.
    - Indeterminate dominates Unsatisfied in [eval_all]. *)

module E = Evidence_claim
module Ev = Deterministic_evidence_evaluator

(* A probe where every world query is "unknown" (None) / absent. Tests
   override only the fields they exercise. *)
let blank_probe : Ev.probe =
  { file_bytes = (fun _ -> None)
  ; command_exit = (fun _ -> None)
  ; pr_merged = (fun ~repo:_ ~pr:_ -> None)
  ; ci_passed = (fun ~repo:_ ~pr:_ -> None)
  ; custom_check = (fun ~id:_ ~payload:_ -> None)
  }

let is_satisfied = function Ev.Satisfied -> true | _ -> false
let is_unsat = function Ev.Unsatisfied _ -> true | _ -> false
let is_indet = function Ev.Indeterminate _ -> true | _ -> false

let check_outcome name pred outcome =
  Alcotest.(check bool) (name ^ " — got " ^ Ev.outcome_to_string outcome) true (pred outcome)

let artifact path = E.Artifact_exists { path; min_bytes = None }
let artifact_min path n = E.Artifact_exists { path; min_bytes = Some n }

let test_artifact_present () =
  let probe = { blank_probe with file_bytes = (fun _ -> Some 42) } in
  check_outcome "present artifact satisfies" is_satisfied
    (Ev.eval_claim probe (artifact ".masc/voice_config.json"))

let test_artifact_absent () =
  check_outcome "absent artifact unsatisfied (definite no)" is_unsat
    (Ev.eval_claim blank_probe (artifact ".masc/voice_config.json"))

let test_artifact_too_small () =
  let probe = { blank_probe with file_bytes = (fun _ -> Some 5) } in
  check_outcome "artifact below min_bytes unsatisfied" is_unsat
    (Ev.eval_claim probe (artifact_min "x" 100))

let test_artifact_min_met () =
  let probe = { blank_probe with file_bytes = (fun _ -> Some 200) } in
  check_outcome "artifact at/over min_bytes satisfied" is_satisfied
    (Ev.eval_claim probe (artifact_min "x" 100))

let test_tests_pass_exit_match () =
  let probe = { blank_probe with command_exit = (fun _ -> Some 0) } in
  check_outcome "command exit matches -> satisfied" is_satisfied
    (Ev.eval_claim probe (E.Tests_pass { command = "dune build"; expected_exit = 0 }))

let test_tests_pass_exit_mismatch () =
  let probe = { blank_probe with command_exit = (fun _ -> Some 1) } in
  check_outcome "command exit mismatch -> unsatisfied" is_unsat
    (Ev.eval_claim probe (E.Tests_pass { command = "dune build"; expected_exit = 0 }))

let test_tests_pass_cannot_run () =
  (* blank_probe.command_exit returns None = could not run *)
  check_outcome "command could not run -> indeterminate (not a false no)" is_indet
    (Ev.eval_claim blank_probe (E.Tests_pass { command = "dune build"; expected_exit = 0 }))

let test_unknown_never_permissive () =
  (* every blank probe answer is None; no claim may come back Satisfied *)
  let claims =
    [ E.PR_merged { repo = "masc"; pr_number = 1 }
    ; E.CI_pass { repo = "masc"; pr_number = 1 }
    ; E.Custom_check { id = "x"; payload = `Null }
    ]
  in
  List.iter
    (fun c ->
      check_outcome "unknown probe -> not satisfied" (fun o -> not (is_satisfied o))
        (Ev.eval_claim blank_probe c))
    claims

let test_eval_all_empty_not_satisfied () =
  check_outcome "empty claim list is never vacuously satisfied" is_unsat
    (Ev.eval_all blank_probe [])

let test_eval_all_all_satisfied () =
  let probe = { blank_probe with file_bytes = (fun _ -> Some 10) } in
  check_outcome "all claims satisfied -> Satisfied" is_satisfied
    (Ev.eval_all probe [ artifact "a"; artifact "b" ])

let test_eval_all_one_absent () =
  (* a present, b absent *)
  let probe =
    { blank_probe with file_bytes = (fun p -> if String.equal p "a" then Some 10 else None) }
  in
  check_outcome "one absent -> Unsatisfied" is_unsat
    (Ev.eval_all probe [ artifact "a"; artifact "b" ])

let test_eval_all_indeterminate_dominates () =
  (* one definite Unsatisfied (absent file) + one Indeterminate (cannot run) *)
  let probe = { blank_probe with file_bytes = (fun _ -> None) } in
  check_outcome "indeterminate dominates unsatisfied" is_indet
    (Ev.eval_all probe
       [ E.Tests_pass { command = "x"; expected_exit = 0 } (* indeterminate *)
       ; artifact "absent" (* unsatisfied *)
       ])

let () =
  Alcotest.run "deterministic_evidence_evaluator"
    [ ( "eval_claim",
        [ Alcotest.test_case "artifact present" `Quick test_artifact_present
        ; Alcotest.test_case "artifact absent" `Quick test_artifact_absent
        ; Alcotest.test_case "artifact too small" `Quick test_artifact_too_small
        ; Alcotest.test_case "artifact min met" `Quick test_artifact_min_met
        ; Alcotest.test_case "tests_pass exit match" `Quick test_tests_pass_exit_match
        ; Alcotest.test_case "tests_pass exit mismatch" `Quick test_tests_pass_exit_mismatch
        ; Alcotest.test_case "tests_pass cannot run" `Quick test_tests_pass_cannot_run
        ; Alcotest.test_case "unknown never permissive" `Quick test_unknown_never_permissive
        ] )
    ; ( "eval_all",
        [ Alcotest.test_case "empty not satisfied" `Quick test_eval_all_empty_not_satisfied
        ; Alcotest.test_case "all satisfied" `Quick test_eval_all_all_satisfied
        ; Alcotest.test_case "one absent" `Quick test_eval_all_one_absent
        ; Alcotest.test_case "indeterminate dominates" `Quick test_eval_all_indeterminate_dominates
        ] )
    ]

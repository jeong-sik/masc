(** Every completion verdict reaches the calibration ledger the Harness
    surface reads.

    The judge kept running after the July 2026 evaluation flow was removed,
    but the [Eval_calibration.record_verdict] call was removed with it: the
    ledger's writer had zero callers while its reader stayed on screen, and
    the Harness tab served month-old rows as if the gate were current (last
    record 2026-07-27, found 2026-08-29). This pins the one call site so the
    wire cannot be cut silently again — a removal has to come here and say
    where verdicts go instead. *)

let module_path = "lib/completion_authority_agent.ml"
let binding = "process_task_once"

let test_the_review_records_its_verdict () =
  let n =
    Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:binding
      ~callee:"Eval_calibration.record_verdict"
  in
  if n <> 1 then
    Alcotest.failf
      "%s must record the review's verdict in the calibration ledger exactly \
       once; Eval_calibration.record_verdict is called %d time(s)"
      binding n
;;

let () =
  Alcotest.run "completion authority records verdicts"
    [ ( "wiring"
      , [ Alcotest.test_case "the review records its verdict" `Quick
            test_the_review_records_its_verdict
        ] )
    ]

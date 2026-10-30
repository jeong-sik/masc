open Alcotest

module Observation = Task_outcome_measurement

let test_approval_does_not_assert_external_acceptance () =
  check bool "approval is the existing lifecycle success" true
    (Observation.lifecycle_success Observation.Approved);
  check bool "cancellation is a lifecycle non-success" false
    (Observation.lifecycle_success Observation.Cancelled);
  let json =
    Observation.external_acceptance_to_yojson
      (Observation.Unobserved { completed_tasks = 2 })
  in
  check bool "even approved terminal Tasks have no inferred acceptance" true
    (json = `Assoc [ "kind", `String "unobserved"; "completed_tasks", `Int 2 ]);
  check bool "roundtrip preserves missing external evidence" true
    (Observation.external_acceptance_of_yojson json
     = Ok (Observation.Unobserved { completed_tasks = 2 }))

let test_external_claims_cannot_enter_task_statistics () =
  List.iter
    (fun json ->
       match Observation.external_acceptance_of_yojson json with
       | Error _ -> ()
       | Ok _ -> fail "a Task statistic admitted invented acceptance evidence")
    [ `Assoc [ "kind", `String "accepted"; "completed_tasks", `Int 1 ]
    ; `Assoc [ "kind", `String "unobserved"; "completed_tasks", `Int (-1) ]
    ; `Assoc [ "kind", `String "unobserved"; "completed_tasks", `Int 1;
               "success_rate", `Float 1.0 ]
    ];
  check bool "the aggregate states its lifecycle basis" true
    (Observation.basis_to_yojson Observation.Task_lifecycle = `String "task_lifecycle");
  check bool "an external-success basis cannot be invented" true
    (Result.is_error (Observation.basis_of_yojson (`String "external_acceptance")))

let () =
  run "task_outcome_measurement"
    [ "evidence boundaries",
      [ test_case "approval does not assert external acceptance" `Quick
          test_approval_does_not_assert_external_acceptance
      ; test_case "Task statistics refuse invented external observations" `Quick
          test_external_claims_cannot_enter_task_statistics
      ] ]

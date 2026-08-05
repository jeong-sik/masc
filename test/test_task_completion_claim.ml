(** Tests for {!Masc.Task_completion_claim} — deliverable completion-claim
    detection (SSOT extracted from verification_protocol / workspace_status_rendering).

    Pins the documented current behaviour, including the known false-negative
    surface for non-English phrasing. *)

module T = Masc.Task_completion_claim

let claims ~task_id deliverable = T.deliverable_claims_completion ~task_id deliverable

let case name ~task_id ~deliverable expected =
  Alcotest.test_case name `Quick (fun () ->
    Alcotest.(check bool) name expected (claims ~task_id deliverable))

let () =
  Alcotest.run
    "task_completion_claim"
    [ ( "positive",
        [ case "bare 'completed' prefix" ~task_id:"task-1"
            ~deliverable:"completed the work" true
        ; case "'<task_id> completed' prefix" ~task_id:"task-42"
            ~deliverable:"task-42 completed and verified" true
        ; case "case-insensitive" ~task_id:"task-1" ~deliverable:"COMPLETED" true
        ; case "first non-empty line drives the verdict" ~task_id:"task-1"
            ~deliverable:"completed\nmore detail below" true
        ] )
    ; ( "negative",
        [ case "empty deliverable" ~task_id:"task-1" ~deliverable:"" false
        ; case "'done' is not the claim token" ~task_id:"task-1"
            ~deliverable:"done with the task" false
          (* Documented current limitation: non-English phrasing is not
             recognised by the deterministic prefix matcher. *)
        ; case "Korean completion claim (known false negative)" ~task_id:"task-1"
            ~deliverable:"완료했습니다" false
        ; case "'completion' mention is not a claim" ~task_id:"task-1"
            ~deliverable:"completion was attempted but failed" false
        ] )
    ]

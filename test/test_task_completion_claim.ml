(** Tests for {!Masc.Task_completion_claim} — deliverable completion-claim
    detection (SSOT extracted from verification_protocol / workspace_status_rendering).

    Pins the documented behaviour, including the known false-negative surface
    (non-English phrasing). When the RFC-0323 LLM-boundary replacement lands,
    the Korean case below is the regression anchor that should flip to [true]. *)

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
          (* Documented false-negative: non-English phrasing is not recognised.
             Explicit anchor for the RFC-0323 LLM-boundary replacement. *)
        ; case "Korean completion claim (known false negative)" ~task_id:"task-1"
            ~deliverable:"완료했습니다" false
        ; case "'completion' mention is not a claim" ~task_id:"task-1"
            ~deliverable:"completion was attempted but failed" false
        ] )
    ]

open Alcotest

let test_references () =
  check string "Board post" "masc://board/post-42"
    (Masc_tui_link.reference Board_post "post-42");
  check string "goal path and escaped id" "masc://planning/goal%2Fone%20two"
    (Masc_tui_link.reference Goal "goal/one two");
  check string "task opens Overview namespace" "masc://overview/tasks/task-7"
    (Masc_tui_link.reference Task "task-7")

let test_osc52 () =
  let reference = "masc://fusion/run-9" in
  let expected = "\027]52;c;" ^ Base64.encode_string reference ^ "\007" in
  check string "OSC 52 clipboard sequence" expected
    (Masc_tui_link.osc52_copy reference)

let () =
  run "tui_link"
    [ ( "reference"
      , [ test_case "canonical paths" `Quick test_references
        ; test_case "OSC 52" `Quick test_osc52
        ] )
    ]

open Alcotest

module Prim = Masc_tui_render_prim
module Decode = Masc.Tui_decode

let state status stage = Prim.fusion_run_state_text ~status ~stage

(* Eight of eighteen live runs read [failed] in this cell and nothing more,
   while each carried its failure code; only the line under the table that
   follows the cursor drew it. The code is what the list is scanned for:
   timeouts, provider errors and panels that never answered are three
   different things to go and fix. *)
let test_a_failed_run_says_how_it_failed () =
  List.iter
    (fun code ->
      check string
        (Printf.sprintf "the %s run names its code" code)
        code
        (state
           (Decode.Fusion_failed
              { frs_failure_code = code
              ; frs_error = "the full sentence stays on the selected line"
              })
           Decode.Fusion_stage_failed))
    [ "timeout"; "provider_error"; "panels_unavailable" ]

(* A code is drawn on one line whatever the wire carried: a raw newline in
   the cell would break the row in two. *)
let test_a_code_is_one_line () =
  check bool "no raw newline reaches the table" false
    (String.contains
       (state
          (Decode.Fusion_failed
             { frs_failure_code = "provider_error\n"; frs_error = "" })
          Decode.Fusion_stage_failed)
       '\n')

let test_a_running_run_says_its_stage () =
  check string "the judge stage with its panel counts" "judge(2/1)"
    (state Decode.Fusion_running
       (Decode.Fusion_stage_judge
          { frs_expected = 3; frs_answered = 2; frs_failed = 1 }))

let test_a_completed_run_says_completed () =
  check string "completed" "completed"
    (state Decode.Fusion_completed Decode.Fusion_stage_completed)

let () =
  run "tui fusion state"
    [ ( "state cell"
      , [ test_case "a failed run says how it failed" `Quick
            test_a_failed_run_says_how_it_failed
        ; test_case "a code is one line" `Quick test_a_code_is_one_line
        ; test_case "a running run says its stage" `Quick
            test_a_running_run_says_its_stage
        ; test_case "a completed run says completed" `Quick
            test_a_completed_run_says_completed
        ] )
    ]

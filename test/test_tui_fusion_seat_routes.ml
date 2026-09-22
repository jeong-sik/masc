(** The seat-routes block of a Fusion run's detail, read as the operator
    reads it: one line per seat, the failed candidates under their seat. *)
open Alcotest
module Decode = Masc.Tui_decode
module Seat_routes = Masc_tui_fusion_seat_routes

let attempt runtime code detail =
  { Decode.fsa_runtime = runtime; fsa_code = code; fsa_detail = detail }

let test_one_line_per_seat_with_its_failed_attempts_under_it () =
  let routes =
    [ { Decode.fsr_seat = Decode.Fusion_panel_seat "first"
      ; fsr_route = "panel-lane"
      ; fsr_answered_by = Some "glm-4.6"
      ; fsr_failed_attempts = [ attempt "deepseek" "rate_limited" "429 from the provider" ]
      }
    ; { Decode.fsr_seat =
          Decode.Fusion_judge_seat { fs_role = Decode.Judge_meta; fs_identity = "meta" }
      ; fsr_route = "judge-lane"
      ; fsr_answered_by = None
      ; fsr_failed_attempts =
          [ attempt "opus" "timeout" "no answer in 300s"; attempt "sonnet" "refused" "quota" ]
      }
    ]
  in
  check (list string) "seats, then their attempts, in the recorded order"
    [ "panel/first \xc2\xb7 route panel-lane \xe2\x86\x92 answered by glm-4.6"
    ; "    deepseek: rate_limited 429 from the provider"
    ; "judge/meta/meta \xc2\xb7 route judge-lane \xe2\x86\x92 no candidate answered"
    ; "    opus: timeout no answer in 300s"
    ; "    sonnet: refused quota"
    ]
    (Seat_routes.lines routes)

let test_a_seat_that_answered_first_has_no_attempts_under_it () =
  let routes =
    [ { Decode.fsr_seat =
          Decode.Fusion_judge_seat { fs_role = Decode.Judge_single; fs_identity = "single" }
      ; fsr_route = "opus"
      ; fsr_answered_by = Some "opus"
      ; fsr_failed_attempts = []
      }
    ]
  in
  check (list string) "one line and nothing indented"
    [ "judge/single/single \xc2\xb7 route opus \xe2\x86\x92 answered by opus" ]
    (Seat_routes.lines routes);
  check (list string) "no routes, no block" [] (Seat_routes.lines [])

let () =
  run "tui_fusion_seat_routes"
    [ ( "lines"
      , [ test_case "one line per seat with its failed attempts under it" `Quick
            test_one_line_per_seat_with_its_failed_attempts_under_it
        ; test_case "a seat that answered first has no attempts under it" `Quick
            test_a_seat_that_answered_first_has_no_attempts_under_it
        ] )
    ]

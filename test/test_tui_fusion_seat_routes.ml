(** The seat-routes block of a Fusion run's detail, read as the operator
    reads it: one line per seat, the failed candidates under their seat. *)
open Alcotest
module Seat_routes = Masc_tui_fusion_seat_routes

let attempt runtime code detail =
  { Masc.Tui_decode_fusion.fsa_runtime = runtime; fsa_code = code; fsa_detail = detail }

let test_a_failure_detail_cannot_carry_an_escape_sequence () =
  let routes =
    [ { Masc.Tui_decode_fusion.fsr_seat = Masc.Tui_decode_fusion.Fusion_panel_seat "first"
      ; fsr_route = "\027[31mlane"
      ; fsr_answered_by = None
      ; fsr_failed_attempts = [ attempt "opus" "refused" "\027[2Jcleared your screen" ]
      }
    ]
  in
  check (list string) "the escape is spelled out, not obeyed"
    [ "panel/first \xc2\xb7 route \\x1B[31mlane \xe2\x86\x92 no candidate answered"
    ; "    opus: refused \\x1B[2Jcleared your screen"
    ]
    (Seat_routes.lines routes)

let test_korean_seat_routes_localize_labels () =
  let routes =
    [ { Masc.Tui_decode_fusion.fsr_seat = Masc.Tui_decode_fusion.Fusion_panel_seat "first"
      ; fsr_route = "lane-a"
      ; fsr_answered_by = None
      ; fsr_failed_attempts = [ attempt "opus" "refused" "quota" ]
      }
    ; { Masc.Tui_decode_fusion.fsr_seat =
          Masc.Tui_decode_fusion.Fusion_judge_seat
            { fs_role = Masc.Tui_decode_fusion.Judge_single; fs_identity = "primary" }
      ; fsr_route = "judge-lane"
      ; fsr_answered_by = Some "sonnet"
      ; fsr_failed_attempts = []
      }
    ]
  in
  check (list string) "Korean mode localizes route, answer, and empty-answer labels"
    [ "panel/first \xc2\xb7 경로 lane-a \xe2\x86\x92 응답한 후보 없음"
    ; "    opus: refused quota"
    ; "judge/single/primary \xc2\xb7 경로 judge-lane \xe2\x86\x92 응답: sonnet"
    ]
    (Seat_routes.lines ~ko:true routes)

let () =
  run "tui_fusion_seat_routes"
    [ ( "lines"
      , [ test_case "a failure detail cannot carry an escape sequence" `Quick
            test_a_failure_detail_cannot_carry_an_escape_sequence
        ; test_case "Korean seat routes localize labels" `Quick
            test_korean_seat_routes_localize_labels
        ] )
    ]

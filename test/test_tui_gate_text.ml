(* The gate's wording, drawn from the typed phase. The store used to compose
   it, in Korean, in OCaml, and said the keeper carries on with other work
   right where the turn ends. *)

open Alcotest
module Gate = Masc_tui_gate_text

let line phase tool = Gate.lifecycle_line ~phase ~tool

let test_each_phase_reads_as_itself () =
  check string "requested"
    "Execute 승인 대기 · 이 호출은 승인될 때까지 실행되지 않습니다"
    (line "requested" (Some "Execute"));
  check string "approved" "Execute 승인됨 · 적용은 아직 확인 전"
    (line "resolved_approved" (Some "Execute"));
  check string "rejected" "Execute 승인 거절" (line "resolved_rejected" (Some "Execute"));
  check string "applied" "Execute 적용 완료" (line "replay_applied" (Some "Execute"));
  check string "applied with warning" "Execute 적용 완료 · 경고 있음"
    (line "replay_applied_with_warning" (Some "Execute"));
  check string "failed" "Execute 적용 실패" (line "replay_failed" (Some "Execute"));
  check string "indeterminate" "Execute 적용 여부 불명 · 대상을 직접 확인하세요"
    (line "replay_indeterminate" (Some "Execute"));
  check string "continuation" "Execute 승인 후 이어서 진행"
    (line "continuation_recorded" (Some "Execute"))

let test_a_row_without_a_tool_still_reads () =
  check string "no tool name" "외부 효과 승인 대기 · 이 호출은 승인될 때까지 실행되지 않습니다"
    (line "requested" None)

(* A phase this build has not been taught is named, not dropped: a silent row
   would read as nothing happening. *)
let test_an_unknown_phase_is_named () =
  check string "unknown phase" "Execute · 알 수 없는 승인 단계 quarantined"
    (line "quarantined" (Some "Execute"))

let () =
  run "Masc_tui_gate_text"
    [ ( "lifecycle wording"
      , [ test_case "each phase reads as itself" `Quick test_each_phase_reads_as_itself
        ; test_case "a row without a tool still reads" `Quick test_a_row_without_a_tool_still_reads
        ; test_case "an unknown phase is named" `Quick test_an_unknown_phase_is_named
        ] )
    ]

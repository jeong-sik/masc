(* The gate's wording, drawn from the typed phase. The store used to compose
   it, in Korean, in OCaml, and said the keeper carries on with other work
   right where the turn ends. The sentences say what the runtime does: the
   call is deferred, not the turn. *)

open Alcotest
module Gate = Masc_tui_gate_text

let line phase tool = Gate.lifecycle_line ~phase ~tool ~summary:None

let with_summary phase tool summary =
  Gate.lifecycle_line ~phase ~tool ~summary
;;

let test_each_phase_reads_as_itself () =
  check string "requested"
    "Execute · 판정 중 · 이 호출은 미뤄짐"
    (line "requested" (Some "Execute"));
  check string "approved" "Execute · 승인됨 · 적용 예정"
    (line "resolved_approved" (Some "Execute"));
  check string "rejected" "Execute · 승인 거절" (line "resolved_rejected" (Some "Execute"));
  check string "applied" "Execute · 미뤘던 호출 적용됨"
    (line "replay_applied" (Some "Execute"));
  check string "applied with warning" "Execute · 적용됨 · 경고 있음"
    (line "replay_applied_with_warning" (Some "Execute"));
  check string "failed" "Execute · 적용 실패" (line "replay_failed" (Some "Execute"));
  check string "indeterminate" "Execute · 적용 여부 불명 · 대상을 직접 확인하세요"
    (line "replay_indeterminate" (Some "Execute"));
  check string "continuation" "Execute · 턴 이어서 진행"
    (line "continuation_recorded" (Some "Execute"))

let test_a_row_without_a_tool_still_reads () =
  check string "no tool name" "외부 효과 · 판정 중 · 이 호출은 미뤄짐"
    (line "requested" None)

(* The summary names what was deferred, so a row answers "what was gated"
   without the pane going back to the request row. *)
let test_a_summary_names_the_call () =
  check string "summary is drawn between tool and phase"
    "tool_execute · cd repos/masc && git log --oneline -8 -- test/dune · 판정 중 · 이 호출은 미뤄짐"
    (with_summary "requested" (Some "tool_execute")
       (Some "cd repos/masc && git log --oneline -8 -- test/dune"));
  check string "a blank summary reads as no summary"
    "tool_execute · 판정 중 · 이 호출은 미뤄짐"
    (with_summary "requested" (Some "tool_execute") (Some "  "))

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
        ; test_case "a summary names the call" `Quick test_a_summary_names_the_call
        ; test_case "an unknown phase is named" `Quick test_an_unknown_phase_is_named
        ] )
    ]

(* The gate's wording, drawn from the typed phase. The store used to compose
   it, in Korean, in OCaml, and said the keeper carries on with other work
   right where the turn ends. The sentences say what the runtime does: the
   call is deferred, not the turn.

   The phase is the store's closed sum, so there is no "unknown phase" line to
   test: a label the store does not know never reaches this module. *)

open Masc.Keeper_chat_store
open Alcotest
module Gate = Masc_tui_gate_text
module Layout = Masc_tui_message_layout

let line phase tool = Gate.lifecycle_line ~phase ~tool ~summary:None

let with_summary phase tool summary =
  Gate.lifecycle_line ~phase ~tool ~summary
;;

let test_each_phase_reads_as_itself () =
  check string "requested"
    "판정 중 · 이 호출은 미뤄짐 · Execute"
    (line Approval_requested (Some "Execute"));
  check string "approved" "승인됨 · 적용 예정 · Execute"
    (line Approval_resolved_approved (Some "Execute"));
  check string "rejected" "승인 거절 · Execute"
    (line Approval_resolved_rejected (Some "Execute"));
  check string "applied" "미뤘던 호출 적용됨 · Execute"
    (line Approval_replay_applied (Some "Execute"));
  check string "applied with warning" "적용됨 · 경고 있음 · Execute"
    (line Approval_replay_applied_with_warning (Some "Execute"));
  check string "failed" "적용 실패 · Execute"
    (line Approval_replay_failed (Some "Execute"));
  check string "indeterminate" "적용 여부 불명 · 대상을 직접 확인하세요 · Execute"
    (line Approval_replay_indeterminate (Some "Execute"));
  check string "continuation" "턴 이어서 진행 · Execute"
    (line Approval_continuation_recorded (Some "Execute"))

(* The part that differs is the part the pane keeps. Every phase used to end
   the row, so at a narrow width the eight above read as one. *)
let test_the_phase_survives_a_narrow_pane () =
  let head text = Layout.take_cells text 24 in
  let heads =
    List.map
      (fun phase -> head (line phase (Some "tool_execute")))
      [ Approval_requested
      ; Approval_resolved_approved
      ; Approval_resolved_rejected
      ; Approval_replay_applied
      ; Approval_replay_applied_with_warning
      ; Approval_replay_failed
      ; Approval_replay_indeterminate
      ; Approval_continuation_recorded
      ]
  in
  check int "eight phases, eight first lines" (List.length heads)
    (List.length (List.sort_uniq String.compare heads))

let test_a_row_without_a_tool_still_reads () =
  check string "no tool name" "판정 중 · 이 호출은 미뤄짐 · 외부 효과"
    (line Approval_requested None)

(* The summary names what was deferred, so a row answers "what was gated"
   without the pane going back to the request row. It also names which call it
   was -- "github/create_pull_request", the shell command itself -- so the
   tool name beside it repeated what was already there and pushed the phase
   off the end. Of 12,592 Gate rows on this fleet, 8,986 carry no summary, and
   those are the rows the tool name is for. *)
let test_a_summary_speaks_for_the_tool () =
  check string "the summary is the subject, alone"
    "판정 중 · 이 호출은 미뤄짐 · cd repos/masc && git log --oneline -8 -- test/dune"
    (with_summary Approval_requested (Some "tool_execute")
       (Some "cd repos/masc && git log --oneline -8 -- test/dune"));
  check string "a blank summary reads as no summary"
    "판정 중 · 이 호출은 미뤄짐 · tool_execute"
    (with_summary Approval_requested (Some "tool_execute") (Some "  "))

let () =
  run "Masc_tui_gate_text"
    [ ( "lifecycle wording"
      , [ test_case "each phase reads as itself" `Quick test_each_phase_reads_as_itself
        ; test_case "a row without a tool still reads" `Quick test_a_row_without_a_tool_still_reads
        ; test_case "the phase survives a narrow pane" `Quick
            test_the_phase_survives_a_narrow_pane
        ; test_case "a summary speaks for the tool" `Quick
            test_a_summary_speaks_for_the_tool
        ] )
    ]

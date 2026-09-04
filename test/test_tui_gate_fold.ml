(* A run of Gate rows folds back into the one approval it describes. The store
   keeps a row per phase; drawn one row per phase, a single approval took four
   lines of the conversation pane and repeated the tool name on each. *)

open Alcotest
module Types = Masc_tui_types
module Gate_text = Masc_tui_gate_text

let entry ?gate role text =
  { Types.me_role = role
  ; me_identity =
      Types.Session_row
        { request_id = ""; turn_phase = Types.Turn_output; operation_seq = 0 }
  ; me_turn_phase = Types.Turn_output
  ; me_turn_sequence = None
  ; me_operation_seq = 0
  ; me_text = text
  ; me_memory_summary = None
  ; me_gate = gate
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_activity = None
  ; me_timestamp = ""
  ; me_keeper_name = "k"
  ; me_request_id = ""
  ; me_at = 0.
  }

let step ?(approval = "appr_1") ?(tool = "Execute") phase =
  entry
    ~gate:
      { Types.gs_approval_id = approval
      ; gs_phase = phase
      ; gs_tool = Some tool
      }
    Types.Message_status
    (Gate_text.lifecycle_line ~phase ~tool:(Some tool))

let said text = entry Types.Message_keeper text
let rows entries = List.map (fun e -> (e, ())) entries
let describe folded = List.map (fun (e, _) -> e.Types.me_text) folded
let fold entries = describe (Types.fold_gate_runs (rows entries))

let test_one_approval_is_one_row () =
  check (list string) "the whole run says where the effect ended up"
    [ "Execute 적용 완료 · 이어서 진행" ]
    (fold
       [ step "requested"
       ; step "resolved_approved"
       ; step "replay_applied"
       ; step "continuation_recorded"
       ])

let test_a_correction_supersedes_the_row_it_corrects () =
  (* A replay correction is a second row for the same approval carrying the
     canonical phase. Ranking by severity kept showing the phase the
     correction exists to overturn. *)
  check (list string) "the canonical phase is the one drawn"
    [ "Execute 적용 완료" ]
    (fold
       [ step "resolved_approved"; step "replay_failed"; step "replay_applied" ])

let test_a_replay_outranks_the_resolution_before_it () =
  check (list string) "the outcome, not how the Gate answered"
    [ "Execute 적용 여부 불명 · 대상을 직접 확인하세요" ]
    (fold [ step "requested"; step "resolved_approved"; step "replay_indeterminate" ])

let test_a_problem_outranks_a_later_step () =
  (* continuation_recorded is the newest row, but an operator scanning the pane
     has to see that the effect never landed. The turn did carry on, so that
     stays on the line -- it just does not get to be the whole line. *)
  check (list string) "the failure is the outcome, not the newest step"
    [ "Execute 적용 실패 · 이어서 진행" ]
    (fold
       [ step "resolved_approved"
       ; step "replay_failed"
       ; step "continuation_recorded"
       ])

let test_a_waiting_request_keeps_its_own_row () =
  check (list string) "a request still waiting is not folded away"
    [ "Execute 승인 대기 · 이 호출은 승인될 때까지 실행되지 않습니다"
    ; "말"
    ; "Execute 적용 완료"
    ]
    (fold [ step "requested"; said "말"; step "resolved_approved"; step "replay_applied" ])

let test_two_approvals_stay_two_rows () =
  check (list string) "back to back approvals do not merge"
    [ "Execute 적용 완료"; "Write 승인 거절" ]
    (fold
       [ step ~approval:"appr_1" "resolved_approved"
       ; step ~approval:"appr_1" "replay_applied"
       ; step ~approval:"appr_2" ~tool:"Write" "resolved_rejected"
       ])

let test_rows_that_are_not_gate_rows_are_untouched () =
  check (list string) "nothing else folds" [ "가"; "나" ] (fold [ said "가"; said "나" ])

let test_an_unknown_phase_still_draws () =
  check (list string) "a phase this build does not know is named"
    [ "Execute · 알 수 없는 승인 단계 invented" ]
    (fold [ step "invented" ])

let () =
  run "tui_gate_fold"
    [ ( "fold"
      , [ test_case "one approval is one row" `Quick test_one_approval_is_one_row
        ; test_case "a problem outranks a later step" `Quick
            test_a_problem_outranks_a_later_step
        ; test_case "a correction supersedes the row it corrects" `Quick
            test_a_correction_supersedes_the_row_it_corrects
        ; test_case "a replay outranks the resolution before it" `Quick
            test_a_replay_outranks_the_resolution_before_it
        ; test_case "a waiting request keeps its own row" `Quick
            test_a_waiting_request_keeps_its_own_row
        ; test_case "two approvals stay two rows" `Quick
            test_two_approvals_stay_two_rows
        ; test_case "rows that are not gate rows are untouched" `Quick
            test_rows_that_are_not_gate_rows_are_untouched
        ; test_case "an unknown phase still draws" `Quick
            test_an_unknown_phase_still_draws
        ] )
    ]

(* What a durable approval step reads as on screen. The store persists the
   typed phase and composes a sentence beside it; the sentence was the only
   thing the pane read, so its wording lived in the store and said things the
   runtime does not do — "나머지 작업은 이어서 진행합니다" on a turn that ends
   right after. The phase is the fact; this is the only place its wording
   lives. *)

let lifecycle_line ~phase ~tool =
  let tool = match tool with None -> "외부 효과" | Some name -> name in
  match phase with
  | "requested" -> tool ^ " 승인 대기 · 이 호출은 승인될 때까지 실행되지 않습니다"
  | "resolved_approved" -> tool ^ " 승인됨 · 적용은 아직 확인 전"
  | "resolved_rejected" -> tool ^ " 승인 거절"
  | "replay_applied" -> tool ^ " 적용 완료"
  | "replay_applied_with_warning" -> tool ^ " 적용 완료 · 경고 있음"
  | "replay_failed" -> tool ^ " 적용 실패"
  | "replay_indeterminate" -> tool ^ " 적용 여부 불명 · 대상을 직접 확인하세요"
  | "continuation_recorded" -> tool ^ " 승인 후 이어서 진행"
  | other -> Printf.sprintf "%s · 알 수 없는 승인 단계 %s" tool other
;;

(* One approval's steps as one line.

   The store records a step per phase, which is right: each is a durable fact
   about an external effect. Drawn one row per step, a single approval took
   four rows of the conversation pane and said the same tool name four times.

   The phases are a sequence, not independent facts -- "적용 완료" already
   implies the call was requested and approved -- so the run collapses to the
   furthest stage it reached: a replay outcome if one landed, else how the
   Gate resolved, else that it is still waiting.

   Within a stage the latest step wins, because a replay correction is a
   second row for the same approval carrying the canonical phase. Ranking by
   severity instead would have kept showing the phase the correction exists to
   overturn.

   [continuation_recorded] is the exception to all of it: it says the turn
   resumed, which no outcome says, so it rides along as a suffix instead of
   replacing the outcome. *)
let stage_of_phase = function
  | "replay_applied" | "replay_applied_with_warning" | "replay_failed"
  | "replay_indeterminate" -> Some 3
  | "resolved_approved" | "resolved_rejected" -> Some 2
  | "requested" -> Some 1
  | _ -> None
;;

let fold_line ~phases ~tool =
  let has phase = List.exists (String.equal phase) phases in
  let outcome =
    List.fold_left
      (fun best phase ->
        match stage_of_phase phase with
        | None -> best
        | Some stage -> (
          match best with
          (* [>=] and not [>]: within one stage the later step is the one that
             stands, which is how a correction row supersedes the row it
             corrects. *)
          | Some (best_stage, _) when stage >= best_stage -> Some (stage, phase)
          | Some _ -> best
          | None -> Some (stage, phase)))
      None phases
  in
  let outcome =
    match outcome with
    | Some (_, phase) -> Some phase
    (* A run of phases this build does not know still has to draw something,
       and the last one is the furthest the approval got. *)
    | None -> List.nth_opt (List.rev phases) 0
  in
  match outcome with
  | None -> None
  | Some phase ->
    let line = lifecycle_line ~phase ~tool in
    if has "continuation_recorded" && not (String.equal phase "continuation_recorded")
    then Some (line ^ " · 이어서 진행")
    else Some line
;;

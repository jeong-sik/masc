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
   furthest one it reached. Problems win over plain success, because an
   operator scanning the pane needs to see a failed or unproven effect even
   when a later step recorded that the turn carried on.

   [continuation_recorded] is the exception: it says the turn resumed, which
   the outcome does not, so it rides along as a suffix instead of replacing
   the outcome. *)
let outcome_order =
  [ "replay_failed"
  ; "replay_indeterminate"
  ; "replay_applied_with_warning"
  ; "replay_applied"
  ; "resolved_rejected"
  ; "resolved_approved"
  ; "requested"
  ]
;;

let fold_line ~phases ~tool =
  let has phase = List.exists (String.equal phase) phases in
  let outcome =
    match List.find_opt has outcome_order with
    | Some phase -> Some phase
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

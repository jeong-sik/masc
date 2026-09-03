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

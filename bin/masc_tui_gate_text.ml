(* What a durable approval step reads as on screen. The store persists the
   typed phase and composes a sentence beside it; the sentence was the only
   thing the pane read, so its wording lived in the store and said things the
   runtime does not do — "나머지 작업은 이어서 진행합니다" on a turn that ends
   right after. The phase is the fact; this is the only place its wording
   lives.

   The phase is the store's own closed sum, so every match here is total: a
   phase the store adds fails this compile instead of drawing as "알 수 없는
   승인 단계", and a label the store does not know never reaches this module
   -- the history decoder drops that row as undecodable.

   A gated call defers the call, not the Keeper: the turn it was asked on
   keeps running, and a settled approval resumes as a continuation. The
   sentences say that — a row that announces waiting reads as the whole turn
   halting while the pane next to it shows the Keeper answering someone
   else. [summary] is the one line naming what was deferred; without it the
   row can only name the tool. *)

open Masc.Keeper_chat_store

module Message_layout = Masc_tui_message_layout

(* Said once, because it is drawn twice: as the whole line of a
   continuation row, and as the suffix of a folded run that also resumed. *)
let continuation_wording = "턴 이어서 진행"

let lifecycle_line ~(phase : approval_lifecycle_phase) ~tool ~summary =
  let subject =
    let tool = match tool with None -> "외부 효과" | Some name -> name in
    match summary with
    | Some summary when String.trim summary <> "" -> tool ^ " · " ^ summary
    | Some _ | None -> tool
  in
  match phase with
  | Approval_requested -> subject ^ " · 판정 중 · 이 호출은 미뤄짐"
  | Approval_resolved_approved -> subject ^ " · 승인됨 · 적용 예정"
  | Approval_resolved_rejected -> subject ^ " · 승인 거절"
  | Approval_replay_applied -> subject ^ " · 미뤘던 호출 적용됨"
  | Approval_replay_applied_with_warning -> subject ^ " · 적용됨 · 경고 있음"
  | Approval_replay_failed -> subject ^ " · 적용 실패"
  | Approval_replay_indeterminate ->
    subject ^ " · 적용 여부 불명 · 대상을 직접 확인하세요"
  | Approval_continuation_recorded -> subject ^ " · " ^ continuation_wording
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

   [Approval_continuation_recorded] is the exception to all of it: it says the
   turn resumed, which no outcome says, so it is not a stage and rides along
   as a suffix instead of replacing the outcome. *)
type stage =
  | Waiting
  | Resolved
  | Replayed

let stage_rank = function
  | Waiting -> 1
  | Resolved -> 2
  | Replayed -> 3
;;

let stage_of_phase = function
  | Approval_replay_applied | Approval_replay_applied_with_warning
  | Approval_replay_failed | Approval_replay_indeterminate ->
    Some Replayed
  | Approval_resolved_approved | Approval_resolved_rejected -> Some Resolved
  | Approval_requested -> Some Waiting
  | Approval_continuation_recorded -> None
;;

let is_continuation = function
  | Approval_continuation_recorded -> true
  | Approval_requested | Approval_resolved_approved | Approval_resolved_rejected
  | Approval_replay_applied | Approval_replay_applied_with_warning
  | Approval_replay_failed | Approval_replay_indeterminate ->
    false
;;

let fold_line ~phases ~tool ~summary =
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
          | Some (best_stage, _) when stage_rank stage >= stage_rank best_stage
            ->
            Some (stage, phase)
          | Some _ -> best
          | None -> Some (stage, phase)))
      None phases
  in
  let continued = List.exists is_continuation phases in
  match outcome, continued with
  (* Every phase is either a stage or the continuation, so a run with neither
     is the empty run. *)
  | None, false -> None
  | None, true ->
    Some (lifecycle_line ~phase:Approval_continuation_recorded ~tool ~summary)
  | Some (_, phase), false -> Some (lifecycle_line ~phase ~tool ~summary)
  | Some (_, phase), true ->
    Some (lifecycle_line ~phase ~tool ~summary ^ " · " ^ continuation_wording)
;;

(* A Gate row's text carries the argument of the call it gated, and nothing
   caps it: one base64 argument took eight rows of the pane. Compact keeps
   what fits on a line and says how much it is holding.

   Counted in cells, not rows. How many rows this becomes is the layout's
   answer, decided after wrapping at a width this function does not have, so a
   row count read here would be a guess printed as a fact. Cells are what the
   text is, whatever the pane does with it.

   Folded, not truncated: Ctrl-D brings the whole argument back. A row that
   also said so would repeat the footer on every Gate row, which is what
   pushed the tool names onto a second line before. *)
let folded_argument ~cap text =
  let flat =
    String.concat " " (String.split_on_char '\n' (String.trim text))
  in
  let width = Message_layout.display_width flat in
  if width <= cap then flat
  else
    Printf.sprintf "%s \xe2\x8c\x84 %d\xec\x9e\x90"
      (Message_layout.take_cells flat cap)
      (width - cap)

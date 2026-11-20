(** Keepers list, detail pane, and turn logs screens. *)

open Masc.Tui_decode_connectors
open Masc_tui_types
open Tui_decode
open Masc.Tui_decode_fusion
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Metrics_tail = Masc_tui_metrics_tail

let keeper_log_style = function
  | Masc_tui_types.Keeper_log_fact -> Ansi.reset
  | Keeper_log_notice -> Theme.recede ()
  | Keeper_log_warning -> Theme.warn ()
  | Keeper_log_failure -> Theme.bad ()

module Rows = Masc_tui_rows
module Observation_layout = Masc_tui_observation_layout
module Keeper_activity = Masc_tui_keeper_activity
module Render_schedule = Masc_tui_render_schedule
module Layout = Masc_tui_layout
module Keeper_control = Masc_tui_keeper_control
module Keeper_list_model = Masc_tui_keeper_list_model
module Keeper_trail = Masc_tui_keeper_trail
module Item_account = Masc_tui_keeper_items

let format_context_tokens = Masc_tui_types.format_context_tokens
let schedule_status_reading = Masc_tui_render_work.schedule_status_reading
let schedule_status_word_cells = Masc_tui_render_work.schedule_status_word_cells
let schedule_requested_clock_cells = Masc_tui_render_work.schedule_requested_clock_cells
let schedule_outcome = Masc_tui_render_work.schedule_outcome
let schedule_status_is_terminal = Masc_tui_render_work.schedule_status_is_terminal

(* Healthy keepers stay quiet beside their NOW activity. A health deviation
   remains available to the secondary detail row instead of repeating a
   separate health word in every compact row. A keeper with no health is
   named by why it has none: the roster was not read, it left the keeper
   out, or it reported the keeper's configuration as an error. *)
let keeper_health_deviation_word ~ko (reading : Keeper_control.reading) =
  match Option.map Tui_decode.keeper_health_reading (Keeper_control.health reading) with
  | Some Tui_decode.Health_running -> None
  | None
  | Some (Tui_decode.Health_idle | Tui_decode.Health_failing | Tui_decode.Health_offline) ->
      Some (Keeper_control.health_label ~ko reading)

(* [runtime_id] is the producer-owned runtime identity. Keep it whole instead
   of deriving a model by splitting its spelling: the phase is a separate
   typed reading, while the sanitized id is the exact identity the gate named. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some row ->
      Printf.sprintf "%s %s"
        (Tui_decode.keeper_phase_to_string row.kr_phase)
        (Terminal_text.single_line row.kr_runtime_id)

(* The two halves of the runtime cell, so the column that has to be wide
   enough for them is measured from the same strings that get drawn. *)
let keeper_runtime_parts (row : keeper_runtime) =
  let phase =
    if row.kr_paused then "paused "
    else if Tui_decode.keeper_phase_is_running row.kr_phase then ""
    else Tui_decode.keeper_phase_to_string row.kr_phase ^ " "
  in
  (phase, Terminal_text.single_line row.kr_runtime_id)

(* What the widest row would spend on this cell. A keeper the roster cannot
   see draws an em dash, which is one cell. *)
let keeper_runtime_cells (runtime : keeper_runtime option) =
  match runtime with
  | None -> 1
  | Some row ->
      let phase, runtime_id = keeper_runtime_parts row in
      Message_layout.display_width phase
      + Message_layout.display_width runtime_id

let keeper_failure_cause_word ~ko = function
  | Keeper_failure_heartbeat -> if ko then "하트비트" else "heartbeat"
  | Keeper_failure_turn -> if ko then "턴" else "turn"
  | Keeper_failure_provider -> if ko then "제공자" else "provider"
  | Keeper_failure_configuration -> if ko then "설정" else "config"
  | Keeper_failure_client_recovery -> if ko then "클라이언트 복구" else "client recovery"
  | Keeper_failure_fiber -> if ko then "파이버" else "fiber"
  | Keeper_failure_exception -> if ko then "예외" else "exception"
  | Keeper_failure_operator_interrupt -> if ko then "운영자 중단" else "operator interrupt"

let failing_glyph = Masc_tui_keeper_mark.failing_glyph

(* The detail window and the failure sentence name a receipt's state with the
   same words. *)
let no_receipt_text ~ko = if ko then "영수증 없음" else "no receipt"
let walk_not_captured_text ~ko = if ko then "후보 순회 미기록" else "candidate walk was not captured"
let evidence_unreadable_text ~ko = if ko then "이력 근거 읽기 실패" else "historical evidence unreadable"
let no_candidate_failure_text ~ko = if ko then "후보 실패 기록 없음" else "no candidate failure recorded"

let keeper_cause_group_word ~ko = function
  | Keeper_trail.Rate_limited -> if ko then "요청 한도" else "rate limited"
  | Keeper_trail.Connection -> if ko then "연결" else "connection"
  | Keeper_trail.Provider -> if ko then "제공자" else "provider"
  | Keeper_trail.Configuration -> if ko then "설정" else "config"
  | Keeper_trail.Input -> if ko then "입력 한도" else "input capacity"
  | Keeper_trail.Unusable_reply -> if ko then "응답 사용 불가" else "unusable reply"
  | Keeper_trail.Effect_fenced -> if ko then "효과 차단" else "effect fenced"
  | Keeper_trail.Recovery -> if ko then "복구 필요" else "recovery needed"
  | Keeper_trail.Stopped -> if ko then "중지됨" else "stopped"
  | Keeper_trail.Server -> if ko then "서버" else "server"
  | Keeper_trail.Internal -> if ko then "내부 오류" else "internal"

(* The age of a failure, or [None] when its time is missing or ahead of the
   clock. The sentence leaves its time piece out then. The width measurement
   asks this same function, so the drawn text and the measured text cannot
   disagree about whether the piece is there. *)
let keeper_trail_age ~now = function
  | None -> None
  | Some since -> Message_layout.age_text ~now ~since

(* The sentence about a failing Keeper's past. [age] turns the failure time
   into the text drawn for it, or into [None] to leave the piece out. A
   sentence has one source: the receipt when it holds facts about the turn, the
   server's own cause word otherwise. *)
let keeper_trail_sentence ~ko ~age = function
  | Keeper_trail.Trail_sound -> None
  | Keeper_trail.Trail_failed { ended_at; last; walk } ->
      let reported =
        match last with
        | Some cause -> keeper_failure_cause_word ~ko cause
        | None -> if ko then "실패 기록 없음" else "no failure record"
      in
      let candidates_text tried =
        if ko then Printf.sprintf "후보 %d개" tried
        else Message_layout.count_noun tried "candidate"
      in
      let rest =
        match walk with
        | Keeper_trail.Walk_ended { runtime_id; cause; tried } ->
            [ keeper_cause_group_word ~ko cause
            ; Terminal_text.single_line runtime_id
            ; candidates_text tried
            ]
        | Keeper_trail.Walk_no_terminal { tried } ->
            [ (if ko then "종료 보고 없음" else "end not reported"); candidates_text tried ]
        | Keeper_trail.Walk_no_candidate_failure -> [ reported; no_candidate_failure_text ~ko ]
        | Keeper_trail.Walk_not_captured -> [ reported; walk_not_captured_text ~ko ]
        | Keeper_trail.Walk_unreadable -> [ reported; evidence_unreadable_text ~ko ]
        | Keeper_trail.Walk_absent -> [ reported; no_receipt_text ~ko ]
        | Keeper_trail.Walk_not_applicable -> [ reported ]
      in
      Some (failing_glyph ^ " " ^ String.concat " · " (Option.to_list (age ended_at) @ rest))

let keeper_row_trail_sentence ~ko ~age (row : Keeper_list_model.row) =
  keeper_trail_sentence ~ko ~age (Keeper_list_model.trail_of_row row)

(* The sentence is measured with the widest age the AGE column holds, so the
   column it widens does not change width as the clock runs. A failure with no
   usable time has no age piece, here as in the drawn sentence. *)
let widest_age_text = String.make Render_schedule.keeper_last_turn_width '0'

(* The cell is styled here: the sentence about the past is drawn in the warning
   colour, and the runtime identity stays receded. *)
let keeper_runtime_cell ~width ?failure_context (runtime : keeper_runtime option) =
  match failure_context with
  | Some text -> Theme.warn () ^ fit_width text width ^ Ansi.reset
  | None ->
      Theme.recede ()
      ^ (match runtime with
         | None -> fit_width Masc_tui_theme.Glyph.no_value width
         | Some row ->
             (* Running is the normal lifecycle and stays silent; the cell goes
                to the runtime identity unless failure context takes priority. *)
             let phase, runtime_id = keeper_runtime_parts row in
             let phase_width = Message_layout.display_width phase in
             if phase_width >= width then fit_width (keeper_runtime_label runtime) width
             else
               fit_width
                 (phase ^ fit_runtime_id (width - phase_width) runtime_id)
                 width)
      ^ Ansi.reset

(* One activation mode and the sandbox declaration from the roster row. The
   cell fills the whole flags field, so the columns to its right line up with
   their header. *)
(* Without a runtime the cell holds one mark at its left, the reason there are
   no letters (RFC tui-one-screen-grammar 5.6, 6.4): [—] the roster loaded and
   has no fiber for the keeper, [◌] the roster was not read, [✕] its record
   could not be read. The mark and its blanks fill the same six cells the two
   letters do. *)
let keeper_flag_cell (liveness : Keeper_control.liveness) =
  let gap = String.make Render_schedule.keeper_flags_gap ' ' in
  let lone tone mark = tone ^ mark ^ gap ^ " " ^ Ansi.reset in
  match liveness with
  | Keeper_control.Absent -> lone (Theme.recede ()) Masc_tui_theme.Glyph.no_value
  | Keeper_control.Unobserved ->
      lone (Theme.recede ()) (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread)
  | Keeper_control.Invalid _ ->
      lone (Theme.status_tone Masc_tui_value.Mark.Failed)
        (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed)
  | Keeper_control.Present row ->
      let module Mark = Masc_tui_keeper_mark in
      let sandbox =
        match Mark.sandbox_of_profile row.kr_sandbox_profile, row.kr_sandbox_profile with
        | Some (Mark.Docker as known), _ ->
          (Theme.accent ()) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Micro_vm as known), _ ->
          (Theme.category Theme.Slot_2) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Remote_ssh as known), _ ->
          (Theme.category Theme.Slot_1) ^ Mark.sandbox_letter known ^ Ansi.reset
        | None, other when String.length other > 0 ->
          (Theme.warn ()) ^ String.uppercase_ascii (String.sub other 0 1) ^ Ansi.reset
        | None, _ -> Theme.recede () ^ "?" ^ Ansi.reset
      in
      Mark.activation_letter row.kr_activation_mode ^ gap ^ sandbox

let keeper_activity_word ~ko (activity : Keeper_list_model.activity) =
  let text korean english = if ko then korean else english in
  match activity with
  | Held_call -> text "승인 대기" "held call"
  | Question -> text "답변 대기" "question"
  | Confirmation -> text "확인 대기" "confirm"
  | Attempt_failed -> text "시도 실패" "try failed"
  | Preparing -> text "준비 중" "preparing"
  | Streaming -> text "응답 중" "streaming"
  | Running -> text "실행 중" "running"
  | Async_working count -> text (Printf.sprintf "별도 실행 %d" count) (Printf.sprintf "async %d" count)
  | Deferred -> text "실행 보류" "deferred"
  | Tool_waiting -> text "도구 대기" "tool wait"
  | Model_waiting -> text "모델 대기" "model wait"
  | Delegate_result -> text "위임 결과" "result in"
  | Verifying -> text "검증 대기" "verify"
  | External_waiting -> text "외부 대기" "external"
  | Idle -> text "대기 중" "idle"
  | Paused -> text "일시정지" "paused"
  | Offline -> text "오프라인" "offline"
  (* An activity that was not read has no word: the not-read-yet mark says it
     (RFC tui-one-screen-grammar §6.4), and the row's detail says why. *)
  | Unknown -> ""

(* The row's activity word. An offline Keeper that starts on its own wears the
   caution mark, and its word says why, in the NOW cell's ten cells. *)
let keeper_row_activity_word ~ko (row : Keeper_list_model.row) =
  if Masc_tui_keeper_mark.offline_unexpectedly row then (if ko then "자율 꺼짐" else "auto off")
  else keeper_activity_word ~ko (Keeper_list_model.primary_activity_of_row row)

(* The row's activity colour is its mark's (RFC tui-one-screen-grammar §7.2). *)
let keeper_activity_style (row : Keeper_list_model.row) =
  match Masc_tui_keeper_mark.row_activity_mark row with
  | Some mark -> Theme.status_tone mark
  | None -> Theme.recede ()

let keeper_badge_text ~ko (badge : Keeper_list_model.badge) =
  let glyph = Masc_tui_keeper_mark.badge_glyph badge in
  let marked korean english = glyph ^ " " ^ if ko then korean else english in
  match badge with
  | Badge_read_error -> marked "조회 실패" "read error"
  | Badge_waiting_unavailable -> marked "대기 목록 조회 불가" "waiting unavailable"
  | Badge_async { running; ownership_unknown } ->
      let unowned = ownership_unknown > 0 in
      marked
        (Printf.sprintf "별도 실행 %d%s" running
           (if unowned then Printf.sprintf " (주인 모름 %d)" ownership_unknown else ""))
        (Printf.sprintf "async %d%s" running
           (if unowned then Printf.sprintf " (%d owner?)" ownership_unknown else ""))
  | Badge_async_queued count ->
      marked (Printf.sprintf "실행 대기 %d" count) (Printf.sprintf "queued %d" count)
  | Badge_async_cancelling count ->
      marked (Printf.sprintf "취소 중 %d" count) (Printf.sprintf "cancelling %d" count)
  | Badge_delegate -> marked "위임 결과" "delegate result"
  | Badge_verification -> marked "검증 대기" "verify"
  | Badge_schedule -> marked "일정" "schedule"
  | Badge_quota_spent -> marked "한도 소진" "quota spent"

(* Between two pieces of DETAIL. *)
let detail_separator = " · "

let keeper_task_detail ?tasks ~ko (row : Keeper_list_model.row) =
  let task_word = if ko then "작업 " else "task " in
  match row.task with
  | Some task ->
      let title = Terminal_text.single_line task.Tui_decode.title in
      let id = Terminal_text.single_line task.Tui_decode.id in
      Some (task_word ^ if String.equal (String.trim title) "" then id else title)
  | None -> (
      match row.keeper.Tui_decode.k_activity with
      | Some activity ->
          Option.map
            (fun id ->
              let label =
                match tasks with
                | Some list ->
                    (match
                       List.find_opt
                         (fun (t : Tui_decode.task) -> String.equal t.id id)
                         list
                     with
                     | Some t when not (String.equal (String.trim t.title) "") ->
                         Terminal_text.single_line t.title
                     | Some _ | None -> Terminal_text.single_line id)
                | None -> Terminal_text.single_line id
              in
              task_word ^ label)
            activity.Tui_decode.k_current_task_id
      | None -> Some (if ko then "작업 보고 없음" else "task not reported"))

let schedule_title_for_id (schedules : schedule_snapshot option) schedule_id =
  match schedules with
  | None -> None
  | Some snapshot ->
      let found =
        List.find_opt
          (fun (row : schedule_row) -> String.equal row.sch_schedule_id schedule_id)
          snapshot.scs_rows
      in
      Option.bind found (fun (row : schedule_row) ->
          match row.sch_payload_summary with
          | Some summary when not (String.equal (String.trim summary) "") ->
              Some (Terminal_text.single_line summary)
          | Some _ | None ->
              if not (String.equal (String.trim row.sch_recurrence_summary) "") then
                Some (Terminal_text.single_line row.sch_recurrence_summary)
              else None)

let clean_schedule_wait_text ?schedules ?now ~ko (item : Tui_decode.waiting_item) text =
  let prefix_sep = " · sched-" in
  let sep_len = String.length prefix_sep in
  let find_sched_sep s =
    let len = String.length s in
    let rec scan i =
      if i + sep_len > len then None
      else if String.sub s i sep_len = prefix_sep then Some i
      else scan (i + 1)
    in
    scan 0
  in
  match find_sched_sep text with
  | None -> text
  | Some idx ->
      let head = String.sub text 0 idx in
      let sched_id = String.sub text (idx + 4) (String.length text - idx - 4) in
      (match schedule_title_for_id schedules sched_id with
       | Some title -> head ^ " · " ^ title
       | None ->
           (match item.kwi_due_at with
            | Some at when Float.is_finite at ->
                let now_val = match now with Some t -> t | None -> Unix.gettimeofday () in
                head ^ " · "
                ^ Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute
                    ~now:now_val at
            | Some _ | None ->
                if String.equal (String.trim head) "" then
                  if ko then "예약 실행" else "scheduled wake"
                else head))

let keeper_waiting_item_text ?schedules ?now ?(ko = false) (item : Tui_decode.waiting_item) =
  let raw =
    Terminal_text.single_line
      (if not (String.equal (String.trim item.kwi_what) "") then item.kwi_what
       else if not (String.equal (String.trim item.kwi_next_action) "") then item.kwi_next_action
       else item.kwi_waiting_on)
  in
  clean_schedule_wait_text ?schedules ?now ~ko item raw

(* The reasons the server gave for each source the fleet waiting read could
   not observe. The Plain header and the axis views say the same thing. *)
let keeper_waiting_failure_reasons ~ko errors =
  List.map
    (function
      | Keeper_list_model.Failure_sentence sentence -> Terminal_text.single_line sentence
      | Keeper_list_model.Failure_next_action action ->
          (if ko then "다음 조치: " else "next action: ") ^ Terminal_text.single_line action
      | Keeper_list_model.Failure_unstated -> if ko then "원인 미기록" else "reason not stated")
    (Keeper_list_model.waiting_failure_reasons errors)

let keeper_waiting_detail ?schedules ?now ~ko (row : Keeper_list_model.row) =
  match row.waiting with
  | Keeper_list_model.Waiting_observed
      { Tui_decode.kwr_waiting_heads = (first :: _ as items); kwr_waiting_count; _ } ->
      (* A delegate result's operator sentence includes the other Keeper and
         its outcome. Do not hide that behind an earlier scheduled wake. *)
      let item =
        match List.find_opt
            (fun item -> item.Tui_decode.kwi_wake_producer = Tui_decode.Wake_keeper_delegate)
            items with
        | Some result -> result
        | None -> first
      in
      let others = kwr_waiting_count - 1 in
      Some (keeper_waiting_item_text ?schedules ?now ~ko item
        ^ (if others > 0 then " (" ^ Masc_tui_value.Count.more ~ko others ^ ")"
           else ""))
  | Keeper_list_model.Waiting_observed { kwr_waiting_heads = []; _ }
  | Keeper_list_model.Waiting_unobserved | Keeper_list_model.Waiting_unavailable -> None

(* The rest of the path the Keeper's next dispatch takes, for a Keeper whose
   phase runs turns. Matches [Tui_decode.keeper_path_rest] with no wildcards.
   [Stated_by_provider] vs [Bounded_by_masc] distinguishes whether the reset
   time came from the provider or is MASC's upper bound.
   A reset time reads as a countdown ([Masc_tui_value.Ongoing.until]); one
   already in the past is omitted. *)
type path_rest =
  | Path_serving of string  (* The runtime the next dispatch goes to. *)
  | Path_resting of string  (* The rest the next dispatch waits out. *)
  | Path_unread of string  (* The rest did not read. *)

let keeper_path_rest ~ko ?now (row : Keeper_list_model.row) =
  match row.reading.Keeper_control.liveness with
  | Keeper_control.Present runtime
    when Tui_decode.keeper_phase_executes_turns runtime.Tui_decode.kr_phase ->
      (match runtime.Tui_decode.kr_runtime_path_rest with
       | Ok None -> None
       | Ok (Some (Tui_decode.Path_rest_serving { runtime_id })) ->
           Some (Path_serving (Terminal_text.single_line runtime_id))
       | Ok (Some (Tui_decode.Path_rest_resting { runtime_id; release_at; release_basis })) ->
           let now_val = match now with Some t -> t | None -> Unix.gettimeofday () in
           let time_clause =
             if release_at > now_val then " ~" ^ Masc_tui_value.Ongoing.until ~now:now_val release_at
             else ""
           in
           let basis_word =
             match release_basis with
             | Tui_decode.Stated_by_provider -> if ko then "제공자" else "provider"
             | Tui_decode.Bounded_by_masc -> if ko then "상한" else "bound"
           in
           Some
             (Path_resting
                (Printf.sprintf (if ko then "쉬는 중%s (%s · %s)" else "resting%s (%s · %s)")
                   time_clause
                   (Terminal_text.single_line runtime_id)
                   basis_word))
       | Error detail ->
           Some
             (Path_unread
                ((if ko then "쉼 조회 실패: " else "rest read failed: ")
                 ^ Terminal_text.single_line detail)))
  | Keeper_control.Present _ | Keeper_control.Absent | Keeper_control.Unobserved
  | Keeper_control.Invalid _ -> None

(* The last piece of DETAIL, so right reads as next. The runtime that serves
   the next dispatch is named only after a failed turn ([Trail_failed]), and
   then, like a rest, behind the next mark. *)
let keeper_next_text ~ko ?now (row : Keeper_list_model.row) =
  let after_failure () =
    match Keeper_list_model.trail_of_row row with
    | Keeper_trail.Trail_failed _ -> true
    | Keeper_trail.Trail_sound -> false
  in
  let marked text = Masc_tui_keeper_mark.axis_next_glyph ^ " " ^ text in
  match keeper_path_rest ~ko ?now row with
  | None -> None
  | Some (Path_serving runtime_id) -> if after_failure () then Some (marked runtime_id) else None
  | Some (Path_resting text) -> Some (if after_failure () then marked text else text)
  | Some (Path_unread text) -> Some text

let keeper_approval_text ~ko (approval : Tui_decode.keeper_tool_approval) =
  (if ko then "승인 대기 " else "hold ") ^ Terminal_text.single_line approval.kta_tool
  ^ detail_separator ^ Terminal_text.single_line approval.kta_question

let keeper_questions_text ~ko count =
  if ko then Printf.sprintf "답을 기다리는 질문 %d건" count
  else Masc_tui_message_layout.count_noun count "question" ^ " awaiting you"

let keeper_detail_text ?schedules ?tasks ~ko ?now (row : Keeper_list_model.row) =
  let health =
    Option.map
      (fun word -> (if ko then "상태 " else "health ") ^ word)
      (keeper_health_deviation_word ~ko row.reading)
  in
  List.map (keeper_badge_text ~ko) (Keeper_list_model.badges_of_row row)
  @ List.filter_map Fun.id
      [ Option.map (keeper_approval_text ~ko) row.approval
      ; (if row.open_questions > 0 then Some (keeper_questions_text ~ko row.open_questions) else None)
      ; keeper_waiting_detail ?schedules ?now ~ko row; keeper_task_detail ?tasks ~ko row; health
      ; keeper_next_text ~ko ?now row ]
  |> String.concat detail_separator

(* The DETAIL cell. When the RUNTIME column is not drawn, the sentence about
   the past leads this cell in the warning colour and the rest stays receded.
   The text is fitted as plain text, so a cut mark takes the colour of the text
   it cuts. A sentence that fills the cell is fitted together with the rest, so
   the rest it pushes out is still marked by the cut. *)
(* Compact inline live context mini-meter for a Keeper list row (btop proc
   style), shown only when live context is already measured for this Keeper. *)
let keeper_row_context_chip (state : state) (row : Keeper_list_model.row) =
  match row.keeper.k_identity with
  | Error _ -> None
  | Ok _ ->
      (match live_context_view state row.keeper with
       | Masc_tui_fetched.Ready obs | Masc_tui_fetched.Stale (obs, _) ->
           (match Observation_layout.context_summary obs with
            | Observation_layout.Context_measured { ratio; _ } ->
                let value = Observation_layout.percentage_tenths ratio in
                let max_value = Observation_layout.percentage_tenths_full in
                let pct = (value + 5) / 10 in
                let scale = Masc_tui_chart.Declared_limit (Theme.paint ()) in
                let bar =
                  Masc_tui_chart.meter_bar ~width:5 ~value ~max_value ~scale
                    ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
                in
                Some (Printf.sprintf "%s %3d%%" bar pct)
            | Observation_layout.Context_partial _
            | Observation_layout.Context_unavailable _ -> None)
       | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
       | Masc_tui_fetched.Failed _ -> None)

let keeper_detail_cell ?schedules ?tasks ~ko ?now ?context_chip ~width ~failure_context row =
  let rest = keeper_detail_text ?schedules ?tasks ~ko ?now row in
  match failure_context with
  | None ->
      (match context_chip with
       | Some chip when width >= 14 ->
           let chip_cells = Message_layout.display_width chip in
           let tail = if String.equal rest "" then "" else detail_separator ^ rest in
           if chip_cells >= width then fit_width chip width
           else
             chip ^ Theme.recede () ^ fit_width tail (width - chip_cells) ^ Ansi.reset
       | Some _ | None -> Theme.recede () ^ fit_width rest width ^ Ansi.reset)
  | Some sentence ->
      let sentence_cells = Message_layout.display_width sentence in
      let tail = if String.equal rest "" then "" else detail_separator ^ rest in
      if sentence_cells >= width then
        Theme.warn () ^ fit_width (sentence ^ tail) width ^ Ansi.reset
      else
        Theme.warn () ^ sentence ^ Theme.recede ()
        ^ fit_width tail (width - sentence_cells)
        ^ Ansi.reset

(* The list view's header words, in the screen language (RFC
   tui-one-screen-grammar 7.1). Each Korean word fits the cells its English
   word measures the column by. *)
let keeper_flags_word ~ko = if ko then "모드 S" else Render_schedule.keeper_flags_header
let keeper_age_word ~ko = if ko then "경과" else Masc_tui_keeper_mark.age_header

let keeper_column_header ~ko (columns : Render_schedule.keeper_columns) =
  let say korean english = if ko then korean else english in
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Message_layout.fit_width (say "키퍼" "KEEPER") columns.kcol_name
    ; " "
    ; Message_layout.fit_width (say "현재" Masc_tui_keeper_mark.now_header)
        Render_schedule.keeper_status_width
    ; (if columns.kcol_show_flags then
         " "
         ^ Message_layout.fit_width (keeper_flags_word ~ko)
             Render_schedule.keeper_flags_width
       else "")
    ; " "
      ^ Message_layout.pad_left (keeper_age_word ~ko)
          Render_schedule.keeper_last_turn_width
    ; (if columns.kcol_show_runtime then
         " " ^ fit_width (say "단계 / 런타임" "LIFECYCLE / RUNTIME") columns.kcol_runtime
       else "")
    ; (if columns.kcol_show_detail then
         " " ^ Message_layout.fit_width (say "내용" "DETAIL") columns.kcol_task
       else "")
    ]

let keeper_row_runtime (row : Keeper_list_model.row) =
  match row.reading.Keeper_control.liveness with
  | Keeper_control.Present runtime -> Some runtime
  | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None

let keeper_row_marker ~selected = if selected then "\xe2\x80\xba " (* ›  *) else "  "

let keeper_row_name ~width ~yolo (row : Keeper_list_model.row) =
  let name =
    Message_layout.fit_middle width (Terminal_text.single_line row.keeper.Tui_decode.k_name)
  in
  if yolo then Theme.bad () ^ name ^ Ansi.reset else name

(* The NOW cell: the activity's mark and word, or the receipt's operator
   disposition where nothing on the row is newer than the receipt. *)
let keeper_now_cell ~ko ?(padded = true) (row : Keeper_list_model.row) =
  let activity = Keeper_list_model.primary_activity_of_row row in
  let runtime = keeper_row_runtime row in
  let operator_disposition =
    match runtime with
    | Some { kr_operator_disposition = Ok (Some (disp, _)); _ }
      when Masc.Keeper_execution_receipt.needs_operator_broadcast disp
           && Masc_tui_keeper_mark.shows_operator_disposition ~activity ->
        Some disp
    | Some { kr_operator_disposition = Ok (Some _); _ } -> None
    | Some { kr_operator_disposition = Ok None; _ } -> None
    | Some { kr_operator_disposition = Error _; _ } -> None
    | None -> None
  in
  let status_color =
    match operator_disposition with
    | Some _ -> Theme.status_tone Masc_tui_value.Mark.Yours
    | None -> keeper_activity_style row
  in
  let glyph =
    match operator_disposition with
    | Some _ -> Masc_tui_keeper_mark.activity_glyph Held_call
    | None -> Masc_tui_keeper_mark.row_activity_glyph row
  in
  let status_word =
    match operator_disposition with
    | Some disp -> Masc_tui_keeper_mark.operator_disposition_word ~ko disp
    | None -> keeper_row_activity_word ~ko row
  in
  status_color ^ glyph ^ " "
  ^ (if padded then Message_layout.fit_width status_word (Render_schedule.keeper_status_width - 2) else status_word)
  ^ Ansi.reset

let keeper_row_content ?schedules ?tasks ~ko ?context_chip ~(columns : Render_schedule.keeper_columns)
    ~now ~yolo ~selected (row : Keeper_list_model.row) =
  let runtime = keeper_row_runtime row in
  let failure_context =
    keeper_row_trail_sentence ~ko ~age:(keeper_trail_age ~now) row
  in
  let age =
    match row.last_activity_at with
    | Some since -> Option.value (Message_layout.age_text ~now ~since)
        ~default:Masc_tui_theme.Glyph.no_value
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let prefix = keeper_row_marker ~selected
    ^ keeper_row_name ~width:columns.kcol_name ~yolo row ^ " " in
  let now_cell = keeper_now_cell ~ko row in
  String.concat ""
    [ prefix
    ; now_cell
    ; (if columns.kcol_show_flags then
         " " ^ keeper_flag_cell row.reading.Keeper_control.liveness
       else "")
    ; " " ^ Theme.recede ()
      ^ Message_layout.pad_left age Render_schedule.keeper_last_turn_width
      ^ Ansi.reset
    ; (if columns.kcol_show_runtime then
         " " ^ keeper_runtime_cell ~width:columns.kcol_runtime ?failure_context runtime
       else "")
    ; (if columns.kcol_show_detail then
         " "
         ^ keeper_detail_cell ?schedules ?tasks ~ko ~now ?context_chip ~width:columns.kcol_task
             ~failure_context:
               (Render_schedule.keeper_failure_context_for_detail
                  ~show_runtime:columns.kcol_show_runtime failure_context)
             row
       else "")
    ]

let format_attempt_node (a : Masc_tui_keeper_trail.attempt) =
  let fault_clause =
    match a.fault with
    | Some w when not (String.equal w "") -> " · " ^ w
    | _ -> ""
  in
  let mark = Masc_tui_keeper_mark.attempt_glyph in
  mark ^ " " ^ Terminal_text.single_line a.runtime_id ^ fault_clause

let render_attempt_chain ~max_cells (attempts : Masc_tui_keeper_trail.attempt list) =
  match attempts with
  | [] -> None
  | _ ->
      let sep = " › " in
      let sep_len = Message_layout.display_width sep in
      let rev_attempts = List.rev attempts in
      let rec fit acc omitted remaining_cells = function
        | [] -> (acc, omitted)
        | a :: rest ->
            let node = format_attempt_node a in
            let node_cells = Message_layout.display_width node in
            let cost = if acc = [] then node_cells else node_cells + sep_len in
            let omit_cost =
              if rest <> [] then
                Message_layout.display_width (Printf.sprintf "+%d › " (List.length rest))
              else 0
            in
            if remaining_cells >= cost + omit_cost then
              fit (node :: acc) omitted (remaining_cells - cost) rest
            else
              (acc, List.length (a :: rest))
      in
      let fitted, omitted_count = fit [] 0 max_cells rev_attempts in
      if fitted = [] then None
      else
        let prefix =
          if omitted_count > 0 then Printf.sprintf "+%d%s" omitted_count sep else ""
        in
        let chain = prefix ^ String.concat sep fitted in
        Some (Theme.warn () ^ chain ^ Ansi.reset)

(* The columns the DETAIL text keeps. The attempt chain leaves them after its
   separator, and the axis cells on the right leave them before the first
   cell. *)
let detail_floor_cells = 10

let style_axis_cell (cell : Masc_tui_keeper_axis_cell.t) =
  let style =
    match cell.tone with
    | Masc_tui_keeper_axis_cell.Quiet -> Theme.recede ()
    | Masc_tui_keeper_axis_cell.Attention -> Theme.warn ()
    | Masc_tui_keeper_axis_cell.Failure -> Theme.bad ()
  in
  style ^ cell.text ^ Ansi.reset
;;

(* A second line opens under the name, and its pieces stand this far apart. *)
let secondary_indent_cells = Render_schedule.keeper_marker_width
let secondary_separator = "  ·  "

let keeper_secondary_row_content ?schedules ?tasks ~ko ?now ?(cells = []) ~inner (row : Keeper_list_model.row) =
  let indent_cells = secondary_indent_cells in
  let available = max 0 (inner - indent_cells) in
  let attempts = Masc_tui_keeper_trail.attempts_of_runtime (keeper_row_runtime row) in
  let detail =
    match keeper_detail_text ?schedules ?tasks ~ko ?now row with
    | "" -> Masc_tui_theme.Glyph.no_value
    | text -> text
  in
  let has_detail = not (String.equal detail Masc_tui_theme.Glyph.no_value) in
  (* A row with DETAIL text leaves it a floor of columns before the cells on
     the right take theirs. The cells that do not fit are the last ones. *)
  let { Masc_tui_keeper_axis_cell.drawn = fitting_cells
      ; cells_width
      ; left_width = detail_space
      }
    =
    Masc_tui_keeper_axis_cell.fit
      ~available
      ~detail_floor:(if has_detail then Some detail_floor_cells else None)
      ~width:(fun (cell : Masc_tui_keeper_axis_cell.t) ->
        Message_layout.display_width cell.text)
      cells
  in
  let sep = secondary_separator in
  let sep_cells = Message_layout.display_width sep in
  (* The chain drops its older attempts to leave the detail a floor of cells.
     Only when the last attempt does not fit beside that floor does the chain
     take the whole row, and the detail is left out. *)
  let left_text =
    let beside_detail =
      if has_detail then
        render_attempt_chain
          ~max_cells:(detail_space - sep_cells - detail_floor_cells)
          attempts
      else None
    in
    match beside_detail with
    | Some chain ->
        let chain_cells = Message_layout.display_width chain in
        chain ^ Theme.recede () ^ sep
        ^ fit_width detail (detail_space - chain_cells - sep_cells)
        ^ Ansi.reset
    | None -> (
        match render_attempt_chain ~max_cells:detail_space attempts with
        | Some chain -> fit_width chain detail_space
        | None -> Theme.recede () ^ fit_width detail detail_space ^ Ansi.reset)
  in
  let right_text =
    match fitting_cells with
    | [] -> ""
    | cs ->
        let styled = List.map style_axis_cell cs in
        String.concat Masc_tui_keeper_axis_cell.separator styled
  in
  let body =
    if right_text = "" then left_text
    else
      let left_w = Message_layout.display_width left_text in
      let pad = max 1 (available - left_w - cells_width) in
      left_text ^ String.make pad ' ' ^ right_text
  in
  String.make indent_cells ' ' ^ body
;;

module Axis_row = Masc_tui_keeper_axis_row
module Memory_reading = Masc_tui_keeper_memory_reading

let keeper_memory_reading state (row : Keeper_list_model.row) =
  Memory_reading.find (Masc_tui_keeper_axis.memory_index state)
    ~keeper_name:row.keeper.Tui_decode.k_name

(* The lag bars and levels are drawn against the listed Keeper furthest
   behind, so a Keeper the snapshot still has a row for but the roster no
   longer lists does not set the scale. *)
let axis_peak_lag state rows = Memory_reading.peak_lag (List.map (keeper_memory_reading state) rows)

(* The fact counts are drawn against the listed Keeper with the most facts. *)
let axis_peak_facts state rows =
  List.fold_left
    (fun peak row ->
      match Memory_reading.age_bins (keeper_memory_reading state row) with
      | Memory_reading.Measured bins -> max peak (Masc.Keeper_memory_age_bins.total bins)
      | Memory_reading.Unmeasured | Memory_reading.No_snapshot | Memory_reading.Snapshot_unknown
      | Memory_reading.Row_absent | Memory_reading.Row_refused -> peak)
    0 rows

(* The grid of the views (RFC-0515 §2.4.1): the columns stand in the same
   cells on every row, fixed from the right edge, and the name takes what is
   left. Each piece below is as wide as its column. *)
module Grid = Masc_tui_keeper_grid
module Keeper_mark = Masc_tui_keeper_mark

(* Quiet separators frame the current activity without painting a full-height
   pane behind every row. Status text keeps its own semantic colour. *)
let grid_band now_text =
  let line = Theme.recede () ^ Keeper_mark.grid_now_line ^ Ansi.reset in
  line ^ " " ^ now_text ^ " " ^ line

let grid_blank_now = String.make Grid.now_cells ' '

type grid_cells =
  { gutter : string
  ; name : string
  ; pulse : string
  ; now_cell : string
  ; strip : string
  ; due : string
  ; right : string
  }

let grid_line (grid : Grid.t) cells =
  let side = grid.side_cells > 0 in
  let prefix = String.concat ""
    [ cells.gutter; cells.name; (if side then " " ^ cells.pulse else ""); " " ] in
  String.concat ""
    [ prefix
    ; grid_band cells.now_cell
    ; " "
    ; (if side then cells.strip ^ " " else "")
    ; cells.due
    ; (if grid.mem_cells > 0 then " " ^ cells.right else "")
    ]

(* The cells before the band: the gutter, the name and the pulse. *)
let grid_lead_cells (grid : Grid.t) =
  Grid.gutter_cells + grid.name_cells + if grid.side_cells > 0 then 1 + grid.side_cells else 0

(* The cells after the band: the strip, the due column and the right column. *)
let grid_tail_cells (grid : Grid.t) =
  (if grid.side_cells > 0 then Grid.strip_cells grid + 1 else 0)
  + Grid.due_cells
  + if grid.mem_cells > 0 then 1 + grid.mem_cells else 0

(* A recovered Keeper is sound now, so it draws the success colour (RFC
   tui-one-screen-grammar section 7.2: one colour per state). Colour alone
   does not tell it from one that never failed: only the By_cause view's mark
   and its Recovered group say it recovered, and the other views draw both
   with the same ok mark. *)
let grid_gutter_style = function
  | Grid.Failing { resting = false } -> Theme.warn ()
  | Grid.Failing { resting = true } | Grid.Paused | Grid.Other -> Theme.recede ()
  | Grid.Recovered | Grid.Sound -> Theme.ok ()

let grid_gutter ?(selected = false) view verdict =
  (if selected then "› " else "  ") ^ grid_gutter_style verdict ^ Ansi.bold
  ^ Grid.mark view verdict ^ Ansi.reset ^ " "

let grid_name (grid : Grid.t) ~yolo verdict name =
  let text = fit_width (Terminal_text.single_line name) grid.name_cells in
  if yolo then Theme.bad () ^ text ^ Ansi.reset
  else
    match verdict with
    | Grid.Paused -> Theme.recede () ^ text ^ Ansi.reset
    | Grid.Failing _ | Grid.Recovered | Grid.Sound | Grid.Other -> text

let grid_repeat count mark = String.concat "" (List.init (max 0 count) (fun _ -> mark))

(* Failures remain prominent; successful history is secondary to current work. *)
let grid_half_hour_style = function
  | Masc_tui_keeper_pulse.Half_hour_failed | Masc_tui_keeper_pulse.Half_hour_failed_and_ok ->
      Theme.warn ()
  | Masc_tui_keeper_pulse.Half_hour_ok -> Theme.recede ()
  | Masc_tui_keeper_pulse.Half_hour_quiet | Masc_tui_keeper_pulse.Half_hour_unknown ->
      Theme.recede ()

(* One mark per half hour of the column, the now slot on the right. *)
let grid_half_hour_pulse state (grid : Grid.t) ~now pulse =
  let slots = Masc_tui_keeper_pulse.half_hours ~now ~count:grid.side_cells pulse in
  if grid.side_cells = 0 then ""
  else if List.for_all (function
    | Masc_tui_keeper_pulse.Half_hour_unknown -> true
    | Half_hour_quiet | Half_hour_ok | Half_hour_failed | Half_hour_failed_and_ok -> false) slots then
    Masc_tui_keeper_strip.history_unknown_label ~cells:grid.side_cells
  else String.concat ""
    (List.map
       (fun half_hour ->
         let mark = match half_hour with
           | Masc_tui_keeper_pulse.Half_hour_quiet -> " "
           | Half_hour_unknown -> Keeper_mark.grid_unknown_range_mark
           | Half_hour_ok | Half_hour_failed | Half_hour_failed_and_ok ->
               Masc_tui_keeper_pulse.half_hour_mark half_hour in
         grid_half_hour_style half_hour ^ mark
         ^ Ansi.reset)
       slots)

let grid_wake_window state ~style slots =
  let ko = state.ui_language = Lang_ko in
  match state.keeper_list_view with
  | Keeper_list_model.By_state -> Masc_tui_keeper_strip.wake_summary ~ko slots
  | Plain | By_cause | By_time | By_memory | By_age | By_runtime | Day_wall ->
      Masc_tui_keeper_strip.wake_strip ~style slots

(* Scheduled wakes per half hour, the now slot first. Unknown windows get
   one label; the shared renderer keeps mixed unknown and empty slots apart. *)
let grid_wake_strip state (grid : Grid.t) ~now ~keeper_name =
  grid_wake_window state
    ~style:Masc_tui_keeper_strip.Keeper_wakes
    (Masc_tui_keeper_axis.wake_strip state ~now ~ahead:(Grid.strip_cells grid - 1)
       ~keeper_name)

let grid_due ~ko ~now verdict next_run =
  let style =
    match next_run, verdict with
    | (Masc_tui_keeper_next_run.Late_since _ | Masc_tui_keeper_next_run.Held_current _), _ ->
        Theme.warn ()
    | Masc_tui_keeper_next_run.Scheduled_at _, Grid.Paused -> Theme.recede ()
    | Masc_tui_keeper_next_run.Scheduled_at _, (Grid.Failing _ | Grid.Recovered | Grid.Sound | Grid.Other) ->
        Theme.info ()
    | ( ( Masc_tui_keeper_next_run.No_schedule | Masc_tui_keeper_next_run.Held_as_of _
        | Masc_tui_keeper_next_run.Not_before _ | Masc_tui_keeper_next_run.Unknown ), _ ) ->
        Theme.recede ()
  in
  style
  ^ fit_width (Grid.due_text ~ko ~now ~localtime:Unix.localtime next_run) Grid.due_cells
  ^ Ansi.reset

(* The count sits on the right of its column, then a space and its level. *)
let grid_level_cells = 2

(* The right column of the activity columns: the librarian's unread turns and
   their level against [peak_lag]. A reading without a measured lag draws the
   word its lag cell already uses. *)
let grid_lag_cell (grid : Grid.t) ~peak_lag memory =
  let fitted (cell : Masc_tui_keeper_axis_cell.t) =
    style_axis_cell { cell with text = Message_layout.pad_left cell.text grid.mem_cells }
  in
  match memory with
  | Memory_reading.Row { lag = Memory_reading.Lag turns; _ } ->
      fitted
        { Masc_tui_keeper_axis_cell.text =
            Message_layout.pad_left (string_of_int turns) (grid.mem_cells - grid_level_cells)
            ^ " " ^ Grid.level_glyph ~peak:peak_lag turns
        ; tone = (if turns > 0 then Masc_tui_keeper_axis_cell.Attention else Masc_tui_keeper_axis_cell.Quiet)
        }
  | Memory_reading.Row { lag = Memory_reading.Lag_unmeasured; _ } | Memory_reading.Unknown
  | Memory_reading.No_row | Memory_reading.Refused _ -> (
      match Memory_reading.lag_cell memory with
      | Some cell -> fitted cell
      | None -> String.make grid.mem_cells ' ')

let grid_fitted cells (cell : Masc_tui_keeper_axis_cell.t) =
  style_axis_cell { cell with text = fit_width cell.text cells }

let grid_quiet text = { Masc_tui_keeper_axis_cell.text; tone = Masc_tui_keeper_axis_cell.Quiet }

(* The memory view's ● cell: how the librarian's last pass ended. A row with
   no pass is one this server process has not seen a pass for yet, not a
   Keeper without a librarian, so it keeps the unmeasured mark. *)
let grid_librarian ~ko memory =
  grid_fitted Grid.now_cells
    (match Memory_reading.pass_end memory with
     | Memory_reading.No_snapshot | Memory_reading.Row_absent ->
         grid_quiet (Keeper_mark.grid_word ~ko Keeper_mark.No_data_word)
     | Memory_reading.Measured _ | Memory_reading.Unmeasured | Memory_reading.Snapshot_unknown
     | Memory_reading.Row_refused -> Memory_reading.pass_cell ~ko memory)

(* The strip column of the memory and age views: a sleek proportional rule bar
   with the exact unread-turn count beside it. Keeps normal lag calm (receded)
   and reserves warning color for a stalled gap. *)
let grid_lag_bar (grid : Grid.t) ~peak_lag memory =
  let cells = Grid.strip_cells grid in
  let ground count = Theme.recede () ^ grid_repeat count Keeper_mark.grid_dot_mark ^ Ansi.reset in
  match memory with
  | Memory_reading.Row { lag = Memory_reading.Lag turns; gap; _ } ->
      (* Reserve a table-wide constant label width from [peak_lag] so every row
         shares the same bar track length, bar lengths stay strictly monotonic
         with unread turn count, and narrow strips never overflow [cells]. *)
      let peak_w =
        if peak_lag <= 0 then 0
        else 1 + Message_layout.display_width (Masc_tui_chart.format_compact_num peak_lag)
      in
      let label_w = if peak_w > 0 && peak_w + 1 <= cells then peak_w else 0 in
      let bar_cells = cells - label_w in
      let filled =
        if bar_cells <= 0 then 0
        else Grid.lag_fill ~cells:bar_cells ~peak:peak_lag turns
      in
      let bar_tone =
        match gap with
        | Memory_reading.Gap _ | Memory_reading.Gap_unmeasured -> Theme.warn ()
        | Memory_reading.No_gap -> Theme.recede ()
      in
      let bar =
        (if filled > 0 then bar_tone ^ grid_repeat filled "\xe2\x94\x81" (* ━ *) ^ Ansi.reset else "")
        ^ ground (max 0 (bar_cells - filled))
      in
      let count_str =
        if label_w = 0 then ""
        else if turns <= 0 then String.make label_w ' '
        else
          let num = Masc_tui_chart.format_compact_num turns in
          let pad = String.make (max 0 (label_w - Message_layout.display_width num)) ' ' in
          bar_tone ^ fit_width (pad ^ num) label_w ^ Ansi.reset
      in
      bar ^ count_str
  | Memory_reading.Row { lag = Memory_reading.Lag_unmeasured; _ } ->
      Theme.recede () ^ Keeper_mark.unknown_mark ^ Ansi.reset ^ ground (cells - 1)
  | Memory_reading.Unknown | Memory_reading.No_row | Memory_reading.Refused _ ->
      String.make cells ' '

(* The memory view's due column: how long ago the last digest succeeded, [—]
   before the first. *)
let grid_digest ~now memory =
  let text =
    match Memory_reading.digest_at memory with
    | Memory_reading.Measured at -> Masc_tui_value.Ongoing.Narrow.since ~now at
    | Memory_reading.Unmeasured -> Masc_tui_theme.Glyph.no_value
    | Memory_reading.No_snapshot | Memory_reading.Snapshot_unknown | Memory_reading.Row_absent
    | Memory_reading.Row_refused -> ""
  in
  Theme.recede () ^ fit_width text Grid.due_cells ^ Ansi.reset

(* The memory view's right column: the atoms requests skip. *)
let grid_gap (grid : Grid.t) memory =
  let text, tone =
    match memory with
    | Memory_reading.Row { gap = Memory_reading.Gap { first_atom; past_last_atom }; _ }
      when past_last_atom > first_atom ->
        Masc_tui_chart.format_compact_num (past_last_atom - first_atom), Theme.warn ()
    | Memory_reading.No_row | Memory_reading.Row { gap = Memory_reading.Gap_unmeasured; _ } ->
        Keeper_mark.unknown_mark, Theme.recede ()
    | Memory_reading.Row { gap = Memory_reading.Gap _ | Memory_reading.No_gap; _ }
    | Memory_reading.Unknown | Memory_reading.Refused _ -> "", Theme.recede ()
  in
  tone ^ Message_layout.pad_left text grid.mem_cells ^ Ansi.reset

module Age_ladder = Masc_tui_keeper_age_ladder

(* A ladder cell takes the colour of the newest bin it adds, as the mock's
   legend reads: under a day the info colour, a day to seven days the row's
   own, older facts recede. *)
let grid_age_group_style = function
  | Age_ladder.Within_day -> Theme.info ()
  | Age_ladder.Within_week -> ""
  | Age_ladder.Past_week -> Theme.recede ()

(* The age view's ladder (§2.4.5): the server's 24 bins added 1, 2 or 4 to a
   cell, oldest on the left, on the right of the pulse column. An empty cell is
   a dot, the others a level against the line's largest cell. A column under
   six cells draws nothing. A Keeper row, a group title and the world row draw
   their ladders the same way. *)
let grid_age_ladder (grid : Grid.t) bins =
  match Age_ladder.merge_of_column grid.side_cells with
  | None -> String.make grid.side_cells ' '
  | Some merge ->
      let cells = Age_ladder.cells merge bins in
      let peak = List.fold_left (fun peak (cell : Age_ladder.cell) -> max peak cell.count) 0 cells in
      String.make (grid.side_cells - List.length cells) ' '
      ^ String.concat ""
          (List.map
             (fun (cell : Age_ladder.cell) ->
               if cell.count = 0 then Theme.recede () ^ Keeper_mark.grid_dot_mark ^ Ansi.reset
               else
                 grid_age_group_style cell.group ^ Grid.level_glyph ~peak cell.count ^ Ansi.reset)
             cells)

let grid_age_ladder_reading (grid : Grid.t) = function
  | Some bins -> grid_age_ladder grid bins
  | None ->
      (match Age_ladder.merge_of_column grid.side_cells with
       | None -> String.make grid.side_cells ' '
       | Some _ -> Theme.recede ()
           ^ Message_layout.pad_left Keeper_mark.unknown_mark grid.side_cells ^ Ansi.reset)

(* The age view's pulse column: the Keeper's ladder, or the word its age cell
   uses when there is none. *)
let grid_fact_ages (grid : Grid.t) memory =
  match Memory_reading.age_bins memory with
  | Memory_reading.Measured bins -> grid_age_ladder grid bins
  | Memory_reading.Unmeasured | Memory_reading.No_snapshot | Memory_reading.Snapshot_unknown
  | Memory_reading.Row_absent | Memory_reading.Row_refused ->
      let cell = Memory_reading.fact_ages_cell memory in
      style_axis_cell { cell with text = Message_layout.pad_left cell.text grid.side_cells }

(* The age view's ● cell: how long ago the memory snapshot was saved. *)
let grid_saved ~ko ~now memory =
  match Memory_reading.updated_at memory with
  | Memory_reading.Measured at ->
      fit_width
        (Keeper_mark.grid_saved_mark ^ " " ^ Masc_tui_value.Ongoing.Narrow.since ~now at)
        Grid.now_cells
  | Memory_reading.No_snapshot | Memory_reading.Row_absent ->
      grid_fitted Grid.now_cells
        (grid_quiet
           (Masc_tui_theme.Glyph.no_value ^ " " ^ Keeper_mark.grid_word ~ko Keeper_mark.No_snapshot_word))
  | Memory_reading.Unmeasured | Memory_reading.Snapshot_unknown | Memory_reading.Row_refused ->
      grid_fitted Grid.now_cells (Memory_reading.updated_cell ~now memory)

(* The age view's due column: the invalidated sources. *)
let grid_stale memory =
  let text =
    match memory with
    | Memory_reading.Row { source_invalidations; _ } when source_invalidations > 0 ->
        Keeper_mark.grid_stale_mark ^ string_of_int source_invalidations
    | Memory_reading.Row _ | Memory_reading.Unknown | Memory_reading.No_row
    | Memory_reading.Refused _ -> ""
  in
  Theme.warn () ^ fit_width text Grid.due_cells ^ Ansi.reset

(* The age view's right column: the fact count and its level against
   [peak_facts]. *)
let grid_facts (grid : Grid.t) ~peak_facts memory =
  match Memory_reading.age_bins memory with
  | Memory_reading.Measured bins ->
      let facts = Masc.Keeper_memory_age_bins.total bins in
      Theme.recede ()
      ^ Message_layout.pad_left (Masc_tui_chart.format_compact_num facts)
          (grid.mem_cells - grid_level_cells)
      ^ " " ^ Grid.level_glyph ~peak:peak_facts facts ^ Ansi.reset
  | Memory_reading.Unmeasured ->
      Theme.recede () ^ Message_layout.pad_left Keeper_mark.unknown_mark grid.mem_cells ^ Ansi.reset
  | Memory_reading.No_snapshot | Memory_reading.Snapshot_unknown | Memory_reading.Row_absent
  | Memory_reading.Row_refused -> String.make grid.mem_cells ' '

let grid_keeper_row state (grid : Grid.t) columns ~view ~peak_lag ~peak_facts ~now ~yolo
    ?(selected = false) (row : Keeper_list_model.row) =
  let runtime = keeper_row_runtime row in
  let verdict = Grid.verdict ~now runtime in
  let keeper_name = row.keeper.Tui_decode.k_name in
  let memory = keeper_memory_reading state row in
  let gutter = grid_gutter ~selected view verdict in
  let name = grid_name grid ~yolo verdict keeper_name in
  let pulse () =
    grid_half_hour_pulse state grid ~now
      (Option.bind runtime (fun runtime -> runtime.Tui_decode.kr_recent_turns))
  in
  grid_line grid
    (match (columns : Axis_row.columns) with
     | Axis_row.Activity_columns ->
         { gutter
         ; name
         ; pulse = pulse ()
         ; now_cell = keeper_now_cell ~ko:(state.ui_language = Lang_ko) row
         ; strip = grid_wake_strip state grid ~now ~keeper_name
         ; due = grid_due ~ko:(state.ui_language = Lang_ko) ~now verdict (Masc_tui_keeper_axis.next_run state ~keeper_name)
         ; right = grid_lag_cell grid ~peak_lag memory
         }
     | Axis_row.Memory_columns ->
         { gutter
         ; name
         ; pulse = pulse ()
         ; now_cell = grid_librarian ~ko:(state.ui_language = Lang_ko) memory
         ; strip = grid_lag_bar grid ~peak_lag memory
         ; due = grid_digest ~now memory
         ; right = grid_gap grid memory
         }
     | Axis_row.Age_columns ->
         { gutter
         ; name
         ; pulse = grid_fact_ages grid memory
         ; now_cell = grid_saved ~ko:(state.ui_language = Lang_ko) ~now memory
         ; strip = grid_lag_bar grid ~peak_lag memory
         ; due = grid_stale memory
         ; right = grid_facts grid ~peak_facts memory
         })

(* The failure line under a failing Keeper of the state and cause views
   (§2.4.6). Under the name: when the failing phase began, or how long ago the
   last failure was when the server recorded no start. *)
let grid_failure_since ~ko ~now ~room (runtime : keeper_runtime option) trail =
  let failing =
    match runtime with
    | None -> Masc_tui_keeper_pulse.Not_failing
    | Some runtime ->
        Masc_tui_keeper_pulse.failing_of_health
          ~health:(Tui_decode.keeper_health_reading runtime.Tui_decode.kr_health)
          ~failing_since:runtime.Tui_decode.kr_failing_since
  in
  match failing, trail with
  | Masc_tui_keeper_pulse.Failing_since at, (Keeper_trail.Trail_failed _ | Keeper_trail.Trail_sound) ->
      let clock = Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now at in
      let worded = Keeper_mark.grid_since_text ~ko clock in
      (* The word goes first, so a cut never leaves a minute that reads as data. *)
      if Message_layout.display_width worded <= room then worded else clock
  | Masc_tui_keeper_pulse.Failing_unrecorded, Keeper_trail.Trail_failed { ended_at = Some at; _ }
    when at <= now ->
      Keeper_mark.grid_ago_text ~ko (Masc_tui_value.Ongoing.since ~now at)
  | ( (Masc_tui_keeper_pulse.Failing_unrecorded | Masc_tui_keeper_pulse.Not_failing)
    , (Keeper_trail.Trail_failed _ | Keeper_trail.Trail_sound) ) -> ""

(* The word for why the failed turn ended: the receipt's cause when it names
   the runtime that ended it, the server's own cause word otherwise. *)
let grid_failure_word ~ko = function
  | Keeper_trail.Trail_failed { walk = Keeper_trail.Walk_ended { cause; _ }; _ } ->
      keeper_cause_group_word ~ko cause
  | Keeper_trail.Trail_failed
      { walk =
          ( Keeper_trail.Walk_no_terminal _ | Keeper_trail.Walk_no_candidate_failure
          | Keeper_trail.Walk_not_captured | Keeper_trail.Walk_unreadable | Keeper_trail.Walk_absent
          | Keeper_trail.Walk_not_applicable )
      ; last = Some cause
      ; ended_at = _
      } -> keeper_failure_cause_word ~ko cause
  | Keeper_trail.Trail_failed { last = None; _ } | Keeper_trail.Trail_sound -> ""

(* In the pulse column: one failed mark per attempt of the failed turn, at most
   [Grid.chain_attempts], then the failure word. *)
let grid_failure_chain ~ko (grid : Grid.t) runtime trail =
  let recede text = Theme.recede () ^ text ^ Ansi.reset in
  let attempts = Masc_tui_keeper_trail.attempts_of_runtime runtime in
  let shown = List.take Grid.chain_attempts attempts in
  let chain =
    match shown with
    | [] -> []
    | _ :: _ ->
        [ String.concat (recede Keeper_mark.grid_chain_link)
            (List.map (fun _ -> Theme.warn () ^ Keeper_mark.attempt_glyph ^ Ansi.reset) shown)
          ^ if List.length attempts > Grid.chain_attempts then recede Keeper_mark.grid_more_mark
            else ""
        ]
  in
  let word =
    match grid_failure_word ~ko trail with
    | "" -> []
    | word -> [ recede word ]
  in
  fit_width (String.concat " " (chain @ word)) grid.side_cells

(* From the strip column on: the runtime the next dispatch takes, or the one
   whose rest it waits out. *)
let grid_next_dispatch ~ko (runtime : keeper_runtime option) =
  match runtime with
  | Some runtime when Tui_decode.keeper_phase_executes_turns runtime.Tui_decode.kr_phase -> (
      match runtime.Tui_decode.kr_runtime_path_rest with
      | Ok (Some (Tui_decode.Path_rest_serving { runtime_id })) ->
          Theme.info () ^ Keeper_mark.axis_next_glyph ^ " " ^ Terminal_text.single_line runtime_id
          ^ Ansi.reset
      | Ok (Some (Tui_decode.Path_rest_resting { runtime_id; release_at = _; release_basis = _ })) ->
          Theme.recede ()
          ^ String.concat " "
              [ Keeper_mark.grid_wait_glyph; Keeper_mark.grid_word ~ko Keeper_mark.Wait_word
              ; Terminal_text.single_line runtime_id ]
          ^ Ansi.reset
      | Ok None -> ""
      | Error _ ->
          Theme.recede () ^ Keeper_mark.axis_next_glyph ^ " " ^ Keeper_mark.unknown_mark ^ Ansi.reset)
  | Some _ | None -> ""

let grid_since_lead = Keeper_mark.failing_glyph ^ " "

let grid_failure_line ~ko (grid : Grid.t) ~now (row : Keeper_list_model.row) =
  let runtime = keeper_row_runtime row in
  let trail = Keeper_list_model.trail_of_row row in
  let since =
    grid_failure_since ~ko ~now
      ~room:(grid.name_cells - Message_layout.display_width grid_since_lead)
      runtime trail
  in
  String.concat ""
    [ "  " ^ grid_gutter_style (Grid.verdict ~now runtime) ^ Keeper_mark.grid_gutter_glyph ^ Ansi.reset
      ^ String.make (max 0 (Grid.gutter_cells - 3)) ' '
    ; (match since with
       | "" -> String.make grid.name_cells ' '
       | since -> Theme.recede () ^ fit_width (grid_since_lead ^ since) grid.name_cells ^ Ansi.reset)
    ; (if grid.side_cells > 0 then " " ^ grid_failure_chain ~ko grid runtime trail else "")
    ; " "
    ; grid_band grid_blank_now
    ; " "
    ; fit_width (grid_next_dispatch ~ko runtime) (grid_tail_cells grid)
    ]

(* Group sums use only members of this heading, including folded rows. *)
let group_pulse_slots = 12
let group_pulse_min_cells = 20

let group_pulse ~now members =
  let hours row = Masc_tui_keeper_pulse.half_hours ~now ~count:group_pulse_slots
      (Option.bind (keeper_row_runtime row) (fun r -> r.Tui_decode.kr_recent_turns)) in
  let readings = List.map hours members in
  if Masc_tui_keeper_pulse.nothing_read readings then
    Masc_tui_keeper_strip.history_unknown_label ~cells:group_pulse_slots
  else
    String.concat "" (List.init group_pulse_slots (fun position ->
      let count, unknown = List.fold_left (fun (count, unknown) slots ->
        match List.nth_opt slots position with
        | Some (Masc_tui_keeper_pulse.Half_hour_failed | Masc_tui_keeper_pulse.Half_hour_failed_and_ok) -> count + 1, unknown
        | Some Masc_tui_keeper_pulse.Half_hour_unknown | None -> count, true
        | Some (Masc_tui_keeper_pulse.Half_hour_quiet | Masc_tui_keeper_pulse.Half_hour_ok) -> count, unknown)
        (0, false) readings in
      if count > 0 then Theme.warn () ^ Grid.level_glyph ~peak:(List.length members) count ^ Ansi.reset
      else Theme.recede () ^ (if unknown then Keeper_mark.grid_unknown_range_mark else "·") ^ Ansi.reset))

let group_sum project readings =
  List.fold_left (fun total reading ->
    match total, project reading with Some a, Some b -> Some (a + b)
    | None, (Some _ | None) | Some _, None -> None) (Some 0) readings

let group_lag = function
  | Memory_reading.Row { lag = Memory_reading.Lag n; _ } -> Some n
  | Memory_reading.Row { lag = Memory_reading.Lag_unmeasured; _ }
  | Memory_reading.No_row
  | Memory_reading.Unknown | Memory_reading.Refused _ -> None

let group_gap = function
  | Memory_reading.Row { gap = Memory_reading.No_gap; _ } -> Some 0
  | Memory_reading.Row { gap = Memory_reading.Gap { first_atom; past_last_atom }; _ } ->
      Some (max 0 (past_last_atom - first_atom))
  | Memory_reading.No_row | Memory_reading.Row { gap = Memory_reading.Gap_unmeasured; _ }
  | Memory_reading.Unknown | Memory_reading.Refused _ -> None

let group_facts reading =
  match Memory_reading.age_bins reading with
  | Memory_reading.Measured bins -> Some (Masc.Keeper_memory_age_bins.total bins)
  | Memory_reading.No_snapshot -> Some 0
  | Memory_reading.Unmeasured | Memory_reading.Row_absent
  | Memory_reading.Snapshot_unknown | Memory_reading.Row_refused -> None

let group_number = function
  | Some n -> Masc_tui_chart.format_compact_num n
  | None -> "?"

(* Each heading adds every member's known wakes, including paused Keepers.
   The shared reducer retains unknowns alongside known counts; the state
   summary exposes that partial observation. *)
let group_wake_strip state (grid : Grid.t) ~now members =
  let open Masc_tui_keeper_next_run in
  let slots =
    List.map
      (fun (row : Keeper_list_model.row) ->
        Masc_tui_keeper_axis.wake_strip state ~now ~ahead:(Grid.strip_cells grid - 1)
          ~keeper_name:row.keeper.Tui_decode.k_name)
      members
    |> sum_wake_strips
  in
  grid_wake_window state
    ~style:Masc_tui_keeper_strip.Wake_counts slots

let grid_group_title state (grid : Grid.t) ~now ~group ~members ~folded ~style ~pulse
    ?(selected = false) title =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let memories = List.map (keeper_memory_reading state) members in
  let lag = group_number (group_sum group_lag memories) in
  (* [title] already names the group and its member count once, so the right
     side carries status marks or aggregate readings without repeating count. *)
  let now_text, tail, right = match group with
    | Keeper_list_model.Group_cause (Keeper_list_model.Cause_named _ | Keeper_list_model.Cause_unnamed) ->
        let retry, wait, unknown = List.fold_left (fun (retry, wait, unknown) row ->
          match keeper_row_runtime row with
          | Some runtime -> (match runtime.Tui_decode.kr_runtime_path_rest with
              | Ok (Some (Tui_decode.Path_rest_resting _)) -> retry, wait + 1, unknown
              | Ok (Some (Tui_decode.Path_rest_serving _)) -> retry + 1, wait, unknown
              | Ok None | Error _ -> retry, wait, unknown + 1)
          | None -> retry, wait, unknown + 1) (0, 0, 0) members in
        let parts = (if retry > 0 then [Printf.sprintf "▹ %s %d" (say "재시도" "retry") retry] else [])
          @ (if wait > 0 then [Printf.sprintf "◌ %s %d" (say "대기" "wait") wait] else [])
          @ (if unknown > 0 then [Printf.sprintf "? %d" unknown] else []) in
        Keeper_mark.grid_failing_mark ^ " " ^ say "실패" "failing",
        String.concat "  " parts, ""
    | Keeper_list_model.Group_cause Keeper_list_model.Cause_recovered ->
        Keeper_mark.grid_recovered_mark,
        group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_cause Keeper_list_model.Not_failing ->
        Keeper_mark.grid_ok_mark,
        group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_cause Keeper_list_model.Cause_paused ->
        Keeper_mark.grid_paused_mark,
        group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_state _ | Keeper_list_model.Group_due _ ->
        "", group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_memory _ ->
        let gap = match group_sum group_gap memories with Some 0 -> "" | value -> group_number value in
        "", say "합계 지연 " "Σ lag " ^ lag, gap
    | Keeper_list_model.Group_age age ->
        let odd = if age <> Keeper_list_model.Age_older then 0 else
          List.length (List.filter (fun row -> match keeper_row_runtime row with
            | Some r -> not r.Tui_decode.kr_paused && (match r.kr_activation_mode with
                | Tui_decode.Activation_autonomous -> true
                | Tui_decode.Activation_manual | Tui_decode.Activation_on_demand -> false)
            | None -> false) members) in
        (if odd > 0 then Printf.sprintf "%d!" odd else ""),
        Printf.sprintf (if ko then "합계 %s 사실 · 지연 %s" else "Σ %s facts · lag %s")
          (group_number (group_sum group_facts memories)) lag, "" in
  let pulse_width = match pulse with
    | Some _ -> grid.side_cells
    | None -> (match group with
        | Keeper_list_model.Group_memory _ | Keeper_list_model.Group_age _ -> 0
        | Keeper_list_model.Group_cause _ | Keeper_list_model.Group_state _ | Keeper_list_model.Group_due _ ->
            if grid.side_cells >= group_pulse_min_cells then group_pulse_slots else 0) in
  let pulse = match pulse with
    | Some pulse -> pulse
    | None -> if pulse_width > 0 then group_pulse ~now members else "" in
  let lead_width = grid_lead_cells grid - Grid.gutter_cells in
  let title_width = max 0 (lead_width - (if pulse_width > 0 then pulse_width + 1 else 0)) in
  let title = match group with Keeper_list_model.Group_age _ -> fit_width title grid.name_cells
    | Keeper_list_model.Group_cause _ | Keeper_list_model.Group_state _
    | Keeper_list_model.Group_due _ | Keeper_list_model.Group_memory _ -> title in
  let tail_width = grid_tail_cells grid in
  let right_width = grid.mem_cells in
  String.concat ""
    [ (if selected then "› " else "  ")
    ; style ^ (if folded then Keeper_mark.grid_folded_mark else Keeper_mark.grid_open_mark) ^ Ansi.reset ^ " "
    ; Ansi.bold ^ fit_width title title_width ^ Ansi.reset
    ; (if pulse_width > 0 then " " ^ pulse else "")
    ; " " ^ grid_band (style ^ fit_width now_text Grid.now_cells ^ Ansi.reset)
    ; " " ^ Theme.recede () ^ fit_width tail (max 0 (tail_width - right_width))
    ; (if right_width > 0 then Message_layout.pad_left right right_width else "")
    ; Ansi.reset ]

(* The rows of one group, folded or not. [klr_groups] is mapped from
   [klr_rows], one group per row. *)
let keeper_group_rows (reading : Masc_tui_types.keeper_list_reading) group =
  let rec members rows groups =
    match rows, groups with
    | row :: rows, Some other :: groups when other = group -> row :: members rows groups
    | _ :: rows, _ :: groups -> members rows groups
    | [], _ | _, [] -> []
  in
  members reading.klr_rows reading.klr_groups

(* The age view's group title draws its Keepers' ladders added up (§2.4.7).
   An unavailable member makes the sum unknown; a known empty snapshot adds zero. *)
let grid_group_pulse state (grid : Grid.t) reading group =
  match (group : Keeper_list_model.group) with
  | Keeper_list_model.Group_age _ ->
      let bins =
        List.fold_left
          (fun sum row ->
            match Memory_reading.age_bins (keeper_memory_reading state row) with
            | Memory_reading.Measured bins ->
                Option.map (fun sum -> Masc.Keeper_memory_age_bins.add sum bins) sum
            | Memory_reading.No_snapshot -> sum
            | Memory_reading.Unmeasured | Memory_reading.Snapshot_unknown
            | Memory_reading.Row_absent | Memory_reading.Row_refused -> None)
          (Some Masc.Keeper_memory_age_bins.zero)
          (keeper_group_rows reading group)
      in
      Some (grid_age_ladder_reading grid bins)
  | Keeper_list_model.Group_state _ | Keeper_list_model.Group_cause _
  | Keeper_list_model.Group_due _ | Keeper_list_model.Group_memory _ -> None

(* A header word on the left of its column and [tail] on its right, or the
   word alone when the column is too narrow for both. *)
let grid_spread ~cells lead tail =
  let lead_cells = Message_layout.display_width lead in
  let tail_cells = Message_layout.display_width tail in
  if lead_cells + 1 + tail_cells <= cells then
    lead ^ String.make (cells - lead_cells - tail_cells) ' ' ^ tail
  else fit_width lead cells

(* The mock's room for the longer header words: the lag bar's long header
   needs a strip of 20 cells, and [facts by age ▸] a name column of 20 cells,
   8 cells after [keeper]. *)
let grid_lag_bar_header_cells = 20
let grid_facts_by_age_name_cells = 20
let grid_facts_by_age_offset = 8

(* The column headers draw the two lines and no band. A header word over the
   due column may run into the gap after it. *)
let grid_header state (grid : Grid.t) (columns : Axis_row.columns) =
  let recede text = Theme.recede () ^ text ^ Ansi.reset in
  let line = " " ^ recede Keeper_mark.grid_now_line ^ " " in
  (* The pulse draws [side_cells] half hours up to the now slot and the strip
     as many after it, so one span names both. *)
  let window = Grid.window_label ~slots:grid.side_cells in
  let side = grid.side_cells > 0 in
  let mem = grid.mem_cells > 0 in
  let word = Keeper_mark.grid_column_word ~ko:(state.ui_language = Lang_ko) in
  let lag_bar =
    if Grid.strip_cells grid >= grid_lag_bar_header_cells then word Keeper_mark.Lag_bar_column
    else word Keeper_mark.Lag_bar_short_column
  in
  let pulse_header word = grid_spread ~cells:grid.side_cells word Grid.slot_label in
  let name, pulse, now_word, strip, due, right =
    match columns with
    | Axis_row.Activity_columns ->
        ( word Keeper_mark.Keeper_column
        , pulse_header (Keeper_mark.grid_pulse_header ~window)
        , word Keeper_mark.Now_column
        , (match state.keeper_list_view with
           | Keeper_list_model.By_state ->
               ui_text state ~ko:("예약 확인 · " ^ window) ~en:("known wakes · " ^ window)
           | Plain | By_cause | By_time | By_memory | By_age | By_runtime | Day_wall ->
               Keeper_mark.grid_next_column_word ~ko:(state.ui_language = Lang_ko) ~window)
        , word Keeper_mark.Due_column
        , Message_layout.pad_left (word Keeper_mark.Lag_column) (grid.mem_cells - grid_level_cells) )
    | Axis_row.Memory_columns ->
        ( word Keeper_mark.Keeper_column
        , pulse_header
            (Keeper_mark.grid_pulse_header ~window:(word Keeper_mark.Turns_column ^ " " ^ window))
        , word Keeper_mark.Librarian_column
        , lag_bar
        , word Keeper_mark.Digest_column
        , Message_layout.pad_left (word Keeper_mark.Gap_column) grid.mem_cells )
    | Axis_row.Age_columns ->
        ( (if grid.name_cells >= grid_facts_by_age_name_cells then
             fit_width (word Keeper_mark.Keeper_column) grid_facts_by_age_offset
             ^ word Keeper_mark.Facts_by_age_column
           else word Keeper_mark.Keeper_column)
        , Age_ladder.tick_line ~column:grid.side_cells
        , word Keeper_mark.Saved_column
        , lag_bar
        , word Keeper_mark.Stale_column
        , Message_layout.pad_left (word Keeper_mark.Facts_column) grid.mem_cells )
  in
  String.concat ""
    [ String.make Grid.gutter_cells ' '
    ; recede (fit_width name grid.name_cells)
    ; (if side then " " ^ recede pulse else "")
    ; line
    ; Ansi.bold ^ fit_width now_word Grid.now_cells ^ Ansi.reset
    ; line
    ; (if side then recede (fit_width strip (Grid.strip_cells grid)) ^ " "
       else "")
    ; recede (fit_width due (Grid.due_cells + if mem then 1 else 0))
    ; (if mem then recede (fit_width right grid.mem_cells) else "")
    ]

(* The subtractions over the fleet's name lists. They answer different
   questions and only one of them is about being stopped: a keeper the fleet
   wants with no live turn-executing fiber is bootable minus executable,
   while a keeper whose fiber is alive but whose durable demand is not
   admissible is running minus executable. Reporting the second as "not
   running" sent an operator to boot ten keepers that were already up, and
   subtracting the Running-phase list instead of the executable list here put
   every Failing keeper in "not running" too -- a failing keepalive still
   runs its turns, so keepers that were visibly turning were listed as not
   running (2026-09-16). Executable is the set with a live fiber (Running or
   Failing), which is the fact the label names. *)
let keeper_fleet_gap_lines ~ko (fleet : fleet_safety) =
  let say korean english = if ko then korean else english in
  let names = Masc.Fleet_stream.Names.to_list in
  let subtract from_names remove_names =
    List.filter (fun name -> not (List.mem name remove_names)) from_names
  in
  let not_running =
    subtract (names fleet.fs_bootable_names) (names fleet.fs_executable_names)
  in
  let running_without_turn =
    subtract (names fleet.fs_running_names) (names fleet.fs_executable_names)
  in
  List.filter_map
    (fun (names, label, color) ->
       match names with
       | [] -> None
       | _ -> Some (color, label, String.concat ", " names))
    [ (not_running, say "실행 안 됨" "not running", (Theme.bad ()))
    ; (running_without_turn, say "실행 중이나 턴 못 돎" "running, cannot take a turn", (Theme.warn ()))
    ; (* Failing subsets that need operator action: turn configuration
         errors survive every retry, so the names are listed where the
         failing counter only counts them. Unscoped on purpose -- the
         configuration_blocked_* wire fields are autoboot-scoped and skip a
         blocked keeper booted on request. *)
      ( names fleet.fs_turn_configuration_error_names
      , say "설정 오류" "config-blocked"
      , (Theme.bad ()) )
    ; ( names fleet.fs_official_client_recovery_required_names
      , say "세션 복구 필요" "session recovery required"
      , (Theme.bad ()) )
    ]


(* The conditions that share a phase with another: either health reading
   makes a keeper failing, and a pending launch is one of the ways it is
   offline. Each of the other conditions has a phase of its own, which the
   lifecycle word already says, so naming it again would add nothing. *)
let keeper_lane_phase_causes ~ko (conditions : Tui_decode.keeper_lane_conditions) =
  let say korean english = if ko then korean else english in
  List.filter_map
    (fun (holds, words) -> if holds then Some words else None)
    [ (not conditions.klc_turn_healthy, say "마지막 턴 실패" "last turn failed")
    ; (not conditions.klc_heartbeat_healthy, say "heartbeat 실패" "heartbeat failed")
    ; (conditions.klc_launch_pending, say "기동 대기" "launch pending")
    ]

let keeper_lane_lifecycle_text ~ko (lane : Tui_decode.keeper_lane) =
  let phase =
    Terminal_text.single_line (Tui_decode.keeper_lane_phase_to_string lane.kl_phase)
  in
  match Option.fold ~none:[] ~some:(keeper_lane_phase_causes ~ko) lane.kl_conditions with
  | [] -> phase
  | causes -> Printf.sprintf "%s (%s)" phase (String.concat ", " causes)

let keeper_operations_outcome_text = function
  | None -> Masc_tui_theme.Glyph.no_value
  | Some (outcome : Tui_decode.keeper_lane_last_outcome) ->
      let state = Terminal_text.single_line outcome.klo_runtime_state in
      (match outcome.klo_selected_model with
       | Some model when String.trim model <> "" ->
           state ^ " · " ^ Terminal_text.single_line model
       | Some _ | None -> state)

(* The runtime that produced the last outcome, apart from the one the keeper
   is assigned: after a failover they differ. An id the catalog does not list
   (or a catalog not loaded yet) shows the raw id, never a guessed provider. *)
let keeper_last_runtime_text (state : state) = function
  | Some { Tui_decode.klo_selected_runtime_id = Some runtime_id; _ } ->
      let id_text = Terminal_text.single_line runtime_id in
      (match state.runtime_surface with
       | None -> id_text
       | Some snap ->
           (match
              Tui_decode.resolve_last_runtime
                snap.rss_resolved.rrs_runtimes runtime_id
            with
            | Tui_decode.Last_runtime_cataloged ro ->
                id_text ^ " \xc2\xb7 " ^ Terminal_text.single_line ro.ro_provider
            | Tui_decode.Last_runtime_uncataloged _ ->
                id_text
                ^ ui_text state ~ko:" \xc2\xb7 런타임 목록에 없음"
                    ~en:" \xc2\xb7 not in the runtime list"))
  | Some { Tui_decode.klo_selected_runtime_id = None; _ } | None ->
      Masc_tui_theme.Glyph.no_value

(* Composite execution facts belong to this Keeper's Info pane. Separate
   fields use the pane's wrapped, scrollable rows; a long one-line preview
   beside the list footer silently lost its outcome and runtime target. *)
(* The composite reading, failure and in-flight read of [keeper_name]; a
   reading of the Keeper the cursor left is not this Keeper's. *)
let keeper_composite_of (state : state) ~keeper_name =
  match state.keeper_composite with
  | Some reading when String.equal reading.kcr_keeper keeper_name -> Some reading
  | Some _ | None -> None

let keeper_composite_error_of (state : state) ~keeper_name =
  match state.keeper_composite_error with
  | Some (keeper, detail) when String.equal keeper keeper_name -> Some detail
  | Some _ | None -> None

let keeper_composite_reading_now (state : state) ~keeper_name =
  Option.equal String.equal state.keeper_composite_inflight (Some keeper_name)

let keeper_operations_fields (state : state) ~keeper_name =
  let reading = keeper_composite_of state ~keeper_name in
  let error = keeper_composite_error_of state ~keeper_name in
  let reading_now = keeper_composite_reading_now state ~keeper_name in
  let ko = state.ui_language = Lang_ko in
  let t korean english = if ko then korean else english in
  let execution = t "실행:" "Execution:" in
  (* The phase, the turn phase and the runtime state are the server's wire
     names and are drawn as sent. *)
  let fields = match reading with
  | Some { kcr_lane = lane; _ } ->
      [ t "수명 주기:" "Lifecycle:", keeper_lane_lifecycle_text ~ko lane
      ; t "턴:" "Turn:", Terminal_text.single_line
          (Tui_decode.keeper_lane_turn_phase_to_string lane.kl_turn_phase)
      ; t "쉰 시간:" "Idle:", Masc_tui_value.Ongoing.Narrow.text (Float.of_int lane.kl_idle_seconds)
      ; t "마지막 턴 결과:" "Last outcome:", keeper_operations_outcome_text lane.kl_last_outcome
      ; t "마지막 런타임:" "Last runtime:", keeper_last_runtime_text state lane.kl_last_outcome
      ]
  | None ->
      (match error with
       | Some detail ->
           [ execution, Theme.bad () ^ t "읽기 실패 · " "read failed · "
             ^ Terminal_text.single_line detail ^ Ansi.reset ]
       | None ->
           (* Not read yet is a mark where the value goes, not a word
              (RFC tui-one-screen-grammar §6.4). *)
           if reading_now then []
           else
             [ execution
             , Theme.recede () ^ Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread
               ^ Ansi.reset ])
  in
  let fields = match reading, error with
    | Some _, Some detail ->
        (execution, Theme.warn () ^ t "이전 관측 · 갱신 실패: " "stale · refresh failed: "
          ^ Terminal_text.single_line detail ^ Ansi.reset) :: fields
    | Some _, None | None, (Some _ | None) -> fields in
  if reading_now then
    (execution, Theme.recede ()
      ^ (match reading with
         | None -> t "실행 상태 읽는 중" "reading execution snapshot"
         | Some _ ->
             t "실행 상태 갱신 중 · 마지막 관측" "refreshing execution snapshot · last observation")
      ^ Ansi.reset) :: fields
  else fields

type keeper_display_entry =
  | Keeper_world
  | Keeper_group_heading of Keeper_list_model.group * int
  | Keeper_display_row of int * Keeper_list_model.row

(* The entries are the stops [j] and [k] land on, so what is drawn and where
   the cursor can go cannot disagree. A heading counts every row of its group,
   folded or not. [klr_groups] is mapped from [klr_rows], so every row stop
   names a row. *)
let keeper_display_entries ~view ~folded (reading : Masc_tui_types.keeper_list_reading) =
  let rows = Array.of_list reading.klr_rows in
  let members group =
    List.length (List.filter (fun other -> other = Some group) reading.klr_groups)
  in
  List.map
    (function
      | Keeper_list_model.Stop_world -> Keeper_world
      | Keeper_list_model.Stop_heading group -> Keeper_group_heading (group, members group)
      | Keeper_list_model.Stop_row position -> Keeper_display_row (position, rows.(position)))
    (Keeper_list_model.stops ~view ~folded reading.klr_groups)

let keeper_entry_selected stop = function
  | Keeper_world -> stop = Some Keeper_list_model.Stop_world
  | Keeper_group_heading (group, _) -> stop = Some (Keeper_list_model.Stop_heading group)
  | Keeper_display_row (position, _) -> stop = Some (Keeper_list_model.Stop_row position)

(* The views [v] walks, one press each (RFC-0515 §2.3), paired with a
   btop-style right-aligned inline control strip showing active sort and row
   density without spending an extra vertical row. *)
let keeper_view_tabs ~ko ~cols ~sort ~density view =
  let lead = "  " in
  let dim text = Theme.recede () ^ text ^ Ansi.reset in
  let sort_chip =
    dim "< " ^ Keeper_list_model.sort_title ~ko sort ^ dim " >"
  in
  let full_controls =
    if Keeper_list_model.supports_density view then
      let density_chip = dim (Keeper_list_model.density_title ~ko density) in
      "  " ^ sort_chip ^ "  " ^ density_chip
    else "  " ^ sort_chip
  in
  let compact_controls = "  " ^ sort_chip in
  let inner = max 1 (framed_inner_width cols) in
  let min_tabs_width = 18 in
  let after =
    if Message_layout.display_width lead + min_tabs_width
       + Message_layout.display_width full_controls <= inner
    then full_controls
    else if Message_layout.display_width lead + min_tabs_width
            + Message_layout.display_width compact_controls <= inner
    then compact_controls
    else ""
  in
  let tabs =
    tab_strip ~width:(tab_strip_width ~cols ~before:lead ~after)
      ~press:(fun target text -> pressable (Press_keeper_view target) text)
      (List.map
         (fun candidate -> Keeper_list_model.view_title ~ko candidate, candidate = view, candidate)
         Keeper_list_model.views)
  in
  if String.equal after "" then lead ^ tabs
  else
    let used =
      Message_layout.display_width lead
      + Message_layout.display_width tabs
      + Message_layout.display_width after
    in
    let pad = max 0 (inner - used) in
    lead ^ tabs ^ String.make pad ' ' ^ after

(* A state group's heading takes the colour of the group's mark, the one its
   rows wear (RFC tui-one-screen-grammar §7.2). *)
let keeper_state_heading_style attention =
  match Masc_tui_keeper_mark.attention_mark attention with
  | Some mark -> Theme.status_tone mark
  | None -> Theme.recede ()

let keeper_group_heading_style = function
  | Keeper_list_model.Group_state attention -> keeper_state_heading_style attention
  | Keeper_list_model.Group_cause (Keeper_list_model.Cause_named _ | Keeper_list_model.Cause_unnamed) ->
      Theme.warn ()
  | Keeper_list_model.Group_cause
      (Keeper_list_model.Cause_recovered | Keeper_list_model.Not_failing) -> Theme.ok ()
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_paused -> Theme.recede ()
  | Keeper_list_model.Group_due (Keeper_list_model.Due_late | Keeper_list_model.Due_held) ->
      Theme.warn ()
  | Keeper_list_model.Group_due
      ( Keeper_list_model.Due_within_hour | Keeper_list_model.Due_within_half_day
      | Keeper_list_model.Due_later ) -> Theme.info ()
  | Keeper_list_model.Group_due (Keeper_list_model.Due_none | Keeper_list_model.Due_unknown) ->
      Theme.recede ()
  | Keeper_list_model.Group_memory Keeper_list_model.Memory_refused -> Theme.bad ()
  | Keeper_list_model.Group_memory (Keeper_list_model.Memory_gap | Keeper_list_model.Memory_lagging) ->
      Theme.warn ()
  | Keeper_list_model.Group_memory Keeper_list_model.Memory_following -> Theme.ok ()
  | Keeper_list_model.Group_memory Keeper_list_model.Memory_unread -> Theme.recede ()
  | Keeper_list_model.Group_age
      ( Keeper_list_model.Age_within_3h | Keeper_list_model.Age_within_day
      | Keeper_list_model.Age_within_3d | Keeper_list_model.Age_older ) -> Theme.info ()
  | Keeper_list_model.Group_age Keeper_list_model.Age_unknown -> Theme.recede ()

(* A Keeper record without activity, in a value cell (RFC tui-one-screen-grammar
   6.4): a declared Keeper that never started has none ([—]); a server roster
   row does not carry it ([?]). A persisted Keeper always carries it. *)
let keeper_activity_absent_mark (keeper : Tui_decode.keeper) =
  match keeper.k_origin with
  | Tui_decode.Declared_keeper _ -> Masc_tui_theme.Glyph.no_value
  | Tui_decode.Remote_keeper | Tui_decode.Persisted_keeper ->
      Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported

let keeper_state_heading_text ~ko ~available_cells rows group count =
  let label =
    match group with
    | Keeper_list_model.Attention -> if ko then "조치 필요" else "Attention"
    | Keeper_list_model.Failing -> if ko then "실패" else "Failing"
    | Keeper_list_model.Active -> if ko then "활성" else "Active"
    | Keeper_list_model.Waiting -> if ko then "대기" else "Waiting"
    | Keeper_list_model.Inactive -> if ko then "비활성" else "Inactive"
    | Keeper_list_model.Unobserved -> if ko then "못 읽음" else "Not read"
  in
  let detail =
    match group with
    | Keeper_list_model.Waiting ->
        Render_schedule.waiting_group_heading_detail ~ko ~available_cells ~group_count:count
          (Keeper_list_model.waiting_summary rows)
    | Keeper_list_model.Attention | Keeper_list_model.Failing | Keeper_list_model.Active
    | Keeper_list_model.Inactive | Keeper_list_model.Unobserved -> ""
  in
  Printf.sprintf "%s %d%s" label count detail

let keeper_group_heading_text ~ko ~available_cells rows group count =
  let say korean english = if ko then korean else english in
  match group with
  | Keeper_list_model.Group_state attention ->
      keeper_state_heading_text ~ko ~available_cells rows attention count
  | Keeper_list_model.Group_cause (Keeper_list_model.Cause_named cause) ->
      Printf.sprintf "%s %s %d" failing_glyph (keeper_cause_group_word ~ko cause) count
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_unnamed ->
      Printf.sprintf "%s %s %d" failing_glyph (say "실패 · 원인 미기록" "Failing · unknown cause") count
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_recovered ->
      Printf.sprintf "%s %d" (say "복구 · 12시간 내 실패" "Recovered · failed in 12h") count
  | Keeper_list_model.Group_cause Keeper_list_model.Not_failing ->
      Printf.sprintf "%s %d" (say "현재 실패 없음" "No current failure") count
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_paused ->
      Printf.sprintf "%s %d" (say "일시정지" "Paused") count
  | Keeper_list_model.Group_due due ->
      let label =
        match due with
        | Keeper_list_model.Due_late -> say "지연됨" "Late"
        | Keeper_list_model.Due_held -> say "보류됨" "Held"
        | Keeper_list_model.Due_within_hour -> say "1시간 내" "Within 1h"
        | Keeper_list_model.Due_within_half_day -> say "12시간 내" "Within 12h"
        | Keeper_list_model.Due_later -> say "이후 예정" "Later"
        | Keeper_list_model.Due_none -> say "예약 없음" "No schedule"
        | Keeper_list_model.Due_unknown -> say "예약 모름" "Schedule unknown"
      in
      Printf.sprintf "%s %s %d" (Masc_tui_keeper_mark.due_glyph due) label count
  | Keeper_list_model.Group_memory follow ->
      let label =
        match follow with
        | Keeper_list_model.Memory_refused -> say "기억 거부됨" "Memory refused"
        | Keeper_list_model.Memory_gap -> say "기억 누락" "Memory gap"
        | Keeper_list_model.Memory_lagging -> say "기억 지연" "Memory lagging"
        | Keeper_list_model.Memory_following -> say "기억 정상" "Memory following"
        | Keeper_list_model.Memory_unread -> say "기억 미조회" "No memory reading"
      in
      Printf.sprintf "%s %d" label count
  | Keeper_list_model.Group_age age ->
      let label =
        match age with
        | Keeper_list_model.Age_within_3h -> say "3시간 내 갱신" "Updated within 3h"
        | Keeper_list_model.Age_within_day -> say "24시간 내 갱신" "Updated within 24h"
        | Keeper_list_model.Age_within_3d -> say "3일 내 갱신" "Updated within 3d"
        | Keeper_list_model.Age_older -> say "이전 갱신" "Updated earlier"
        | Keeper_list_model.Age_unknown -> say "갱신 시각 모름" "Update time unknown"
      in
      Printf.sprintf "%s %d" label count

(* The columns a Story window label takes: two of indent, the mark and the word. *)
let story_label_cells = 10

(* Compact btop-style live context meter for the Story window when the
   Keeper's context window has been measured. *)
let keeper_story_context_meter (state : state) ~ko ~inner (row : Keeper_list_model.row) =
  let observation =
    match row.keeper.k_identity with
    | Error _ -> None
    | Ok _ ->
        (match live_context_view state row.keeper with
         | Masc_tui_fetched.Ready obs | Masc_tui_fetched.Stale (obs, _) -> Some obs
         | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ -> None)
  in
  match
    Option.bind observation (fun obs ->
      match Observation_layout.context_summary obs with
      | Observation_layout.Context_measured { ratio; tokens; maximum; _ } ->
          Some (ratio, tokens, maximum)
      | Observation_layout.Context_partial _ | Observation_layout.Context_unavailable _ -> None)
  with
  | None -> None
  | Some (ratio, tokens, maximum) ->
      let value = Observation_layout.percentage_tenths ratio in
      let max_value = Observation_layout.percentage_tenths_full in
      let pct = Float.of_int value /. 10.0 in
      let scale = Masc_tui_chart.Declared_limit (Theme.paint ()) in
      let suffix =
        Printf.sprintf "%.1f%% (%s/%s)" pct
          (Message_layout.compact_count tokens)
          (Message_layout.compact_count maximum)
      in
      let label = if ko then "컨텍스트" else "ctx" in
      let width = min 44 (max 1 (inner - story_label_cells)) in
      Some
        (Masc_tui_chart.meter ~width ~value ~max_value ~scale ~label ~suffix
           ~track_style:(Theme.recede ()) ~reset:Ansi.reset ())

let keeper_story_task_segment ~ko (row : Keeper_list_model.row) =
  match row.task with
  | None -> None
  | Some (task : Tui_decode.task) ->
      let title =
        let raw = Terminal_text.single_line task.title in
        if String.equal raw "" then Terminal_text.single_line task.id else raw
      in
      let style = task_state_style task.status in
      let close = if String.equal style "" then "" else Ansi.reset in
      let prefix = if ko then "작업 " else "task " in
      Some (Theme.recede () ^ prefix ^ Ansi.reset ^ style ^ task_status_icon task.status ^ " " ^ title ^ close)

(* The story page of the Story window (RFC-0515 section 2.5): the Keeper under
   the cursor told as past, now and next. The embedded top rule already carries
   the Keeper's name and current activity word, so [now] leads with context,
   task and detail telemetry rather than repeating the heading. *)
let keeper_story_lines (state : state) ~now ~inner ~body_rows (row : Keeper_list_model.row) =
  let ko = state.ui_language = Lang_ko in
  let keeper_name = row.keeper.Tui_decode.k_name in
  let runtime =
    match row.reading.Keeper_control.liveness with
    | Keeper_control.Present runtime -> Some runtime
    | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None
  in
  let memory = Masc_tui_render_keeper_story.memory_reading state ~keeper_name in
  let dim text = Theme.recede () ^ text ^ Ansi.reset in
  let join parts = String.concat (dim "  ·  ") parts in
  let labelled_lines name entries =
    let label = dim (Message_layout.fit_width ("  " ^ name) story_label_cells) in
    match entries with
    | [] -> []
    | first :: rest ->
        (label ^ first) :: List.map (fun entry -> String.make story_label_cells ' ' ^ entry) rest
  in
  let failing_cell, pulse_cell =
    match runtime with
    | None -> None, None
    | Some runtime ->
        ( Masc_tui_keeper_pulse.failing_cell ~now
            (Masc_tui_keeper_pulse.failing_of_health
               ~health:(Tui_decode.keeper_health_reading runtime.kr_health)
               ~failing_since:runtime.kr_failing_since)
        , Masc_tui_keeper_pulse.pulse_cell ~now runtime.kr_recent_turns )
  in
  let lag =
    match memory with
    | Masc_tui_keeper_memory_reading.Row { lag = Masc_tui_keeper_memory_reading.Lag turns; _ }
      when turns > 0 ->
        Some
          (Theme.warn ()
           ^ Printf.sprintf (if ko then "밀림 %d" else "lag %d") turns
           ^ Ansi.reset)
    | Masc_tui_keeper_memory_reading.Row
        { lag = Masc_tui_keeper_memory_reading.Lag _ | Masc_tui_keeper_memory_reading.Lag_unmeasured
        ; _ }
    | Masc_tui_keeper_memory_reading.Unknown | Masc_tui_keeper_memory_reading.No_row
    | Masc_tui_keeper_memory_reading.Refused _ -> None
  in
  let past_parts =
    List.filter_map Fun.id
      [ Option.map style_axis_cell failing_cell
      ; Option.map
          (fun (cell : Masc_tui_keeper_axis_cell.t) ->
            style_axis_cell
              { cell with
                Masc_tui_keeper_axis_cell.text =
                  Printf.sprintf (if ko then "최근 %dh %s" else "last %dh %s")
                    Masc_tui_keeper_mark.pulse_hours cell.text
              })
          pulse_cell
      ]
  in
  let past_head = match past_parts with [] -> [] | _ -> [ join past_parts ] in
  let past_tail =
    Option.to_list
      (Option.map
         (fun sentence -> Theme.warn () ^ sentence ^ Ansi.reset)
         (keeper_row_trail_sentence ~ko ~age:(keeper_trail_age ~now) row))
    @ Option.to_list
        (render_attempt_chain
           ~max_cells:(max 0 (inner - story_label_cells))
           (Masc_tui_keeper_trail.attempts_of_runtime runtime))
  in
  let age =
    match row.last_activity_at with
    | Some since ->
        Option.value (Message_layout.age_text ~now ~since) ~default:Masc_tui_theme.Glyph.no_value
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let schedules =
    if Option.is_some state.schedules_agenda_error then None else state.schedules_agenda
  in
  let detail = keeper_detail_text ?schedules ~tasks:state.tasks ~ko ~now row in
  let telemetry_row =
    let parts =
      List.filter_map Fun.id
        [ keeper_story_context_meter state ~ko ~inner row
        ; keeper_story_task_segment ~ko row
        ; (if String.equal detail "" then None else Some detail)
        ]
    in
    match parts with [] -> None | _ -> Some (join parts)
  in
  let meta_row =
    dim (keeper_flags_word ~ko ^ " ")
    ^ keeper_flag_cell row.reading.Keeper_control.liveness
    ^ dim
        (Printf.sprintf "   %s %s   %s" (keeper_age_word ~ko) age
           (keeper_runtime_label runtime))
  in
  let now_entries =
    match telemetry_row with
    | Some primary -> [ primary; meta_row ]
    | None -> [ meta_row ]
  in
  let next_parts =
    List.filter_map Fun.id
      [ Option.map style_axis_cell
          (Masc_tui_render_keeper_story.next_run_cell state ~now ~keeper_name)
      ; Option.map dim (keeper_next_text ~ko ~now row)
      ; lag
      ]
  in
  let next_entries =
    match next_parts with
    | [] -> [ dim (if ko then "예정 없음" else "nothing announced") ]
    | _ -> [ join next_parts ]
  in
  (* Source cautions in the feed precede the optional trail and flags. Keep
     the current telemetry and next reading, then let the feed use its own
     caution-first policy before filling spare rows with older detail. *)
  let primary_now = List.take 1 now_entries in
  let feed_room =
    max 0 (body_rows - List.length past_head - List.length primary_now
           - List.length next_entries)
  in
  let feed =
    Masc_tui_render_keeper_story.feed_lines state ~now ~max_lines:feed_room ~keeper_name
  in
  let feed =
    if feed = [] && past_head = [] && past_tail = [] && feed_room > 0
    then [ dim (if ko then "기록 없음" else "nothing recorded") ] else feed in
  let detail_room = max 0 (feed_room - List.length feed) in
  let past_tail = List.take detail_room past_tail in
  let now_entries = primary_now
    @ List.take (max 0 (detail_room - List.length past_tail)) (List.drop 1 now_entries) in
  let past_entries = past_head @ feed @ past_tail in
  labelled_lines (if ko then "◂ 과거" else "◂ past") past_entries
  @ labelled_lines (if ko then "● 현재" else "● now") now_entries
  @ labelled_lines (if ko then "▹ 다음" else "▹ next") next_entries

(* The Keeper's name and current activity mark + word, embedded on the left of
   the Story window's top rule. *)
let keeper_story_lead ~ko (row : Keeper_list_model.row) =
  Ansi.bold ^ Terminal_text.single_line row.keeper.Tui_decode.k_name ^ Ansi.reset ^ "  "
  ^ keeper_activity_style row
  ^ Masc_tui_keeper_mark.row_activity_glyph row ^ " "
  ^ keeper_row_activity_word ~ko row ^ Ansi.reset

let draw_keeper_story buf ~cols ~rows ~now ~inner (state : state) page
    (row : Keeper_list_model.row option) =
  let ko = state.ui_language = Lang_ko in
  let lead, lines =
    match page, row with
    | Masc_tui_keeper_story.World, (Some _ | None) ->
        (Theme.info ()
         ^ (if ko then "월드 · 공유 워크스페이스 기억" else "world · shared workspace memory")
         ^ Ansi.reset,
         Masc_tui_keeper_world.dock_lines ~ko ~health_error:(memory_health_error_text state)
           ~cells:inner ~max_lines:(Masc_tui_render_keeper_story.body_rows ~rows)
           state.memory_health (Masc_tui_memory_world.reading state.memory_world))
    | Masc_tui_keeper_story.(Story | Schedule | Memory), None ->
        ( Theme.recede () ^ (if ko then "선택된 키퍼 없음" else "no Keeper") ^ Ansi.reset
        , [ Theme.recede ()
            ^ (if ko then "  커서 아래 키퍼가 없습니다" else "  no Keeper under the cursor")
            ^ Ansi.reset ] )
    | Masc_tui_keeper_story.(Story | Schedule | Memory), Some row ->
        let keeper_name = row.keeper.Tui_decode.k_name in
        ( keeper_story_lead ~ko row
        , (match page with
           | Masc_tui_keeper_story.Story | Masc_tui_keeper_story.World ->
               keeper_story_lines state ~now ~inner
                 ~body_rows:(Masc_tui_render_keeper_story.body_rows ~rows) row
           | Masc_tui_keeper_story.Schedule ->
               Masc_tui_render_keeper_story.schedule_lines state ~now ~keeper_name
           | Masc_tui_keeper_story.Memory ->
               Masc_tui_render_keeper_story.memory_lines state ~cols:inner
                 ~max_lines:(Masc_tui_render_keeper_story.body_rows ~rows) ~now ~keeper_name) )
  in
  Masc_tui_render_keeper_story.draw buf ~ko ~cols ~rows ~lead ~current:page lines

(* The matrix keeps runtime identities separate from their display labels. *)
type runtime_matrix =
  { matrix_ids : string list; matrix_omitted : int
  ; matrix_name_cells : int; matrix_cell_cells : int; matrix_pulse_slots : int }

let runtime_matrix ~inner rows =
  let ids = List.concat_map (fun row -> Keeper_trail.matrix_runtime_ids (keeper_row_runtime row)) rows
    |> List.sort_uniq String.compare in
  let count id = List.length (List.filter (fun row ->
    List.mem id (Keeper_trail.matrix_runtime_ids (keeper_row_runtime row))) rows) in
  let ids = List.sort (fun a b ->
    let order = Int.compare (count b) (count a) in
    if order = 0 then String.compare a b else order) ids in
  let matrix_cell_cells = if inner >= 100 then 3 else 2 in
  let matrix_name_cells = min 24 (max 0 (inner - 25)) in
  let matrix_pulse_slots = min (if inner >= 100 then 12 else 8) (max 0 (inner - matrix_name_cells - 11)) in
  let capacity = max 0 ((inner - matrix_name_cells - matrix_pulse_slots - 11) / matrix_cell_cells) in
  { matrix_ids = List.take capacity ids; matrix_omitted = max 0 (List.length ids - capacity)
  ; matrix_name_cells; matrix_cell_cells; matrix_pulse_slots }

let rec matrix_letter index =
  let last = String.make 1 (Char.chr (Char.code 'A' + index mod 26)) in
  if index < 26 then last else matrix_letter (index / 26 - 1) ^ last

let matrix_header ~ko matrix =
  String.make Grid.gutter_cells ' '
  ^ fit_width (Keeper_mark.grid_column_word ~ko Keeper_mark.Keeper_column) matrix.matrix_name_cells
  ^ " "
  ^ String.concat "" (List.mapi (fun index _ -> fit_width (matrix_letter index) matrix.matrix_cell_cells) matrix.matrix_ids)
  ^ " " ^ fit_width (if ko then "최근" else "last") 5
  ^ fit_width ("◂ " ^ Grid.window_label ~slots:matrix.matrix_pulse_slots) matrix.matrix_pulse_slots

(* A runtime view row draws the gutter, mark and pulse every grid view draws
   (RFC tui-one-screen-grammar 7.2): a sound Keeper reads as sound, and only a
   failed half hour wears the warn tone. *)
let matrix_keeper_row ?(selected = false) matrix ~now row =
  let runtime = keeper_row_runtime row in
  let verdict = Grid.verdict ~now runtime in
  let cells = List.map (fun runtime_id ->
    let cell = Keeper_trail.matrix_cell ~runtime_id runtime in
    let head = match cell.head with
      | Keeper_trail.Head_elsewhere -> " "
      | Keeper_trail.Head_serving -> Theme.info () ^ Keeper_mark.axis_next_glyph
      | Keeper_trail.Head_resting -> Theme.recede () ^ Keeper_mark.grid_wait_glyph
      | Keeper_trail.Head_unknown -> Theme.recede () ^ Keeper_mark.unknown_mark in
    let failure = match cell.failure with
      | Keeper_trail.Matrix_failed -> Theme.warn () ^ Keeper_mark.attempt_glyph
      | Keeper_trail.Matrix_clear -> " "
      | Keeper_trail.Matrix_unknown -> Theme.recede () ^ Keeper_mark.unknown_mark in
    fit_width (failure ^ head ^ Ansi.reset) matrix.matrix_cell_cells) matrix.matrix_ids in
  (* The time since the last failed turn: [—] for a Keeper whose trail holds
     no failure, [?] for a failure with no end the screen can read (6.4). *)
  let last = match Keeper_list_model.trail_of_row row with
    | Keeper_trail.Trail_failed { ended_at = Some at; _ } when at <= now ->
        Masc_tui_value.Ongoing.Narrow.since ~now at
    | Keeper_trail.Trail_failed _ -> Keeper_mark.unknown_mark
    | Keeper_trail.Trail_sound -> Masc_tui_theme.Glyph.no_value in
  let pulse = Option.bind runtime (fun r -> r.Tui_decode.kr_recent_turns)
    |> Masc_tui_keeper_pulse.half_hours ~now ~count:matrix.matrix_pulse_slots
    |> List.map (fun half_hour ->
         grid_half_hour_style half_hour ^ Masc_tui_keeper_pulse.half_hour_mark half_hour
         ^ Ansi.reset)
    |> String.concat "" in
  grid_gutter ~selected Keeper_list_model.By_runtime verdict
  ^ fit_width (Terminal_text.single_line row.Keeper_list_model.keeper.Tui_decode.k_name) matrix.matrix_name_cells
  ^ " " ^ String.concat "" cells ^ " " ^ Theme.recede () ^ fit_width last 5 ^ Ansi.reset
  ^ pulse

let matrix_legend ~ko ~inner matrix =
  let ids = List.mapi (fun index id -> matrix_letter index ^ " " ^ Terminal_text.single_line id) matrix.matrix_ids in
  let omitted = if matrix.matrix_omitted = 0 then [] else
    [Printf.sprintf (if ko then "이 폭 밖 런타임 열 +%d" else "+%d runtime columns outside this width")
       matrix.matrix_omitted] in
  Printf.sprintf
    (if ko then "%s 지난 순회에서 실패 · %s 다음 실행 · %s 쉬는 중 · %s 못 읽음"
     else "%s failed in last walk · %s next head · %s resting head · %s unread head")
    Keeper_mark.attempt_glyph Keeper_mark.axis_next_glyph Keeper_mark.grid_wait_glyph
    Keeper_mark.unknown_mark
  :: Message_layout.wrap_words ~max_cells:inner (String.concat " · " (ids @ omitted))

let proactive_outcome_word ~ko =
  let text korean english = if ko then korean else english in
  function
  | Masc.Keeper_meta_contract.Proactive_never_started -> text "아직 시작하지 않음" "never started"
  | Masc.Keeper_meta_contract.Proactive_unknown -> text "결과 보고 안 됨" "outcome not reported"
  | Masc.Keeper_meta_contract.Proactive_silent -> text "응답 없이 종료" "silent"
  | Masc.Keeper_meta_contract.Proactive_text_response -> text "글로 응답함" "replied with text"
  | Masc.Keeper_meta_contract.Proactive_tool_use -> text "도구를 사용함" "used tools"
  | Masc.Keeper_meta_contract.Proactive_mixed_response -> text "글과 도구로 응답함" "text and tools"
  | Masc.Keeper_meta_contract.Proactive_error -> text "오류 보고" "error"
  | Masc.Keeper_meta_contract.Proactive_rested -> text "제공자 할당량을 기다림" "rested on a provider quota"

(* The awaiting flag turns on for every waiting change event and off at the
   next successful read. With a live roster that is a burst per event, so
   drawing the flag directly made header rows come and go with each burst.
   The age names how long the screen has actually been behind; only that,
   past the pending display bar, is worth a row or a word. *)
let keeper_waiting_refresh_slow state =
  match Keeper_waiting_read.awaiting_age state.keeper_waiting_read with
  | Some age when past_pending_display_bar age -> Some age
  | Some _ | None -> None

(* The line a slow waiting refresh is said on. Its slot is drawn on every
   frame, blank while the read keeps up: a line that came and went with each
   slow read moved every Keeper row below it (60 moves in 180s on a live
   list, 2026-11-17). *)
(* The fleet reading's own trouble: a lost stream or failing scans, while the
   last reading stays on screen. [None] while the reading is current. *)
let keeper_fleet_trouble_line state ~now =
  match fleet_stream_view state with
  | Masc_tui_fleet_stream.Reading { trouble = Some trouble; _ } ->
      Some
        (Theme.warn ()
         ^ ui_text state ~ko:"  관측 상태: " ~en:"  fleet reading: "
         ^ Masc_tui_fleet_line.trouble_text ~ko:(state.ui_language = Lang_ko) ~now trouble
         ^ Ansi.reset)
  | Masc_tui_fleet_stream.Reading { trouble = None; _ }
  | Masc_tui_fleet_stream.Awaiting_first_reading
  | Masc_tui_fleet_stream.Unreachable _
  | Masc_tui_fleet_stream.Cannot_read _
  | Masc_tui_fleet_stream.Unavailable _ -> None

let keeper_waiting_refresh_line state =
  match keeper_waiting_refresh_slow state with
  | None -> ""
  | Some age ->
      (* A length still going reads in whole seconds, then whole minutes
         (RFC tui-one-screen-grammar §6.2). *)
      let elapsed = Masc_tui_value.Ongoing.age ~now:(Unix.gettimeofday ())
          (Int64.to_float age /. 1e9) in
      Theme.warn ()
      ^ ui_text state
          ~ko:("  대기 목록 갱신 중 · 마지막 관측 표시 · " ^ elapsed)
          ~en:("  waiting refresh pending · last observation · " ^ elapsed)
      ^ Ansi.reset

(* Observation status warnings drawn above the divider only when a stream
   trouble, slow waiting refresh, or read failure is active. Returns [[]] when
   healthy so no blank row sits above or below column headers. *)
let keeper_observation_status_rows state ~now ~failure =
  match keeper_fleet_trouble_line state ~now, failure with
  | None, None ->
      let line = keeper_waiting_refresh_line state in
      if String.equal line "" then [] else [ line ]
  | Some trouble, None -> [ trouble ]
  | None, Some failure -> [ failure ]
  | Some trouble, Some failure -> [ trouble; failure ]

(* The operator roster uses the same row readings as the axis views. These
   sentences do not turn missing observations into idle work or no requests. *)
let keeper_plain_work ?now (state : state) (row : Keeper_list_model.row) =
  let text ko en = ui_text state ~ko ~en in
  match row.task with
  | Some task ->
      let title = Terminal_text.single_line task.Tui_decode.title in
      let title = if String.equal (String.trim title) "" then Terminal_text.single_line task.id else title in
      let task_source = match local_rows_page state ~error:state.tasks_error with
        | Page_failed -> text "배정 목록 갱신 실패 · 보존된 배정 작업: " "assignment refresh failed · retained assignment: "
        | Page_unread -> text "배정 목록 미조회 · 보존된 배정 작업: " "assignment source not read · retained assignment: "
        | Page_empty ->
            if Option.is_some (local_source_pending state Local_work) then
              text "배정 목록 갱신 중 · 보존된 배정 작업: " "assignment refresh pending · retained assignment: "
            else ""
      in
      let keeper_source = match keeper_rows_page state ~error:state.keepers_error with
        | Page_failed -> text "키퍼 배정 연결 갱신 실패 · " "Keeper assignment link refresh failed · "
        | Page_unread -> text "키퍼 배정 연결 미조회 · " "Keeper assignment link not read · "
        | Page_empty ->
            if Option.is_some (local_source_pending state Local_keepers) then
              text "키퍼 배정 연결 갱신 중 · " "Keeper assignment link refreshing · " else ""
      in
      (if row.reading.Keeper_control.paused then text "저장된 일시정지 · " "stored pause · " else "")
      ^ keeper_source ^ task_source ^ title
  | None ->
      let schedules =
        if Option.is_some state.schedules_agenda_error then None else state.schedules_agenda
      in
      (match keeper_waiting_detail ?schedules ?now
          ~ko:(state.ui_language = Lang_ko) row with
       | Some reason ->
           (if Option.is_some state.keeper_waiting_error || Option.is_some state.keeper_waiting_failure
               || Option.is_some state.keeper_turns_error then
              text "마지막 대기 관측 · 갱신 실패: " "last waiting observation · refresh failed: "
            else if Option.is_some (keeper_waiting_refresh_slow state) then
              text "마지막 대기 관측 · 갱신 대기: " "last waiting observation · refresh pending: "
            else "") ^ reason
       | None ->
           let observed ko en =
             (if Option.is_some state.keeper_turns_error then
                text "마지막 턴 관측 · 갱신 실패: " "last turn observation · refresh failed: "
              else if state.keeper_turns_inflight then
                text "마지막 턴 관측 · 갱신 중: " "last turn observation · refreshing: "
              else "") ^ text ko en
           in
           match row.turn with
           | Some (Tui_decode.Keeper_turn_running { preview = Some preview; _ }) ->
               let status = Terminal_text.single_line preview.ktp_status_text in
               if String.equal (String.trim status) "" then
                 observed "실행 중 · 작업 이름 보고 안 됨" "running · work title not reported"
               else observed status status
           | Some (Tui_decode.Keeper_turn_unavailable reason) ->
               text "실행 상태 조회 실패: " "execution read failed: " ^ Terminal_text.single_line reason
           | Some (Tui_decode.Keeper_turn_running { preview = None; _ }) ->
               observed "실행 중 · 작업 이름 보고 안 됨" "running · work title not reported"
           | Some Tui_decode.Keeper_turn_idle ->
               (* No running turn has no work to name. *)
               observed "실행 중인 턴 없음" "no running turn"
           | None -> text "현재 작업 미조회" "current work not read")

let keeper_plain_help ?now (state : state) (row : Keeper_list_model.row) =
  let text ko en = ui_text state ~ko ~en in
  match Keeper_list_model.person_wait row with
  | Some request ->
      let schedules =
        if Option.is_some state.schedules_agenda_error then None else state.schedules_agenda
      in
      let detail, retained = match request with
        | Keeper_list_model.Held_tool approval ->
            ( (let question = Terminal_text.single_line approval.Tui_decode.kta_question in
               if String.equal (String.trim question) "" then
                 text "도구 실행 승인: " "approve tool: " ^ Terminal_text.single_line approval.kta_tool
               else question)
            , Option.is_some state.keeper_tool_approvals_error )
        | Keeper_list_model.Open_questions count ->
            (text (Printf.sprintf "답하지 않은 질문 %d개" count)
               (Printf.sprintf "%d unanswered questions" count), Option.is_some state.asks_error)
        | Keeper_list_model.Held_item item | Keeper_list_model.Confirmation_item item ->
            keeper_waiting_item_text ?schedules ?now
              ~ko:(state.ui_language = Lang_ko) item,
            (Option.is_some state.keeper_waiting_error || Option.is_some state.keeper_waiting_failure
             || Option.is_some state.keeper_turns_error)
      in
      let prefix = if retained then text "마지막 관측 · 갱신 실패 · " "last observed · refresh failed · "
        else
            (match request with
             | Keeper_list_model.Held_item _ | Keeper_list_model.Confirmation_item _
               when Option.is_some (keeper_waiting_refresh_slow state) ->
                 text "마지막 관측 · 갱신 대기 · " "last observed · refresh pending · "
             | Keeper_list_model.Held_item _ | Keeper_list_model.Confirmation_item _
             | Keeper_list_model.Held_tool _ | Keeper_list_model.Open_questions _ -> "")
      in
      Some (prefix ^ detail)
  | None -> None

let keeper_plain_turn_record (state : state) ~now ~keeper_name =
  let text ko en = ui_text state ~ko ~en in
  (* The Story page owns this read. Ready only means its own last request
     completed, not that Plain has kept observing later turns. Even an empty
     successful page is retained here until the operator reopens Story. *)
  let retained =
    text "이전 관측 · Enter:스토리 재조회 · "
      "earlier reading · Enter:Story to reread · "
  in
  let observed turns =
    match List.rev turns with
    | [] -> text "조회된 턴 기록 없음" "no turn records in the reading"
    | (turn : Masc_tui_keeper_turns.turn) :: _ ->
        (* An age that does not read (a clock that moved backwards) says
           nothing, as [age_text] does. *)
        let ended = match Message_layout.age_text ~now ~since:turn.at with
          | Some age -> age ^ text " 전 종료 · " " ago ended · "
          | None -> ""
        in
        ended ^ (match turn.stop with
          | Masc_tui_keeper_turns.Stopped reason -> Terminal_text.single_line reason
          | Masc_tui_keeper_turns.No_stop_reason -> text "종료 사유 보고 안 됨" "stop reason not reported")
  in
  match Masc_tui_fetched.view_for ~equal:String.equal state.keeper_story_turns ~key:keeper_name with
  | Masc_tui_fetched.Absent -> text "턴 종료 기록 미조회 · Enter:스토리" "turn records not read · Enter:Story"
  | Masc_tui_fetched.Loading -> text "턴 종료 기록 조회 중" "reading turn records"
  | Masc_tui_fetched.Ready turns -> retained ^ observed turns
  | Masc_tui_fetched.Stale (turns, Request_failed reason) ->
      retained ^ text "갱신 실패: " "refresh failed: " ^ Terminal_text.single_line reason
      ^ " · " ^ observed turns
  | Masc_tui_fetched.Stale (turns, Request_withdrawn refusal) ->
      retained ^ workspace_refusal_text ~ko:(state.ui_language = Lang_ko)
        ~request:Kept_request.Keeper_turns_read refusal
      ^ " · " ^ observed turns
  | Masc_tui_fetched.Failed (Request_failed reason) ->
      text "턴 종료 기록 조회 실패: " "turn records read failed: " ^ Terminal_text.single_line reason
  | Masc_tui_fetched.Failed (Request_withdrawn refusal) ->
      workspace_refusal_text ~ko:(state.ui_language = Lang_ko)
        ~request:Kept_request.Keeper_turns_read refusal

let keeper_plain_result (state : state) (row : Keeper_list_model.row) =
  let ko = state.ui_language = Lang_ko in
  let text ko en = ui_text state ~ko ~en in
  match row.keeper.Tui_decode.k_activity with
  | Some { k_last_proactive_outcome = Some outcome; _ } ->
      text "최근 자율 턴: " "last autonomous cycle: " ^ proactive_outcome_word ~ko outcome
  | Some { k_last_proactive_outcome = None; _ } | None ->
      text "최근 자율 턴 결과 보고 안 됨" "last autonomous cycle outcome not reported"

let keeper_plain_detail_lines (state : state) ~now ~width ~compact row =
  let text ko en = ui_text state ~ko ~en in
  let fit value = Message_layout.fit_width value width in
  match row with
  | None -> [ Theme.recede () ^ fit (text "선택한 키퍼 없음" "no Keeper selected") ^ Ansi.reset ]
  | Some (row : Keeper_list_model.row) ->
      let help = match keeper_plain_help ~now state row with
        | Some request -> Theme.warn () ^ request ^ Ansi.reset
        | None ->
            let waiting_observed = match row.waiting with
              | Keeper_list_model.Waiting_observed _ -> true
              | Keeper_list_model.Waiting_unobserved | Keeper_list_model.Waiting_unavailable -> false
            in
            let requests_observed = waiting_observed
              && state.keeper_tool_approvals_observed && Option.is_some state.asks_snapshot
              && state.keeper_tool_approvals_error = None && state.asks_error = None
              && state.keeper_waiting_error = None && state.keeper_waiting_failure = None
              && state.keeper_turns_error = None
              && Option.is_none (keeper_waiting_refresh_slow state)
            in
            Theme.recede () ^ (if requests_observed then
              text "없음 · 승인에서 확인"
                "none observed · inspect Approvals"
            else text "승인에서 확인"
                "human waits: inspect Approvals") ^ Ansi.reset
      in
      let current = keeper_plain_work ~now state row in
      let result = keeper_plain_result state row in
      let name = Terminal_text.single_line row.keeper.Tui_decode.k_name in
      let route key label =
        key ^ Theme.recede () ^ ":" ^ label ^ Ansi.reset
      in
      let routes =
        [ String.concat "  "
            [ route "c" (text "대화·원래 요청" "chat / original request")
            ; route "→" (text "상세" "detail")
            ; route "Enter" (text "스토리" "Story")
            ]
        ; String.concat "  "
            [ route "Enter→m" (text "기억" "memory")
            ; route "J" (text "일정" "schedules")
            ; route "l" (text "로그" "logs")
            ]
        ]
      in
      let badge_plain =
        Masc_tui_keeper_mark.row_activity_glyph row ^ " "
        ^ keeper_row_activity_word ~ko:(state.ui_language = Lang_ko) row
      in
      let badge_cells = Message_layout.display_width badge_plain in
      let heading =
        if (not compact) && width >= badge_cells + 6 then
          let name_cells = width - badge_cells - 2 in
          Ansi.bold ^ Message_layout.fit_width name name_cells ^ Ansi.reset
          ^ "  " ^ keeper_activity_style row ^ badge_plain ^ Ansi.reset
        else
          Ansi.bold ^ fit name ^ Ansi.reset
      in
      if compact then
        let compact_result = match row.keeper.Tui_decode.k_activity with
          | Some { k_last_proactive_outcome = Some _; _ } -> result
          | Some { k_last_proactive_outcome = None; _ } | None ->
              keeper_plain_turn_record state ~now ~keeper_name:name
        in
        let field label value = Theme.recede () ^ label ^ Ansi.reset ^ value in
        heading
        :: List.map fit
          ([ field (text "현재 일  " "work  ") current
           ; field (text "도움  " "help  ") help
           ; field (text "최근 결과  " "last result  ") compact_result
           ] @ routes)
      else
        let section title content =
          let lines = Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 2)) content in
          let lines = match lines with
            | first :: second :: _ :: _ ->
                [first; Message_layout.fit_width (second ^ Message_layout.cut_mark) (max 1 (width - 2))]
            | [] | [ _ ] | [ _; _ ] -> lines
          in
          let title_cells = Message_layout.display_width title in
          let rule_cells = max 0 (width - title_cells - 1) in
          let header_line =
            if rule_cells >= 2 then
              Ansi.bold ^ title ^ Ansi.reset
              ^ Theme.recede () ^ " " ^ draw_hline rule_cells ^ Ansi.reset
            else
              Ansi.bold ^ fit title ^ Ansi.reset
          in
          header_line
          :: List.map (fun line -> "  " ^ fit_width line (max 0 (width - 2))) lines
        in
        let ko = state.ui_language = Lang_ko in
        let next_run =
          match state.schedules_agenda_error with
          | Some _ -> Masc_tui_keeper_next_run.Unknown
          | None -> Masc_tui_keeper_axis.next_run state ~keeper_name:row.keeper.Tui_decode.k_name
        in
        let next_text =
          match Masc_tui_keeper_next_run.cell ~ko ~now next_run with
          | Some cell ->
              let style =
                match cell.tone with
                | Masc_tui_keeper_axis_cell.Failure -> Theme.bad ()
                | Attention -> Theme.warn ()
                | Quiet -> Theme.recede ()
              in
              [ style ^ cell.text ^ Ansi.reset ]
          | None -> [ Theme.recede () ^ text "예정된 일정 없음" "no scheduled wake" ^ Ansi.reset ]
        in
        let mem_text =
          match keeper_memory_reading state row with
          | Memory_reading.Row { lag = Memory_reading.Lag n; gap; _ } when n > 0 ->
              let style =
                match gap with
                | Memory_reading.Gap _ | Memory_reading.Gap_unmeasured -> Theme.warn ()
                | Memory_reading.No_gap -> Theme.recede ()
              in
              let label =
                if ko then Printf.sprintf "기억 지연 %d턴" n
                else "memory lag " ^ Message_layout.count_noun n "turn"
              in
              [ style ^ label ^ Ansi.reset ]
          | Memory_reading.Row { lag = Memory_reading.Lag _; gap = (Memory_reading.Gap _ | Memory_reading.Gap_unmeasured); _ } ->
              [ Theme.warn () ^ text "기억 누락 구간 있음" "memory gap active" ^ Ansi.reset ]
          | Memory_reading.Row { lag = Memory_reading.Lag _; gap = Memory_reading.No_gap; _ } ->
              [ Theme.recede () ^ text "기억 지연 없음" "memory caught up" ^ Ansi.reset ]
          | Memory_reading.Row { lag = Memory_reading.Lag_unmeasured; _ } ->
              [ Theme.recede () ^ text "기억 지연 미측정" "memory lag unmeasured" ^ Ansi.reset ]
          | Memory_reading.Unknown ->
              [ Theme.recede () ^ text "기억 미조회" "memory unread" ^ Ansi.reset ]
          | Memory_reading.Refused _ ->
              [ Theme.bad () ^ text "기억 읽기 거부" "memory refused" ^ Ansi.reset ]
          | Memory_reading.No_row -> []
        in
        let schedule_and_memory =
          fit (String.concat (Theme.recede () ^ " · " ^ Ansi.reset) (next_text @ mem_text))
        in
        (* Compact metadata strip right under the heading keeps total minimum
           height at 14 rows so both hotkey route lines stay visible on a
           standard 24-row terminal. *)
        [heading; schedule_and_memory; ""]
        @ section (text "지금 하는 일" "Current work") current
        @ [""] @ section (text "사람의 도움" "Human wait") help
        @ [""] @ section (text "최근 관측 결과" "Observed result")
            (result ^ Theme.recede () ^ " · " ^ Ansi.reset
             ^ keeper_plain_turn_record state ~now ~keeper_name:name)
        @ [""] @ List.map fit routes

let keeper_pulse_counts_header (state : state) ~now ~inner ~selected_row all_rows =
  let selected = Option.map (fun row -> row.Keeper_list_model.keeper.Tui_decode.k_name) selected_row in
  let header = Masc_tui_keeper_strip.header ~ko:(state.ui_language = Lang_ko) ~now ~cells:inner
      ~view:state.keeper_list_view ~selected
      ~age:(fun row -> (Masc_tui_keeper_axis.outside state ~now
          ~keeper_name:row.Keeper_list_model.keeper.Tui_decode.k_name).age) all_rows in
  if String.equal header "" then [] else [ header ]

let keeper_grid_fleet_row (state : state) ~now ~(grid : Grid.t) all_rows =
  match state.keeper_list_view with
  | Keeper_list_model.By_age | Keeper_list_model.By_memory -> None
  | Keeper_list_model.(Plain | By_state | By_cause | By_time | By_runtime | Day_wall) ->
      Option.map
        (fun (fleet : Masc_tui_keeper_strip.fleet_cells) ->
           grid_line grid
             { gutter = String.make Grid.gutter_cells ' '; name = fit_width fleet.name grid.name_cells
             ; pulse = fleet.pulse; now_cell = grid_blank_now; strip = fleet.strip
             ; due = fit_width fleet.due Grid.due_cells; right = String.make grid.mem_cells ' ' })
        (Masc_tui_keeper_strip.fleet_cells
           ~summarize_wakes:(state.keeper_list_view = Keeper_list_model.By_state)
           ~ko:(state.ui_language = Lang_ko) ~now ~grid
           ~wakes:(fun row -> Masc_tui_keeper_axis.wake_strip state ~now
             ~ahead:grid.side_cells ~keeper_name:row.Keeper_list_model.keeper.Tui_decode.k_name) all_rows)

let keeper_selected_summary (state : state) ~now (row : Keeper_list_model.row) =
  let keeper_name = row.keeper.Tui_decode.k_name in
  let now_cell = keeper_now_cell ~ko:(state.ui_language = Lang_ko)
      ~padded:false row in
  Masc_tui_keeper_strip.selected_summary ~ko:(state.ui_language = Lang_ko) ~now
    ~activity_cell:now_cell
    ~next_run:(match state.schedules_agenda_error with
      | Some _ -> Masc_tui_keeper_next_run.Unknown
      | None -> Masc_tui_keeper_axis.next_run state ~keeper_name)
    ~recurrence:(Masc_tui_keeper_axis.next_recurrence state ~keeper_name)
    ~memory:(keeper_memory_reading state row) row

let draw_keeper_selected_summary buf ~cols summary = box_line buf cols ("  " ^ summary)

let keeper_plain_fleet_lines (state : state) ~now ~inner =
  let text ko en = ui_text state ~ko ~en in
  let ko = state.ui_language = Lang_ko in
  let warning value = Theme.warn () ^ "  " ^ value ^ Ansi.reset in
  match fleet_stream_view state with
  | Masc_tui_fleet_stream.Awaiting_first_reading ->
      [Theme.recede () ^ text "  운영 상태 미조회" "  fleet status not read" ^ Ansi.reset]
  | Masc_tui_fleet_stream.Unreachable { since } ->
      [warning (Masc_tui_fleet_line.unreachable_text ~ko ~now ~since)]
  | Masc_tui_fleet_stream.Cannot_read failure ->
      [warning (Masc_tui_fleet_line.failure_text ~ko failure)]
  | Masc_tui_fleet_stream.Unavailable { degradation; disconnected_since } ->
      [warning (Masc_tui_fleet_line.unavailable_text ~ko ~now ~degradation ~disconnected_since)]
  | Masc_tui_fleet_stream.Reading { reading = { fleet; _ }; trouble } ->
      let lead = (match trouble with
        | None -> text "운영 관측: " "fleet observation: "
        | Some (Masc_tui_fleet_stream.Scans_failing _ | Masc_tui_fleet_stream.Disconnected _) ->
            text "마지막 운영 관측: " "last fleet observation: ")
        ^ Masc_tui_fleet_line.status_text ~ko fleet.fs_status
      in
      let clauses = lead :: Option.to_list (Masc_tui_fleet_line.blocker_text ~ko fleet)
        @ [text
             (Printf.sprintf "실행 %d/%d" fleet.fs_running_count fleet.fs_bootable_count)
             (Printf.sprintf "running %d/%d" fleet.fs_running_count fleet.fs_bootable_count)
           ; Masc_tui_fleet_line.proactive_text ~ko fleet ]
      in
      let tone = match trouble with
        | Some _ -> Theme.warn ()
        | None -> if fleet.fs_operator_action_required then Theme.bad ()
            else if Masc_tui_fleet_line.status_is_ok fleet.fs_status then Theme.ok ()
            else Theme.warn ()
      in
      [tone ^ "  " ^ Message_layout.join_fitting ~sep:" · " ~cells:(max 0 (inner - 2)) clauses ^ Ansi.reset]

let keeper_observation_errors (state : state) =
  let text korean english = if state.ui_language = Lang_ko then korean else english in
  List.filter_map Fun.id
    [ Option.map (fun e -> (text "목록" "roster metadata", e)) state.keepers_error
    ; Option.map (fun e -> (text "실행 관측" "live roster", e)) state.keeper_roster_error
    ; Option.map (fun e -> (text "턴 관측" "turn observation",
        request_failure_text ~ko:(state.ui_language = Lang_ko)
          ~request:Kept_request.Turn_observation_read e)) state.keeper_turns_error
    ; Option.map (fun e -> (text "대기 목록" "waiting inventory",
        request_failure_text ~ko:(state.ui_language = Lang_ko)
          ~request:Kept_request.Waiting_list_read e)) state.keeper_waiting_error
    ; Option.map (fun e -> (text "별도 실행" "async observation",
        request_failure_text ~ko:(state.ui_language = Lang_ko)
          ~request:Kept_request.Async_requests_read e)) state.tools_async_observation_error
    ; Option.map (fun e -> (text "승인 요청" "approval reading", e)) state.keeper_tool_approvals_error
    ; Option.map (fun e -> (text "질문" "questions", e)) state.asks_error
    ]

let keeper_observation_reading (state : state) =
  match keeper_observation_errors state with
  | [] -> None
  | errors ->
      let ko = state.ui_language = Lang_ko in
      Some (Masc_tui_detail_reading.create ~ko
        ~title:(if ko then "키퍼 관측 오류" else "Keeper observation errors")
        (List.map (fun (heading, body) ->
          ({heading; body} : Masc_tui_detail_reading.section)) errors))

(* The selected row among the rows the list draws, counted from one. A group
   heading or the World row selects no Keeper. *)
let keeper_list_position ~stop rows : Masc_tui_value.Position.t option =
  match rows with
  | [] -> None
  | _ :: _ ->
      let selected =
        match stop with
        | Some (Keeper_list_model.Stop_row position) -> Some position
        | Some (Keeper_list_model.Stop_world | Keeper_list_model.Stop_heading _)
        | None -> None
      in
      Some (Masc_tui_value.Position.row ~selected ~total:(List.length rows))

(* Shared top header stack across every Keeper List view:
   1. Zone 2 title & position (row 2 — no leading blank line)
   2. View tab strip + sort/(optional density) controls (locked on row 3 so
      cycling [v] never shifts the tabs vertically)
   3. Single compact fleet line
   4. Concise health counts summary
   5. Optional folded observation/roster/fleet warnings (0 lines when healthy),
      capped by [cap_keeper_headers] so a burst of warnings never evicts the
      roster. *)
let keeper_list_top_headers (state : state) ~now ~cols ~inner ~selected_reading
    ~selected_row ~stop ~model_rows ~all_rows =
  let ko = state.ui_language = Lang_ko in
  let text k e = ui_text state ~ko:k ~en:e in
  let warning prefix reason =
    Theme.warn () ^ "  " ^ prefix ^ Terminal_text.single_line reason ^ Ansi.reset
  in
  let cells = max 0 (inner - 2) in
  let errors =
    match keeper_observation_errors state with
    | [] -> []
    | [ (label, reason) ] ->
      [ warning "" (Message_layout.fit_width
          (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Caution ^ " " ^ label ^ ": " ^ Terminal_text.single_line reason) cells) ]
    | many ->
      let prefix =
        Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Caution ^ (if ko then Printf.sprintf " 원문 · 오류 %d종: " (List.length many)
        else Printf.sprintf " details · %d errors: " (List.length many)) in
      let labels = String.concat " · " (List.map fst many) in
      [ warning "" (Message_layout.fit_width (prefix ^ labels) cells) ]
  in
  let fleet_gaps =
    match fleet_stream_view state with
    | Masc_tui_fleet_stream.Reading { reading = { fleet; _ }; _ } ->
        List.map
          (fun (color, label, names) ->
            Printf.sprintf "%s  %s: %s%s" color label
              (Terminal_text.single_line names) Ansi.reset)
          (keeper_fleet_gap_lines ~ko fleet)
    | Masc_tui_fleet_stream.Awaiting_first_reading
    | Masc_tui_fleet_stream.Unreachable _
    | Masc_tui_fleet_stream.Cannot_read _
    | Masc_tui_fleet_stream.Unavailable _ -> []
  in
  let roster = match Keeper_control.roster_view state.keeper_roster with
    | Keeper_control.Roster_partial { observed; total } ->
        [warning "" (text
           (Printf.sprintf "일부 관측 %d/%d · 나머지는 미조회" (List.length observed) total)
           (Printf.sprintf "partial reading %d/%d · the rest not read" (List.length observed) total))]
    | Keeper_control.Roster_invalid { errors; _ } ->
        [warning "" (text
           (Printf.sprintf "설정 읽기 오류 %d개 · 상세에서 확인" (List.length errors))
           (Printf.sprintf "%d configuration read errors · inspect detail" (List.length errors)))]
        @ (match selected_reading with
          | Some { Keeper_control.liveness = Keeper_control.Invalid detail; _ } -> [warning "" detail]
          | Some { Keeper_control.liveness = (Keeper_control.Unobserved | Keeper_control.Absent | Keeper_control.Present _); _ }
          | None -> [])
    | Keeper_control.Roster_unobserved ->
        [Theme.recede () ^ text "  실행 상태 미조회 · 저장된 목록 표시"
           "  live status not read · showing stored roster" ^ Ansi.reset]
    | Keeper_control.Roster_complete _ -> []
  in
  let failure = match state.keeper_waiting_failure with
    | Some (Tui_decode.Keeper_waiting_invalid reason) -> Some (warning (text "대기 관측 조회 실패: " "waiting read failed: ") reason)
    | Some (Tui_decode.Keeper_waiting_sources_unavailable errors) ->
        let failure = text "대기 원본을 읽지 못했습니다" "waiting sources unavailable" in
        let failure = match keeper_waiting_failure_reasons ~ko errors with
          | [] -> failure
          | reasons -> failure ^ ": " ^ String.concat ", " reasons
        in
        Some (warning "" (Message_layout.fit_width
           (failure ^ text " · 대기 목록이 업무 차단을 뜻하지는 않습니다"
              " · inventory is not a work blocker") cells))
    | None -> None
  in
  let waiting = keeper_observation_status_rows state ~now ~failure in
  let waiting_failed = Option.is_some state.keeper_waiting_failure in
  let keepers_error = Terminal_text.optional_single_line state.keepers_error in
  let title_readings =
    match state.keepers, keeper_rows_page state ~error:keepers_error with
    | [], (Page_unread | Page_failed) ->
        [ here_missing_reading state ~error:keepers_error ]
    | (_ :: _ | []), (Page_empty | Page_unread | Page_failed) ->
        if errors <> [] || roster <> [] || waiting_failed then
          [ Theme.warn () ^ text "일부 관측" "partial reading" ^ Ansi.reset ]
        else []
  in
  [ here_row ~cols state ~path:[]
      ~readings:title_readings
      ~position:(keeper_list_position ~stop model_rows)
  ; keeper_view_tabs ~ko ~cols
      ~sort:state.keeper_list_sort ~density:state.keeper_list_density
      state.keeper_list_view
  ]
  @ keeper_plain_fleet_lines state ~now ~inner
  @ keeper_pulse_counts_header state ~now ~inner ~selected_row all_rows
  @ errors @ fleet_gaps @ roster @ waiting
  @ Option.to_list (Option.map (warning (text "보기 설정: " "view preferences: ")) state.keeper_list_preference_notice)
  @ Option.to_list (local_source_pending_note state Local_keepers)

let cap_keeper_headers (state : state) ~inner ~budget headers =
  if List.length headers <= budget then headers
  else match List.take budget headers with
    | [] -> []
    | kept ->
        let last = List.length kept - 1 in
        let suffix =
          Theme.recede ()
          ^ ui_text state
              ~ko:(Printf.sprintf " · 보기 %d행 생략" (List.length headers - budget))
              ~en:(Printf.sprintf " · %d header rows omitted" (List.length headers - budget))
          ^ Ansi.reset
        in
        let suffix_cells = Message_layout.display_width suffix in
        List.mapi (fun index row ->
          if index <> last then row
          else if inner > suffix_cells then
            fit_width row (inner - suffix_cells) ^ suffix
          else
            fit_width suffix inner) kept

type keeper_plain_projection =
  { kpp_headers : string list
  ; kpp_list_width : int
  ; kpp_detail_width : int option
  ; kpp_detail_lines : string list
  ; kpp_list_rows : int
  ; kpp_entry_rows : int
  ; kpp_window : keeper_display_entry list
  ; kpp_page : int
      (* the stops a window of [kpp_entry_rows] always holds whole, which a
         page key moves by less one ([Masc_tui_scroll.items_always_shown]) *)
  ; kpp_scroll : int
  ; kpp_count : int
  ; kpp_density : Keeper_list_model.density
  ; kpp_selected_reading : Keeper_control.reading option
  ; kpp_selected_summary : string option
  }

let keeper_plain_entry_height density = function
  | Keeper_world -> 0
  | Keeper_group_heading _ -> 1
  | Keeper_display_row _ -> match density with
    | Keeper_list_model.One_line -> 1
    | Keeper_list_model.Two_lines -> 2

let keeper_plain_projection (state : state) ~terminal_rows ~cols ~now =
  let inner = max 1 (framed_inner_width cols) in
  let reading = keeper_list_reading state in
  let stop = keeper_list_stop state in
  let selected_row = match stop with
    | Some (Keeper_list_model.Stop_row position) -> List.nth_opt reading.klr_rows position
    | Some (Keeper_list_model.Stop_world | Keeper_list_model.Stop_heading _) | None -> None
  in
  let selected_reading = Option.map (fun (row : Keeper_list_model.row) -> row.reading) selected_row in
  let rows = surface_body_rows state ~terminal_rows in
  let entries = keeper_display_entries ~view:state.keeper_list_view ~folded:state.keeper_list_folded reading in
  let desired_heights = List.map (keeper_plain_entry_height state.keeper_list_density) entries in
  let side_by_side = cols >= Masc_tui_roster_pane.threshold_cols in
  let list_width = if side_by_side then max 1 ((inner - 3) * 2 / 5) else inner in
  let detail_width = if side_by_side then Some (max 1 (inner - list_width - 3)) else None in
  let detail = keeper_plain_detail_lines state ~now
      ~width:(Option.value detail_width ~default:inner) ~compact:(not side_by_side) selected_row in
  let list_floor = 1 + List.fold_left max 1 desired_heights + (if List.length entries > 1 then 1 else 0) in
  let selected_summary = match state.keeper_story, selected_row with
    | None, Some row when (not side_by_side) && rows - 1 - 2 > list_floor ->
        Some (keeper_selected_summary state ~now row)
    | (Some _ | None), (Some _ | None) -> None in
  let summary_rows = match selected_summary with Some _ -> 1 | None -> 0 in
  let headers =
    keeper_list_top_headers state ~now ~cols ~inner ~selected_reading
      ~selected_row ~stop ~model_rows:reading.klr_rows ~all_rows:reading.klr_all_rows
  in
  (* A long list of failed reads must not evict the selectable Keeper or the
     action footer. Keep a useful list and its selected summary first; top
     headers then take rows up to [header_budget] above the header divider. *)
  let body_floor = min (list_floor + summary_rows) (max 1 (rows - 1 - 2 - 1)) in
  let header_budget = max 0 (rows - 1 - 2 - body_floor) in
  let headers = cap_keeper_headers state ~inner ~budget:header_budget headers in
  (* One divider sits below [headers] and two rows (divider + footer) sit below
     the body; there is no leading blank line so Zone 2 starts on row 2. *)
  let body_rows = max 0 (rows - List.length headers - 1 - 2 - summary_rows) in
  let detail_budget = match detail_width with
    | Some _ -> body_rows
    | None ->
        min (List.length detail) (max 0 (body_rows - list_floor - 1))
  in
  let detail_lines =
    if List.length detail <= detail_budget then detail
    else if detail_budget = 0 then []
    else List.take (detail_budget - 1) detail
      @ [Theme.recede () ^ ui_text state ~ko:"→:상세에서 이어 보기" ~en:"→:continue in detail" ^ Ansi.reset]
  in
  let list_rows = match detail_width with
    | Some _ -> body_rows
    | None -> body_rows - List.length detail_lines - (if detail_lines = [] then 0 else 1)
  in
  let content_rows = max 0 (list_rows - if list_rows > 1 then 1 else 0) in
  let density = match state.keeper_list_density with
    | Keeper_list_model.Two_lines when content_rows = 1 -> Keeper_list_model.One_line
    | Keeper_list_model.Two_lines -> Keeper_list_model.Two_lines
    | Keeper_list_model.One_line -> Keeper_list_model.One_line
  in
  let heights = List.map (keeper_plain_entry_height density) entries in
  (* Where the cursor stands is on the title row, so every row draws entries. *)
  let entry_rows = content_rows in
  let cursor = Option.value ~default:0 (List.find_index (keeper_entry_selected stop) entries) in
  let scroll, count = Masc_tui_scroll.window_of_heights ~heights ~cursor ~rows:entry_rows state.keeper_list_scroll in
  { kpp_headers = headers; kpp_list_width = list_width; kpp_detail_width = detail_width
  ; kpp_detail_lines = detail_lines; kpp_list_rows = list_rows; kpp_entry_rows = entry_rows
  ; kpp_window = List.take count (List.drop scroll entries); kpp_scroll = scroll
  ; kpp_page = Masc_tui_scroll.items_always_shown ~heights ~rows:entry_rows
  ; kpp_count = List.length reading.klr_rows
  ; kpp_density = density
  ; kpp_selected_reading = selected_reading; kpp_selected_summary = selected_summary }

let keeper_plain_list_lines (state : state) ~now projection =
  let width = projection.kpp_list_width in
  let text ko en = ui_text state ~ko ~en in
  let stop = keeper_list_stop state in
  let entry_lines = function
    | Keeper_world -> []
    | Keeper_group_heading (group, count) as entry ->
        let selected = keeper_entry_selected stop entry in
        let heading =
          (if selected then "\xe2\x80\xba " else "  ")
          ^ (if List.mem group state.keeper_list_folded then Keeper_mark.grid_folded_mark
             else Keeper_mark.grid_open_mark) ^ " "
          ^ keeper_group_heading_text ~ko:(state.ui_language = Lang_ko)
              ~available_cells:(max 1 (width - 4)) (keeper_list_rows state) group count in
        [ if selected then
            Theme.sidebar_selection () ^ fit_width (Masc_tui_theme.strip_sgr heading) width ^ Ansi.reset
          else
            fit_width (keeper_group_heading_style group ^ heading ^ Ansi.reset) width ]
    | Keeper_display_row (_, row) as entry ->
        let selected = keeper_entry_selected stop entry in
        let name_width = max 1 (width - Render_schedule.keeper_marker_width - Render_schedule.keeper_status_width - 1) in
        let yolo = List.mem row.Keeper_list_model.keeper.Tui_decode.k_name state.keeper_yolo_names in
        let prefix = keeper_row_marker ~selected
          ^ keeper_row_name ~width:name_width ~yolo row ^ " " in
        let now_cell = keeper_now_cell ~ko:(state.ui_language = Lang_ko) row in
        let primary = prefix ^ now_cell in
        let emit value =
          let value = fit_width value width in
          let value =
            if selected then
              Theme.sidebar_selection () ^ Masc_tui_theme.strip_sgr value ^ Ansi.reset
            else value
          in
          pressable (Press_keeper_row row.keeper.Tui_decode.k_name) value
        in
        let primary = emit primary in
        match projection.kpp_density with
        | Keeper_list_model.One_line -> [primary]
        | Keeper_list_model.Two_lines ->
            let detail = match keeper_plain_help ~now state row with
              | Some request -> Theme.warn () ^ request ^ Ansi.reset
              | None -> Theme.recede () ^ keeper_plain_work ~now state row ^ Ansi.reset
            in
            [primary; emit ("  " ^ Message_layout.fit_width detail (max 0 (width - 2)))]
  in
  let content = List.concat_map entry_lines projection.kpp_window in
  let content = if content <> [] || projection.kpp_entry_rows = 0 then content else
    [Theme.recede () ^ (if projection.kpp_count > 0 then text "창이 좁아 행 표시 불가" "window too short for a row"
       else match keeper_rows_page state ~error:(Terminal_text.optional_single_line state.keepers_error) with
         | Page_empty -> text "조회된 키퍼 없음" "Keeper roster empty"
         | Page_unread -> text "키퍼 목록 미조회" "Keeper roster not read"
         | Page_failed -> text "키퍼 목록 읽기 실패" "Keeper roster read failed") ^ Ansi.reset]
  in
  if projection.kpp_list_rows = 0 then [] else
    (if projection.kpp_list_rows > 1 then
      let lead = "  " ^ text "키퍼 목록" "Keepers" in
      let sub = text " · 현재 상태 / 일과 대기" " · current status / work and wait" in
      let lead_cells = Message_layout.display_width lead in
      let header_row =
        if width > lead_cells + 4 then
          Ansi.bold ^ lead ^ Ansi.reset
          ^ Theme.recede () ^ fit_width sub (width - lead_cells) ^ Ansi.reset
        else
          Theme.recede () ^ fit_width (lead ^ sub) width ^ Ansi.reset
      in
      [ header_row ]
     else [])
    @ content
    @ List.init (max 0 (projection.kpp_entry_rows - List.length content)) (fun _ -> "")

let render_keeper_plain (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.gettimeofday () in
  let projection = keeper_plain_projection state ~terminal_rows ~cols ~now in
  report_drawn_list Keeper_stops ~height:projection.kpp_page;
  let buf = Buffer.create 4096 in
  List.iter (box_line buf cols) projection.kpp_headers;
  box_divider buf cols;
  let roster = keeper_plain_list_lines state ~now projection in
  (match projection.kpp_detail_width with
   | None ->
       List.iter (box_line buf cols) roster;
       if projection.kpp_detail_lines <> [] then box_divider buf cols;
       List.iter (box_line buf cols) projection.kpp_detail_lines
   | Some detail_width ->
       List.iteri
         (fun position left ->
           let right = Option.value (List.nth_opt projection.kpp_detail_lines position) ~default:"" in
           box_line buf cols (fit_width left projection.kpp_list_width ^ Theme.recede () ^ " │ " ^ Ansi.reset
                              ^ fit_width right detail_width))
         roster);
  Option.iter (draw_keeper_selected_summary buf ~cols) projection.kpp_selected_summary;
  box_divider buf cols;
  Buffer.add_string buf
    (footer_line state ~status:(keeper_action_status state) ~max_cells:cols
       ~hints:(keeper_control_hints ~keys:Roster_keys state projection.kpp_selected_reading));
  finish_surface state ~clamped:(Keeper_list_scroll projection.kpp_scroll)
    ~surface_key:"keeper-list" ~rows:terminal_rows ~cols buf

let render_keeper_axes (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let inner = max 1 (framed_inner_width cols) in
  let list_reading = keeper_list_reading state in
  let model_rows = list_reading.klr_rows in
  let all_rows = list_reading.klr_all_rows in
  let stop = keeper_list_stop state in
  (* Selection already follows this ordered model in list mode. Reuse it in
     this synchronous draw rather than rebuilding it through selected_keeper.
     A heading selects no Keeper. *)
  let selected_row =
    match stop with
    | Some (Keeper_list_model.Stop_row position) -> List.nth_opt model_rows position
    | Some (Keeper_list_model.Stop_world | Keeper_list_model.Stop_heading _) | None -> None
  in
  let selected_reading =
    Option.map (fun (row : Keeper_list_model.row) -> row.reading) selected_row
  in
  let keepers_error = Terminal_text.optional_single_line state.keepers_error in

  (* One observation time for stale fleet readings and roster turn ages. *)
  let now_unix = Unix.gettimeofday () in
  let grid = Grid.layout ~cols:inner in
  let ko = state.ui_language = Lang_ko in
  let shape = Axis_row.shape_of_view state.keeper_list_view in
  let matrix = match state.keeper_list_view with
    | Keeper_list_model.By_runtime -> Some (runtime_matrix ~inner model_rows)
    | Keeper_list_model.(Plain | By_state | By_cause | By_time | By_memory | By_age | Day_wall) -> None in
  let grid_fleet_row =
    match matrix, shape with
    | None, Axis_row.Grid _ -> keeper_grid_fleet_row state ~now:now_unix ~grid all_rows
    | Some _, _ | None, (Axis_row.Wall_columns | Axis_row.List_columns) -> None
  in
  let col_header_rows =
    match matrix, shape with
    | Some _, _ -> 1
    | None, Axis_row.Wall_columns -> 2
    | None, Axis_row.List_columns -> 1
    | None, Axis_row.Grid _ -> 1 + if Option.is_some grid_fleet_row then 1 else 0
  in
  (* Cap top headers just like [keeper_plain_projection] so observation or
     fleet warnings never evict the roster rows or footer. *)
  let summary_floor =
    if Option.is_none state.keeper_story && Option.is_some selected_row then 1 else 0
  in
  let max_headers = max 0 (rows - 1 (* divider *) - col_header_rows - 2 (* footer *)) in
  let top_header_budget =
    min max_headers
      (max 2 (rows - 1 (* divider *) - col_header_rows - 2 (* min roster *) - summary_floor - 2 (* footer *)))
  in
  let top_headers =
    keeper_list_top_headers state ~now:now_unix ~cols ~inner ~selected_reading
      ~selected_row ~stop ~model_rows ~all_rows
    |> cap_keeper_headers state ~inner ~budget:top_header_budget
  in
  List.iter (box_line buf cols) top_headers;

  (* Measured over every reading rather than the rows on screen, so the
     columns do not move while a reader scrolls. The measured sentence is not
     drawn, so the ages it reads ask for no redraw; the rows drawn below note
     their own. *)
  let failure_sentence_cells (row : Keeper_list_model.row) =
    Masc_tui_value.Redraw.measuring (fun () ->
      let age ended_at =
        Option.map (fun _ -> widest_age_text) (keeper_trail_age ~now:now_unix ended_at)
      in
      match keeper_row_trail_sentence ~ko ~age row with
      | Some sentence -> Message_layout.display_width sentence
      | None -> 0)
  in
  let has_failing_keeper =
    List.exists (fun row -> failure_sentence_cells row > 0) model_rows
  in
  let widest_detail =
    List.fold_left
      (fun widest (row : Keeper_list_model.row) ->
        let failure_width = failure_sentence_cells row in
        let next_width =
          match keeper_next_text ~ko ~now:now_unix row with
          | None -> 0
          | Some text ->
            let task_w =
              match keeper_task_detail ~tasks:state.tasks ~ko row with
              | None -> 0
              | Some t -> Message_layout.display_width t + 3
            in
            task_w + Message_layout.display_width text
        in
        max widest (max failure_width next_width))
      0 model_rows
  in
  let widest_runtime =
    List.fold_left
      (fun widest (row : Keeper_list_model.row) ->
        let reading = row.reading in
        let runtime =
          match reading.Keeper_control.liveness with
          | Keeper_control.Present row -> Some row
          | Keeper_control.Absent | Keeper_control.Unobserved
          | Keeper_control.Invalid _ -> None
        in
        max widest (max (failure_sentence_cells row) (keeper_runtime_cells runtime)))
      0 model_rows
  in
  let columns =
    Render_schedule.allocate_keeper_columns
      (* One line gives the available row to the current work. Two lines
         keep the explicit runtime column and state the detail once, on the
         second row (RFC-0515 P2). *)
      ~runtime_visible:(match state.keeper_list_density with
        | Keeper_list_model.Two_lines -> true
        | Keeper_list_model.One_line -> false)
      ~detail_beside_runtime:(match state.keeper_list_density with
        | Keeper_list_model.Two_lines -> false
        | Keeper_list_model.One_line -> true)
      ~prioritize_runtime:has_failing_keeper ~inner_width:inner
      ~widest_runtime ~widest_detail ()
  in
  let peak_lag = axis_peak_lag state model_rows in
  let peak_facts = axis_peak_facts state model_rows in
  box_divider buf cols;
  (match matrix, shape with
   | Some matrix, (Axis_row.List_columns | Axis_row.Wall_columns | Axis_row.Grid _) ->
       box_line_styled buf cols ~style:(Theme.recede ())
         (matrix_header ~ko matrix)
   | None, Axis_row.Wall_columns ->
       box_line buf cols
         (Masc_tui_keeper_wall.header ~ko ~cols:inner ~now:now_unix);
       box_line buf cols (Masc_tui_keeper_wall.fleet ~ko
         ~cols:inner ~now:now_unix (List.map keeper_row_runtime model_rows))
   | None, Axis_row.List_columns ->
       box_line_styled buf cols ~style:(Theme.recede ())
         (keeper_column_header ~ko columns)
   | None, Axis_row.Grid grid_columns ->
       box_line buf cols (grid_header state grid grid_columns);
       Option.iter (box_line buf cols) grid_fleet_row);

  let chrome_rows = count_frame_lines buf in
  let footer_rows = 2 in
  let keeper_count = List.length model_rows in
  let second_line (row : Keeper_list_model.row) =
    Axis_row.second_line state.keeper_list_view state.keeper_list_density
      (Keeper_list_model.trail_of_row row)
  in
  (* A heading is one line whatever the density. *)
  let wall_separator position =
    match shape, List.nth_opt model_rows position, List.nth_opt model_rows (max 0 (position - 1)) with
    | Axis_row.Wall_columns, Some row, Some previous when position > 0 ->
        Masc_tui_keeper_wall.group ~now:now_unix (keeper_row_runtime row) <>
        Masc_tui_keeper_wall.group ~now:now_unix (keeper_row_runtime previous)
    | (Axis_row.Wall_columns | Axis_row.List_columns | Axis_row.Grid _), (Some _ | None), (Some _ | None) -> false in
  let entry_lines = function
    | Keeper_world | Keeper_group_heading _ -> 1
    | Keeper_display_row (position, row) ->
        (if wall_separator position then 1 else 0) +
        (match second_line row with
        | Axis_row.No_second_line -> 1
        | Axis_row.List_detail | Axis_row.Failure_chain -> 2)
  in
  let entries = keeper_display_entries ~view:state.keeper_list_view ~folded:state.keeper_list_folded list_reading in
  let portrait_candidate =
    (* The portrait and the Story window both want the rows under the list. *)
    if Option.is_some state.keeper_story then None
    else
    match
      Keeper_list_model.shows_portrait state.keeper_list_view state.keeper_list_density,
      selected_reading
    with
    | true, Some reading -> (
        match reading.Keeper_control.liveness with
        | Keeper_control.Present runtime -> (
            match runtime.Tui_decode.kr_portrait with
            | Tui_decode.Ready equipment ->
                Option.map (fun portrait -> reading.Keeper_control.name, portrait)
                  (Masc_tui_chat_portrait.shown ~figure:Masc_tui_chat_portrait.Whole_body
                     ~name:reading.Keeper_control.name
                     ~portrait:(Keeper_portrait_equipment.Ready equipment)
                     ~rows ~cols)
            | Tui_decode.Unavailable _ -> None)
        | Keeper_control.Unobserved | Keeper_control.Absent
        | Keeper_control.Invalid _ -> None)
    | true, None | false, _ -> None
  in
  let portrait_list_rows =
    let target = min 4 keeper_count in
    target * 2 + if keeper_count > target then 1 else 0
  in
  let portrait =
    match portrait_candidate with
    | Some (_, portrait) as candidate
      when portrait.Masc_tui_chat_portrait.roster_rows - chrome_rows - footer_rows
           >= portrait_list_rows -> candidate
    | Some _ | None -> None
  in
  let roster_rows =
    match portrait with
    | None -> rows
    | Some (_, portrait) -> portrait.Masc_tui_chat_portrait.roster_rows
  in
  let available_rows = max 0 (roster_rows - chrome_rows - footer_rows) in
  let story_rows =
    match state.keeper_story with
    | Some (Masc_tui_keeper_story.Story | Masc_tui_keeper_story.Schedule
            | Masc_tui_keeper_story.Memory | Masc_tui_keeper_story.World) ->
        Masc_tui_render_keeper_story.rows ~budget:available_rows
    | None -> 0
  in
  let selected_summary = match state.keeper_story, selected_row with
    | None, Some row when available_rows > 0 ->
        Some (keeper_selected_summary state ~now:now_unix row)
    | (Some _ | None), (Some _ | None) -> None in
  let summary_rows = match selected_summary with Some _ -> 1 | None -> 0 in
  let content_rows = max 0 (available_rows - story_rows - summary_rows) in
  let legend = match matrix with
    | None -> []
    | Some matrix ->
        List.take (max 0 (content_rows - 2))
          (matrix_legend ~ko:(state.ui_language = Lang_ko) ~inner matrix) in
  let content_rows = max 0 (content_rows - List.length legend) in
  Option.iter
    (fun (name, portrait) ->
      box_line buf cols
        (Theme.recede () ^ ui_text state ~ko:"  선택됨 · " ~en:"  selected · "
         ^ Terminal_text.single_line name ^ Ansi.reset);
      let picture_row = count_frame_lines buf in
      List.iter (box_line buf cols) portrait.Masc_tui_chat_portrait.picture_lines;
      box_line buf cols "";
      Option.iter
        (fun (placement : Masc_tui_portrait_view.placement) ->
          Masc_tui_portrait_view.request
            { placement with row = picture_row + strip_rows })
        portrait.Masc_tui_chat_portrait.placement)
    portrait;

  let heights = List.map entry_lines entries in
  (* Where the cursor stands is on the title row, so every row draws entries. *)
  let entry_rows = content_rows in
  let selected_entry =
    Option.value ~default:0 (List.find_index (keeper_entry_selected stop) entries)
  in
  let scroll_offset, window_entries =
    Masc_tui_scroll.window_of_heights ~heights ~cursor:selected_entry ~rows:entry_rows
      state.keeper_list_scroll
  in
  report_drawn_list Keeper_stops
    ~height:(Masc_tui_scroll.items_always_shown ~heights ~rows:entry_rows);
  let entries_window = List.take window_entries (List.drop scroll_offset entries) in
  (* Strip visual SGR before adding pressable marks: those marks also end in
     [m] and must reach the frame presenter. *)
  let selected_line text =
    box_line_styled buf cols ~style:(Theme.sidebar_selection ()) text in
  List.iter
    (function
      | Keeper_world as entry ->
          let selected = keeper_entry_selected stop entry in
          let world = Masc_tui_keeper_world.row_cells ~ko ~view:state.keeper_list_view
              ~health_error:(memory_health_error_text state) state.memory_health
              (Masc_tui_memory_world.reading state.memory_world) in
          let text = (grid_line grid
            { gutter = Theme.info () ^ (if selected then "› ■ " else "  ■ ") ^ Ansi.reset
            ; name = fit_width (if ko then "공유 세계" else "world · shared") grid.name_cells
            ; pulse = (match world.pulse with
                | Masc_tui_keeper_world.Ledger_and_briefing ->
                    fit_width (if ko then "원장 + 브리핑" else "ledger + briefing") grid.side_cells
                | Masc_tui_keeper_world.Fact_ages bins -> grid_age_ladder_reading grid bins)
            ; now_cell = fit_width world.now_cell Grid.now_cells
            ; strip = fit_width world.strip (Grid.strip_cells grid)
            ; due = fit_width world.due Grid.due_cells
            ; right = Message_layout.pad_left world.right grid.mem_cells }) in
          let press value = pressable Press_keeper_world (fit_width value inner) in
          if selected then
            selected_line (press (Masc_tui_theme.strip_sgr text))
          else box_line buf cols (press text)
      | Keeper_group_heading (group, count) as entry ->
          let selected = keeper_entry_selected stop entry in
          let text =
            let available_cells =
              match matrix with
              | Some _ -> max 1 (inner - 4)
              | None -> inner
            in
            let title =
              keeper_group_heading_text ~ko ~available_cells model_rows group count
            in
            match matrix with
            | Some _ ->
                let folded = List.mem group state.keeper_list_folded in
                let fold_mark =
                  if folded then Keeper_mark.grid_folded_mark
                  else Keeper_mark.grid_open_mark
                in
                keeper_group_heading_style group
                ^ (if selected then "\xe2\x80\xba " else "  ")
                ^ fold_mark ^ " " ^ title ^ Ansi.reset
            | None ->
                let members = keeper_group_rows list_reading group in
                grid_group_title state grid ~now:now_unix ~group ~members
                  ~folded:(List.mem group state.keeper_list_folded)
                  ~style:(keeper_group_heading_style group)
                  ~pulse:(grid_group_pulse state grid list_reading group)
                  ~selected title
          in
          if selected then
            selected_line (Masc_tui_theme.strip_sgr text)
          else box_line buf cols text
      | Keeper_display_row (position, row) as entry ->
          if wall_separator position then box_line buf cols (Theme.recede () ^ draw_hline inner ^ Ansi.reset);
          let selected = keeper_entry_selected stop entry in
          let yolo =
            List.mem row.Keeper_list_model.keeper.Tui_decode.k_name state.keeper_yolo_names
          in
          let primary =
            match matrix, shape with
            | Some matrix, (Axis_row.List_columns | Axis_row.Wall_columns | Axis_row.Grid _) ->
                matrix_keeper_row ~selected matrix ~now:now_unix row
            | None, Axis_row.Wall_columns ->
                Masc_tui_keeper_wall.row ~selected ~ko:(state.ui_language = Lang_ko)
                  ~cols:inner ~now:now_unix
                  ~name:row.Keeper_list_model.keeper.Tui_decode.k_name (keeper_row_runtime row)
            | None, Axis_row.List_columns ->
                let schedules =
                  if Option.is_some state.schedules_agenda_error then None
                  else state.schedules_agenda
                in
                keeper_row_content ?schedules ~tasks:state.tasks
                  ~ko:(state.ui_language = Lang_ko)
                  ?context_chip:(keeper_row_context_chip state row) ~columns ~now:now_unix ~yolo
                  ~selected row
            | None, Axis_row.Grid grid_columns ->
                grid_keeper_row state grid grid_columns ~view:state.keeper_list_view ~peak_lag
                  ~peak_facts ~now:now_unix ~yolo ~selected row
          in
          let press text =
            pressable (Press_keeper_row row.Keeper_list_model.keeper.Tui_decode.k_name)
              (fit_width text inner)
          in
          let emit text =
            if selected then
              selected_line (press (Masc_tui_theme.strip_sgr text))
            else box_line buf cols (press text)
          in
          emit primary;
          (* Only a row that draws a second line builds one. *)
          (match second_line row with
           | Axis_row.No_second_line -> ()
           | Axis_row.List_detail ->
               let cells =
                 Masc_tui_keeper_axis.segments state ~now:now_unix
                   ~keeper_name:row.Keeper_list_model.keeper.Tui_decode.k_name
                   ~runtime:(keeper_row_runtime row)
               in
               let schedules =
                 if Option.is_some state.schedules_agenda_error then None
                 else state.schedules_agenda
               in
               emit
                 (keeper_secondary_row_content ?schedules ~tasks:state.tasks ~ko ~now:now_unix
                    ~inner ~cells row)
           | Axis_row.Failure_chain -> emit (grid_failure_line ~ko:(state.ui_language = Lang_ko) grid ~now:now_unix row)))
    entries_window;

  let note =
    if keeper_count > 0 then None
    else
      match keeper_rows_page state ~error:keepers_error with
      | Page_empty when Option.is_some matrix ->
          Some (ui_text state ~ko:"   실패 중인 키퍼 없음" ~en:"   no failing Keepers")
      | Page_empty -> Some (match state.workspace_identity with
          | Workspace_identity_mismatch _ ->
              ui_text state ~ko:"   서버 키퍼 목록이 비어 있음" ~en:"   server Keeper roster is empty"
          | Workspace_identity_match | Workspace_identity_match_unconfirmed _
          | Workspace_identity_unread ->
              ui_text state ~ko:"   .masc/keepers/ 아래 키퍼 메타데이터 없음"
                ~en:"   no keeper metadata under .masc/keepers/")
      | Page_unread -> Some (page_unread_note ~ko:(state.ui_language = Lang_ko))
      | Page_failed -> None
  in
  let room_for_note = List.fold_left (fun n entry -> n + entry_lines entry) 0 entries_window < entry_rows in
  Option.iter
    (fun text ->
      if room_for_note then box_line buf cols (Theme.recede () ^ text ^ Ansi.reset)) note;
  let note_rows = match note with Some _ when room_for_note -> 1 | Some _ | None -> 0 in
  let drawn_rows =
    List.fold_left (fun drawn entry -> drawn + entry_lines entry) note_rows entries_window
  in
  for _ = 1 to max 0 (entry_rows - drawn_rows) do
    match matrix, shape with
    | Some _, (Axis_row.Grid _ | Axis_row.List_columns | Axis_row.Wall_columns)
    | None, (Axis_row.List_columns | Axis_row.Wall_columns) -> box_empty buf cols
    | None, Axis_row.Grid _ -> box_line buf cols ""
  done;
  List.iter (fun line -> box_line_styled buf cols ~style:(Theme.recede ()) line) legend;

  (* The window follows the list cursor and takes its rows out of the list's.
     A heading selects no Keeper, so the window has none to show there. *)
  Option.iter
    (fun page ->
      draw_keeper_story buf ~cols ~rows:story_rows ~now:now_unix ~inner state page selected_row)
    state.keeper_story;

  Option.iter (draw_keeper_selected_summary buf ~cols) selected_summary;
  box_divider buf cols;
  Buffer.add_string buf
    (footer_line state
       ~status:(keeper_action_status state)
       ~max_cells:cols
       ~hints:(keeper_control_hints ~keys:Roster_keys state selected_reading));

  finish_surface state ~clamped:(Keeper_list_scroll scroll_offset)
    ~surface_key:"keeper-list" ~rows:terminal_rows ~cols buf

let render_keeper_list (state : state) =
  match state.keeper_list_view, state.keeper_story with
  | Keeper_list_model.Plain, None -> render_keeper_plain state
  | (Keeper_list_model.Plain | Keeper_list_model.By_state | Keeper_list_model.By_cause
    | Keeper_list_model.By_time | Keeper_list_model.By_memory | Keeper_list_model.By_age
    | Keeper_list_model.By_runtime | Keeper_list_model.Day_wall), Some _
  | (Keeper_list_model.By_state | Keeper_list_model.By_cause | Keeper_list_model.By_time
    | Keeper_list_model.By_memory | Keeper_list_model.By_age | Keeper_list_model.By_runtime
    | Keeper_list_model.Day_wall), None -> render_keeper_axes state

(** Render keeper detail view with live context and scrolling *)
(* The detail box alone -- borders, title, scrolled content -- written into
   [buf] at [cols] wide, footer excluded so a caller can lay it beside the
   roster pane. Returns the scroll the frame actually used. *)
(* What the Keeper carries to reach a service, by name.

   Values are not here to be hidden -- the producer never sends them. The
   composite body carries names, counts and a validation flag, so this pane
   cannot show a credential by accident.

   A Keeper absent from the projection list is a different reading from one
   whose projection says [absent]: the first means the producer has not
   answered for this Keeper yet, the second means it answered that no root is
   configured. Saying "none" for both would report a fact the server did not
   send. [None] here is the first; the tab decides what to say about it from
   the composite reading it rides on, because no projection after a failed
   read and none before any read are the same absence. *)
let secret_lines (state : state) (k : keeper) =
  let dim line = Theme.recede () ^ line ^ Ansi.reset in
  let t korean english = ui_text state ~ko:korean ~en:english in
  match keeper_composite_of state ~keeper_name:k.k_name with
  | None | Some { kcr_secret = None; _ } -> None
  | Some { kcr_secret = Some p; _ } ->
      (* HIGH-RISK-UNREVIEWED: [keeper_secret_status_text] already makes an
         unknown producer word one printable row; the styles below wrap it
         as it is. *)
      let status =
        Masc.Tui_decode.keeper_secret_status_text
          ~ko:(state.ui_language = Lang_ko) p.ksp_status
      in
      let status_label = t "  상태:    " "  Status:  " in
      let status_line =
        match p.ksp_status with
        | Masc.Tui_decode.Secret_ready ->
            status_label ^ (Theme.ok ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_error ->
            status_label ^ (Theme.bad ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_empty | Masc.Tui_decode.Secret_absent
        | Masc.Tui_decode.Secret_status_unknown _ ->
            status_label ^ Theme.recede () ^ status ^ Ansi.reset
      in
      let entry_lines label = function
        | [] -> [ dim (Printf.sprintf "  %s  -" label) ]
        | names ->
            List.mapi
              (fun index name ->
                let lead =
                  if index = 0 then label
                  else String.make (Message_layout.display_width label) ' '
                in
                Printf.sprintf "  %s  %s" lead (Terminal_text.single_line name))
              names
      in
      detail_section_lines ~first:true (t "1. 시크릿 상태 · 루트 경로" "1. Status & Root")
      @ [ status_line
        ; t "  루트:    " "  Root:    " ^ Terminal_text.single_line p.ksp_root
        ]
      @ detail_section_lines (t "2. 환경변수 · 시크릿 파일" "2. Env & Files")
      @ entry_lines (t "환경변수:" "Env: ") p.ksp_env_names
      @ (match p.ksp_file_paths with
         | [] -> []
         | paths -> "" :: entry_lines (t "파일:    " "Files:") paths)
      @ (match p.ksp_error with
         | None -> []
         | Some detail ->
             [ ""; (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ])
      @ [ ""
        ; dim
            (if p.ksp_values_validated then
               t "  값을 읽고 검증했음. 값은 여기로 보내지 않음."
                 "  Values were read and validated. They are never sent here."
             else
               t "  마지막 읽기에서 값을 검증하지 못함."
                 "  Values were not validated on the last read.")
        ]
      |> Option.some

(* The Identity tab's body. Numbering comes from
   [Masc_tui_identity_model.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
(* The Terminal tab: a Keeper's Execute output as a terminal draws it, oldest
   row first. [terminal_rows] scroll; [terminal_status] is the row under them
   that stays put. [width] is the cells a row may use. *)
type terminal_drawing = { terminal_rows : string list; terminal_status : string }

let terminal_drawing (state : state) ~width =
  let module Execute_terminal = Masc_tui_execute_terminal in
  let module Say = Masc_tui_say in
  (* The tab's own words take the screen's language here, once. *)
  let say =
    Say.render
      (match state.ui_language with
       | Lang_ko -> Say.Ko
       | Lang_en -> Say.En)
  in
  let text ~ko ~en = say (Say.both ~ko ~en) in
  let hold = Masc_tui_types.keeper_terminal_hold state in
  let live = keeper_execute_view state in
  let observation = match hold with
    | Execute_terminal.Paused { frozen; _ } ->
        Masc_tui_fetched.Ready (frozen.ktf_reading, frozen.ktf_observed_at)
    | Execute_terminal.Following -> live in
  let sanitize = Masc.Tui_terminal_text.sanitize_terminal_text in
  let text_cells = max 1 (width - 2) in
  (* Each wrapped row replays the style it opened under and ends with a reset,
     so the pane can cut the list anywhere. *)
  let wrapped styled =
    Message_layout.wrap_styled_words ~max_cells:text_cells styled
    |> List.map (fun row -> "  " ^ row) in
  let note text = wrapped (Theme.recede () ^ sanitize text) in
  let lines_of = function
    | Keeper_execute_none -> []
    | Keeper_execute_snapshot snapshot ->
        List.map terminal_line_of_execute_line snapshot.kes_lines in
  let drawn_rows (reading : keeper_execute_reading) =
    match reading with
    | Keeper_execute_none ->
        note
          (text ~ko:"이 서버 프로세스에서 본 Execute 출력 없음"
             ~en:"No Execute output observed in this server process.")
    | Keeper_execute_snapshot snapshot ->
        let rows = Execute_terminal.rows (lines_of reading) in
        let tagged = Execute_terminal.tagged rows in
        let tag (row : Execute_terminal.row) =
          if not tagged then ""
          else
            Theme.recede ()
            ^ Printf.sprintf "[%s] "
                (match row.stream_id with Some id -> string_of_int id | None -> "?")
            ^ Ansi.reset in
        (* A terminal puts a tab at the next stop; here it would read [\x09]. The
           stops run across the colour runs of one row. *)
        let with_tab_stops line =
          let _, runs =
            List.fold_left
              (fun (column, expanded) (run : Masc_tui_sgr_text.run) ->
                 let text, column = Message_layout.expand_tabs ~column run.text in
                 column, { run with text } :: expanded)
              (0, []) line in
          List.rev runs in
        let output_rows ~style (row : Execute_terminal.row) =
          Masc_tui_sgr_text.parse row.text
          |> List.concat_map (fun line ->
               wrapped
                 (tag row ^ style
                  ^ Masc_tui_sgr_text.render ~sanitize (with_tab_stops line))) in
        let ended_rows (row : Execute_terminal.row) status =
          let tone, label = match status with
            | Execute_terminal.Process (Unix.WEXITED 0 as ended) ->
                Theme.recede (), Masc_tui_execute_result.process_status_text ended
            | Process (Unix.WEXITED _ | Unix.WSIGNALED _ as ended) ->
                Theme.bad (), Masc_tui_execute_result.process_status_text ended
            | Process (Unix.WSTOPPED _ as ended) ->
                Theme.warn (), Masc_tui_execute_result.process_status_text ended
            | Outcome (phase, outcome) ->
                let what = match phase with
                  | Execute_terminal.Command -> ""
                  | Gate_observation -> text ~ko:"Gate 관측 " ~en:"gate observation " in
                (match outcome with
                 | Execute_terminal.Result_unknown ->
                     Theme.warn (), what ^ text ~ko:"결과 알 수 없음" ~en:"result unknown"
                 | Request_not_sent ->
                     Theme.warn (), what ^ text ~ko:"요청 보내지 않음" ~en:"request not sent"
                 | Observation_ended -> Theme.recede (), what ^ text ~ko:"끝남" ~en:"ended")
            | Rejected { why; reason } ->
                Theme.bad (),
                text ~ko:"거절: " ~en:"rejected: " ^ why
                ^ (match reason with Some r -> " (" ^ r ^ ")" | None -> "")
            | Unrecognized status_text ->
                Theme.recede (), text ~ko:"상태 " ~en:"status " ^ status_text in
          wrapped (tag row ^ tone ^ "\xc2\xb7 " ^ sanitize label) in
        let drawn (row : Execute_terminal.row) =
          match row.kind with
          | Execute_terminal.Command_start ->
              wrapped (tag row ^ Theme.info () ^ "$ " ^ Ansi.reset ^ Ansi.bold ^ sanitize row.text)
          | Command_more ->
              wrapped (tag row ^ Theme.info () ^ "> " ^ Ansi.reset ^ Ansi.bold ^ sanitize row.text)
          | Stdout -> output_rows ~style:"" row
          | Stderr -> output_rows ~style:(Theme.warn ()) row
          | Status status -> ended_rows row status
          | Foreign name ->
              wrapped (tag row ^ Theme.recede () ^ sanitize ("[" ^ name ^ "] " ^ row.text)) in
        let started = List.filter_map (fun (row : Execute_terminal.row) ->
          match row.kind with
          | Execute_terminal.Command_start -> row.stream_id
          | Command_more | Stdout | Stderr | Status _ | Foreign _ -> None) rows in
        (* A command that began before this window still runs; its line is the
           only thing that says what the output below belongs to. *)
        let running = List.filter (fun (stream : keeper_execute_stream) ->
          not (List.mem stream.kes_id started)) snapshot.kes_active in
        (if snapshot.kes_first_seq > 1 then
           note
             (text
                ~ko:(Printf.sprintf "앞선 출력은 보관하지 않음 (순번 %s 이전)"
                       (Masc_tui_value.Count.grouped snapshot.kes_first_seq))
                ~en:(Printf.sprintf "Earlier output is no longer kept (before sequence %s)."
                       (Masc_tui_value.Count.grouped snapshot.kes_first_seq)))
         else [])
        @ (if snapshot.kes_lines_omitted > 0 then
             note
               (text
                  ~ko:(Printf.sprintf "이전 %s줄은 이 보기에 없음"
                         (Masc_tui_value.Count.grouped snapshot.kes_lines_omitted))
                  ~en:(Printf.sprintf "%s older rows are not in this view."
                         (Masc_tui_value.Count.grouped snapshot.kes_lines_omitted)))
           else [])
        @ List.concat_map (fun (stream : keeper_execute_stream) ->
            note (text ~ko:"실행 중: " ~en:"running: " ^ stream.kes_command)) running
        @ List.concat_map drawn rows in
  let rows = match observation with
    | Masc_tui_fetched.Absent ->
        note (text ~ko:"Execute 출력을 아직 읽지 않음" ~en:"Execute output has not been read.")
    | Loading -> note (text ~ko:"Execute 출력 읽는 중" ~en:"Reading Execute output")
    | Failed detail ->
        wrapped (Theme.bad () ^ sanitize
          (text ~ko:"Execute 출력 없음: " ~en:"Execute output unavailable: "
           ^ keeper_execute_failure_detail detail))
    | Ready (reading, _) | Stale ((reading, _), _) -> drawn_rows reading in
  (* The live stream can stop while a historical view is held. Put recovery
     in the fixed status row, leaving the output and its scroll math alone. *)
  let stopped = match live with
    | Masc_tui_fetched.Failed (Execute_stream_stopped { reason; detail })
    | Stale (_, Execute_stream_stopped { reason; detail })
      when not (Masc_tui_fetched.in_flight state.keeper_execute_output) -> Some (reason, detail)
    | Failed (Execute_stream_stopped _) | Stale (_, Execute_stream_stopped _) -> None
    | Absent | Loading | Ready _
    | Failed (Execute_read_failed _ | Execute_stream_retrying _)
    | Stale (_, (Execute_read_failed _ | Execute_stream_retrying _)) -> None in
  let newer = match hold, Masc_tui_fetched.value live with
    | Execute_terminal.Paused { frozen; _ }, Some (live_reading, _) ->
        Execute_terminal.unseen ~seen:(lines_of frozen.ktf_reading) ~latest:(lines_of live_reading)
    | (Execute_terminal.Paused _ | Execute_terminal.Following), (Some _ | None) -> 0 in
  let mode, mode_facts = match hold with
    | Execute_terminal.Following -> text ~ko:"따라가는 중" ~en:"following", []
    | Paused _ ->
        text ~ko:"멈춰 둠" ~en:"paused",
        [ text
            ~ko:(Printf.sprintf "새 줄 %s개" (Masc_tui_value.Count.grouped newer))
            ~en:(Message_layout.count_noun newer "newer row")
        ; text ~ko:"End:따라가기" ~en:"End:follow" ] in
  let facts = match observation with
    | Masc_tui_fetched.Ready (Keeper_execute_snapshot snapshot, observed_at)
    | Stale ((Keeper_execute_snapshot snapshot, observed_at), _) ->
        [ say (Say.of_ko_flag
                 (Masc_tui_types.keeper_execute_state_text
                    ~active_count:snapshot.kes_active_count ~closed:snapshot.kes_closed))
        ; Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ()) observed_at ]
    | Ready (Keeper_execute_none, _) | Stale ((Keeper_execute_none, _), _)
    | Absent | Loading | Failed _ -> [] in
  let facts = mode_facts @ facts in
  let stale = match observation with
    | Masc_tui_fetched.Stale (_, Execute_stream_stopped _) when Option.is_some stopped -> []
    | Masc_tui_fetched.Stale
        (_, ((Execute_stream_stopped _ | Execute_read_failed _ | Execute_stream_retrying _) as detail)) ->
        [ Theme.bad () ^ text ~ko:"오래된 화면: " ~en:"stale: "
          ^ sanitize (keeper_execute_failure_detail detail) ^ Ansi.reset ]
    | Ready _ | Absent | Loading | Failed _ -> [] in
  (* A stopped stream has nothing to follow, so "following" beside "stream
     stopped" would say two opposite things. A held view keeps its word: it
     still shows what was read before the stop. *)
  let shown = match stopped, hold with
    | Some _, Execute_terminal.Following -> facts
    | Some _, Execute_terminal.Paused _ | None, (Execute_terminal.Following | Paused _) ->
        mode :: facts in
  let status = Theme.recede () ^ String.concat " \xc2\xb7 " shown ^ Ansi.reset
    ^ String.concat "" (List.map (fun part -> " \xc2\xb7 " ^ part) stale) in
  let status = match stopped with
    | None -> status
    | Some (reason, detail) ->
      let cause = match reason with
        | Masc_tui_execute_stream_job.Http_status status -> Printf.sprintf "HTTP %d" status
        | Unattested_response _ -> text ~ko:"확인 안 된 응답" ~en:"unattested"
        | Invalid_stream_response _ -> text ~ko:"잘못된 스트림" ~en:"invalid stream"
        | Unexpected_error -> text ~ko:"오류" ~en:"error" in
      (* A stopped stream stays stopped while the tab is open: the stream plan
         keeps it for the same key. Leaving the tab ends it and coming back
         opens a new one, so the row says that instead of naming a retry key
         there is none of. *)
      let prefix = text ~ko:"연결 멈춤: " ~en:"stream stopped: " ^ cause in
      let reopen = text ~ko:"탭을 다시 열면 다시 연결" ~en:"reopen the tab to reconnect" in
      let lead = Theme.bad () ^ prefix ^ Ansi.reset in
      (* A truncation mark consumes a cell. At exactly the prefix width,
         leave the prefix whole instead of cutting its last character. *)
      if width <= Message_layout.display_width prefix then lead
      else
        (* With no reading the body's first row already carries the detail. *)
        let detail_part = match observation with
          | Masc_tui_fetched.Failed _ -> []
          | Absent | Loading | Ready _ | Stale _ ->
              [ Theme.bad () ^ sanitize detail ^ Ansi.reset ] in
        String.concat " \xc2\xb7 "
          ([ lead; Theme.recede () ^ reopen ^ Ansi.reset ]
           @ (if shown = [] then [] else [ status ])
           @ detail_part) in
  { terminal_rows = rows; terminal_status = status }

let keeper_detail_pane (state : state) (k : keeper) ~framed ~rows ~cols
    ~origin:(origin_row, origin_col) buf =
    (* Beside the roster pane the box is the pane separator; alone on the
       surface it is the redundant outer frame, dropped. *)
    let box_top = if framed then framed_top else box_top in
    let box_divider = if framed then framed_divider else box_divider in
    let box_line = if framed then framed_line else box_line in
    let box_empty = if framed then framed_empty else box_empty in
    let box_bottom = if framed then framed_bottom else box_bottom in
    let inner = framed_inner_width cols in
    (* What the pane has written so far, so the portrait's placement is
       counted from what was drawn above it rather than by hand. *)
    let pane_start = Buffer.length buf in
    (* The content rows under the title and divider, before an overflow
       indicator takes one of them. *)
    let base_height = max 0 (rows - framed_chrome_rows) in
    (* Info shows the current outfit; Items changes only the drawing for its
       selected preview. Both use the server's observed equipment. *)
    let portrait_reading =
      let reading = keeper_reading state k in
      match reading.Keeper_control.liveness with
      | Keeper_control.Present runtime -> runtime.kr_portrait
      (* The profile error's full text owns the failure section on the Info
         tab, where it wraps under its own heading. The portrait row is a
         status line read on the Items tab too, where no failure section
         exists, so its sentence names the state and no location: a second
         unwrapped copy of the whole diagnosis here is what made the pane
         read as broken. *)
      | Keeper_control.Unobserved | Keeper_control.Absent | Keeper_control.Invalid _ ->
          Tui_decode.Unavailable
            (Keeper_control.health_label ~ko:(state.ui_language = Lang_ko) reading) in
    let account = selected_item_account state in
    let items = item_browser_items state in
    let cursor = Item_account.cursor ~items state.item_cursor in
    let selected_item = List.nth_opt items cursor in
    let milli value = Printf.sprintf "%d.%03d" (value / 1000) (value mod 1000) in
    let ko = state.ui_language = Lang_ko in
    let item_say korean english = if ko then korean else english in
    let account_line =
      match account, state.item_account_error with
      | Some (Item_account.Ready account), _ ->
          let balance_milli = selected_item_balance_now state in
          Printf.sprintf
            (if ko then "  지갑 %s Candle%s · 보유 %d개"
             else "  Wallet %s Candle%s · %d owned")
            (milli (Item_account.spendable_milli account ~balance_milli))
            (match balance_milli with Some _ -> "" | None -> item_say " (마지막 관측)" " (as read)")
            (List.length account.owned_items)
      | Some Item_account.Off, _ -> item_say "  Candle 꺼짐" "  Candle off"
      | Some (Item_account.Disabled reason), _ ->
          item_say "  Candle 비활성: " "  Candle disabled: " ^ Terminal_text.single_line reason
      | None, Some detail ->
          item_say "  계정 조회 불가: " "  Account unavailable: " ^ Terminal_text.single_line detail
      | None, None ->
          (match pending_detail_read state ~tab:Detail_items ~keeper:k.k_name with
           | Some _ -> item_say "  아이템 계정 불러오는 중" "  Loading Item account"
           | None -> item_say "  아이템 계정 미조회" "  Item account not read")
    in
    let is_worn item =
      match portrait_reading with
      | Tui_decode.Unavailable _ -> false
      | Tui_decode.Ready equipment ->
          Keeper_portrait_item.in_slot equipment (Keeper_portrait_item.slot item) = Some item
    in
    (* Starting accessories may be worn without being purchased. Ownership and
       the observed picture therefore remain separate facts. *)
    let equipped_word = "  " ^ Ansi.bold ^ item_say "착용 중" "wearing" ^ Ansi.reset in
    let item_account_facts item =
      match account with
      | Some (Item_account.Ready account) ->
          let owned = List.mem item account.owned_items in
          let price =
            match List.find_opt (fun (entry : Item_account.entry) -> entry.item = item) account.catalog with
            | None -> item_say "카탈로그 미조회" "catalog unavailable"
            | Some { price = Item_account.Unpriced; _ } -> item_say "가격 미정" "unpriced"
            | Some { price = Item_account.Priced 0; _ } -> item_say "무료" "free"
            | Some { price = Item_account.Priced amount; _ } ->
              milli amount ^ " Candle"
              ^ (if owned then ""
                 else
                   let spendable =
                     Item_account.spendable_milli account
                       ~balance_milli:(selected_item_balance_now state)
                   in
                   if amount <= spendable then item_say " · 구매 가능" " · can buy"
                   else
                     let diff = milli (amount - spendable) in
                     if ko then " · " ^ diff ^ " 더 필요"
                     else " · need " ^ diff ^ " more")
          in
          Some ((if owned then item_say "보유 · " "owned · " else item_say "미보유 · " "not owned · ") ^ price)
      | Some (Item_account.Off | Item_account.Disabled _) | None -> None
    in
    let outfit_lines = match portrait_reading with
      | Tui_decode.Unavailable _ -> []
      | Tui_decode.Ready equipment ->
        let slots = List.map (fun slot ->
          let name = match Keeper_portrait_item.in_slot equipment slot with
            | None -> item_say "없음" "none"
            | Some item -> Item_account.item_name item in
          Keeper_portrait_item.slot_id slot ^ ": " ^ name) Keeper_portrait_item.slots in
        Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
          (item_say "착용 중 · " "Wearing · " ^ String.concat " · " slots)
        |> List.map (fun line -> "  " ^ line)
    in
    let portrait =
      match state.detail_tab, portrait_reading with
      | Detail_info, Tui_decode.Ready equipment ->
          Masc_tui_keeper_portrait.shown ~name:k.k_name ~equipment
            ~content_rows:base_height ~content_cols:inner
      | Detail_items, Tui_decode.Ready equipment ->
          let equipment = match state.item_preview, selected_item with
            | true, Some item -> Keeper_portrait_item.preview item equipment
            | (true | false), (Some _ | None) -> equipment in
          Masc_tui_keeper_portrait.preview ~name:k.k_name ~equipment
            ~content_rows:base_height ~content_cols:inner
      | (Detail_info | Detail_items), Tui_decode.Unavailable _
      | (Detail_sandbox | Detail_instructions | Detail_secrets | Detail_github
        | Detail_identity | Detail_channels | Detail_automation | Detail_runs
        | Detail_terminal), _ -> None
    in
    let item_row index item =
      let facts = if inner < 90 then "" else
        match item_account_facts item with Some facts -> "  " ^ facts | None -> "" in
      Printf.sprintf "  %s %-5s %s%s%s"
        (if index = cursor then "\xe2\x80\xba" else " ")
        (Keeper_portrait_item.slot_id (Keeper_portrait_item.slot item))
        (Item_account.item_name item) facts (if is_worn item then equipped_word else "")
    in
    let headline =
      [ Printf.sprintf
          (if ko then "  아이템 · %s · %s · %s" else "  Items · %s · %s · %s")
          (Item_account.filter_name state.item_filter)
          (Masc_tui_value.Count.grouped (List.length items))
          (if state.item_preview && selected_item <> None then item_say "미리 착용" "try on"
           else item_say "현재 복장" "current outfit")
      ; account_line ]
    in
    let portrait = match state.detail_tab, portrait with
      | Detail_items, Some band ->
          if List.exists (fun line -> Message_layout.display_width line > inner)
               (Masc_tui_keeper_portrait.beside band (headline @ List.mapi item_row items))
          then None else Some band
      | (Detail_info | Detail_items | Detail_sandbox | Detail_instructions | Detail_secrets
        | Detail_github | Detail_identity | Detail_channels | Detail_automation | Detail_runs
        | Detail_terminal), portrait -> portrait
    in
    let item_lines () =
      let count = List.length items in
      let observation = match portrait_reading with
        | Tui_decode.Ready _ -> []
        | Tui_decode.Unavailable reason ->
          [ item_say "  초상화 조회 불가: " "  Portrait unavailable: " ^ Terminal_text.single_line reason ] in
      let selected_facts = match selected_item with
        | None -> []
        | Some item ->
          let name = "  " ^ Ansi.bold ^ Item_account.item_name item ^ Ansi.reset
            ^ " · " ^ Keeper_portrait_item.slot_id (Keeper_portrait_item.slot item)
            ^ (if is_worn item then equipped_word else "") in
          name :: (match item_account_facts item with
            | Some facts -> ["  " ^ facts]
            | None -> []) in
      let empty = if count > 0 then [] else
        [ "  " ^ (match state.item_filter, account with
          | Item_account.Owned, Some (Item_account.Ready _) ->
              item_say "구매한 장신구가 아직 없습니다." "No purchased accessories yet."
          | Item_account.Can_buy, Some (Item_account.Ready _) ->
              item_say "현재 잔액으로 구매 가능한 미보유 아이템이 없습니다."
                "No unowned item fits the current balance."
          | (Item_account.Owned | Item_account.Can_buy), (None | Some (Item_account.Off | Item_account.Disabled _)) ->
              item_say "이 보기는 활성화된 아이템 계정이 필요합니다."
                "This view needs a ready Item account."
          | (Item_account.All | Item_account.In_slot _), _ ->
              item_say "이 보기에 표시할 아이템이 없습니다." "No items in this view.") ] in
      let footer =
        [ item_say "  요청 시 채팅 초안이 열리며 키퍼가 결과를 보고합니다."
            "  Requests open a chat draft; the Keeper reports the result." ] in
      let reserved = List.length headline + List.length selected_facts + List.length outfit_lines
        + List.length observation + List.length empty + List.length footer in
      let visible = min count (max 1 (base_height - reserved)) in
      let first = max 0 (min (cursor - visible / 2) (count - visible)) in
      let row_width = match portrait with
        | None -> inner
        | Some band -> max 1 (inner - 2 - band.Masc_tui_keeper_portrait.box.cols)
      in
      let rows = List.filter_map (fun (index, item) ->
        if index < first || index >= first + visible then None
        else
          let line = item_row index item in
          Some
            (if index = cursor then
               Theme.selection_style ()
               ^ fit_width (Masc_tui_theme.strip_sgr line) row_width
               ^ Ansi.reset
             else line))
        (List.mapi (fun index item -> index, item) items) in
      let listing = match portrait with
        | Some band -> Masc_tui_keeper_portrait.beside band (headline @ rows @ empty)
        | None -> headline @ rows @ empty in
      listing @ selected_facts @ outfit_lines @ observation @ footer
    in
    (* A long value takes the width below its label, rather than the few
       cells a fixed label column leaves beside it. These are actual display
       rows, counted before the detail window is sliced. Values have already
       passed their wire-boundary sanitizer and may carry this pane's SGR. *)
    let field_rows ~width ~label_cells ~label_style label value =
      let prefix = "  " ^ label_style ^ fit_width label label_cells ^ Ansi.reset ^ " " in
      if Message_layout.display_width label <= label_cells
         && Message_layout.display_width (prefix ^ value) <= width then
        [prefix ^ value]
      else
        (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 2)) label
         |> List.map (fun line -> "  " ^ label_style ^ line ^ Ansi.reset))
        @ (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 4)) value
           |> List.map (fun line -> "    " ^ line ^ Ansi.reset))
    in

    (* Each tab projects only when selected. Retained data for the other
       tabs must not be walked and formatted on every scroll frame. These
       functions capture this frame, so switching tabs reads current state. *)
    let info_lines () =
      (* Build all detail lines first, then apply scroll *)
      let lines = ref [] in
      let add_line s = lines := s :: !lines in
      let ko = state.ui_language = Lang_ko in
      let t korean english = if ko then korean else english in

      (* Helper to add a labeled row *)
      let row_lines ~width label value =
        field_rows ~width ~label_cells:18
          ~label_style:Ansi.dim label value
      in
      let add_row label value = List.iter add_line (row_lines ~width:inner label value) in
      let add_empty () = add_line "" in
      let section_line title = Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset in
      let add_section title = add_line (section_line title) in

      (* Identity, current task and context share the icon's header. These
         facts use the same label column, rather than leaving the portrait's
         lower rows blank while the current work falls below the viewport. *)
      let header_width = match portrait with
        | None -> inner
        | Some band -> max 1 (inner - 2 - band.Masc_tui_keeper_portrait.box.cols)
      in
      let identity =
        let width = header_width in
        [ section_line (t "기본 정보" "Identity") ]
        @ row_lines ~width (t "이름:" "Name:") (Terminal_text.single_line k.k_name)
        @ row_lines ~width (t "일시정지:" "Paused:")
            (match k.k_origin, (keeper_reading state k).Keeper_control.liveness with
             | Tui_decode.Remote_keeper,
                 (Keeper_control.Invalid _ | Unobserved | Absent) ->
                 Ansi.dim ^ Keeper_control.health_label ~ko (keeper_reading state k) ^ Ansi.reset
             | (Tui_decode.Persisted_keeper | Declared_keeper _), _
             | Remote_keeper, Keeper_control.Present _ ->
                 if k.k_paused then (Theme.warn ()) ^ t "예" "yes" ^ Ansi.reset
                 else Ansi.dim ^ t "아니오" "no" ^ Ansi.reset)
        @ row_lines ~width (t "권장 조치:" "Suggested action:")
            (keeper_suggested_action ~ko (keeper_reading state k))
        @ (match Masc_tui_candle.balance_text ~now:(Unix.gettimeofday ())
                   state.candle_observation ~keeper:k.k_name with
           | None -> []
           | Some value -> row_lines ~width (t "Candle 잔액:" "Candle balance:") (Terminal_text.single_line value))
      in
      List.iter add_line identity;
      (match portrait_reading with
       | Tui_decode.Ready _ -> ()
       | Tui_decode.Unavailable reason -> add_row (t "초상:" "Portrait:") (t "없음: " "unavailable: " ^ Terminal_text.single_line reason));
      add_empty ();
      let add_row label value =
        List.iter add_line (row_lines ~width:header_width label value)
      in
      (* Current work section *)
      add_section (t "현재 작업" "Current Work");
      add_row (t "작업:" "Task:")
        (match k.k_activity with
         | None -> keeper_activity_absent_mark k
         | Some activity ->
             (match activity.k_current_task_id with
              | None -> Masc_tui_theme.Glyph.no_value
              | Some id -> resolve_task_title state id));
      add_empty ();

      add_section (t "실시간 컨텍스트" "Live Context");
      let context_label = t "컨텍스트:" "Context:" in
      let add_context observation =
        match Observation_layout.context_summary observation with
        | Observation_layout.Context_measured observation ->
            let ratio = observation.ratio in
            let value = Observation_layout.percentage_tenths ratio in
            let max_value = Observation_layout.percentage_tenths_full in
            let pct = Float.of_int value /. 10.0 in
            let bar_width = Layout.keeper_context_bar_width ~inner_width:header_width in
            let scale = Masc_tui_chart.Declared_limit (Theme.paint ()) in
            (* The context window is a declared limit: a turn past it is
               refused, so each cell takes the colour of its place in it,
               and the readout matches the bar's tip colour (btop style). *)
            let bar =
              Masc_tui_chart.meter_bar ~width:bar_width ~value ~max_value
                ~scale ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
            in
            let tip_style = Masc_tui_chart.meter_tip_style scale ~value ~max_value in
            let tip_close = if String.equal tip_style "" then "" else Ansi.reset in
            add_row context_label
              (Printf.sprintf
                 (if ko then "%s%.1f%%%s  %s  %s / %s 토큰"
                  else "%s%.1f%%%s  %s  %s / %s tokens")
                 tip_style pct tip_close bar
                 (Masc_tui_message_layout.compact_count observation.tokens)
                 (Masc_tui_message_layout.compact_count observation.maximum));
            add_row (t "관측 시각:" "Observed:") (Terminal_text.short_timestamp observation.observed_at);
            add_row (t "턴 참조:" "Turn Ref:") (Terminal_text.single_line observation.turn_ref)
        | Observation_layout.Context_partial observation ->
            add_row context_label
              (Printf.sprintf
                 (if ko then "컨텍스트 %s 토큰 · 창 크기 보고 안 됨"
                  else "%s tokens in context; window not reported")
                 (Masc_tui_message_layout.compact_count observation.tokens));
            add_row (t "관측 시각:" "Observed:") (Terminal_text.short_timestamp observation.observed_at);
            add_row (t "턴 참조:" "Turn Ref:") (Terminal_text.single_line observation.turn_ref)
        | Observation_layout.Context_unavailable reason ->
            add_row context_label (Ansi.dim ^ reason ^ Ansi.reset)
      in
      (* A Keeper row without identity has no context to read: the row says
         why from the Keeper row itself, in the screen language. *)
      (match k.k_identity with
       | Error (Tui_decode.Keeper_not_started as absence) ->
           add_row context_label
             (Ansi.dim ^ Tui_decode.keeper_identity_absence_text ~ko absence ^ Ansi.reset)
       | Error (Tui_decode.Identity_unreadable _ as absence) ->
           add_row context_label
             ((Theme.bad ())
              ^ Terminal_text.single_line (Tui_decode.keeper_identity_absence_text ~ko absence)
              ^ Ansi.reset)
       | Ok _ ->
      (match live_context_view state k with
       | Masc_tui_fetched.Absent ->
           add_row context_label (Ansi.dim ^ t "읽기 전" "not loaded" ^ Ansi.reset)
       | Masc_tui_fetched.Loading ->
           add_row context_label (Ansi.dim ^ t "읽는 중" "reading" ^ Ansi.reset)
       | Masc_tui_fetched.Ready observation -> add_context observation
       | Masc_tui_fetched.Stale (observation, detail) ->
           add_row (t "갱신:" "Refresh:") ((Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset);
           add_context observation
       | Masc_tui_fetched.Failed detail ->
           add_row context_label ((Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset)));
      add_empty ();

      let header_lines = List.rev !lines in
      lines := [];
      List.iter add_line
        (match portrait with
         | Some band -> Masc_tui_keeper_portrait.beside band header_lines
         | None -> header_lines);
      let add_row label value = List.iter add_line (row_lines ~width:inner label value) in
      let add_numbered_section ?(first = false) title =
        List.iter add_line (detail_section_lines ~first title)
      in

      (* The live roster owns this reading, including its absence after a
         successful turn. Neither historical last_error nor the last outcome
         can answer for the current failure. A blocker may carry a signature:
         the machine wire its summary replaced with a human sentence. It is
         drawn dimmed underneath, so the wire a log search keys on stays on
         screen without ever leading the row. *)
      add_numbered_section ~first:true
        (t "1. 현재 장애 · 보드 격리" "1. Current Failure & Board Attention");
      let indent = "  " in
      let wrap ?(tone = "") text =
        Message_layout.wrap_words
          ~max_cells:(max 1 (inner - Message_layout.display_width indent))
          (Terminal_text.single_line text)
        |> List.iter (fun line -> add_line (indent ^ tone ^ line ^ Ansi.reset))
      in
      let () =
        match (keeper_reading state k).Keeper_control.liveness with
        | Keeper_control.Present runtime -> (
            match runtime.kr_runtime_blocker_summary with
            | Some summary ->
                (* The cause rides whole now, and the JSON error bodies among
                   them read as punctuation when the terminal wraps them.
                   The goal timeline unfolds the same wire value the same
                   way; here the sentence keeps the bad colour and the value
                   dims one step further in, the volume the goal detail
                   gives its JSON blocks. *)
                (match Masc_tui_planning_detail.split_embedded_json summary with
                 | None -> wrap ~tone:(Theme.bad ()) summary
                 | Some (sentence, value, after) ->
                     wrap ~tone:(Theme.bad ()) sentence;
                     Masc_tui_text_block.preformatted_rows
                       ~max_cells:(max 1 (inner - 4)) value
                     |> List.iter (fun row ->
                            add_line ("    " ^ Ansi.dim ^ row ^ Ansi.reset));
                     if not (String.equal (String.trim after) "") then
                       wrap ~tone:Ansi.dim after);
                (match runtime.kr_runtime_blocker_signature with
                | Some signature -> wrap ~tone:Ansi.dim signature
                | None -> ())
            | None -> wrap ~tone:Ansi.dim (t "현재 장애 없음" "no current failure"))
        | Keeper_control.Unobserved | Keeper_control.Absent ->
            wrap ~tone:Ansi.dim (Keeper_control.health_label ~ko (keeper_reading state k))
        | Keeper_control.Invalid detail ->
            wrap ~tone:(Theme.bad ())
              (Keeper_control.health_label ~ko (keeper_reading state k) ^ ": " ^ detail)
      in

      (* Blocked Board-attention partitions wait here for an
         operator's requeue, and nothing else on the screens said they existed.
         Beside the current failure because it is one: this Keeper's Board
         judgments for those posts do not move until someone presses Q. *)
      Masc_tui_board_quarantine.lines ~ko ~now:(Unix.gettimeofday ())
        state.keeper_board_quarantines ~keeper_name:k.k_name
      |> List.iter (fun (tone, text) ->
           let color =
             match tone with
             | Masc_tui_board_quarantine.Plain -> ""
             | Masc_tui_board_quarantine.Dim -> Ansi.dim
             | Masc_tui_board_quarantine.Warn -> Theme.warn ()
             | Masc_tui_board_quarantine.Bad -> Theme.bad ()
           in
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 2)) text
           |> List.iter (fun line -> add_line (indent ^ color ^ line ^ Ansi.reset)));

      (* Gate section. Two settings with similar names decide different things,
         so both are named rather than merged: YOLO is the in-memory stance that
         stops this chat asking and a restart clears, while the Gate mode is
         durable and is what an external effect -- a write to a service this
         Keeper is attached to -- is actually decided under. An operator reading
         one for the other is how a call gets made that nobody meant to allow. *)
      add_numbered_section (t "2. 권한 게이트 · 승인 정책" "2. Gate & Tool Policy");
      (* The same word the chat header wears in capitals and the footer offers
         after g, with what it does beside it. This row said "asked" under a
         header saying AUTO. *)
      add_row (t "도구 호출:" "Tool calls:")
        (let mode =
           if List.mem k.k_name state.keeper_yolo_names then
             Masc.Keeper_tool_approval_mode.Yolo
           else Masc.Keeper_tool_approval_mode.Auto
         in
         let tone =
           match mode with
           | Masc.Keeper_tool_approval_mode.Yolo -> Theme.bad ()
           | Masc.Keeper_tool_approval_mode.Auto -> Ansi.dim
         in
         tone ^ Masc_tui_types.tool_mode_word mode ^ " \xc2\xb7 "
         ^ Masc_tui_types.tool_mode_effect ~ko:(state.ui_language = Lang_ko) mode
         ^ Ansi.reset);

      (* Runtime & 24h section *)
      add_numbered_section (t "3. 런타임 배정 · 최근 24시간 활동" "3. Runtime & Last 24h Activity");
      List.iter (fun (label, value) -> add_row label value)
        (keeper_operations_fields state ~keeper_name:k.k_name);
      let assignment =
        List.find_opt
          (fun (a : Tui_decode.runtime_assignment) ->
             String.equal a.ra_keeper k.k_name)
          state.runtime_assignments
      in
      let target_str =
        match assignment with
        | Some a -> runtime_assignment_label a
        | None ->
            let def_name =
              match state.runtime_surface with
              | Some s ->
                  (match s.rss_resolved.rrs_default_runtime_id with
                   | Some d -> t "상속: " "inherited: " ^ d
                   | None -> t "상속" "inherited")
              | None -> t "상속" "inherited"
            in
            Printf.sprintf "%s (%s)" (t "기본" "default") def_name
      in
      add_row (t "런타임 대상:" "Runtime Target:") target_str;
      (match assignment with
       | Some { ra_resolution = Runtime_assignment_lane tid; _ } ->
           (match
              List.find_opt
                (fun (l : Tui_decode.runtime_resolved_lane) ->
                   String.equal l.rrl_id tid)
                state.runtime_lanes
            with
            | Some lane ->
                let hops =
                  String.concat " \xe2\x86\x92 "
                    (List.map runtime_id_model_part lane.rrl_runtime_ids)
                in
                add_row (t "후보 순서:" "Candidate Chain:") hops;
                (match lane.rrl_runtime_ids with
                 | first :: _ -> add_row (t "첫 후보:" "Head Candidate:") first
                 | [] -> ())
            | None -> ())
       | Some
           { ra_resolution =
               (Runtime_assignment_missing | Runtime_assignment_unavailable _)
           ; _
           } ->
         ()
       | None ->
           (match state.runtime_surface with
            | Some snap ->
                (match snap.rss_resolved.rrs_default_runtime_id with
                 | Some def_id ->
                     (match
                        List.find_opt
                          (fun (ro : Tui_decode.runtime_option) -> String.equal ro.ro_id def_id)
                          snap.rss_resolved.rrs_runtimes
                      with
                      | Some ro ->
                          add_row (t "기본 컨텍스트:" "Default Context:")
                            (Printf.sprintf
                               (if ko then "%s \xc2\xb7 최대 출력 %s"
                                else "%s \xc2\xb7 max output %s")
                               (format_context_tokens ro.ro_effective_max_context)
                               (match ro.ro_max_output_tokens with
                                | Some t -> format_context_tokens t
                                | None -> t "기본" "default"))
                      | None -> ())
                 | None -> ())
            | None -> ()));
      (match k.k_origin with
       | Tui_decode.Persisted_keeper -> ()
       | Remote_keeper -> add_row (t "출처:" "Source:") (t "서버 목록" "server roster")
       | Declared_keeper requirements ->
         add_row (t "준비:" "Preparation:") (String.concat " · "
           (List.map Masc.Keeper_declared_roster.requirement_label requirements)));
      add_row (t "최근 자율 턴:" "Last Outcome:")
        (match k.k_activity with
         | None -> keeper_activity_absent_mark k
         | Some activity ->
           (match activity.k_last_proactive_outcome with
            | Some outcome -> proactive_outcome_word ~ko outcome
            | None -> Masc_tui_theme.Glyph.no_value));
      (* Recent activity, folded from the metrics rows already read for this
         Keeper. The window is bounded by row count, so it can fall short of the
         span; when it does, say what it reached instead of implying a full day.
         With no rows there is nothing to total, so the section says why and
         draws no zeros: the same sentence the Logs tab gives for the same
         read. *)
      let log_snapshot = keeper_log_snapshot state in
      let window_label = t "구간:" "Window:" in
      let log_diagnostics = keeper_log_diagnostics state in
      List.iter (fun (tone, detail) ->
        add_row (t "지표:" "Metrics:") (keeper_log_style tone ^ Terminal_text.single_line detail ^ Ansi.reset))
        log_diagnostics;
      (match
         Keeper_activity.read
           ~since:
             (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
           log_snapshot.entries
       with
       | Keeper_activity.No_rows ->
         if log_diagnostics = [] then add_row window_label
           (Ansi.dim
            ^ Metrics_tail.empty_message ~ko:(state.ui_language = Lang_ko)
                log_snapshot.error
            ^ Ansi.reset)
       | Keeper_activity.Rows activity ->
         if not activity.Keeper_activity.aw_covered then
           add_row window_label
             (match activity.Keeper_activity.aw_oldest_ts with
              | Some oldest ->
                (if ko then Terminal_text.short_timestamp oldest ^ " 까지만"
                 else "partial, reaches " ^ Terminal_text.short_timestamp oldest)
              | None -> t "일부만" "partial");
         add_row (t "턴 / heartbeat:" "Turns / Heartbeats:")
           (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
              activity.Keeper_activity.aw_heartbeats);
         add_row (t "토큰 입력 / 출력:" "Tokens In / Out:")
           (Printf.sprintf "%s / %s"
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_input_tokens)
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_output_tokens));
         add_row (t "비용:" "Cost:")
           (match activity.Keeper_activity.aw_cost_usd with
            | Some cost -> Printf.sprintf "$%.4f" cost
            | None -> Ansi.dim ^ t "provider 가 값을 매기지 않음" "not priced by the provider" ^ Ansi.reset);
         add_row (t "도구 호출:" "Tool Calls:")
           (string_of_int activity.Keeper_activity.aw_tool_calls);
         add_row (t "많이 쓴 도구:" "Top Tools:")
           (match activity.Keeper_activity.aw_top_tools with
            | [] -> Masc_tui_theme.Glyph.no_value
            | tools ->
              tools
              |> List.map (fun (tool : Keeper_activity.tool_use) ->
                     Terminal_text.single_line tool.Keeper_activity.tu_name
                     ^ " " ^ Masc_tui_value.Count.times tool.Keeper_activity.tu_calls)
              |> String.concat "  "));

      (* This Keeper's month beside the fleet's per-turn figures: the same
         numbers for every Keeper, read once per month. The month is neither
         the current failure of section 1 nor the 24 hours of section 3, and
         under section 1 it read as part of the failure. *)
      add_numbered_section (t "4. 이번 달 효율" "4. This Month's Efficiency");
      (match Masc_tui_keeper_efficiency.lines ~ko state.keeper_efficiency ~keeper_name:k.k_name with
       | [] -> wrap ~tone:Ansi.dim (t "읽기 전" "unread")
       | lines ->
         List.iter
           (fun (tone, text) ->
             let color =
               match tone with
               | Masc_tui_keeper_efficiency.Plain -> ""
               | Masc_tui_keeper_efficiency.Dim -> Ansi.dim
               | Masc_tui_keeper_efficiency.Bad -> Theme.bad ()
             in
             Message_layout.wrap_words ~max_cells:(max 1 (inner - 2)) text
             |> List.iter (fun line -> add_line (indent ^ color ^ line ^ Ansi.reset)))
           lines);

      (* Historical receipt evidence is a separate reading. A successful
         fallback may retain earlier refusals while the live blocker is clear. *)
      add_numbered_section (t "5. 최근 후보 모델 폴백 이력" "5. Recorded Runtime Walk");
      let module Receipt = Masc.Keeper_execution_receipt in
      let module Evidence = Keeper_runtime_walk_evidence in
      let module Fault = Llm_provider.Candidate_fault in
      let history_row label value = add_row label (Terminal_text.single_line value) in
      let terminal_label = t "마지막 실패 후보:" "Terminal origin:" in
      let source (turn : Receipt.receipt_turn) =
        history_row (t "영수증 trace:" "Receipt trace:") turn.receipt_trace_id;
        history_row (t "영수증 턴:" "Receipt turn:")
          (match turn.receipt_turn_count with
           | Some count -> string_of_int count
           | None -> t "기록 없음" "not recorded");
        history_row (t "영수증 종료:" "Receipt ended:") turn.receipt_ended_at
      in
      let fault = function
        | None -> t "API 분류 해당 없음" "API classification inapplicable"
        | Some Fault.Unattributed -> t "원인 미분류 API 거절" "unattributed API refusal"
        | Some Fault.Unknown_after_dispatch -> t "결과 불확실" "outcome uncertain"
        | Some Fault.Local_admission -> t "MASC 입장 대기" "MASC admission wait"
        | Some Fault.Not_sent -> t "연결 못 함, 보내지 않음" "not sent, no connection"
        | Some (Fault.Binding binding) ->
          match binding with
          | Fault.Credential -> t "인증 정보" "credential"
          | Fault.Account_access -> t "계정 접근" "account access"
          | Fault.Account -> t "계정" "account"
          | Fault.Model_absent -> t "모델 없음" "model absent"
          | Fault.Rate_limit -> t "요청 한도" "rate limit"
          | Fault.Capacity -> t "용량" "capacity"
          | Fault.Server -> t "서버" "server"
          | Fault.Window -> t "컨텍스트 창" "context window"
          | Fault.Body_limit -> t "본문 크기 한도" "body limit"
          | Fault.Admission -> t "입장" "admission"
          | Fault.Deadline -> t "기한" "deadline"
          | Fault.Output_dialect -> t "출력 형식" "output dialect"
          | Fault.Refusal_unread -> t "거절 본문 못 읽음" "refusal unread"
      in
      (match (keeper_reading state k).Keeper_control.liveness with
       | Keeper_control.Present runtime ->
         (match runtime.kr_runtime_lane_observation with
          | None -> wrap ~tone:Ansi.dim (no_receipt_text ~ko)
          | Some (Receipt.Runtime_lane_not_observed turn) ->
            source turn;
            wrap ~tone:Ansi.dim (walk_not_captured_text ~ko)
          | Some (Receipt.Runtime_lane_unreadable {turn;field}) ->
            Option.iter source turn;
            wrap ~tone:(Theme.warn ()) (evidence_unreadable_text ~ko ^ ": " ^ field)
          | Some (Receipt.Runtime_lane_observed {turn;evidence}) ->
            source turn;
            (match evidence.failures with
             | [] -> wrap ~tone:Ansi.dim (no_candidate_failure_text ~ko)
             | failures -> List.iter (fun (failure : Evidence.failure) ->
                 history_row (t "후보:" "Candidate:")
                   (Printf.sprintf "%d · %s" failure.attempt failure.runtime_id);
                 history_row (t "호출:" "Invocation:")
                   (match failure.dispatch with
                    | Runtime_attempt_dispatch.Dispatched -> t "후보 호출함" "candidate invoked"
                    | Runtime_attempt_dispatch.Rejected_before_dispatch -> t "호출 전 거절" "rejected before invocation");
                 history_row (t "API 분류:" "API fact:") (fault failure.api_candidate_fault);
                 wrap (Keeper_request_failure.summary failure.failure)) failures);
            (match evidence.terminal with
             | Evidence.Terminal_not_observed ->
               history_row terminal_label
                 (Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported)
             | Evidence.Candidate_terminal {runtime_id;attempt;failure} ->
               history_row terminal_label (Printf.sprintf "%d · %s" attempt runtime_id);
               wrap (Keeper_request_failure.summary failure)))
       | Keeper_control.Unobserved | Keeper_control.Absent ->
         wrap ~tone:Ansi.dim (Keeper_control.health_label ~ko (keeper_reading state k))
       | Keeper_control.Invalid detail ->
         wrap ~tone:(Theme.warn ())
           (Keeper_control.health_label ~ko (keeper_reading state k) ^ ": " ^ detail));

      (* Lifetime totals & Timestamps section *)
      add_numbered_section (t "6. 누적 통계 · 생성 이력" "6. Lifetime Totals & Timestamps");
      (match k.k_activity with
       | None -> add_row (t "활동:" "Activity:") (keeper_activity_absent_mark k)
       | Some activity ->
         add_row (t "누적 턴:" "Total Turns:") (string_of_int activity.k_total_turns);
         (* Read at a glance, the way the Acting pane's block already reads its
            token figures. A live roster drew "75111274" here: eight digits a
            reader counts rather than reads. Turns and tool calls keep their
            digits -- three or four of them, and a count of things done rather
            than a size. *)
         add_row (t "누적 토큰:" "Total Tokens:")
           (Masc_tui_message_layout.compact_count activity.k_total_tokens);
         add_row (t "누적 비용:" "Lifetime Cost:") (Tui_decode.keeper_cost_summary activity.k_total_cost_usd);
         add_row (t "마지막 턴:" "Last Turn:")
           (match activity.k_last_turn_at with
            | Some at -> Terminal_text.short_timestamp_of_unix at
            | None -> t "(없음)" "(never)"));
      (match k.k_identity with
       | Ok identity ->
         add_row (t "생성:" "Created:") (Terminal_text.short_timestamp identity.k_created_at);
         add_row (t "수정:" "Updated:") (Terminal_text.short_timestamp identity.k_updated_at)
       | Error absence ->
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 26))
             (Terminal_text.single_line (Tui_decode.keeper_identity_absence_text ~ko absence))
           |> List.iteri (fun index line ->
                add_row (if index = 0 then t "메타데이터:" "Metadata:" else "") line));

      List.rev !lines
    in
    (* The non-Info tabs draw a fetched read; the stamp has to name the
       keeper on screen or the pane shows loading, never another keeper's
       answer. *)
    (* A pending read says how long it has been pending. Five to sixteen
       seconds is what the Sandbox tab's status took against a live server,
       and a bare "(loading...)" through that window reads as a stall.

       The stamp is the read's own: the tab read and the container-log read are
       two reads and the operator starts the second long after the first has
       landed. One reading of the clock for the frame, so two rows drawn in the
       same frame cannot disagree about what time it is. *)
    let now_ns = Mtime_clock.elapsed_ns () in
    let loading_row ?started_ns what =
      Ansi.dim ^ "  "
      ^ Masc_tui_types.loading_notice
          ?elapsed:(Masc_tui_types.pending_elapsed ~now_ns started_ns)
          what
      ^ Ansi.reset
    in
    let stamped_or view error =
      let observed = match view with
        | Some (stamp, lines) when String.equal stamp k.k_name ->
            Some (List.map (fun line -> "  " ^ line) lines)
        | Some _ | None -> None in
      (* Only this tab's original pending request proves a read is scheduled.
         A missing or foreign snapshot does not prove any work is in flight. *)
      let pending = Masc_tui_types.detail_read_started state
          ~tab:state.detail_tab ~keeper:k.k_name in
      let failure = match error with
        | None -> []
        | Some detail ->
            [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ] in
      let progress = match pending with
        | None -> []
        | Some started_ns ->
            [ loading_row ~started_ns
                (match observed with
                 | None -> ui_text state ~ko:"불러오는 중" ~en:"loading"
                 | Some _ -> ui_text state ~ko:"새로고침 중" ~en:"refreshing") ] in
      match observed with
      | Some lines ->
          let previous = match error, pending with
            | None, None -> []
            | Some _, (Some _ | None) | None, Some _ ->
                [ Ansi.dim ^ ui_text state ~ko:"  이전 관측:" ~en:"  Last observation:" ^ Ansi.reset ] in
          failure @ progress @ previous @ lines
      | None ->
          (match error, pending with
           | None, None ->
               [ Ansi.dim ^ "  "
                 ^ (if server_authority_ready state then
                      ui_text state ~ko:"미조회 · r:읽기" ~en:"Not read · r to read"
                    else
                      ui_text state ~ko:"미조회 · 워크스페이스 확인 필요"
                        ~en:"Not read · workspace confirmation required")
                 ^ Ansi.reset ]
           | Some _, (Some _ | None) | None, Some _ -> failure @ progress)
    in
    let channel_lines () =
      let ko = state.ui_language = Lang_ko in
      let t korean english = if ko then korean else english in
      (* The kind column of the learned names: "channel", the widest word. *)
      let mapping_kind_cells = 7 in
      let rows = match state.connectors_error, state.connectors with
      | Some detail, None ->
          [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
            ^ Ansi.reset ]
      | None, None ->
          (match Connector_read.view state.connectors_read with
           | Connector_read.Quiet ->
               [ Ansi.dim ^ t "  채널 커넥터 미조회" "  Channel transports not read" ^ Ansi.reset ]
           | Reading _ | Waiting_after_write | Failed_to_start ->
               (* The existing typed-source notice below owns pending,
                  held recheck and failed-start guidance; none is a value. *)
               [])
      | error, Some snapshot ->
          let connectors = snapshot.cs_connectors in
          let selected_index =
            max 0 (min state.connectors_cursor (List.length connectors - 1))
          in
          (* The list the open arm or pause offer would send for this Keeper
             now, read through the decision its key reads. The footer cuts
             from the right and any other key ends the arm, so this pane is
             where the operator reads every channel before confirming. *)
          let unbind_confirmation =
            Masc_tui_connector_unbind.confirmation
              ~armed:state.connector_unbind_all_armed
              ~offer:state.connector_unbind_offer ~keeper_name:k.k_name
              (Masc_tui_connector_unbind.targets ~keeper_name:k.k_name connectors)
          in
          let confirmation_lines =
            match unbind_confirmation with
            | None -> []
            | Some { Masc_tui_connector_unbind.confirm_key; confirm_targets } ->
                let count = List.length confirm_targets in
                let unreadable =
                  Masc_tui_connector_unbind.unreadable_transports connectors
                in
                ((Theme.warn ())
                 ^ (if ko then
                      Printf.sprintf
                        "  %s 를 누르면 아래 바인딩 %d개를 제거 · 다른 키는 그대로 둠"
                        confirm_key count
                    else
                      Printf.sprintf
                        "  %s removes these %d binding%s · any other key keeps them"
                        confirm_key count (if count = 1 then "" else "s"))
                 ^ Ansi.reset)
                :: List.concat_map
                     (fun (target : Masc_tui_connector_unbind.target) ->
                        Terminal_text.single_line target.connector_name ^ " · "
                        ^ Masc_tui_connector_unbind.target_label target
                        |> Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
                        |> List.map (fun line -> "    " ^ line))
                     confirm_targets
                @ (match unreadable with
                   | [] -> []
                   | names ->
                       [ (Theme.warn ())
                         ^ t "    빠짐 · 바인딩 목록 읽지 못함: "
                             "    not included, binding list unreadable: "
                         ^ String.concat ", " names ^ Ansi.reset ])
          in
          (* The list row and the detail badge spell the same connection, so
             they read the same table. This pane kept a byte-identical copy of
             it, which meant a change to the vocabulary could land in one
             place and leave the omission rule in [Masc_tui_connector_state]
             judging against the other. *)
          let connection_label (connector : Masc.Tui_decode_connectors.connector) =
            let word =
              Masc_tui_connector_state.badge_word connector.cn_connection
            in
            match connector.cn_connection with
            | Masc.Tui_decode_connectors.Connector_connected ->
                (Theme.ok ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_connected_unavailable ->
                (Theme.warn ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_disconnected -> (Theme.bad ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_offline -> Ansi.dim ^ "○ " ^ word ^ Ansi.reset
            | Connector_stale -> (Theme.warn ()) ^ "● " ^ word ^ Ansi.reset
          in
          let transport_rows =
            List.mapi
              (fun index (connector : Masc.Tui_decode_connectors.connector) ->
                 let here_count =
                   List.length
                     (List.filter
                        (fun (binding : Masc.Tui_decode_connectors.connector_binding) ->
                           String.equal binding.cb_keeper_name k.k_name)
                        connector.cn_bindings)
                 in
                 let tail =
                   Printf.sprintf
                     (if ko then "  여기 %d / 전체 %d" else "  %d here / %d total")
                     here_count
                     (List.length connector.cn_bindings)
                 in
                 (* Two cells of indent, two for the cursor mark, two between
                    the name and the badge: the padding the row spends before
                    its columns. *)
                 let name_cells =
                   Masc_tui_connector_state.list_row_name_cells
                     ~inner:(framed_inner_width cols) ~fixed_cells:6
                     ~tail_cells:(Message_layout.display_width tail)
                 in
                 let line =
                   "  " ^ (if index = selected_index then "\xe2\x80\xba " else "  ")
                   ^ fit_width
                       (Terminal_text.single_line connector.cn_display_name)
                       name_cells
                   ^ "  "
                   ^ fit_width
                       (Masc_tui_connector_state.badge_word
                          connector.cn_connection)
                       Masc_tui_connector_state.badge_column_cells
                   ^ tail
                 in
                 if index = selected_index then
                   Theme.selection_style () ^ Masc_tui_theme.strip_sgr line ^ Ansi.reset
                 else line)
              connectors
          in
          let refused_rows =
            List.map
              (fun (refusal : Masc.Tui_decode_connectors.connector_refusal) ->
                 let name =
                   match refusal.cr_connector_id with
                   | Some id -> Terminal_text.single_line id
                   | None -> Printf.sprintf "connectors[%d]" refusal.cr_row
                 in
                 (Theme.bad ()) ^ "    " ^ name ^ t "  읽지 못함: " "  unreadable: "
                 ^ Terminal_text.single_line refusal.cr_reason ^ Ansi.reset)
              snapshot.cs_refused
          in
          let selected_lines =
            match List.nth_opt connectors selected_index, snapshot.cs_refused with
            | None, [] ->
                [ Ansi.dim ^ t "  (등록된 채널 커넥터 없음)" "  (no channel transports registered)" ^ Ansi.reset ]
            | None, _ :: _ -> []
            | Some connector, _ ->
                let field label value =
                  field_rows ~width:inner ~label_cells:18 ~label_style:"" label value
                in
                let optional_row label value =
                  match value with
                  | None -> []
                  | Some value ->
                      field label (Terminal_text.single_line value)
                in
                let optional_bool_row label value =
                  optional_row label
                    (Option.map (fun present -> if present then t "예" "yes" else t "아니오" "no") value)
                in
                let optional_int_row label value =
                  optional_row label (Option.map string_of_int value)
                in
                let selected_binding =
                  List.nth_opt connector.cn_bindings state.connectors_binding_cursor
                in
                let keeper_is_present keeper_name =
                  List.exists
                    (fun (keeper : Tui_decode.keeper) ->
                       String.equal keeper.k_name keeper_name)
                    state.keepers
                in
                let binding_reference (binding : Masc.Tui_decode_connectors.connector_binding) =
                  Masc_tui_connector_unbind.channel_label ~ko
                    ~channel_id:binding.cb_channel_id
                    ~channel_name:binding.cb_channel_name
                in
                let store_state =
                  match connector.cn_binding_store_read_ok with
                  | Some true -> Some (t "읽힘" "readable")
                  | Some false -> Some (t "읽지 못함" "UNREADABLE")
                  | None -> None
                in
                let binding_lines =
                  List.mapi
                    (fun index (binding : Masc.Tui_decode_connectors.connector_binding) ->
                      let here = String.equal binding.cb_keeper_name k.k_name in
                      let selected = index = state.connectors_binding_cursor in
                      let missing_keeper =
                        not (keeper_is_present binding.cb_keeper_name)
                      in
                      let removal =
                        match
                          Masc_tui_connector_unbind.row_mark unbind_confirmation
                            connector binding
                        with
                        | Masc_tui_connector_unbind.Will_unbind key ->
                            Printf.sprintf (if ko then "  · %s 로 제거" else "  · %s removes") key
                        | Masc_tui_connector_unbind.Not_targeted -> ""
                      in
                      let line =
                        Printf.sprintf "    %s %s → %s%s%s"
                          (if selected then "\xe2\x80\xba" else " ")
                          (binding_reference binding)
                          (Terminal_text.single_line binding.cb_keeper_name)
                          (if here then t "  (이 Keeper)" "  (this Keeper)"
                           else if missing_keeper then
                             t "  (없는 Keeper · e:다시 배정  u×2:제거)"
                               "  (MISSING KEEPER · e:reassign  u×2:remove)"
                           else "")
                          removal
                      in
                      if selected then
                        Theme.selection_style () ^ Masc_tui_theme.strip_sgr line ^ Ansi.reset
                      else if missing_keeper then
                        (Theme.bad ()) ^ line ^ Ansi.reset
                      else line)
                    connector.cn_bindings
                  |> function
                  | [] -> [ Ansi.dim ^ t "    (채널 바인딩 없음)" "    (no channel bindings)" ^ Ansi.reset ]
                  | lines -> lines
                in
                [ ""
                ; Ansi.bold ^ t "  선택 · " "  Selected · "
                  ^ Terminal_text.single_line connector.cn_display_name
                  ^ Ansi.reset
                ]
                @ detail_section_lines (t "1. 연결 상태 · 트리거 및 응답 정책" "1. Connection & Routing Policy")
                @ field (t "바인딩 대상" "Binding target")
                    (match selected_binding with
                     | None -> t "(고른 바인딩 없음)" "(no binding selected)"
                     | Some binding -> binding_reference binding)
                  (* The badge is read from the status the row would print
                     beside it ([decode_connector_connection] takes status,
                     available and connected), so the word never differs from
                     the badge and the row said the same thing twice. *)
                @ field (t "연결" "Connection")
                    (connection_label connector)
                @ field "MASC API"
                    (Printf.sprintf "%s:%d"
                       Masc_network_defaults.masc_http_loopback_peer state.port)
                @ field (t "채널 종류" "Channel type")
                    (Terminal_text.single_line_or
                       ~default:Masc_tui_theme.Glyph.no_value connector.cn_channel)
                @ optional_row (t "런타임 상태" "Runtime state")
                    (Masc_tui_connector_state.runtime_state_to_draw connector)
                @ optional_row (t "상태 출처" "Status source") connector.cn_status_source
                @ optional_row (t "원격 endpoint" "Remote endpoint") connector.cn_endpoint
                @ optional_row (t "상태 파일" "Status file") connector.cn_status_path
                @ optional_row (t "바인딩 저장소" "Binding store") connector.cn_binding_store_path
                @ optional_row (t "저장소 상태" "Store state") store_state
                @ optional_row (t "바인딩 출처" "Binding source") connector.cn_binding_source
                @ optional_row (t "트리거 정책" "Trigger policy") connector.cn_trigger_policy
                @ optional_row (t "응답 방식" "Reply mode") connector.cn_reply_mode
                @ optional_row (t "채팅 DB" "Chat database") connector.cn_chat_db_path
                @ detail_section_lines (t "2. 봇 자격증명 · 프로세스 상태" "2. Bot Credentials & Process")
                @ optional_row (t "봇 사용자" "Bot user") connector.cn_bot_user_name
                @ optional_row (t "봇 사용자 id" "Bot user id") connector.cn_bot_user_id
                @ optional_bool_row (t "봇 토큰 준비" "Bot token ready") connector.cn_bot_token_present
                @ optional_bool_row (t "앱 토큰 준비" "App token ready") connector.cn_app_token_present
                @ optional_bool_row (t "Gate 정상" "Gate healthy") connector.cn_gate_healthy
                @ optional_int_row (t "서버 pid" "Server pid") connector.cn_pid
                @ optional_int_row (t "길드 수" "Guilds") connector.cn_guild_count
                @ detail_section_lines (t "3. 디렉토리 동기화 · 이름 매핑 파일" "3. Directory & Name Mapping")
                @ optional_row (t "디렉토리 상태" "Directory state")
                    (Option.map
                       (function
                         | Masc.Tui_decode_connectors.Connector_directory_not_started ->
                           t "시작 전" "not started"
                         | Connector_directory_refreshing -> t "갱신 중" "refreshing"
                         | Connector_directory_complete -> t "완료" "complete"
                         | Connector_directory_partial -> t "일부만" "partial")
                       connector.cn_directory_state)
                @ optional_int_row (t "알게 된 서버" "Servers learned")
                    connector.cn_directory_server_count
                @ optional_int_row (t "알게 된 채널" "Channels learned")
                    connector.cn_directory_channel_count
                @ optional_int_row (t "알게 된 사람" "People learned")
                    connector.cn_directory_person_count
                @ (match connector.cn_directory_authentication_failed with
                   | [] -> []
                   | values ->
                     field (t "인증 실패" "Authentication")
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_permission_denied with
                   | [] -> []
                   | values ->
                     field (t "권한 제한" "Permission limits")
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_errors with
                   | [] -> []
                   | values ->
                     field (t "디렉토리 오류" "Directory errors")
                         (String.concat "; "
                            (List.map Terminal_text.single_line values))
                     )
                @ optional_row (t "디렉토리 갱신" "Directory updated")
                    connector.cn_directory_updated_at
                @ optional_row (t "워크스페이스 id" "Workspace id") connector.cn_workspace_id
                @ optional_row (t "서버 이름 파일" "Server names") connector.cn_server_names_path
                @ optional_row (t "채널 이름 파일" "Channel names") connector.cn_channel_names_path
                @ optional_row (t "사람 이름 파일" "People names") connector.cn_people_names_path
                @ optional_row (t "매핑 범위" "Mapping scope") connector.cn_name_mapping_scope
                @ optional_row (t "이름 읽기 오류" "Names read error") connector.cn_names_error
                @ optional_row (t "갱신" "Updated") connector.cn_updated_at
                @ optional_row (t "연결 오류" "Connection error") connector.cn_error
                @ optional_row (t "저장소 오류" "Store error") connector.cn_binding_store_error
                @ detail_section_lines (t "4. 채널 → 키퍼 바인딩" "4. Channel → Keeper Bindings")
                @ binding_lines
                @ (match connector.cn_name_mappings with
                   | [] -> []
                   | mappings ->
                       [ ""; Ansi.bold ^ t "  알려진 ID ↔ 이름" "  Known ID ↔ names" ^ Ansi.reset ]
                       @ List.concat_map
                           (fun (mapping : Masc.Tui_decode_connectors.connector_name_mapping) ->
                              Printf.sprintf "%s %s ↔ %s"
                                (fit_width
                                   (match mapping.cnm_kind with
                                    | Masc.Tui_decode_connectors.Connector_channel_name ->
                                        t "채널" "channel"
                                    | Connector_person_name -> t "사람" "person"
                                    | Connector_server_name -> t "서버" "server")
                                   mapping_kind_cells)
                                (Terminal_text.single_line mapping.cnm_id)
                                (Terminal_text.single_line mapping.cnm_name)
                              |> Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
                              |> List.map (fun line -> "    " ^ line))
                           mappings)
                @ [ ""
                  ; Ansi.dim
                    ^ t "  j/k:커넥터  J/K:바인딩  b:연결  e:다시 배정  u×2:제거"
                        "  j/k:transport  J/K:binding  b:bind  e:reassign  u×2:remove"
                    ^ Ansi.reset
                  ; Ansi.dim
                    ^ t "  채널 라우팅만 변경 · 커넥터 프로세스는 유지"
                        "  Changes channel routing only; connector process stays untouched."
                    ^ Ansi.reset
                  ; Ansi.dim ^ t "  PgUp/PgDn:스크롤  r:바인딩·이름 새로고침" "  PgUp/PgDn:scroll  r:reload bindings and names" ^ Ansi.reset
                  ]
          in
          [ Printf.sprintf
              (if ko then "  커넥터 %d개 · 사용 가능 %d개 · 동작 대상 %s"
               else "  %d transports · %d available · actions target %s")
              snapshot.cs_total snapshot.cs_active
              (Terminal_text.single_line k.k_name)
          ]
          @ (match error with
             | None -> []
             | Some detail ->
                 [ (Theme.bad ()) ^ t "  이전 관측 · " "  STALE · "
                   ^ Terminal_text.single_line detail ^ Ansi.reset
                 ])
          @ confirmation_lines @ transport_rows @ refused_rows @ selected_lines
      in
      match connectors_read_notice state with
      | None -> rows
      | Some notice -> (Theme.info () ^ "  " ^ notice ^ Ansi.reset) :: rows
    in
    let automation_lines () =
      (* This tab reads the Keeper's own page from the server rather than
         filtering the fleet page: that page caps at its own limit with active
         rows first, so a Keeper whose schedules are terminal or further down
         was absent from it and the tab said none existed. The page it asks for
         can still truncate, which is why the absence reading stays. *)
      let pending = detail_read_started state ~tab:Detail_automation ~keeper:k.k_name in
      let observed = match state.keeper_schedules with
        | Some (name, _) -> String.equal name k.k_name
        | None -> false in
      let error = match state.keeper_schedules_error with
        | Some (name, detail) when String.equal name k.k_name -> Some detail
        | Some _ | None -> None in
      let error_lines = match error with
        | Some (Request_failed detail) ->
            [ (Theme.bad ()) ^ "  "
              ^ (if observed then ui_text state ~ko:"이전 관측 · " ~en:"STALE · " else "")
              ^ Terminal_text.single_line detail ^ Ansi.reset ]
        | Some (Request_withdrawn refusal) ->
            [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line
                (workspace_refusal_text ~ko:(state.ui_language = Lang_ko)
                   ~request:Kept_request.Schedule_read refusal) ^ Ansi.reset ]
        | None -> [] in
      let ko = state.ui_language = Lang_ko in
      let say korean english = if ko then korean else english in
      let progress = match pending with
        | None -> []
        | Some started_ns ->
            [ loading_row ~started_ns (if observed
                then say "이 키퍼의 일정 새로고침 중 · 이전 관측"
                       "refreshing this Keeper's schedules · last observation"
                else say "이 키퍼의 일정 불러오는 중" "loading this Keeper's schedules") ] in
      let snapshot_lines = match state.keeper_schedules with
      | Some (keeper_name, snapshot) when String.equal keeper_name k.k_name ->
          let rows = snapshot.scs_rows in
          if not (String.equal snapshot.scs_status "ok") then
            [ (Theme.bad ())
              ^ (match snapshot.scs_read_error with
                 | Some err -> "  " ^ Terminal_text.single_line err
                 | None -> say "  (일정 저장소 읽기 불가)" "  (schedule store unreadable)")
              ^ Ansi.reset ]
          else if rows = [] then
            match
              Render_schedule.classify_keeper_schedule_absence
                ~truncated:snapshot.scs_truncated
                ~shown:(List.length snapshot.scs_rows)
                ~total:snapshot.scs_request_count
            with
            | Render_schedule.Store_has_none ->
                [ Ansi.dim ^ say "  (이 키퍼에 등록된 일정 없음)" "  (no schedules for this Keeper)" ^ Ansi.reset ]
            | Render_schedule.Page_capped { shown; total } ->
                let of_total =
                  match total with
                  | Some total ->
                      Printf.sprintf
                        (if ko then " · 요청 %s / %s건" else " · %s of %s requests")
                        (Masc_tui_value.Count.grouped shown)
                        (Masc_tui_value.Count.grouped total)
                  | None -> ""
                in
                let next_step = match state.keeper_schedules_page with
                  | Some (name, { sp_previous = _ :: _; _ }) when String.equal name k.k_name ->
                      say "< 로 이전 페이지 보기" "use < for the previous page"
                  | Some _ | None -> say "r 로 다시 읽기" "refresh to read again"
                in
                [ Ansi.dim
                  ^ Printf.sprintf
                      (if ko then "  (이 페이지에 없음%s · %s)" else "  (none on this page%s · %s)")
                      of_total next_step
                  ^ Ansi.reset
                ]
          else
            (* What the store holds, above the rows it sent. The rows come
               live-first, and a Keeper whose store has run for weeks answers
               with a page of closed work behind the one live row -- without
               this line a reader learns that only by scrolling to the end.
               The counts describe the whole store, so they stay right when
               the page below them is capped. *)
            (match snapshot.scs_paging, state.keeper_schedules_page with
             | Schedule_paging _, Some (name, page) when String.equal name k.k_name
                   && (snapshot.scs_truncated || Option.is_some page.sp_cursor) ->
                 [ Ansi.dim ^ Printf.sprintf
                     (if ko then "  %d페이지 · < / > 페이지 이동 · 조회 사이에 바뀔 수 있음"
                      else "  page %d · < / > pages · pages may change between reads")
                     (List.length page.sp_previous + 1) ^ Ansi.reset ]
             | Schedule_paging_unavailable, _ when snapshot.scs_truncated ->
                 [ Ansi.dim ^ say "  첫 페이지만 표시 · 서버 페이지네이션 미지원"
                     "  first page only · server paging unavailable" ^ Ansi.reset ]
             | (Schedule_paging_unavailable | Schedule_paging _), (Some _ | None) -> [])
            @ (match snapshot.scs_counts with
             | None -> []
             | Some counts ->
                 [ Ansi.dim ^ "  "
                   ^ Masc_tui_types.schedule_counts_line ~ko counts
                   ^ Ansi.reset
                 ; ""
                 ])
            @ ((* The word and colour of what the row's last occurrence came
                  to, or the empty-field dash in no colour. *)
               let outcome_of row =
                 match schedule_outcome ~ko row with
                 | Some (word, tone) -> Terminal_text.single_line word, tone
                 | None -> Masc_tui_theme.Glyph.no_value, Ansi.reset
               in
               let outcome_words = List.map (fun row -> fst (outcome_of row)) rows in
               let by_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_requested_by)
                   rows
               in
               let recurrence_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line
                        (Masc_tui_schedule_recurrence.text ~ko ~now:(Unix.gettimeofday ())
                           ~summary:row.sch_recurrence_summary row.sch_recurrence))
                   rows
               in
               (* Every line carries a two-cell lead before the table, so the
                  table is fitted to what the lead leaves -- the same reserve
                  the Schedules list makes, without which the frame cuts the
                  last column's tail on every row. *)
               let table_inner = max 1 (inner - 2) in
               let layout =
                 Render_schedule.kauto_layout ~inner_width:table_inner
                   ~status_width:(schedule_status_word_cells ~ko)
                   ~clock_width:schedule_requested_clock_cells
                   ~outcome_width:
                     (Render_schedule.schedule_delivery_width outcome_words)
                   ~recurrence_width:
                     (Render_schedule.kauto_recurrence_width recurrence_words)
                   ~by_width:(Render_schedule.kauto_by_width by_words)
               in
               let header =
                 Render_schedule.kauto_header_row
                   ~ko:(state.ui_language = Lang_ko) ~layout
               in
               (* The rule under the names runs the header's own width, so a
                  pane narrower than the table does not draw a rule longer
                  than the rows under it. The closed rule below ends at the
                  same cell, so the two rules read as one margin. *)
               let rule_cells =
                 min table_inner (Message_layout.display_width header) in
               let occurrence_clock = function
                 | Some iso -> Terminal_text.column_timestamp iso
                 | None -> Masc_tui_theme.Glyph.no_value
               in
               let row_line (row : schedule_row) =
                 (* The mark and the state word wear one colour, the state's
                    own; the outcome wears the outcome's, so a failed wake
                    reads red beside a state still reading live. *)
                 let status = schedule_status_reading ~ko row.sch_status in
                 (* A held occurrence has no wake of its own, and the wake and
                    ledger fields on the row still describe the occurrence
                    before it (#38205): while the hold holds, the three
                    occurrence cells draw nothing rather than the previous
                    occurrence's clocks beside a state that reads due-now.
                    Why it holds is the Schedules list's own reading -- its
                    row carries the hold tag -- which this tab's capped-page
                    line already points the reader to. *)
                 let held = Option.is_some row.sch_runner_hold in
                 let occurrence_clock value =
                   if held then Masc_tui_theme.Glyph.no_value
                   else occurrence_clock value
                 in
                 let outcome, outcome_tone =
                   if held then Masc_tui_theme.Glyph.no_value, Ansi.reset
                   else outcome_of row
                 in
                 "  "
                 ^ Render_schedule.kauto_row ~layout
                     ~styles:
                       ({ kstyle_mark = status.tone
                        ; kstyle_status = status.tone
                        ; kstyle_outcome = outcome_tone
                        ; kstyle_recurrence = Ansi.dim
                        ; kstyle_by = Theme.recede ()
                        } : Render_schedule.kauto_row_styles)
                     { Render_schedule.krow_mark = status.mark
                     ; krow_status = status.word
                     ; krow_triggered =
                         occurrence_clock row.sch_last_wake_started_at_iso
                     ; krow_outcome = outcome
                     ; krow_received =
                         occurrence_clock row.sch_stimulus_recorded_at_iso
                     ; krow_recurrence =
                         Terminal_text.single_line
                           (Masc_tui_schedule_recurrence.text ~ko ~now:(Unix.gettimeofday ())
                              ~summary:row.sch_recurrence_summary row.sch_recurrence)
                     ; krow_by = Terminal_text.single_line row.sch_requested_by
                     ; krow_requested =
                         Terminal_text.column_timestamp row.sch_requested_at_iso
                     ; krow_what =
                         Terminal_text.single_line
                           (Option.value ~default:row.sch_schedule_id
                              row.sch_payload_summary)
                     }
               in
               (* The page's live rows, then its closed ones under a labelled
                  rule. The server sends live-first; the partition keeps each
                  group's order and makes the grouping this pane's own rather
                  than the server's sort happening to be right. *)
               let live, closed =
                 List.partition
                   (fun (row : schedule_row) ->
                      not (schedule_status_is_terminal row.sch_status))
                   rows
               in
               let closed_rule =
                 if closed = [] || live = [] then []
                 else
                   let words =
                     List.map
                       (fun (row : schedule_row) -> row.sch_status)
                       closed
                   in
                   let rec first_seen acc = function
                     | [] -> List.rev acc
                     | word :: rest ->
                         if List.mem word acc then first_seen acc rest
                         else first_seen (word :: acc) rest
                   in
                   let label =
                     Render_schedule.kauto_group_label
                       ~title:(if ko then "닫힘" else "closed")
                       (List.map
                          (fun word ->
                             let count =
                               Masc_tui_value.Count.grouped
                                 (List.length (List.filter (String.equal word) words))
                             in
                             let shown = (schedule_status_reading ~ko word).word in
                             if ko then Printf.sprintf "%s %s" shown count
                             else Printf.sprintf "%s %s" count shown)
                          (first_seen [] words))
                   in
                   let lead = "  \xe2\x94\x80\xe2\x94\x80 " ^ label ^ " " in
                   let rest_cells =
                     max 0
                       (min (2 + rule_cells) inner
                          - Message_layout.display_width lead)
                   in
                   [ Theme.recede () ^ lead ^ draw_hline rest_cells
                     ^ Ansi.reset
                   ]
               in
               [ Theme.recede () ^ "  " ^ header ^ Ansi.reset
               ; Theme.recede () ^ "  " ^ draw_hline rule_cells ^ Ansi.reset
               ]
               @ List.map row_line live
               @ closed_rule
               @ List.map row_line closed)
      | Some _ | None ->
          (match error, pending with
           | None, None -> [ Ansi.dim ^ say "  일정 미조회" "  Schedules not read" ^ Ansi.reset ]
           | Some _, (Some _ | None) | None, Some _ -> [])
      in
      error_lines @ progress @ snapshot_lines
    in
    let run_lines () =
      let failure detail =
        (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset
      in
      let listing runs =
        ui_text state
          ~ko:"  Fusion 실행  j/k:선택  Enter:열기  (Fusion 화면과 같은 ID)"
          ~en:"  Fusion runs  j/k:select  Enter:open  (same IDs as Fusion)" ::
        (if runs = [] then
           [ ui_text state
               ~ko:"  이 키퍼에 보관된 Fusion 실행 없음"
               ~en:"  No retained Fusion runs for this Keeper" ]
         else List.mapi (fun index (run : Masc.Tui_decode_fusion.fusion_run) ->
           (* The clock the Fusion list and the run detail already draw for
              this field, rather than a second copy of its format: three
              lists show a run's start, and a copy is one that stops
              following when the other two change. *)
           let selected =
             Option.fold ~none:false ~some:(fun (cursor, _) -> index = cursor)
               (Masc_tui_fusion_model.selected_keeper_run state)
           in
           let status_text =
             if ko then
               match run.fur_status with
               | Masc.Tui_decode_fusion.Fusion_running -> "실행 중"
               | Masc.Tui_decode_fusion.Fusion_completed -> "완료"
               | Masc.Tui_decode_fusion.Fusion_failed _ -> "실패"
             else Masc.Tui_decode_fusion.fusion_run_status_to_string run.fur_status
           in
           let row =
             Printf.sprintf "%s %s · %s · %s · %s"
               (if selected then "›" else " ")
               (fusion_run_clock run)
               status_text
               (Terminal_text.single_line run.fur_preset)
               (Terminal_text.single_line run.fur_run_id)
           in
           if selected then
             Theme.selection_style () ^ fit_width (Masc_tui_theme.strip_sgr row) inner ^ Ansi.reset
           else row) runs)
      in
      match Masc_tui_fusion_model.keeper_runs_view state with
      | Masc_tui_fetched.Absent -> [ Ansi.dim ^ (page_unread_note ~ko:(state.ui_language = Lang_ko)) ^ Ansi.reset ]
      | Masc_tui_fetched.Loading ->
          [ loading_row (ui_text state ~ko:"Fusion 실행 불러오는 중" ~en:"loading Fusion runs") ]
      | Masc_tui_fetched.Failed detail -> [ failure detail ]
      (* Rows already held stay on a failed refresh, as they do on the Fusion
         surface, with the failure above them so they read as stale. *)
      | Masc_tui_fetched.Stale (runs, detail) -> failure detail :: listing runs
      | Masc_tui_fetched.Ready runs -> listing runs
    in
    let terminal = lazy (terminal_drawing state ~width:inner) in
    (* Drawn once, read twice: for the rows, and for the row the cursor is
       on, which the scroll below keeps in view. *)
    let identity_drawn =
      lazy
        (Option.map
           (fun (stamp, providers) ->
             ( stamp
             , Masc_tui_render_identity.draw ~ko:(state.ui_language = Lang_ko) ~cols
                 { keeper_name = k.k_name
                 ; providers
                 ; filter = state.identity_filter
                 ; cursor = state.identity_cursor
                 ; logins = state.identity_logins
                 ; attempt_error = state.identity_attempt_error
                 ; app_form = state.identity_app_form
                 ; callback = state.identity_callback
                 ; order = state.identity_order
                 ; show = state.identity_show
                 } ))
           state.identity_view)
    in
    let all_lines =
      match state.detail_tab with
      | Detail_info -> info_lines ()
      | Detail_items -> item_lines ()
      | Detail_sandbox ->
          let width = max 24 (framed_inner_width cols - 4) in
          let status =
            match state.keeper_sandbox_view with
            | Some (stamp, partial) when String.equal stamp k.k_name ->
              Masc_tui_keeper_sandbox.partial_view_lines
                ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text
                ~ko:(state.ui_language = Lang_ko) ~width partial
            | Some _ | None ->
              [ Ansi.dim ^ (if state.ui_language = Lang_ko then
                    "  샌드박스 상태 미조회" else "  Sandbox status not read") ^ Ansi.reset ]
          in
          let logs =
            match state.keeper_sandbox_logs_inflight with
            | Some request when String.equal request.slr_keeper k.k_name ->
              [ loading_row ~started_ns:request.slr_started_ns
                  (if state.ui_language = Lang_ko then "실제 컨테이너 로그 조회 중" else "loading actual container logs") ]
            | Some _ | None ->
              match state.keeper_sandbox_logs_error with
              | Some (stamp, detail) when String.equal stamp k.k_name ->
                [ (Theme.bad ()) ^ (if state.ui_language = Lang_ko then "  컨테이너 로그 조회 실패: " else "  Container logs unavailable: ")
                  ^ Terminal_text.single_line detail ^ Ansi.reset
                ]
              | Some _ | None ->
                (match state.keeper_sandbox_logs with
                 | Some (stamp, logs) when String.equal stamp k.k_name ->
                   Masc_tui_keeper_sandbox.logs_view_lines ~ko:(state.ui_language = Lang_ko) ~width logs
                   |> List.map (fun line -> "  " ^ line)
                 | Some _ | None -> [])
          in
          status @ logs
      | Detail_instructions ->
          stamped_or state.keeper_config_view state.keeper_config_view_error
      | Detail_secrets ->
          let reading = keeper_composite_of state ~keeper_name:k.k_name in
          let error = keeper_composite_error_of state ~keeper_name:k.k_name in
          let reading_now = keeper_composite_reading_now state ~keeper_name:k.k_name in
          let observed = Option.is_some reading in
          let t korean english = ui_text state ~ko:korean ~en:english in
          let failure = match error with
            | None -> []
            | Some detail ->
                [ (Theme.bad ()) ^ "  " ^ (if observed then t "이전 관측 · " "STALE · " else "")
                  ^ Terminal_text.single_line detail ^ Ansi.reset ] in
          let progress = if reading_now then
              [ loading_row (if observed
                  then t "실행 상태 갱신 중 · 마지막 관측"
                      "refreshing execution snapshot · last observation"
                  else t "실행 상태 읽는 중" "reading execution snapshot") ]
            else [] in
          let lines = match secret_lines state k with
            | Some lines -> lines
            | None ->
                (match reading, error, reading_now with
                 | None, None, false ->
                     [ Ansi.dim ^ t "  실행 상태 미조회" "  Execution snapshot not read" ^ Ansi.reset ]
                 | None, (Some _ | None), true | None, Some _, false -> []
                 | Some _, (Some _ | None), (true | false) ->
                     [ Ansi.dim
                       ^ t "  (이 Keeper 시크릿 상태 보고 없음)"
                           "  (no projection reported for this Keeper)"
                       ^ Ansi.reset ]) in
          failure @ progress @ lines
      | Detail_github ->
          let base =
            stamped_or state.github_identity_view
              state.github_identity_view_error
          in
          Masc_tui_render_github.lines ~ko:(state.ui_language = Lang_ko)
            { token_input = state.github_token_input
            ; save_status = state.github_token_save_status
            ; login_scopes = state.github_login_scopes
            }
            ~base
      | Detail_identity ->
          stamped_or
            (Option.map
               (fun (stamp, (drawn : Masc_tui_render_identity.drawn)) ->
                 stamp, drawn.rows)
               (Lazy.force identity_drawn))
            state.identity_view_error
      | Detail_channels ->
          channel_lines ()
      | Detail_automation -> automation_lines ()
      | Detail_runs -> run_lines ()
      | Detail_terminal -> (Lazy.force terminal).terminal_rows
    in
    let total_lines = List.length all_lines in
    (* [stamped_or] puts this Keeper's rows last, after whatever failure,
       progress or "Last observation" lines it says above them, so the
       cursor's line is counted back from the end. *)
    let identity_cursor_line =
      match state.detail_tab with
      | Detail_identity ->
        (match Lazy.force identity_drawn with
         | Some (stamp, (drawn : Masc_tui_render_identity.drawn))
           when String.equal stamp k.k_name ->
           Option.map
             (fun row -> total_lines - List.length drawn.rows + row)
             drawn.cursor_row
         | Some _ | None -> None)
      | Detail_info | Detail_items | Detail_sandbox | Detail_instructions
      | Detail_secrets | Detail_github | Detail_channels | Detail_automation
      | Detail_runs | Detail_terminal -> None
    in


    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom). Where the window stands is on the title row, so the content
       keeps every row. *)
    let terminal_tab = state.detail_tab = Detail_terminal in
    let content_height =
      (* The Terminal's status row is there whether or not the output
         overflows, so the output never moves when it starts to. *)
      if terminal_tab then max 0 (base_height - 1) else base_height
    in
    let visible_lines = min content_height total_lines in
    (* Two tabs draw a list in this window, one line per run or service. *)
    (match state.detail_tab with
     | Detail_runs -> report_drawn_list Keeper_runs ~height:content_height
     | Detail_identity ->
         (match Lazy.force identity_drawn with
          | Some (stamp, (drawn : Masc_tui_render_identity.drawn))
            when String.equal stamp k.k_name ->
              report_drawn_list Identity_services
                ~height:(content_height - drawn.separator_rows)
          | Some _ | None -> ())
     | Detail_info | Detail_items | Detail_sandbox | Detail_instructions
     | Detail_secrets | Detail_github | Detail_channels | Detail_automation
     | Detail_terminal -> ());
    (* How far back from the bottom this window can go, and how far it is. *)
    let terminal_scroll, terminal_back =
      if terminal_tab then
        Masc_tui_execute_terminal.window ~content_height ~total_rows:total_lines
          (Masc_tui_types.keeper_terminal_hold state)
      else 0, 0
    in
    let scroll =
      if terminal_tab then terminal_scroll
      else
        Render_schedule.normalize_keeper_detail_scroll ~line_count:total_lines
          ~content_height state.detail_scroll
        |> fun scroll ->
          if state.detail_tab = Detail_runs then
            let header_offset =
              match Masc_tui_fusion_model.keeper_runs_view state with
              | Masc_tui_fetched.Stale _ -> 2
              | Masc_tui_fetched.Absent | Loading | Failed _ | Ready _ -> 1
            in
            Option.fold ~none:scroll
              ~some:(fun (cursor, _) ->
                Masc_tui_scroll.ensure_visible ~cursor:(cursor + header_offset)
                  ~height:(max 1 content_height) scroll)
              (Masc_tui_fusion_model.selected_keeper_run state)
          else
            Option.fold ~none:scroll
              ~some:(fun cursor ->
                Masc_tui_scroll.ensure_visible ~cursor
                  ~height:(max 1 content_height) scroll)
              identity_cursor_line
    in
    (* Top border *)
    box_top buf cols;

    (* The Terminal tab's own row says what its view is doing; every other
       tab names its window on the title row. *)
    box_line buf cols
      (zone_two_title ~cols state
         ~title:(keeper_detail_title state ~keeper_name:k.k_name)
         ~position:
           (if terminal_tab then None
            else
              Masc_tui_value.Position.window ~first:scroll ~shown:content_height
                ~total:total_lines));

    (* Divider *)
    box_divider buf cols;

    let all_lines_window = Rows.of_list ~first:scroll ~height:visible_lines all_lines in

    (* Real pixels go over the blank cells the band left, from the first
       content row: the lines this pane drew above it, under whatever the
       caller drew above the pane. *)
    Option.iter
      (fun band ->
        Masc_tui_keeper_portrait.placement band ~scroll ~visible_rows:visible_lines
          ~origin:
            ( origin_row + lines_ended_since buf ~start:pane_start
            , origin_col + framed_content_column )
        |> Option.iter Masc_tui_portrait_view.request)
      portrait;

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (Option.value (Rows.at all_lines_window idx) ~default:"")
      else
        box_empty buf cols
    done;

    (* Fill remaining space *)
    for _ = visible_lines to content_height - 1 do
      box_empty buf cols
    done;

    (* On the Terminal tab one row says what the view is doing. *)
    if terminal_tab then box_line buf cols (Lazy.force terminal).terminal_status;

    (* Bottom border *)
    box_bottom buf cols;
    if terminal_tab then Keeper_terminal_scroll terminal_back else Keeper_detail scroll


let render_keeper_detail (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  if state.keeper_cursor >= List.length state.keepers then begin
    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
      ~surface_key:"keeper-detail"
      ~title:
        (here_row ~cols state
           ~path:[ ui_text state ~ko:"상세" ~en:"detail" ]
           ~readings:[] ~position:None)
      ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view)
      ~body:(fun ~budget:_ c ->
        c.push_styled ~style:(Theme.recede ())
          (ui_text state ~ko:"  고른 키퍼가 없습니다." ~en:"  No keeper selected."))
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    (* The row the Keepers list draws, through the same [footer_line]: the
       armed or running action as a status item, the keys as items the fitter
       can drop whole, [Esc] and [q] kept whatever else goes. It was cut with
       [fit_width] instead, which keeps the front and loses the back -- where
       [Left / Esc] and [q] sit -- so at 80 columns the row ended "t:c…" and
       named no way out. [key:label] for the roster pane's key too. *)
    (* The open tab's own keys lead, and a Keeper control on a key the tab
       answers itself leaves the row. They were a strip at the end of the
       title row, which the frame cut at 120 columns ("o:act…", "L:log…"),
       while this row said "s:shutdown" and "o:container logs" on the
       Sandbox tab, where [s] sets the remote_ssh backend and [o] reads the
       container logs the strip called "actual logs". *)
    let hints =
      Masc_tui_keys.keeper_detail_tab_hint
        ~ko:(state.ui_language = Lang_ko) state.detail_tab
      ^ "  "
      ^ keeper_control_hints ~keys:Detail_keys
          ~taken:(Masc_tui_keys.keeper_detail_tab_taken_keys state.detail_tab)
          state (Some (keeper_reading state k))
    in
    let hints =
      if keeper_roster_pane_shown state ~cols then
        "h/l:" ^ ui_text state ~ko:"창" ~en:"pane" ^ "  " ^ hints
      else hints
    in
    let footer =
      footer_line state ~status:(keeper_action_status state) ~max_cells:cols ~hints
    in
    if not (keeper_roster_pane_shown state ~cols) then begin
      let scroll =
        keeper_detail_pane state k ~framed:false ~rows ~cols
          ~origin:(strip_rows, 0) buf
      in
      Buffer.add_string buf footer;
      finish_surface state ~clamped:scroll
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
    else begin
      (* Wide terminals keep the roster in sight beside the detail. Both
         panes draw the same number of rows, so the zip below is a plain
         row-by-row join. *)
      let left_cols = keeper_roster_pane_cols in
      let right_cols = cols - left_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      keeper_roster_pane
        ~focused:(state.keeper_detail_focus = Left_pane)
        state ~rows ~cols:left_cols left_buf;
      let scroll =
        keeper_detail_pane state k ~framed:true ~rows ~cols:right_cols
          ~origin:(strip_rows, left_cols) right_buf
      in
      write_two_panes buf ~left_cols:left_cols ~left:left_buf
        ~right:right_buf;
      Buffer.add_string buf footer;
      finish_surface state ~clamped:scroll
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
      ~surface_key:"keeper-logs"
      ~title:
        (here_row ~cols state
           ~path:[ ui_text state ~ko:"로그" ~en:"logs" ]
           ~readings:[] ~position:None)
      ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view)
      ~body:(fun ~budget:_ c ->
        c.push_styled ~style:(Theme.recede ())
          (ui_text state ~ko:"  고른 키퍼가 없습니다." ~en:"  No keeper selected."))
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let log_snapshot = keeper_log_snapshot state in
    let total_entries = List.length log_snapshot.entries in
    let reading_label = match keeper_logs_view state with
      | Masc_tui_fetched.Absent -> ui_text state ~ko:"미조회" ~en:"not read"
      | Loading -> ui_text state ~ko:"메트릭 조회 중" ~en:"reading metrics"
      | Failed _ -> ui_text state ~ko:"조회 불가" ~en:"unavailable"
      | Ready _ | Stale _ ->
          count_reading state Masc_tui_value.Count.Entry total_entries in

    let log_rows = Masc_tui_types.keeper_log_rows state ~cols in
    let row_count = List.length log_rows in
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:None
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:row_count ~content_height
        (if state.log_wrap_cols = Some cols then state.log_scroll else 0)
    in

    (* Header *)
    let header =
      here_row ~cols state
        ~path:
          [ Terminal_text.single_line k.k_name
          ; ui_text state ~ko:"로그" ~en:"logs" ]
        ~readings:[ reading_label ]
        ~position:
          (Masc_tui_value.Position.window ~first:scroll ~shown:content_height
             ~total:row_count)
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    box_line_styled buf cols ~style:(Theme.recede ())
      (ui_text state ~ko:"  시각  종류  지연 · 아래에 전체 기록"
         ~en:"  TIME  KIND  LATENCY · full facts below");
    box_divider buf cols;

    let visible = Rows.of_list ~first:scroll ~height:content_height log_rows in
    for index = 0 to content_height - 1 do
      if row_count = 0 && index = 0 then
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  "
           ^ Metrics_tail.empty_message ~ko:(state.ui_language = Lang_ko)
               log_snapshot.error)
      else
        match Rows.at visible (scroll + index) with
        | Some (diagnostic, line) ->
            let style = keeper_log_style diagnostic in
            box_line_styled buf cols ~style line
        | None -> box_empty buf cols
    done;

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view));

    finish_surface state ~clamped:(Keeper_logs_scroll { scroll; cols })
      ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end

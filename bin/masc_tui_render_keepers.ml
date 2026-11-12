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
let schedule_status_color = Masc_tui_render_work.schedule_status_color
let schedule_status_word_cells = Masc_tui_render_work.schedule_status_word_cells
let schedule_requested_clock_cells = Masc_tui_render_work.schedule_requested_clock_cells
let schedule_outcome_word = Masc_tui_render_work.schedule_outcome_word
let schedule_status_is_terminal = Masc_tui_render_work.schedule_status_is_terminal

(* Healthy keepers stay quiet beside their NOW activity. A health deviation
   remains available to the secondary detail row instead of repeating a
   separate health word in every compact row. *)
let keeper_health_deviation_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> (
      match Tui_decode.keeper_health_reading value with
      | Tui_decode.Health_running -> ""
      | Tui_decode.Health_idle | Tui_decode.Health_failing | Tui_decode.Health_offline ->
          Tui_decode.keeper_health_to_string value)

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

let keeper_failure_cause_word = function
  | Keeper_failure_heartbeat -> "heartbeat"
  | Keeper_failure_turn -> "turn"
  | Keeper_failure_provider -> "provider"
  | Keeper_failure_configuration -> "config"
  | Keeper_failure_client_recovery -> "client recovery"
  | Keeper_failure_fiber -> "fiber"
  | Keeper_failure_exception -> "exception"
  | Keeper_failure_operator_interrupt -> "operator interrupt"

let failing_glyph = Masc_tui_keeper_mark.failing_glyph

(* The detail window and the failure sentence name a receipt's state with the
   same words. *)
let no_receipt_text = "no receipt"
let walk_not_captured_text = "candidate walk was not captured"
let evidence_unreadable_text = "historical evidence unreadable"
let no_candidate_failure_text = "no candidate failure recorded"

let keeper_cause_group_word = function
  | Keeper_trail.Rate_limited -> "rate limited"
  | Keeper_trail.Connection -> "connection"
  | Keeper_trail.Provider -> "provider"
  | Keeper_trail.Configuration -> "config"
  | Keeper_trail.Input -> "input capacity"
  | Keeper_trail.Unusable_reply -> "unusable reply"
  | Keeper_trail.Effect_fenced -> "effect fenced"
  | Keeper_trail.Recovery -> "recovery needed"
  | Keeper_trail.Stopped -> "stopped"
  | Keeper_trail.Server -> "server"
  | Keeper_trail.Internal -> "internal"

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
let keeper_trail_sentence ~age = function
  | Keeper_trail.Trail_sound -> None
  | Keeper_trail.Trail_failed { ended_at; last; walk } ->
      let reported =
        match last with
        | Some cause -> keeper_failure_cause_word cause
        | None -> "no failure record"
      in
      let rest =
        match walk with
        | Keeper_trail.Walk_ended { runtime_id; cause; tried } ->
            [ keeper_cause_group_word cause
            ; Terminal_text.single_line runtime_id
            ; Message_layout.count_noun tried "candidate"
            ]
        | Keeper_trail.Walk_no_terminal { tried } ->
            [ "terminal not observed"; Message_layout.count_noun tried "candidate" ]
        | Keeper_trail.Walk_no_candidate_failure -> [ reported; no_candidate_failure_text ]
        | Keeper_trail.Walk_not_captured -> [ reported; walk_not_captured_text ]
        | Keeper_trail.Walk_unreadable -> [ reported; evidence_unreadable_text ]
        | Keeper_trail.Walk_absent -> [ reported; no_receipt_text ]
        | Keeper_trail.Walk_not_applicable -> [ reported ]
      in
      Some (failing_glyph ^ " " ^ String.concat " · " (Option.to_list (age ended_at) @ rest))

let keeper_row_trail_sentence ~age (row : Keeper_list_model.row) =
  keeper_trail_sentence ~age (Keeper_list_model.trail_of_row row)

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
let keeper_flag_cell (runtime : keeper_runtime option) =
  let gap = String.make Render_schedule.keeper_flags_gap ' ' in
  match runtime with
  | None -> Ansi.dim ^ "-" ^ gap ^ "-" ^ Ansi.reset
  | Some row ->
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
        | None, _ -> Ansi.dim ^ "?" ^ Ansi.reset
      in
      Mark.activation_letter row.kr_activation_mode ^ gap ^ sandbox

let keeper_activity_word ?(ko = false) (activity : Keeper_list_model.activity) =
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
  | Unknown -> text "미확인" "unknown"

let keeper_activity_style (activity : Keeper_list_model.activity) =
  match activity with
  | Held_call -> Theme.bad ()
  | Question | Confirmation | Offline | Attempt_failed -> Theme.warn ()
  | Preparing | Streaming | Running | Async_working _ | Deferred -> Theme.info ()
  | Tool_waiting -> Theme.warn ()
  | Model_waiting -> Theme.info ()
  | Delegate_result -> Theme.category Theme.Slot_2
  | Verifying -> Theme.category Theme.Slot_1
  | External_waiting | Idle | Paused | Unknown -> Theme.recede ()

let keeper_badge_text (badge : Keeper_list_model.badge) =
  let glyph = Masc_tui_keeper_mark.badge_glyph badge in
  match badge with
  | Badge_read_error -> glyph ^ " read error"
  | Badge_waiting_unavailable -> glyph ^ " waiting unavailable"
  | Badge_async { running; ownership_unknown } ->
      Printf.sprintf "%s async %d%s" glyph running
        (if ownership_unknown > 0 then Printf.sprintf " (%d owner?)" ownership_unknown else "")
  | Badge_async_queued count -> Printf.sprintf "%s queued %d" glyph count
  | Badge_async_cancelling count -> Printf.sprintf "%s cancelling %d" glyph count
  | Badge_delegate -> glyph ^ " delegate result"
  | Badge_verification -> glyph ^ " verify"
  | Badge_schedule -> glyph ^ " schedule"
  | Badge_quota_spent -> glyph ^ " quota spent"

(* Between two pieces of DETAIL. *)
let detail_separator = " · "

let keeper_task_detail (row : Keeper_list_model.row) =
  match row.task with
  | Some task ->
      let id = Terminal_text.single_line task.Tui_decode.id in
      let title = Terminal_text.single_line task.Tui_decode.title in
      Some ("task " ^ id ^ if String.equal title "" then "" else detail_separator ^ title)
  | None -> (
      match row.keeper.Tui_decode.k_activity with
      | Some activity -> Option.map (fun id -> "task " ^ Terminal_text.single_line id)
          activity.Tui_decode.k_current_task_id
      | None -> Some "task not observed")

let keeper_waiting_item_text (item : Tui_decode.waiting_item) =
  Terminal_text.single_line
    (if not (String.equal (String.trim item.kwi_what) "") then item.kwi_what
     else if not (String.equal (String.trim item.kwi_next_action) "") then item.kwi_next_action
     else item.kwi_waiting_on)

let keeper_waiting_detail (row : Keeper_list_model.row) =
  match row.waiting with
  | Keeper_list_model.Waiting_observed { Tui_decode.kwr_waiting_on = (first :: rest as items); _ } ->
      (* A delegate result's operator sentence includes the other Keeper and
         its outcome. Do not hide that behind an earlier scheduled wake. *)
      let item =
        match List.find_opt
            (fun item -> item.Tui_decode.kwi_wake_producer = Tui_decode.Wake_keeper_delegate)
            items with
        | Some result -> result
        | None -> first
      in
      Some (keeper_waiting_item_text item
        ^ (match rest with [] -> "" | _ -> Printf.sprintf " (+%d more)" (List.length rest)))
  | Keeper_list_model.Waiting_observed { kwr_waiting_on = []; _ }
  | Keeper_list_model.Waiting_unobserved | Keeper_list_model.Waiting_unavailable -> None

(* The rest of the path the Keeper's next dispatch takes, for a Keeper whose
   phase runs turns. Matches [Tui_decode.keeper_path_rest] with no wildcards.
   [Stated_by_provider] vs [Bounded_by_masc] distinguishes whether the reset
   time came from the provider or is MASC's upper bound.
   Times are rendered as relative spans via [Message_layout.span_text]; if
   already in the past, time is omitted. *)
type path_rest =
  | Path_serving of string  (* The runtime the next dispatch goes to. *)
  | Path_resting of string  (* The rest the next dispatch waits out. *)
  | Path_unread of string  (* The rest did not read. *)

let keeper_path_rest ?now (row : Keeper_list_model.row) =
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
             if release_at > now_val then " ~" ^ Message_layout.span_text (release_at -. now_val)
             else ""
           in
           let basis_word =
             match release_basis with
             | Tui_decode.Stated_by_provider -> "제공자"
             | Tui_decode.Bounded_by_masc -> "상한"
           in
           Some
             (Path_resting
                (Printf.sprintf "쉬는 중%s (%s · %s)"
                   time_clause
                   (Terminal_text.single_line runtime_id)
                   basis_word))
       | Error detail -> Some (Path_unread ("쉼 읽기 실패: " ^ Terminal_text.single_line detail)))
  | Keeper_control.Present _ | Keeper_control.Absent | Keeper_control.Unobserved
  | Keeper_control.Invalid _ -> None

(* The last piece of DETAIL, so right reads as next. The runtime that serves
   the next dispatch is named only after a failed turn ([Trail_failed]), and
   then, like a rest, behind the next mark. *)
let keeper_next_text ?now (row : Keeper_list_model.row) =
  let after_failure () =
    match Keeper_list_model.trail_of_row row with
    | Keeper_trail.Trail_failed _ -> true
    | Keeper_trail.Trail_sound -> false
  in
  let marked text = Masc_tui_keeper_mark.axis_next_glyph ^ " " ^ text in
  match keeper_path_rest ?now row with
  | None -> None
  | Some (Path_serving runtime_id) -> if after_failure () then Some (marked runtime_id) else None
  | Some (Path_resting text) -> Some (if after_failure () then marked text else text)
  | Some (Path_unread text) -> Some text

let keeper_approval_text (approval : Tui_decode.keeper_tool_approval) =
  "hold " ^ Terminal_text.single_line approval.kta_tool
  ^ detail_separator ^ Terminal_text.single_line approval.kta_question

let keeper_questions_text count =
  Masc_tui_message_layout.count_noun count "question" ^ " awaiting you"

let keeper_detail_text ?now (row : Keeper_list_model.row) =
  let health =
    match keeper_health_deviation_word (Keeper_control.health row.reading) with
    | "" -> None
    | word -> Some ("health " ^ word)
  in
  List.map keeper_badge_text (Keeper_list_model.badges_of_row row)
  @ List.filter_map Fun.id
      [ Option.map keeper_approval_text row.approval
      ; (if row.open_questions > 0 then Some (keeper_questions_text row.open_questions) else None)
      ; keeper_waiting_detail row; keeper_task_detail row; health; keeper_next_text ?now row ]
  |> String.concat detail_separator

(* The DETAIL cell. When the RUNTIME column is not drawn, the sentence about
   the past leads this cell in the warning colour and the rest stays receded.
   The text is fitted as plain text, so a cut mark takes the colour of the text
   it cuts. A sentence that fills the cell is fitted together with the rest, so
   the rest it pushes out is still marked by the cut. *)
let keeper_detail_cell ?now ~width ~failure_context row =
  let rest = keeper_detail_text ?now row in
  match failure_context with
  | None -> Theme.recede () ^ fit_width rest width ^ Ansi.reset
  | Some sentence ->
      let sentence_cells = Message_layout.display_width sentence in
      let tail = if String.equal rest "" then "" else detail_separator ^ rest in
      if sentence_cells >= width then
        Theme.warn () ^ fit_width (sentence ^ tail) width ^ Ansi.reset
      else
        Theme.warn () ^ sentence ^ Theme.recede ()
        ^ fit_width tail (width - sentence_cells)
        ^ Ansi.reset

let keeper_column_header (columns : Render_schedule.keeper_columns) =
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Message_layout.fit_width "KEEPER" columns.kcol_name
    ; " "
    ; Message_layout.fit_width Masc_tui_keeper_mark.now_header
        Render_schedule.keeper_status_width
    ; (if columns.kcol_show_flags then
         " "
         ^ Message_layout.fit_width Render_schedule.keeper_flags_header
             Render_schedule.keeper_flags_width
       else "")
    ; " "
      ^ Message_layout.pad_left Masc_tui_keeper_mark.age_header
          Render_schedule.keeper_last_turn_width
    ; (if columns.kcol_show_runtime then
         " " ^ fit_width "LIFECYCLE / RUNTIME" columns.kcol_runtime
       else "")
    ; (if columns.kcol_show_detail then
         " " ^ Message_layout.fit_width "DETAIL" columns.kcol_task
       else "")
    ]

let keeper_row_runtime (row : Keeper_list_model.row) =
  match row.reading.Keeper_control.liveness with
  | Keeper_control.Present runtime -> Some runtime
  | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None

let keeper_row_marker ~selected = if selected then "\xe2\x80\xba  " (* › *) else "   "

let keeper_row_name ~width ~yolo (row : Keeper_list_model.row) =
  let name =
    Message_layout.fit_middle width (Terminal_text.single_line row.keeper.Tui_decode.k_name)
  in
  if yolo then Theme.bad () ^ name ^ Ansi.reset else name

type keeper_primary_row = { text : string; motion : Masc_tui_answering.motion }
let still_row text = { text; motion = Masc_tui_answering.Still }
let shift_motion ~prefix = function
  | Masc_tui_answering.Still -> Masc_tui_answering.Still
  | Moving through -> Moving (Message_layout.display_width prefix + through)

(* The NOW cell: the activity's mark and word, or the receipt's operator
   disposition where nothing on the row is newer than the receipt. *)
let keeper_now_cell ?(ko = false) ?(padded = true) ~frame (row : Keeper_list_model.row) =
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
    | Some _ -> Theme.bad ()
    | None -> keeper_activity_style activity
  in
  let glyph =
    match operator_disposition with
    | Some _ -> Masc_tui_keeper_mark.activity_glyph Held_call
    | None ->
      (match activity with
       | Preparing | Running -> Masc_tui_answering.running_glyph ~frame
       | Held_call | Question | Confirmation | Attempt_failed | Streaming | Async_working _
       | Deferred | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting
       | Idle | Paused | Offline | Unknown -> Masc_tui_keeper_mark.activity_glyph activity)
  in
  let status_word =
    match operator_disposition with
    | Some disp -> Masc_tui_keeper_mark.operator_disposition_word disp
    | None -> keeper_activity_word ~ko activity
  in
  let text = status_color ^ glyph ^ " "
    ^ (if padded then Message_layout.fit_width status_word (Render_schedule.keeper_status_width - 2) else status_word)
    ^ Ansi.reset in
  let motion = match operator_disposition, activity with
    | None, (Preparing | Running) -> Masc_tui_answering.Moving (Message_layout.display_width glyph)
    | Some _, (Preparing | Running | Held_call | Question | Confirmation | Attempt_failed
        | Streaming | Async_working _ | Deferred | Tool_waiting | Model_waiting | Delegate_result
        | Verifying | External_waiting | Idle | Paused | Offline | Unknown)
    | None, (Held_call | Question | Confirmation | Attempt_failed | Streaming | Async_working _
        | Deferred | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting
        | Idle | Paused | Offline | Unknown) -> Masc_tui_answering.Still in
  { text; motion }

let keeper_row_content ~(columns : Render_schedule.keeper_columns)
    ~now ~frame ~yolo ~selected (row : Keeper_list_model.row) =
  let runtime = keeper_row_runtime row in
  let failure_context =
    keeper_row_trail_sentence ~age:(keeper_trail_age ~now) row
  in
  let age =
    match row.last_activity_at with
    | Some since -> Option.value (Message_layout.age_text ~now ~since)
        ~default:Masc_tui_theme.Glyph.no_value
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let prefix = keeper_row_marker ~selected
    ^ keeper_row_name ~width:columns.kcol_name ~yolo row ^ " " in
  let now_cell = keeper_now_cell ~frame row in
  let text = String.concat ""
    [ prefix
    ; now_cell.text
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; " " ^ Theme.recede ()
      ^ Message_layout.pad_left age Render_schedule.keeper_last_turn_width
      ^ Ansi.reset
    ; (if columns.kcol_show_runtime then
         " " ^ keeper_runtime_cell ~width:columns.kcol_runtime ?failure_context runtime
       else "")
    ; (if columns.kcol_show_detail then
         " "
         ^ keeper_detail_cell ~now ~width:columns.kcol_task
             ~failure_context:
               (Render_schedule.keeper_failure_context_for_detail
                  ~show_runtime:columns.kcol_show_runtime failure_context)
             row
       else "")
    ] in
  { text; motion = shift_motion ~prefix now_cell.motion }

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
let secondary_indent_cells = Render_schedule.keeper_marker_width + 2
let secondary_separator = "  ·  "

let keeper_secondary_row_content ?now ?(cells = []) ~inner (row : Keeper_list_model.row) =
  let indent_cells = secondary_indent_cells in
  let available = max 0 (inner - indent_cells) in
  let attempts = Masc_tui_keeper_trail.attempts_of_runtime (keeper_row_runtime row) in
  let detail =
    match keeper_detail_text ?now row with
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
  ; now_cell : keeper_primary_row
  ; strip : string
  ; due : string
  ; right : string
  }

let grid_line (grid : Grid.t) cells =
  let side = grid.side_cells > 0 in
  let prefix = String.concat ""
    [ cells.gutter; cells.name; (if side then " " ^ cells.pulse else ""); " " ] in
  let text = String.concat ""
    [ prefix
    ; grid_band cells.now_cell.text
    ; " "
    ; (if side then cells.strip ^ " " else "")
    ; cells.due
    ; (if grid.mem_cells > 0 then " " ^ cells.right else "")
    ] in
  (* The band's style/background sequences take no cells. Its left line and
     following space precede the source NOW cell. *)
  { text; motion = shift_motion ~prefix:(prefix ^ Keeper_mark.grid_now_line ^ " ")
      cells.now_cell.motion }

(* The cells before the band: the gutter, the name and the pulse. *)
let grid_lead_cells (grid : Grid.t) =
  Grid.gutter_cells + grid.name_cells + if grid.side_cells > 0 then 1 + grid.side_cells else 0

(* The cells after the band: the strip, the due column and the right column. *)
let grid_tail_cells (grid : Grid.t) =
  (if grid.side_cells > 0 then Grid.strip_cells grid + 1 else 0)
  + Grid.due_cells
  + if grid.mem_cells > 0 then 1 + grid.mem_cells else 0

(* The mock's [okd]: the ok colour, receded. *)
let grid_receded_ok () = Ansi.dim ^ Theme.ok ()

let grid_gutter_style = function
  | Grid.Failing { resting = false } -> Theme.warn ()
  | Grid.Failing { resting = true } | Grid.Paused | Grid.Other -> Theme.recede ()
  | Grid.Recovered -> grid_receded_ok ()
  | Grid.Sound -> Theme.ok ()

let grid_gutter view verdict =
  "  " ^ grid_gutter_style verdict ^ Ansi.bold
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
    Masc_tui_keeper_strip.history_unknown_label ~ko:(state.ui_language = Lang_ko)
      ~cells:grid.side_cells
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
      Masc_tui_keeper_strip.wake_strip ~ko ~style slots

(* Scheduled wakes per half hour, the now slot first. Unknown windows get
   one label; the shared renderer keeps mixed unknown and empty slots apart. *)
let grid_wake_strip state (grid : Grid.t) ~now verdict ~keeper_name =
  let paused = match verdict with
    | Grid.Paused -> true
    | Grid.Failing _ | Grid.Recovered | Grid.Sound | Grid.Other -> false in
  grid_wake_window state
    ~style:(Masc_tui_keeper_strip.Keeper_wakes { paused })
    (Masc_tui_keeper_axis.wake_strip state ~now ~ahead:(Grid.strip_cells grid - 1)
       ~keeper_name)

let grid_due ~now verdict next_run =
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
  ^ fit_width (Grid.due_text ~now ~localtime:Unix.localtime next_run) Grid.due_cells
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
let grid_librarian memory =
  grid_fitted Grid.now_cells
    (match Memory_reading.pass_end memory with
     | Memory_reading.No_snapshot | Memory_reading.Row_absent ->
         grid_quiet Keeper_mark.grid_no_data_word
     | Memory_reading.Measured _ | Memory_reading.Unmeasured | Memory_reading.Snapshot_unknown
     | Memory_reading.Row_refused -> Memory_reading.pass_cell memory)

(* The strip column of the memory and age views: the unread turns as a bar
   against [peak_lag] on a ground of dots, in the info colour when requests
   skip atoms. A reading without a row leaves it to the ● cell. *)
let grid_lag_bar (grid : Grid.t) ~peak_lag memory =
  let cells = Grid.strip_cells grid in
  let ground count = Theme.recede () ^ grid_repeat count Keeper_mark.grid_dot_mark ^ Ansi.reset in
  match memory with
  | Memory_reading.Row { lag = Memory_reading.Lag turns; gap; _ } ->
      let filled = Grid.lag_fill ~cells ~peak:peak_lag turns in
      let fill =
        match gap with
        | Memory_reading.Gap _ | Memory_reading.Gap_unmeasured -> Theme.info ()
        | Memory_reading.No_gap -> Theme.recede ()
      in
      fill ^ grid_repeat filled Keeper_mark.grid_full_mark ^ Ansi.reset ^ ground (cells - filled)
  | Memory_reading.Row { lag = Memory_reading.Lag_unmeasured; _ } ->
      Theme.recede () ^ Keeper_mark.unknown_mark ^ Ansi.reset ^ ground (cells - 1)
  | Memory_reading.Unknown | Memory_reading.No_row | Memory_reading.Refused _ ->
      String.make cells ' '

(* The memory view's due column: how long ago the last digest succeeded, [—]
   before the first. *)
let grid_digest ~now memory =
  let text =
    match Memory_reading.digest_at memory with
    | Memory_reading.Measured at -> Grid.short_span (now -. at)
    | Memory_reading.Unmeasured -> Masc_tui_theme.Glyph.no_value
    | Memory_reading.No_snapshot | Memory_reading.Snapshot_unknown | Memory_reading.Row_absent
    | Memory_reading.Row_refused -> ""
  in
  Theme.recede () ^ fit_width text Grid.due_cells ^ Ansi.reset

(* The memory view's right column: the atoms requests skip. *)
let grid_gap (grid : Grid.t) memory =
  let text =
    match memory with
    | Memory_reading.Row { gap = Memory_reading.Gap { first_atom; past_last_atom }; _ }
      when past_last_atom > first_atom ->
        Masc_tui_chart.format_compact_num (past_last_atom - first_atom)
    | Memory_reading.No_row | Memory_reading.Row { gap = Memory_reading.Gap_unmeasured; _ } -> Keeper_mark.unknown_mark
    | Memory_reading.Row { gap = Memory_reading.Gap _ | Memory_reading.No_gap; _ }
    | Memory_reading.Unknown | Memory_reading.Refused _ -> ""
  in
  Theme.info () ^ Message_layout.pad_left text grid.mem_cells ^ Ansi.reset

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
let grid_saved ~now memory =
  match Memory_reading.updated_at memory with
  | Memory_reading.Measured at ->
      fit_width (Keeper_mark.grid_saved_mark ^ " " ^ Grid.short_span (now -. at)) Grid.now_cells
  | Memory_reading.No_snapshot | Memory_reading.Row_absent ->
      grid_fitted Grid.now_cells
        (grid_quiet (Masc_tui_theme.Glyph.no_value ^ " " ^ Keeper_mark.grid_no_snapshot_word))
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

let grid_keeper_row state (grid : Grid.t) columns ~view ~peak_lag ~peak_facts ~now ~frame ~yolo
    (row : Keeper_list_model.row) =
  let runtime = keeper_row_runtime row in
  let verdict = Grid.verdict ~now runtime in
  let keeper_name = row.keeper.Tui_decode.k_name in
  let memory = keeper_memory_reading state row in
  let gutter = grid_gutter view verdict in
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
         ; now_cell = keeper_now_cell ~frame row
         ; strip = grid_wake_strip state grid ~now verdict ~keeper_name
         ; due = grid_due ~now verdict (Masc_tui_keeper_axis.next_run state ~keeper_name)
         ; right = grid_lag_cell grid ~peak_lag memory
         }
     | Axis_row.Memory_columns ->
         { gutter
         ; name
         ; pulse = pulse ()
         ; now_cell = still_row (grid_librarian memory)
         ; strip = grid_lag_bar grid ~peak_lag memory
         ; due = grid_digest ~now memory
         ; right = grid_gap grid memory
         }
     | Axis_row.Age_columns ->
         { gutter
         ; name
         ; pulse = grid_fact_ages grid memory
         ; now_cell = still_row (grid_saved ~now memory)
         ; strip = grid_lag_bar grid ~peak_lag memory
         ; due = grid_stale memory
         ; right = grid_facts grid ~peak_facts memory
         })

(* The failure line under a failing Keeper of the state and cause views
   (§2.4.6). Under the name: when the failing phase began, or how long ago the
   last failure was when the server recorded no start. *)
let grid_failure_since ~now ~room (runtime : keeper_runtime option) trail =
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
      let clock = Grid.dated_clock_text ~now ~localtime:Unix.localtime at in
      let worded = Keeper_mark.grid_since_word ^ " " ^ clock in
      (* The word goes first, so a cut never leaves a minute that reads as data. *)
      if Message_layout.display_width worded <= room then worded else clock
  | Masc_tui_keeper_pulse.Failing_unrecorded, Keeper_trail.Trail_failed { ended_at = Some at; _ }
    when at <= now ->
      Grid.short_span (now -. at) ^ " " ^ Keeper_mark.grid_ago_word
  | ( (Masc_tui_keeper_pulse.Failing_unrecorded | Masc_tui_keeper_pulse.Not_failing)
    , (Keeper_trail.Trail_failed _ | Keeper_trail.Trail_sound) ) -> ""

(* The word for why the failed turn ended: the receipt's cause when it names
   the runtime that ended it, the server's own cause word otherwise. *)
let grid_failure_word = function
  | Keeper_trail.Trail_failed { walk = Keeper_trail.Walk_ended { cause; _ }; _ } ->
      keeper_cause_group_word cause
  | Keeper_trail.Trail_failed
      { walk =
          ( Keeper_trail.Walk_no_terminal _ | Keeper_trail.Walk_no_candidate_failure
          | Keeper_trail.Walk_not_captured | Keeper_trail.Walk_unreadable | Keeper_trail.Walk_absent
          | Keeper_trail.Walk_not_applicable )
      ; last = Some cause
      ; ended_at = _
      } -> keeper_failure_cause_word cause
  | Keeper_trail.Trail_failed { last = None; _ } | Keeper_trail.Trail_sound -> ""

(* In the pulse column: one ✗ per attempt of the failed turn, at most
   [Grid.chain_attempts], then the failure word. *)
let grid_failure_chain (grid : Grid.t) runtime trail =
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
    match grid_failure_word trail with
    | "" -> []
    | word -> [ recede word ]
  in
  fit_width (String.concat " " (chain @ word)) grid.side_cells

(* From the strip column on: the runtime the next dispatch takes, or the one
   whose rest it waits out. *)
let grid_next_dispatch (runtime : keeper_runtime option) =
  match runtime with
  | Some runtime when Tui_decode.keeper_phase_executes_turns runtime.Tui_decode.kr_phase -> (
      match runtime.Tui_decode.kr_runtime_path_rest with
      | Ok (Some (Tui_decode.Path_rest_serving { runtime_id })) ->
          Theme.info () ^ Keeper_mark.axis_next_glyph ^ " " ^ Terminal_text.single_line runtime_id
          ^ Ansi.reset
      | Ok (Some (Tui_decode.Path_rest_resting { runtime_id; release_at = _; release_basis = _ })) ->
          Theme.recede ()
          ^ String.concat " "
              [ Keeper_mark.grid_wait_glyph; Keeper_mark.grid_wait_word
              ; Terminal_text.single_line runtime_id ]
          ^ Ansi.reset
      | Ok None -> ""
      | Error _ ->
          Theme.recede () ^ Keeper_mark.axis_next_glyph ^ " " ^ Keeper_mark.unknown_mark ^ Ansi.reset)
  | Some _ | None -> ""

let grid_since_lead = Keeper_mark.failing_glyph ^ " "

let grid_failure_line (grid : Grid.t) ~now (row : Keeper_list_model.row) =
  let runtime = keeper_row_runtime row in
  let trail = Keeper_list_model.trail_of_row row in
  let since =
    grid_failure_since ~now
      ~room:(grid.name_cells - Message_layout.display_width grid_since_lead)
      runtime trail
  in
  String.concat ""
    [ grid_gutter_style (Grid.verdict ~now runtime) ^ Keeper_mark.grid_gutter_glyph ^ Ansi.reset
      ^ String.make (Grid.gutter_cells - 1) ' '
    ; (match since with
       | "" -> String.make grid.name_cells ' '
       | since -> Theme.recede () ^ fit_width (grid_since_lead ^ since) grid.name_cells ^ Ansi.reset)
    ; (if grid.side_cells > 0 then " " ^ grid_failure_chain grid runtime trail else "")
    ; " "
    ; grid_band grid_blank_now
    ; " "
    ; fit_width (grid_next_dispatch runtime) (grid_tail_cells grid)
    ]

(* Group sums use only members of this heading, including folded rows. *)
let group_pulse_slots = 12
let group_pulse_min_cells = 20

let group_pulse ~now members =
  let hours row = Masc_tui_keeper_pulse.half_hours ~now ~count:group_pulse_slots
      (Option.bind (keeper_row_runtime row) (fun r -> r.Tui_decode.kr_recent_turns)) in
  let readings = List.map hours members in
  String.concat "" (List.init group_pulse_slots (fun position ->
    let count, unknown = List.fold_left (fun (count, unknown) slots ->
      match List.nth_opt slots position with
      | Some (Masc_tui_keeper_pulse.Half_hour_failed | Masc_tui_keeper_pulse.Half_hour_failed_and_ok) -> count + 1, unknown
      | Some Masc_tui_keeper_pulse.Half_hour_unknown | None -> count, true
      | Some (Masc_tui_keeper_pulse.Half_hour_quiet | Masc_tui_keeper_pulse.Half_hour_ok) -> count, unknown)
      (0, false) readings in
    if count > 0 then Theme.warn () ^ Grid.level_glyph ~peak:(List.length members) count ^ Ansi.reset
    else Theme.recede () ^ (if unknown then "?" else "·") ^ Ansi.reset))

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

let grid_group_title state (grid : Grid.t) ~now ~group ~members ~folded ~style ~pulse title =
  let count = List.length members in
  let memories = List.map (keeper_memory_reading state) members in
  let lag = group_number (group_sum group_lag memories) in
  let now_text, tail, right = match group with
    | Keeper_list_model.Group_cause (Keeper_list_model.Cause_named _ | Keeper_list_model.Cause_unnamed) ->
        let retry, wait, unknown = List.fold_left (fun (retry, wait, unknown) row ->
          match keeper_row_runtime row with
          | Some runtime -> (match runtime.Tui_decode.kr_runtime_path_rest with
              | Ok (Some (Tui_decode.Path_rest_resting _)) -> retry, wait + 1, unknown
              | Ok (Some (Tui_decode.Path_rest_serving _)) -> retry + 1, wait, unknown
              | Ok None | Error _ -> retry, wait, unknown + 1)
          | None -> retry, wait, unknown + 1) (0, 0, 0) members in
        let parts = (if retry > 0 then [Printf.sprintf "▹ retry %d" retry] else [])
          @ (if wait > 0 then [Printf.sprintf "◌ wait %d" wait] else [])
          @ (if unknown > 0 then [Printf.sprintf "? %d" unknown] else []) in
        Printf.sprintf "! %d failing" count, String.concat "  " parts, ""
    | Keeper_list_model.Group_cause Keeper_list_model.Cause_recovered ->
        Printf.sprintf "✓ %d" count, group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_cause Keeper_list_model.Not_failing ->
        Printf.sprintf "● %d" count, group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_cause Keeper_list_model.Cause_paused ->
        Printf.sprintf "○ %d" count, group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_state _ | Keeper_list_model.Group_due _ ->
        string_of_int count, group_wake_strip state grid ~now members, ""
    | Keeper_list_model.Group_memory _ ->
        let gap = match group_sum group_gap memories with Some 0 -> "" | value -> group_number value in
        string_of_int count, "Σ lag " ^ lag, gap
    | Keeper_list_model.Group_age age ->
        let odd = if age <> Keeper_list_model.Age_older then 0 else
          List.length (List.filter (fun row -> match keeper_row_runtime row with
            | Some r -> not r.Tui_decode.kr_paused && (match r.kr_activation_mode with
                | Tui_decode.Activation_autonomous -> true
                | Tui_decode.Activation_manual | Tui_decode.Activation_on_demand -> false)
            | None -> false) members) in
        (if odd > 0 then Printf.sprintf "%d · %d!" count odd else string_of_int count),
        "Σ " ^ group_number (group_sum group_facts memories) ^ " facts · lag " ^ lag, "" in
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
    [ "  "
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
  let lag_bar =
    if Grid.strip_cells grid >= grid_lag_bar_header_cells then Keeper_mark.grid_lag_bar_header
    else Keeper_mark.grid_lag_bar_short_header
  in
  let pulse_header word = grid_spread ~cells:grid.side_cells word Grid.slot_label in
  let name, pulse, now_word, strip, due, right =
    match columns with
    | Axis_row.Activity_columns ->
        ( Keeper_mark.grid_keeper_header
        , pulse_header (Keeper_mark.grid_pulse_header ~window)
        , Keeper_mark.axis_now_header
        , (match state.keeper_list_view with
           | Keeper_list_model.By_state ->
               ui_text state ~ko:("예약 확인 · " ^ window) ~en:("known wakes · " ^ window)
           | Plain | By_cause | By_time | By_memory | By_age | By_runtime | Day_wall ->
               Keeper_mark.grid_next_header ~window)
        , Keeper_mark.grid_due_header
        , Message_layout.pad_left Keeper_mark.grid_lag_header (grid.mem_cells - grid_level_cells) )
    | Axis_row.Memory_columns ->
        ( Keeper_mark.grid_keeper_header
        , pulse_header (Keeper_mark.grid_pulse_header ~window:(Keeper_mark.grid_turns_word ^ " " ^ window))
        , Keeper_mark.grid_librarian_header
        , lag_bar
        , Keeper_mark.grid_digest_header
        , Message_layout.pad_left Keeper_mark.grid_gap_header grid.mem_cells )
    | Axis_row.Age_columns ->
        ( (if grid.name_cells >= grid_facts_by_age_name_cells then
             fit_width Keeper_mark.grid_keeper_header grid_facts_by_age_offset
             ^ Keeper_mark.grid_facts_by_age_header
           else Keeper_mark.grid_keeper_header)
        , Age_ladder.tick_line ~column:grid.side_cells
        , Keeper_mark.grid_saved_header
        , lag_bar
        , Keeper_mark.grid_stale_header
        , Message_layout.pad_left Keeper_mark.grid_facts_header grid.mem_cells )
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
let keeper_fleet_gap_lines (fleet : fleet_safety) =
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
    [ (not_running, "not running", (Theme.bad ()))
    ; (running_without_turn, "running, cannot take a turn", (Theme.warn ()))
    ; (* Failing subsets that need operator action: turn configuration
         errors survive every retry, so the names are listed where the
         failing counter only counts them. Unscoped on purpose -- the
         configuration_blocked_* wire fields are autoboot-scoped and skip a
         blocked keeper booted on request. *)
      ( names fleet.fs_turn_configuration_error_names
      , "config-blocked"
      , (Theme.bad ()) )
    ; ( names fleet.fs_official_client_recovery_required_names
      , "session recovery required"
      , (Theme.bad ()) )
    ]


(* The conditions that share a phase with another: either health reading
   makes a keeper failing, and a pending launch is one of the ways it is
   offline. Each of the other conditions has a phase of its own, which the
   lifecycle word already says, so naming it again would add nothing. *)
let keeper_lane_phase_causes (conditions : Tui_decode.keeper_lane_conditions) =
  List.filter_map
    (fun (holds, words) -> if holds then Some words else None)
    [ (not conditions.klc_turn_healthy, "last turn failed")
    ; (not conditions.klc_heartbeat_healthy, "heartbeat failed")
    ; (conditions.klc_launch_pending, "launch pending")
    ]

let keeper_lane_lifecycle_text (lane : Tui_decode.keeper_lane) =
  let phase =
    Terminal_text.single_line (Tui_decode.keeper_lane_phase_to_string lane.kl_phase)
  in
  match Option.fold ~none:[] ~some:keeper_lane_phase_causes lane.kl_conditions with
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
                id_text ^ " \xc2\xb7 not in the runtime list"))
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
  let fields = match reading with
  | Some { kcr_lane = lane; _ } ->
      [ "Lifecycle:", keeper_lane_lifecycle_text lane
      ; "Turn:", Terminal_text.single_line
          (Tui_decode.keeper_lane_turn_phase_to_string lane.kl_turn_phase)
      ; "Idle:", keeper_lane_idle_text lane.kl_idle_seconds
      ; "Last outcome:", keeper_operations_outcome_text lane.kl_last_outcome
      ; "Last runtime:", keeper_last_runtime_text state lane.kl_last_outcome
      ]
  | None ->
      (match error with
       | Some detail ->
           [ "Execution:", Theme.warn () ^ "unavailable · "
             ^ Terminal_text.single_line detail ^ Ansi.reset ]
       | None ->
           if reading_now then []
           else [ "Execution:", Ansi.dim ^ "not observed" ^ Ansi.reset ])
  in
  let fields = match reading, error with
    | Some _, Some detail ->
        ("Execution:", Theme.warn () ^ "stale · refresh failed: "
          ^ Terminal_text.single_line detail ^ Ansi.reset) :: fields
    | Some _, None | None, (Some _ | None) -> fields in
  if reading_now then
    ("Execution:", Ansi.dim
      ^ (match reading with
         | None -> "reading execution snapshot…"
         | Some _ -> "refreshing execution snapshot · last observation")
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

(* The views [v] walks, one press each (RFC-0515 §2.3). *)
let keeper_view_tabs ~cols view =
  let lead = "  " in
  lead
  ^ tab_strip ~width:(tab_strip_width ~cols ~before:lead ~after:"")
      ~press:(fun target text -> pressable (Press_keeper_view target) text)
      (List.map
         (fun candidate -> Keeper_list_model.view_label candidate, candidate = view, candidate)
         Keeper_list_model.views)

let keeper_state_heading_style = function
  | Keeper_list_model.Attention -> Theme.bad ()
  | Keeper_list_model.Failing -> Theme.warn ()
  | Keeper_list_model.Active -> Theme.ok ()
  | Keeper_list_model.Waiting -> Theme.info ()
  | Keeper_list_model.Inactive -> Theme.recede ()
  | Keeper_list_model.Unobserved -> Theme.warn ()

let keeper_group_heading_style = function
  | Keeper_list_model.Group_state attention -> keeper_state_heading_style attention
  | Keeper_list_model.Group_cause (Keeper_list_model.Cause_named _ | Keeper_list_model.Cause_unnamed) ->
      Theme.warn ()
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_recovered -> grid_receded_ok ()
  | Keeper_list_model.Group_cause Keeper_list_model.Not_failing -> Theme.ok ()
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

let keeper_state_heading_text ~available_cells rows group count =
  let label =
    match group with
    | Keeper_list_model.Attention -> "Attention"
    | Keeper_list_model.Failing -> "Failing"
    | Keeper_list_model.Active -> "Active"
    | Keeper_list_model.Waiting -> "Waiting"
    | Keeper_list_model.Inactive -> "Inactive"
    | Keeper_list_model.Unobserved -> "Unknown"
  in
  let detail =
    match group with
    | Keeper_list_model.Waiting ->
        Render_schedule.waiting_group_heading_detail ~available_cells ~group_count:count
          (Keeper_list_model.waiting_summary rows)
    | Keeper_list_model.Attention | Keeper_list_model.Failing | Keeper_list_model.Active
    | Keeper_list_model.Inactive | Keeper_list_model.Unobserved -> ""
  in
  Printf.sprintf "%s %d%s" label count detail

let keeper_group_heading_text ~available_cells rows group count =
  match group with
  | Keeper_list_model.Group_state attention ->
      keeper_state_heading_text ~available_cells rows attention count
  | Keeper_list_model.Group_cause (Keeper_list_model.Cause_named cause) ->
      Printf.sprintf "%s %s %d" failing_glyph
        (String.uppercase_ascii (keeper_cause_group_word cause)) count
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_unnamed ->
      Printf.sprintf "%s FAILING · CAUSE NOT RECORDED %d" failing_glyph count
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_recovered -> "recovered · failed in 12h"
  | Keeper_list_model.Group_cause Keeper_list_model.Not_failing -> "no current failure"
  | Keeper_list_model.Group_cause Keeper_list_model.Cause_paused -> "paused"
  | Keeper_list_model.Group_due due ->
      let label =
        match due with
        | Keeper_list_model.Due_late -> "LATE"
        | Keeper_list_model.Due_held -> "HELD"
        | Keeper_list_model.Due_within_hour -> "WITHIN 1H"
        | Keeper_list_model.Due_within_half_day -> "WITHIN 12H"
        | Keeper_list_model.Due_later -> "LATER"
        | Keeper_list_model.Due_none -> "NO SCHEDULE"
        | Keeper_list_model.Due_unknown -> "SCHEDULE UNKNOWN"
      in
      Printf.sprintf "%s %s %d"
        (Masc_tui_keeper_mark.badge_glyph Keeper_list_model.Badge_schedule)
        label count
  | Keeper_list_model.Group_memory follow ->
      let label =
        match follow with
        | Keeper_list_model.Memory_refused -> "MEMORY REFUSED"
        | Keeper_list_model.Memory_gap -> "MEMORY GAP"
        | Keeper_list_model.Memory_lagging -> "MEMORY LAGGING"
        | Keeper_list_model.Memory_following -> "MEMORY FOLLOWING"
        | Keeper_list_model.Memory_unread -> "NO MEMORY READING"
      in
      Printf.sprintf "%s %d" label count
  | Keeper_list_model.Group_age age ->
      let label =
        match age with
        | Keeper_list_model.Age_within_3h -> "UPDATED WITHIN 3H"
        | Keeper_list_model.Age_within_day -> "UPDATED WITHIN 24H"
        | Keeper_list_model.Age_within_3d -> "UPDATED WITHIN 3D"
        | Keeper_list_model.Age_older -> "UPDATED EARLIER"
        | Keeper_list_model.Age_unknown -> "UPDATE TIME UNKNOWN"
      in
      Printf.sprintf "%s %d" label count

(* The columns a Story window label takes: two of indent, the mark and the word. *)
let story_label_cells = 10

(* The story page of the Story window (RFC-0515 section 2.5): the Keeper under
   the cursor told as past, now and next. Every part is a cell or a sentence the
   list rows already draw, so the window states no value a row does not. *)
let keeper_story_lines (state : state) ~now ~inner ~body_rows (row : Keeper_list_model.row) =
  let keeper_name = row.keeper.Tui_decode.k_name in
  let runtime =
    match row.reading.Keeper_control.liveness with
    | Keeper_control.Present runtime -> Some runtime
    | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None
  in
  let memory = Masc_tui_render_keeper_story.memory_reading state ~keeper_name in
  let dim text = Ansi.dim ^ text ^ Ansi.reset in
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
        Some (Theme.warn () ^ Printf.sprintf "lag %d" turns ^ Ansi.reset)
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
                  Printf.sprintf "last %dh %s" Masc_tui_keeper_mark.pulse_hours cell.text
              })
          pulse_cell
      ]
  in
  let past_head = match past_parts with [] -> [] | _ -> [ join past_parts ] in
  let past_tail =
    Option.to_list
      (Option.map
         (fun sentence -> Theme.warn () ^ sentence ^ Ansi.reset)
         (keeper_row_trail_sentence ~age:(keeper_trail_age ~now) row))
    @ Option.to_list
        (render_attempt_chain
           ~max_cells:(max 0 (inner - story_label_cells))
           (Masc_tui_keeper_trail.attempts_of_runtime runtime))
  in
  let activity = Keeper_list_model.primary_activity_of_row row in
  let age =
    match row.last_activity_at with
    | Some since ->
        Option.value (Message_layout.age_text ~now ~since) ~default:Masc_tui_theme.Glyph.no_value
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let detail = keeper_detail_text ~now row in
  let now_entries =
    [ keeper_activity_style activity
      ^ Masc_tui_keeper_mark.activity_glyph activity ^ " " ^ keeper_activity_word activity
      ^ Ansi.reset
      ^ (if String.equal detail "" then "" else dim (" · " ^ detail))
    ; dim (Render_schedule.keeper_flags_header ^ " ")
      ^ keeper_flag_cell runtime
      ^ dim
          (Printf.sprintf "   %s %s   %s" Masc_tui_keeper_mark.age_header age
             (keeper_runtime_label runtime))
    ]
  in
  let next_parts =
    List.filter_map Fun.id
      [ Option.map style_axis_cell
          (Masc_tui_render_keeper_story.next_run_cell state ~now ~keeper_name)
      ; Option.map dim (keeper_next_text ~now row)
      ; lag
      ]
  in
  let next_entries =
    match next_parts with [] -> [ dim "nothing announced" ] | _ -> [ join next_parts ]
  in
  (* Source cautions in the feed precede the optional trail and flags. Keep
     the current activity and next reading, then let the feed use its own
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
    then [ dim "nothing recorded" ] else feed in
  let detail_room = max 0 (feed_room - List.length feed) in
  let past_tail = List.take detail_room past_tail in
  let now_entries = primary_now
    @ List.take (max 0 (detail_room - List.length past_tail)) (List.drop 1 now_entries) in
  let past_entries = past_head @ feed @ past_tail in
  labelled_lines "◂ past" past_entries
  @ labelled_lines "● now" now_entries
  @ labelled_lines "▹ next" next_entries

(* The Keeper's name and what it is doing, at the left of the window's title. *)
let keeper_story_lead (row : Keeper_list_model.row) =
  let activity = Keeper_list_model.primary_activity_of_row row in
  "  " ^ Ansi.bold ^ Terminal_text.single_line row.keeper.Tui_decode.k_name ^ Ansi.reset ^ "  "
  ^ keeper_activity_style activity ^ keeper_activity_word activity ^ Ansi.reset

let draw_keeper_story buf ~cols ~rows ~now ~inner (state : state) page
    (row : Keeper_list_model.row option) =
  let lead, lines =
    match page, row with
    | Masc_tui_keeper_story.World, (Some _ | None) ->
        ("  " ^ Theme.info () ^ "world · shared workspace memory" ^ Ansi.reset,
         Masc_tui_keeper_world.dock_lines ~health_error:state.memory_health_error
           ~cells:inner ~max_lines:(Masc_tui_render_keeper_story.body_rows ~rows)
           state.memory_health (Masc_tui_memory_world.reading state.memory_world))
    | Masc_tui_keeper_story.(Story | Schedule | Memory), None ->
        ( "  " ^ Ansi.dim ^ "no Keeper" ^ Ansi.reset
        , [ Ansi.dim ^ "  no Keeper under the cursor" ^ Ansi.reset ] )
    | Masc_tui_keeper_story.(Story | Schedule | Memory), Some row ->
        let keeper_name = row.keeper.Tui_decode.k_name in
        ( keeper_story_lead row
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
  Masc_tui_render_keeper_story.draw buf ~cols ~rows ~lead ~current:page lines

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

let matrix_header matrix =
  String.make Grid.gutter_cells ' ' ^ fit_width "keeper" matrix.matrix_name_cells ^ " "
  ^ String.concat "" (List.mapi (fun index _ -> fit_width (matrix_letter index) matrix.matrix_cell_cells) matrix.matrix_ids)
  ^ " " ^ fit_width "last" 5
  ^ fit_width ("◂ " ^ Grid.window_label ~slots:matrix.matrix_pulse_slots) matrix.matrix_pulse_slots

let matrix_keeper_row matrix ~now row =
  let runtime = keeper_row_runtime row in
  let cells = List.map (fun runtime_id ->
    let cell = Keeper_trail.matrix_cell ~runtime_id runtime in
    let head = match cell.head with
      | Keeper_trail.Head_elsewhere -> " "
      | Keeper_trail.Head_serving -> Theme.info () ^ "▹"
      | Keeper_trail.Head_resting -> Theme.recede () ^ "◌"
      | Keeper_trail.Head_unknown -> Theme.recede () ^ "?" in
    let failure = match cell.failure with
      | Keeper_trail.Matrix_failed -> Theme.warn () ^ "✗"
      | Keeper_trail.Matrix_clear -> " "
      | Keeper_trail.Matrix_unknown -> Theme.recede () ^ "?" in
    fit_width (failure ^ head ^ Ansi.reset) matrix.matrix_cell_cells) matrix.matrix_ids in
  let last = match Keeper_list_model.trail_of_row row with
    | Keeper_trail.Trail_failed { ended_at = Some at; _ } when at <= now -> Grid.short_span (now -. at)
    | Keeper_trail.Trail_failed _ | Keeper_trail.Trail_sound -> "?" in
  let pulse = Option.bind runtime (fun r -> r.Tui_decode.kr_recent_turns)
    |> Masc_tui_keeper_pulse.half_hours ~now ~count:matrix.matrix_pulse_slots
    |> List.map Masc_tui_keeper_pulse.half_hour_mark |> String.concat "" in
  Theme.warn () ^ "▌ ! " ^ Ansi.reset
  ^ fit_width (Terminal_text.single_line row.Keeper_list_model.keeper.Tui_decode.k_name) matrix.matrix_name_cells
  ^ " " ^ String.concat "" cells ^ " " ^ Theme.recede () ^ fit_width last 5
  ^ Theme.warn () ^ pulse ^ Ansi.reset

let matrix_legend ~inner matrix =
  let ids = List.mapi (fun index id -> matrix_letter index ^ " " ^ Terminal_text.single_line id) matrix.matrix_ids in
  let omitted = if matrix.matrix_omitted = 0 then [] else
    [Printf.sprintf "+%d runtime columns outside this width" matrix.matrix_omitted] in
  "✗ failed in last walk · ▹ next head · ◌ resting head · ? unread head"
  :: Message_layout.wrap_words ~max_cells:inner (String.concat " · " (ids @ omitted))

let proactive_outcome_word ?(ko = false) =
  let text korean english = if ko then korean else english in
  function
  | Masc.Keeper_meta_contract.Proactive_never_started -> text "아직 시작하지 않음" "never started"
  | Masc.Keeper_meta_contract.Proactive_unknown -> text "결과 미확인" "unknown"
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

(* The operator roster uses the same row readings as the axis views. These
   sentences do not turn missing observations into idle work or no requests. *)
let keeper_plain_work (state : state) (row : Keeper_list_model.row) =
  let text ko en = ui_text state ~ko ~en in
  match row.task with
  | Some task ->
      let title = Terminal_text.single_line task.Tui_decode.title in
      let title = if String.equal (String.trim title) "" then Terminal_text.single_line task.id else title in
      let task_source = match local_rows_page state ~error:state.tasks_error with
        | Page_failed -> text "배정 목록 갱신 실패 · 보존된 배정 작업: " "assignment refresh failed · retained assignment: "
        | Page_unread -> text "배정 목록 미확인 · 보존된 배정 작업: " "assignment source unread · retained assignment: "
        | Page_empty ->
            if Option.is_some (local_source_pending state Local_work) then
              text "배정 목록 갱신 중 · 보존된 배정 작업: " "assignment refresh pending · retained assignment: "
            else text "관측된 배정 작업: " "observed assignment: "
      in
      let keeper_source = match keeper_rows_page state ~error:state.keepers_error with
        | Page_failed -> text "Keeper 배정 연결 갱신 실패 · " "Keeper assignment link refresh failed · "
        | Page_unread -> text "Keeper 배정 연결 미확인 · " "Keeper assignment link unread · "
        | Page_empty ->
            if Option.is_some (local_source_pending state Local_keepers) then
              text "Keeper 배정 연결 갱신 중 · " "Keeper assignment link refreshing · " else ""
      in
      (if row.reading.Keeper_control.paused then text "저장된 일시정지 · " "stored pause · " else "")
      ^ keeper_source ^ task_source ^ title
  | None ->
      (match keeper_waiting_detail row with
       | Some reason ->
           (if Option.is_some state.keeper_waiting_error || Option.is_some state.keeper_waiting_failure
               || Option.is_some state.keeper_turns_error then
              text "마지막 대기 관측 · 갱신 실패: " "last waiting observation · refresh failed: "
            else if Option.is_some (keeper_waiting_refresh_slow state) then
              text "마지막 대기 관측 · 갱신 대기: " "last waiting observation · refresh pending: "
            else text "관측된 대기: " "observed wait: ") ^ reason
       | None ->
           let observed ko en =
             (if Option.is_some state.keeper_turns_error then
                text "마지막 턴 관측 · 갱신 실패: " "last turn observation · refresh failed: "
              else if state.keeper_turns_inflight then
                text "마지막 턴 관측 · 갱신 중: " "last turn observation · refreshing: "
              else text "턴 관측: " "turn observation: ") ^ text ko en
           in
           match row.turn with
           | Some (Tui_decode.Keeper_turn_running { preview = Some preview; _ }) ->
               let status = Terminal_text.single_line preview.ktp_status_text in
               if String.equal (String.trim status) "" then
                 observed "실행 중 · 작업 이름 미관측" "running · work title not observed"
               else observed status status
           | Some (Tui_decode.Keeper_turn_unavailable reason) ->
               text "실행 상태 미확인: " "execution unknown: " ^ Terminal_text.single_line reason
           | Some (Tui_decode.Keeper_turn_running { preview = None; _ }) ->
               observed "실행 중 · 작업 이름 미관측" "running · work title not observed"
           | Some Tui_decode.Keeper_turn_idle ->
               observed "실행 중인 턴 없음 · 작업 이름 미관측" "no running turn · work title not observed"
           | None -> text "현재 작업 미관측" "current work not observed")

let keeper_plain_help (state : state) (row : Keeper_list_model.row) =
  let text ko en = ui_text state ~ko ~en in
  match Keeper_list_model.person_wait row with
  | Some request ->
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
            keeper_waiting_item_text item,
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
    text "보존 관측 · 현재 결과 미확인 · Enter:Story 재조회 · "
      "retained observation · current result unknown · Enter:Story to reread · "
  in
  let observed turns =
    match List.rev turns with
    | [] -> text "조회된 턴 기록 없음" "no turn records in the reading"
    | (turn : Masc_tui_keeper_turns.turn) :: _ ->
        let ended = match Message_layout.age_text ~now ~since:turn.at with
          | Some age -> age ^ text " 전 종료 · " " ago ended · "
          | None -> text "종료 시각 미확인 · " "end time unknown · "
        in
        ended ^ (match turn.stop with
          | Masc_tui_keeper_turns.Stopped reason -> Terminal_text.single_line reason
          | Masc_tui_keeper_turns.No_stop_reason -> text "종료 사유 미기록" "stop reason not recorded")
  in
  match Masc_tui_fetched.view_for ~equal:String.equal state.keeper_story_turns ~key:keeper_name with
  | Masc_tui_fetched.Absent -> text "턴 종료 기록 미조회 · Enter:Story" "turn records not read · Enter:Story"
  | Masc_tui_fetched.Loading -> text "턴 종료 기록 조회 중" "reading turn records"
  | Masc_tui_fetched.Ready turns -> retained ^ observed turns
  | Masc_tui_fetched.Stale (turns, reason) ->
      retained ^ text "갱신 실패: " "refresh failed: " ^ Terminal_text.single_line reason
      ^ " · " ^ observed turns
  | Masc_tui_fetched.Failed reason ->
      text "턴 종료 기록 미확인: " "turn records unknown: " ^ Terminal_text.single_line reason

let keeper_plain_result (state : state) (row : Keeper_list_model.row) =
  let ko = state.ui_language = Lang_ko in
  let text ko en = ui_text state ~ko ~en in
  match row.keeper.Tui_decode.k_activity with
  | Some { k_last_proactive_outcome = Some outcome; _ } ->
      text "최근 자율 턴: " "last autonomous cycle: " ^ proactive_outcome_word ~ko outcome
  | Some { k_last_proactive_outcome = None; _ } | None ->
      text "최근 자율 턴 결과 미관측" "last autonomous cycle outcome not observed"

let keeper_plain_detail_lines (state : state) ~now ~width ~compact row =
  let text ko en = ui_text state ~ko ~en in
  let fit value = Message_layout.fit_width value width in
  match row with
  | None -> [ Theme.recede () ^ fit (text "선택한 Keeper 없음" "no Keeper selected") ^ Ansi.reset ]
  | Some (row : Keeper_list_model.row) ->
      let help = match keeper_plain_help state row with
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
              text "관측된 사람 대기 없음 · Approvals에서 확인"
                "no human wait in the reading · inspect Approvals"
            else text "도움 요청 상태 미확인 · Approvals에서 확인"
                "human waits unknown · inspect Approvals") ^ Ansi.reset
      in
      let current = keeper_plain_work state row in
      let result = keeper_plain_result state row in
      let name = Terminal_text.single_line row.keeper.Tui_decode.k_name in
      let routes =
        [ text "c:대화·원래 요청   →:상세   Enter:Story"
            "c:chat / original request   →:detail   Enter:Story"
        ; text "Enter→m:기억   J:일정   l:로그"
            "Enter→m:memory   J:schedules   l:logs"
        ]
      in
      let heading = Ansi.bold ^ fit name ^ Ansi.reset in
      if compact then
        let compact_result = match row.keeper.Tui_decode.k_activity with
          | Some { k_last_proactive_outcome = Some _; _ } -> result
          | Some { k_last_proactive_outcome = None; _ } | None ->
              keeper_plain_turn_record state ~now ~keeper_name:name
        in
        heading
        :: List.map fit
          ([ text "현재 일  " "work  " ^ current
           ; text "도움  " "help  " ^ help
           ; text "최근 결과  " "last result  " ^ compact_result
           ] @ routes)
      else
        let section title content =
          let lines = Message_layout.wrap_words ~max_cells:(max 1 (width - 2)) content in
          let lines = match lines with
            | first :: second :: _ :: _ ->
                [first; Message_layout.fit_width (second ^ " " ^ Message_layout.cut_mark) (max 1 (width - 2))]
            | _ -> lines
          in
          (Ansi.bold ^ fit title ^ Ansi.reset)
          :: List.map (fun line -> "  " ^ fit_width line (max 0 (width - 2))) lines
        in
        [heading; ""]
        @ section (text "지금 하는 일" "CURRENT WORK") current
        @ [""] @ section (text "사람의 도움" "HUMAN WAIT") help
        @ [""] @ section (text "최근 관측 결과" "OBSERVED RESULT")
            (result ^ " · " ^ keeper_plain_turn_record state ~now ~keeper_name:name)
        @ [""] @ List.map (fun line -> Theme.info () ^ fit line ^ Ansi.reset) routes

let keeper_pulse_headers (state : state) ~now ~inner ~(grid : Grid.t) ~selected_row all_rows =
  let selected = Option.map (fun row -> row.Keeper_list_model.keeper.Tui_decode.k_name) selected_row in
  let header = Masc_tui_keeper_strip.header ~now ~cells:inner
      ~view:state.keeper_list_view ~selected
      ~age:(fun row -> (Masc_tui_keeper_axis.outside state ~now
          ~keeper_name:row.Keeper_list_model.keeper.Tui_decode.k_name).age) all_rows in
  header :: (match state.keeper_list_view with
  | Keeper_list_model.By_age -> []
  | Keeper_list_model.(Plain | By_state | By_cause | By_time | By_memory | By_runtime | Day_wall) ->
      (match Masc_tui_keeper_strip.fleet_cells ~ko:(state.ui_language = Lang_ko) ~now ~grid
          ~wakes:(fun row -> Masc_tui_keeper_axis.wake_strip state ~now
            ~ahead:grid.side_cells ~keeper_name:row.Keeper_list_model.keeper.Tui_decode.k_name) all_rows with
       | None -> []
       | Some fleet ->
           [(grid_line grid
             { gutter = String.make Grid.gutter_cells ' '; name = fit_width fleet.name grid.name_cells
             ; pulse = fleet.pulse; now_cell = still_row grid_blank_now; strip = fleet.strip
             ; due = fit_width fleet.due Grid.due_cells; right = String.make grid.mem_cells ' ' }).text]))

let keeper_selected_summary (state : state) ~now (row : Keeper_list_model.row) =
  let keeper_name = row.keeper.Tui_decode.k_name in
  let now_cell = keeper_now_cell ~ko:(state.ui_language = Lang_ko)
      ~padded:false ~frame:state.activity_frame row in
  let text = Masc_tui_keeper_strip.selected_summary ~now
    ~activity_cell:now_cell.text
    ~next_run:(match state.schedules_agenda_error with
      | Some _ -> Masc_tui_keeper_next_run.Unknown
      | None -> Masc_tui_keeper_axis.next_run state ~keeper_name)
    ~recurrence:(Masc_tui_keeper_axis.next_recurrence state ~keeper_name)
    ~memory:(keeper_memory_reading state row) row in
  { text; motion = shift_motion
      ~prefix:(Terminal_text.single_line keeper_name ^ " ") now_cell.motion }

let draw_keeper_selected_summary buf ~cols summary =
  (match summary.motion with
   | Masc_tui_answering.Still -> ()
   | Moving through_cell -> Render_schedule.Activity_tick.note_motion_if_visible
       ~text:summary.text ~width:(framed_inner_width cols) ~through_cell);
  box_line buf cols summary.text

let keeper_plain_fleet_lines (state : state) ~now ~inner =
  let text ko en = ui_text state ~ko ~en in
  let warning value = Theme.warn () ^ "  " ^ value ^ Ansi.reset in
  match fleet_stream_view state with
  | Masc_tui_fleet_stream.Awaiting_first_reading ->
      [Theme.recede () ^ text "  운영 상태 미조회" "  fleet status not read" ^ Ansi.reset]
  | Masc_tui_fleet_stream.Unreachable { since } ->
      [warning (Masc_tui_fleet_line.unreachable_text ~now ~since)]
  | Masc_tui_fleet_stream.Cannot_read failure ->
      [warning (Masc_tui_fleet_line.failure_text failure)]
  | Masc_tui_fleet_stream.Unavailable { degradation; disconnected_since } ->
      [warning (Masc_tui_fleet_line.unavailable_text ~now ~degradation ~disconnected_since)]
  | Masc_tui_fleet_stream.Reading { reading = { fleet; _ }; trouble } ->
      let lead = (match trouble with
        | None -> text "운영 관측: " "fleet observation: "
        | Some (Masc_tui_fleet_stream.Scans_failing _ | Masc_tui_fleet_stream.Disconnected _) ->
            text "마지막 운영 관측: " "last fleet observation: ")
        ^ Masc_tui_fleet_line.status_text fleet.fs_status
      in
      let clauses = lead :: Option.to_list (Masc_tui_fleet_line.blocker_text fleet)
        @ [text
             (Printf.sprintf "실행 %d/%d" fleet.fs_running_count fleet.fs_bootable_count)
             (Printf.sprintf "running %d/%d" fleet.fs_running_count fleet.fs_bootable_count)
           ; Masc_tui_fleet_line.proactive_text fleet ]
      in
      let tone = match trouble with
        | Some _ -> Theme.warn ()
        | None -> if fleet.fs_operator_action_required then Theme.bad ()
            else if Masc_tui_fleet_line.status_is_ok fleet.fs_status then Theme.ok ()
            else Theme.warn ()
      in
      [tone ^ "  " ^ Message_layout.join_fitting ~sep:" · " ~cells:(max 0 (inner - 2)) clauses ^ Ansi.reset]
      @ Option.to_list (Option.map
          (fun trouble -> warning (Masc_tui_fleet_line.trouble_text ~now trouble)) trouble)

let keeper_observation_errors (state : state) =
  let text korean english = if state.ui_language = Lang_ko then korean else english in
  List.filter_map Fun.id
    [ Option.map (fun e -> (text "목록" "roster metadata", e)) state.keepers_error
    ; Option.map (fun e -> (text "실행 관측" "live roster", e)) state.keeper_roster_error
    ; Option.map (fun e -> (text "턴 관측" "turn observation", e)) state.keeper_turns_error
    ; Option.map (fun e -> (text "대기 목록" "waiting inventory", e)) state.keeper_waiting_error
    ; Option.map (fun e -> (text "별도 실행" "async observation", e)) state.tools_async_observation_error
    ; Option.map (fun e -> (text "승인 요청" "approval reading", e)) state.keeper_tool_approvals_error
    ; Option.map (fun e -> (text "질문" "questions", e)) state.asks_error
    ]

let keeper_observation_reading (state : state) =
  match keeper_observation_errors state with
  | [] -> None
  | errors ->
      let ko = state.ui_language = Lang_ko in
      Some (Masc_tui_detail_reading.create ~ko
        ~title:(if ko then "Keepers 관측 오류" else "Keeper observation errors")
        (List.map (fun (heading, body) ->
          ({heading; body} : Masc_tui_detail_reading.section)) errors))

(* The selected row among the rows the list draws, counted from one. A group
   heading or the World row selects no Keeper. *)
let keeper_list_position ~stop rows : Masc_tui_value.Position.t option =
  match rows with
  | [] -> None
  | _ :: _ ->
      let at =
        match stop with
        | Some (Keeper_list_model.Stop_row position) -> position + 1
        | Some (Keeper_list_model.Stop_world | Keeper_list_model.Stop_heading _)
        | None -> 0
      in
      Some (Row { at; total = List.length rows })

let keeper_plain_headers (state : state) ~now ~cols ~inner ~selected_reading ~pulse_headers =
  let text ko en = ui_text state ~ko ~en in
  let warning prefix reason = Theme.warn () ^ "  " ^ prefix ^ Terminal_text.single_line reason ^ Ansi.reset in
  (* One failing read at most names itself with its reason; several at once
     fold into a single summary line. Either way the header grows by one line
     instead of one per failure, so a burst of read errors cannot shove the
     whole list up and down. *)
  let errors =
    let cells = max 0 (inner - 2) in
    match keeper_observation_errors state with
    | [] -> []
    | [ (label, reason) ] ->
      [ warning "" (Message_layout.fit_width
          ("! " ^ label ^ ": " ^ Terminal_text.single_line reason) cells) ]
    | many ->
      let prefix =
        if state.ui_language = Lang_ko then Printf.sprintf "! 원문 · 오류 %d종: " (List.length many)
        else Printf.sprintf "! details · %d errors: " (List.length many) in
      let labels = String.concat " · " (List.map fst many) in
      [ warning "" (Message_layout.fit_width (prefix ^ labels) cells) ]
  in
  let roster = match Keeper_control.roster_view state.keeper_roster with
    | Keeper_control.Roster_partial { observed; total } ->
        [warning "" (text
           (Printf.sprintf "실행 관측 %d/%d · 나머지는 미확인" (List.length observed) total)
           (Printf.sprintf "live reading %d/%d · the rest unknown" (List.length observed) total))]
    | Keeper_control.Roster_invalid { errors; _ } ->
        [warning "" (text
           (Printf.sprintf "설정 읽기 오류 %d개 · 상세에서 확인" (List.length errors))
           (Printf.sprintf "%d configuration read errors · inspect detail" (List.length errors)))]
        @ (match selected_reading with
          | Some { Keeper_control.liveness = Keeper_control.Invalid detail; _ } -> [warning "" detail]
          | Some { Keeper_control.liveness = (Keeper_control.Unobserved | Keeper_control.Absent | Keeper_control.Present _); _ }
          | None -> [])
    | Keeper_control.Roster_unobserved ->
        [Theme.recede () ^ text "  실행 상태 미조회 · 저장된 목록을 표시합니다"
           "  live status not read · showing stored roster" ^ Ansi.reset]
    | Keeper_control.Roster_complete _ -> []
  in
  let waiting = match state.keeper_waiting_failure with
    | Some (Tui_decode.Keeper_waiting_invalid reason) -> [warning (text "대기 관측 미확인: " "waiting unknown: ") reason]
    | Some (Tui_decode.Keeper_waiting_sources_unavailable _) ->
        [warning "" (text "대기 원본을 읽지 못했습니다 · 대기 목록이 업무 차단을 뜻하지는 않습니다"
                       "waiting sources unavailable · inventory is not a work blocker")]
    | None ->
        (match keeper_waiting_refresh_slow state with
         | Some age ->
             let elapsed = Printf.sprintf "%.1f" (Int64.to_float age /. 1e9) in
             [warning "" (text
                ("대기 목록 갱신 중 · 마지막 관측을 표시합니다 · " ^ elapsed ^ "초")
                ("waiting refresh pending · showing last observation · " ^ elapsed ^ "s"))]
         | None -> [])
  in
  [ here_row ~cols state
      ~path:[ text "일과 도움" "work and help" ]
      ~readings:
        (if errors <> [] || roster <> [] || waiting <> [] then
           [ Theme.warn () ^ text "일부 관측 미확인" "some observations unknown" ^ Ansi.reset ]
         else [])
      ~position:
        (keeper_list_position ~stop:(keeper_list_stop state)
           (keeper_list_reading state).klr_rows) ]
  @ keeper_plain_fleet_lines state ~now ~inner
  @ errors @ roster @ waiting
  @ [keeper_view_tabs ~cols state.keeper_list_view]
  @ pulse_headers
  @ Option.to_list (Option.map (warning (text "보기 설정: " "view preferences: ")) state.keeper_list_preference_notice)
  @ Option.to_list (local_source_pending_note state Local_keepers)

type keeper_plain_projection =
  { kpp_headers : string list
  ; kpp_list_width : int
  ; kpp_detail_width : int option
  ; kpp_detail_lines : string list
  ; kpp_list_rows : int
  ; kpp_entry_rows : int
  ; kpp_window : keeper_display_entry list
  ; kpp_scroll : int
  ; kpp_overflow : bool
  ; kpp_count : int
  ; kpp_density : Keeper_list_model.density
  ; kpp_selected_reading : Keeper_control.reading option
  ; kpp_selected_summary : keeper_primary_row option
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
    | None, Some row when rows - 1 - 2 > list_floor -> Some (keeper_selected_summary state ~now row)
    | (Some _ | None), (Some _ | None) -> None in
  let summary_rows = match selected_summary with Some _ -> 1 | None -> 0 in
  let pulse_headers = keeper_pulse_headers state ~now ~inner ~grid:(Grid.layout ~cols:inner)
      ~selected_row reading.klr_all_rows in
  let headers = keeper_plain_headers state ~now ~cols ~inner ~selected_reading ~pulse_headers in
  (* A long list of failed reads must not evict the selectable Keeper or the
     action footer. Keep a useful list and its selected summary first; source
     errors and Pulse headers then take rows before optional card detail and
     preference metadata. The title still qualifies retained readings. *)
  let body_floor = min (list_floor + summary_rows) (max 1 (rows - 1 - 2 - 1)) in
  let header_budget = max 0 (rows - 1 - 2 - body_floor) in
  let headers =
    if List.length headers <= header_budget then headers
    else match List.take header_budget headers with
      | [] -> []
      | kept ->
          let last = List.length kept - 1 in
          List.mapi (fun index row ->
            if index <> last then row else row ^ Theme.recede ()
              ^ ui_text state
                  ~ko:(Printf.sprintf " · 보기 %d행 생략" (List.length headers - header_budget))
                  ~en:(Printf.sprintf " · %d header rows omitted" (List.length headers - header_budget))
              ^ Ansi.reset) kept
  in
  (* The initial blank and the divider/footer have the same ownership as the
     axis renderer. Both keyboard paging and drawing use this allocation. *)
  let body_rows = max 0 (rows - 1 - List.length headers - 2 - summary_rows) in
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
  let primary_entry_height = List.fold_left max 1 heights in
  let overflowing = content_rows > primary_entry_height
    && List.fold_left ( + ) 0 heights > content_rows in
  let entry_rows = max 0 (content_rows - if overflowing then 1 else 0) in
  let cursor = Option.value ~default:0 (List.find_index (keeper_entry_selected stop) entries) in
  let scroll, count = Masc_tui_scroll.window_of_heights ~heights ~cursor ~rows:entry_rows state.keeper_list_scroll in
  { kpp_headers = headers; kpp_list_width = list_width; kpp_detail_width = detail_width
  ; kpp_detail_lines = detail_lines; kpp_list_rows = list_rows; kpp_entry_rows = entry_rows
  ; kpp_window = List.take count (List.drop scroll entries); kpp_scroll = scroll
  ; kpp_overflow = overflowing; kpp_count = List.length reading.klr_rows
  ; kpp_density = density
  ; kpp_selected_reading = selected_reading; kpp_selected_summary = selected_summary }

let keeper_plain_page_rows state ~terminal_rows ~cols =
  match state.keeper_list_view, state.keeper_story with
  | Keeper_list_model.Plain, None ->
      let projection = keeper_plain_projection state ~terminal_rows ~cols ~now:(Unix.gettimeofday ()) in
      Some (max 1 (List.length projection.kpp_window))
  | (Keeper_list_model.Plain | Keeper_list_model.By_state | Keeper_list_model.By_cause
    | Keeper_list_model.By_time | Keeper_list_model.By_memory | Keeper_list_model.By_age
    | Keeper_list_model.By_runtime | Keeper_list_model.Day_wall), Some _
  | (Keeper_list_model.By_state | Keeper_list_model.By_cause | Keeper_list_model.By_time
    | Keeper_list_model.By_memory | Keeper_list_model.By_age | Keeper_list_model.By_runtime
    | Keeper_list_model.Day_wall), None -> None

let keeper_plain_list_lines (state : state) ~now:_ projection =
  let width = projection.kpp_list_width in
  let text ko en = ui_text state ~ko ~en in
  let stop = keeper_list_stop state in
  let entry_lines = function
    | Keeper_world -> []
    | Keeper_group_heading (group, count) as entry ->
        let heading =
          (if List.mem group state.keeper_list_folded then Keeper_mark.grid_folded_mark
           else Keeper_mark.grid_open_mark) ^ " "
          ^ keeper_group_heading_text ~available_cells:(width - 2) (keeper_list_rows state) group count in
        [if keeper_entry_selected stop entry then Ansi.reverse ^ fit_width heading width ^ Ansi.reset else heading]
    | Keeper_display_row (_, row) as entry ->
        let selected = keeper_entry_selected stop entry in
        let name_width = max 1 (width - Render_schedule.keeper_marker_width - Render_schedule.keeper_status_width - 1) in
        let yolo = List.mem row.Keeper_list_model.keeper.Tui_decode.k_name state.keeper_yolo_names in
        let prefix = keeper_row_marker ~selected
          ^ keeper_row_name ~width:name_width ~yolo row ^ " " in
        let now_cell = keeper_now_cell ~ko:(state.ui_language = Lang_ko)
            ~frame:state.activity_frame row in
        let primary = prefix ^ now_cell.text in
        (match shift_motion ~prefix now_cell.motion with
         | Masc_tui_answering.Still -> ()
         | Moving through_cell ->
             if projection.kpp_list_rows > 0 then
               Render_schedule.Activity_tick.note_motion_if_visible
                 ~text:primary ~width ~through_cell);
        let emit value =
          let value = fit_width value width in
          let value = if selected then Ansi.reverse ^ Masc_tui_theme.strip_sgr value ^ Ansi.reset else value in
          pressable (Press_keeper_row row.keeper.Tui_decode.k_name) value
        in
        let primary = emit primary in
        match projection.kpp_density with
        | Keeper_list_model.One_line -> [primary]
        | Keeper_list_model.Two_lines ->
            let detail = match keeper_plain_help state row with
              | Some request -> Theme.warn () ^ request ^ Ansi.reset
              | None -> keeper_plain_work state row
            in
            [primary; emit ("   " ^ Message_layout.fit_width detail (max 0 (width - 3)))]
  in
  let content = List.concat_map entry_lines projection.kpp_window in
  let content = if content <> [] || projection.kpp_entry_rows = 0 then content else
    [Theme.recede () ^ (if projection.kpp_count > 0 then text "창이 좁아 행을 표시할 수 없습니다" "window too short for a row"
       else match keeper_rows_page state ~error:(Terminal_text.optional_single_line state.keepers_error) with
         | Page_empty -> text "조회된 Keeper 목록이 비어 있습니다" "the Keeper roster reading is empty"
         | Page_unread -> text "Keeper 목록 미조회" "Keeper roster not read"
         | Page_failed -> text "Keeper 목록 읽기 실패" "Keeper roster read failed") ^ Ansi.reset]
  in
  if projection.kpp_list_rows = 0 then [] else
    (if projection.kpp_list_rows > 1 then
      [Theme.recede () ^ fit_width (text "Keeper 목록 · 현재 상태 / 일과 대기" "KEEPERS · current status / work and wait") width ^ Ansi.reset]
     else [])
    @ content
    @ List.init (max 0 (projection.kpp_entry_rows - List.length content)) (fun _ -> "")
    @ if projection.kpp_overflow then
        [Theme.recede () ^ Printf.sprintf "  %d–%d / %d · j/k · PgUp/PgDn"
           (if projection.kpp_window = [] then 0 else projection.kpp_scroll + 1)
           (projection.kpp_scroll + List.length projection.kpp_window) projection.kpp_count ^ Ansi.reset]
      else []

let render_keeper_plain (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.gettimeofday () in
  let projection = keeper_plain_projection state ~terminal_rows ~cols ~now in
  let buf = Buffer.create 4096 in
  Buffer.add_char buf '\n';
  List.iter (box_line buf cols) projection.kpp_headers;
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
       ~hints:(keeper_control_hints ~offers_back:false state projection.kpp_selected_reading));
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

  Buffer.add_char buf '\n';

  (* One observation time for stale fleet readings and roster turn ages. *)
  let now_unix = Unix.gettimeofday () in
  let grid = Grid.layout ~cols:inner in
  (* The roster is the surface an operator watches to see which keepers are
     up. Whether the reading is live is the top row's word; a list that could
     not be read says so here, and the position counts the rows drawn. *)
  let heading =
    here_row ~cols state ~path:[]
      ~readings:
        (match state.keepers, keeper_rows_page state ~error:keepers_error with
         | _ :: _, _ | [], Page_empty -> []
         | [], (Page_unread | Page_failed) ->
             [ String.trim (title_missing_reading ~error:keepers_error) ])
      ~position:(keeper_list_position ~stop model_rows)
  in
  box_line buf cols heading;
  box_line buf cols (keeper_view_tabs ~cols state.keeper_list_view);
  List.iter (box_line buf cols)
    (keeper_pulse_headers state ~now:now_unix ~inner ~grid ~selected_row all_rows);
  Option.iter
    (fun message -> box_line buf cols
      (Theme.warn () ^ "  preferences: " ^ Terminal_text.single_line message ^ Ansi.reset))
    state.keeper_list_preference_notice;

  (match fleet_stream_view state with
   | Masc_tui_fleet_stream.Awaiting_first_reading -> ()
   | Masc_tui_fleet_stream.Unreachable { since } ->
       box_line buf cols
         ((Theme.warn ()) ^ "  fleet: "
          ^ Masc_tui_fleet_line.unreachable_text ~now:now_unix ~since
          ^ Ansi.reset)
   | Masc_tui_fleet_stream.Cannot_read failure ->
       box_line buf cols
         ((Theme.bad ()) ^ "  fleet: " ^ Masc_tui_fleet_line.failure_text failure
          ^ Ansi.reset)
   | Masc_tui_fleet_stream.Unavailable { degradation; disconnected_since } ->
       box_line buf cols
         ((Theme.warn ()) ^ "  fleet: "
          ^ Masc_tui_fleet_line.unavailable_text ~now:now_unix ~degradation ~disconnected_since
          ^ Ansi.reset)
   | Masc_tui_fleet_stream.Reading { reading = { fleet; _ }; trouble } ->
       let tone, lead =
         let status = Masc_tui_fleet_line.status_text fleet.fs_status in
         match trouble with
         | None ->
             let tone =
               if fleet.fs_operator_action_required then Theme.bad ()
               else if Masc_tui_fleet_line.status_is_ok fleet.fs_status then Theme.ok ()
               else Theme.warn ()
             in
             tone, Printf.sprintf "  fleet %s" status
         | Some
             (Masc_tui_fleet_stream.Scans_failing _
             | Masc_tui_fleet_stream.Disconnected _) ->
             (* The grade, counts and blocker below all belong to the retained
                reading. Qualify that same row before any stale zero or blocker
                can be read as the fleet's current state. *)
             Theme.warn (), Printf.sprintf "  fleet last observed: %s" status
       in
       let running =
         Printf.sprintf "running %d/%d" fleet.fs_running_count
           fleet.fs_bootable_count
       in
       let turn_capacity =
         Printf.sprintf "turn capacity %d/%d"
           (fleet.fs_target_reaction_capacity
           - fleet.fs_reaction_capacity_shortfall)
           fleet.fs_target_reaction_capacity
       in
       (* [select] keeps a prefix, so the last reading is the first a narrow
          screen drops. The proactive interval goes last: it is a setting the
          operator chose, the same on every scan, while the counts and the
          blocker are what changed and what needs an answer. *)
       let readings =
         [ Masc_tui_fleet_summary.Running, running
         ; Masc_tui_fleet_summary.Turn_capacity, turn_capacity
         ]
         @ (match Masc_tui_fleet_line.blocker_text fleet with
           | None -> []
           | Some text -> [ Masc_tui_fleet_summary.Blocker, text ])
         @ [ ( Masc_tui_fleet_summary.Proactive_interval
             , Masc_tui_fleet_line.proactive_text fleet ) ]
       in
       let separator = "   " in
       let selected =
         readings
         |> List.map (fun (reading, text) ->
                (reading, Message_layout.display_width text))
         |> Masc_tui_fleet_summary.select ~cells:inner
              ~lead_cells:(Message_layout.display_width lead)
              ~separator_cells:(Message_layout.display_width separator)
       in
       let joined =
         match selected with
         | [] -> ""
         | _ ->
             separator
             ^ String.concat separator
                 (List.map (fun reading -> List.assoc reading readings) selected)
       in
       box_line buf cols
         (Printf.sprintf "%s%s%s%s%s" tone lead Ansi.reset joined Ansi.reset);
       (* Its own row under the fleet line rather than a tail on it: the
          frame cuts a row from the right, and the counts are what a narrow
          screen keeps. *)
       Option.iter
         (fun trouble ->
            box_line buf cols
              ((Theme.warn ()) ^ "  fleet reading: "
               ^ Masc_tui_fleet_line.trouble_text ~now:now_unix trouble ^ Ansi.reset))
         trouble;
       let failing_entry =
         Option.to_list (Masc_tui_fleet_line.failing_text fleet)
       in
       let entry label n =
         if n > 0 then [ Printf.sprintf "%s %d" label n ] else []
       in
       (* The owner count keeps its place in the row and brings its own
          shortfall, which is the only reading that says the scan came up
          short: an unread Keeper does not move the fleet status. *)
       let counts =
         failing_entry
         @ entry "paused" fleet.fs_paused_count
         @ Option.to_list (Masc_tui_fleet_line.owner_scan_text fleet)
         @ entry "awaiting verdict" fleet.fs_completion_authority_pending_count
       in
       if counts <> [] then
         box_line buf cols
           (Ansi.dim ^ "  " ^ String.concat "   " counts ^ Ansi.reset);
       List.iter
         (fun (color, label, names) ->
            box_line buf cols
              (Printf.sprintf "%s  %s: %s%s" color label
                 (Terminal_text.single_line names) Ansi.reset))
         (keeper_fleet_gap_lines fleet));

  (* The roster's own failure. The rows below still come from disk so they stay
     on screen; this says the live half of every one of them is missing, which
     does not prevent confirmed deletion through the authoritative server. *)
  (match state.keeper_roster_error with
   | Some err ->
       box_line buf cols
         ((Theme.warn ()) ^ "  " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match Keeper_control.roster_view state.keeper_roster with
   | Keeper_control.Roster_invalid { errors; _ } ->
       box_line buf cols
         (Printf.sprintf "%s  configuration errors: %d; select a keeper for details%s"
            (Theme.warn ()) (List.length errors) Ansi.reset);
       (match selected_reading with
        | Some { Keeper_control.name; liveness = Keeper_control.Invalid detail; _ } ->
            box_line buf cols ((Theme.warn ()) ^ "  "
              ^ Terminal_text.single_line (name ^ ": " ^ detail) ^ Ansi.reset)
        | Some
            { Keeper_control.liveness =
                ( Keeper_control.Unobserved | Keeper_control.Absent
                | Keeper_control.Present _ )
            ; _
            }
        | None -> ())
   | Keeper_control.Roster_partial { observed; total } ->
       box_line buf cols
         (Printf.sprintf
            "%s  live status covers %d of %s; the rest read as unknown%s"
            (Theme.warn ()) (List.length observed) (Masc_tui_message_layout.count_noun total "keeper") Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  (* Measured over every reading rather than the rows on screen, so the
     columns do not move while a reader scrolls. *)
  let failure_sentence_cells (row : Keeper_list_model.row) =
    let age ended_at =
      Option.map (fun _ -> widest_age_text) (keeper_trail_age ~now:now_unix ended_at)
    in
    match keeper_row_trail_sentence ~age row with
    | Some sentence -> Message_layout.display_width sentence
    | None -> 0
  in
  let has_failing_keeper =
    List.exists (fun row -> failure_sentence_cells row > 0) model_rows
  in
  let widest_detail =
    List.fold_left
      (fun widest (row : Keeper_list_model.row) ->
        let failure_width = failure_sentence_cells row in
        let next_width =
          match keeper_next_text ~now:now_unix row with
          | None -> 0
          | Some text ->
            let task_w =
              match keeper_task_detail row with
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
  let shape = Axis_row.shape_of_view state.keeper_list_view in
  let matrix = match state.keeper_list_view with
    | Keeper_list_model.By_runtime -> Some (runtime_matrix ~inner model_rows)
    | Keeper_list_model.(Plain | By_state | By_cause | By_time | By_memory | By_age | Day_wall) -> None in
  let peak_lag = axis_peak_lag state model_rows in
  let peak_facts = axis_peak_facts state model_rows in
  box_line buf cols "";
  (match matrix, shape with
   | Some matrix, (Axis_row.List_columns | Axis_row.Wall_columns | Axis_row.Grid _) ->
       box_line_styled buf cols ~style:(Theme.recede ()) (matrix_header matrix)
   | None, Axis_row.Wall_columns ->
       box_line buf cols (Masc_tui_keeper_wall.header ~cols:inner ~now:now_unix);
       box_line buf cols (Masc_tui_keeper_wall.fleet ~ko:(state.ui_language = Lang_ko)
         ~cols:inner ~now:now_unix (List.map keeper_row_runtime model_rows))
   | None, Axis_row.List_columns ->
       box_line_styled buf cols ~style:(Theme.recede ()) (keeper_column_header columns)
   | None, Axis_row.Grid grid_columns -> box_line buf cols (grid_header state grid grid_columns));

  (match keepers_error with
   | Some err -> box_line buf cols ((Theme.bad ()) ^ "  " ^ err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_turns_error with
   | Some err ->
       box_line buf cols
         (Theme.warn () ^ "  turn/waiting observation: "
          ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_waiting_error with
   | Some err ->
       box_line buf cols
         (Theme.warn () ^ "  waiting refresh failed: " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None ->
       (match keeper_waiting_refresh_slow state with
        | Some age ->
            let detail = if Keeper_waiting_read.in_flight state.keeper_waiting_read
              then "refreshing" else "refresh pending" in
            let elapsed = Printf.sprintf "%.1f" (Int64.to_float age /. 1e9) in
            box_line buf cols
              (Theme.warn () ^ "  waiting inventory: " ^ detail ^ " · " ^ elapsed ^ "s" ^ Ansi.reset)
        | None -> ()));
  (match state.keeper_waiting_failure with
   | None -> ()
   | Some failure ->
       let detail =
         match failure with
         | Tui_decode.Keeper_waiting_sources_unavailable errors ->
             errors
             |> List.map (fun item ->
               let detail =
                 if item.Tui_decode.kwi_source = Tui_decode.Waiting_source_observation_unavailable
                 then item.kwi_what else item.kwi_waiting_on in
               Terminal_text.single_line detail)
             |> String.concat ", "
         | Tui_decode.Keeper_waiting_invalid detail -> Terminal_text.single_line detail
       in
       box_line buf cols
         (Theme.warn () ^ "  fleet waiting observation unavailable: " ^ detail ^ Ansi.reset));
  (match state.tools_async_observation_error with
   | Some err ->
       box_line buf cols
         (Theme.warn () ^ "  async observation: "
          ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());

  Option.iter (fun note -> box_line buf cols note)
    (local_source_pending_note state Local_keepers);

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
    | Some matrix -> List.take (max 0 (content_rows - 2)) (matrix_legend ~inner matrix) in
  let content_rows = max 0 (content_rows - List.length legend) in
  Option.iter
    (fun (name, portrait) ->
      box_line buf cols
        (Theme.recede () ^ "  selected · " ^ Terminal_text.single_line name ^ Ansi.reset);
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
  let total_entry_lines = List.fold_left ( + ) 0 heights in
  let overflowing = content_rows > 0 && total_entry_lines > content_rows in
  let entry_rows = if overflowing then max 0 (content_rows - 1) else content_rows in
  let selected_entry =
    Option.value ~default:0 (List.find_index (keeper_entry_selected stop) entries)
  in
  let scroll_offset, window_entries =
    Masc_tui_scroll.window_of_heights ~heights ~cursor:selected_entry ~rows:entry_rows
      state.keeper_list_scroll
  in
  let entries_window = List.take window_entries (List.drop scroll_offset entries) in
  (* Strip visual SGR before adding pressable marks: those marks also end in
     [m] and must reach the frame presenter. *)
  let selected_line text =
    box_line_styled buf cols ~style:(Theme.sidebar_selection ()) text in
  List.iter
    (function
      | Keeper_world as entry ->
          let world = Masc_tui_keeper_world.row_cells ~view:state.keeper_list_view
              ~health_error:state.memory_health_error state.memory_health
              (Masc_tui_memory_world.reading state.memory_world) in
          let text = (grid_line grid
            { gutter = Theme.info () ^ "▌ ■ " ^ Ansi.reset
            ; name = fit_width "world · shared" grid.name_cells
            ; pulse = (match world.pulse with
                | Masc_tui_keeper_world.Ledger_and_briefing ->
                    fit_width "ledger + briefing" grid.side_cells
                | Masc_tui_keeper_world.Fact_ages bins -> grid_age_ladder_reading grid bins)
            ; now_cell = still_row (fit_width world.now_cell Grid.now_cells)
            ; strip = fit_width world.strip (Grid.strip_cells grid)
            ; due = fit_width world.due Grid.due_cells
            ; right = Message_layout.pad_left world.right grid.mem_cells }).text in
          let text = pressable Press_keeper_world (fit_width text inner) in
          if keeper_entry_selected stop entry then
            selected_line (Masc_tui_theme.strip_sgr text)
          else box_line buf cols text
      | Keeper_group_heading (group, count) as entry ->
          let text =
            let title = keeper_group_heading_text ~available_cells:inner model_rows group count in
            match matrix with
            | Some _ -> keeper_group_heading_style group ^ "▌   " ^ title ^ Ansi.reset
            | None ->
                let members = keeper_group_rows list_reading group in
                grid_group_title state grid ~now:now_unix ~group ~members
                  ~folded:(List.mem group state.keeper_list_folded)
                  ~style:(keeper_group_heading_style group)
                  ~pulse:(grid_group_pulse state grid list_reading group) title
          in
          if keeper_entry_selected stop entry then
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
                still_row (matrix_keeper_row matrix ~now:now_unix row)
            | None, Axis_row.Wall_columns ->
                still_row (Masc_tui_keeper_wall.row ~ko:(state.ui_language = Lang_ko)
                  ~cols:inner ~now:now_unix
                  ~name:row.Keeper_list_model.keeper.Tui_decode.k_name (keeper_row_runtime row))
            | None, Axis_row.List_columns ->
                keeper_row_content ~columns ~now:now_unix ~frame:state.activity_frame ~yolo
                  ~selected row
            | None, Axis_row.Grid grid_columns ->
                grid_keeper_row state grid grid_columns ~view:state.keeper_list_view ~peak_lag
                  ~peak_facts ~now:now_unix ~frame:state.activity_frame ~yolo row
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
          (match primary.motion with
           | Masc_tui_answering.Still -> ()
           | Moving through_cell -> Render_schedule.Activity_tick.note_motion_if_visible
               ~text:primary.text ~width:inner ~through_cell);
          emit primary.text;
          (* Only a row that draws a second line builds one. *)
          (match second_line row with
           | Axis_row.No_second_line -> ()
           | Axis_row.List_detail ->
               let cells =
                 Masc_tui_keeper_axis.segments state ~now:now_unix
                   ~keeper_name:row.Keeper_list_model.keeper.Tui_decode.k_name
                   ~runtime:(keeper_row_runtime row)
               in
               emit (keeper_secondary_row_content ~now:now_unix ~inner ~cells row)
           | Axis_row.Failure_chain -> emit (grid_failure_line grid ~now:now_unix row)))
    entries_window;

  let note =
    if keeper_count > 0 then None
    else
      match keeper_rows_page state ~error:keepers_error with
      | Page_empty when Option.is_some matrix -> Some "   no failing Keepers"
      | Page_empty -> Some (match state.workspace_identity with
          | Workspace_identity_mismatch _ -> "   server Keeper roster is empty"
          | Workspace_identity_match | Workspace_identity_match_unconfirmed _
          | Workspace_identity_unread ->
            "   no keeper metadata under .masc/keepers/")
      | Page_unread -> Some page_unread_note
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

  if overflowing then begin
    (* Positions rather than a count of the rows drawn above, since a
       folded group above the window draws none of its rows. *)
    let positions =
      List.filter_map
        (function
          | Keeper_display_row (position, _) -> Some position
          | Keeper_world | Keeper_group_heading _ -> None)
        entries_window
    in
    let range =
      match positions with
      | [] -> "0/" ^ string_of_int keeper_count
      | first :: rest ->
          Printf.sprintf "%d–%d/%d" (first + 1) (List.fold_left max first rest + 1) keeper_count
    in
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [keepers %s]" range)
  end;

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
       ~hints:(keeper_control_hints ~offers_back:false state selected_reading));

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
  let dim line = Ansi.dim ^ line ^ Ansi.reset in
  match keeper_composite_of state ~keeper_name:k.k_name with
  | None | Some { kcr_secret = None; _ } -> None
  | Some { kcr_secret = Some p; _ } ->
      let status = Masc.Tui_decode.keeper_secret_status_to_string p.ksp_status in
      let status_line =
        match p.ksp_status with
        | Masc.Tui_decode.Secret_ready ->
            "  Status:  " ^ (Theme.ok ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_error ->
            "  Status:  " ^ (Theme.bad ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_empty | Masc.Tui_decode.Secret_absent
        | Masc.Tui_decode.Secret_status_unknown _ ->
            "  Status:  " ^ Ansi.dim ^ status ^ Ansi.reset
      in
      let entry_lines label = function
        | [] -> [ dim (Printf.sprintf "  %s  -" label) ]
        | names ->
            List.mapi
              (fun index name ->
                let lead = if index = 0 then label else String.make (String.length label) ' ' in
                Printf.sprintf "  %s  %s" lead (Terminal_text.single_line name))
              names
      in
      detail_section_lines ~first:true "1. 시크릿 상태 · 루트 경로 (Status & Root)"
      @ [ status_line
        ; Printf.sprintf "  Root:    %s" (Terminal_text.single_line p.ksp_root)
        ]
      @ detail_section_lines "2. 환경변수 · 시크릿 파일 (Env & Files)"
      @ entry_lines "Env: " p.ksp_env_names
      @ (match p.ksp_file_paths with
         | [] -> []
         | paths -> "" :: entry_lines "Files:" paths)
      @ (match p.ksp_error with
         | None -> []
         | Some detail ->
             [ ""; (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ])
      @ [ ""
        ; dim
            (if p.ksp_values_validated then
               "  Values were read and validated. They are never sent here."
             else "  Values were not validated on the last read.")
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
    | Keeper_execute_none -> note "No Execute output observed in this server process."
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
                  | Gate_observation -> "gate observation " in
                (match outcome with
                 | Execute_terminal.Result_unknown -> Theme.warn (), what ^ "result unknown"
                 | Request_not_sent -> Theme.warn (), what ^ "request not sent"
                 | Observation_ended -> Theme.recede (), what ^ "ended")
            | Rejected { why; reason } ->
                Theme.bad (),
                "rejected: " ^ why ^ (match reason with Some r -> " (" ^ r ^ ")" | None -> "")
            | Unrecognized text -> Theme.recede (), "status " ^ text in
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
           note (Printf.sprintf "Earlier output is no longer kept (before sequence %d)."
                   snapshot.kes_first_seq)
         else [])
        @ (if snapshot.kes_lines_omitted > 0 then
             note (Printf.sprintf "%d older rows are not in this view." snapshot.kes_lines_omitted)
           else [])
        @ List.concat_map (fun (stream : keeper_execute_stream) ->
            note ("running: " ^ stream.kes_command)) running
        @ List.concat_map drawn rows in
  let rows = match observation with
    | Masc_tui_fetched.Absent -> note "Execute output has not been read."
    | Loading -> note "Reading Execute output\xe2\x80\xa6"
    | Failed detail ->
        wrapped (Theme.bad () ^ sanitize
          ("Execute output unavailable: " ^ keeper_execute_failure_detail detail))
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
    | Execute_terminal.Following -> "following", []
    | Paused _ ->
        "paused", [ Message_layout.count_noun newer "newer row"; "End:follow" ] in
  let facts = match observation with
    | Masc_tui_fetched.Ready (Keeper_execute_snapshot snapshot, observed_at)
    | Stale ((Keeper_execute_snapshot snapshot, observed_at), _) ->
        let time = Unix.localtime observed_at in
        [ (if snapshot.kes_active_count > 0 then Printf.sprintf "%d active" snapshot.kes_active_count
           else if snapshot.kes_closed then "closed" else "state unknown")
        ; Printf.sprintf "%02d:%02d:%02d" time.Unix.tm_hour time.tm_min time.tm_sec ]
    | Ready (Keeper_execute_none, _) | Stale ((Keeper_execute_none, _), _)
    | Absent | Loading | Failed _ -> [] in
  let facts = mode_facts @ facts in
  let stale = match observation with
    | Masc_tui_fetched.Stale (_, Execute_stream_stopped _) when Option.is_some stopped -> []
    | Masc_tui_fetched.Stale
        (_, ((Execute_stream_stopped _ | Execute_read_failed _ | Execute_stream_retrying _) as detail)) ->
        [ Theme.bad () ^ "stale: " ^ sanitize (keeper_execute_failure_detail detail) ^ Ansi.reset ]
    | Ready _ | Absent | Loading | Failed _ -> [] in
  let status = Theme.recede () ^ String.concat " \xc2\xb7 " (mode :: facts) ^ Ansi.reset
    ^ String.concat "" (List.map (fun part -> " \xc2\xb7 " ^ part) stale) in
  let status = match stopped with
    | None -> status
    | Some (reason, detail) ->
      let cause = match reason with
        | Masc_tui_execute_stream_job.Http_status status -> Printf.sprintf "HTTP %d" status
        | Unattested_response _ -> "unattested"
        | Invalid_stream_response _ -> "invalid stream"
        | Unexpected_error -> "error" in
      let prefix = "Retry[] " ^ cause in
      let lead = Theme.bad () ^ prefix ^ Ansi.reset in
      (* A truncation mark consumes a cell. At exactly the prefix width,
         leave the prefix whole instead of cutting its last character. *)
      if width <= Message_layout.display_width prefix then lead
      else lead ^ " \xc2\xb7 " ^ status
        ^ " \xc2\xb7 " ^ Theme.bad () ^ sanitize detail ^ Ansi.reset in
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
    let portrait_reading = match (keeper_reading state k).Keeper_control.liveness with
      | Keeper_control.Present runtime -> runtime.kr_portrait
      | Keeper_control.Unobserved -> Tui_decode.Unavailable "not yet read"
      | Keeper_control.Absent -> Tui_decode.Unavailable "absent from live roster"
      (* The profile error's full text owns the failure section on the Info
         tab, where it wraps under its own heading. The portrait row is a
         status line read on the Items tab too, where no failure section
         exists, so its sentence names the state and no location: a second
         unwrapped copy of the whole diagnosis here is what made the pane
         read as broken. *)
      | Keeper_control.Invalid _ ->
          Tui_decode.Unavailable "invalid keeper profile" in
    let account = selected_item_account state in
    let items = item_browser_items state in
    let cursor = Item_account.cursor ~items state.item_cursor in
    let selected_item = List.nth_opt items cursor in
    let milli value = Printf.sprintf "%d.%03d" (value / 1000) (value mod 1000) in
    let account_line =
      match account, state.item_account_error with
      | Some (Item_account.Ready account), _ ->
          let balance_milli = selected_item_balance_now state in
          Printf.sprintf "  Wallet %s Candle%s · %d owned"
            (milli (Item_account.spendable_milli account ~balance_milli))
            (match balance_milli with Some _ -> "" | None -> " (as read)")
            (List.length account.owned_items)
      | Some Item_account.Off, _ -> "  Candle off"
      | Some (Item_account.Disabled reason), _ ->
          "  Candle disabled: " ^ Terminal_text.single_line reason
      | None, Some detail -> "  Account unavailable: " ^ Terminal_text.single_line detail
      | None, None ->
          (match pending_detail_read state ~tab:Detail_items ~keeper:k.k_name with
           | Some _ -> "  Loading Item account…"
           | None -> "  Item account not observed")
    in
    let is_worn item =
      match portrait_reading with
      | Tui_decode.Unavailable _ -> false
      | Tui_decode.Ready equipment ->
          Keeper_portrait_item.in_slot equipment (Keeper_portrait_item.slot item) = Some item
    in
    (* Starting accessories may be worn without being purchased. Ownership and
       the observed picture therefore remain separate facts. *)
    let equipped_word = "  " ^ Ansi.bold ^ "wearing" ^ Ansi.reset in
    let item_account_facts item =
      match account with
      | Some (Item_account.Ready account) ->
          let owned = List.mem item account.owned_items in
          let price =
            match List.find_opt (fun (entry : Item_account.entry) -> entry.item = item) account.catalog with
            | None -> "catalog unavailable"
            | Some { price = Item_account.Unpriced; _ } -> "unpriced"
            | Some { price = Item_account.Priced 0; _ } -> "free"
            | Some { price = Item_account.Priced amount; _ } ->
              milli amount ^ " Candle"
              ^ (if owned then ""
                 else
                   let spendable =
                     Item_account.spendable_milli account
                       ~balance_milli:(selected_item_balance_now state)
                   in
                   if amount <= spendable then " · can buy"
                   else " · need " ^ milli (amount - spendable) ^ " more")
          in
          Some ((if owned then "owned · " else "not owned · ") ^ price)
      | Some (Item_account.Off | Item_account.Disabled _) | None -> None
    in
    let outfit_lines = match portrait_reading with
      | Tui_decode.Unavailable _ -> []
      | Tui_decode.Ready equipment ->
        let slots = List.map (fun slot ->
          let name = match Keeper_portrait_item.in_slot equipment slot with
            | None -> "none"
            | Some item -> Item_account.item_name item in
          Keeper_portrait_item.slot_id slot ^ ": " ^ name) Keeper_portrait_item.slots in
        Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
          ("Wearing · " ^ String.concat " · " slots)
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
        (if index = cursor then ">" else " ")
        (Keeper_portrait_item.slot_id (Keeper_portrait_item.slot item))
        (Item_account.item_name item) facts (if is_worn item then equipped_word else "")
    in
    let headline =
      [ Printf.sprintf "  Items · %s · %d/%d · %s"
          (Item_account.filter_name state.item_filter)
          (if items = [] then 0 else cursor + 1) (List.length items)
          (if state.item_preview && selected_item <> None then "try on" else "current outfit")
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
          [ "  Portrait unavailable: " ^ Terminal_text.single_line reason ] in
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
          | Item_account.Owned, Some (Item_account.Ready _) -> "No purchased accessories yet."
          | Item_account.Can_buy, Some (Item_account.Ready _) -> "No unowned item fits the current balance."
          | (Item_account.Owned | Item_account.Can_buy), (None | Some (Item_account.Off | Item_account.Disabled _)) ->
            "This view needs a ready Item account."
          | (Item_account.All | Item_account.In_slot _), _ -> "No items in this view.") ] in
      let footer = ["  Requests open a chat draft; the Keeper reports the result."] in
      let reserved = List.length headline + List.length selected_facts + List.length outfit_lines
        + List.length observation + List.length empty + List.length footer in
      let visible = min count (max 1 (base_height - reserved)) in
      let first = max 0 (min (cursor - visible / 2) (count - visible)) in
      let rows = List.filter_map (fun (index, item) ->
        if index < first || index >= first + visible then None else Some (item_row index item))
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
        [ section_line "Identity" ]
        @ row_lines ~width "Name:" (Terminal_text.single_line k.k_name)
        @ row_lines ~width "Paused:"
            (match k.k_origin, (keeper_reading state k).Keeper_control.liveness with
             | Tui_decode.Remote_keeper,
                 (Keeper_control.Invalid _ | Unobserved | Absent) ->
                 Ansi.dim ^ "not observed" ^ Ansi.reset
             | (Tui_decode.Persisted_keeper | Declared_keeper _), _
             | Remote_keeper, Keeper_control.Present _ ->
                 if k.k_paused then (Theme.warn ()) ^ "yes" ^ Ansi.reset
                 else Ansi.dim ^ "no" ^ Ansi.reset)
        @ row_lines ~width "Suggested action:"
            (keeper_suggested_action (keeper_reading state k))
        @ (match Masc_tui_candle.balance_text ~now:(Unix.gettimeofday ())
                   state.candle_observation ~keeper:k.k_name with
           | None -> []
           | Some value -> row_lines ~width "Candle balance:" (Terminal_text.single_line value))
      in
      List.iter add_line identity;
      (match portrait_reading with
       | Tui_decode.Ready _ -> ()
       | Tui_decode.Unavailable reason -> add_row "Portrait:" ("unavailable: " ^ Terminal_text.single_line reason));
      add_empty ();
      let add_row label value =
        List.iter add_line (row_lines ~width:header_width label value)
      in
      (* Current work section *)
      add_section "Current Work";
      add_row "Task:"
        (match k.k_activity with
         | None -> "not observed"
         | Some activity -> Terminal_text.single_line_or
             ~default:Masc_tui_theme.Glyph.no_value activity.k_current_task_id);
      add_empty ();

      add_section "Live Context";
      let add_context observation =
        match Observation_layout.context_summary observation with
        | Observation_layout.Context_measured observation ->
            let ratio = observation.ratio in
            let pct = Float.of_int (Observation_layout.percentage_tenths ratio) /. 10.0 in
            let bar_width = Layout.keeper_context_bar_width ~inner_width:header_width in
            add_row "Context:"
              (Printf.sprintf "%s%.1f%%%s  %s  %s / %s tokens"
                 (ctx_color ratio) pct Ansi.reset (ctx_bar ratio bar_width)
                 (Masc_tui_message_layout.compact_count observation.tokens)
                 (Masc_tui_message_layout.compact_count observation.maximum));
            add_row "Observed:" (Terminal_text.short_timestamp observation.observed_at);
            add_row "Turn Ref:" (Terminal_text.single_line observation.turn_ref)
        | Observation_layout.Context_partial observation ->
            add_row "Context:"
              (Printf.sprintf "%s tokens in context; window not observed"
                 (Masc_tui_message_layout.compact_count observation.tokens));
            add_row "Observed:" (Terminal_text.short_timestamp observation.observed_at);
            add_row "Turn Ref:" (Terminal_text.single_line observation.turn_ref)
        | Observation_layout.Context_unavailable reason ->
            add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset)
      in
      (match live_context_view state k with
       | Masc_tui_fetched.Absent ->
           add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)
       | Masc_tui_fetched.Loading ->
           add_row "Context:" (Ansi.dim ^ "reading" ^ Ansi.reset)
       | Masc_tui_fetched.Ready observation -> add_context observation
       | Masc_tui_fetched.Stale (observation, detail) ->
           add_row "Refresh:" ((Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset);
           add_context observation
       | Masc_tui_fetched.Failed detail ->
           add_row "Context:" ((Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset));
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
        "1. 현재 장애 · 보드 격리 (Current Failure & Board Attention)";
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
            | None -> wrap ~tone:Ansi.dim "none")
        | Keeper_control.Unobserved -> wrap ~tone:Ansi.dim "unread"
        | Keeper_control.Absent -> wrap ~tone:Ansi.dim "absent from live roster"
        | Keeper_control.Invalid detail ->
            wrap ~tone:(Theme.bad ()) ("config error: " ^ detail)
      in

      (* Blocked Board-attention partitions wait here for an
         operator's requeue, and nothing else on the screens said they existed.
         Beside the current failure because it is one: this Keeper's Board
         judgments for those posts do not move until someone presses Q. *)
      Masc_tui_board_quarantine.lines ~now:(Unix.gettimeofday ())
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
      add_numbered_section "2. 권한 게이트 · 승인 정책 (Gate & Tool Policy)";
      (* The same word the chat header wears in capitals and the footer offers
         after g, with what it does beside it. This row said "asked" under a
         header saying AUTO. *)
      add_row "Tool calls:"
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
         ^ Masc_tui_types.tool_mode_effect mode ^ Ansi.reset);
      (* "workspace" is where the stance comes from, not what it is. The chat
         header resolves the same inheritance before drawing it; this row left
         the reader to go and look it up. *)
      add_row "Effects (Gate mode):"
        (let inherited =
           Option.map
             (fun (modes : Tui_decode.gate_lane_modes) ->
               gate_mode_reading_word modes.Tui_decode.glm_workspace)
             state.gate_modes
         in
         match List.assoc_opt k.k_name state.keeper_gate_modes with
         | Some mode ->
             (Theme.accent ())
             ^ Terminal_text.single_line (gate_mode_reading_word mode)
             ^ Ansi.reset
         | None ->
             Ansi.dim ^ "workspace"
             ^ (match inherited with
                | Some word -> " \xc2\xb7 " ^ Terminal_text.single_line word
                | None -> "")
             ^ Ansi.reset);
      add_row "Lane first:"
        (match
           List.filter
             (fun (first : Tui_decode.keeper_exact_lane_first) ->
               String.equal first.Tui_decode.kel_keeper k.k_name)
             state.keeper_exact_lane_firsts
         with
         | [] -> Ansi.dim ^ "lane order" ^ Ansi.reset
         | firsts ->
             (Theme.accent ())
             ^ Terminal_text.single_line
                 (String.concat ", "
                    (List.map
                       (fun (first : Tui_decode.keeper_exact_lane_first) ->
                         (* The marker leads: a narrow pane cuts the row's
                            tail, and the slot id is the part it can lose. *)
                         (if first.kel_offered then ""
                          else "not offered, lane order \xc2\xb7 ")
                         ^ first.Tui_decode.kel_lane_id ^ " \xe2\x86\x92 "
                         ^ first.kel_slot_id)
                       firsts))
             ^ Ansi.reset);
      (match state.keeper_gate_settings_unread with
       | None -> ()
       | Some reason ->
           add_row "Gate settings:"
             (Theme.bad () ^ "unread \xc2\xb7 "
              ^ Terminal_text.single_line reason ^ Ansi.reset));

      (* Runtime & 24h section *)
      add_numbered_section "3. 런타임 배정 · 최근 24시간 활동 (Runtime & Last 24h Activity)";
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
                   | Some d -> Printf.sprintf "inherited: %s" d
                   | None -> "inherited")
              | None -> "inherited"
            in
            Printf.sprintf "default (%s)" def_name
      in
      add_row "Runtime Target:" target_str;
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
                add_row "Candidate Chain:" hops;
                (match lane.rrl_runtime_ids with
                 | first :: _ -> add_row "Head Candidate:" first
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
                          add_row "Default Context:"
                            (Printf.sprintf "%s \xc2\xb7 max output %s"
                               (format_context_tokens ro.ro_effective_max_context)
                               (match ro.ro_max_output_tokens with
                                | Some t -> format_context_tokens t
                                | None -> "default"))
                      | None -> ())
                 | None -> ())
            | None -> ()));
      (match k.k_origin with
       | Tui_decode.Persisted_keeper -> ()
       | Remote_keeper -> add_row "Source:" "server roster"
       | Declared_keeper requirements ->
         add_row "Preparation:" (String.concat " · "
           (List.map Masc.Keeper_declared_roster.requirement_label requirements)));
      add_row "Last Outcome:"
        (match k.k_activity with
         | None -> "not observed"
         | Some activity ->
           (match activity.k_last_proactive_outcome with
            | Some outcome -> proactive_outcome_word outcome
            | None -> Masc_tui_theme.Glyph.no_value));
      (* Recent activity, folded from the metrics rows already read for this
         Keeper. The window is bounded by row count, so it can fall short of the
         span; when it does, say what it reached instead of implying a full day.
         With no rows there is nothing to total, so the section says why and
         draws no zeros: the same sentence the Logs tab gives for the same
         read. *)
      let log_snapshot = keeper_log_snapshot state in
      let log_diagnostics = keeper_log_diagnostics state in
      List.iter (fun (tone, detail) ->
        add_row "Metrics:" (keeper_log_style tone ^ Terminal_text.single_line detail ^ Ansi.reset))
        log_diagnostics;
      (match
         Keeper_activity.read
           ~since:
             (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
           log_snapshot.entries
       with
       | Keeper_activity.No_rows ->
         if log_diagnostics = [] then add_row "Window:"
           (Ansi.dim ^ Metrics_tail.empty_message log_snapshot.error ^ Ansi.reset)
       | Keeper_activity.Rows activity ->
         if not activity.Keeper_activity.aw_covered then
           add_row "Window:"
             (match activity.Keeper_activity.aw_oldest_ts with
              | Some oldest ->
                Printf.sprintf "partial, reaches %s"
                  (Terminal_text.short_timestamp oldest)
              | None -> "partial");
         add_row "Turns / Heartbeats:"
           (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
              activity.Keeper_activity.aw_heartbeats);
         add_row "Tokens In / Out:"
           (Printf.sprintf "%s / %s"
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_input_tokens)
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_output_tokens));
         add_row "Cost:"
           (match activity.Keeper_activity.aw_cost_usd with
            | Some cost -> Printf.sprintf "$%.4f" cost
            | None -> Ansi.dim ^ "not priced by the provider" ^ Ansi.reset);
         add_row "Tool Calls:"
           (string_of_int activity.Keeper_activity.aw_tool_calls);
         add_row "Top Tools:"
           (match activity.Keeper_activity.aw_top_tools with
            | [] -> Masc_tui_theme.Glyph.no_value
            | tools ->
              tools
              |> List.map (fun (tool : Keeper_activity.tool_use) ->
                     Printf.sprintf "%s x%d"
                       (Terminal_text.single_line tool.Keeper_activity.tu_name)
                       tool.Keeper_activity.tu_calls)
              |> String.concat "  "));

      (* This Keeper's month beside the fleet's per-turn figures: the same
         numbers for every Keeper, read once per month. The month is neither
         the current failure of section 1 nor the 24 hours of section 3, and
         under section 1 it read as part of the failure. *)
      add_numbered_section "4. 이번 달 효율 (This Month's Efficiency)";
      (match Masc_tui_keeper_efficiency.lines state.keeper_efficiency ~keeper_name:k.k_name with
       | [] -> wrap ~tone:Ansi.dim "unread"
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
      add_numbered_section "5. 최근 후보 모델 폴백 이력 (Recorded Runtime Walk)";
      let module Receipt = Masc.Keeper_execution_receipt in
      let module Evidence = Keeper_runtime_walk_evidence in
      let module Fault = Llm_provider.Candidate_fault in
      let history_row label value = add_row label (Terminal_text.single_line value) in
      let source (turn : Receipt.receipt_turn) =
        history_row "Receipt trace:" turn.receipt_trace_id;
        history_row "Receipt turn:"
          (match turn.receipt_turn_count with
           | Some count -> string_of_int count
           | None -> "not recorded");
        history_row "Receipt ended:" turn.receipt_ended_at
      in
      let fault = function
        | None -> "API classification inapplicable"
        | Some Fault.Unattributed -> "unattributed API refusal"
        | Some Fault.Unknown_after_dispatch -> "outcome uncertain"
        | Some Fault.Local_admission -> "MASC admission wait"
        | Some (Fault.Binding binding) ->
          match binding with
          | Fault.Credential -> "credential"
          | Fault.Account_access -> "account access"
          | Fault.Account -> "account"
          | Fault.Model_absent -> "model absent"
          | Fault.Rate_limit -> "rate limit"
          | Fault.Capacity -> "capacity"
          | Fault.Server -> "server"
          | Fault.Window -> "context window"
          | Fault.Body_limit -> "body limit"
          | Fault.Admission -> "admission"
          | Fault.Deadline -> "deadline"
          | Fault.Output_dialect -> "output dialect"
          | Fault.Refusal_unread -> "refusal unread"
      in
      (match (keeper_reading state k).Keeper_control.liveness with
       | Keeper_control.Present runtime ->
         (match runtime.kr_runtime_lane_observation with
          | None -> wrap ~tone:Ansi.dim no_receipt_text
          | Some (Receipt.Runtime_lane_not_observed turn) ->
            source turn;
            wrap ~tone:Ansi.dim walk_not_captured_text
          | Some (Receipt.Runtime_lane_unreadable {turn;field}) ->
            Option.iter source turn;
            wrap ~tone:(Theme.warn ()) (evidence_unreadable_text ^ ": " ^ field)
          | Some (Receipt.Runtime_lane_observed {turn;evidence}) ->
            source turn;
            (match evidence.failures with
             | [] -> wrap ~tone:Ansi.dim no_candidate_failure_text
             | failures -> List.iter (fun (failure : Evidence.failure) ->
                 history_row "Candidate:"
                   (Printf.sprintf "%d · %s" failure.attempt failure.runtime_id);
                 history_row "Invocation:"
                   (match failure.dispatch with
                    | Runtime_attempt_dispatch.Dispatched -> "candidate invoked"
                    | Runtime_attempt_dispatch.Rejected_before_dispatch -> "rejected before invocation");
                 history_row "API fact:" (fault failure.api_candidate_fault);
                 wrap (Keeper_request_failure.summary failure.failure)) failures);
            (match evidence.terminal with
             | Evidence.Terminal_not_observed ->
               history_row "Terminal origin:" "not observed"
             | Evidence.Candidate_terminal {runtime_id;attempt;failure} ->
               history_row "Terminal origin:" (Printf.sprintf "%d · %s" attempt runtime_id);
               wrap (Keeper_request_failure.summary failure)))
       | Keeper_control.Unobserved -> wrap ~tone:Ansi.dim "live roster unread"
       | Keeper_control.Absent -> wrap ~tone:Ansi.dim "absent from live roster"
       | Keeper_control.Invalid detail ->
         wrap ~tone:(Theme.warn ()) ("roster unavailable: " ^ detail));

      (* Lifetime totals & Timestamps section *)
      add_numbered_section "6. 누적 통계 · 생성 이력 (Lifetime Totals & Timestamps)";
      (match k.k_activity with
       | None -> add_row "Activity:" "not observed"
       | Some activity ->
         add_row "Total Turns:" (string_of_int activity.k_total_turns);
         (* Read at a glance, the way the Acting pane's block already reads its
            token figures. A live roster drew "75111274" here: eight digits a
            reader counts rather than reads. Turns and tool calls keep their
            digits -- three or four of them, and a count of things done rather
            than a size. *)
         add_row "Total Tokens:"
           (Masc_tui_message_layout.compact_count activity.k_total_tokens);
         add_row "Lifetime Cost:" (Tui_decode.keeper_cost_summary activity.k_total_cost_usd);
         add_row "Last Turn:"
           (match activity.k_last_turn_at with
            | Some at -> Terminal_text.short_timestamp_of_unix at
            | None -> "(never)"));
      (match k.k_identity with
       | Ok identity ->
         add_row "Created:" (Terminal_text.short_timestamp identity.k_created_at);
         add_row "Updated:" (Terminal_text.short_timestamp identity.k_updated_at)
       | Error reason ->
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 26))
             (Terminal_text.single_line reason)
           |> List.iteri (fun index line ->
                add_row (if index = 0 then "Metadata:" else "") line));

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
          ?elapsed_s:(Masc_tui_types.pending_elapsed_s ~now_ns started_ns)
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
                (match observed with None -> "loading" | Some _ -> "refreshing") ] in
      match observed with
      | Some lines ->
          let previous = match error, pending with
            | None, None -> []
            | Some _, (Some _ | None) | None, Some _ ->
                [ Ansi.dim ^ "  Last observation:" ^ Ansi.reset ] in
          failure @ progress @ previous @ lines
      | None ->
          (match error, pending with
           | None, None ->
               [ Ansi.dim ^ "  "
                 ^ (if server_authority_ready state then "Not observed · r to read"
                    else "Not observed · workspace confirmation required")
                 ^ Ansi.reset ]
           | Some _, (Some _ | None) | None, Some _ -> failure @ progress)
    in
    let channel_lines () =
      let rows = match state.connectors_error, state.connectors with
      | Some detail, None ->
          [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
            ^ Ansi.reset ]
      | None, None ->
          (match Connector_read.view state.connectors_read with
           | Connector_read.Quiet ->
               [ Ansi.dim ^ "  Channel transports not observed" ^ Ansi.reset ]
           | Reading _ | Waiting_after_write | Failed_to_start ->
               (* The existing typed-source notice below owns pending,
                  held recheck and failed-start guidance; none is a value. *)
               [])
      | error, Some snapshot ->
          let connectors = snapshot.cs_connectors in
          let selected_index =
            max 0 (min state.connectors_cursor (List.length connectors - 1))
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
                   Printf.sprintf "  %d here / %d total" here_count
                     (List.length connector.cn_bindings)
                 in
                 (* Two cells of indent, two for the cursor mark, two between
                    the name and the badge: the padding the row spends before
                    its columns. *)
                 let name_cells =
                   Masc_tui_connector_state.list_row_name_cells
                     ~inner:(framed_inner_width cols) ~fixed_cells:6
                     ~tail_cells:(String.length tail)
                 in
                 let line =
                   "  " ^ (if index = selected_index then "▸ " else "  ")
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
                 if index = selected_index then Ansi.reverse ^ line ^ Ansi.reset
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
                 (Theme.bad ()) ^ "    " ^ name ^ "  unreadable: "
                 ^ Terminal_text.single_line refusal.cr_reason ^ Ansi.reset)
              snapshot.cs_refused
          in
          let selected_lines =
            match List.nth_opt connectors selected_index, snapshot.cs_refused with
            | None, [] ->
                [ Ansi.dim ^ "  (no channel transports registered)" ^ Ansi.reset ]
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
                    (Option.map (fun present -> if present then "yes" else "no") value)
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
                  Masc_tui_connector_unbind.channel_label
                    ~channel_id:binding.cb_channel_id
                    ~channel_name:binding.cb_channel_name
                in
                let store_state =
                  match connector.cn_binding_store_read_ok with
                  | Some true -> Some "readable"
                  | Some false -> Some "UNREADABLE"
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
                      let line =
                        Printf.sprintf "    %s %s → %s%s"
                          (if selected then Masc_tui_theme.Glyph.current_entry else " ")
                          (binding_reference binding)
                          (Terminal_text.single_line binding.cb_keeper_name)
                          (if here then "  (this Keeper)"
                           else if missing_keeper then
                             "  (MISSING KEEPER · e reassign · u u remove)"
                           else "")
                      in
                      if selected then Ansi.reverse ^ line ^ Ansi.reset
                      else if missing_keeper then
                        (Theme.bad ()) ^ line ^ Ansi.reset
                      else line)
                    connector.cn_bindings
                  |> function
                  | [] -> [ Ansi.dim ^ "    (no channel bindings)" ^ Ansi.reset ]
                  | lines -> lines
                in
                [ ""
                ; Ansi.bold ^ "  Selected · "
                  ^ Terminal_text.single_line connector.cn_display_name
                  ^ Ansi.reset
                ]
                @ detail_section_lines "1. 연결 상태 · 트리거 및 응답 정책 (Connection & Routing Policy)"
                @ field "Binding target"
                    (match selected_binding with
                     | None -> "(no binding selected)"
                     | Some binding -> binding_reference binding)
                  (* The badge is read from the status the row would print
                     beside it ([decode_connector_connection] takes status,
                     available and connected), so the word never differs from
                     the badge and the row said the same thing twice. *)
                @ field "Connection"
                    (connection_label connector)
                @ field "MASC API"
                    (Printf.sprintf "%s:%d"
                       Masc_network_defaults.masc_http_loopback_peer state.port)
                @ field "Channel type"
                    (Terminal_text.single_line_or
                       ~default:Masc_tui_theme.Glyph.no_value connector.cn_channel)
                @ optional_row "Runtime state"
                    (Masc_tui_connector_state.runtime_state_to_draw connector)
                @ optional_row "Status source" connector.cn_status_source
                @ optional_row "Remote endpoint" connector.cn_endpoint
                @ optional_row "Status file" connector.cn_status_path
                @ optional_row "Binding store" connector.cn_binding_store_path
                @ optional_row "Store state" store_state
                @ optional_row "Binding source" connector.cn_binding_source
                @ optional_row "Trigger policy" connector.cn_trigger_policy
                @ optional_row "Reply mode" connector.cn_reply_mode
                @ optional_row "Chat database" connector.cn_chat_db_path
                @ detail_section_lines "2. 봇 자격증명 · 프로세스 상태 (Bot Credentials & Process)"
                @ optional_row "Bot user" connector.cn_bot_user_name
                @ optional_row "Bot user id" connector.cn_bot_user_id
                @ optional_bool_row "Bot token ready" connector.cn_bot_token_present
                @ optional_bool_row "App token ready" connector.cn_app_token_present
                @ optional_bool_row "Gate healthy" connector.cn_gate_healthy
                @ optional_int_row "Server pid" connector.cn_pid
                @ optional_int_row "Guilds" connector.cn_guild_count
                @ detail_section_lines "3. 디렉토리 동기화 · 이름 매핑 파일 (Directory & Name Mapping)"
                @ optional_row "Directory state"
                    (Option.map
                       (function
                         | Masc.Tui_decode_connectors.Connector_directory_not_started ->
                           "not started"
                         | Connector_directory_refreshing -> "refreshing"
                         | Connector_directory_complete -> "complete"
                         | Connector_directory_partial -> "partial")
                       connector.cn_directory_state)
                @ optional_int_row "Servers learned"
                    connector.cn_directory_server_count
                @ optional_int_row "Channels learned"
                    connector.cn_directory_channel_count
                @ optional_int_row "People learned"
                    connector.cn_directory_person_count
                @ (match connector.cn_directory_authentication_failed with
                   | [] -> []
                   | values ->
                     field "Authentication"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_permission_denied with
                   | [] -> []
                   | values ->
                     field "Permission limits"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_errors with
                   | [] -> []
                   | values ->
                     field "Directory errors"
                         (String.concat "; "
                            (List.map Terminal_text.single_line values))
                     )
                @ optional_row "Directory updated"
                    connector.cn_directory_updated_at
                @ optional_row "Workspace id" connector.cn_workspace_id
                @ optional_row "Server names" connector.cn_server_names_path
                @ optional_row "Channel names" connector.cn_channel_names_path
                @ optional_row "People names" connector.cn_people_names_path
                @ optional_row "Mapping scope" connector.cn_name_mapping_scope
                @ optional_row "Names read error" connector.cn_names_error
                @ optional_row "Updated" connector.cn_updated_at
                @ optional_row "Connection error" connector.cn_error
                @ optional_row "Store error" connector.cn_binding_store_error
                @ detail_section_lines "4. 채널 → 키퍼 바인딩 (Channel → Keeper Bindings)"
                @ binding_lines
                @ (match connector.cn_name_mappings with
                   | [] -> []
                   | mappings ->
                       [ ""; Ansi.bold ^ "  Known ID ↔ names" ^ Ansi.reset ]
                       @ List.concat_map
                           (fun (mapping : Masc.Tui_decode_connectors.connector_name_mapping) ->
                              Printf.sprintf "%-7s %s ↔ %s"
                                (match mapping.cnm_kind with
                                 | Masc.Tui_decode_connectors.Connector_channel_name -> "channel"
                                 | Connector_person_name -> "person"
                                 | Connector_server_name -> "server")
                                (Terminal_text.single_line mapping.cnm_id)
                                (Terminal_text.single_line mapping.cnm_name)
                              |> Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
                              |> List.map (fun line -> "    " ^ line))
                           mappings)
                @ [ ""
                  ; Ansi.dim
                    ^ "  j/k transport · J/K binding · b bind · e reassign · u u remove"
                    ^ Ansi.reset
                  ; Ansi.dim
                    ^ "  These actions change channel routing, not the connector process."
                    ^ Ansi.reset
                  ; Ansi.dim ^ "  PgUp/PgDn scrolls this detail" ^ Ansi.reset
                  ; Ansi.dim ^ "  r reloads bindings and learned names" ^ Ansi.reset
                  ]
          in
          [ Printf.sprintf "  %d transports · %d available · actions target %s"
              snapshot.cs_total snapshot.cs_active
              (Terminal_text.single_line k.k_name)
          ]
          @ (match error with
             | None -> []
             | Some detail ->
                 [ (Theme.bad ()) ^ "  STALE · "
                   ^ Terminal_text.single_line detail ^ Ansi.reset
                 ])
          @ transport_rows @ refused_rows @ selected_lines
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
        | Some detail ->
            [ (Theme.bad ()) ^ "  " ^ (if observed then "STALE · " else "")
              ^ Terminal_text.single_line detail ^ Ansi.reset ]
        | None -> [] in
      let progress = match pending with
        | None -> []
        | Some started_ns ->
            [ loading_row ~started_ns (if observed
                then "refreshing this Keeper's schedules · last observation"
                else "loading this Keeper's schedules") ] in
      let snapshot_lines = match state.keeper_schedules with
      | Some (keeper_name, snapshot) when String.equal keeper_name k.k_name ->
          let rows = snapshot.scs_rows in
          if not (String.equal snapshot.scs_status "ok") then
            [ (Theme.bad ())
              ^ (match snapshot.scs_read_error with
                 | Some err -> "  " ^ Terminal_text.single_line err
                 | None -> "  (schedule store unreadable)")
              ^ Ansi.reset ]
          else if rows = [] then
            match
              Render_schedule.classify_keeper_schedule_absence
                ~truncated:snapshot.scs_truncated
                ~shown:(List.length snapshot.scs_rows)
                ~total:snapshot.scs_request_count
            with
            | Render_schedule.Store_has_none ->
                [ Ansi.dim ^ "  (no schedules for this Keeper)" ^ Ansi.reset ]
            | Render_schedule.Page_capped { shown; total } ->
                let of_total =
                  match total with
                  | Some total ->
                      Printf.sprintf " -- %s of %s requests"
                        (Masc_tui_value.Count.grouped shown)
                        (Masc_tui_value.Count.grouped total)
                  | None -> ""
                in
                let next_step = match state.keeper_schedules_page with
                  | Some (name, { sp_previous = _ :: _; _ }) when String.equal name k.k_name ->
                      "use < for the previous page"
                  | Some _ | None -> "refresh to read again"
                in
                [ Ansi.dim
                  ^ Printf.sprintf
                      "  (none on this page%s; %s)" of_total next_step
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
                     "  page %d · < / > pages · pages may change between reads"
                     (List.length page.sp_previous + 1) ^ Ansi.reset ]
             | Schedule_paging_unavailable, _ when snapshot.scs_truncated ->
                 [ Ansi.dim ^ "  first page only · server paging unavailable" ^ Ansi.reset ]
             | (Schedule_paging_unavailable | Schedule_paging _), (Some _ | None) -> [])
            @ (match snapshot.scs_counts with
             | None -> []
             | Some counts ->
                 [ Ansi.dim ^ "  "
                   ^ Masc_tui_types.schedule_counts_line counts
                   ^ Ansi.reset
                 ; ""
                 ])
            @ (let outcome_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line (schedule_outcome_word row))
                   rows
               in
               let by_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_requested_by)
                   rows
               in
               let recurrence_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_recurrence_summary)
                   rows
               in
               (* Every line carries a two-cell lead before the table, so the
                  table is fitted to what the lead leaves -- the same reserve
                  the Schedules list makes, without which the frame cuts the
                  last column's tail on every row. *)
               let table_inner = max 1 (inner - 2) in
               let layout =
                 Render_schedule.kauto_layout ~inner_width:table_inner
                   ~status_width:schedule_status_word_cells
                   ~clock_width:schedule_requested_clock_cells
                   ~outcome_width:
                     (Render_schedule.schedule_delivery_width outcome_words)
                   ~recurrence_width:
                     (Render_schedule.kauto_recurrence_width recurrence_words)
                   ~by_width:(Render_schedule.kauto_by_width by_words)
               in
               let header = Render_schedule.kauto_header_row ~layout in
               (* The rule under the names runs the header's own width, so a
                  pane narrower than the table does not draw a rule longer
                  than the rows under it. The closed rule below ends at the
                  same cell, so the two rules read as one margin. *)
               let rule_cells =
                 min table_inner (Message_layout.display_width header) in
               let occurrence_clock = function
                 | Some iso -> Terminal_text.short_timestamp iso
                 | None -> Masc_tui_theme.Glyph.no_value
               in
               let row_line (row : schedule_row) =
                 (* The mark and the state word wear one colour, the state's
                    own; the outcome wears the outcome's, so a failed wake
                    reads red beside a state still reading live. *)
                 let status_style = schedule_status_color row.sch_status in
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
                 let outcome =
                   if held then Masc_tui_theme.Glyph.no_value
                   else Terminal_text.single_line (schedule_outcome_word row)
                 in
                 "  "
                 ^ Render_schedule.kauto_row ~layout
                     ~styles:
                       ({ kstyle_mark = status_style
                        ; kstyle_status = status_style
                        ; kstyle_outcome = semantic_status_color outcome
                        ; kstyle_recurrence = Ansi.dim
                        ; kstyle_by = Theme.recede ()
                        } : Render_schedule.kauto_row_styles)
                     { Render_schedule.krow_mark =
                         Render_schedule.kauto_status_mark row.sch_status
                     ; krow_status = Terminal_text.single_line row.sch_status
                     ; krow_triggered =
                         occurrence_clock row.sch_last_wake_started_at_iso
                     ; krow_outcome = outcome
                     ; krow_received =
                         occurrence_clock row.sch_stimulus_recorded_at_iso
                     ; krow_recurrence =
                         Terminal_text.single_line row.sch_recurrence_summary
                     ; krow_by = Terminal_text.single_line row.sch_requested_by
                     ; krow_requested =
                         Terminal_text.short_timestamp row.sch_requested_at_iso
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
                     Render_schedule.kauto_group_label ~title:"closed"
                       (List.map
                          (fun word ->
                             Printf.sprintf "%d %s"
                               (List.length
                                  (List.filter (String.equal word) words))
                               (Terminal_text.single_line word))
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
           | None, None -> [ Ansi.dim ^ "  Schedules not observed" ^ Ansi.reset ]
           | Some _, (Some _ | None) | None, Some _ -> [])
      in
      error_lines @ progress @ snapshot_lines
    in
    let run_lines () =
      let failure detail =
        (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset
      in
      let listing runs =
        "  Fusion runs · j/k:select · Enter:open · same IDs as Fusion" ::
        (if runs = [] then ["  No retained Fusion runs for this Keeper"]
         else List.mapi (fun index (run : Masc.Tui_decode_fusion.fusion_run) ->
           (* The clock the Fusion list and the run detail already draw for
              this field, rather than a second copy of its format: three
              lists show a run's start, and a copy is one that stops
              following when the other two change. *)
           Printf.sprintf "%s %s · %s · %s · %s"
             (if Option.fold ~none:false ~some:(fun (cursor, _) -> index = cursor)
                   (Masc_tui_fusion_model.selected_keeper_run state) then ">" else " ")
             (fusion_run_clock run)
             (Masc.Tui_decode_fusion.fusion_run_status_to_string run.fur_status)
             (Terminal_text.single_line run.fur_preset)
             (Terminal_text.single_line run.fur_run_id)) runs)
      in
      match Masc_tui_fusion_model.keeper_runs_view state with
      | Masc_tui_fetched.Absent -> [ Ansi.dim ^ page_unread_note ^ Ansi.reset ]
      | Masc_tui_fetched.Loading -> [ loading_row "loading Fusion runs" ]
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
             , Masc_tui_render_identity.draw ~cols
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
                    "  샌드박스 상태 미조회" else "  Sandbox status not observed") ^ Ansi.reset ]
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
          let failure = match error with
            | None -> []
            | Some detail ->
                [ (Theme.bad ()) ^ "  " ^ (if observed then "STALE · " else "")
                  ^ Terminal_text.single_line detail ^ Ansi.reset ] in
          let progress = if reading_now then
              [ loading_row (if observed
                  then "refreshing execution snapshot · last observation"
                  else "reading execution snapshot") ]
            else [] in
          let lines = match secret_lines state k with
            | Some lines -> lines
            | None ->
                (match reading, error, reading_now with
                 | None, None, false ->
                     [ Ansi.dim ^ "  Execution snapshot not observed" ^ Ansi.reset ]
                 | None, (Some _ | None), true | None, Some _, false -> []
                 | Some _, (Some _ | None), (true | false) ->
                     [ Ansi.dim ^ "  (no projection reported for this Keeper)" ^ Ansi.reset ]) in
          failure @ progress @ lines
      | Detail_github ->
          let base =
            stamped_or state.github_identity_view
              state.github_identity_view_error
          in
          Masc_tui_render_github.lines
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

    (* Top border *)
    box_top buf cols;

    (* Title, with the tab walk on the same row so the chrome height the
       scroll math counts does not move. *)
    (* The tab you are on carries the mark the surface strip puts on the
       surface you are on. Bold and underline said it alone before, so the
       answer was gone from a monochrome terminal, from one that drops
       underline, and from every text capture -- a frame dump, a screenshot
       pasted into an issue, the keyboard-input fixtures. Info's own body
       opens with a section called "Identity", which is also the name of
       another tab, so a reader with no mark had a wrong guess waiting.

       Drawn through [tab_strip] with the row's width: ten tabs are wider
       than the row beside the roster pane, and cut from the right the mark
       on Runs was the part that went. *)
    let entries =
      List.map
        (fun tab ->
          ( Masc_tui_types.keeper_detail_tab_label tab
          , tab = state.detail_tab
          , tab ))
        Masc_tui_types.keeper_detail_tabs
    in
    (* The strip keeps the cells its current tab needs; a name longer than
       what is left folds in the middle. Drawn whole, a long name took the
       row and the strip drew nothing, so the row no longer said which tab
       the body below it is. *)
    let name =
      Message_layout.truncate_middle
        (max heading_id_floor
           (here_steps_room ~cols state ~steps:1
              ~after:
                (Message_layout.display_width tab_strip_gap
                 + tab_strip_min_width entries)))
        (Terminal_text.single_line k.k_name)
    in
    let before =
      here_path state ~path:[ Ansi.bold ^ name ^ Ansi.reset ] ^ tab_strip_gap
    in
    let tabs =
      tab_strip ~width:(tab_strip_width ~cols ~before ~after:"")
        ~press:(fun tab text -> pressable (Press_keeper_tab tab) text)
        entries
    in
    let title = before ^ tabs in
    box_line buf cols title;

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom); the indicator, when the content overflows, spends one
       content row rather than growing the pane, so the pane's height is
       rows - 1 in both cases and the split's two bottoms stay level. *)
    let terminal_tab = state.detail_tab = Detail_terminal in
    let content_height =
      (* The Terminal's status row is there whether or not the output
         overflows, so the output never moves when it starts to. *)
      if total_lines > base_height || terminal_tab then max 0 (base_height - 1)
      else base_height
    in
    let visible_lines = min content_height total_lines in
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
            Option.fold ~none:scroll
              ~some:(fun (cursor, _) ->
                Masc_tui_scroll.ensure_visible ~cursor:(cursor + 1)
                  ~height:(max 1 content_height) scroll)
              (Masc_tui_fusion_model.selected_keeper_run state)
          else
            Option.fold ~none:scroll
              ~some:(fun cursor ->
                Masc_tui_scroll.ensure_visible ~cursor
                  ~height:(max 1 content_height) scroll)
              identity_cursor_line
    in
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

    (* Scroll indicator; on the Terminal tab the row says what the view is
       doing instead. *)
    if terminal_tab then box_line buf cols (Lazy.force terminal).terminal_status
    else
      Option.iter
        (fun row ->
          box_line buf cols ((Theme.recede ()) ^ row ^ Ansi.reset))
        (Masc_tui_scroll.position_row ~scroll ~height:content_height total_lines);

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
        c.push_styled ~style:(Theme.recede ()) "  No keeper selected.")
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
      Masc_tui_keys.keeper_detail_tab_hint state.detail_tab
      ^ "  "
      ^ keeper_control_hints
          ~taken:(Masc_tui_keys.keeper_detail_tab_taken_keys state.detail_tab)
          state (Some (keeper_reading state k))
    in
    let hints =
      if keeper_roster_pane_shown state ~cols then "h/l:pane  " ^ hints
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
        c.push_styled ~style:(Theme.recede ()) "  No keeper selected.")
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let log_snapshot = keeper_log_snapshot state in
    let total_entries = List.length log_snapshot.entries in
    let reading_label = match keeper_logs_view state with
      | Masc_tui_fetched.Absent -> "not read"
      | Loading -> "reading metrics"
      | Failed _ -> "unavailable"
      | Ready _ | Stale _ ->
          count_reading state Masc_tui_value.Count.Entry total_entries in

    (* Header *)
    let header =
      here_row ~cols state
        ~path:
          [ Terminal_text.single_line k.k_name
          ; ui_text state ~ko:"로그" ~en:"logs" ]
        ~readings:[ reading_label ] ~position:None
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    box_line_styled buf cols ~style:(Theme.recede ())
      "  TIME  KIND  LATENCY · full facts below";
    box_divider buf cols;

    let log_rows = Masc_tui_types.keeper_log_rows state ~cols in
    let row_count = List.length log_rows in
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:None
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:row_count ~content_height
        (if state.log_wrap_cols = Some cols then state.log_scroll else 0)
    in
    let visible = Rows.of_list ~first:scroll ~height:content_height log_rows in
    for index = 0 to content_height - 1 do
      if row_count = 0 && index = 0 then
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  " ^ Metrics_tail.empty_message log_snapshot.error)
      else
        match Rows.at visible (scroll + index) with
        | Some (diagnostic, line) ->
            let style = keeper_log_style diagnostic in
            box_line_styled buf cols ~style line
        | None -> box_empty buf cols
    done;
    if row_count > content_height then
      box_line_styled buf cols ~style:(Theme.recede ())
        (Printf.sprintf "  [newest rows %d-%d of %d]" (scroll + 1)
           (min row_count (scroll + content_height)) row_count)
    else box_empty buf cols;

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language state.view));

    finish_surface state ~clamped:(Keeper_logs_scroll { scroll; cols })
      ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end

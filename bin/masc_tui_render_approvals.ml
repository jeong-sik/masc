(** Approval queue, detail and question surfaces. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim

module Approval_detail = Masc_tui_approval_detail
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Message_layout = Masc_tui_message_layout
module Render_schedule = Masc_tui_render_schedule
module Rows = Masc_tui_rows

type approval_line =
  | Field_line of Approval_detail.line
  | Gate_line of Approval_detail.gate_line

let approval_gate_phase state phase =
  ( Masc_tui_types.gate_phase_word state phase
  , match phase with
    | Gate_queued | Gate_human_required -> Theme.warn ()
    | Gate_judging -> Theme.info ()
    | Gate_blocked -> Theme.bad () )

let approval_source_notices state ~(reading : Masc_tui_approvals_model.approvals_reading) =
  [ ui_text state ~ko:"운영자 승인" ~en:"Confirmations", reading.confirm_queue
  ; ui_text state ~ko:"보류 도구" ~en:"Held calls", reading.held_calls
  ; ui_text state ~ko:"도구 심사" ~en:"Gate queue", reading.gate_queue
  ; ui_text state ~ko:"질문" ~en:"Questions", reading.questions ]
  |> List.filter_map (fun (label, list_reading) ->
    let open Masc_tui_approvals_model in
    match list_reading with
    | List_read -> None
    | List_not_read Approval_unread ->
        Some (Theme.recede (), label ^ ui_text state ~ko:" · 미조회" ~en:" · not read")
    | List_not_read (Approval_failed cause) ->
        Some (Theme.bad (), label ^ ui_text state ~ko:" · 조회 실패: " ~en:" · read failed: "
          ^ Terminal_text.single_line cause)
    | List_not_read (Approval_stale cause) ->
        Some (Theme.warn (), label ^ ui_text state ~ko:" · 이전 조회 · 갱신 실패: " ~en:" · retained; refresh failed: "
          ^ Terminal_text.single_line cause)
    | List_not_read (Approval_unavailable detail) ->
        Some (Theme.warn (), label ^ ui_text state ~ko:" · 조회 불가: " ~en:" · unavailable: "
          ^ Terminal_text.single_line detail)
    | List_not_read (Approval_kept_back notice) ->
        (* The notice names the list it kept back; it is drawn alone. *)
        Some (Theme.bad (), Terminal_text.single_line notice))

(** Render the Approvals surface (pending confirmations). *)
(* The ask, whole. The list row is one line through [single_line], which
   turns a newline into the six characters [\x0A] and then cuts; an [Edit]
   carrying a page of code read as its first forty characters and there was
   no second screen. This is that screen. *)
let approval_detail_pane (state : state) ~value_hint ~clamped ~viewport ~rows ~cols (row : Masc_tui_approvals_model.approval_row) buf =
  let width = max 0 (framed_inner_width cols - 2) in
  let say ko en = ui_text state ~ko ~en in
  (* [Approval_detail.of_fields] makes every value terminal-safe. *)
  let fields, gate_fields, identifiers =
    match row with
    | Masc_tui_approvals_model.Keeper_tool_row held ->
      ([ say "질문" "question", held.Tui_decode.kta_question
      ; say "사유" "because",
        Option.value ~default:(say "(미제공)" "(not provided)") held.Tui_decode.kta_because
      ; say "키퍼" "keeper", held.Tui_decode.kta_keeper
      ; say "도구" "tool", held.Tui_decode.kta_tool
      ; say "인자" "args", held.Tui_decode.kta_args
      ], None, [say "호출 ID" "call", held.Tui_decode.kta_tool_call_id])
    | Masc_tui_approvals_model.Gate_row pending ->
      let phase = fst (approval_gate_phase state pending.Tui_decode.gp_phase) in
      let blocked_fields =
        match pending.Tui_decode.gp_phase with
        | Gate_blocked ->
          [ ( say "사유" "reason"
            , Option.value
                ~default:(say "(서버에 기록된 상세 없음)" "(the server recorded no detail)")
                pending.Tui_decode.gp_auto_judge_detail )
          ; ( say "다음 조치" "next"
            , match pending.Tui_decode.gp_retry_request with
              | Some _ -> say "R:자동 판정 재시도  y/n:지금 결정" "R:retry Auto Judge  y/n:decide now"
              | None ->
                  say "y/n:지금 결정 (이 시도는 재실행 불가)"
                    "y/n:decide now (cannot replay this attempt)" )
          ]
        | Gate_human_required ->
          (* Auto Judge handed the row over with its reasons; the person
             deciding reads them here instead of guessing why. *)
          (match pending.Tui_decode.gp_judge_advice with
           | Some advice ->
             ( say "판정 의견" "judge said", Terminal_text.single_line advice.rationale )
             :: List.mapi
                  (fun index question ->
                     ((if index = 0 then say "확인 질문" "asks" else ""), Terminal_text.single_line question))
                  advice.key_questions
           | None -> [])
        | Gate_queued | Gate_judging -> []
      in
      let fields = [ say "도구" "tool", pending.Tui_decode.gp_display_tool
      ; say "키퍼" "keeper", pending.Tui_decode.gp_keeper
      ; say "상태" "state", phase
      ]
      @ blocked_fields
      @ [
        ( say "작업" "operation", pending.Tui_decode.gp_operation )
      ; ( say "샌드박스" "sandbox"
        , Terminal_text.single_line_or ~default:(say "(미기록)" "(not recorded)")
            pending.Tui_decode.gp_execution_sandbox )
      ; ( say "작업 디렉터리" "working directory"
        , Terminal_text.single_line_or ~default:(say "(미기록)" "(not recorded)")
            pending.Tui_decode.gp_execution_cwd )
      ]
      in
      let fields, input = match pending.Tui_decode.gp_input_rows with
         | Tui_decode.Rows (_ :: _ as input_fields) ->
           fields, Some input_fields
         | Tui_decode.Rows [] ->
           fields @ [ say "입력" "input", say "(저장된 입력 객체가 비어 있음)" "(the stored input object is empty)" ], None
         | Tui_decode.Flattened preview ->
           fields @ [ ( say "입력 (평탄화 미리보기 · 일부 생략 가능)" "input (flattened preview, may be cut)"
             , Terminal_text.single_line_or
                 ~default:(say "(서버에 기록된 입력 미리보기 없음)" "(the server recorded no input preview)") preview )
           ], None in
      fields, input, [say "승인 ID" "approval", pending.Tui_decode.gp_id]
    | Masc_tui_approvals_model.Operator_row a ->
      ([ say "요약" "summary", a.Masc_tui_operator_projection.ap_summary
      ; say "주체" "actor", a.Masc_tui_operator_projection.ap_actor
      ; say "동작" "action", a.Masc_tui_operator_projection.ap_action_type
      ; say "대상" "target", a.Masc_tui_operator_projection.ap_target_type
      ; say "페이로드" "payload",
        Masc_tui_operator_projection.approval_payload_document_for_terminal
          a.Masc_tui_operator_projection.ap_payload
      ], None,
      [ say "대상 ID" "target id", Terminal_text.single_line_or ~default:(say "(미기록)" "(not recorded)") a.ap_target_id
      ; say "생성 시각" "created", Terminal_text.short_timestamp a.ap_created_at
      ; say "만료 시각" "expires", (match Terminal_text.optional_single_line a.ap_expires_at with
          | None -> Masc_tui_theme.Glyph.no_value
          | Some at -> Terminal_text.short_timestamp at)
      ; say "추적 ID" "trace", a.ap_trace_id
      ])
  in
  let lines =
    List.map (fun line -> Field_line line) (Approval_detail.of_fields ~width fields)
    @ (match gate_fields with
       | None -> []
       | Some fields ->
         let string_reading = match value_hint with
           | Masc_tui_keys.No_value_reading | Readable_values -> Approval_detail.Readable_string
           | Byte_values -> Approval_detail.Exact_string_bytes in
         Approval_detail.of_gate_fields ~string_reading ~width fields
         |> List.map (fun line -> Gate_line line))
    @ List.map (fun line -> Field_line line) (Approval_detail.of_fields ~width identifiers)
    @ List.map (fun line -> Field_line line)
        (Approval_detail.of_fields ~width
          (approval_source_notices state ~reading:(Masc_tui_approvals_model.approvals_reading state)
           |> List.map (fun (_, text) -> say "조회 상태" "read status", text)))
  in
  let input_unreadable =
    List.exists
      (function
        | Field_line line -> line.unreadable
        | Gate_line line -> line.gate_origin = Approval_detail.Gate_unreadable)
      lines
  in
  let key_has_bytes =
    List.exists
      (function
        | Field_line _ -> false
        | Gate_line line ->
          (match line.gate_origin with
           | Approval_detail.Gate_key_with_bytes _ -> true
           | Gate_key | Gate_key_continuation | Gate_key_with_bytes_continuation _
           | Gate_key_bytes _ | Gate_key_bytes_continuation _
           | Gate_string | Gate_string_bytes | Gate_json | Gate_unreadable -> false))
      lines
  in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let action_inflight = Masc_tui_operator_projection.Flow.action_inflight state.approval_flow in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"approvals-action" ~now
      (if action_inflight then Some "approval-action" else None)
  in
  let progress_sheet =
    if not action_inflight then None
    else
      Some
        { ps_title = say "승인 요청 처리 중" "Submitting approval decision"
        ; ps_detail = Some (say "서버에서 승인/거절 결정을 처리하고 있습니다" "Processing approval decision on server")
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint = Some (say "Esc:목록" "Esc:back")
        ; ps_blocking = true
        }
  in
  let raw_content_height = max 1 (rows - max 0 (framed_chrome_rows - 2)) in
  let sheet_lines =
    match progress_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:raw_content_height
          ~width:(framed_inner_width cols) sheet
  in
  let content_height = max 0 (raw_content_height - List.length sheet_lines) in
  let total = List.length lines in
  viewport := Some
    { adv_count = total; adv_height = content_height;
      adv_presentation = (match value_hint with
        | Masc_tui_keys.Byte_values -> Approval_string_bytes
        | No_value_reading | Readable_values -> Approval_text) };
  let scroll =
    Masc_tui_scroll.normalize ~count:total ~height:content_height
      state.approval_detail_scroll
  in
  (* The pane is where the field count and the drawn height meet, so the row
     it could actually use is reported back rather than recomputed outside. *)
  clamped := scroll;
  (* Keep the numbered-key legend visible while scrolling; unreadable input
     takes precedence over it. The footer owns the way out. The pane
     scrolls, and an operator who reads the first screen as the whole ask
     could press y on it: the title row's position says there is more. *)
  box_line buf cols
    (zone_two_title ~cols state
       ~position:(Masc_tui_value.Position.window ~first:scroll ~shown:content_height ~total)
       ~title:(fun ~cols:_ ->
         let base =
           screen_title
             (if input_unreadable then say "!창 넓히기 필요 · 승인" "!WIDEN Approval"
              else match value_hint, key_has_bytes with
                | Masc_tui_keys.No_value_reading, false -> say " 승인 상세" " Approval"
                | No_value_reading, true -> say "*N=bN 바이트 | 승인" "*N=bN bytes | Approval"
                | Readable_values, false -> say "v:바이트 | 최상위 문자열" "v:bytes | top-level strings"
                | Readable_values, true -> say "v:바이트 *N=bN | 승인" "v:bytes *N=bN | Approval"
                | Byte_values, false -> say "v:텍스트 | 최상위 문자열 바이트" "v:text | top-level string bytes"
                | Byte_values, true -> say "v:텍스트 *N=bN | 최상위 문자열" "v:text *N=bN | top-level strings")
         in
         match progress_sheet with
         | None -> base
         | Some sheet ->
             base ^ "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title));
  box_divider buf cols;
  let drawn =
    lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun line ->
      let label, text, prefix =
        match line with
        | Field_line line -> line.label, line.text, ""
        | Gate_line line -> line.gate_label, line.gate_text, Approval_detail.prefix line.gate_origin
      in
      let content_width = max 0 (framed_inner_width cols - 2 - String.length prefix) in
      match label with
      | Some label ->
        (* The name is bold, what sits beside it is not: the row carries both
           now, and bolding the whole of it would weight the value too. *)
        let drawn = fit_width text content_width in
        let name = String.length label in
        (* Split only where the whole name survived the cut. A narrow pane
           can end the row inside the name, and [fit_width]'s ellipsis is
           three bytes: splitting at the name's byte length there would cut
           the ellipsis and send half a character to the terminal. *)
        box_line buf cols
          (if String.starts_with ~prefix:label drawn then
             Printf.sprintf "  %s%s%s%s%s" prefix Ansi.bold label Ansi.reset
               (String.sub drawn name (String.length drawn - name))
           else Printf.sprintf "  %s%s%s%s" prefix Ansi.bold drawn Ansi.reset)
      | None ->
        box_line buf cols (Printf.sprintf "  %s%s" prefix (fit_width text content_width)))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;
  List.iter (box_line buf cols) sheet_lines
;;

(* The queue stays beside the ask. Reading one used to hide the rest, and the
   rest is what tells an operator whether this one is the urgent one. *)
(* Who asked, beside what they asked for. The label was the tool alone, and a
   queue holds one row per held call. Many calls can name the same tool while
   different Keepers wait. The full-width list row beside this pane already
   draws the asker; only the index dropped it.

   The asker goes after the tool because the pane folds a label from the
   middle and keeps its tail (Render_schedule.sidebar_row_label). *)
let approval_sidebar_label (row : Masc_tui_approvals_model.approval_row) =
  let about, apart =
    match row with
    | Masc_tui_approvals_model.Keeper_tool_row held ->
      held.Tui_decode.kta_tool, held.Tui_decode.kta_keeper
    | Masc_tui_approvals_model.Gate_row pending ->
      pending.Tui_decode.gp_display_tool, pending.Tui_decode.gp_keeper
    | Masc_tui_approvals_model.Operator_row item -> item.ap_action_type, item.ap_actor
  in
  Render_schedule.sidebar_row_label ~about ~apart:(Some apart)

let render_approval_detail (state : state) (row : Masc_tui_approvals_model.approval_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll = ref state.approval_detail_scroll in
  let viewport = ref None in
  let value_hint =
    if not (Masc_tui_approvals_model.value_reading_available state row) then
      Masc_tui_keys.No_value_reading
    else if Option.is_some (Masc_tui_approvals_model.current_value_reading state) then
      Masc_tui_keys.Byte_values
    else Masc_tui_keys.Readable_values in
  (if cols < keeper_split_threshold_cols then
      approval_detail_pane state ~value_hint ~clamped:scroll ~viewport ~rows ~cols row buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* Not "Asks": this surface already calls a Keeper's question to a human
         an ask, and these rows are the confirmations waiting on an operator. *)
      (* The actor filter hides entries rather than paging past them, and
         the surface's own title already carries "hidden N". *)
      write_list_sidebar ~framed:false left_buf ~rows ~cols:left_cols
        ~title:(ui_text state ~ko:"승인" ~en:"Approvals")
        ~holding:None
        ~focused:false
        ~labels:(List.map approval_sidebar_label (Masc_tui_approvals_model.approval_items state))
        ~selected:state.approval_cursor;
      approval_detail_pane state ~value_hint ~clamped:scroll ~viewport ~rows
        ~cols:(cols - left_cols) row right_buf;
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf
    end);
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_approval_detail ~lang:state.ui_language
              ~value_hint));
  finish_surface state ~clamped:(Approval_detail_scroll (!scroll, !viewport))
    ~surface_key:"approval-detail" ~rows:terminal_rows ~cols buf

(* Six cells hold [Message_layout.span_text]'s widest reading ("99d23h"), the
   same cell the Board and Keeper roster ages take. *)
let ask_age_cells = 6

(* The asks cut off below the list. The queue and the selected ask's
   summary list both end with this row, so both write it one way: the
   cut-off count (RFC tui-one-screen-grammar 6.3, never "+N") and the keys
   that reach the rest. *)
let more_asks_text (state : state) count =
  let ko = state.ui_language = Lang_ko in
  Masc_tui_value.Count.more ~ko count ^ (if ko then " · [/]: 이동" else " · [/] to reach")

(* A folded Ask leads with its first original question. The asker, age and
   additional-question count distinguish it without opening an answer editor. *)
let ask_summary_line state ~cols ~now ~(row : Masc.Tui_decode_asks.ask_row) =
  let count = List.length row.Masc.Tui_decode_asks.ar_questions in
  let prompt = match row.Masc.Tui_decode_asks.ar_questions with
    | question :: _ -> Terminal_text.single_line question.aq_prompt
    | [] -> ui_text state ~ko:"질문 없음" ~en:"no questions" in
  let context =
    Printf.sprintf "%s  %s%s"
      (fit_width (Terminal_text.single_line (Masc.Tui_decode_asks.ask_asker_label row.ar_asker)) 16)
      (fit_width
         (Option.value ~default:"" (Message_layout.age_text ~now ~since:row.ar_asked_at))
         ask_age_cells)
      (if count > 1 then
         " · " ^ Masc_tui_value.Count.more ~ko:(state.ui_language = Lang_ko) (count - 1)
       else "") in
  let width = max 1 (framed_inner_width cols - Message_layout.display_width context - 3) in
  Printf.sprintf " %s%s  %s%s" (Theme.recede ()) (fit_width prompt width) context Ansi.reset

(* Keep the original strings until the reader sanitizes and wraps them.
   Compact rendering and the immutable reader share the same receipt facts. *)
let ask_answer_feedback_document (state : state) =
  let module Decode = Masc.Tui_decode_asks in
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  Option.map (fun feedback ->
    let fields = ref [] in
    let emit heading style body =
      let section : Masc_tui_detail_reading.section = {heading; body} in
      fields := (section, style) :: !fields in
    let followup = Masc_tui_types.current_ask_followup state in
    let delivered ~already = function
      | Decode.Ask_wake_stored ->
          (if already then say "기존 답변 유지 · 깨우기 기록됨" "Existing answer retained · wake recorded"
           else say "답변 저장됨 · 깨우기 기록됨" "Answer saved · wake recorded"), Theme.info (),
          (match followup with
           | None -> Some (say "키퍼 활동 화면에서 작업 재개 여부를 확인할 수 있습니다."
                             "Keeper activity shows whether work has resumed.")
           | Some _ -> None)
      | Decode.Ask_wake_pending detail ->
          (if already then say "기존 답변 유지 · 초기 전달 대기 중" "Existing answer retained · initial delivery pending"
           else say "답변 저장됨 · 초기 전달 대기 중" "Answer saved · initial delivery pending"), Theme.warn (), Some detail in
    let status, style, detail = match feedback.Ask_projection.af_receipt with
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_recorded delivery)) -> delivered ~already:false delivery
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_already_recorded { aar_delivery; _ })) ->
          delivered ~already:true aar_delivery
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_written_unconfirmed detail)) ->
          say "채택 답변 미확정 · 로그 기록됨" "Winning answer unconfirmed · log written", Theme.warn (), Some detail
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_refused detail))
      | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_refused detail)) ->
          say "답변 거부됨" "Answer refused", Theme.bad (), Some detail
      | Ok (Decode.Installation_answer_receipt Decode.Installation_answer_recorded) ->
          say "답변 저장됨 · 설치가 다음 호스트 요청 주기에 읽습니다"
            "Answer saved · installation reads it on its next host request cycle", Theme.info (), None
      | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_already_answered _)) ->
          say "이전 답변이 유지됩니다" "An earlier answer stands", Theme.info (), None
      | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_withdrawn _)) ->
          say "설치가 질문을 철회했습니다" "Installation withdrew the question", Theme.warn (), None
      | Error (Ask_projection.Answer_unconfirmed detail) ->
          say "답변 기록 미확정" "Answer recording unconfirmed", Theme.warn (), Some detail
      (* Not sent: the kept-back notice alone, never an unconfirmed
         recording (RFC §2). *)
      | Error (Ask_projection.Answer_kept_back notice) -> notice, Theme.bad (), None in
    emit (say "기록 결과" "Recording") style status;
    emit (say "질문" "Question") Ansi.dim
      (Decode.ask_asker_label feedback.af_asker
       ^ say "\n질문 ID: " "\nAsk ID: " ^ feedback.af_ask_id);
    Option.iter (emit (say "기록된 답변 라벨" "Recorded answer label") Ansi.dim) feedback.af_submitted_label;
    Option.iter (emit (say "기록 상세" "Recording details") (Theme.warn ())) detail;
    (match feedback.af_asker with
     | Decode.Ask_keeper _ ->
         let source = match feedback.af_source_turn_ref with
           | None -> say "원본 질문 턴: 기록 없음" "Original asking turn: not recorded"
           | Some reference ->
               say "원본 질문 턴:\n" "Original asking turn:\n"
               ^ Yojson.Safe.pretty_to_string (Ids.Turn_ref.to_yojson reference) in
         emit (say "원본 질문 턴" "Original asking turn") Ansi.dim source
     | Decode.Ask_installation { ai_title; _ } ->
         emit (say "설치" "Installation") Ansi.dim
           ((if ko then Printf.sprintf "Esc:돌아가기 후 g:%s 결과 열기\n" ai_title
             else "Esc:return, then g:open " ^ ai_title ^ " Results\n")
            ^ Yojson.Safe.pretty_to_string (Ask_projection.asker_to_json feedback.af_asker)));
    Option.iter (fun reading ->
      let observed = Ask_projection.followup_view reading in
      let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
      let source_notice source = match source.Ask_projection.fo_state with
        | Followup_pending ->
            (match source.fo_value with None -> "" | Some _ -> " · " ^ under_way ^ " " ^ say "최신 조회 중" "reading latest")
        | Followup_received -> ""
        | Followup_unconfirmed ->
            (match source.fo_value with None -> ""
             | Some _ -> say " · 이전 관측 · 최신 출처 미확인" " · earlier observation; latest source unconfirmed") in
      let source_style source observed = match source.Ask_projection.fo_state with
        | Followup_unconfirmed -> Theme.warn ()
        | Followup_pending -> Theme.info ()
        | Followup_received -> observed in
      let absent source label = match source.Ask_projection.fo_state with
        | Followup_pending -> under_way ^ " " ^ label ^ say ": 조회 중" ": reading", Theme.info ()
        | Followup_received -> label ^ say ": 관측 불가" ": observation unavailable", Theme.warn ()
        | Followup_unconfirmed -> label ^ say ": 최신 출처 미확인" ": latest source unconfirmed", Theme.warn () in
      Option.iter (fun identity ->
        emit (say "원본 답변 식별자" "Original answer identity") Ansi.dim
          (Yojson.Safe.pretty_to_string (`Assoc [
            "answered_at", `Float identity.Decode.afi_answered_at;
            "stimulus_id", `String identity.afi_stimulus_id]))) observed.fv_identity;
      (match observed.fv_reactions.fo_value with
       | None ->
           let text, style = absent observed.fv_reactions (say "키퍼 깨우기/턴" "Keeper wake/turn") in
           emit (say "키퍼 후속 반응" "Keeper follow-up") style text
       | Some Decode.Ask_reactions_unavailable ->
           emit (say "키퍼 후속 반응" "Keeper follow-up") (Theme.warn ())
             (say "깨우기/턴 관측 불가" "Wake/turn observation unavailable" ^ source_notice observed.fv_reactions)
       | Some (Ask_reactions_observed reactions) ->
           let facts = List.filter_map Fun.id
             [Option.map (fun _ -> say "턴 시작 관측" "turn entry observed") reactions.ar_turn_started_at;
              Option.map (fun _ -> say "턴 종료 관측" "turn boundary observed") reactions.ar_turn_finished_at;
              Option.map (fun _ -> say "깨우기 정산/전달됨 (소비 미증명)" "wake settled or transferred (consumption unproven)") reactions.ar_queue_settled_at;
              Option.map (fun _ -> say "깨우기 취소됨" "wake cancelled") reactions.ar_queue_cancelled_at] in
           let facts = if facts=[] then [say "관측된 턴 시작 없음" "no turn entry observed"] else facts in
           let facts = if reactions.ar_evidence_complete then facts else facts @ [say "근거 불완전" "evidence incomplete"] in
           let facts = if reactions.ar_evidence_current then facts
             else facts @ [say "일부 이전 관측 미확정" "some earlier observations remain unconfirmed"] in
           emit (say "키퍼 후속 반응" "Keeper follow-up")
             (source_style observed.fv_reactions
               (if reactions.ar_evidence_complete && reactions.ar_evidence_current
                then Theme.info () else Theme.warn ()))
             (String.concat " · " facts ^ source_notice observed.fv_reactions));
      let action_text, action_style = match observed.fv_tools.fo_value with
        | None -> absent observed.fv_tools (say "도구 결과" "Tool results")
        | Some Decode.Ask_tools_unavailable -> say "관측 불가" "Observation unavailable", Theme.warn ()
        | Some (Decode.Ask_tools_observed {at_count;at_outcomes;at_evidence_current;_}) ->
            let counts = List.filter_map (fun (label,count) ->
                if count=0 then None else Some (Printf.sprintf "%s %d" label count))
              [say "성공" "succeeded",at_outcomes.ato_succeeded;
               say "실패" "failed",at_outcomes.ato_failed;
               say "보류" "deferred",at_outcomes.ato_deferred;
               say "미확정" "unsettled",at_outcomes.ato_unsettled;
               say "형식오류" "malformed",at_outcomes.ato_malformed] in
            let text = if at_count=0 then say "관측 없음" "None observed"
              else Printf.sprintf
                (if ko then "%d건 관측 · %s" else "%d observed · %s")
                at_count (String.concat " · " counts) in
            let uncertain = at_outcomes.ato_failed>0 || at_outcomes.ato_unsettled>0 || at_outcomes.ato_malformed>0 in
            if at_evidence_current then text, (if uncertain then Theme.warn () else Theme.info ())
            else text ^ say " · 이전 근거 유지" " · retained earlier evidence", Theme.warn () in
      emit (say "도구 결과" "Tool results") (source_style observed.fv_tools action_style)
        (action_text ^ source_notice observed.fv_tools);
      (match observed.fv_tools.fo_value with
       | Some (Decode.Ask_tools_observed {at_latest=Some latest;at_evidence_current;_}) ->
           let style = match latest.ata_outcome with
             | Tool_result.Recorded_failed when at_evidence_current -> Theme.bad ()
             | Recorded_succeeded | Recorded_deferred when at_evidence_current -> Theme.info ()
             | Recorded_failed | Recorded_succeeded | Recorded_deferred
             | Recorded_unsettled | Recorded_malformed -> Theme.warn () in
           emit (say "최근 도구 결과" "Latest Tool result") style
             (Printf.sprintf
                (if ko then "%s · %s · #%d턴" else "%s · %s · turn #%d")
                (Tool_result.recorded_call_outcome_to_string latest.ata_outcome)
                latest.ata_tool latest.ata_keeper_turn_id)
       | None | Some Decode.Ask_tools_unavailable | Some (Ask_tools_observed {at_latest=None;_}) -> ());
      let task_text, task_style = match observed.fv_task.fo_value with
        | None -> absent observed.fv_task (say "원본 태스크" "Original Task")
        | Some Decode.Ask_task_unlinked -> say "연결된 태스크 없음" "No linked Task", Theme.recede ()
        | Some (Ask_task_missing id) -> id ^ say ": 조회 결과에 없음" ": not observed in lookup", Theme.warn ()
        | Some (Ask_task_unavailable id) -> id ^ say ": 관측 불가" ": observation unavailable", Theme.warn ()
        | Some (Ask_task_observed {akt_task_id;akt_location;akt_status;akt_evidence_current;akt_observed_at=_}) ->
            let phase = match akt_status with
              | Masc_domain.Todo -> say "대기" "to do"
              | Claimed {assignee;_} -> say "할당됨: " "claimed by " ^ assignee
              | InProgress {assignee;_} -> say "진행 중: " "in progress by " ^ assignee
              | AwaitingVerification {verification_id;_} -> say "검증 대기: " "awaiting verification " ^ verification_id
              | Done {assignee;_} -> say "완료: " "done by " ^ assignee
              | Cancelled {cancelled_by;_} -> say "취소됨: " "cancelled by " ^ cancelled_by in
            let location = match akt_location with
              | Decode.Ask_task_backlog -> "" | Ask_task_archive -> say " · 보관됨" " · archived" in
            let freshness = if akt_evidence_current then ""
              else say " · 마지막 관측 · 최신 미확인" " · last observed; not freshly confirmed" in
            akt_task_id ^ ": " ^ phase ^ location ^ freshness,
            (if akt_evidence_current then Theme.info () else Theme.warn ()) in
      emit (say "원본 태스크" "Original Task") (source_style observed.fv_task task_style)
        (task_text ^ source_notice observed.fv_task);
      (match observed.fv_identity, observed.fv_task.fo_value with
       | Some _, Some (Decode.Ask_task_missing _ | Ask_task_unavailable _ | Ask_task_observed _) ->
           emit (say "원본 태스크 보기" "Original Task reader") (Theme.info ())
             (say "Esc:돌아가기 후 T:원본 태스크·이력·검증 근거 확인"
                "Esc:return, then T:inspect original Task, history, and verification evidence")
       | Some _, (Some Decode.Ask_task_unlinked | None)
       | None, (Some _ | None) -> ())) followup;
    Option.iter (fun failure ->
      emit (say "후속 조회 미완료" "Follow-up read incomplete") (Theme.warn ())
        (say "완료된 출처 유지\n" "Completed sources retained\n" ^ Ask_projection.followup_failure_text failure)) state.ask_followup_error;
    List.rev !fields) (Masc_tui_types.current_ask_answer_feedback state)

let answer_feedback_reading (state : state) =
  Option.map (fun fields ->
    Masc_tui_detail_reading.create ~ko:(state.ui_language = Lang_ko)
      ~title:(ui_text state ~ko:"마지막 답변 결과" ~en:"Last answer")
      (List.map fst fields)) (ask_answer_feedback_document state)

let draw_ask_answer_feedback buf cols state =
  match ask_answer_feedback_document state with
  | Some ((section, style) :: _) ->
      box_line buf cols ("  v: " ^ style ^ Terminal_text.single_line section.body ^ Ansi.reset)
  | Some [] | None -> ()

let draw_compact_ask_origin buf cols state =
  Option.iter (fun (origin : Ask_projection.origin) ->
    let turn = match origin.ao_source_turn_ref with
      | None -> ui_text state ~ko:" · 원본 턴 기록 없음" ~en:" · original turn not recorded"
      | Some reference ->
          Printf.sprintf
            (if state.ui_language = Lang_ko then " · #%d턴" else " · turn #%d")
            (Ids.Turn_ref.absolute_turn reference) in
    box_line buf cols
      (Ansi.dim ^ ui_text state ~ko:"  o/O 출처: " ~en:"  o/O source: "
       ^ Terminal_text.single_line (origin.ao_keeper_name ^ turn ^ " · " ^ origin.ao_ask_id)
       ^ Ansi.reset)) (Masc_tui_types.current_ask_origin state)

(* Copy complete terminal rows from the original safe question rendering.
   Do not cut an ANSI/UTF-8 sequence, reflow the prompt or borrow choice/draft
   state from another question. This preview does not enter answering mode. *)
let draw_ask_question_preview buf cols ~ko ~rows text =
  let length = String.length text in
  let prompt_rows = if rows > 1 then rows - 1 else rows in
  let rec copy offset remaining =
    if remaining > 0 && offset < length then
      match String.index_from_opt text offset '\n' with
      | Some stop ->
          Buffer.add_substring buf text offset (stop - offset + 1);
          copy (stop + 1) (remaining - 1)
      | None ->
          Buffer.add_substring buf text offset (length - offset);
          Buffer.add_char buf '\n'
  in
  copy 0 prompt_rows;
  if rows > 1 then
    box_line buf cols
      (Ansi.dim
       ^ (if ko then "    … a: 전체 질문 열기 및 답변"
          else "    … a opens the full ask and answers")
       ^ Ansi.reset)

let draw_ask_questions buf cols (state : state) ~budget =
  let now = Unix.gettimeofday () in
  (* Questions Keepers put to a human sit under the approval queue rather than
     in it. Nothing is held waiting on them -- the Keeper that asked kept
     working -- so they are not a queue of blocked calls, but an operator
     deciding things belongs in one place either way. *)
  let answering_ask =
    match state.ask_answer_mode with
    | Ask_answering { aam_ask } -> Some aam_ask
    | Ask_browsing -> None
  in
  match Masc_tui_approvals_model.approvals_open_questions state with
  | None -> ()
  | Some open_rows -> (
      box_divider buf cols;
      (* The warning colour says someone is waiting. With nobody waiting the
         heading drew it anyway, over a line that reads "none", so the one
         row on the screen asking for attention was the one with nothing to
         ask. *)
      let heading_tone =
        match open_rows with
        | [] -> Theme.recede ()
        | _ :: _ -> Ansi.bold ^ Theme.warn ()
      in
      (* [a] opens the question under the cursor. With none under it the key
         answers "Choose a question with [ or ] first", so the heading names it
         only while one is selected, in the footer's words. *)
      let selected_index = Ask_projection.selected_index open_rows state.ask_cursor in
      let answer_hint =
        if Option.is_some selected_index then
          " · " ^ Masc_tui_keys.approval_answer_hint_for ~lang:state.ui_language
        else ""
      in
      (* The section follows the screen language, as the queue above it does
         (RFC tui-one-screen-grammar section 5.1). *)
      let count = Masc_tui_approvals_model.approvals_open_question_count state in
      box_line buf cols
        ("  " ^ heading_tone
         ^ (if state.ui_language = Lang_ko
            then Printf.sprintf "[?] 답을 기다리는 질문 %d" count
            else Printf.sprintf "[?] Questions waiting on you (%d)" count)
         ^ answer_hint ^ Ansi.reset);
      match open_rows with
      | [] ->
          box_line buf cols
            ("  " ^ Ansi.dim
             ^ ui_text state ~ko:"결정을 기다리는 키퍼 없음"
                 ~en:"none · nobody is waiting on a decision"
             ^ Ansi.reset)
      | rows ->
          (* Only the ask under the cursor keeps its questions; every other one
             folds to a line. Before this the panel drew all of them and the
             surface, which puts this block last, dropped whatever ran past its
             budget -- an ask of four questions was enough to push the rest off
             the bottom, the cursor with it, so [/] and j/k moved a selection
             nothing on screen showed. *)
          match selected_index with
          | None ->
              (* The selected ask left the list. No ask is drawn open, because
                 an open ask here is the one the next keys would answer. *)
              box_line buf cols
                ("  " ^ Ansi.dim
                 ^ ui_text state ~ko:"고른 질문 없음 · [/]: 질문 고르기"
                     ~en:"nothing selected · [ or ] chooses a question"
                 ^ Ansi.reset);
              let count = List.length rows in
              let room = max 0 (budget - count_frame_lines buf) in
              let shown = if count <= room then count else max 0 (room - 1) in
              List.iteri
                (fun index row -> if index < shown then box_line buf cols (ask_summary_line state ~cols ~now ~row))
                rows;
              if shown < count then
                box_line buf cols
                  ("  " ^ Ansi.dim
                   ^ more_asks_text state (count - shown)
                   ^ Ansi.reset)
          | Some cursor ->
          let count = List.length rows in
          let selected = List.nth rows cursor in
          let draft = Ask_projection.draft_for state.ask_draft ~row:selected in
          let answering =
            match answering_ask with
            | Some ask -> Masc.Tui_decode_asks.(equal_ask_key ask (ask_key selected))
            | None -> false
          in
          let questions = Array.of_list selected.Masc.Tui_decode_asks.ar_questions in
          let question_count = Array.length questions in
          let question_cursor =
            max 0 (min state.ask_question_cursor (question_count - 1))
          in
          let text_entry = state.ask_text_entry in
          (* Each lazy cell is private to this synchronous draw. The layout
             and emission below are its only force sites; no cell/provider
             escapes to a fiber, worker or later frame. Capture original
             immutable inputs rather than mutable UI state in the cells. *)
          let ko = state.ui_language = Lang_ko in
          let question_blocks =
            Array.mapi
              (fun index question ->
                lazy (ask_block (fun b ->
                    draw_ask_question ~ko b cols ~text_entry ~row:selected ~draft ~question
                      ~answering
                      ~selected_question:(index = question_cursor))))
              questions
          in
          let question_block index = Stdlib.Lazy.force question_blocks.(index) in
          let context_block =
            lazy (ask_block (fun b -> draw_ask_context ~ko b cols ~row:selected))
          in
          let plan =
            Ask_layout.plan ~budget ~spent:(count_frame_lines buf)
              ~question_count ~question_height:(fun index -> snd (question_block index))
              ~question_cursor
              ~context_height:(fun () -> snd (Stdlib.Lazy.force context_block))
              ~other_asks:(count - 1)
          in
          for index = plan.Ask_layout.question_start to
              plan.Ask_layout.question_start + plan.Ask_layout.questions_shown - 1 do
            let text, _ = question_block index in
            if plan.Ask_layout.question_preview_rows > 0 then
              draw_ask_question_preview buf cols
                ~ko:(state.ui_language = Lang_ko)
                ~rows:plan.Ask_layout.question_preview_rows text
            else Buffer.add_string buf text
          done;
          if plan.Ask_layout.question_notice then
            box_line buf cols
              (* "in this ask", because the count above names every question
                 the fleet is waiting on and this one names the selected
                 ask's own. Both said "questions", and a reader saw "(1)"
                 three rows above "+2 more questions". *)
              (Printf.sprintf
                 (if state.ui_language = Lang_ko then "    %s이 요청에 질문 %s개 더 있음 · a:전체 열기%s"
                  else "    %s%s in this ask · a opens the full ask%s")
                 Ansi.dim
                 (if state.ui_language = Lang_ko
                  then Masc_tui_value.Count.grouped plan.Ask_layout.questions_hidden
                  else Masc_tui_value.Count.more ~ko:false plan.Ask_layout.questions_hidden)
                 Ansi.reset);
          if plan.Ask_layout.context_shown then
            Buffer.add_string buf (fst (Stdlib.Lazy.force context_block))
          else if plan.Ask_layout.context_notice then
            (* The questions are the ask and the reason explains it, so the
               reason is what the plan drops first. It used to drop without a
               word: hidden questions are counted on a line of their own and
               folded asks are too, and only this one left no trace, so a
               reader had nothing to tell them there was a reason to go and
               read. The answering view draws it whole and scrolls. *)
            box_line buf cols
              (Printf.sprintf
                 (if state.ui_language = Lang_ko then "    %s배경 설명 생략됨 · a:전체 열기%s"
                  else "    %sthe reason did not fit · a opens it%s")
                 Ansi.dim Ansi.reset);
          let printed = ref 0 in
          List.iteri
            (fun index row ->
              if index <> cursor && !printed < plan.Ask_layout.summaries_shown
              then begin
                box_line buf cols (ask_summary_line state ~cols ~now ~row);
                incr printed
              end)
            rows;
          if plan.Ask_layout.summaries_hidden > 0 then
            box_line buf cols
              ("  " ^ Ansi.dim ^ more_asks_text state plan.Ask_layout.summaries_hidden
               ^ Ansi.reset))

(* The selected row's detail, and the only one of the three detail rows whose
   height depends on which kind is selected. A held tool call answers two
   questions -- what is being asked, and why it was held -- and the ask runs
   the width of the pane, so at eighty columns the two cannot share a row.

   Built here rather than inline so the surface draws it into the block it
   then measures with [count_frame_lines], which is where its height comes
   from.
   Until 2026-08-31 the second row was spelled as a literal ["\\n"] --
   backslash and n, printed as those two characters -- because a real newline
   would have drawn a row nobody counted. *)
let approvals_progress_sheet ~now (state : state) =
  let action_inflight = Masc_tui_operator_projection.Flow.action_inflight state.approval_flow in
  let action_started =
    Masc_tui_types.progress_clock_option state ~slot:"approvals-action" ~now
      (if action_inflight then Some "approval-action" else None)
  in
  let ask_started =
    Masc_tui_types.progress_clock_option state ~slot:"approvals-ask" ~now
      (if state.ask_submit_inflight then Some "ask-submit" else None)
  in
  if action_inflight then
    Some
      { ps_title = ui_text state ~ko:"승인 요청 처리 중" ~en:"Submitting approval decision"
      ; ps_detail =
          Some
            (ui_text state ~ko:"서버에서 승인/거절 결정을 처리하고 있습니다"
               ~en:"Processing approval decision on server")
      ; ps_started_at = action_started
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking = true
      }
  else if state.ask_submit_inflight then
    Some
      { ps_title = ui_text state ~ko:"질문 답변 제출 중" ~en:"Submitting answer"
      ; ps_detail =
          Some
            (ui_text state ~ko:"작성한 질문 답변을 서버로 전송하고 있습니다"
               ~en:"Sending your answer to the server")
      ; ps_started_at = ask_started
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking = true
      }
  else None
;;

let approval_detail_line (state : state) ~now ~started_at ~approvals ~cols ~action_inflight =
    let ko = state.ui_language = Lang_ko in
    let say korean english = if ko then korean else english in
    if action_inflight && Option.is_some (List.nth_opt approvals state.approval_cursor) then
      "  " ^ progress_inline ~ko ~now ?started_at
        (say "승인 요청 처리 중" "Approval request in progress")
    else
    match List.nth_opt approvals state.approval_cursor with
    | Some (Masc_tui_approvals_model.Operator_row a) -> (
        match state.pending_approval_action with
        | Some { paa_token; paa_decision }
          when String.equal paa_token a.ap_token ->
            let key =
              match paa_decision with
              | Confirm -> "y"
              | Deny -> "n"
            in
            let prefix =
              if ko then Printf.sprintf "%s 키를 한 번 더 누르세요: " key
              else Printf.sprintf "Press %s again: " key
            in
            let room =
              max 8 (framed_inner_width cols - 2 - Message_layout.display_width prefix)
            in
            Printf.sprintf "  %s%s%s%s" (Theme.warn ()) prefix
              (fit_width (Terminal_text.single_line a.ap_summary) room)
              Ansi.reset
        | _ ->
            let summary =
              fit_width (Terminal_text.single_line a.ap_summary) (max 8 (framed_inner_width cols - 30))
            in
            Printf.sprintf "  %s%s%s  %s%s%s"
              Ansi.dim summary Ansi.reset
              (Theme.info ()) (say "y:승인  n:거절" "y:approve  n:reject") Ansi.reset)
    | Some (Masc_tui_approvals_model.Keeper_tool_row held) ->
        Printf.sprintf "  %s%s%s  %s%s%s\n  %s%s%s%s"
          (Theme.warn ())
          (fit_width
             (Terminal_text.single_line held.kta_question)
             (max 8 (framed_inner_width cols - 24)))
          Ansi.reset
          (Theme.info ()) (say "y:허용  n:거부" "y:allow  n:deny") Ansi.reset
          Ansi.dim
          (say "사유: " "why: ")
          (fit_width
             (Terminal_text.single_line_or ~default:(say "(미제공)" "(not provided)")
                held.kta_because)
             (max 8 (framed_inner_width cols - 8)))
          Ansi.reset
    | Some (Masc_tui_approvals_model.Gate_row pending) ->
        let keeper =
          Terminal_text.single_line pending.Tui_decode.gp_keeper
        in
        let phase, tone = approval_gate_phase state pending.Tui_decode.gp_phase in
        let actions =
          "  " ^ (Theme.info ()) ^ say "y:승인  n:거절" "y:approve  n:reject" ^ Ansi.reset
        in
        let headline =
          Printf.sprintf "  %s%s → %s · %s%s%s"
            tone
            keeper
            (fit_width
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
               (max 8 (framed_inner_width cols - 52 - Message_layout.display_width keeper
                       - Message_layout.display_width phase)))
            phase
            Ansi.reset
            actions
        in
        (match pending.gp_phase with
         | Gate_blocked ->
             let detail =
               Terminal_text.single_line_or
                 ~default:(say "(서버에 기록된 상세 없음)" "(the server recorded no detail)")
                 pending.gp_auto_judge_detail
             in
             let next =
               match pending.gp_retry_request with
               | Some _ -> say "R:자동 판정 재시도  y/n:지금 결정" "R:retry Auto Judge  y/n:decide now"
               | None ->
                   say "y/n:지금 결정 (이 시도는 재실행 불가)"
                     "y/n:decide now (cannot replay this attempt)"
             in
             Printf.sprintf "%s\n  %s%s%s%s\n  %s%s%s"
               headline Ansi.dim
               (say "사유: " "reason: ")
               (fit_width detail (max 8 (framed_inner_width cols - 8))) Ansi.reset
               Ansi.dim (fit_width next (max 8 (framed_inner_width cols))) Ansi.reset
         | Gate_human_required ->
             (match pending.gp_judge_advice with
              | Some advice ->
                  Printf.sprintf "%s\n  %s%s%s%s"
                    headline Ansi.dim
                    (say "판정: " "judge: ")
                    (fit_width (Terminal_text.single_line advice.rationale) (max 8 (framed_inner_width cols - 7)))
                    Ansi.reset
              | None -> headline)
         | Gate_queued | Gate_judging -> headline)
    | None -> ""
;;

(* The selected request's decision context and input preview. Technical
   identifiers belong to the full reader; execution site, age and deadlines
   remain here. Pack clauses with the same measured rows the queue budgets. *)
let approval_metadata_lines (state : state) ~approvals ~cols =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let clauses, payload_line =
    match List.nth_opt approvals state.approval_cursor with
    | None -> [], ""
    | Some (Masc_tui_approvals_model.Operator_row approval) ->
        let expires =
          match Terminal_text.optional_single_line approval.ap_expires_at with
          | None -> Masc_tui_theme.Glyph.no_value
          | Some at -> Terminal_text.short_timestamp at
        in
        let payload =
          Masc_tui_operator_projection.approval_payload_for_terminal
            approval.ap_payload
        in
        let payload_label = say "페이로드=" "payload=" in
        ( [ Printf.sprintf (if ko then "생성=%s" else "created=%s")
              (Terminal_text.short_timestamp approval.ap_created_at)
          ; Printf.sprintf (if ko then "만료=%s" else "expires=%s") expires ]
        , Printf.sprintf "  %s%s%s%s" Ansi.dim payload_label
            (fit_width payload
               (max 8 (framed_inner_width cols - 2 - Message_layout.display_width payload_label)))
            Ansi.reset )
    | Some (Masc_tui_approvals_model.Keeper_tool_row held) ->
        let args_label = say "인자=" "args=" in
        ( [ Printf.sprintf (if ko then "키퍼=%s" else "keeper=%s")
              (Terminal_text.single_line held.kta_keeper)
          ; Printf.sprintf (if ko then "도구=%s" else "tool=%s")
              (Terminal_text.single_line (Masc.Tool_display.label held.kta_tool))
          ; Masc_tui_value.Ongoing.since ~now:(Unix.gettimeofday ()) held.kta_asked_at
            ^ ui_text state ~ko:" 대기" ~en:" waiting" ]
        , Printf.sprintf "  %s%s%s%s" Ansi.dim args_label
            (fit_width
               (Terminal_text.preview_line held.kta_args)
               (max 8 (framed_inner_width cols - 2 - Message_layout.display_width args_label)))
            Ansi.reset )
    | Some (Masc_tui_approvals_model.Gate_row pending) ->
        let site =
          match
            pending.Tui_decode.gp_execution_sandbox,
            pending.Tui_decode.gp_execution_cwd
          with
          | None, None -> []
          | sandbox, cwd ->
            [ Printf.sprintf (if ko then "샌드박스=%s" else "sandbox=%s")
                (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value sandbox)
            ; Printf.sprintf (if ko then "경로=%s" else "at=%s")
                (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value cwd) ]
        in
        let operation =
          let name = Terminal_text.single_line pending.Tui_decode.gp_operation in
          if String.equal name
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
          then []
          else [ Printf.sprintf (if ko then "작업=%s" else "operation=%s") name ]
        in
        let input_label = say "입력=" "input=" in
        ( operation @ site
          @ (match pending.gp_waiting_s with
             | None -> []
             | Some seconds -> [Masc_tui_value.Ongoing.text seconds
                 ^ ui_text state ~ko:" 경과" ~en:" old"])
        , Printf.sprintf "  %s%s%s%s" Ansi.dim input_label
            (fit_width
               (Terminal_text.single_line_or ~default:(say "(입력 미리보기 없음)" "(no input preview)")
                  pending.Tui_decode.gp_input_preview)
               (max 8 (framed_inner_width cols - 2 - Message_layout.display_width input_label)))
            Ansi.reset )
  in
  let metadata_rows =
    match clauses with
    | [] -> [ "" ]
    | clauses ->
        Message_layout.pack_clauses ~max_cells:(framed_inner_width cols) clauses
        |> List.map (fun row -> Printf.sprintf "  %s%s%s" Ansi.dim row Ansi.reset)
  in
  String.concat "\n" metadata_rows, payload_line
;;

let render_approvals (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let approvals = Masc_tui_approvals_model.approval_items state in
  let action_inflight =
    Masc_tui_operator_projection.Flow.action_inflight state.approval_flow
  in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let progress_sheet = approvals_progress_sheet ~now state in
  let started_at = Option.bind progress_sheet (fun s -> s.ps_started_at) in
  let detail_line =
    approval_detail_line state ~now ~started_at ~approvals ~cols ~action_inflight
  in
  let metadata_line, payload_line =
    approval_metadata_lines state ~approvals ~cols
  in

  let count = Masc_tui_approvals_model.approvals_surface_pending state in
  let reading = Masc_tui_approvals_model.approvals_reading state in
  let source_notices = approval_source_notices state ~reading in
  let count_text =
    if Masc_tui_approvals_model.approvals_reading_current state then
      Printf.sprintf (if state.ui_language = Lang_ko then "대기 %d" else "%d pending") count
    else Printf.sprintf (if state.ui_language = Lang_ko then
        "관측 %d · 조회 미확인 %d곳" else "%d observed · %d sources not current")
      count (List.length source_notices) in
  let hidden_note = match state.approval_snapshot with
    | Some snapshot when snapshot.aps_hidden_count > 0 ->
        Printf.sprintf (if state.ui_language = Lang_ko then ", 승인 %d개 숨김 · 필터 %s"
          else ", %d confirmations hidden · filter %s") snapshot.aps_hidden_count
          (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value snapshot.aps_actor_filter)
    | Some _ | None -> "" in
  let header =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"요청" ~en:"requests" ]
      ~readings:
        [ count_text ^ hidden_note
        ; (match progress_sheet with
           | Some sheet ->
               progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
           | None -> "") ]
      ~position:
        (match approvals with
         | [] -> None
         | _ :: _ ->
             Some
               (Masc_tui_value.Position.row ~selected:(Some state.approval_cursor)
                  ~total:(List.length approvals)))
  in
  box_line buf cols header;
  let policy_buf = Buffer.create 512 in
  (* Both Gate lanes are always on screen here. The durable rows obey the
     external lane, and an operator deciding them needs to see which switch
     they are under. The [e] that cycles the external lane is a footer key
     like any other: it reaches the footer and the [?] help through the
     Approvals row of Masc_tui_keys. *)
  (* A lane word this build does not know is drawn as the server wrote it,
     the same spelling the chat header and the Keeper detail draw. *)
  (* The command palette names a lane and a mode in English because its
     entries are what the operator types. On a Korean screen this row says the
     same two things in Korean; on an English one it shows the palette's own
     words. *)
  let lane_mode_label = function
    | Tui_decode.Gate_mode mode ->
        (match mode, state.ui_language with
         | Masc.Keeper_gate_mode.Manual, Lang_ko -> "매번 나에게 묻기"
         | Masc.Keeper_gate_mode.Auto_judge, Lang_ko -> "Auto Judge 가 판단"
         | Masc.Keeper_gate_mode.Always_allow, Lang_ko -> "검토 없이 모두 허용"
         | ( Masc.Keeper_gate_mode.Manual | Masc.Keeper_gate_mode.Auto_judge
           | Masc.Keeper_gate_mode.Always_allow ), Lang_en ->
             Masc_tui_palette.gate_mode_label mode)
    | Tui_decode.Unrecognised_gate_mode raw -> Terminal_text.single_line raw
  in
  let lane_word gate =
    match gate, state.ui_language with
    | Masc_tui_palette.Workspace_gate, Lang_ko -> "워크스페이스"
    | Masc_tui_palette.External_gate, Lang_ko -> "외부 서비스"
    | (Masc_tui_palette.Workspace_gate | Masc_tui_palette.External_gate), Lang_en ->
        Masc_tui_palette.gate_lane_label gate
  in
  (* The two lanes share a row while both fit. A narrower terminal gives each
     lane its own row, so a mode is not cut off in the middle of its words. *)
  let lane_rows modes =
    let lane ~key gate mode =
      Printf.sprintf "[%s] %s: %s" key (lane_word gate) (lane_mode_label mode)
    in
    let workspace =
      lane ~key:"w" Masc_tui_palette.Workspace_gate modes.Tui_decode.glm_workspace
    in
    let external_lane =
      lane ~key:"e" Masc_tui_palette.External_gate modes.Tui_decode.glm_external
    in
    let together = Printf.sprintf "  %s  |  %s" workspace external_lane in
    List.map
      (fun row -> Theme.info () ^ row ^ Ansi.reset)
      (if Message_layout.display_width together <= framed_inner_width cols
       then [ together ]
       else [ "  " ^ workspace; "  " ^ external_lane ])
  in
  List.iter (box_line policy_buf cols)
    (match state.gate_modes, Terminal_text.optional_single_line state.gate_error with
     | Some modes, _ -> lane_rows modes
     (* No prefix: [data_unreliable_row] already opens "(data unreliable: "
        and the loader's message already opens "gate load failed:", so a third
        "gate:" in front read as a stutter -- "(data unreliable: gate: gate
        load failed: ...)". Same rule the schedule warning is written to. The
        two rows below keep their prefixes because the detail there is the
        server's own sentence about the store, which does not name itself. *)
     | None, Some err -> [ data_unreliable_row ~cols err ]
     | None, None ->
         if server_authority_ready state then
           [ Theme.info () ^ "  " ^ Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way ^ " "
             ^ ui_text state ~ko:"Gate 설정: 조회 중" ~en:"Gate lanes: loading"
             ^ Ansi.reset ]
         else
           [ Ansi.dim
             ^ ui_text state ~ko:"  Gate 설정: 미조회" ~en:"  Gate lanes: unread"
             ^ Ansi.reset ]);
  (* Standing always-allow rules, on the row under the lanes. A rule answers
     its call before the call can reach the queue, so an operator reading an
     empty queue is reading the rules' work without seeing them. One row: the
     count, and who the newest one covers. *)
  box_line policy_buf cols
    (match state.gate_rules_unavailable, state.gate_rules with
     | Some detail, _ ->
         data_unreliable_row ~cols
           (ui_text state ~ko:"항상 허용 규칙: " ~en:"always-allow rules: " ^ detail)
     | None, [] ->
         Ansi.dim
         ^ ui_text state ~ko:"  항상 허용 규칙: 없음" ~en:"  Always-allow rules: none"
         ^ Ansi.reset
     | None, (newest :: _ as rules) ->
         Printf.sprintf
           (if state.ui_language = Lang_ko then
              "  %s항상 허용 규칙: %d개  ·  최근 %s / %s%s%s"
            else "  %sAlways-allow rules: %d  ·  newest %s / %s%s%s")
           Ansi.dim
           (List.length rules)
           (Terminal_text.single_line newest.Tui_decode.gr_keeper)
           (Terminal_text.single_line newest.Tui_decode.gr_tool)
           (match newest.Tui_decode.gr_expires_at with
            | Some _ -> ui_text state ~ko:" (만료 있음)" ~en:" (expires)"
            | None -> "")
           Ansi.reset);
  box_divider policy_buf cols;

  let footer_buf = Buffer.create 256 in
  Buffer.add_string footer_buf
    (footer_line state ~max_cells:cols ~hints:(question_hints state));
  let footer_rows = count_frame_lines footer_buf in
  let preview_minimum =
    if Option.is_some state.pending_approval_action || action_inflight then 1 else 0 in
  let base_head_rows = count_frame_lines buf + count_frame_lines policy_buf in
  (* Reserve the selected question, decision notice and footer first. Last
     answer/source summaries use only the remaining complete terminal rows;
     their full text stays available in the receipt/question readers. *)
  let question_room = max 0
      (rows - base_head_rows - footer_rows - 2 - preview_minimum) in
  let question_rows = min question_room
      (match Masc_tui_approvals_model.approvals_open_questions state with
       | None -> 0
       | Some [] -> 3
       | Some (_ :: _) -> 2 + Ask_layout.min_expanded_rows) in
  let intro_room = max 0 (question_room - question_rows) in
  let intro_buf = Buffer.create 256 in
  if intro_room > 0 then draw_ask_answer_feedback intro_buf cols state;
  if count_frame_lines intro_buf < intro_room then
    draw_compact_ask_origin intro_buf cols state;
  let intro_rows = count_frame_lines intro_buf in
  let primary_rows = 1 (* queue *) + 1 (* closing edge *) + footer_rows
      + intro_rows + question_rows + preview_minimum in
  let notice_room = max 0 (rows - base_head_rows - primary_rows) in
  List.iteri (fun index (style, text) ->
    if index < notice_room then box_line_styled buf cols ~style ("  " ^ text)) source_notices;
  Buffer.add_buffer buf policy_buf;
  let head_rows = count_frame_lines buf in
  let sheet_lines =
    match progress_sheet with
    | None -> []
    | Some sheet ->
        let sheet_avail = max 0 (rows - head_rows - footer_rows - 2 - intro_rows - question_rows) in
        render_progress_sheet ~ko ~now ~available:sheet_avail
          ~width:(framed_inner_width cols) sheet
  in
  let preview = Buffer.create 1024 in
  List.iter (fun line ->
    if not (String.equal line "") then Buffer.add_string preview (line ^ "\n"))
    [detail_line; metadata_line; payload_line];
  let preview_room = max 0 (rows - head_rows - footer_rows - 1 - 1 - intro_rows - question_rows - List.length sheet_lines) in
  let preview_count = count_frame_lines preview in
  let preview_notice = preview_count > preview_room && preview_room > 1 in
  let shown_preview = min preview_count (if preview_notice then preview_room - 1 else preview_room) in
  let below_buf = Buffer.create 1024 in
  List.iter (box_line below_buf cols) sheet_lines;
  box_bottom below_buf cols;
  let text = Buffer.contents preview in
  let rec copy_rows offset remaining =
    if remaining > 0 && offset < String.length text then
      match String.index_from_opt text offset '\n' with
      | Some stop ->
          Buffer.add_substring below_buf text offset (stop - offset + 1);
          copy_rows (stop + 1) (remaining - 1)
      | None ->
          Buffer.add_substring below_buf text offset (String.length text - offset);
          Buffer.add_char below_buf '\n'
  in
  copy_rows 0 shown_preview;
  if preview_notice then
    Buffer.add_string below_buf (Theme.recede ()
      ^ fit_width (ui_text state ~ko:"  Enter:요청 전체 읽기" ~en:"  Enter:read full request")
          (max 1 (framed_inner_width cols)) ^ Ansi.reset ^ "\n");
  let around_rows = head_rows + count_frame_lines below_buf + footer_rows in
  let ask_budget = max 0 (rows - around_rows - 1) in
  let ask_buf = Buffer.create 1024 in
  Buffer.add_buffer ask_buf intro_buf;
  draw_ask_questions ask_buf cols state ~budget:ask_budget;
  let ask_rows = count_frame_lines ask_buf in
  let approval_body_rows = max 0 (rows - around_rows - ask_rows) in

  (* The queue's own population, not the surface's. [count] above is the
     approval rows plus the open questions -- the right reading for the title,
     which names the screen -- and this block is about the three
     lists that hold approval rows. With the queue empty and a question
     waiting, [count] was three, so the list drew its empty self: a cursor
     mark on a blank row and nothing to say the queue was empty, where the
     same screen with no question at all said "(no pending approvals)".

     "(no pending approvals)" is itself a reading of all three lists. A Gate
     poll that failed after one that answered keeps its empty rows, so the
     queue is empty on screen while the server may hold Gate approvals; each
     list that was not read says so here instead. *)
  if approvals = [] then begin
    let lines =
      match Masc_tui_approvals_model.approvals_empty_queue ~ko:(state.ui_language = Lang_ko) reading with
      | Masc_tui_approvals_model.Nothing_pending ->
          [ Ansi.dim
            ^ ui_text state ~ko:"  (대기 중인 요청 없음)" ~en:"  (no pending approvals)"
            ^ Ansi.reset ]
      | Masc_tui_approvals_model.Lists_not_read not_read ->
          List.map
            (fun (name, (not_read : Masc_tui_approvals_model.approval_not_read)) ->
              match not_read with
              | Masc_tui_approvals_model.Approval_unread ->
                  Ansi.dim ^ "  (" ^ name
                  ^ ui_text state ~ko:" 미조회 · r로 새로고침)"
                      ~en:" not read yet · press 'r' to refresh)"
                  ^ Ansi.reset
              (* The loader's message already names what failed ("... load
                 failed: ..."), so the row carries it as it came. *)
              | Masc_tui_approvals_model.Approval_failed cause
              | Masc_tui_approvals_model.Approval_stale cause ->
                  data_unreliable_row ~cols (Terminal_text.single_line cause)
              | Masc_tui_approvals_model.Approval_unavailable detail ->
                  data_unreliable_row ~cols
                    (Printf.sprintf "%s %s: %s" name
                       (ui_text state ~ko:"사용 불가" ~en:"unavailable")
                       (Terminal_text.single_line detail))
              (* Never sent, so not unreliable data: the notice alone. *)
              | Masc_tui_approvals_model.Approval_kept_back notice ->
                  Theme.bad () ^ "  " ^ Terminal_text.single_line notice ^ Ansi.reset)
            not_read
    in
    let lines = List.take approval_body_rows lines in
    List.iter (fun line -> box_line buf cols line) lines;
    for _ = 1 to max 0 (approval_body_rows - List.length lines) do
      box_empty buf cols
    done
  end else begin
    (* Which row of the queue is selected, and of how many, is the title
       row's position, so a queue longer than its rows says so without
       spending one of them. *)
    let approval_total = List.length approvals in
    let show_header = approval_body_rows >= 3 in
    let content_height =
      if show_header then approval_body_rows - 2 else approval_body_rows
    in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    let approval_row_name = function
      | Masc_tui_approvals_model.Operator_row item -> Terminal_text.single_line item.ap_actor
      | Masc_tui_approvals_model.Keeper_tool_row held -> Terminal_text.single_line held.kta_keeper
      | Masc_tui_approvals_model.Gate_row pending -> Terminal_text.single_line pending.gp_keeper in
    (* The request keeps at least as much room as its author at narrow widths.
       Both columns are display-only; selection still addresses the original row. *)
    let phase_width = List.fold_left (fun widest -> function
      | Masc_tui_approvals_model.Gate_row pending ->
          max widest (Message_layout.display_width (fst (approval_gate_phase state pending.gp_phase)))
      | Keeper_tool_row _ | Operator_row _ -> widest) 0 approvals in
    let name_width =
      List.fold_left (fun widest row ->
        max widest (Message_layout.display_width (approval_row_name row))) 16 approvals
      |> min 26
      |> min (max 0 ((framed_inner_width cols - 4) / 2))
      |> min (max 0 (framed_inner_width cols - 4 - phase_width)) in
    let subject_width = max 1 (framed_inner_width cols - name_width - 4) in
    if show_header then begin
      box_line_styled buf cols ~style:(Theme.recede ())
        (Printf.sprintf "  %s  %s"
           (fit_width (ui_text state ~ko:"요청" ~en:"REQUEST") subject_width)
           (fit_width (ui_text state ~ko:"요청자" ~en:"ACTOR") name_width));
      box_divider buf cols
    end;
    let approvals_window = Rows.of_list ~first:scroll_offset ~height:content_height approvals in
    report_drawn_list Approval_items ~height:content_height;
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < approval_total then begin
        let line =
          match Rows.at approvals_window idx with
          | None -> ""
          | Some row ->
              let subject = match row with
                | Masc_tui_approvals_model.Operator_row item ->
                    Terminal_text.single_line_or
                      ~default:(Terminal_text.single_line item.ap_action_type) (Some item.ap_summary)
                | Masc_tui_approvals_model.Keeper_tool_row held ->
                    Terminal_text.single_line held.kta_question
                | Masc_tui_approvals_model.Gate_row pending ->
                    let phase, tone = approval_gate_phase state pending.gp_phase in
                    let tool_width = subject_width - Message_layout.display_width phase - 3 in
                    if tool_width <= 0 then tone ^ phase ^ Ansi.reset
                    else fit_width (Terminal_text.single_line pending.gp_display_tool) tool_width
                      ^ " · " ^ tone ^ phase ^ Ansi.reset
              in
              Printf.sprintf "%s  %s" (fit_width subject subject_width)
                (fit_width (approval_row_name row) name_width)
        in
        let is_selected = idx = state.approval_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("\xe2\x80\xba " ^ line))
        else
          box_line buf cols ("  " ^ line)
      end else
        box_empty buf cols
    done
  end;

  Buffer.add_buffer buf below_buf;

  Buffer.add_buffer buf ask_buf;

  Buffer.add_buffer buf footer_buf;

  finish_surface state ~surface_key:"approvals" ~rows:terminal_rows
      ~cols buf

(* Source diagnostics that cannot take space from the selected compact Ask
   remain reachable in the same full reader and its actual scroll domain. *)
let question_reader_sheet_rows ~cols ~room (state : state) =
  if Masc_tui_operator_projection.Flow.action_inflight state.approval_flow || state.ask_submit_inflight then
    progress_sheet_height ~available:room ~cols:(framed_inner_width cols)
      { ps_title = ""
      ; ps_detail = None
      ; ps_started_at = None
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking = true
      }
  else 0
;;

let question_reader_viewport state =
  let lines, room = ask_question_viewport state in
  (* The editor follows the last question row while typing. Diagnostics must
     not become the new end and scroll the active editor out of view. *)
  let notices = match state.ask_text_entry with
    | Some _ -> []
    | None -> approval_source_notices state
        ~reading:(Masc_tui_approvals_model.approvals_reading state) in
  let buf = Buffer.create 512 in
  let _, cols = get_terminal_size () in
  if notices <> [] then box_divider buf cols;
  List.iter (fun (style, text) -> box_wrapped_field buf cols ~head:"  " ~style text) notices;
  let notice_lines = String.split_on_char '\n' (Buffer.contents buf)
      |> List.filter (fun line -> line <> "") in
  let sheet_rows = question_reader_sheet_rows ~cols ~room state in
  lines @ notice_lines, max 0 (room - sheet_rows)

let ask_question_page_size state = snd (question_reader_viewport state)

let ask_question_scroll_limit state =
  let lines, room = question_reader_viewport state in
  max 0 (List.length lines - room)

let render_question_reader (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let asks = open_ask_rows state in
  let selected_index = Ask_projection.selected_index asks state.ask_cursor in
  let selected = Option.bind selected_index (List.nth_opt asks) in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let progress_sheet = approvals_progress_sheet ~now state in
  let lines, raw_room =
    let lines, room = ask_question_viewport state in
    let notices = match state.ask_text_entry with
      | Some _ -> []
      | None -> approval_source_notices state
          ~reading:(Masc_tui_approvals_model.approvals_reading state) in
    let nbuf = Buffer.create 512 in
    if notices <> [] then box_divider nbuf cols;
    List.iter (fun (style, text) -> box_wrapped_field nbuf cols ~head:"  " ~style text) notices;
    let notice_lines = String.split_on_char '\n' (Buffer.contents nbuf)
        |> List.filter (fun line -> line <> "") in
    lines @ notice_lines, room
  in
  let sheet_lines =
    match progress_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:raw_room
          ~width:(framed_inner_width cols) sheet
  in
  let room = max 0 (raw_room - List.length sheet_lines) in
  let limit = max 0 (List.length lines - room) in
  let scroll =
    if Option.is_some state.ask_text_entry then limit
    else max 0 (min state.ask_question_scroll limit)
  in
  let say korean english = if ko then korean else english in
  box_top buf cols;
  box_line buf cols
    (zone_two_title ~cols state
       ~position:
         (Masc_tui_value.Position.window ~first:scroll ~shown:room
            ~total:(List.length lines))
       ~title:(fun ~cols:_ ->
         let base =
           screen_title
             (say " 승인 › 질문" " Approvals › Questions"
              ^ Masc_tui_approvals_model.approval_list_note ~ko
                  ~name:(say "질문" "questions")
                  (Masc_tui_approvals_model.approvals_questions_reading state))
         in
         match progress_sheet with
         | None -> base
         | Some sheet ->
             base ^ "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title));
  box_line buf cols
    (match selected with
     | None ->
         (match Masc_tui_approvals_model.approvals_questions_reading state with
          | Masc_tui_approvals_model.List_read when asks <> [] ->
              say "  선택된 질문 없음 · [ 또는 ] 키로 선택"
                "  Nothing selected · [ or ] chooses a question"
          | Masc_tui_approvals_model.List_read ->
              say "  대기 중인 질문 없음" "  No questions waiting"
          | List_not_read (Approval_unread | Approval_kept_back _) ->
              say "  질문 목록 미조회" "  Questions not loaded"
          | List_not_read (Approval_failed _ | Approval_stale _ | Approval_unavailable _) ->
              say "  질문 출처 조회 불가" "  Question source unavailable")
     | Some row ->
         let draft = Ask_projection.draft_for state.ask_draft ~row in
         let drafted = List.filter (fun question ->
             Option.is_some (Ask_projection.response_for draft ~question)) row.ar_questions |> List.length in
         Printf.sprintf
           (if ko then "  %s%s · 요청 %d/%d · 질문 %d/%d · 작성 %d건%s"
            else "  %s%s · Ask %d/%d · Question %d/%d · %d drafted%s")
           (Theme.warn ()) (Terminal_text.single_line (Masc.Tui_decode_asks.ask_asker_label row.ar_asker))
           (Option.fold ~none:0 ~some:succ selected_index) (List.length asks) (state.ask_question_cursor + 1)
           (List.length row.ar_questions) drafted Ansi.reset);
  box_line buf cols
    (match state.asks_error with
     | Some error ->
         say "  질문 출처 조회 불가 · " "  Question source unavailable · "
         ^ Terminal_text.single_line error
     | None ->
       if Option.is_some state.ask_text_entry then
         say "  Enter:답변 저장  Esc:취소" "  Enter:save answer  Esc:cancel"
       else
         say "  ←/→:이전/다음 질문  [/]:이전/다음 요청  PgUp/PgDn:페이지  Home/End:처음/끝  Esc:"
           "  Left/Right:prev/next question  [/]:prev/next ask  PgUp/PgDn:page  Home/End:top/end  Esc:"
         ^ (match state.followed_from with
          | Some (Overview, _) -> say "운영" "Dashboard"
          | Some ((Acting | Metrics | Keepers _ | Memory | Lanes | Clients | Board
              | Approvals | Planning | Schedules | Verification | Harness | Fusion
              | Repositories | Code | Changes | Connectors | Runtime | Config
              | Resources | Tools | System_logs), _)
            | None -> say "승인" "approvals"));
  box_divider buf cols;
  let lines_window = Rows.of_list ~first:scroll ~height:room lines in
  for i = 0 to room - 1 do
    match Rows.at lines_window (scroll + i) with
    | Some line -> Buffer.add_string buf (line ^ "\n")
    | None -> box_empty buf cols
  done;
  List.iter (box_line buf cols) sheet_lines;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints:(question_hints state));
  finish_surface state ~surface_key:"approval-questions" ~rows:terminal_rows ~cols buf

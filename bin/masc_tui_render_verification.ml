(** Verification (Task Review) and Harness (Task Verdicts) screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim

module Magnitude = Masc_tui_magnitude
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule
module Link = Masc_tui_link
module Card = Masc_tui_card
module Doc = Masc_tui_doc
module Chart = Masc_tui_chart
module Text_block = Masc_tui_text_block

let review_mark = function
  | Review_unobserved -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Waiting
  | Review_running _ | Review_waiting_original _ ->
      Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way
  | Review_stopped { cause = Review_original_repair; _ } ->
      Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Caution
  | Review_stopped
      { cause =
          ( Review_environment | Review_no_judgment | Review_commit_failure
          | Review_failure | Review_cancelled )
      ; _
      } ->
      Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Paused
  | Review_approved _ -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled
  | Review_rejected _ -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Failed
  | Review_superseded _ -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Waiting

let review_style = function
  | Review_unobserved | Review_superseded _ -> Theme.recede ()
  | Review_running _ | Review_waiting_original _ -> Theme.info ()
  | Review_stopped { cause = Review_original_repair; _ } -> Theme.warn ()
  | Review_stopped
      { cause =
          ( Review_environment | Review_no_judgment | Review_commit_failure
          | Review_failure | Review_cancelled )
      ; _
      } ->
      Theme.recede ()
  | Review_approved _ -> Theme.ok ()
  | Review_rejected _ -> Theme.bad ()

let review_label state = function
  | Review_unobserved -> ui_text state ~ko:"보고 안 됨" ~en:"not reported"
  | Review_running _ -> ui_text state ~ko:"검증 중" ~en:"reviewing"
  | Review_waiting_original _ -> ui_text state ~ko:"원 실행 확인" ~en:"checking original"
  | Review_stopped {cause=Review_original_repair;_} ->
      ui_text state ~ko:"확인 필요" ~en:"repair needed"
  | Review_stopped {cause=(Review_environment | Review_no_judgment | Review_commit_failure
      | Review_failure | Review_cancelled);_} -> ui_text state ~ko:"중단" ~en:"stopped"
  | Review_approved _ -> ui_text state ~ko:"승인 기록" ~en:"approved"
  | Review_rejected _ -> ui_text state ~ko:"반려 기록" ~en:"rejected"
  | Review_superseded _ -> ui_text state ~ko:"다른 판정 적용" ~en:"superseded"

(* The verdict's own failure in its words, or the notice of a verdict the
   workspace guard kept back. *)
let verdict_failure_text state failure =
  request_failure_text ~ko:(state.ui_language = Lang_ko)
    ~request:Kept_request.Verification_verdict failure

(* These are readings of the retained snapshot, including while a new read is
   outstanding. The label qualifies the value even if a narrow title clips. *)
let previous_reading_label state ~inflight ~error label =
  if inflight || Option.is_some error then
    ui_text state ~ko:"이전 " ~en:"last " ^ label
  else label

(* Both list headings and rows use these exact two widths. IDs, evaluator and
   evidence metadata remain in the complete selected reading. *)
let judgement_list_columns state ~cols ~status_header ~statuses =
  let inner_width = max 1 (framed_inner_width cols - 2) in
  let status_width =
    List.fold_left (fun widest text -> max widest (Message_layout.display_width text))
      (Message_layout.display_width status_header) statuses
    |> min (max 1 (inner_width - 3)) in
  let title_width = max 1 (inner_width - status_width - 2) in
  let row ?(selected = false) ?(status_style = "") title status =
    (if selected then "\xe2\x80\xba " else "  ")
    ^ fit_width (Terminal_text.single_line title) title_width
    ^ "  " ^ Ansi.wrap_style status_style (fit_width status status_width) in
  row (ui_text state ~ko:"작업" ~en:"Task") status_header, row

(* What the notice above a retained reading says went wrong: the last read
   failed with [detail], or the workspace guard kept the read back, which is
   drawn as its kept-back notice alone. *)
type reading_error = Last_error of string | Read_kept_back of string

let verification_reading_error state = function
  | Request_failed detail -> Last_error detail
  | Request_withdrawn refusal ->
      Read_kept_back (workspace_refusal_text ~ko:(state.ui_language = Lang_ko)
        ~request:Kept_request.Verification_read refusal)

let verification_progress_sheet ~now (state : state) =
  let writing_path =
    List.find_map
      (fun (_, _, progress) ->
        match progress with
        | Masc_tui_evidence_file.Writing path -> Some path
        | Not_started | Saved _ | Aborted _ -> None)
      state.verification_evidence_saved
  in
  let spec =
    match state.verification_verdict_inflight, writing_path with
    | Some (task_id, request_id), _ ->
        Some
          ( "verdict:" ^ task_id ^ ":" ^ request_id
          , ui_text state ~ko:"검증 판정 전송 중" ~en:"Submitting verification verdict"
          , Some (Terminal_text.single_line task_id ^ " [" ^ Terminal_text.single_line request_id ^ "]")
          , true )
    | None, Some path ->
        Some
          ( "evidence-save:" ^ path
          , ui_text state ~ko:"증거 파일 저장 중" ~en:"Saving verification evidence"
          , Some (Terminal_text.single_line path)
          , false )
    | None, None -> None
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"verification-op" ~now
      (Option.map (fun (sig_key, _, _, _) -> sig_key) spec)
  in
  Option.map
    (fun (_, ps_title, ps_detail, ps_blocking) ->
      { ps_title
      ; ps_detail
      ; ps_started_at = started_at
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking
      })
    spec
;;

let reading_notice_lines state ~width ~inflight ~error =
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
  let notice = match error, inflight with
    | None, false -> None
    | None, true -> Some (Theme.info (),
        under_way ^ " " ^ ui_text state ~ko:"재조회 중 · 이전 조회 자료" ~en:"Refreshing · previous reading")
    | Some (Read_kept_back notice), (false | true) -> Some (Theme.warn (), notice)
    | Some (Last_error detail), refreshing ->
        let prefix = if refreshing then
            under_way ^ " " ^ ui_text state ~ko:"재조회 중 · 이전 자료 · 마지막 오류: "
              ~en:"Refreshing · previous reading · last error: "
          else ui_text state ~ko:"이전 관측 · 조회 실패: "
              ~en:"Previous reading · read failed: " in
        Some (Theme.warn (), prefix ^ detail) in
  match notice with
  | None -> []
  | Some (style, text) ->
      Message_layout.wrap_body ~max_cells:(max 1 (width - 4))
        ~sanitize:Keeper_chat.terminal_safe_text text
      |> List.map (fun line -> style, "  " ^ line)

let verification_status state (request : Tui_decode.verification_request) =
  let mark, label =
    match request.vr_evidence_error with
    | Some _ ->
        Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Failed,
        ui_text state ~ko:"증거 읽기 실패" ~en:"evidence error"
    | None -> review_mark request.vr_review, review_label state request.vr_review
  in
  mark ^ " "
  ^ previous_reading_label state ~inflight:state.verification_inflight
      ~error:state.verification_error label

let verification_status_style (request : Tui_decode.verification_request) =
  match request.vr_evidence_error with
  | Some _ -> Theme.bad ()
  | None -> review_style request.vr_review

let review_detail ~ko review =
  let text korean english = if ko then korean else english in
  match review with
  | Review_unobserved ->
    text "자동 검증 실행 보고 안 됨" "No automatic review run reported yet."
  | Review_running actor ->
    text "자동 검증 증거 확인 중: " "Automatic reviewer checking evidence: " ^ actor
  | Review_waiting_original {detail;actor} ->
    text "기존 검증 실행 기록 확인 중 · 모델 재호출 미예약 · "
      "Checking earlier review run · no model retry scheduled · "
    ^ actor ^ " · " ^ detail
  | Review_stopped {cause; detail; actor} ->
    let reason = match cause with
      | Review_environment ->
        text "검증 환경 접근 불가" "Review environment unreachable"
      | Review_no_judgment -> text "검증자 판정 없음" "Reviewer reached no judgment"
      | Review_commit_failure ->
        text "검증 결과 Task 반영 실패" "Failed to write review result to Task"
      | Review_original_repair ->
        text "원 실행 결과 미확정 · 운영자 확인 필요"
          "Original run unsettled · operator check needed"
      | Review_failure -> text "검증 실행 중단" "Review run stopped"
      | Review_cancelled -> text "검증 실행 취소" "Review run cancelled" in
    reason ^ " · " ^ actor ^ " · " ^ detail
  | Review_approved reason ->
    text "승인 판정 기록됨 · Task 완료 여부는 Task 상태 확인 · "
      "Approval recorded · check Task status for completion · " ^ reason
  | Review_rejected reason -> text "반려 판정 기록됨 · " "Rejection recorded · " ^ reason
  | Review_superseded actor ->
    text "다른 판정 선적용: " "Another verdict applied first: " ^ actor

(* The task and its actual review state lead the list. Submission identity,
   evidence counts and original source remain in the complete reading. *)
let render_verification_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let requests =
    match state.verification with None -> [] | Some s -> s.Masc.Tui_decode.vs_requests
  in
  let shown = List.length requests in
  let header ~cols =
    match state.verification with
    | None ->
        let reading_note =
          match state.verification_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        let after =
          (if reading_note = "" then "" else "  " ^ reading_note)
          ^ quiet_connection_tail state
        in
        Printf.sprintf "%s%s"
          (planning_workspace_title state ~cols ~tab:Planning_task_review ~window:""
             ~after)
          after
    | Some snapshot ->
        (* Both numbers, for the same reason the log surface shows both: "12"
           beside a list of 12 would read as "that is all of them".

           Except when the tab's own badge already carries the total: it
           wears the count once the queue is above zero, and a page holding
           the whole queue then read "Task Review·2 (2 of 2)". The window
           stays for a cut page, where it says how much of the badge's number
           is on screen, and for an empty read, which has no badge to say
           the read happened at all. *)
        let total = snapshot.Masc.Tui_decode.vs_total in
        let window =
          if shown > 0 then ""
          else
            Printf.sprintf
              (if state.ui_language = Lang_ko then " (전체 %s 중 0)" else " (0 of %s)")
              (Masc_tui_value.Count.grouped total)
        in
        let badge = quiet_connection_tail state in
        planning_workspace_title state ~cols ~tab:Planning_task_review ~window ~after:badge
        ^ badge
  in
  (* The selected row, and how much of the server's list is loaded when the
     page holds less than all of it. *)
  let cursor = Masc_tui_scroll.cursor_normalized ~count:shown state.verification_cursor in
  let position =
    match state.verification with
    | None -> None
    | Some _ when shown = 0 -> None
    | Some snapshot ->
        (* Counted in the server's list, not the page: on a later page the
           selected row and the rows read run on from the rows before it. *)
        let offset = max 0 snapshot.Masc.Tui_decode.vs_offset in
        let selected = Some (offset + cursor) in
        let total = snapshot.Masc.Tui_decode.vs_total in
        if total > offset + shown then
          Some (Masc_tui_value.Position.partial ~selected ~loaded:(offset + shown) ~total)
        else Some (Masc_tui_value.Position.row ~selected ~total:(offset + shown))
  in
  box_line buf cols (zone_two_title ~cols state ~title:header ~position);
  box_divider buf cols;
  let col_hdr, request_row =
    judgement_list_columns state ~cols
      ~status_header:(ui_text state ~ko:"자동 검증" ~en:"Review")
      ~statuses:(List.map (verification_status state) requests) in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.verification_error with
   | None -> ()
   | Some failure ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text
            (request_failure_text ~ko:(state.ui_language = Lang_ko)
               ~request:Kept_request.Verification_read failure));
       box_divider buf cols);
  (* The height the keypress bounds its step with, asked of the same layout:
     it counts the rows drawn under the list as well as the frame. *)
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let progress_sheet = verification_progress_sheet ~now state in
  let raw_content_height =
    match scrolled_surface state ~cols Verification with
    | Some layout ->
        Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
          ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
    | None -> max 1 (rows - listing_chrome ~error:state.verification_error)
  in
  let sheet_lines =
    match progress_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:raw_content_height
          ~width:(framed_inner_width cols) sheet
  in
  let content_height = max 0 (raw_content_height - List.length sheet_lines) in
  let scroll = Masc_tui_scroll.ensure_visible ~cursor
      ~height:content_height state.verification_scroll
    |> Masc_tui_scroll.normalize ~count:shown ~height:content_height in
  let requests_window = Rows.of_list ~first:scroll ~height:content_height requests in
  report_drawn_list Verification_rows ~height:content_height;
  if shown = 0 then begin
    if content_height > 0 then begin
      let style, empty =
        match
          empty_page_of ~snapshot:state.verification
            ~error:state.verification_error
        with
        | Page_failed -> Theme.recede (), page_failed_note ~ko
        | Page_unread ->
            (if state.verification_inflight then Theme.info () else Theme.recede ()),
            page_unread_note_while ~ko ~reading:state.verification_inflight
        | Page_empty ->
            Theme.recede (),
            ui_text state ~ko:"  (판정 대기 중인 항목 없음)"
              ~en:"  (nothing waiting on a verdict)"
      in
      box_line_styled buf cols ~style empty;
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at requests_window idx with
      | None -> box_empty buf cols
      | Some r ->
          let open Masc.Tui_decode in
          let is_selected = idx = cursor in
          let status_style = verification_status_style r in
          let line =
            request_row ~selected:is_selected ~status_style
              r.vr_task_title (verification_status state r)
          in
          if is_selected then box_line_selected_styled buf cols line
          else box_line buf cols line
    done;
  (* Which list this is, and where in it -- drawn on every read rather than
     only on a cut page. The same row count means "nothing else is waiting" in
     the queue and "the newest page of what was ever submitted" in the
     history, and the rows themselves do not say which. *)
  (match state.verification with
   | None -> ()
   | Some snapshot ->
       let total = snapshot.Masc.Tui_decode.vs_total in
       let offset = snapshot.Masc.Tui_decode.vs_offset in
       let place =
         match snapshot.Masc.Tui_decode.vs_view with
         | Masc.Tui_decode.Awaiting_queue ->
             Printf.sprintf
               (if state.ui_language = Lang_ko then "대기 %s건" else "awaiting %s")
               (Masc_tui_value.Count.grouped total)
         | Masc.Tui_decode.Full_history ->
             if offset = 0 then ui_text state ~ko:"전체 이력" ~en:"history"
             else
               Printf.sprintf
                 (if state.ui_language = Lang_ko then "이력 %s번부터" else "history from %s")
                 (Masc_tui_value.Count.grouped (offset + 1))
       in
       (* Named because the key is not on the footer of a narrow terminal, and
          a page with more behind it that says so is the difference between
          "that is all" and "there is more". *)
       let more =
         if snapshot.Masc.Tui_decode.vs_truncated then
           ui_text state ~ko:" \xc2\xb7 > 다음 페이지" ~en:" \xc2\xb7 > next page"
         else ""
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "[%s%s]" place more);
       (* An empty queue carrying a reason is not an empty queue. *)
       (match snapshot.Masc.Tui_decode.vs_backlog_error with
        | Some detail ->
            box_line_styled buf cols ~style:(Theme.bad ())
              (Printf.sprintf
                 (if state.ui_language = Lang_ko then "  대기열을 읽지 못함: %s"
                  else "  the queue could not be read: %s")
                 (Terminal_text.single_line detail))
        | None -> ());
       (* A queue built from a recovery snapshot is a queue of real rows that
          is older than the workspace. Drawn, because the rows themselves look
          exactly like a current queue and nothing else on this screen would
          say otherwise. *)
       (match snapshot.Masc.Tui_decode.vs_backlog_recovery with
        | Some detail ->
            box_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf
                 (if state.ui_language = Lang_ko then "  복구 스냅샷 시점의 이전 대기열: %s"
                  else "  this queue is as old as the snapshot it came from: %s")
                 (Terminal_text.single_line detail))
        | None -> ());
       (* A task waiting on a record the store does not hold cannot be moved
          from this surface, and no other surface says so either. *)
       (match snapshot.Masc.Tui_decode.vs_awaiting_unresolved with
        | [] -> ()
        | ids ->
            let named = List.filteri (fun i _ -> i < 3) ids in
            (* The list is one page; the total counts them all. *)
            let rest =
              snapshot.Masc.Tui_decode.vs_awaiting_unresolved_total
              - List.length named
            in
            box_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf
                 (if state.ui_language = Lang_ko then "  저장소에 없는 기록을 기다리는 중: %s%s"
                  else "  waiting on a record this store does not hold: %s%s")
                 (String.concat ", " named)
                 (* The ids past the first three: a cut-off count joined as
                    a fact of the same rank, never "(+N)" (RFC
                    tui-one-screen-grammar 6.3, 6.5). *)
                 (if rest > 0 then
                    " · " ^ Masc_tui_value.Count.more
                      ~ko:(state.ui_language = Lang_ko) rest
                  else ""))));
  (* The arm and the server's last refusal sit under the list, the same rows
     the schedule cancel carries them on. *)
  (match state.verification_verdict_armed with
   | Some (task_id, request_id) ->
       let armed_label =
         match
           Option.bind state.verification (fun snapshot ->
             List.find_opt
               (fun (r : Masc.Tui_decode.verification_request) ->
                 String.equal r.vr_task_id task_id
                 && String.equal r.vr_request_id request_id)
               snapshot.Masc.Tui_decode.vs_requests)
         with
         | Some r when not (String.equal (String.trim r.vr_task_title) "") ->
             Terminal_text.single_line r.vr_task_title
         | Some _ | None -> resolve_task_title state task_id
       in
       (* No width padding on the label: padding to a reserved column pushes the
          "same key again" tail past the box on a narrow terminal, and the
          tail is the half that instructs. *)
       box_line buf cols
         ((Theme.warn ())
         ^ Printf.sprintf
             (if state.ui_language = Lang_ko then "  승인 대기: %s · 같은 키를 한 번 더 누르면 전송 [%s]"
              else "  armed: approve %s · same key again to send [%s]")
             armed_label
             (Terminal_text.single_line request_id)
         ^ Ansi.reset)
   | None -> ());
  (match state.verification_verdict_error with
   | Some failure ->
       let err = verdict_failure_text state failure in
       box_line buf cols
         ((Theme.bad ()) ^ "  "
         ^ fit_width (Terminal_text.single_line err) (framed_inner_width cols - 4)
         ^ Ansi.reset)
   | None -> ());
  List.iter (box_line buf cols) sheet_lines;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line_keys state ~max_cells:cols
       ~keys:
         (Masc_tui_keys.footer_row_of_surface ~lang:state.ui_language ~detail_open:false
            ~has_rows:(shown > 0) state.view));
  finish_surface state ~surface_key:"verification" ~rows:terminal_rows ~cols buf

(* Complete judgement metadata is a physical document. Rows that fit keep
   their field alignment; longer rows remain literal and reachable by scroll. *)
let judgement_detail_rows = Masc_tui_render_evidence.wrap_rows

let verification_detail_lines ~ko ~width
    (request : Masc.Tui_decode.verification_request) =
  let text k e = if ko then k else e in
  let pre = List.map (fun s -> "", s) in
  let title =
    Text_block.rows ~max_cells:(max 1 (width - 4)) request.vr_task_title
    |> List.map (fun line -> Ansi.bold, "  " ^ line)
  in
  let detail_tone =
    match request.vr_review with
    | Review_stopped _ | Review_waiting_original _ -> Theme.warn ()
    | Review_approved _ -> Theme.ok ()
    | Review_rejected _ -> Theme.bad ()
    | Review_unobserved | Review_running _ | Review_superseded _ -> ""
  in
  title
  @ pre
      (Doc.prose_block ~width ~indent:2
         ~guide_style:(if detail_tone = "" then Theme.border_muted () else detail_tone)
         ~break_numbered:true ~tone:detail_tone (review_detail ~ko request.vr_review))
  @ pre
      (Doc.kv_rows ~width ~indent:2 ~max_label_cells:12
         [ Doc.kv ~tone:(Theme.recede ()) (text "증거" "Evidence")
             (Printf.sprintf
                (if ko then "제출 %d개 · 요구 %d항목 (개수는 충족 여부가 아님)"
                 else "%d submitted · %d required (count is not sufficiency)")
                (List.length request.vr_submitted_evidence)
                (List.length request.vr_required_artifacts))
         ])
  @ (match request.vr_evidence_error with
     | None -> []
     | Some detail ->
         pre (Doc.prose_block ~width ~indent:2 ~guide_style:(Theme.bad ()) ~tone:(Theme.bad ()) detail))

let verification_contract_lines state ~width (request : Masc.Tui_decode.verification_request) =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let pre = List.map (fun s -> "", s) in
  let bullet_rows text =
    Doc.prose_block ~width ~indent:2 ~guide_style:(Theme.border_muted ()) ("• " ^ text)
    |> pre
  in
  let submitted_at =
    match Time_codec.parse_rfc3339_opt request.vr_created_at with
    | Some at -> Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ()) at
    | None -> Terminal_text.single_line request.vr_created_at
  in
  let task_text =
    if String.equal (String.trim request.vr_task_title) "" then
      resolve_task_title state request.vr_task_id
    else
      Terminal_text.single_line request.vr_task_title ^ " (" ^ request.vr_task_id ^ ")"
  in
  let record_path =
    match state.server_identity with
    | Some identity -> Filename.concat (Canonical_path.to_string identity.sid_masc_root)
        ("verifications/" ^ request.vr_request_id ^ ".json")
    | None ->
      workspace_identity_unread ~ko ^ " · verifications/" ^ request.vr_request_id ^ ".json"
  in
  [ "", "" ]
  @ pre [ Doc.section_rule ~width ~indent:2 (say "완료 조건" "Completion contract") ]
  @ List.concat_map bullet_rows request.vr_completion_contract
  @ [ "", "" ]
  @ pre [ Doc.section_rule ~width ~indent:2 (say "요구 증거" "Required evidence") ]
  @ (if request.vr_required_artifacts = [] then
       pre (Doc.kv_rows ~width ~indent:2 [ Doc.kv ~tone:(Theme.recede ()) "" (say "별도 요구 목록 없음" "No separate list of required evidence.") ])
     else List.concat_map bullet_rows request.vr_required_artifacts)
  @ [ "", "" ]
  @ pre [ Doc.section_rule ~width ~indent:2 (say "제출 정보" "Submission") ]
  @ pre
      (Doc.kv_rows ~width ~indent:2 ~max_label_cells:14
         [ Doc.kv (say "작업" "Task") task_text
         ; Doc.kv (say "제출자" "Submitted by") request.vr_submitted_by
         ; Doc.kv ~tone:(Theme.recede ()) (say "제출 시각" "Submitted") submitted_at
         ; Doc.kv ~tone:(Theme.recede ()) (say "저장 기록" "Server record") record_path
         ])

(* The nouns are the ones the evidence section under the index uses
   ([Masc_tui_render_evidence.section]). *)
let evidence_name ~ko item =
  let text korean english = if ko then korean else english in
  let collaboration = text "협업 기록" "submitted source" in
  let artifact = text "파일" "artifact" in
  match item with
  | Masc_tui_evidence_picture.Source_item {source=Ev_collaboration {ev_reference;_};_} ->
    collaboration ^ " · " ^ ev_reference
  | Masc_tui_evidence_picture.Source_item
      {source=(Ev_note _ | Ev_artifact _ | Ev_artifact_unreadable _ | Ev_binary _);_} -> collaboration
  | Masc_tui_evidence_picture.Text_item item -> (match item with
      | Ev_note note -> text "메모" "note" ^ " · " ^ Terminal_text.single_line note
      | Ev_collaboration {ev_reference; _} -> collaboration ^ " · " ^ ev_reference
      | Ev_artifact {ev_reference; ev_bytes; ev_truncated; _} ->
        Printf.sprintf "%s · %s · %dB%s" artifact ev_reference ev_bytes
          (if ev_truncated then text " · 일부만 저장됨" " · truncated" else "")
      | Ev_artifact_unreadable {ev_u_reference; ev_u_reason} ->
        text "읽을 수 없음" "unreadable" ^ " · "
        ^ Option.value ev_u_reference ~default:(text "참조 없음" "no reference") ^ " · " ^ ev_u_reason
      | Ev_binary {ev_b_reference; _} -> artifact ^ " · " ^ ev_b_reference)
  | Masc_tui_evidence_picture.Binary_item {reference; bytes; format; _} ->
    Printf.sprintf "%s · %s · %s · %dB" (text "바이너리 파일" "binary artifact") reference format bytes

let verification_evidence_index state request ~width observation =
  match observation with
  | Masc_tui_fetched.Ready (Masc_tui_evidence_picture.Items items)
  | Stale (Masc_tui_evidence_picture.Items items, _) ->
    let count = List.length items in
    let index = max 0 (min (count - 1) state.verification_evidence_cursor) in
    let rows = List.mapi (fun i item ->
      let row_text =
        Printf.sprintf "  %s %d. %s" (if i = index then "\xe2\x80\xba" else " ") (i + 1)
          (fit_width (Terminal_text.single_line (evidence_name ~ko:(state.ui_language = Lang_ko) item))
             (max 1 (width - 9)))
      in
      if i = index then ("", selection_row_styled ~cells:(max 1 width) row_text)
      else (Theme.recede (), row_text)) items in
    let rows = if state.verification_evidence_index_open then rows
      else Option.to_list (List.nth_opt rows index) in
    let location =
      let ko = state.ui_language = Lang_ko in
      Printf.sprintf
        (if ko then
           "  원본 참조는 제출자 %s의 %s 기준입니다. 여기서는 제출 시 저장한 사본을 읽습니다."
         else
           "  Original references are relative to submitter %s's %s; this view reads the snapshot saved at submission.")
        request.vr_submitted_by (workspace_name ~ko) in
    let ko = state.ui_language = Lang_ko in
    let say korean english = if ko then korean else english in
    (* The selected item carries its own number below; this row counts the
       items, it does not say which is read. *)
    judgement_detail_rows ~width ([Theme.recede (), ""; Ansi.bold, Printf.sprintf
        (if ko then "  증거 %s  e/E:다음/이전  i:목록  o:열기  s:저장"
         else "  Evidence %s  e/E:next/prev  i:list  o:open  s:save")
        (Masc_tui_value.Count.grouped count)]
      @ rows @ [Theme.recede (), location]
      @ List.filter_map (fun (key, saved_index, progress) ->
          if key.vek_request_id = request.vr_request_id
             && key.vek_task_id = request.vr_task_id && saved_index = index
          then (match progress with
            | Masc_tui_evidence_file.Not_started -> None
            | Writing path ->
              let mark = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
              Some (Theme.info (),
                "  " ^ mark ^ " " ^ say "저장 중(완료 보고 안 됨): " "Saving to (completion not reported): " ^ path)
            | Saved path -> Some (Ansi.reset, say "  이 기기에 저장한 파일: " "  Saved on this device: " ^ path)
            | Aborted path ->
              Some (Theme.warn (), say "  저장하지 못한 목적지: " "  Could not save to: " ^ path))
          else None)
          state.verification_evidence_saved), index
  | Absent | Loading | Failed _ | Ready (Masc_tui_evidence_picture.Access_unavailable _)
  | Stale (Masc_tui_evidence_picture.Access_unavailable _, _) -> [], 0

let verification_detail_pane (state : state) ~rows ~cols
    ~origin:(origin_row, origin_col) request buf =
  let width = max 1 (framed_inner_width cols) in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let say korean english = if ko then korean else english in
  let progress_sheet = verification_progress_sheet ~now state in
  let armed_note =
    match state.verification_verdict_armed with
    | Some (task_id, request_id)
      when String.equal task_id request.Masc.Tui_decode.vr_task_id
           && String.equal request_id request.vr_request_id ->
        let armed_label =
          if not (String.equal (String.trim request.vr_task_title) "") then
            Terminal_text.single_line request.vr_task_title
          else resolve_task_title state task_id
        in
        Some (Printf.sprintf
          (if ko then "  확인 대기: a를 다시 누르면 %s [%s] 승인" else "  ARMED: a again to approve %s [%s]")
          armed_label
          (Terminal_text.single_line request_id))
    | Some _ | None -> None
  in
  let approve = say "  a×2:운영자 승인" "  a×2:operator approval" in
  let reject = say "x:사유 반려  j/k:스크롤" "x:reject with reason  j/k:scroll" in
  let verdict_action = approve ^ "  " ^ reject in
  let verdict_action_rows =
    if Message_layout.display_width verdict_action <= width then
      [ verdict_action ]
    else [ approve; "  " ^ reject ]
  in
  (* The action rows are fixed chrome; subtract exactly what this pane draws
     so the window on the title row matches the visible body. *)
  let fixed_rows =
    List.length verdict_action_rows
      + (if Option.is_some armed_note then 1 else 0)
      + (if Option.is_some state.verification_verdict_error then 1 else 0)
  in
  let raw_content_height = max 1 (rows - max 0 (framed_chrome_rows - 2) - fixed_rows) in
  let sheet_lines =
    match progress_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:raw_content_height
          ~width:(framed_inner_width cols) sheet
  in
  let content_height = max 0 (raw_content_height - List.length sheet_lines) in
  (* The three parts are wrapped apart so the evidence section's row index is
     known: wrapping is per row, so this is the same rows as wrapping once. *)
  let before = judgement_detail_rows ~width
      (reading_notice_lines state ~width ~inflight:state.verification_inflight
         ~error:(Option.map (verification_reading_error state) state.verification_error)
       @ verification_detail_lines ~ko:(state.ui_language = Lang_ko) ~width request) in
  (* What the verifier can actually inspect: the operator evidence bundle,
     lazily fetched on detail entry. The snapshot above lists references; this
     carries artifact content prefixes (server-capped, truncation marked), the
     pictures of image artifacts, and the typed reason when an artifact could
     not be read — the judge's actual input, drawn beside the verdict keys so
     approval is not blind. *)
  let key = {vek_request_id=request.Masc.Tui_decode.vr_request_id;vek_task_id=request.vr_task_id} in
  let observation = Masc_tui_fetched.view_for ~equal:equal_verification_evidence_key state.verification_evidence ~key in
  let index_rows, selected_index = verification_evidence_index state request ~width observation in
  let before = before @ index_rows in
  let evidence, pictures =
    let in_flight = Masc_tui_fetched.in_flight state.verification_evidence
      && (match Masc_tui_fetched.current_key state.verification_evidence with
          | Some current -> equal_verification_evidence_key current key | None -> false) in
    Masc_tui_render_evidence.section ~ko:(state.ui_language = Lang_ko)
      ~selection:(Some selected_index)
      ~evidence:observation
      ~in_flight ~workspace_confirmed:(server_authority_ready state) ~width ~content_height
      ~display:(Masc_tui_portrait_view.current_display ())
  in
  let evidence_first = List.length before in
  let lines = before @ evidence @ verification_contract_lines state ~width request in
  report_drawn_list Verification_detail_rows ~height:content_height;
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.verification_detail_scroll max_scroll) in
  let pane_start = Buffer.length buf in
  box_line buf cols
    (zone_two_title ~cols state
       ~position:
         (Masc_tui_value.Position.window ~first:scroll ~shown:content_height
            ~total:(List.length lines))
       ~title:(fun ~cols ->
         let details_step = ui_text state ~ko:"상세" ~en:"details" in
         let task_label =
           if String.equal (String.trim request.Masc.Tui_decode.vr_task_title) "" then
             resolve_task_title state request.vr_task_id
           else Terminal_text.single_line request.vr_task_title
         in
         Printf.sprintf "%s  %s"
           (planning_workspace_title state ~cols ~tab:Planning_task_review ~window:""
              ~after:(Printf.sprintf " \xe2\x80\xba %s  %s" details_step task_label)
            ^ " \xe2\x80\xba " ^ details_step)
           task_label));
  box_divider buf cols;
  (* The frame cell of the first content row, counted from what was drawn
     above it, for the pictures placed over the rows under it. *)
  let content_origin =
    ( origin_row + lines_ended_since buf ~start:pane_start
    , origin_col + framed_content_column )
  in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  (* A picture with a row in view is requested, cropped to those rows. One
     wholly out of view is held: its pixels stay with the terminal, and a
     picture that is neither requested nor held comes off at the next flush. *)
  List.iter
    (function
      | Masc_tui_render_evidence.Show placement -> Masc_tui_portrait_view.request_png placement
      | Masc_tui_render_evidence.Hold { image_id; key } ->
          Masc_tui_portrait_view.hold_png ~image_id ~key)
    (Masc_tui_render_evidence.requests ~pictures ~evidence_first ~scroll ~content_height
       ~content_origin);
  Option.iter
    (fun note -> box_line_styled buf cols ~style:(Theme.warn ())
      (fit_width note (framed_inner_width cols)))
    armed_note;
  Option.iter
    (fun failure -> box_line_styled buf cols ~style:(Theme.bad ())
      (fit_width ("  " ^ Terminal_text.single_line (verdict_failure_text state failure))
         (framed_inner_width cols)))
    state.verification_verdict_error;
  List.iter
    (box_line_styled buf cols ~style:(Theme.warn ()))
    verdict_action_rows;
  List.iter (box_line buf cols) sheet_lines;
  scroll
;;

(* The queue stays beside the request under review. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_verification_detail (state : state) request =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll =
    if cols < keeper_split_threshold_cols then
      verification_detail_pane state ~rows ~cols ~origin:(strip_rows, 0) request buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.verification with
        | None -> []
        | Some snapshot ->
          List.map
            (fun (row : Tui_decode.verification_request) ->
              (* The request id is one per row and never moves. The age it
                 replaced rounded two requests six minutes apart to the same
                 "1d12h", and spelled seconds under an hour, so an index row
                 changed while the reader was looking at it. *)
              let label =
                match String.trim row.Tui_decode.vr_task_title with
                | "" -> row.Tui_decode.vr_task_id
                | title -> title
              in
              Render_schedule.task_history_sidebar_label
                ~task_id:label
                ~apart:(Some row.Tui_decode.vr_request_id))
            snapshot.Tui_decode.vs_requests
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* One server page: the list screen next door draws "history 1-50 of
         664" off the same snapshot, and this index drew "(50)". *)
      write_list_sidebar ~framed:false left_buf ~rows ~cols:left_cols
        ~title:(ui_text state ~ko:"태스크 검증" ~en:"Task Review")
        ~focused:false
        ~holding:
          (Option.map
             (fun (snapshot : Tui_decode.verification_snapshot) ->
               snapshot.Tui_decode.vs_total)
             state.verification)
        ~labels
        ~selected:
          (Masc_tui_scroll.cursor_normalized ~count:(List.length labels)
             state.verification_cursor);
      let answer =
        verification_detail_pane state ~rows ~cols:(cols - left_cols)
          ~origin:(strip_rows, left_cols) request right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:true state.view));
  finish_surface state
    ~clamped:(Verification_detail_scroll scroll)
    ~surface_key:"verification-detail" ~rows:terminal_rows ~cols buf

let render_verification (state : state) =
  match state.verification_detail_request_id, state.verification with
  | Some request_id, Some snapshot ->
      (match
         List.find_opt
           (fun request ->
              String.equal request.Masc.Tui_decode.vr_request_id request_id)
           snapshot.Masc.Tui_decode.vs_requests
       with
       | Some request -> render_verification_detail state request
       | None -> render_verification_list state)
  | Some _, None | None, _ -> render_verification_list state

(* Workspace-wide calibration is separate from the recent verdict page and
   the selected Task. Preserve its original denominator and unknown labels
   in the selected detail document. *)
let harness_ledger_lines ~ko ~cols snapshot =
  match snapshot with
  | None -> []
  | Some snapshot -> (
      match snapshot.Masc.Tui_decode.hs_calibration with
      | None -> []
      | Some calibration ->
          let open Masc.Tui_decode in
          if calibration.hcal_total <= 0 then []
          else
            let doc_width = max 1 (framed_inner_width cols) in
            let share count =
              100. *. float_of_int count /. float_of_int calibration.hcal_total
            in
            let top_gates =
              Magnitude.of_counts calibration.hcal_gates
              |> List.filteri (fun index _ -> index < 4)
            in
            let remaining = max 0 (List.length calibration.hcal_gates - 4) in
            let gate_bar_rows =
              if top_gates = [] then []
              else
                let top_with_readout =
                  List.map
                    (fun (gate, count, _band) ->
                      let safe_gate = Masc.Tui_terminal_text.sanitize_terminal_text gate in
                      let readout = Printf.sprintf "%d (%.0f%%)" count (share count) in
                      safe_gate, count, readout)
                    top_gates
                in
                let name_w =
                  List.fold_left
                    (fun widest (safe_gate, _, _) ->
                      max widest (Message_layout.display_width safe_gate))
                    8 top_with_readout
                  |> min (max 8 (min 20 (doc_width / 3)))
                in
                let max_readout_w =
                  List.fold_left
                    (fun widest (_, _, readout) ->
                      max widest (Message_layout.display_width readout))
                    0 top_with_readout
                in
                let avail_bar = doc_width - 8 - name_w - max_readout_w in
                if doc_width >= 40 && avail_bar >= 6 then
                  let max_gate_count =
                    List.fold_left (fun acc (_, count, _) -> max acc count) 1 top_with_readout
                  in
                  let bar_w = min 20 avail_bar in
                  let rows =
                    List.map
                      (fun (safe_gate, count, readout) ->
                        let bar =
                          Chart.meter_bar ~width:bar_w ~value:count
                            ~max_value:max_gate_count
                            ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Calls })
                            ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
                        in
                        Printf.sprintf "    %s  %s  %s"
                          (fit_width safe_gate name_w)
                          bar
                          (Ansi.wrap_style (Theme.recede ()) readout))
                      top_with_readout
                  in
                  let more_row =
                    if remaining = 0 then []
                    else [ "    " ^ Ansi.wrap_style (Theme.recede ()) (Masc_tui_value.Count.more ~ko remaining) ]
                  in
                  ("  " ^ Ansi.wrap_style (Theme.recede ()) (if ko then "게이트" else "Gates"))
                  :: rows @ more_row
                else []
            in
            let evaluator =
              match snapshot.hs_overview with
              | None -> ""
              | Some overview ->
                  Printf.sprintf
                    (if ko then " · 평가자 %s" else " · evaluator %s")
                    (Terminal_text.single_line overview.hov_evaluator_status)
            in
            let ledger_value =
              Printf.sprintf
                (if ko then "%d건 판정 · 승인 %d · 거절 %d%s"
                 else "%d ruled · approve %d · reject %d%s")
                calibration.hcal_total calibration.hcal_approve
                calibration.hcal_reject evaluator
            in
            let label_value =
              if calibration.hcal_labeled > 0 then
                Printf.sprintf (if ko then "%d건" else "%d") calibration.hcal_labeled
              else
                if ko then "없음 · 일치율·오류 집계용 정답 기준 없음"
                else "none · no ground truth for agreement/error counts"
            in
            let meter_row =
              let m_width = min 52 (doc_width - 4) in
              if m_width < 18 then []
              else
                let suffix =
                  if m_width >= 32 then
                    Some (Printf.sprintf "%.0f%% (%d/%d)"
                            (share calibration.hcal_approve)
                            calibration.hcal_approve calibration.hcal_total)
                  else None
                in
                let bar =
                  Chart.dot_meter ~width:m_width ~value:calibration.hcal_approve
                    ~max_value:calibration.hcal_total
                    ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Completion })
                    ~label:(if ko then "승인율" else "Approved")
                    ~label_style:(Theme.recede ())
                    ?suffix
                    ~track_style:(Theme.border_muted ())
                    ~reset:Ansi.reset ()
                in
                [ "  " ^ bar ]
            in
            let kv_fields =
              if gate_bar_rows <> [] then
                [ Doc.kv (if ko then "누적" else "Ledger") ledger_value
                ; Doc.kv ~tone:(Theme.recede ()) (if ko then "라벨" else "Labelled") label_value
                ]
              else
                let gates =
                  let base =
                    top_gates
                    |> List.map (fun (gate, count, _band) ->
                           Printf.sprintf "%s %d (%.0f%%)"
                             (Masc.Tui_terminal_text.sanitize_terminal_text gate) count (share count))
                    |> String.concat " · "
                  in
                  if remaining = 0 then base
                  else base ^ " · " ^ Masc_tui_value.Count.more ~ko remaining
                in
                [ Doc.kv (if ko then "누적" else "Ledger") ledger_value
                ; Doc.kv (if ko then "게이트" else "Gates") gates
                ; Doc.kv ~tone:(Theme.recede ()) (if ko then "라벨" else "Labelled") label_value
                ]
            in
            meter_row
            @ Doc.kv_rows ~width:doc_width ~indent:2 ~max_label_cells:12 kv_fields
            @ gate_bar_rows)

let harness_ruling_presentation ~ko ~has_fallback raw_ruling =
  let normalized = String.lowercase_ascii (String.trim raw_ruling) in
  let mark, base_style, label =
    match normalized with
    | "approve" | "approved" | "pass" | "passed" ->
        Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled,
        Theme.ok (),
        if ko then "승인" else raw_ruling
    | "reject" | "rejected" | "fail" | "failed" | "deny" | "denied" ->
        Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Failed,
        Theme.bad (),
        if ko then "반려" else raw_ruling
    | "warn" | "warning" | "caution" | "fallback" ->
        Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Caution,
        Theme.warn (),
        if ko then "주의" else raw_ruling
    | _ ->
        Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Waiting,
        semantic_status_color raw_ruling,
        raw_ruling
  in
  let style = if has_fallback then Theme.warn () else base_style in
  mark, style, label

let split_verdict_ruling (verdict : Masc.Tui_decode.harness_verdict) =
  let whole = verdict.hv_verdict in
  match String.index_opt whole ':' with
  | None -> Terminal_text.single_line whole, ""
  | Some at ->
      ( Terminal_text.single_line (String.sub whole 0 at)
      , String.trim
          (String.sub whole (at + 1) (String.length whole - at - 1)) )

let render_harness_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let verdicts =
    match state.harness with
    | None -> []
    | Some s -> s.Masc.Tui_decode.hs_verdicts
  in
  let shown = List.length verdicts in
  let fallbacks =
    List.length
      (List.filter
         (fun (v : Masc.Tui_decode.harness_verdict) ->
           Option.is_some v.Masc.Tui_decode.hv_fallback_reason)
         verdicts)
  in
  let header ~cols =
    match state.harness with
    | None ->
        let reading_note =
          match state.harness_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        let after =
          (if reading_note = "" then "" else "  " ^ reading_note)
          ^ quiet_connection_tail state
        in
        Printf.sprintf "%s%s"
          (planning_workspace_title state ~cols ~tab:Planning_verdicts ~window:""
             ~after)
          after
    | Some snapshot ->
        (* The recent page and the workspace-wide ledger have distinct
           denominators. The complete calibration is read in detail. *)
        let of_total =
          match snapshot.Masc.Tui_decode.hs_calibration with
          | Some calibration when calibration.Masc.Tui_decode.hcal_total > 0 ->
              Printf.sprintf
                (if state.ui_language = Lang_ko then " / 전체 %d" else " of %d")
                calibration.Masc.Tui_decode.hcal_total
          | Some _ | None -> ""
        in
        let by_fallback =
          if fallbacks > 0 then
            Printf.sprintf
              (if state.ui_language = Lang_ko then ", 대체 %d건" else ", %d by fallback")
              fallbacks
          else ""
        in
        let badge = quiet_connection_tail state in
        planning_workspace_title state ~cols ~tab:Planning_verdicts
          ~window:(Printf.sprintf " (%d%s%s)" shown of_total by_fallback)
          ~after:badge
        ^ badge
  in
  let cursor = Masc_tui_scroll.cursor_normalized ~count:shown state.harness_cursor in
  box_line buf cols
    (zone_two_title ~cols state ~title:header
       ~position:
         (if shown = 0 then None
          else
            Some
              (Masc_tui_value.Position.row ~selected:(Some cursor)
                 ~total:shown)));
  box_divider buf cols;
  let ko = state.ui_language = Lang_ko in
  let verdict_status_and_style (verdict : Tui_decode.harness_verdict) =
    let text = Terminal_text.single_line verdict.hv_verdict in
    let raw_ruling = match String.index_opt text ':' with
      | None -> text
      | Some index -> String.sub text 0 index in
    let has_fallback = Option.is_some verdict.hv_fallback_reason in
    let mark, style, ruling =
      harness_ruling_presentation ~ko ~has_fallback raw_ruling
    in
    let label =
      if has_fallback then ui_text state ~ko:"대체 · " ~en:"fallback · " ^ ruling
      else ruling
    in
    mark ^ " "
    ^ previous_reading_label state ~inflight:state.harness_inflight
        ~error:state.harness_error label,
    style
  in
  let col_hdr, verdict_row = judgement_list_columns state ~cols
      ~status_header:(ui_text state ~ko:"판정" ~en:"Verdict")
      ~statuses:(List.map (fun v -> fst (verdict_status_and_style v)) verdicts) in
  (* This is the newest record in the returned page, not evidence that the
     judge is running or has stopped. A retained page keeps its qualification
     while a new read is outstanding or failed. *)
  let latest_label =
    match state.harness with
    | Some _ when state.harness_inflight || Option.is_some state.harness_error ->
        ui_text state ~ko:"이전 판정" ~en:"Prior verdict"
    | Some _ | None -> ui_text state ~ko:"최근 판정" ~en:"Latest verdict"
  in
  let latest_record =
    match verdicts, state.harness with
    (* The producer also emits zero for an absent/unreadable timestamp. The
       current wire cannot distinguish that from the Unix epoch. *)
    | newest :: _, _ when Float.equal newest.hv_at 0.0 ->
        ui_text state ~ko:"시각 보고 안 됨" ~en:"time not reported"
    | newest :: _, _ ->
        (* The operator's zone (RFC tui-one-screen-grammar 6.1), not the
           server's ISO text. *)
        Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ()) newest.hv_at
    | [], None -> ui_text state ~ko:"미조회" ~en:"not read"
    | [], Some _ -> ui_text state ~ko:"이 페이지에 판정 없음" ~en:"none on this page"
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  %s: %s" latest_label latest_record);
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.harness_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let tail = Buffer.create 256 in
  box_bottom tail cols;
  Buffer.add_string tail
    (footer_line_keys state ~max_cells:cols
       ~keys:(Masc_tui_keys.footer_row_of_surface ~lang:state.ui_language ~detail_open:false
         ~has_rows:(shown > 0) state.view));
  (* Drawing and cursor/page movement consume the same state-owned bound.
     The timestamp makes five head rows and two tail rows; aggregate ledger
     rows are part of the selected detail document instead. *)
  let total_body =
    match scrolled_surface state ~cols Harness with
    | Some layout ->
        Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
          ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
    | None -> max 1 (rows - harness_listing_chrome ~error:state.harness_error)
  in
  let selected_verdict = List.nth_opt verdicts cursor in
  let split =
    Masc_tui_types.docked_vertical_split ~total_rows:total_body
      ~mode:state.harness_preview_mode
      ~has_selection:(shown > 0 && Option.is_some selected_verdict)
  in
  let content_height = max 1 split.list_rows in
  let preview_rows = max 0 (total_body - content_height) in
  let scroll =
    Masc_tui_scroll.ensure_visible ~cursor ~height:content_height
      state.harness_scroll
    |> Masc_tui_scroll.normalize ~count:shown ~height:content_height
  in
  let verdicts_window = Rows.of_list ~first:scroll ~height:content_height verdicts in
  report_drawn_list Harness_rows ~height:content_height;
  if shown = 0 then begin
    let style, empty =
      match empty_page_of ~snapshot:state.harness ~error:state.harness_error with
      | Page_failed -> Theme.recede (), page_failed_note ~ko
      | Page_unread ->
          (if state.harness_inflight then Theme.info () else Theme.recede ()),
          page_unread_note_while ~ko ~reading:state.harness_inflight
      | Page_empty ->
          Theme.recede (), ui_text state ~ko:"  (기록된 판정 없음)" ~en:"  (no verdicts recorded)"
    in
    box_line_styled buf cols ~style empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at verdicts_window idx with
      | None -> box_empty buf cols
      | Some v ->
          let open Masc.Tui_decode in
          let is_selected = idx = cursor in
          let status_text, status_style = verdict_status_and_style v in
          let line =
            verdict_row ~selected:is_selected ~status_style
              v.hv_task_title status_text
          in
          if is_selected then box_line_selected_styled buf cols line
          else box_line buf cols line
    done;
  (if preview_rows > 0 then
     match selected_verdict with
     | None ->
         for _ = 1 to preview_rows do
           box_empty buf cols
         done
     | Some v ->
         let inner = max 1 (framed_inner_width cols) in
         let ko = state.ui_language = Lang_ko in
         let t korean english = if ko then korean else english in
         let ruling, reason = split_verdict_ruling v in
         let verdict_tone = semantic_status_color ruling in
         let stage_label =
           match state.harness_preview_mode with
           | Preview_compact -> t "미리보기 확장" "expand"
           | Preview_half -> t "최대" "full"
           | Preview_full -> t "접기" "compact"
         in
         let fallback_rows =
           match v.hv_fallback_reason with
           | None -> []
           | Some fb ->
               [ Doc.kv ~tone:(Theme.warn ()) (t "대체 사유" "Fallback")
                   (Terminal_text.single_line fb) ]
         in
         let kv_body =
           Doc.kv_rows ~width:inner ~indent:0 ~max_label_cells:12
             ([ Doc.kv ~tone:(verdict_tone ^ Ansi.bold) (t "판정" "Verdict") ruling
              ; Doc.kv "Gate" (Terminal_text.single_line v.hv_gate)
              ; Doc.kv ~tone:Ansi.bold (t "에이전트" "Agent")
                  (Terminal_text.single_line v.hv_agent)
              ; Doc.kv ~tone:(Theme.recede ()) (t "평가자" "Evaluator")
                  (Terminal_text.single_line v.hv_evaluator)
              ]
              @ fallback_rows)
         in
         let prose_body =
           if preview_rows >= 7 && not (String.equal reason "") then
             [ "" ]
             @ Doc.prose_block ~width:inner ~indent:0
                 ~guide_style:(if String.equal verdict_tone "" then Theme.border_muted () else verdict_tone)
                 ~break_numbered:true reason
           else []
         in
         let preview_lines =
           Doc.docked_preview ~width:inner ~height:preview_rows ~indent:0
             ~eyebrow:(t "선택한 판정" "Selected Verdict")
             ~meta:(ruling ^ " · " ^ Terminal_text.single_line v.hv_gate)
             ~footer_hints:
               [ { Card.key = "Space"; label = stage_label }
               ; { Card.key = "Enter"; label = t "상세" "open" }
               ; { Card.key = "Esc"; label = t "닫기/뒤로" "back" }
               ]
             (kv_body @ prose_body)
         in
         List.iter (box_line buf cols) preview_lines);
  Buffer.add_buffer buf tail;
  finish_surface state ~surface_key:"harness" ~rows:terminal_rows ~cols buf

(* Which goals the judged task serves, and what those goals are aiming at.
   The verdict names a task, the task names its goals, and a goal carries the
   measure it is judged by -- three hops that were all present and never
   walked, so a verdict said "pass" without saying what it was passing
   towards. *)
let harness_goal_lines ~width (state : state) (verdict : Masc.Tui_decode.harness_verdict) =
  let t korean english = ui_text state ~ko:korean ~en:english in
  let towards = t "목표" "Towards" in
  let pre = List.map (fun s -> "", s) in
  let kv_list fields = Doc.kv_rows ~width ~indent:2 ~max_label_cells:12 fields |> pre in
  let goal_of id =
    Option.bind state.planning (fun snapshot ->
      List.find_opt
        (fun (goal : Tui_decode.planning_goal) -> String.equal goal.pg_id id)
        snapshot.Tui_decode.pl_goals)
  in
  match task_goal_reading state ~task_id:verdict.hv_task_id with
  | Masc_tui_agenda.Not_read ->
      kv_list [ Doc.kv ~tone:(Theme.recede ()) towards (t "목표 연결을 읽기 전" "goal links not read") ]
  | Read_failed _ ->
      kv_list [ Doc.kv ~tone:(Theme.warn ()) towards (t "목표 연결을 읽지 못함" "goal links unavailable") ]
  | Read [] ->
      let known_task =
        List.exists
          (fun (row : Masc_domain.task) -> String.equal row.id verdict.hv_task_id)
          (Masc_tui_types.task_domain_values state)
      in
      if known_task then
        kv_list [ Doc.kv ~tone:(Theme.recede ()) towards (t "이 태스크는 목표에 연결되지 않음" "this task is not linked to a goal") ]
      else
        kv_list [ Doc.kv ~tone:(Theme.recede ()) towards (t "판정한 태스크가 이 backlog 에 없음" "the judged task is not in this backlog") ]
  | Read goal_ids ->
      List.concat_map
        (fun id ->
           match goal_of id with
           | None ->
               kv_list
                 [ Doc.kv (t "목표" "Goal") (Terminal_text.single_line id)
                 ; Doc.kv ~tone:(Theme.recede ()) "" (Link.reference Goal id)
                 ]
           | Some goal ->
               let aim = Masc_tui_planning_detail.measure_text goal.pg_measure in
               kv_list
                 [ Doc.kv ~tone:Ansi.bold (t "목표" "Goal") (Terminal_text.single_line goal.pg_title)
                 ; Doc.kv ~tone:(Theme.ok ()) (t "지표" "Aim") (Terminal_text.single_line aim)
                 ; Doc.kv ~tone:(Theme.recede ()) "" (Link.reference Goal id)
                 ])
        goal_ids
;;

let harness_detail_lines ~ko ~width ~now (verdict : Masc.Tui_decode.harness_verdict) =
  let t korean english = if ko then korean else english in
  let pre = List.map (fun s -> "", s) in
  let raw_ruling, reason = split_verdict_ruling verdict in
  let ruling_mark, ruling_style, ruling_label =
    harness_ruling_presentation ~ko
      ~has_fallback:(Option.is_some verdict.hv_fallback_reason)
      raw_ruling
  in
  let ruling_badge = ruling_mark ^ " " ^ ruling_label in
  let title =
    Text_block.rows ~max_cells:(max 1 (width - 4)) verdict.hv_task_title
    |> List.map (fun line -> Ansi.bold, "  " ^ line)
  in
  let fallback =
    match verdict.hv_fallback_reason with
    | None ->
        pre
          (Doc.kv_rows ~width ~indent:2 ~max_label_cells:12
             [ Doc.kv ~tone:(Theme.recede ()) (t "대체 평가" "Fallback")
                 (t "없음 · 지정한 평가자가 답함" "none; the named evaluator answered")
             ])
    | Some fallback_reason ->
        [ (Theme.warn () ^ Ansi.bold, t "  대체 평가 사유" "  Fallback evaluation reason") ]
        @ pre (Doc.prose_block ~width ~indent:2 ~guide_style:(Theme.warn ()) ~break_numbered:true fallback_reason)
  in
  title
  @ [ "", "" ]
  @ pre [ Doc.section_rule ~width ~indent:2 ~badge:ruling_badge ~badge_tone:ruling_style
            (t "1. 판정 결과 · 사유" "1. Decision & Verdict") ]
  @ pre
      (Doc.kv_rows ~width ~indent:2 ~max_label_cells:12
         [ Doc.kv ~tone:(ruling_style ^ Ansi.bold) (t "판정" "Verdict") ruling_badge
         ; Doc.kv (t "게이트" "Gate") verdict.hv_gate
         ; Doc.kv (t "평가자" "Evaluator") verdict.hv_evaluator
         ; Doc.kv ~tone:(Theme.recede ()) (t "기록 시각" "Recorded")
             (if Float.equal verdict.hv_at 0.0 then t "시각 보고 안 됨" "time not reported"
              else Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now verdict.hv_at)
         ])
  @ (if reason = "" then []
     else
       [ "", ""
       ; (Ansi.bold, "  " ^ t "사유" "Reason")
       ]
       @ pre (Doc.prose_block ~width ~indent:2
                ~guide_style:(if ruling_style = "" then Theme.border_muted () else ruling_style)
                ~break_numbered:true reason))
  @ (if fallback = [] then [] else [ "", "" ] @ fallback)
  @ [ "", "" ]
  @ pre [ Doc.section_rule ~width ~indent:2 (t "2. 대상 태스크 · 에이전트" "2. Task & Agent") ]
  @ pre
      (Doc.kv_rows ~width ~indent:2 ~max_label_cells:12
         [ Doc.kv (t "태스크" "Task") verdict.hv_task_id
         ; Doc.kv ~tone:(Theme.recede ()) (t "태스크 링크" "Task link") (Link.reference Task verdict.hv_task_id)
         ; Doc.kv ~tone:Ansi.bold (t "에이전트" "Agent") verdict.hv_agent
         ])

let harness_detail_pane (state : state) ~rows ~cols verdict buf =
  let width = max 1 (framed_inner_width cols) in
  let goal_lines = harness_goal_lines ~width state verdict in
  let ledger_section_num = if goal_lines = [] then 3 else 4 in
  let lines =
    reading_notice_lines state ~width
      ~inflight:state.harness_inflight
      ~error:(Option.map (fun detail -> Last_error detail) state.harness_error)
    @ harness_detail_lines ~ko:(state.ui_language = Lang_ko)
        ~width ~now:(Unix.gettimeofday ()) verdict
    @ (match goal_lines with
       | [] -> []
       | lines ->
           [ "", ""; "", Doc.section_rule ~width ~indent:2 (ui_text state ~ko:"3. 연결된 목표" ~en:"3. Towards Goals") ]
           @ lines)
    @ (match harness_ledger_lines ~ko:(state.ui_language = Lang_ko) ~cols state.harness with
       | [] -> []
       | lines ->
           [ "", ""
           ; "", Doc.section_rule ~width ~indent:2
                   (Printf.sprintf "%d. %s" ledger_section_num
                      (ui_text state ~ko:"전체 판정 집계" ~en:"All Verdicts"))
           ]
           @ List.map (fun line -> "", line) lines)
    |> judgement_detail_rows ~width
  in
  let content_height = max 1 (rows - max 0 (framed_chrome_rows - 2)) in
  report_drawn_list Harness_detail_rows ~height:content_height;
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.harness_detail_scroll max_scroll) in
  box_line buf cols
    (zone_two_title ~cols state
       ~title:
         (let task_label =
            if String.equal (String.trim verdict.Masc.Tui_decode.hv_task_title) "" then
              resolve_task_title state verdict.hv_task_id
            else Terminal_text.single_line verdict.hv_task_title
          in
          harness_detail_heading state
            ~task_id:task_label
            ~tail:(Option.value ~default:"" (reading_connection_notice state)))
       ~position:
         (Masc_tui_value.Position.window ~first:scroll ~shown:content_height
            ~total:(List.length lines)));
  box_divider buf cols;
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  scroll
;;

(* The verdict list stays beside the verdict. A verdict is a judgement
   about one task among many, and which ones came out the same way is
   most of what it means. Below the split width the detail keeps the
   screen. *)
let render_harness_detail (state : state) verdict =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll = harness_detail_pane state ~rows ~cols verdict buf in
  Buffer.add_string buf
    (* The key table, not a literal. This row was written out here, and what
       it left out was the pair that answers a ruling -- [y / x] -- on the one
       screen that exists for reading a ruling in full. It also left out
       [[ / ]], which the dispatcher answers here and only here. *)
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:true Masc_tui_types.Harness));
  finish_surface state ~clamped:(Harness_detail_scroll scroll)
    ~surface_key:"harness-detail" ~rows:terminal_rows ~cols buf

let render_harness (state : state) =
  match state.harness_detail, state.harness with
  | Some (task_id, at), Some snapshot ->
      (match
         List.find_opt
           (fun verdict ->
              String.equal verdict.Masc.Tui_decode.hv_task_id task_id
              && Float.equal verdict.hv_at at)
           snapshot.Masc.Tui_decode.hs_verdicts
       with
       | Some verdict -> render_harness_detail state verdict
       | None -> render_harness_list state)
  | Some _, None | None, _ -> render_harness_list state


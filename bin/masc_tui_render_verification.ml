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

let review_label state = function
  | Review_unobserved -> ui_text state ~ko:"미관측" ~en:"not observed"
  | Review_running _ -> ui_text state ~ko:"검증 중" ~en:"reviewing"
  | Review_waiting_original _ -> ui_text state ~ko:"원 실행 확인" ~en:"checking original"
  | Review_stopped {cause=Review_original_repair;_} ->
      ui_text state ~ko:"확인 필요" ~en:"repair needed"
  | Review_stopped {cause=(Review_environment | Review_no_judgment | Review_commit_failure
      | Review_failure | Review_cancelled);_} -> ui_text state ~ko:"중단" ~en:"stopped"
  | Review_approved _ -> ui_text state ~ko:"승인 기록" ~en:"approved"
  | Review_rejected _ -> ui_text state ~ko:"반려 기록" ~en:"rejected"
  | Review_superseded _ -> ui_text state ~ko:"다른 판정 적용" ~en:"superseded"

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
  let row title status =
    "  " ^ fit_width (Terminal_text.single_line title) title_width
    ^ "  " ^ fit_width status status_width in
  row (ui_text state ~ko:"작업" ~en:"Task") status_header, row

let reading_notice_lines state ~width ~inflight ~error =
  let notice = match error, inflight with
    | None, false -> None
    | None, true -> Some (Theme.recede (),
        ui_text state ~ko:"재조회 중 · 이전 조회 자료" ~en:"Refreshing · previous reading")
    | Some detail, refreshing ->
        let prefix = if refreshing then
            ui_text state ~ko:"재조회 중 · 이전 자료 · 마지막 오류: "
              ~en:"Refreshing · previous reading · last error: "
          else ui_text state ~ko:"이전 자료 · 현재 상태 미확인: "
              ~en:"Previous reading · current state unconfirmed: " in
        Some (Theme.warn (), prefix ^ detail) in
  match notice with
  | None -> []
  | Some (style, text) ->
      Message_layout.wrap_body ~max_cells:(max 1 (width - 4))
        ~sanitize:Keeper_chat.terminal_safe_text text
      |> List.map (fun line -> style, "  " ^ line)

let verification_status state (request : Tui_decode.verification_request) =
  let label = match request.vr_evidence_error with
    | Some _ -> ui_text state ~ko:"증거 읽기 실패" ~en:"evidence error"
    | None -> review_label state request.vr_review in
  previous_reading_label state ~inflight:state.verification_inflight
    ~error:state.verification_error label

let review_detail = function
  | Review_unobserved -> "자동 검증의 실행 기록이 아직 관측되지 않았습니다."
  | Review_running actor -> "자동 검증자가 증거를 확인하고 있습니다: " ^ actor
  | Review_waiting_original {detail;actor} ->
    "기존 검증 실행의 기록을 확인하고 있습니다. 모델 재호출은 예약하지 않습니다. " ^ actor ^ " · " ^ detail
  | Review_stopped {cause; detail; actor} ->
    let reason = match cause with
      | Review_environment -> "검증 환경에 접근하지 못했습니다."
      | Review_no_judgment -> "검증자가 판정을 내리지 못했습니다."
      | Review_commit_failure -> "검증 결과를 Task에 반영하지 못했습니다."
      | Review_original_repair -> "원 실행의 결과를 확정할 수 없어 운영자 확인이 필요합니다."
      | Review_failure -> "검증 실행이 중단되었습니다."
      | Review_cancelled -> "검증 실행이 취소되었습니다." in
    reason ^ " " ^ actor ^ " · " ^ detail
  | Review_approved reason -> "승인 판정이 기록되었습니다. Task 완료 여부는 Task 상태에서 확인합니다. " ^ reason
  | Review_rejected reason -> "반려 판정이 기록되었습니다. " ^ reason
  | Review_superseded actor -> "다른 판정이 먼저 적용되었습니다: " ^ actor

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
  let header =
    match state.verification with
    | None ->
        let reading_note =
          match state.verification_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        let after =
          Printf.sprintf "  %s  %s" reading_note (connection_badge state)
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
          if total > 0 && shown >= total then ""
          else
            Printf.sprintf " (%s of %s)" (Masc_tui_value.Count.grouped shown)
              (Masc_tui_value.Count.grouped total)
        in
        Printf.sprintf "%s  %s"
          (planning_workspace_title state ~cols ~tab:Planning_task_review ~window
             ~after:("  " ^ connection_badge state))
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr, request_row =
    judgement_list_columns state ~cols
      ~status_header:(ui_text state ~ko:"자동 검증" ~en:"Review")
      ~statuses:(List.map (verification_status state) requests) in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.verification_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The height the keypress bounds its step with, asked of the same layout:
     it counts the rows drawn under the list as well as the frame. *)
  let content_height =
    match scrolled_surface state ~cols Verification with
    | Some layout ->
        Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
          ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
          ~overflow_takes_row:layout.sc_overflow_takes_row
    | None -> max 1 (rows - listing_chrome ~error:state.verification_error)
  in
  let scroll = Masc_tui_scroll.ensure_visible ~cursor:state.verification_cursor
      ~height:content_height state.verification_scroll
    |> Masc_tui_scroll.normalize ~count:shown ~height:content_height in
  let requests_window = Rows.of_list ~first:scroll ~height:content_height requests in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.verification
          ~error:state.verification_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note_while ~reading:state.verification_inflight
      | Page_empty -> "  (nothing waiting on a verdict)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at requests_window idx with
      | None -> box_empty buf cols
      | Some r ->
          let open Masc.Tui_decode in
          let line = request_row r.vr_task_title (verification_status state r) in
          let style =
            match r.vr_evidence_error with
            | Some _ -> (Theme.bad ())
            | None -> Ansi.reset
          in
          if idx = state.verification_cursor then box_line_selected buf cols line
          else box_line_styled buf cols ~style line
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
             Printf.sprintf "awaiting %s" (Masc_tui_value.Count.grouped total)
         | Masc.Tui_decode.Full_history ->
             let total = Masc_tui_value.Count.grouped total in
             if shown = 0 then Printf.sprintf "history 0 of %s" total
             else
               Printf.sprintf "history %s-%s of %s"
                 (Masc_tui_value.Count.grouped (offset + 1))
                 (Masc_tui_value.Count.grouped (offset + shown)) total
       in
       let rows_window =
         if shown > content_height then
           Printf.sprintf " \xc2\xb7 rows %s"
             (Masc_tui_scroll.window_text ~scroll ~height:content_height shown)
         else ""
       in
       (* Named because the key is not on the footer of a narrow terminal, and
          a page with more behind it that says so is the difference between
          "that is all" and "there is more". *)
       let more =
         if snapshot.Masc.Tui_decode.vs_truncated then " \xc2\xb7 > next page"
         else ""
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "[%s%s%s]" place rows_window more);
       (* An empty queue carrying a reason is not an empty queue. *)
       (match snapshot.Masc.Tui_decode.vs_backlog_error with
        | Some detail ->
            box_line_styled buf cols ~style:(Theme.bad ())
              (Printf.sprintf "  the queue could not be read: %s"
                 (Terminal_text.single_line detail))
        | None -> ());
       (* A queue built from a recovery snapshot is a queue of real rows that
          is older than the workspace. Drawn, because the rows themselves look
          exactly like a current queue and nothing else on this screen would
          say otherwise. *)
       (match snapshot.Masc.Tui_decode.vs_backlog_recovery with
        | Some detail ->
            box_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "  this queue is as old as the snapshot it came from: %s"
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
              (Printf.sprintf "  waiting on a record this store does not hold: %s%s"
                 (String.concat ", " named)
                 (if rest > 0 then Printf.sprintf " (+%d)" rest else ""))));
  (* The arm and the server's last refusal sit under the list, the same rows
     the schedule cancel carries them on. *)
  (match state.verification_verdict_armed with
   | Some (task_id, request_id) ->
       (* No width padding on the id: padding to a reserved column pushes the
          "same key again" tail past the box on a narrow terminal, and the
          tail is the half that instructs. *)
       box_line buf cols
         ((Theme.warn ())
         ^ Printf.sprintf "  armed: approve %s -- same key again to send [%s]"
             (Terminal_text.single_line task_id)
             (Terminal_text.single_line request_id)
         ^ Ansi.reset)
   | None -> ());
  (match state.verification_verdict_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  "
         ^ fit_width (Terminal_text.single_line err) (framed_inner_width cols - 4)
         ^ Ansi.reset)
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:false ~has_rows:(shown > 0)
            state.view));
  finish_surface state ~surface_key:"verification" ~rows:terminal_rows ~cols buf

(* Complete judgement metadata is a physical document. Rows that fit keep
   their field alignment; longer rows remain literal and reachable by scroll. *)
let judgement_detail_rows = Masc_tui_render_evidence.wrap_rows

let verification_detail_lines ~width
    (request : Masc.Tui_decode.verification_request) =
  let wrap style text = Message_layout.wrap_body ~max_cells:(max 1 (width - 4))
    ~sanitize:Keeper_chat.terminal_safe_text text
    |> List.map (fun line -> style, "  " ^ line) in
  wrap Ansi.bold request.vr_task_title
  @ wrap (match request.vr_review with
      | Review_stopped _ -> Theme.warn ()
      | Review_waiting_original _ -> Theme.warn ()
      | Review_unobserved | Review_running _ | Review_approved _ | Review_rejected _
      | Review_superseded _ -> Ansi.reset)
      (review_detail request.vr_review)
  @ wrap (Theme.recede ()) (Printf.sprintf "제출 증거 %d개 · 요구 증거 %d항목 · 개수는 충족 여부가 아닙니다."
      (List.length request.vr_submitted_evidence) (List.length request.vr_required_artifacts))
  @ (match request.vr_evidence_error with None -> [] | Some detail -> wrap (Theme.bad ()) detail)

let verification_contract_lines state ~width (request : Masc.Tui_decode.verification_request) =
  let wrap text = Message_layout.wrap_body ~max_cells:(max 1 (width - 4))
    ~sanitize:Keeper_chat.terminal_safe_text text
    |> List.map (fun line -> Ansi.reset, "  " ^ line) in
  [Ansi.dim, ""; Ansi.bold, "  완료 조건"]
  @ List.concat_map (fun text -> wrap ("• " ^ text)) request.vr_completion_contract
  @ [Ansi.bold, "  요구 증거"]
  @ (if request.vr_required_artifacts = [] then wrap "별도 요구 목록이 없습니다."
     else List.concat_map (fun text -> wrap ("• " ^ text)) request.vr_required_artifacts)
  @ [Ansi.dim, ""; Ansi.bold, "  제출 정보"]
  @ wrap ("Task: " ^ request.vr_task_id ^ " · 제출자: " ^ request.vr_submitted_by)
  @ wrap ("제출 시각: " ^ request.vr_created_at)
  @ wrap ("서버의 저장 기록: " ^
      (match state.server_identity with
       | Some identity -> Filename.concat (Canonical_path.to_string identity.sid_masc_root)
           ("verifications/" ^ request.vr_request_id ^ ".json")
       | None -> "workspace 미확인 · verifications/" ^ request.vr_request_id ^ ".json"))

let evidence_name = function
  | Masc_tui_evidence_picture.Source_item {source=Ev_collaboration {ev_reference;_};_} ->
    "협업 기록 · " ^ ev_reference
  | Masc_tui_evidence_picture.Source_item
      {source=(Ev_note _ | Ev_artifact _ | Ev_artifact_unreadable _ | Ev_binary _);_} -> "협업 기록"
  | Masc_tui_evidence_picture.Text_item item -> (match item with
      | Ev_note note -> "메모 · " ^ Terminal_text.single_line note
      | Ev_collaboration {ev_reference; _} -> "협업 기록 · " ^ ev_reference
      | Ev_artifact {ev_reference; ev_bytes; ev_truncated; _} ->
        Printf.sprintf "파일 · %s · %dB%s" ev_reference ev_bytes (if ev_truncated then " · 일부만 저장됨" else "")
      | Ev_artifact_unreadable {ev_u_reference; ev_u_reason} ->
        "읽을 수 없음 · " ^ Option.value ev_u_reference ~default:"참조 없음" ^ " · " ^ ev_u_reason
      | Ev_binary {ev_b_reference; _} -> "파일 · " ^ ev_b_reference)
  | Masc_tui_evidence_picture.Binary_item {reference; bytes; format; _} ->
    Printf.sprintf "이미지/바이너리 · %s · %s · %dB" reference format bytes

let verification_evidence_index state request ~width observation =
  match observation with
  | Masc_tui_fetched.Ready (Masc_tui_evidence_picture.Items items)
  | Stale (Masc_tui_evidence_picture.Items items, _) ->
    let count = List.length items in
    let index = max 0 (min (count - 1) state.verification_evidence_cursor) in
    let rows = List.mapi (fun i item ->
      (if i = index then Theme.category Theme.Slot_1 else Theme.recede ()),
      Printf.sprintf "  %s %d. %s" (if i = index then "▸" else " ") (i + 1)
        (fit_width (Terminal_text.single_line (evidence_name item)) (max 1 (width - 9)))) items in
    let rows = if state.verification_evidence_index_open then rows
      else Option.to_list (List.nth_opt rows index) in
    let location = Printf.sprintf
      (if state.ui_language = Lang_ko then
         "  원본 참조는 제출자 %s의 작업 공간 기준입니다. 여기서는 제출 시 저장한 사본을 읽습니다."
       else
         "  Original references are relative to submitter %s's workspace; this view reads the snapshot saved at submission.")
      request.vr_submitted_by in
    judgement_detail_rows ~width ([Ansi.bold, Printf.sprintf "  증거 %d / %d · e/E 다음/이전 · i 목록 · o 열기 · s 저장" (if count = 0 then 0 else index + 1) count]
      @ rows @ [Theme.recede (), location]
      @ List.filter_map (fun (key, saved_index, progress) ->
          if key.vek_request_id = request.vr_request_id
             && key.vek_task_id = request.vr_task_id && saved_index = index
          then (match progress with
            | Masc_tui_evidence_file.Not_started -> None
            | Writing path -> Some (Theme.warn (), "  저장 시도 경로(완료 미확인): " ^ path)
            | Saved path -> Some (Ansi.reset, "  이 기기에 저장한 파일: " ^ path)
            | Aborted path -> Some (Theme.warn (), "  저장하지 못한 목적지: " ^ path))
          else None)
          state.verification_evidence_saved), index
  | Absent | Loading | Failed _ | Ready (Masc_tui_evidence_picture.Access_unavailable _)
  | Stale (Masc_tui_evidence_picture.Access_unavailable _, _) -> [], 0

let verification_detail_pane (state : state) ~rows ~cols
    ~origin:(origin_row, origin_col) request buf =
  let pane_start = Buffer.length buf in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s"
       (planning_workspace_title state ~cols ~tab:Planning_task_review ~window:""
          ~after:
            (Printf.sprintf " \xe2\x96\xb8 details  %s"
               (Terminal_text.single_line request.Masc.Tui_decode.vr_task_id))
        ^ " \xe2\x96\xb8 details")
       (Terminal_text.single_line request.Masc.Tui_decode.vr_task_id));
  box_divider buf cols;
  (* The frame cell of the first content row, counted from what was drawn
     above it, for the pictures placed over the rows under it. *)
  let content_origin =
    ( origin_row + lines_ended_since buf ~start:pane_start
    , origin_col + framed_content_column )
  in
  let width = max 1 (framed_inner_width cols) in
  let armed_note =
    match state.verification_verdict_armed with
    | Some (task_id, request_id)
      when String.equal task_id request.Masc.Tui_decode.vr_task_id
           && String.equal request_id request.vr_request_id ->
        Some (Printf.sprintf "  ARMED: a again to approve %s [%s]"
          (Terminal_text.single_line task_id)
          (Terminal_text.single_line request_id))
    | Some _ | None -> None
  in
  let verdict_action = "  a 두 번: 운영자 승인 · x: 사유와 함께 반려 · j/k: 스크롤" in
  let verdict_action_rows =
    if Message_layout.display_width verdict_action <= width then
      [ verdict_action ]
    else [ "  a 두 번: 운영자 승인"; "  x: 사유와 함께 반려 · j/k: 스크롤" ]
  in
  (* The position and action rows are fixed chrome; subtract exactly what
     this pane draws so the reported window matches the visible body. *)
  let fixed_rows =
    1 + List.length verdict_action_rows
      + (if Option.is_some armed_note then 1 else 0)
      + (if Option.is_some state.verification_verdict_error then 1 else 0)
  in
  let content_height = max 1 (rows - framed_chrome_rows - fixed_rows) in
  (* The three parts are wrapped apart so the evidence section's row index is
     known: wrapping is per row, so this is the same rows as wrapping once. *)
  let before = judgement_detail_rows ~width
      (reading_notice_lines state ~width ~inflight:state.verification_inflight
         ~error:state.verification_error
       @ verification_detail_lines ~width request) in
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
    Masc_tui_render_evidence.section ~selection:(Some selected_index)
      ~evidence:observation
      ~in_flight ~workspace_confirmed:(server_authority_ready state) ~width ~content_height
      ~display:(Masc_tui_portrait_view.current_display ())
  in
  let after =
    ((match armed_note with None -> [] | Some note -> [Theme.warn (), note])
     @ (match state.verification_verdict_error with
        | None -> []
        | Some detail -> [Theme.bad (), "  Verdict action failed: " ^ Terminal_text.single_line detail]))
    |> judgement_detail_rows ~width
  in
  let evidence_first = List.length before in
  let lines = before @ evidence @ verification_contract_lines state ~width request @ after in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.verification_detail_scroll max_scroll) in
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
    (fun err -> box_line_styled buf cols ~style:(Theme.bad ())
      (fit_width ("  " ^ Terminal_text.single_line err) (framed_inner_width cols)))
    state.verification_verdict_error;
  (* This reading has its own pane row: pinned footer keys can consume the
     whole footer at 30 and 40 columns, leaving its trailing position cut. *)
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf "  [rows %s]"
       (Masc_tui_scroll.window_text ~scroll ~height:content_height
          (List.length lines)));
  List.iter
    (box_line_styled buf cols ~style:(Theme.warn ()))
    verdict_action_rows;
  box_bottom buf cols;
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
              Render_schedule.task_history_sidebar_label
                ~task_id:row.Tui_decode.vr_task_id
                ~apart:(Some row.Tui_decode.vr_request_id))
            snapshot.Tui_decode.vs_requests
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* One server page: the list screen next door draws "history 1-50 of
         664" off the same snapshot, and this index drew "(50)". *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Task Review"
        ~focused:false
        ~holding:
          (Option.map
             (fun (snapshot : Tui_decode.verification_snapshot) ->
               snapshot.Tui_decode.vs_total)
             state.verification)
        ~labels ~selected:state.verification_cursor;
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
let harness_ledger_lines ~cols snapshot =
  match snapshot with
  | None -> []
  | Some snapshot -> (
      match snapshot.Masc.Tui_decode.hs_calibration with
      | None -> []
      | Some calibration ->
          let open Masc.Tui_decode in
          if calibration.hcal_total <= 0 then []
          else
            let share count =
              100. *. float_of_int count /. float_of_int calibration.hcal_total
            in
            (* Banded over every gate, then cut to the four that fit. The
               tail is where the small ones are, so ranking only what is
               drawn would rank four leaders out of four. *)
            let gates =
              Magnitude.of_counts calibration.hcal_gates
              |> List.filteri (fun index _ -> index < 4)
              |> List.map (fun (gate, count, band) ->
                     Printf.sprintf "%s%s %d (%.0f%%)%s" (magnitude_tone band)
                       gate count (share count) Ansi.reset)
              |> String.concat "  \xc2\xb7  "
            in
            let remaining = max 0 (List.length calibration.hcal_gates - 4) in
            let gates =
              if remaining = 0 then gates
              else Printf.sprintf "%s  \xc2\xb7  +%d more" gates remaining
            in
            let evaluator =
              match snapshot.hs_overview with
              | None -> ""
              | Some overview ->
                  Printf.sprintf "  \xc2\xb7  evaluator %s"
                    (Terminal_text.single_line overview.hov_evaluator_status)
            in
            [ Printf.sprintf "  %sledger%s  %d ruled  \xc2\xb7  approve %d  \xc2\xb7  reject %d%s"
                Ansi.dim Ansi.reset calibration.hcal_total
                calibration.hcal_approve calibration.hcal_reject evaluator
            ; row_with_field ~cols
                ~lead:(Printf.sprintf "  %sgate%s    " Ansi.dim Ansi.reset)
                ~field:gates ~tail:""
            ; (if calibration.hcal_labeled > 0 then
                 Printf.sprintf "  %slabelled%s %d" Ansi.dim Ansi.reset
                   calibration.hcal_labeled
               else
                 Printf.sprintf
                   "  %slabelled%s none \xe2\x80\x94 agreement and the error counts have no ground truth"
                   Ansi.dim Ansi.reset)
            ])

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
  let header =
    match state.harness with
    | None ->
        let reading_note =
          match state.harness_error with
          | None -> here_missing_reading state ~error:None
          | Some _ -> ""
        in
        let after =
          Printf.sprintf "  %s  %s" reading_note (connection_badge state)
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
              Printf.sprintf " of %d"
                calibration.Masc.Tui_decode.hcal_total
          | Some _ | None -> ""
        in
        let by_fallback =
          if fallbacks > 0 then Printf.sprintf ", %d by fallback" fallbacks
          else ""
        in
        Printf.sprintf "%s  %s"
          (planning_workspace_title state ~cols ~tab:Planning_verdicts
             ~window:
               (Printf.sprintf " (%d%s%s)" shown of_total by_fallback)
             ~after:("  " ^ connection_badge state))
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let verdict_status (verdict : Tui_decode.harness_verdict) =
    let text = Terminal_text.single_line verdict.hv_verdict in
    let ruling = match String.index_opt text ':' with
      | None -> text
      | Some index -> String.sub text 0 index in
    let label = match verdict.hv_fallback_reason with
      | None -> ruling
      | Some _ -> ui_text state ~ko:"대체 · " ~en:"fallback · " ^ ruling in
    previous_reading_label state ~inflight:state.harness_inflight
      ~error:state.harness_error label in
  let col_hdr, verdict_row = judgement_list_columns state ~cols
      ~status_header:(ui_text state ~ko:"판정" ~en:"Verdict")
      ~statuses:(List.map verdict_status verdicts) in
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
        ui_text state ~ko:"시각 미관측" ~en:"time not observed"
    | newest :: _, _ -> Masc_domain.iso8601_of_unix_seconds newest.hv_at
    | [], None -> ui_text state ~ko:"미관측" ~en:"not observed"
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
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:false ~has_rows:(shown > 0)
         state.view));
  (* Drawing and cursor/page movement consume the same state-owned bound.
     The timestamp makes six head rows and two tail rows; aggregate ledger
     rows are part of the selected detail document instead. *)
  let content_height =
    match scrolled_surface state ~cols Harness with
    | Some layout -> Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
        ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
        ~overflow_takes_row:layout.sc_overflow_takes_row
    | None -> max 1 (rows - harness_listing_chrome ~error:state.harness_error) in
  let scroll = Masc_tui_scroll.ensure_visible ~cursor:state.harness_cursor
      ~height:content_height state.harness_scroll
    |> Masc_tui_scroll.normalize ~count:shown ~height:content_height in
  let verdicts_window = Rows.of_list ~first:scroll ~height:content_height verdicts in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.harness ~error:state.harness_error with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note_while ~reading:state.harness_inflight
      | Page_empty -> ui_text state ~ko:"  (기록된 판정 없음)" ~en:"  (no verdicts recorded)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
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
          let line = verdict_row v.hv_task_title (verdict_status v) in
          let style =
            match v.hv_fallback_reason with
            | Some _ -> (Theme.warn ())
            | None -> Ansi.reset
          in
          if idx = state.harness_cursor then box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [verdicts %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  Buffer.add_buffer buf tail;
  finish_surface state ~surface_key:"harness" ~rows:terminal_rows ~cols buf

(* Which goals the judged task serves, and what those goals are aiming at.
   The verdict names a task, the task names its goals, and a goal carries the
   metric it is measured by -- three hops that were all present and never
   walked, so a verdict said "pass" without saying what it was passing
   towards. *)
(* The label column of the verdict detail, in display cells: a Korean label
   is padded by what it occupies, not by its bytes. *)
let harness_label_cells = 12

let harness_labeled label value =
  Printf.sprintf "  %s %s" (Message_layout.fit_width label harness_label_cells) value

let harness_goal_lines (state : state) (verdict : Masc.Tui_decode.harness_verdict) =
  let t korean english = ui_text state ~ko:korean ~en:english in
  let towards = t "목표" "Towards" in
  let goal_of id =
    Option.bind state.planning (fun snapshot ->
      List.find_opt
        (fun (goal : Tui_decode.planning_goal) -> String.equal goal.pg_id id)
        snapshot.Tui_decode.pl_goals)
  in
  match task_goal_reading state ~task_id:verdict.hv_task_id with
  | Masc_tui_agenda.Not_read ->
    [ Ansi.dim, harness_labeled towards (t "목표 연결을 읽기 전" "goal links not read") ]
  | Read_failed _ ->
    [ Ansi.dim, harness_labeled towards (t "목표 연결을 읽지 못함" "goal links unavailable") ]
  | Read [] ->
    (* Two different silences, told apart. A task this screen has never seen
       (the backlog has not loaded, or the verdict judged something already
       archived) is not the same as a task that serves no goal, and drawing
       nothing for both leaves the reader unable to tell which. *)
    let known_task =
      List.exists
        (fun (row : Masc_domain.task) -> String.equal row.id verdict.hv_task_id)
        (Masc_tui_types.task_domain_values state)
    in
    if known_task then
      [ Ansi.dim
        , harness_labeled towards
            (t "이 태스크는 목표에 연결되지 않음" "this task is not linked to a goal") ]
    else
      [ Ansi.dim
        , harness_labeled towards
            (t "판정한 태스크가 이 backlog 에 없음" "the judged task is not in this backlog") ]
  | Read goal_ids ->
    (Ansi.bold, t "  목표" "  TOWARDS")
    :: List.concat_map
         (fun id ->
           match goal_of id with
           | None ->
             (* Linked to a goal this snapshot does not carry -- terminal, or
                simply not in the page that was fetched. Named rather than
                dropped: the link is a fact even when the goal is not here. *)
             [ Ansi.reset, harness_labeled (t "목표" "Goal") (Terminal_text.single_line id)
             ; Ansi.dim, harness_labeled "" (Link.reference Goal id)
             ]
           | Some goal ->
             let aim =
               match goal.pg_metric, goal.pg_target_value with
               | Some metric, Some target -> Printf.sprintf "%s -> %s" metric target
               | Some metric, None -> metric
               | None, Some target -> t "목표값 " "target " ^ target
               | None, None -> t "선언한 지표 없음" "no metric declared"
             in
             [ Ansi.reset,
               harness_labeled (t "목표" "Goal") (Terminal_text.single_line goal.pg_title)
             ; Ansi.reset, harness_labeled (t "지표" "Aim") (Terminal_text.single_line aim)
             ; Ansi.dim, harness_labeled "" (Link.reference Goal id)
             ])
         goal_ids
;;

let harness_detail_lines ~ko ~width (verdict : Masc.Tui_decode.harness_verdict) =
  let t korean english = if ko then korean else english in
  let field ?(style = Ansi.reset) label value =
    style, harness_labeled label (Terminal_text.single_line value)
  in
  let wrapped label text =
    (Ansi.bold, "  " ^ label)
    :: (Message_layout.wrap_body
          ~max_cells:(max 1 (width - 6))
          ~sanitize:Keeper_chat.terminal_safe_text text
        |> List.map (fun line -> Ansi.reset, "    " ^ line))
  in
  let fallback =
    match verdict.hv_fallback_reason with
    | None ->
        [ Ansi.dim
        , harness_labeled (t "대체 평가" "Fallback")
            (t "없음 · 지정한 평가자가 답함" "none; the named evaluator answered") ]
    | Some reason ->
        [ (Theme.warn ()), t "  대체 평가" "  FALLBACK EVALUATION" ]
        @ wrapped
            (t "요청한 평가자가 돌지 못한 이유" "Why the requested evaluator did not run")
            reason
  in
  let ruling, reason =
    let whole = verdict.hv_verdict in
    match String.index_opt whole ':' with
    | None -> Terminal_text.single_line whole, ""
    | Some at ->
        ( Terminal_text.single_line (String.sub whole 0 at)
        , String.trim
            (String.sub whole (at + 1) (String.length whole - at - 1)) )
  in
  let title = Message_layout.wrap_body ~max_cells:(max 1 (width - 4))
      ~sanitize:Keeper_chat.terminal_safe_text verdict.hv_task_title
    |> List.map (fun line -> Ansi.bold, "  " ^ line)
  in
  title
  @ detail_section_heading (t "1. 판정 결과 · 사유" "1. Decision & Verdict")
  @ [ field ~style:(semantic_status_color ruling) (t "판정" "Verdict") ruling
    ; field "Gate" verdict.hv_gate
    ; field (t "평가자" "Evaluator") verdict.hv_evaluator
    ; field (t "기록 시각" "Recorded")
        (Masc_domain.iso8601_of_unix_seconds verdict.hv_at)
    ]
  (* The reason a task was rejected or approved is the sentence the operator came
     here to read, and it runs long. [field] is one [single_line], so it was cut at
     the pane's width and the rest existed nowhere on the surface. The title
     above already wraps for the same reason. *)
  @ (if reason = "" then [] else wrapped (t "사유" "Reason") reason)
  @ fallback
  @ detail_section_heading (t "2. 대상 태스크 · 에이전트" "2. Task & Agent")
  @ [ field (t "태스크" "Task") verdict.hv_task_id
    ; field (t "태스크 링크" "Task link") (Link.reference Task verdict.hv_task_id)
    ; field (t "에이전트" "Agent") verdict.hv_agent
    ]

let harness_detail_pane (state : state) ~rows ~cols verdict buf =
  box_top buf cols;
  box_line buf cols
    (harness_detail_heading state ~cols
       ~task_id:verdict.Masc.Tui_decode.hv_task_id
       ~tail:(connection_badge state));
  box_divider buf cols;
  let lines =
    reading_notice_lines state ~width:(max 1 (framed_inner_width cols))
      ~inflight:state.harness_inflight ~error:state.harness_error
    @ harness_detail_lines ~ko:(state.ui_language = Lang_ko)
        ~width:(max 1 (framed_inner_width cols)) verdict
    (* Appended rather than woven in: the verdict block is what the server
       said, and what the task is aiming at is read from two other surfaces.
       Keeping them in that order keeps the judged fact above the context. *)
    @ (match harness_goal_lines state verdict with
       | [] -> []
       | goal_lines ->
           detail_section_heading (ui_text state ~ko:"3. 연결된 목표" ~en:"3. Towards Goals")
           @ goal_lines)
    @ (match harness_ledger_lines ~cols state.harness with
       | [] -> []
       | lines ->
           detail_section_heading (ui_text state ~ko:"전체 판정 집계" ~en:"All Verdicts")
           @ List.map (fun line -> Ansi.reset, line) lines)
    |> judgement_detail_rows ~width:(max 1 (framed_inner_width cols))
  in
  let content_height = max 1 (rows - framed_chrome_rows - 1) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.harness_detail_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  (* Keep the reading inside the pane: the way out can occupy the entire
     key footer at narrow widths, leaving no room for a trailing position. *)
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf "  [rows %s]"
       (Masc_tui_scroll.window_text ~scroll ~height:content_height
          (List.length lines)));
  box_bottom buf cols;
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
  let scroll =
    if cols < keeper_split_threshold_cols then
      harness_detail_pane state ~rows ~cols verdict buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.harness with
        | None -> []
        | Some snapshot ->
          (* A verdict has no id of its own on the wire. The notes hash is
             shared by repeat verdicts on one submission, and a clock alone
             can name several verdicts recorded in the same second. *)
          snapshot.Tui_decode.hs_verdicts
          |> List.map (fun (row : Tui_decode.harness_verdict) ->
               row.hv_task_id, row.hv_at)
          |> Render_schedule.verdict_sidebar_labels
               ~now:(Unix.gettimeofday ())
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* The harness snapshot carries its verdicts whole; there is no page
         behind them. *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Verdicts"
        ~focused:false ~holding:None ~labels ~selected:state.harness_cursor;
      let answer =
        harness_detail_pane state ~rows ~cols:(cols - left_cols) verdict
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
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


(* The Code surface: one directory level on the left, the opened file on the
   right. Entries come from the lazy /workspace/children route; the file is
   lexed once at load (masc_tui_code_lexer) and drawn as styled spans.
   fit_width measures cells past the SGR bytes and closes a cut style, so a
   long row truncates without bleeding colour into the margin. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module File_icon = Masc_tui_file_icon
module Diff = Masc_tui_diff

(* Blame reaches further back than the two surfaces [keeper_lane_idle_text]
   serves. A line untouched since a repository's first year is ordinary, and
   "3684d" is not a reading anyone converts in their head. Weeks and years
   continue where that helper stops; the whole label fits three cells so the
   margin stays a margin. *)
let blame_age_text ~now_s at_ms =
  let seconds = Float.max 0. (now_s -. (at_ms /. 1000.)) in
  let days = int_of_float (seconds /. 86400.) in
  if days < 1 then Printf.sprintf "%dh" (int_of_float (seconds /. 3600.))
  else if days < 14 then Printf.sprintf "%dd" days
  else if days < 365 then Printf.sprintf "%dw" (days / 7)
  else Printf.sprintf "%dy" (days / 365)

(* The margin's own width: a name and a relative age, which is the smallest
   pair that answers "who, and how long ago" without a second lookup. Fixed
   so the code below it stays aligned whether or not a run starts on the
   row. *)
let blame_author_cells = 9
let blame_age_cells = 3
let blame_margin_cells = blame_author_cells + blame_age_cells + 2

let file_change_ranges (change : Masc.Tui_decode.file_change) =
  match change.fc_line_evidence with
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = Some range }) ->
    [ range ]
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrences = Some occurrences; _ }) ->
    List.map
      (fun (occurrence : Masc.Keeper_file_change_evidence.edit_occurrence) ->
        Option.value ~default:occurrence.old_range occurrence.new_range)
      occurrences
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = None })
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrences = None; _ })
  | None -> []

(* The title's note in the screen's language. The server's words, symbols,
   paths and links are drawn as they came; only the sentence around them is
   chosen here. *)
let code_note_text ~ko = function
  | Code_note_server_words { symbol; words } -> symbol ^ ": " ^ words
  | Code_note_nothing_to_say symbol ->
      symbol ^ (if ko then ": 서버가 돌려준 설명 없음" else ": the server has nothing to say here")
  | Code_note_not_found { question; symbol } ->
      Printf.sprintf (if ko then "찾지 못함: %s %S" else "no %s found for %S") question symbol
  | Code_note_location { symbol; path; line } -> Printf.sprintf "%s: %s:%d" symbol path line
  | Code_note_outside_workspace { symbol; path; line } ->
      Printf.sprintf
        (if ko then "%s: 워크스페이스 밖 %s:%d" else "%s: outside the workspace at %s:%d")
        symbol path line
  | Code_note_navigation_failed detail ->
      (if ko then "이동 실패: " else "Navigation failed: ") ^ detail
  | Code_note_no_jump_back -> if ko then "돌아갈 이동 없음" else "No jump to return from"
  | Code_note_return_waits_for_workspace ->
      if ko then "워크스페이스를 확인하기 전에는 돌아갈 수 없음"
      else "Cannot return until the workspace is confirmed"
  | Code_note_no_name_on_line ->
      if ko then "커서 줄에 물어볼 이름 없음" else "the cursor line has no name to ask about"
  | Code_note_saved -> if ko then "파일 저장됨" else "File saved"
  | Code_note_pr_link url -> url
  | Code_note_no_pr_number hash ->
      hash ^ (if ko then ": 제목에 PR 번호 없음" else ": no PR number in this subject")
  | Code_note_pr_without_remote number ->
      Printf.sprintf
        (if ko then "#%d · 이 범위에는 링크할 원격 저장소가 등록되지 않음"
         else "#%d -- this scope has no registered remote to link into")
        number
  | Code_note_pr_remote_not_github number ->
      Printf.sprintf
        (if ko then "#%d · 원격 저장소가 GitHub 가 아니라 링크 모양을 모름"
         else "#%d -- the remote is not GitHub, so the link shape is unknown")
        number

(* The file pane's usable rows: the surface title, then the pane's top gap,
   title, divider, bottom gap, and the footer. One owner — the dispatch keeps
   the cursor visible against the same number the renderer draws with. *)
let code_pane_content_height (state : state) =
  let terminal_rows, _ = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  pane_surface_content_height ~rows

let draft_rows_cache :
    (Masc_tui_code_draft.t * int * ui_language * string list) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let prepare_code_draft_rows ~ko ~cols draft =
  let module Draft = Masc_tui_code_draft in
  let say korean english = if ko then korean else english in
  let wrap text = Message_layout.wrap_body
    ~max_cells:(max 1 (framed_inner_width cols - 2)) ~sanitize:Terminal_text.single_line text in
  let status, before, comparing = match Draft.phase draft with
    | Draft.Editable ->
      say "저장하지 않은 초안 · 이 세션에만 있음" "Unsaved draft · this session",
      (Draft.base draft).text, say "원본 → 초안" "original source → draft"
    | Draft.Saving _ ->
      say "보낸 초안 저장 중 · 서버 확인 대기" "Saving submitted draft; waiting for acknowledgement",
      (Draft.base draft).text, say "원본 → 보낸 초안" "original source → submitted draft"
    | Draft.Rejected detail ->
      say "저장 거절: " "Save refused: " ^ detail, (Draft.base draft).text,
      say "원본 → 초안" "original source → draft"
    | Draft.Needs_review (reason, current) ->
      let detail = match reason with Draft.Conflict text | Draft.Uncertain text -> text in
      (say "초안을 남겨 둠: " "Draft retained: " ^ detail),
      (match current with Some source -> source.text | None -> (Draft.base draft).text),
      (match current with
       | Some _ ->
         say "다시 읽은 서버 원본 → 초안 · A 로 서버 판 받기"
           "reread server source → draft · A adopts this revision"
       | None ->
         say "원본 → 초안 · r 로 서버를 다시 읽은 뒤 비교"
           "original source → draft · r rereads the server before comparison") in
  let ending_text text = match Draft.ending text with
    | Draft.Empty_source -> say "빈 내용" "empty"
    | Draft.Final_lf -> say "끝 LF" "final LF"
    | Draft.Final_crlf -> say "끝 CRLF" "final CRLF"
    | Draft.No_final_newline -> say "끝 줄바꿈 없음" "no final newline" in
  let bytes = Printf.sprintf (if ko then "바이트 %d → %d · %s → %s" else "Bytes %d → %d · %s → %s")
    (String.length before) (String.length (Draft.text draft))
    (ending_text before) (ending_text (Draft.text draft)) in
  let rows = Diff.rows ~before ~after:(Draft.text draft) |> List.concat_map (fun row ->
    let marker, style, text = match row with
      | Diff.Context text -> "  ", Ansi.dim, text
      | Diff.Removed text -> "- ", Theme.Syntax.diff_removed_bg, text
      | Diff.Added text -> "+ ", Theme.Syntax.diff_added_bg, text in
    Terminal_text.single_line
      (fst (Message_layout.expand_tabs ~column:0 text))
    |> Message_layout.split_cells
      ~max_cells:(max 1 (framed_inner_width cols - 4))
    |> List.map (fun text -> style ^ marker ^ text ^ Ansi.reset)) in
  List.concat_map wrap
    [ status; comparing; bytes;
      say "e 편집 · S 저장 · r 다시 읽기 · A 서버 판 받기 · X 버리기 · Esc 닫기"
        "e edit · S save · r reread · A adopt compared revision · X discard · Esc close" ]
  @ rows

(* [same_draft] follows the editing session, including later edits. Only the
   exact immutable value also fixes text, compared source and save phase. *)
let code_draft_rows state ~cols =
  match current_code_draft state with
  | None -> Domain.DLS.set draft_rows_cache None; []
  | Some draft ->
      match Domain.DLS.get draft_rows_cache with
      | Some (seen, width, language, rows)
        when seen == draft && width = cols && language = state.ui_language -> rows
      | Some _ | None ->
          let rows = prepare_code_draft_rows ~ko:(state.ui_language = Lang_ko) ~cols draft in
          Domain.DLS.set draft_rows_cache (Some (draft, cols, state.ui_language, rows));
          rows

let code_hover_rows state ~cols =
  match current_code_hover state with
  | None -> []
  | Some reading ->
      Message_layout.wrap_body
        ~max_cells:(max 1 (framed_inner_width cols - 2))
        ~sanitize:Terminal_text.single_line reading.chr_text

let code_hover_viewport state =
  let _, cols = get_terminal_size () in
  let pane_cols = if cols >= keeper_split_threshold_cols then cols - keeper_roster_pane_cols else cols in
  (List.length (code_hover_rows state ~cols:pane_cols),
   max 1 (code_pane_content_height state - 1))

let code_notes_rows (state : state) ~cols =
  let memos =
    match Masc_tui_fetched.current state.code_file with
    | Some (_, Masc_tui_fetched.Ready _) -> state.code_memos
    | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _))
    | None -> []
  in
  let wrap text =
    Message_layout.wrap_body
      ~max_cells:(max 1 (framed_inner_width cols - 2)) ~sanitize:Terminal_text.single_line text
  in
  match memos with
  | [] ->
      wrap
        (ui_text state ~ko:"(이 파일에 메모 없음 · 메모는 따로 한 줄에 쓴 주석 masc(이름): 내용)"
           ~en:"(no memo in this file: a comment on its own row reading masc(name): text)")
  | _ :: _ ->
      List.concat_map
        (function
          | Masc_tui_memo.Memo_at (line, memo) ->
              let kind = match Ide_memo.kind_word memo.Ide_memo.kind with
                | None -> "" | Some word -> " (" ^ word ^ ")"
              in
              wrap (Printf.sprintf "L%d · %s%s\n%s" line
                      (Terminal_text.single_line memo.Ide_memo.author) kind
                      (Terminal_text.single_line memo.Ide_memo.text))
          | Masc_tui_memo.Broken_at (line, why) ->
              wrap (Printf.sprintf
                      (if state.ui_language = Lang_ko then "L%d · 메모를 읽을 수 없음: %s"
                       else "L%d · memo unreadable: %s") line
                      (Terminal_text.single_line why)))
        memos

let code_notes_viewport (state : state) =
  let _, cols = get_terminal_size () in
  let pane_cols =
    if cols >= keeper_split_threshold_cols then cols - keeper_roster_pane_cols
    else cols
  in
  (List.length (code_notes_rows state ~cols:pane_cols),
   max 1 (code_pane_content_height state - 1))

(* These are tool-call bytes, not a reconstruction of today's checkout.
   Repeat the marker on wrapped rows so a narrow pane retains each side. *)
let history_change_rows ~ko ~cols (change : Masc.Tui_decode.file_change) =
  let open Masc.Tui_decode in
  let say korean english = if ko then korean else english in
  let wrap text =
    Message_layout.wrap_body ~max_cells:(max 1 (framed_inner_width cols - 2))
      ~sanitize:Terminal_text.single_line text
  in
  let status =
    if change.fc_succeeded then
      say "기록된 변경 · 적용된 호출 · d:접기" "Recorded change · applied call · d:collapse"
    else say "기록된 시도 · 실패한 호출 · d:접기" "Recorded attempt · call failed · d:collapse"
  in
  let before, after, note = match change.fc_kind with
    | Fc_edited { before; after; replace_all } ->
        before, after,
        (if replace_all then
           [ say "replace_all: 일치하는 곳을 모두 바꾸려 함 · 기록에는 글이 한 번만 있음"
               "replace_all: recorded text once; every occurrence was targeted" ]
         else [])
    | Fc_inserted { text; _ } ->
        "", text, [ say "넣은 글 · 둘레 파일 내용은 기록에 없음" "Inserted text; surrounding file is not recorded" ]
    | Fc_written { content } ->
        "", content,
        [ say "쓴 내용 · 이전 파일 바이트는 기록에 없음" "Written content; previous file bytes are not recorded" ]
    | Fc_materialized _ ->
        "", "", [ say "기록에는 blob 의 식별 값만 있음 · 비교할 글 없음" "Blob identity only; no recorded text to compare" ]
  in
  let rows = Diff.rows ~before ~after |> List.concat_map (fun row ->
    let marker, style, text = match row with
      | Diff.Context text -> "  ", Ansi.dim, text
      | Diff.Removed text -> "- ", Theme.Syntax.diff_removed_bg, text
      | Diff.Added text -> "+ ", Theme.Syntax.diff_added_bg, text
    in
    (* Code whitespace is evidence: word wrapping would erase indentation
       and collapse internal spaces. Cell splitting also retains empty rows. *)
    let lines = Terminal_text.single_line text
      |> Message_layout.split_cells ~max_cells:(max 1 (framed_inner_width cols - 4)) in
    List.map (fun line -> style ^ marker ^ line ^ Ansi.reset) lines)
  in
  List.concat_map wrap (status :: note) @ rows

let prepare_code_history_rows (state : state) ~cols =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let wrap owner text =
    Message_layout.wrap_body
      ~max_cells:(max 1 (framed_inner_width cols - 2)) ~sanitize:Terminal_text.single_line text
    |> List.map (fun text -> (owner, text))
  in
  let field name text = name ^ ": " ^ Terminal_text.single_line text in
  let date seconds =
    let t = Unix.localtime seconds in
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (t.Unix.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
      t.tm_hour t.tm_min t.tm_sec
  in
  match Masc_tui_fetched.current state.code_history with
  | Some (_, (Masc_tui_fetched.Stale (_, detail) | Masc_tui_fetched.Failed detail)) ->
      wrap None (field (say "이력을 읽지 못함" "History unavailable") detail)
  | Some (_, Masc_tui_fetched.Loading) -> wrap None (say "(이력 읽는 중…)" "(loading history)")
  | Some (_, Masc_tui_fetched.Absent) | None -> []
  | Some ((scope, path), Masc_tui_fetched.Ready listing) ->
      let git_failure = match listing.chl_git_error with
        | None -> []
        | Some detail -> wrap None (field (say "Git 이력을 읽지 못함" "Git history unavailable") detail)
      in
      let entries = List.mapi
        (fun index entry ->
          let lines = match entry with
            | Hist_commit row ->
                let open Masc.Tui_decode in
                [field (say "커밋" "Commit") row.gl_hash;
                 field (say "날짜" "Date") (date (row.gl_at_ms /. 1000.));
                 field (say "작성자" "Author") row.gl_author;
                 field (say "제목" "Subject") row.gl_subject]
            | Hist_keeper_change change ->
                let open Masc.Tui_decode in
                let kind = match change.fc_kind with
                  | Fc_edited _ -> say "수정" "EDIT" | Fc_inserted _ -> say "메모" "MEMO"
                  | Fc_written _ | Fc_materialized _ -> say "쓰기" "WRITE"
                in
                let anchor = match file_change_evidence_label ~ko change.fc_line_evidence with
                  | Some label -> label | None -> "L?"
                in
                [field "Keeper" change.fc_keeper; field (say "날짜" "Date") (date change.fc_at);
                 field (say "종류" "Kind") kind; field (say "줄" "Lines") anchor;
                 field (say "결과" "Result")
                   (if change.fc_succeeded then say "적용됨" "applied" else say "실패" "failed")]
                @ List.filter_map Fun.id
                    [Option.map (field "Task") change.fc_task_id;
                     Option.map (fun turn -> field (say "턴" "Turn") (string_of_int turn)) change.fc_turn;
                     Option.map (field "Execution") change.fc_execution_id]
          in
          let owner = Some (index, entry) in
          let metadata = List.concat_map (wrap owner) lines in
          match entry, state.code_history_expanded with
          | Hist_keeper_change change, Some expanded when index = expanded ->
              metadata @ List.map (fun row -> owner, row)
                (history_change_rows ~ko ~cols change)
          | Hist_commit _, _ | Hist_keeper_change _, _ -> metadata)
        listing.chl_entries |> List.concat
      in
      let empty = match listing.chl_entries with
        | [] ->
            wrap None
              (say "(돌아온 이력 없음 · 아래 기록 출처 참고)"
                 "(no history entries returned; see source coverage below)")
        | _ :: _ -> []
      in
      let note = match state.code_lsp_note with
        | None -> [] | Some note -> wrap None (field (say "알림" "File note") (code_note_text ~ko note))
      in
      let scope_text = match scope with
        | Code_scope_project -> say "프로젝트" "Project"
        | Code_scope_keeper keeper -> "Keeper " ^ keeper
        | Code_scope_repo repo -> say "저장소 " "Repository " ^ repo
      in
      git_failure @ entries @ empty @ wrap None (field (say "파일" "File") path)
      @ wrap None (field (say "범위" "Scope") scope_text)
      @ wrap None (field (say "기록 출처" "Coverage") listing.chl_activity_note) @ note

let history_rows_cache :
    (((code_workspace_scope * string, code_history_listing) Masc_tui_fetched.t
      * int option * code_note option * int * ui_language)
     * ((int * code_history_entry) option * string) list) option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let code_history_rows (state : state) ~cols =
  let source = state.code_history in
  let expanded = state.code_history_expanded in
  let note = state.code_lsp_note in
  match Domain.DLS.get history_rows_cache with
  | Some ((seen, seen_expanded, seen_note, width, language), rows)
      when seen == source && seen_expanded = expanded && seen_note = note && width = cols
           && language = state.ui_language -> rows
  | Some _ | None ->
      let rows = prepare_code_history_rows state ~cols in
      Domain.DLS.set history_rows_cache
        (Some ((source, expanded, note, cols, state.ui_language), rows));
      rows

let code_history_pane_cols () =
  let _, cols = get_terminal_size () in
  if cols >= keeper_split_threshold_cols then cols - keeper_roster_pane_cols
  else cols

let code_history_viewport (state : state) =
  (List.length (code_history_rows state ~cols:(code_history_pane_cols ())),
   max 1 (code_pane_content_height state - 1))

(* The diff is drawn through the whole pane height with no row of its own
   above it, so its window is [code_pane_content_height]. A diff that has not
   been read has no rows and no window to move in. *)
let code_diff_viewport (state : state) =
  match Masc_tui_fetched.current state.code_diff with
  | Some (_, Masc_tui_fetched.Ready diff) ->
      Some (List.length diff.Masc.Tui_decode.gd_rows,
            max 1 (code_pane_content_height state))
  | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
             | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _))
  | None -> None

let code_history_selected_occurrence (state : state) =
  let rows = code_history_rows state ~cols:(code_history_pane_cols ()) in
  (* The first row owns Enter. Let every physical row reach that position,
     including the final record when the whole document fits the pane. *)
  let scroll = Masc_tui_scroll.normalize ~count:(List.length rows) ~height:1
      state.code_history_scroll in
  match List.nth_opt rows scroll with
  | Some (owner, _) -> owner | None -> None

let code_history_selected state =
  Option.map snd (code_history_selected_occurrence state)

let toggle_history_change state =
  match code_history_selected_occurrence state with
  | Some (index, Hist_keeper_change _) ->
      state.code_history_expanded <-
        (if state.code_history_expanded = Some index then None else Some index);
      (* Switching records can collapse rows before this owner. Locate it in
         the new document so the selected record stays at the top. *)
      let rows = code_history_rows state ~cols:(code_history_pane_cols ()) in
      let first = List.find_index
          (fun (owner, _) -> Option.map fst owner = Some index) rows in
      Option.iter (fun row -> state.code_history_scroll <- row) first;
      true
  | Some (_, Hist_commit _) | None -> false

let render_code (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  pane_surface_header buf cols state ~path:[ ui_text state ~ko:"코드" ~en:"code" ] ~split;
  let list_rows_budget = code_pane_content_height state in
  let entries = code_entries state in
  let total = List.length entries in
  let cursor = max 0 (min state.code_cursor (total - 1)) in
  let span = lexed_span in
  let list_pane ~framed pane_buf pane_cols =
    (* Beside the file pane the box is the pane separator; alone on a narrow
       terminal it is the redundant outer frame every other surface dropped
       (same rule as keeper_detail_pane). Alone, its top row is the gap
       [pane_surface_header] already drew above the title. *)
    let framed_top = if framed then framed_top else fun _ _ -> () in
    let framed_divider = if framed then framed_divider else box_divider in
    let framed_line = if framed then framed_line else box_line in
    let framed_empty = if framed then framed_empty else box_empty in
    let framed_bottom = if framed then framed_bottom else box_bottom in
    framed_top pane_buf pane_cols;
    let list_focused = state.code_focus_file = Left_pane in
    let where = if String.equal state.code_dir "" then "/" else state.code_dir in
    (* Whose tree this is: a keeper workspace or a repository reads
       differently from the project's, and the same relative path exists in
       more than one of them. *)
    let where =
      match state.code_scope with
      | Code_scope_project -> where
      | Code_scope_keeper keeper -> keeper ^ " \xe2\x96\xb8 " ^ where
      | Code_scope_repo repo -> repo ^ " \xe2\x96\xb8 " ^ where
    in
    framed_line pane_buf pane_cols
      ((if list_focused then Ansi.bold else Ansi.dim)
       ^ (if list_focused then " \xe2\x96\xb8 " else " ")
       ^ Terminal_text.single_line where
       ^ workspace_entries_count_label total
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* Each state of the listing says which it is. "(loading…)" stood for all
       three empty ones: a request in flight, a listing never asked for, and a
       directory that answered with no entries. *)
    let status_line text =
      framed_line pane_buf pane_cols text;
      1
    in
    let status_rows =
      match code_listing_view state with
      | Masc_tui_fetched.Stale (_, detail) ->
          status_line
            ((Theme.bad ())
             ^ ui_text state ~ko:" 새로 고침 실패 · 마지막으로 읽은 목록: "
                 ~en:" Refresh failed, showing the last read: "
             ^ Terminal_text.single_line detail ^ Ansi.reset)
      | Masc_tui_fetched.Failed detail ->
          status_line
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset)
      | Masc_tui_fetched.Loading ->
          status_line
            (Ansi.dim ^ ui_text state ~ko:" (읽는 중\xe2\x80\xa6)" ~en:" (loading\xe2\x80\xa6)"
             ^ Ansi.reset)
      | Masc_tui_fetched.Absent ->
          status_line (Ansi.dim ^ " " ^ String.trim (page_unread_note ~ko:(state.ui_language = Lang_ko)) ^ Ansi.reset)
      | Masc_tui_fetched.Ready [] ->
          status_line (Ansi.dim ^ ui_text state ~ko:" (빈 폴더)" ~en:" (empty directory)" ^ Ansi.reset)
      | Masc_tui_fetched.Ready (_ :: _) -> 0
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    let entries_window = Rows.of_list ~first:first ~height:list_rows_budget entries in
    for i = 0 to list_rows_budget - 1 do
      match Rows.at entries_window (first + i) with
      | Some node ->
          let name =
            Terminal_text.single_line node.Masc.Tui_decode.wt_label
          in
          let selected = first + i = cursor in
          (* A folder keeps the "▸" it has always drawn; a file takes a
             type mark by extension. The colour is dropped on the selected
             row, where the selection band already owns the whole line and a
             mid-line reset would tear a hole in it.

             The folder mark takes the same slot as a code file, which is
             the cyan it always had: both were bright cyan to the byte until
             one of them started resolving through the theme and the other
             did not, leaving two cyans in one column. *)
          let marker =
            if node.Masc.Tui_decode.wt_has_children then
              if selected then File_icon.folder_glyph ^ " "
              (* The mark colour the files below it take. A folder is not a
                 kind of file, and the arrow already says which of the two
                 this row is. Both rows read the arrow from the module that
                 also hands it to the help sheet: they were two literals a
                 branch apart, one of them borrowed from the current-entry
                 glyph, which is the same byte under another name. *)
              else
                (Theme.category Theme.Slot_1) ^ File_icon.folder_glyph ^ " "
                ^ Ansi.reset
            else
              let kind =
                File_icon.kind_of_name node.Masc.Tui_decode.wt_label
              in
              let glyph = File_icon.glyph kind in
              if selected then glyph ^ " "
              else
                let colour =
                  (* One colour for "this is a file mark". Which kind it is
                     belongs to the glyph, and the glyph already carries it --
                     seven kinds, seven distinct marks in File_icon.glyph.

                     Colour used to carry the kind, over four slots, and it
                     could not. Two reasons, both measured.

                     RFC-0431 measured the slot hues across every shipped
                     scheme: 0.0014 to 0.0044 apart in Oklab under
                     deuteranopia and protanopia, against the 0.024 a colour
                     has to clear to read as a distinction at all. About a
                     seventh of it. For roughly one reader in twelve the axis
                     was never splitting, whatever the slots held.

                     And it cost what it could not buy. write_two_panes joins
                     this listing to the content pane on one terminal row, and
                     that pane draws Theme.bad, ok, info and warn -- red,
                     green, cyan, yellow. Of the seven colours a theme names
                     that leaves blue and magenta, so a kind axis wider than
                     two was a status token to the byte on somebody's row.
                     #33477 caught red against bad, when a .png in the listing
                     drew the blame failure's escape beside it. #33722 caught
                     green against ok. Cyan against info and yellow against
                     warn were the same defect and outlived both, because the
                     test that was supposed to stop this named only bad and
                     ok.

                     Blue rather than magenta, because magenta already means
                     Verifying, microvm, EDIT, MEMO and two context readings
                     elsewhere, and one more meaning on it is the pile
                     RFC-0431 was opened to take apart.

                     Plain recedes rather than taking a constant [dim], so a
                     mark nobody classified still moves with the theme. *)
                  match kind with
                  | File_icon.Code | File_icon.Web | File_icon.Data
                  | File_icon.Prose | File_icon.Script | File_icon.Media ->
                    Theme.category Theme.Slot_1
                  | File_icon.Plain -> Theme.recede ()
                in
                colour ^ glyph ^ Ansi.reset ^ " "
          in
          let line =
            if selected then
              Theme.selection ^ " " ^ marker ^ name
              ^ String.make
                  (max 0
                     (framed_inner_width pane_cols - 3
                      - Message_layout.display_width (marker ^ name)))
                  ' '
              ^ Ansi.reset
            else " " ^ marker ^ name
          in
          framed_line pane_buf pane_cols line
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane ~split pane_buf pane_cols =
    let hover = current_code_hover state in
    let hover_showing = Option.is_some hover in
    let draft_showing = state.code_draft_open && Option.is_some (current_code_draft state) in
    let history_showing = state.code_history_open in
    let diff_showing = state.code_diff_open in
    let notes_showing = state.code_notes_open in
    let title =
      match Masc_tui_fetched.current_key state.code_file with
      | Some path ->
          let path = Terminal_text.single_line path in
          let path =
            (* Say the view is shifted; a pane that silently starts at
               column 41 reads as a file whose lines begin mid-word. *)
            if
              state.code_file_hscroll > 0 && not history_showing
              && not diff_showing && not notes_showing
            then
              Printf.sprintf
                (if state.ui_language = Lang_ko then "%s  (%d열부터)" else "%s  (col %d)") path
                (state.code_file_hscroll + 1)
            else path
          in
          let base =
            if hover_showing then
              (match hover with
               | Some reading ->
                   Printf.sprintf
                     (if state.ui_language = Lang_ko then "이름 설명: %s:%d · %s" else "hover: %s:%d · %s")
                     path
                   reading.chr_query.clq_line
                   (Terminal_text.single_line reading.chr_query.clq_symbol)
               | None -> path)
            else if draft_showing then ui_text state ~ko:"초안: " ~en:"draft: " ^ path
            else if notes_showing then ui_text state ~ko:"메모: " ~en:"notes: " ^ path
            else if diff_showing then
              let basis =
                match Masc_tui_fetched.current_key state.code_diff with
                | Some (Diff_commit { commit; _ }) ->
                    ui_text state ~ko:"커밋 " ~en:"commit " ^ Terminal_text.single_line commit
                | Some (Diff_worktree { base_ref; _ }) ->
                    "vs " ^ Terminal_text.single_line base_ref
                | None -> "vs HEAD"
              in
              (if state.ui_language = Lang_ko then
                 Printf.sprintf "diff %s · %d열부터: %s" basis (state.code_diff_hscroll + 1) path
               else
                 Printf.sprintf "diff col %d %s: %s"
                   (state.code_diff_hscroll + 1) basis path)
            else if history_showing then ui_text state ~ko:"이력: " ~en:"history: " ^ path
            else
              path
              ^ (if Option.is_some (current_code_draft state) then
                   ui_text state ~ko:" · 초안 남아 있음 (V)" ~en:" · draft retained (V)"
                 else "")
          in
          (* The note (a language-server answer, a PR link) rides the title
             in every view: the history's Enter writes one too. *)
          let with_note =
            let note = match code_pending_navigation state with
              | Some (owner, path) ->
                  let path = Terminal_text.single_line path in
                  Some (match owner.cno_action with
                    | Return_to_history ->
                        ui_text state ~ko:"돌아가는 중: " ~en:"Returning to " ^ path
                    | Follow_location ->
                        Printf.sprintf (if state.ui_language = Lang_ko then "여는 중: %s:%d" else "Opening %s:%d")
                          path
                        (owner.cno_destination.cj_cursor + 1))
              | None ->
                  (match code_lsp_pending_query state with
                   | Some query ->
                       Some (Printf.sprintf
                         (if state.ui_language = Lang_ko then "언어 서버에 묻는 중: %s %S"
                          else "asking %s about %S")
                         query.clq_question query.clq_symbol)
                   | None ->
                       Option.map (code_note_text ~ko:(state.ui_language = Lang_ko))
                         state.code_lsp_note) in
            match (if hover_showing then None else note) with
            | Some note ->
                base ^ "  " ^ (Theme.accent ())
                ^ Terminal_text.single_line note ^ Ansi.reset
            | None -> base
          in
          (* What the memo on the cursor's line says. The gutter already
             marks which rows carry one (RFC-0429 §3.1); a mark alone makes
             the reader open the list to learn what it marks. This rides the
             title for the same reason blame's status does: the margin is one
             cell wide and has no pane to speak in.

             Only where the body is the thing on screen. The overlays replace
             it, so under them the cursor's line is not drawn and the rider
             would caption a row nobody can see.

             No width arithmetic here: framed_line fits the title to the pane,
             which is the truncation §3.1 asks for. *)
          let with_note =
            if hover_showing || notes_showing || diff_showing || history_showing then with_note
            else
              let line = state.code_file_cursor + 1 in
              match
                List.find_opt
                  (fun found -> Masc_tui_memo.line_of found = line)
                  state.code_memos
              with
              | None -> with_note
              | Some (Masc_tui_memo.Memo_at (_, memo)) ->
                  let kind =
                    match Ide_memo.kind_word memo.Ide_memo.kind with
                    | None -> ""
                    | Some word -> " (" ^ word ^ ")"
                  in
                  with_note ^ "  "
                  ^ (Theme.accent ())
                  ^ ui_text state ~ko:"메모 " ~en:"memo "
                  ^ Terminal_text.single_line memo.Ide_memo.author
                  ^ kind ^ Ansi.reset ^ " "
                  ^ Terminal_text.single_line memo.Ide_memo.text
              | Some (Masc_tui_memo.Broken_at (_, why)) ->
                  with_note ^ "  " ^ Theme.bad ()
                  ^ ui_text state ~ko:"메모를 읽을 수 없음: " ~en:"memo unreadable: "
                  ^ Terminal_text.single_line why ^ Ansi.reset
          in
          (* A blame that did not come back has no pane of its own to say so
             in -- the margin is beside the code, not instead of it -- so the
             refusal rides the title the way a language-server answer does.
             In the bad tone rather than the accent: this one is a failure. *)
          (* The margin has no pane of its own to speak in, so both the
             refusal and the wait ride the title. *)
          (match Masc_tui_fetched.current state.code_blame with
           | Some (_, (Masc_tui_fetched.Stale (_, detail) | Masc_tui_fetched.Failed detail)) ->
               with_note ^ "  " ^ Theme.bad () ^ "blame: "
               ^ Terminal_text.single_line detail ^ Ansi.reset
           | Some (_, Masc_tui_fetched.Loading) ->
               with_note ^ "  " ^ Theme.recede ()
               ^ ui_text state ~ko:"blame 읽는 중…" ~en:"reading blame…" ^ Ansi.reset
           | Some (_, (Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent))
           | None -> with_note)
      | None -> ui_text state ~ko:"(Enter 로 고른 파일 열기)" ~en:"(Enter opens the selected file)"
    in
    if split then box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.code_focus_file = Right_pane then Ansi.bold else Ansi.dim)
       ^ (if state.code_focus_file = Right_pane then " \xe2\x96\xb8 " else " ")
       ^ title
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = code_pane_content_height state in
    let file_scroll total_lines =
      max 0 (min state.code_file_scroll (max 0 (total_lines - content_height)))
    in
    (* The row under the pane's rows. A file or a diff longer than its window
       says there where the window is, like the other panes' "rows X-Y/Z" line;
       with nothing to say it is the gap above the footer. The diff says it
       here, as the file does, and not in its title: the title ends in the
       path, which a narrow pane cuts first. [content_height] budgets that one
       row, so a position drawn beside the gap made the surface one row too
       tall and [finish_surface] cut its last row, the footer. *)
    let position_row =
      if hover_showing || draft_showing || notes_showing then None
      else if diff_showing then
        match code_diff_viewport state with
        | Some (count, height) when count > height ->
            Some
              (Masc_tui_scroll.window_reading ~noun:(ui_text state ~ko:"줄" ~en:"rows")
                 ~scroll:
                   (Masc_tui_scroll.normalize ~count ~height
                      state.code_diff_scroll)
                 ~height count)
        | Some _ | None -> None
      else if history_showing then None
      else
        match Masc_tui_fetched.current state.code_file with
        | Some (_, Masc_tui_fetched.Ready { cfd_rows = file_rows; _ })
          when Array.length file_rows > content_height ->
            let total_lines = Array.length file_rows in
            let scroll = file_scroll total_lines in
            Some
              (Masc_tui_scroll.window_reading ~noun:(ui_text state ~ko:"줄" ~en:"lines") ~scroll
                 ~height:content_height total_lines)
        | Some (_, Masc_tui_fetched.Ready _)
        | Some
            ( _,
              ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
              | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _ ) )
        | None -> None
    in
    (if hover_showing then
       let rendered = code_hover_rows state ~cols:pane_cols in
       let height = max 1 (content_height - 1) in
       let total = List.length rendered in
       let scroll = match hover with
         | None -> 0 | Some reading -> max 0 (min reading.chr_scroll (max 0 (total - height))) in
       if content_height > 1 then
         box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
           ("  "
            ^ Masc_tui_scroll.window_reading ~noun:(ui_text state ~ko:"줄" ~en:"rows") ~scroll ~height total
            ^ ui_text state ~ko:" · Esc: 코드로 돌아가기" ~en:" · Esc returns to code");
       let window = Rows.of_list ~first:scroll ~height rendered in
       for index = 0 to height - 1 do
         match Rows.at window (scroll + index) with
         | Some line -> box_line pane_buf pane_cols ("  " ^ line)
         | None -> box_empty pane_buf pane_cols
       done
     else if draft_showing then
       let rendered = code_draft_rows state ~cols:pane_cols in
       let maximum = max 0 (List.length rendered - content_height) in
       let scroll = max 0 (min state.code_draft_scroll maximum) in
       let window = Rows.of_list ~first:scroll ~height:content_height rendered in
       for index = 0 to content_height - 1 do
         match Rows.at window (scroll + index) with
         | Some line -> box_line pane_buf pane_cols ("  " ^ line)
         | None -> box_empty pane_buf pane_cols
       done
     else if notes_showing then
       let rendered = code_notes_rows state ~cols:pane_cols in
       let total = List.length rendered in
       let height = max 1 (content_height - 1) in
       let scroll = max 0 (min state.code_notes_scroll (max 0 (total - height))) in
       if content_height > 1 then
         box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
           ("  " ^ Masc_tui_scroll.window_reading ~noun:(ui_text state ~ko:"줄" ~en:"rows") ~scroll ~height total);
       let window = Rows.of_list ~first:scroll ~height rendered in
       for i = 0 to height - 1 do
         match Rows.at window (scroll + i) with
         | Some line -> box_line pane_buf pane_cols ("  " ^ line)
         | None -> box_empty pane_buf pane_cols
       done
     else if diff_showing then
       match Masc_tui_fetched.current state.code_diff with
       | Some (_, (Masc_tui_fetched.Stale (_, detail) | Masc_tui_fetched.Failed detail)) ->
           box_line pane_buf pane_cols
             ((Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Loading) ->
           box_line pane_buf pane_cols
             (Ansi.dim ^ ui_text state ~ko:"  (트리 읽는 중…)" ~en:"  (reading the tree)" ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready diff) -> (
           match diff.Masc.Tui_decode.gd_rows with
           | [] ->
               box_line pane_buf pane_cols
                 (Ansi.dim
                 ^ (match Masc_tui_fetched.current_key state.code_diff with
                    | Some (Diff_commit _) ->
                        if diff.Masc.Tui_decode.gd_has_changes then
                          ui_text state ~ko:"  (커밋에 변경이 있다는데 줄이 오지 않음)"
                            ~en:"  (the commit reports a change and sent no lines)"
                        else
                          ui_text state ~ko:"  (이 커밋은 이 파일을 바꾸지 않음)"
                            ~en:"  (this commit changed nothing in this file)"
                    | Some (Diff_worktree _) | None ->
                        if diff.Masc.Tui_decode.gd_has_changes then
                          ui_text state ~ko:"  (트리에 변경이 있다는데 줄이 오지 않음)"
                            ~en:"  (the tree reports a change and sent no lines)"
                        else
                          ui_text state ~ko:"  (이 파일은 마지막 커밋과 같음)"
                            ~en:"  (this file matches its last commit)")
                 ^ Ansi.reset);
               for _ = 2 to content_height do
                 box_empty pane_buf pane_cols
               done
           | rows ->
               let total = List.length rows in
               let scroll =
                 Masc_tui_scroll.normalize ~count:total ~height:content_height
                   state.code_diff_scroll
               in
               let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
               (* The open file is a separate observation. A diff line number
                  cannot identify its text, for either a commit or a later
                  working-tree read. Keep the diff's own body for every row. *)
               for i = 0 to content_height - 1 do
                 match Rows.at rows_window (scroll + i) with
                 | Some row ->
                     let open Masc.Tui_decode in
                     let gutter =
                       Printf.sprintf "  %s %s %s "
                         (Diff.line_number_cell row.gdr_old_line)
                         (Diff.line_number_cell row.gdr_new_line)
                         (match row.gdr_kind with
                          | Gd_removed -> "-"
                          | Gd_added -> "+"
                          | Gd_context -> " ")
                     in
                     let text =
                       Terminal_text.single_line
                         (fst
                            (Message_layout.expand_tabs
                               ~column:0 row.gdr_text))
                     in
                     let body =
                       match row.gdr_kind with
                       | Gd_removed ->
                           Theme.Syntax.diff_removed_bg ^ text ^ Ansi.reset
                       | Gd_added ->
                           Theme.Syntax.diff_added_bg ^ text ^ Ansi.reset
                       | Gd_context -> Ansi.dim ^ text ^ Ansi.reset
                     in
                     box_line pane_buf pane_cols
                       (Ansi.dim ^ gutter ^ Ansi.reset
                        ^ Message_layout.drop_cells body state.code_diff_hscroll)
                 | None -> box_empty pane_buf pane_cols
               done)
     else if history_showing then
       let rendered = code_history_rows state ~cols:pane_cols in
       let total = List.length rendered in
       let height = max 1 (content_height - 1) in
       let scroll = Masc_tui_scroll.normalize ~count:total ~height:1 state.code_history_scroll in
       if content_height > 1 then
         box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
           ("  " ^ Masc_tui_scroll.window_reading ~noun:(ui_text state ~ko:"줄" ~en:"rows") ~scroll ~height total);
       let window = Rows.of_list ~first:scroll ~height rendered in
       for i = 0 to height - 1 do
         match Rows.at window (scroll + i) with
         | Some (_, line) ->
             box_line pane_buf pane_cols
               ("  " ^ (if i = 0 then Ansi.bold else "") ^ line ^ Ansi.reset)
         | None -> box_empty pane_buf pane_cols
       done
     else
       (* A blank pane used to mean three things: no file open, a file being
          read, and a file that failed to read. Two of them now say so. *)
       let say style text =
         box_line pane_buf pane_cols
           (style ^ "  " ^ Terminal_text.single_line text ^ Ansi.reset);
         for _ = 2 to content_height do
           box_empty pane_buf pane_cols
         done
       in
       match Masc_tui_fetched.current state.code_file with
       | Some (_, (Masc_tui_fetched.Stale (_, detail) | Masc_tui_fetched.Failed detail)) -> say (Theme.bad ()) detail
       | Some (path, Masc_tui_fetched.Loading) ->
           say (Theme.recede ())
             (ui_text state ~ko:(path ^ " 읽는 중…") ~en:("reading " ^ path ^ "…"))
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready { cfd_body = Code_binary { bytes }; _ }) ->
           (* Its bytes would draw as hundreds of rows of escapes. The title
              already names the file, so the pane says only what it is. *)
           say (Theme.recede ())
             (Printf.sprintf
                (if state.ui_language = Lang_ko then "바이너리 파일 · %s · 텍스트로 그리지 않음"
                 else "binary file · %s · not drawn as text")
                (Masc_tui_context_inspector.format_bytes bytes))
       | Some (open_path, Masc_tui_fetched.Ready { cfd_body = Code_text _; cfd_rows = file_rows; _ }) ->
           let scroll = file_scroll (Array.length file_rows) in
           let hscroll =
             max 0
               (min state.code_file_hscroll
                  (max 0 (state.code_file_max_width - 1)))
           in
           (* Which lines carry a note or a durable Keeper change -- only what
              is already loaded (m or H has been opened for this file); the
              pane does not fetch merely to decorate. *)
           let matches_open_file loaded_path =
             match Masc_tui_fetched.current_key state.code_file with
             | Some open_path -> String.equal loaded_path open_path
             | None -> false
           in
           let note_spans =
             List.map
               (fun found ->
                 let line = Masc_tui_memo.line_of found in
                 (line, line))
               state.code_memos
           in
           let keeper_spans =
             match Masc_tui_fetched.current state.code_history with
             | Some ((_, loaded_path), Masc_tui_fetched.Ready listing)
               when matches_open_file loaded_path ->
                 List.concat_map
                   (function
                     | Hist_keeper_change change ->
                       List.map
                         (fun range -> (range.Masc.Keeper_file_change_evidence.start_line,
                           range.end_line))
                         (file_change_ranges change)
                     | Hist_commit _ -> [])
                   listing.chl_entries
             | Some
                 ( _,
                   ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                   | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
                   | Masc_tui_fetched.Failed _ ) )
             | None -> []
           in
           let covers line spans =
             List.exists (fun (a, b) -> line >= a && line <= b) spans
           in
           (* Who last touched each run, when [b] has read it for this file.
              Same rule as the two span lists above: the pane decorates what
              is loaded and does not fetch to decorate. *)
           let blame_blocks =
             match Masc_tui_fetched.current state.code_blame with
             | Some (loaded_path, Masc_tui_fetched.Ready blocks)
               when matches_open_file loaded_path -> blocks
             | Some
                 ( _,
                   ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                   | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
                   | Masc_tui_fetched.Failed _ ) )
             | None -> []
           in
           let blame_now_s = Unix.gettimeofday () in
           (* One name per run, not one per line: the run boundary is the fact
              worth drawing, and repeating the author down every line of a
              block is what hides it. Continuation rows hold the same cells in
              blanks so the code stays in one column.

              No colour of its own. The frame draws plain, dim or the single
              accent, and a colour outside them is a claim about state --
              blame carries no state, only who and when. So the answer (the
              name) draws plain and the qualifier (the age) draws dim, and
              nothing here competes with the lexer's own colours in the code
              beside it. *)
           let blame_cell line =
             match blame_blocks with
             | [] -> ""
             | _ -> (
               match Masc.Tui_decode.blame_block_at blame_blocks line with
               | Some (block, true) ->
                   Printf.sprintf "%s %s%s%s "
                     (Message_layout.fit_width block.bb_author
                        blame_author_cells)
                     Ansi.dim
                     (Message_layout.fit_width
                        (blame_age_text ~now_s:blame_now_s block.bb_at_ms)
                        blame_age_cells)
                     Ansi.reset
               | Some (_, false) | None -> String.make blame_margin_cells ' ')
           in
           let file_rows_window = Rows.of_array file_rows in
           for i = 0 to content_height - 1 do
             match Rows.at file_rows_window (scroll + i) with
             | Some segments ->
                 let body =
                   String.concat "" (List.map span segments)
                 in
                 (* The gutter stays put; only the code scrolls sideways. *)
                 let body = Message_layout.drop_cells body hscroll in
                 let row_index = scroll + i in
                 let gutter_style =
                   (* The cursor line carries the gutter in reverse video:
                      a full-row band would sit on top of the lexer's own
                      colours, and the gutter is the row's stable margin. *)
                   if row_index = state.code_file_cursor then Ansi.reverse
                   else Ansi.dim
                 in
                 let mark =
                   let line = row_index + 1 in
                   if covers line note_spans then
                     (Theme.accent ())
                     ^ "\xe2\x97\x8f" ^ Ansi.reset
                   else if covers line keeper_spans then Ansi.dim ^ "\xc2\xb7" ^ Ansi.reset
                   else " "
                 in
                 box_line pane_buf pane_cols
                   (Printf.sprintf "%s%s%s%4d%s %s"
                      (blame_cell (row_index + 1))
                      mark gutter_style (row_index + 1) Ansi.reset body)
             | None -> box_empty pane_buf pane_cols
           done);
    (match position_row with
     | Some text ->
         box_line_styled pane_buf pane_cols ~style:(Theme.recede ()) text
     | None -> box_bottom pane_buf pane_cols)
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane ~framed:true left_buf left_cols;
     content_pane ~split right_buf right_cols;
     write_two_panes buf ~left_cols:left_cols ~left:left_buf
       ~right:right_buf
   end
   else if state.code_focus_file = Right_pane then content_pane ~split buf cols
   else list_pane ~framed:false buf cols);
  let code_pane = Masc_tui_keys.code_pane_of state in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(if Option.is_some (current_code_hover state) then Masc_tui_keys.footer_hints_code_hover ~lang:state.ui_language
               else Masc_tui_keys.footer_hints_code ~lang:state.ui_language ~pane:code_pane));
  finish_surface state ~surface_key:"code" ~rows:terminal_rows ~cols buf

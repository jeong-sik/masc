(** Overlay and modal screens and their viewport calculators. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Frame_presenter = Masc_tui_frame_presenter
module Message_layout = Masc_tui_message_layout
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule
module Agenda = Masc_tui_agenda
module Keeper_control = Masc_tui_keeper_control

(* /about: the candle over the surface, with what the TUI is running under
   -- its colour scheme and how many Keepers the workspace holds. *)
let render_about (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let theme =
    Terminal_text.single_line_or ~default:"default" state.theme_choice
  in
  let keepers =
    match state.keepers_error, state.local_keepers with
    | Some _, _ | None, Local_workspace_failed _ -> Masc_tui_emblem_screen.Keepers_unreadable
    | None, Local_workspace_unread -> Masc_tui_emblem_screen.Keepers_unread
    | None, Local_workspace_read ->
        Masc_tui_emblem_screen.Keepers_read (List.length state.keepers)
  in
  surface_chrome ~overflow:Fits ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~help_door:true
    ~surface_key:"about" ~title:(screen_title " MASC")
    ~hints:(Masc_tui_keys.footer_hints_about ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      Masc_tui_emblem_screen.about_body
        ~cols:(framed_inner_width cols) ~rows:budget
        ~origin:(c.next_origin ())
        ~frame:state.emblem_frame
        ~keepers:(match keepers with
          | Masc_tui_emblem_screen.Keepers_read _ ->
              List.map (fun (keeper : Tui_decode.keeper) ->
                let portrait =
                  match (keeper_reading state keeper).Keeper_control.liveness with
                  | Keeper_control.Present runtime -> runtime.kr_portrait
                  | Keeper_control.Unobserved | Keeper_control.Absent
                  | Keeper_control.Invalid _ ->
                      Keeper_portrait_equipment.Unavailable
                        (ui_text state ~ko:"키퍼 장비 미관측" ~en:"Keeper equipment not observed")
                in
                keeper.k_name, portrait) state.keepers
          | Masc_tui_emblem_screen.Keepers_unreadable
          | Masc_tui_emblem_screen.Keepers_unread -> [])
        ~caption:
          [ Theme.accent ()
            ^ "MASC \xc2\xb7 Multi-Agent Shared Context" ^ Ansi.reset
          ; Ansi.dim
            ^ Masc_tui_emblem_screen.about_facts ~theme keepers
            ^ Ansi.reset
          ]
      |> List.iter c.push)

let render_keeper_navigation (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  keeper_roster_pane ~focused:true state ~rows:terminal_rows ~cols buf;
  finish_frame_beside_acting_pane state ~surface_key:"keeper-navigation"
    ~help_door:(Option.is_none (text_input_target state ~compact_viewport:false))
    ~cursor:Frame_presenter.Hidden ~rows:terminal_rows ~cols
    ~footer:
      (Footer_hints
         { hints = Masc_tui_keys.keeper_navigation_hints ~lang:state.ui_language
         ; position = None
         })
    buf

let context_split_lines ~cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = Theme.recede () ^ " │ " ^ Ansi.reset in
  let right_width = max 1 (inner - left_width - 3) in
  let count = max (List.length left) (List.length right) in
  List.init count (fun index ->
      let left = Option.value ~default:"" (List.nth_opt left index) in
      let right = Option.value ~default:"" (List.nth_opt right index) in
      fit_width left left_width ^ divider ^ fit_width right right_width)

let context_inspector_progress_spec state =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let keeper =
    Option.value ~default:(say "키퍼 없음" "no Keeper") state.context_inspector_keeper
    |> Keeper_chat.terminal_safe_text
  in
  let gen = string_of_int state.context_inspector_generation in
  if state.context_inspector_loading then
    Some ("reading:" ^ gen, say "컨텍스트 읽는 중" "Loading context", Some keeper)
  else if Masc_tui_fetched.in_flight state.context_inspector_part then
    Some ("part:" ^ gen, say "컨텍스트 구간 읽는 중" "Loading context section", Some keeper)
  else None

let context_inspector_sheet_of_spec ~ko ?started_at = function
  | None -> None
  | Some (_, ps_title, ps_detail) ->
      Some
        { ps_title
        ; ps_detail
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint = Some (if ko then "Esc:닫기" else "Esc:close")
        ; ps_blocking = false
        }

(* The plain body's line count and the window the frame shows it in, for the
   keys that scroll it. *)
let context_inspector_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let progress_sheet =
    context_inspector_sheet_of_spec ~ko:(state.ui_language = Lang_ko)
      (context_inspector_progress_spec state)
  in
  let count =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, _) -> List.length lines
    | Split _ -> 0
  in
  (count, surface_window_height ?progress_sheet state ~terminal_rows ~count)

(* The split detail column's body line count and its window height, for the
   keys that scroll it. The pinned header row is not theirs to scroll. *)
let context_inspector_detail_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let progress_sheet =
    context_inspector_sheet_of_spec ~ko:(state.ui_language = Lang_ko)
      (context_inspector_progress_spec state)
  in
  match context_inspector_content_lines ~cols state with
  | Plain _ -> (0, 0)
  | Split { common; right; _ } ->
      let content_height =
        surface_chrome_budget ~frame:Chrome_overlay ?progress_sheet state ~terminal_rows
      in
      let split_height =
        context_split_pane_height ~content_height ~common_len:(List.length common)
      in
      ( List.length right - 1
      , max 0 (split_height - 1) )

let context_split_window ~height ~offset lines =
  lines |> List.filteri (fun index _ -> index >= offset && index < offset + height)

(* The context inspector, through the overlay contract. The frame counts its
   rows and fills under a short body, which this pane did by hand with a loop
   of empty lines.

   The title opened on " Context" where every other overlay opens on MASC and
   its name, and spelled the tabs "1:stack 2:request 3:proof" -- key and label
   in the grammar of a footer hint, with the current one told apart only by
   colour. The tabs are the shared strip now, and the digits are the footer's
   to name. The footer's "[/] turn" had no colon, so the fitter read it as a
   note rather than a key. *)
let render_context_inspector state =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let say korean english = if ko then korean else english in
  let keeper =
    Option.value ~default:(say "키퍼 없음" "no Keeper") state.context_inspector_keeper
    |> Keeper_chat.terminal_safe_text
  in
  let spec = context_inspector_progress_spec state in
  let ctx_started_at =
    Masc_tui_types.progress_clock_option state ~slot:"context-inspector" ~now
      (Option.map (fun (sig_key, _, _) -> sig_key) spec)
  in
  let progress_sheet =
    context_inspector_sheet_of_spec ~ko ?started_at:ctx_started_at spec
  in
  (* What the numbers describe: a reading in flight, or one received some
     time ago. The pane does not poll, so without the age a reading from
     before the current turn read as the current turn. *)
  let refreshing =
    match progress_sheet with
    | Some sheet ->
        "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
    | None ->
        (match state.context_inspector_reading, state.context_inspector_read_at with
         | Some _, Some read_at ->
             let ago = Masc_tui_value.Ongoing.since ~now read_at in
             Ansi.dim
             ^ (if ko then "  " ^ ago ^ " 전 조회" else "  read " ^ ago ^ " ago")
             ^ Ansi.reset
         | Some _, None | None, (Some _ | None) -> "")
  in
  (* The search query, drawn where the typing lands: the Keepers strip's
     own indicator sits on a surface this pane replaced. *)
  let search_marker = search_marker_styled state in
  let ctx_title = screen_title (say " 컨텍스트" " Context") in
  let tabs =
    tab_strip
      ~width:
        (tab_strip_width ~cols
           ~before:(ctx_title ^ "  " ^ keeper ^ refreshing ^ "  ")
           ~after:search_marker)
      ~press:(fun tab text -> pressable (Press_context_tab tab) text)
      (List.map
         (fun (label, tab) -> (label, state.context_inspector_tab = tab, tab))
         [ (say "구성" "stack", Masc_tui_context_inspector.Composition)
         ; (say "요청" "request", Masc_tui_context_inspector.Exact_input)
         ; (say "근거" "proof", Masc_tui_context_inspector.Input_map)
         ; (say "응답" "response", Masc_tui_context_inspector.Response)
         ])
  in
  let hints = Masc_tui_keys.footer_hints_context ~cols state in
  let content = context_inspector_content_lines ~cols state in
  (* The plain shapes are one list, so the contract windows it and says which
     of its lines are showing; the inspector's overflow used to be cut with
     nothing saying so (#38623). The split pins its summary and headers above
     two windows of its own. *)
  let overflow =
    match content with
    | Plain (lines, selected) ->
        let height =
          surface_window_height ?progress_sheet state ~terminal_rows ~count:(List.length lines)
        in
        (* The cursor names a row, the window follows it: on the single-column
           shapes nothing lives under the row, so the smallest move that keeps
           it drawn is the right one. *)
        let response = state.context_inspector_tab = Masc_tui_context_inspector.Response in
        let stored_scroll = if response then state.context_inspector_response_scroll
          else state.context_inspector_scroll in
        let scroll =
          match selected with
          | None -> stored_scroll
          | Some cursor ->
              (* The item rows are one-line rows in a row, and the window
                 follows the selected one as it follows any row, so the
                 item list is paged by this window. *)
              report_drawn_list Context_inspector_items ~height;
              Masc_tui_scroll.ensure_visible ~cursor ~height
                (Masc_tui_scroll.normalize ~count:(List.length lines) ~height
                   stored_scroll)
        in
        Scrolled
          { scroll; report = (fun scroll ->
              if response then Context_inspector_response_scroll scroll
              else Context_inspector_scroll scroll) }
    | Split _ -> Paged_by_cursor
  in
  surface_chrome ~overflow ?progress_sheet ~now state ~terminal_rows ~cols
    ~surface_key:"context-inspector"
    ~help_door:(Option.is_none state.search)
    ~frame:Chrome_overlay
    ~title:
      (ctx_title ^ "  " ^ keeper ^ refreshing ^ "  " ^ tabs
       ^ search_marker)
    ~hints
    ~body:(fun ~budget:content_height c ->
      match content with
      | Plain (lines, _) -> List.iter c.push lines
      | Split { common; left; right } ->
          (* The summary clips to the frame rather than overflowing it: on a
             short terminal the split gives way before the pane draws a row
             past its last. *)
          List.iteri
            (fun index line -> if index < content_height then c.push line)
            common;
          let split_height =
            context_split_pane_height ~content_height
              ~common_len:(List.length common)
          in
          if split_height > 0 then begin
            (* Both columns are header :: rows, so the heads are total. The
               header row stays pinned above the windows -- it carries the
               focus caret, and a caret that scrolls away stops saying which
               pane hears j/k. *)
            context_split_lines ~cols ~left_width:(context_split_width cols)
              ~left:[ List.hd left ] ~right:[ List.hd right ]
            |> List.iter c.push;
            let body_height = split_height - 1 in
            report_drawn_list Context_inspector_items ~height:body_height;
            let items = List.length left - 1 in
            let cursor =
              min (max 0 (items - 1)) (max 0 state.context_inspector_cursor)
            in
            (* Stateless bottom-pin over the item rows; the detail column
               owns its scroll, so neither pane drags the other. *)
            let left_offset =
              Masc_tui_scroll.ensure_visible ~cursor ~height:body_height 0
            in
            let right_offset =
              Masc_tui_scroll.normalize ~count:(List.length right - 1)
                ~height:body_height state.context_inspector_detail_scroll
            in
            (* The pane that hears j/k says where its reader is: the
               selected item, or the window over the detail. *)
            (match state.context_inspector_focus with
             | Left_pane ->
                 if items > 0 then
                   c.position (Masc_tui_value.Position.row ~selected:(Some cursor) ~total:items)
             | Right_pane ->
                 Option.iter c.position
                   (Masc_tui_value.Position.window ~first:right_offset ~shown:body_height
                      ~total:(List.length right - 1)));
            context_split_lines ~cols ~left_width:(context_split_width cols)
              ~left:
                (context_split_window ~height:body_height ~offset:left_offset
                   (List.tl left))
              ~right:
                (context_split_window ~height:body_height ~offset:right_offset
                   (List.tl right))
            |> List.iter c.push
          end)

(* The height an overlay shows [count] rows in. Where the window stands is
   on the title row, so the body keeps every row. [Masc_tui_scroll.content_height]
   owns that rule; the frame supplies the chrome. *)
let overlay_window_height ~rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:framed_chrome_rows ~count
    ~preview_keep:None

let detail_reading_action_width cols = max 0 (framed_inner_width cols - 2)
let detail_reading_width cols = max 1 (detail_reading_action_width cols)
let detail_reading_document reading ~cols =
  Masc_tui_detail_reading.rows ~width:(detail_reading_width cols) reading

(* The relationship page is an independently refreshed observation. Keep its
   read status outside the document window so End/G cannot hide a failed or
   pending replacement while the old page remains on screen. *)
let detail_peer_status state reading =
  let ko = state.ui_language = Lang_ko in
  let retained = function
    | Some page ->
        Printf.sprintf (if ko then " · %d페이지 유지" else " · page %d retained") page
    | None -> "" in
  let retry = function
    | Some page ->
        Printf.sprintf (if ko then " · r:%d페이지 재시도" else " · r retries page %d") page
    | None -> "" in
  match keeper_peer_status_for_reading state reading with
  | Some (Keeper_peer_loading {page; retained = previous; retry = failed}) ->
      Some (Theme.info (),
        Printf.sprintf
          (if ko then "  %s %d페이지 읽는 중%s%s" else "  %s Loading page %d%s%s")
          (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way)
          page (retained previous) (retry failed))
  | Some (Keeper_peer_arrived {page; retained = previous; retry = failed}) ->
      Some (Theme.info (),
        Printf.sprintf
          (if ko then "  %s %d페이지 응답 수신%s%s · 화면 반영 대기"
           else "  %s Page %d response received%s%s · awaiting frame")
          (Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way)
          page (retained previous) (retry failed))
  | Some (Keeper_peer_failed {page; retained = previous; reason}) ->
      Some (Theme.warn (), keeper_peer_failure_status ~page ~retained:previous ~reason)
  | Some (Keeper_peer_kept_back {page; retained = previous; notice}) ->
      Some (Theme.warn (),
        Printf.sprintf
          (if ko then "  %s · r:재시도 · %d페이지%s" else "  %s · r retry · page %d%s")
          (Masc.Tui_terminal_text.sanitize_terminal_text notice) page (retained previous))
  | Some (Keeper_peer_current page) ->
      Some (Theme.recede (),
        Printf.sprintf (if ko then "  %d페이지 · 대기 중 관계" else "  Page %d · queued relationships") page)
  | Some Keeper_peer_unread ->
      Some (Theme.warn (),
        ui_text state ~ko:"  관계 페이지 조회 불가 · r:재시도"
          ~en:"  Relationship page unavailable · r retry")
  | None -> None

let detail_reading_progress_spec state reading =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  match keeper_peer_status_for_reading state reading with
  | Some (Keeper_peer_loading { page; _ }) ->
      Some
        ( "peer-loading:" ^ string_of_int page
        , say "관계 페이지 읽는 중" "Loading relationship page"
        , Some (Printf.sprintf (if ko then "%d페이지를 조회하고 있습니다" else "Fetching page %d") page)
        , false )
  | Some (Keeper_peer_arrived { page; _ }) ->
      Some
        ( "peer-arrived:" ^ string_of_int page
        , say "관계 페이지 반영 중" "Applying relationship page"
        , Some (Printf.sprintf (if ko then "%d페이지 응답을 반영하고 있습니다" else "Applying page %d response") page)
        , false )
  | Some (Keeper_peer_failed _ | Keeper_peer_kept_back _ | Keeper_peer_current _ | Keeper_peer_unread)
  | None ->
      (match current_board_reader state with
       | Some reader when Masc_tui_board_reader.original_open_pending reader ->
           Some
             ( "board-open"
             , say "원본 파일 여는 중" "Opening original file"
             , Some (say "외부 뷰어에서 원본 첨부 파일을 열고 있습니다"
                       "Opening verified attachment in viewer")
             , true )
       | Some reader when Option.is_some (Masc_tui_board_reader.pending reader) ->
           Some
             ( "board-read"
             , say "첨부 파일 읽는 중" "Loading attachment"
             , Some (say "서버에서 첨부 원본을 조회하고 있습니다"
                       "Fetching attachment bytes from server")
             , false )
       | Some reader when Option.is_some (Masc_tui_board_reader.pending_preparation reader) ->
           Some
             ( "board-prep"
             , say "첨부 문서 준비 중" "Preparing attachment"
             , Some (say "선택한 형식으로 문서를 정리하고 있습니다"
                       "Preparing attachment for display")
             , false )
       | Some _ | None ->
           (match current_chat_call_reader state with
            | Some reader when Masc_tui_chat_call_reader.pending reader ->
                Some
                  ( "chat-call"
                  , say "원본 도구 실행 읽는 중" "Loading tool execution"
                  , Some (say "선택한 실행의 원본 입출력을 조회하고 있습니다"
                            "Reading original execution transcript")
                  , false )
            | Some _ | None ->
                (match current_task_inspector state with
                 | Some reader
                   when Option.is_some (task_inspection_pending reader.tci_original)
                        || Masc_tui_original_task_read.any_pending
                             (task_inspection_source reader.tci_original) ->
                     Some
                       ( "task-inspect"
                       , say "원본 작업 정보 읽는 중" "Loading original task"
                       , Some (say "작업 상세·이력·검증 근거를 조회하고 있습니다"
                                 "Reading original task details, history, and evidence")
                       , false )
                 | Some _ | None -> None)))

let detail_reading_sheet_of_spec ~ko ?started_at = function
  | None -> None
  | Some (_, ps_title, ps_detail, ps_blocking) ->
      Some
        { ps_title
        ; ps_detail
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint = Some (if ko then "Esc:뒤로" else "Esc:back")
        ; ps_blocking
        }

let detail_reading_height state reading ~terminal_rows ~count:_ =
  let ko = state.ui_language = Lang_ko in
  let progress_sheet =
    detail_reading_sheet_of_spec ~ko (detail_reading_progress_spec state reading)
  in
  let budget =
    surface_chrome_budget ~frame:Chrome_overlay ?progress_sheet state ~terminal_rows
  in
  match detail_peer_status state reading with
  | None -> max 0 budget
  | Some _ -> max 0 (budget - 1)

let detail_reading_viewport_at (state : state) reading ~terminal_rows ~cols =
  let count = List.length (detail_reading_document reading ~cols) in
  count, detail_reading_height state reading ~terminal_rows ~count

let detail_reading_viewport (state : state) reading =
  let terminal_rows, cols = get_terminal_size () in
  detail_reading_viewport_at state reading ~terminal_rows ~cols

let render_detail_reading (state : state) reading =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let say korean english = if ko then korean else english in
  let document = Masc_tui_detail_reading.rows_with_search
      ~width:(detail_reading_width cols) reading in
  let count = List.length document in
  let peer_status = detail_peer_status state reading in
  let active_spec = detail_reading_progress_spec state reading in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"detail-reading" ~now
      (Option.map (fun (sig_key, _, _, _) -> sig_key) active_spec)
  in
  let progress_sheet =
    detail_reading_sheet_of_spec ~ko ?started_at active_spec
  in
  let title_badge =
    match progress_sheet with
    | None -> ""
    | Some sheet ->
        "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
  in
  let source_title = Terminal_text.single_line (Masc_tui_detail_reading.title reading) in
  let title, search_hint = match Masc_tui_detail_reading.search_query reading with
    | None -> source_title, say "/:찾기" "/:find"
    | Some query ->
        let match_count = List.fold_left (fun count (_,mark) ->
          match mark with
          | Masc_tui_detail_reading.No_match -> count
          | Match | Current_match -> count+1) 0 document in
        let query_label = Printf.sprintf "/%s (%d)"
          (Terminal_text.single_line query)
          match_count in
        let editing = Masc_tui_detail_reading.search_editing reading in
        (* The footer can collapse to its help door. Keep the query with the
           document too, ahead of its title so narrow readers can see it. *)
        (if editing then say "찾기 " "Find " else "") ^ query_label ^ " · " ^ source_title,
        query_label ^ "  " ^
          (if editing then say "Enter:유지  Esc:취소" "Enter:keep  Esc:cancel"
           else say "n/N:다음/이전  /:찾기" "n/N:next/previous  /:find") in
  let hints=Option.value (Masc_tui_detail_reading.hints reading)
      ~default:(say "j/k:스크롤  PgUp/PgDn:페이지  Home/End:처음/끝  Esc:뒤로"
                  "j/k:scroll  PgUp/PgDn:page  Home/End:edges  Esc:back") in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay ?progress_sheet ~now state
    ~terminal_rows ~cols ~surface_key:"detail-reading"
    ~title:(screen_title (" " ^ title) ^ title_badge)
    ~hints:(search_hint ^ "  " ^ hints)
    ~body:(fun ~budget c ->
      let peer_rows = if Option.is_some peer_status then 1 else 0 in
      let height = max 0 (budget - peer_rows) in
      let scroll = Masc_tui_detail_reading.scroll ~count ~height reading in
      if budget > 0 then
        Option.iter (fun (style, text) -> c.push_styled ~style text) peer_status;
      List.iteri (fun index (row,mark) ->
        if index >= scroll && index < scroll + height then
          let text = match row with
            | Masc_tui_detail_reading.Heading text | Content text | Note text -> text in
          match mark with
          | Masc_tui_detail_reading.Current_match ->
              c.push_selected ("\xe2\x80\xba " ^ Masc_tui_theme.strip_sgr text)
          | Match ->
              c.push_styled ~style:Ansi.underline ("* " ^ Masc_tui_theme.strip_sgr text)
          | No_match ->
              match row with
              | Masc_tui_detail_reading.Heading text -> c.push_styled ~style:Ansi.bold ("  " ^ text)
              | Content text -> c.push ("  " ^ text)
              | Note text -> c.push_styled ~style:(Theme.recede ()) ("  " ^ text)) document;
      if height > 0 then
        Option.iter c.position
          (Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count))

(* The sheet's rows and the viewport that shows them, at this width. One
   answer for the two readers -- the keypress that bounds the scroll and the
   frame that draws it -- so [G] cannot land the scroll a row past what the
   frame is showing, and a press the frame cannot spend is not taken. *)
let help_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count =
    List.length
      (Masc_tui_help.sheet ~cols
         (help_lines ~width:(Masc_tui_help.line_cells ~cols) state))
  in
  (count, overlay_window_height ~rows ~count)

(* What a palette lists, as the noun a count is written with and its plural.
   The count line, the finder's catalog note and the empty-list line name the
   same thing, and each spelled it as a plural: "1 commands · 1/1". The
   symbol chooser's rows are the names on the cursor's line, not commands. *)
let palette_noun : palette_mode -> string * string = function
  | Masc_tui_types.Palette_jump -> ("command", "commands")
  | Masc_tui_types.Palette_choice _ -> ("name", "names")
  | Masc_tui_types.Palette_files _ -> ("file", "files")
  | Masc_tui_types.Palette_locations _ -> ("location", "locations")
  | Masc_tui_types.Palette_branches _ -> ("branch", "branches")
  | Masc_tui_types.Palette_worktrees _ -> ("worktree", "worktrees")
  | Masc_tui_types.Palette_search _ -> ("match", "matches")

let palette_noun_ko = function
  | Masc_tui_types.Palette_jump -> "명령"
  | Masc_tui_types.Palette_choice _ -> "이름"
  | Masc_tui_types.Palette_files _ -> "파일"
  | Masc_tui_types.Palette_locations _ -> "위치"
  | Masc_tui_types.Palette_branches _ -> "브랜치"
  | Masc_tui_types.Palette_worktrees _ -> "워크트리"
  | Masc_tui_types.Palette_search _ -> "일치"

let palette_count ~ko mode count =
  if ko then
    Printf.sprintf "%s %d개" (palette_noun_ko mode) count
  else
    let singular, plural = palette_noun mode in
    Message_layout.count_noun ~plural count singular

(* The search runs under the directory the Code pane had open (the server
   passes it to git as a pathspec), so the overlay says which. The root of the
   checkout is the default and needs no words. *)
let search_place (origin : code_finder_origin) =
  if String.equal origin.cfo_dir "" then None else Some origin.cfo_dir

(* The [:] palette: a typed filter over every jump the strip and roster
   offer. The list is the same [Masc_tui_palette.palette_matches] the Enter key resolves, so
   what is highlighted is what will run. *)
let render_palette (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let typed_question =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump ->
        Masc_tui_palette.palette_typed_question state.palette_query
    | Masc_tui_types.Palette_choice _ | Masc_tui_types.Palette_files _
    | Masc_tui_types.Palette_locations _ | Masc_tui_types.Palette_branches _
    | Masc_tui_types.Palette_worktrees _ | Masc_tui_types.Palette_search _ -> None
  in
  let explicit_question =
    match typed_question with
    | Some (question, Some symbol) -> Some (question, symbol)
    | Some (_, None) | None -> None
  in
  let matches = Masc_tui_palette.palette_matches state in
  let total = List.length matches in
  let cursor = max 0 (min state.palette_cursor (total - 1)) in
  let say korean english = if ko then korean else english in
  let palette_progress_spec =
    match state.palette_mode with
    | Masc_tui_types.Palette_worktrees _ ->
        (match code_worktrees_view state with
         | Masc_tui_fetched.Loading ->
             Some
               ( "worktrees"
               , say "워크트리 읽는 중" "Reading worktrees"
               , Some (say "Git 워크트리 목록을 조회하고 있습니다" "Listing Git worktrees")
               , false )
         | Absent | Ready _ | Stale _ | Failed _ -> None)
    | Masc_tui_types.Palette_branches _ ->
        (match code_branches_view state with
         | Masc_tui_fetched.Loading ->
             Some
               ( "branches"
               , say "브랜치 읽는 중" "Reading branches"
               , Some (say "Git 브랜치 목록을 조회하고 있습니다" "Listing Git branches")
               , false )
         | Absent | Ready _ | Stale _ | Failed _ -> None)
    | Masc_tui_types.Palette_search _ ->
        (match code_search_current state with
         | Some (key, Masc_tui_fetched.Loading) ->
             Some
               ( "search:" ^ key.css_query
               , say "파일 내 검색 중" "Searching in files"
               , Some (Terminal_text.single_line key.css_query)
               , false )
         | Some (_, (Absent | Ready _ | Stale _ | Failed _)) | None -> None)
    | Masc_tui_types.Palette_files _ ->
        (match Masc_tui_fetched.current state.code_finder_file with
         | Some (_, Masc_tui_fetched.Loading) ->
             Some
               ( "open-file"
               , say "선택한 파일 여는 중" "Opening selected file"
               , Some (say "파일 내용을 불러오고 있습니다" "Loading file contents")
               , true )
         | Some (_, (Absent | Ready _ | Stale _ | Failed _)) | None ->
             (match code_finder_catalog state with
              | Masc_tui_fetched.Loading ->
                  Some
                    ( "files"
                    , say "체크아웃 파일 읽는 중" "Reading checkout files"
                    , Some (say "워크스페이스 파일 목록을 수집하고 있습니다"
                              "Indexing checkout files")
                    , false )
              | Absent | Ready _ | Stale _ | Failed _ -> None))
    | Masc_tui_types.Palette_jump | Palette_choice _ | Palette_locations _ -> None
  in
  let palette_started_at =
    Masc_tui_types.progress_clock_option state ~slot:"palette" ~now
      (Option.map (fun (sig_key, _, _, _) -> sig_key) palette_progress_spec)
  in
  let progress_sheet =
    Option.map
      (fun (_, ps_title, ps_detail, ps_blocking) ->
        { ps_title
        ; ps_detail
        ; ps_started_at = palette_started_at
        ; ps_meter = None
        ; ps_action_hint = Some (say "Esc:닫기" "Esc:close")
        ; ps_blocking
        })
      palette_progress_spec
  in
  let title, prompt, action =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump ->
        (say " 명령 팔레트" " Command palette", ":",
         if Option.is_some typed_question then say "질문" "ask" else say "실행" "run")
    | Masc_tui_types.Palette_choice { choice_question; choice_line } ->
        let names = List.length (Masc_tui_palette.code_cursor_line_symbols state) in
        let heading =
          if ko then
            Printf.sprintf " %s · %d줄 %s" choice_question choice_line
              (palette_count ~ko state.palette_mode names)
          else
            Printf.sprintf " %s · %s on line %d" choice_question
              (palette_count ~ko state.palette_mode names) choice_line
        in
        (heading, say "필터:" "filter:", say "질문" "ask")
    | Masc_tui_types.Palette_files _ ->
        (say " 파일 찾기" " Find file", say "필터:" "filter:", say "열기" "open")
    | Masc_tui_types.Palette_branches _ ->
        (say " 브랜치" " Branches", say "필터:" "filter:", say "닫기" "close")
    | Masc_tui_types.Palette_worktrees _ ->
        (say " 워크트리" " Worktrees", say "필터:" "filter:", say "닫기" "close")
    | Masc_tui_types.Palette_search _ ->
        (say " 파일 내 검색" " Search in files", say "검색:" "search:",
         (match Masc_tui_palette.search_enter state with
          | Masc_tui_palette.Enter_opens _ -> say "열기" "open"
          | Masc_tui_palette.Enter_searches -> say "검색" "search"))
    | Masc_tui_types.Palette_locations offer ->
        let query = Masc_tui_fetched.request_key offer.clo_query in
        (Printf.sprintf " %s · %s" query.clq_question
           (Terminal_text.single_line query.clq_symbol), say "필터:" "filter:", say "열기" "open")
  in
  (* The overlay fills unused rows so the footer stays on the composer row. *)
  let caret = "\xe2\x96\x8c" in
  let prompt = Ansi.bold ^ prompt ^ Ansi.reset ^ " " in
  let inner_width = framed_inner_width cols in
  let prompt_width = Message_layout.display_width prompt in
  let caret_width = Message_layout.display_width caret in
  (* Keep the end being edited on screen. The masthead yields before the
     filter loses all of its cells; it returns as the viewport grows. *)
  let query = Terminal_text.single_line state.palette_query in
  let title = screen_title title ^ "  " in
  let title =
    if Message_layout.display_width title + prompt_width + caret_width
       + Message_layout.display_width query > inner_width
    then "" else title
  in
  let query_width =
    max 0
      (inner_width - Message_layout.display_width title - prompt_width
       - caret_width)
  in
  let query =
    Message_layout.input_viewport ~max_cells:query_width
      query
  in
  let finder_notes =
    let plain text = Terminal_text.single_line text in
    let loading text = progress_inline ~ko ~now ?started_at:palette_started_at text in
    match state.palette_mode with
    | Palette_jump | Palette_choice _ -> []
    | Palette_worktrees _ ->
        (match code_worktrees_view state with
         | Masc_tui_fetched.Absent ->
             [ plain (say "워크트리 목록이 비활성 상태입니다 · Esc로 코드 화면 복귀"
                        "Worktrees are no longer active; Esc returns to Code") ]
         | Masc_tui_fetched.Loading -> [ loading (say "워크트리 읽는 중" "Reading worktrees") ]
         | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> [ plain detail ]
         | Masc_tui_fetched.Ready listing ->
             [ plain
                 (Printf.sprintf "%s · %s%s"
                    (palette_count ~ko state.palette_mode
                       (List.length listing.Tui_decode.gws_worktrees))
                    (if String.equal listing.gws_root "" then
                       say "워크스페이스 저장소" "workspace repository"
                     else listing.gws_root)
                    (if listing.gws_truncated then say " · 앞부분만 표시" " · first only" else "")) ])
    | Palette_branches _ ->
        (match code_branches_view state with
         | Masc_tui_fetched.Absent ->
             [ plain (say "브랜치 목록이 비활성 상태입니다 · Esc로 코드 화면 복귀"
                        "Branches are no longer active; Esc returns to Code") ]
         | Masc_tui_fetched.Loading -> [ loading (say "브랜치 읽는 중" "Reading branches") ]
         | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> [ plain detail ]
         | Masc_tui_fetched.Ready listing ->
             [ plain
                 (Printf.sprintf "%s · %s%s"
                    (palette_count ~ko state.palette_mode
                       (List.length listing.Tui_decode.gbs_branches))
                    (if String.equal listing.gbs_root "" then
                       say "워크스페이스 체크아웃" "workspace checkout"
                     else listing.gbs_root)
                    (if listing.gbs_truncated then say " · 최신만 표시" " · newest only" else "")) ])
    | Palette_search search_origin ->
        (match code_search_current state with
         | None ->
             [ plain
                 (Printf.sprintf
                    (if ko then "%d자 이상 입력 후 Enter로 %s 검색"
                     else "Type at least %d characters, then Enter to search %s")
                    code_search_min_query_bytes
                    (match search_place search_origin with
                     | None -> say "체크아웃 전체" "the checkout"
                     | Some dir -> if ko then dir ^ " 하위" else "under " ^ dir)) ]
         | Some (key, Masc_tui_fetched.Loading) ->
             let label =
               if ko then Terminal_text.single_line key.css_query ^ " 검색 중"
               else "Searching for " ^ Terminal_text.single_line key.css_query
             in
             [ loading label ]
         | Some (_, (Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail))) ->
             [ plain detail ]
         | Some (_, Masc_tui_fetched.Ready search) ->
             (match search.Tui_decode.wss_matches, search.wss_truncated with
              | _, false -> []
              | [], true ->
                  [ plain (say "표시할 일치 항목 없음 · 검색어를 좁혀 주세요"
                             "No match could be shown · narrow the text") ]
              | shown, true ->
                  [ plain
                      (Printf.sprintf
                         (if ko then "앞의 %d건만 표시됨 · 검색어를 좁혀 주세요"
                          else "Only the first %d are shown · narrow the text")
                         (List.length shown)) ])
         | Some (_, Masc_tui_fetched.Absent) -> [])
    | Palette_locations offer ->
        if code_location_offer_current state offer then
          [ plain (say "결과 파일과 줄 선택 · Esc:현재 위치 유지"
                     "Choose a returned file and line · Esc keeps the current reading") ]
        else
          [ plain (say "이 위치 결과는 더 이상 최신이 아닙니다 · Esc로 코드 화면 복귀"
                     "These locations are no longer current · Esc returns to Code") ]
    | Palette_files _ ->
        let catalog_note = match code_finder_catalog state with
          | Masc_tui_fetched.Absent ->
              plain (say "파일 찾기가 비활성 상태입니다 · Esc로 코드 화면 복귀"
                       "File finder is no longer active; Esc returns to Code")
          | Masc_tui_fetched.Loading -> loading (say "체크아웃 파일 읽는 중" "Reading checkout files")
          | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> plain detail
          | Masc_tui_fetched.Ready catalog ->
              plain
                (Printf.sprintf "%s · %s"
                   (palette_count ~ko state.palette_mode
                      (List.length catalog.Tui_decode.wfc_files))
                   (if String.equal catalog.wfc_root "" then
                      say "워크스페이스 체크아웃" "workspace checkout"
                    else catalog.wfc_root)) in
        let file_notes = match Masc_tui_fetched.current state.code_finder_file with
          | Some (_, Masc_tui_fetched.Loading) ->
              [ loading (say "선택한 파일 여는 중" "Opening selected file") ]
          | Some (_, (Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail))) ->
              [ plain detail ]
          | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Ready _)) -> [] in
        catalog_note :: file_notes
  in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols
    ~surface_key:"palette"
    ~frame:Chrome_overlay
    ~title:
      (title ^ prompt ^ query
       ^ Theme.accent () ^ caret ^ Ansi.reset)
    (* [key:label] items, two spaces apart, the way every other footer is
       written. In the dotted form this row was one item with no colon, so
       {!Masc_tui_footer} could shed no whole key and keep no door: it fell
       through to the cell cut, where [Esc] survived only when the budget
       happened to reach it. test_a_row_in_another_grammar_loses_its_door
       measures that across widths. The selected row is the title row's
       position, not a footer item. *)
    ~hints:
      (if Masc_tui_palette.command_enter_has_nothing state then
         (* Nothing is listed, so Enter, the arrows and Home/End have no row to
            act on. The key handler reads the same answer. *)
         say "Ctrl-U:지우기  Esc:닫기" "Ctrl-U:clear  Esc:close"
       else
         Printf.sprintf
           (if ko then "Enter:%s  ↑/↓:선택  Home/End:처음/끝  Ctrl-U:지우기  Esc:닫기"
            else "Enter:%s  Up/Down:select  Home/End:first/last  Ctrl-U:clear  Esc:close")
           action)
    ~body:(fun ~budget c ->
      c.position
        (Masc_tui_value.Position.row
           ~selected:(if total = 0 then None else Some cursor) ~total);
      List.iter (fun note -> c.push ("   " ^ note)) finder_notes;
      match explicit_question with
      | Some (question, symbol) ->
          c.push_selected (" " ^ Masc_tui_theme.Glyph.current_entry ^ " " ^ question ^ " "
            ^ Terminal_text.single_line symbol);
          c.push
            (say "   코드 화면에 열린 파일의 이 심볼에 대해 질문"
               "   Ask about this symbol in the file open on Code")
      | None ->
          let context = match state.palette_mode with
            | Palette_jump when String.trim state.palette_query = "" ->
                [ui_text state
                   ~ko:"화면·키퍼·Task·게시글·설정 검색"
                   ~en:"Search screens, Keepers, Tasks, posts, or settings"]
            | Palette_search search_origin ->
                (match search_place search_origin with
                 | None -> []
                 | Some dir ->
                     let dir = Terminal_text.single_line dir in
                     [ if ko then "범위: " ^ dir else "In " ^ dir ])
            | Palette_jump | Palette_choice _ | Palette_files _ | Palette_branches _
            | Palette_worktrees _ | Palette_locations _ -> []
          in
          List.iter (fun note -> c.push_styled ~style:(Theme.recede ()) ("   " ^ note)) context;
          let selected_description =
            let ko = state.ui_language = Lang_ko in
            match state.palette_mode, Masc_tui_palette.search_enter state with
            | Palette_search _, Masc_tui_palette.Enter_searches ->
                Some
                  (if ko then "Enter:입력한 검색어로 워크스페이스 검색"
                   else "Enter:search workspace for typed query")
            | (Palette_search _, Masc_tui_palette.Enter_opens _)
            | ((Palette_jump | Palette_choice _ | Palette_files _
                | Palette_locations _ | Palette_branches _ | Palette_worktrees _),
               (Masc_tui_palette.Enter_opens _ | Masc_tui_palette.Enter_searches)) ->
                (match List.nth_opt matches cursor with
                 | Some (_, action) ->
                     Some (Masc_tui_palette.action_description ~ko action)
                 | None -> None)
          in
          let header_rows = List.length context + List.length finder_notes in
          let show_description =
            Option.is_some selected_description && budget - header_rows >= 4
          in
          let desc_rows = if show_description then 2 else 0 in
          let list_rows = max 0 (budget - header_rows - desc_rows) in
          let first = max 0 (cursor - max 1 list_rows + 1) in
          let visible =
            matches
            |> List.filteri (fun i _ -> i >= first && i < first + list_rows)
          in
          List.iteri
            (fun visible_index (label, _) ->
               if first + visible_index = cursor then
                 c.push_selected (" " ^ Masc_tui_theme.Glyph.current_entry ^ " " ^ Terminal_text.single_line label)
               else c.push ("   " ^ Terminal_text.single_line label))
            visible;
          (match show_description, selected_description with
           | true, Some desc ->
               let pad_rows = max 0 (list_rows - List.length visible) in
               for _ = 1 to pad_rows do c.push_empty () done;
               c.push_divider ();
               c.push_styled ~style:(Theme.recede ())
                 ("   " ^ Terminal_text.single_line desc)
           | false, (Some _ | None) | true, None -> ());
          if total = 0 then
            (match state.palette_mode, code_finder_catalog state with
             | Palette_search _, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                 | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Failed _
                 | Masc_tui_fetched.Stale _) -> ()
             | Palette_files _, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                 | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Stale _) -> ()
             | Palette_branches _, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                 | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Failed _
                 | Masc_tui_fetched.Stale _)
               when (match code_branches_view state with
                     | Masc_tui_fetched.Ready _ -> false
                     | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                     | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Stale _ -> true) -> ()
             | Palette_worktrees _, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                 | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Failed _
                 | Masc_tui_fetched.Stale _)
               when (match code_worktrees_view state with
                     | Masc_tui_fetched.Ready _ -> false
                     | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                     | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Stale _ -> true) -> ()
             | (Palette_files _ | Palette_branches _ | Palette_worktrees _ | Palette_locations _
               | Palette_jump | Palette_choice _),
               (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Ready _
               | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Stale _) ->
                 c.push
                   (if state.ui_language = Lang_ko then
                      "   일치하는 " ^ palette_noun_ko state.palette_mode ^ " 없음 · Ctrl-U로 필터 지우기"
                    else
                      "   No matching "
                      ^ snd (palette_noun state.palette_mode)
                      ^ " · Ctrl-U clears the filter")))

(* The link preview overlay. [surface_chrome] owns the box, the fill and the
   footer's row. The title names the site, so the footer carries only keys. *)
(* The card, its height and the line count, computed once for the two readers
   that need to agree: the renderer that draws it and the keys that scroll it.
   They did not agree before -- the renderer sized the card to the window while
   the keys moved a fixed five lines -- so a page key covered a quarter of a
   tall window and four windows of a short one. *)
let link_modal_card (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let url_opt =
    match state.link_modal_url with
    | Some u -> Some u
    | None ->
        (match state.link_modal_links with
         | first :: _ -> Some first
         | [] -> None)
  in
  match url_opt with
  | None -> None
  | Some url ->
      let preview = Masc_tui_link_preview.get_preview url in
      let total_links = List.length state.link_modal_links in
      (* Link index/total moved to zone 2 ([c.position]); body uses the full
         overlay budget without subtracting deleted in-body nav rows. *)
      let content_height =
        surface_chrome_budget ~frame:Chrome_overlay state ~terminal_rows
      in
      let content_lines =
        Masc_tui_link_preview.render_modal_card
          ~width:(framed_inner_width cols) ~height:content_height preview
      in
      Some (url, preview, total_links, content_height, content_lines)

(* The rows the modal shows and the rows it holds, for the page keys. *)
let link_modal_viewport (state : state) =
  match link_modal_card state with
  | None -> (0, 1)
  | Some (_, _, _, content_height, content_lines) ->
      (List.length content_lines, content_height)

let render_link_preview_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  match link_modal_card state with
  | None ->
      ignore (Masc_tui_types.progress_clock_option state ~slot:"link-preview" ~now None);
      surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"link-modal"
        ~frame:Chrome_overlay
        ~title:
          (screen_title (ui_text state ~ko:" 링크 미리보기" ~en:" Link preview")
           ^ "  " ^ Ansi.dim ^ ui_text state ~ko:"(링크 없음)" ~en:"(no links)"
           ^ Ansi.reset)
        ~hints:(Masc_tui_keys.footer_hints_link_preview_empty ~lang:state.ui_language)
        ~body:(fun ~budget:_ c ->
          c.push
            (ui_text state ~ko:"  (이 대화에서 미리볼 웹 링크가 없습니다)"
               ~en:"  (no web links found in this conversation to preview)"))
  | Some (_url, preview, total_links, _content_height, content_lines) ->
      let site = Masc_tui_link_preview.site_label preview in
      let total = List.length content_lines in
      let mosaic_loading =
        Option.exists Masc_tui_link_preview.mosaic_pending
          preview.Masc_tui_link_preview.image_url
      in
      let started_at =
        Masc_tui_types.progress_clock_option state ~slot:"link-preview" ~now
          (if mosaic_loading then preview.Masc_tui_link_preview.image_url else None)
      in
      let progress_sheet =
        if not mosaic_loading then None
        else
          Some
            { ps_title =
                ui_text state ~ko:"미리보기 이미지 불러오는 중"
                  ~en:"Loading preview image"
            ; ps_detail = Some (Terminal_text.single_line site)
            ; ps_started_at = started_at
            ; ps_meter = None
            ; ps_action_hint = Some (ui_text state ~ko:"Esc:닫기" ~en:"Esc:close")
            ; ps_blocking = false
            }
      in
      let title_badge =
        match progress_sheet with
        | None -> ""
        | Some sheet ->
            "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
      in
      let scroll_ref = ref 0 in
      surface_chrome state ~terminal_rows ~cols ~surface_key:"link-modal"
        ~frame:Chrome_overlay
        ?progress_sheet ~now
        ~overflow:(Self_scrolled (fun () -> Link_modal_scroll !scroll_ref))
        ~title:
          (screen_title (ui_text state ~ko:" 링크 미리보기" ~en:" Link preview")
           ^ "  " ^ Ansi.bold
           ^ Terminal_text.single_line site ^ Ansi.reset ^ title_badge)
        ~hints:
          (Masc_tui_link_preview.modal_hints ~total_links
             ~has_image:(Option.is_some preview.Masc_tui_link_preview.image_url))
        ~body:(fun ~budget c ->
          let height = max 1 budget in
          let max_scroll = max 0 (total - height) in
          let scroll = max 0 (min state.link_modal_scroll max_scroll) in
          scroll_ref := scroll;
          (* Which link of several is the position; a preview taller than
             its rows is read through a window, which then is. *)
          if total_links > 1 then
            c.position
              (Masc_tui_value.Position.row ~selected:(Some state.link_modal_cursor)
                 ~total:total_links);
          Option.iter c.position
            (Masc_tui_value.Position.window ~first:scroll ~shown:height ~total);
          List.iteri
            (fun index line ->
              if index >= scroll && index < scroll + height then
                c.push line)
            content_lines)

(* The invite card: the link a /play invite answer carries, and its QR. Where
   each row falls, and whether the QR fits at all, is decided by
   [Masc_tui_play_card.draw]; this only gives each kind of row its look. The
   QR rows arrive coloured and go in as they are: a theme colour on them would
   turn the code into a picture that no phone reads. *)
let play_card_indent = "  "

let render_play_card (state : state) card =
  let terminal_rows, cols = get_terminal_size () in
  (* The window as the operator sees it. The rows and columns a frame is laid
     out in are that less the navigation strip and any pane beside the surface,
     so a size the card asks for is added to this, not to those. *)
  let window_rows, window_cols = Masc_tui_ansi.get_terminal_size () in
  surface_chrome
    ~overflow:(Scrolled { scroll = state.play_invite_scroll;
                          report = (fun scroll -> Play_invite_scroll (card, scroll)) })
    state ~terminal_rows ~cols ~surface_key:"play-invite"
    ~frame:Chrome_overlay
    ~title:(screen_title (ui_text state ~ko:" 플레이 초대" ~en:" Play invite"))
    ~hints:(Masc_tui_keys.footer_hints_play_invite ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      let width = framed_inner_width cols - String.length play_card_indent in
      List.iter
        (fun row ->
          match row with
          | Masc_tui_play_card.Heading text ->
              c.push_styled ~style:Ansi.bold (play_card_indent ^ text)
          | Masc_tui_play_card.Advice text ->
              c.push_styled ~style:(Theme.recede ()) (play_card_indent ^ text)
          | Masc_tui_play_card.Link_row text | Masc_tui_play_card.Qr_row text ->
              c.push (play_card_indent ^ text)
          | Masc_tui_play_card.Note text ->
              c.push_styled ~style:(Theme.warn ()) (play_card_indent ^ text)
          | Masc_tui_play_card.Qr_needs { columns; rows } ->
              (* The card counts its own cells and says what it lacks. What
                 surrounds them -- the frame, the composer, the agenda strip,
                 the navigation strip -- stays the same when the window grows,
                 so the window needs what it has now plus the card's shortfall
                 in each direction. *)
              c.push_styled ~style:(Theme.warn ())
                (Printf.sprintf
                   (if state.ui_language = Lang_ko then
                      "%sQR을 표시하려면 최소 %d열 × %d행 창이 필요합니다"
                    else
                      "%sthe QR needs a window of %d columns by %d rows")
                   play_card_indent
                   (window_cols + max 0 (columns - width))
                   (window_rows + max 0 (rows - budget)))
          | Masc_tui_play_card.Blank -> c.push_empty ())
        (Masc_tui_play_card.draw ~ko:(state.ui_language = Lang_ko) card ~width ~rows:budget))

(* The record's rows and the viewport that shows them, the way
   [help_viewport] answers for the sheet: one pair for the keypress that
   bounds the scroll and the frame that draws it, and one row off the height
   when the record has more rows than it can show. *)
let keeper_deletions_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count = List.length (keeper_deletions_lines state ~cols) in
  (count, overlay_window_height ~rows ~count)

(* The deletion record overlay drew its rows and closed the box under them,
   with nothing filling the rows between: on a short record the footer stood in
   the middle of the screen with the composer alone at the bottom (150x44, a
   failed read, footer on row 9). The contract fills to the bottom. *)
let render_keeper_deletions (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let lines = keeper_deletions_lines state ~cols in
  let count = List.length lines in
  let loading = state.keeper_deletions_loading in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"keeper-deletions" ~now
      (if loading then Some ("active:" ^ string_of_int state.keeper_deletions_generation)
       else None)
  in
  let progress_sheet =
    if not loading then None
    else
      Some
        { ps_title =
            ui_text state ~ko:"삭제 기록 조회·재시도 중" ~en:"Loading/retrying deletions"
        ; ps_detail =
            Some
              (ui_text state ~ko:"키퍼 삭제 작업 이력과 복구 상태를 조회하고 있습니다"
                 ~en:"Reading Keeper deletion operations and retry state")
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint = Some (ui_text state ~ko:"Esc:닫기" ~en:"Esc:close")
        ; ps_blocking = true
        }
  in
  let viewport_height =
    max 1 (surface_chrome_budget ~frame:Chrome_overlay ?progress_sheet state ~terminal_rows)
  in
  let title_badge =
    match progress_sheet with
    | None -> ""
    | Some sheet ->
        "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
  in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols
    ~surface_key:"keeper-deletions"
    ~frame:Chrome_overlay
    ~title:
      (screen_title (if ko then " 키퍼 삭제 기록" else " Keeper deletion records")
       ^ title_badge)
    ~hints:(keeper_deletions_hints state ~scrollable:(count > viewport_height))
    ~body:(fun ~budget c ->
      let height = max 1 budget in
      let scroll =
        Masc_tui_scroll.normalize ~count ~height state.keeper_deletions_scroll
      in
      (* The record among the records is the position until its text runs
         past the rows, and then the window over that text is. *)
      (match state.keeper_deletions with
       | Some (Ok inventory) when inventory.Keeper_control.operations <> [] ->
           c.position
             (Masc_tui_value.Position.row ~selected:(Some state.keeper_deletions_cursor)
                ~total:(List.length inventory.Keeper_control.operations))
       | Some (Ok _ | Error _) | None -> ());
      List.iteri
        (fun index text ->
          if index >= scroll && index < scroll + height then c.push text)
        lines;
      (* The record is one JSON document. Measured on the live server, it ran
         past every height: at 44 rows it ended mid-object on "kind":
         "delivered", and the footer named the scroll keys without saying how
         far they had to go. *)
      Option.iter c.position
        (Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count))

(* The sheet's title: its name, then the filter while there is one, or whether
   the hint rows are on. The end of the filter being typed stays in view, the
   way the palette keeps its query. *)
let help_title (state : state) ~cols =
  (* The product name is not drawn (RFC tui-one-screen-grammar §2): the sheet
     is named for what it is, in the screen's language. *)
  let name = screen_title (" " ^ ui_text state ~ko:"도움말" ~en:"Help") in
  match state.help_filter with
  | Masc_tui_help.Off ->
      name ^ "  " ^ Ansi.dim
      ^ (if state.hints_visible then ui_text state ~ko:"힌트 켬" ~en:"hints on"
         else ui_text state ~ko:"힌트 끔" ~en:"hints off")
      ^ Ansi.reset
  | (Masc_tui_help.Typing query | Masc_tui_help.Kept query) as filter ->
      let caret =
        match filter with
        | Masc_tui_help.Typing _ -> "\xe2\x96\x8c"
        | Masc_tui_help.Off | Masc_tui_help.Kept _ -> ""
      in
      let lead = name ^ "  /" in
      let query_cells =
        framed_inner_width cols - Message_layout.display_width lead
        - Message_layout.display_width caret
      in
      lead
      ^ Message_layout.input_viewport ~max_cells:query_cells
          (Terminal_text.single_line query)
      ^ caret

(* The keys the footer names for the sheet in its current state. *)
let help_hints (state : state) =
  match state.help_filter with
  | Masc_tui_help.Off -> (
      match state.help_scope with
      | Masc_tui_help.Here ->
          ui_text state
            ~ko:"?:모든 화면  /:찾기  j/k:스크롤  PgUp/PgDn:페이지  g/G:처음/끝  h:힌트  Esc:닫기"
            ~en:"?:every screen  /:find  j/k:scroll  PgUp/PgDn:page  g/G:first/last  h:hints  Esc:close"
      | Masc_tui_help.Everything ->
          ui_text state
            ~ko:"/:필터  j/k:스크롤  PgUp/PgDn:페이지  g/G:처음/끝  h:힌트  Esc:닫기"
            ~en:"/:filter  j/k:scroll  PgUp/PgDn:page  g/G:first/last  h:hints  Esc:close")
  | Masc_tui_help.Typing _ ->
      ui_text state ~ko:"Enter:유지  Esc:지우기  Up/Down:스크롤  PgUp/PgDn:페이지"
        ~en:"Enter:keep  Esc:clear  Up/Down:scroll  PgUp/PgDn:page"
  | Masc_tui_help.Kept _ ->
      ui_text state
        ~ko:"/:고치기  Esc:지우기  j/k:스크롤  PgUp/PgDn:페이지  g/G:처음/끝  h:힌트  ?:닫기"
        ~en:"/:edit  Esc:clear  j/k:scroll  PgUp/PgDn:page  g/G:first/last  h:hints  ?:close"

(* The cheat sheet, through the overlay contract. It drew its box and its rows
   by hand and closed the box under the last row, so a sheet shorter than the
   screen -- a narrow filter, a tall terminal -- put the footer mid-screen. *)
let render_help (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rendered_rows =
    Masc_tui_help.sheet ~cols
      (help_lines ~width:(Masc_tui_help.line_cells ~cols) state)
  in
  surface_chrome ~overflow:(Self_scrolled (fun () -> Help_presented)) state ~terminal_rows ~cols ~surface_key:"help"
    ~frame:Chrome_overlay
    (* The title says what state the sheet is in; the keys that change it are
       the footer's, which draws h and Esc on this overlay and never drops Esc.
       Both rows spelled them, so the title said the footer twice. *)
    ~title:(help_title state ~cols)
    (* The sheet that names every other surface's keys did not name its own.
       It is longer than any terminal -- at 150x78 the later sections are
       still off screen -- so [G] is the difference between reading them and
       pressing [j] forty times, and nothing said [G] exists. The keys are
       handled at masc_tui.ml: "pageup" | "pagedown", "g", "G". *)
    ~hints:(help_hints state)
    (* [help_viewport] rather than the budget it is derived from: the
       keypress bounds the scroll against that pair, and a sheet whose
       drawing used a different height would leave [G] one row short. *)
    ~body:(fun ~budget:_ c ->
      let count, height = help_viewport state in
      let scroll =
        Masc_tui_scroll.normalize ~count ~height state.help_scroll
      in
      List.iteri
        (fun index line ->
          if index >= scroll && index < scroll + height then c.push line)
        rendered_rows;
      (* Which of them these are. The sheet is longer than any terminal --
         at 150x78 the later sections are still off screen -- so a reader
         pressing [j] had no way of telling a page from a hundred. *)
      Option.iter c.position
        (Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count))

(* Rows the agenda panel can show, and how many it has. The keypress bounds
   the scroll from the same pair the frame draws with -- the shape
   [Masc_tui_scroll] exists to keep in one place. *)
(* The panel's rows. Built in one place because three readers ask for them:
   the viewport that bounds the scroll, the frame that draws them, and the
   keypress that walks the ones Enter can act on. Three builders would be
   three chances for the cursor to name a row the frame is not drawing. *)
let agenda_lines (state : state) =
  let _terminal_rows, cols = get_terminal_size () in
  Agenda.overlay
    ~ko:(state.ui_language = Lang_ko)
    ~now:(Unix.gettimeofday ())
    ~localtime:Unix.localtime
    ~cols:(framed_inner_width cols)
    (Masc_tui_types.agenda state)

(* The panel's rows and the viewport that shows them, the way
   [help_viewport] answers for the sheet: one pair for the keypress that
   bounds the cursor and the frame that draws it, and one row off the height
   when the panel has more rows than it can show. *)
let agenda_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count = List.length (agenda_lines state) in
  (count, overlay_window_height ~rows ~count)

let agenda_scroll_position (state : state) =
  let lines = agenda_lines state in
  let count, height = agenda_viewport state in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.agenda_scroll in
  match state.agenda_navigation with
  | Agenda_read_rows -> scroll
  | Agenda_follow_selection ->
      (match Agenda.selected_index lines ~selected:state.agenda_selected with
       | Some cursor -> Masc_tui_scroll.ensure_visible ~cursor ~height scroll
       | None -> scroll)

let answering_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  ( List.length (answering_lines state)
  , max 1 (framed_content_height ~rows - answering_preview_rows) )

let answering_selected_target (state : state) ~lines =
  let count = List.length lines in
  let _, height = answering_viewport state in
  let scroll = Masc_tui_scroll.normalize ~count ~height state.answering_scroll in
  if state.answering_cursor < scroll || state.answering_cursor >= scroll + height then None
  else
    match List.nth_opt lines state.answering_cursor with
    | Some line -> line.Masc_tui_answering.target
    | None -> None

let queue_panel_item_identity ~ko = function
  | Masc_tui_queue_inspection.Local_message id ->
    (if ko then "로컬 메시지: " else "Local message: ") ^ id
  | Server_message id ->
    (if ko then "대기 메시지: " else "Queued message: ") ^ id
  | Running_message id ->
    (if ko then "실행 중 메시지: " else "Running message: ") ^ id
  | Event (reference, revision) ->
    Printf.sprintf
      (if ko then "이벤트: %s · 세대 %Ld" else "Event: %s · incarnation %Ld")
      reference revision
  | Schedule (id, instance) ->
    if ko then "일정: " ^ id ^ " · 인스턴스 " ^ instance
    else "Schedule: " ^ id ^ " · instance " ^ instance

let queue_panel_detail_lines state (panel : queue_panel) ~cols =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let reading = queue_panel_detail_reading ~items:(queue_panel_items state panel) panel in
  let content = match reading with
    | Queue_detail_ready (id, item) ->
      queue_panel_item_identity ~ko id ^ "\n\n" ^ item.text
    | Queue_detail_loading ->
      say "대기열 요청을 처리 중입니다. 완료될 때까지 서버 항목을 볼 수 없습니다."
        "Queue request in progress. The current server item is unavailable until it finishes."
    | Queue_detail_unavailable reason ->
      say "현재 대기열 관측에서 이 서버 항목을 읽을 수 없습니다. 목록으로 돌아가 새로고침하세요."
        "This server item is unavailable in the current queue observation. Return to the list and refresh."
      ^ Option.fold ~none:"" ~some:(fun detail -> "\n\n" ^ detail) reason
    | Queue_detail_missing ->
      say "이 항목은 더 이상 현재 대기열에 없습니다. 목록으로 돌아가 새로고침하세요."
        "This item is no longer in the current queue. Return to the list and refresh."
    | Queue_detail_none -> say "선택한 항목이 없습니다." "No item is selected." in
  Message_layout.wrap_body ~max_cells:(max 1 (framed_inner_width cols - 2))
    ~sanitize:Terminal_text.single_line content

let queue_panel_progress_spec state (panel : queue_panel) =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  if Option.is_some panel.qp_detail then
    let items = queue_panel_items state panel in
    match queue_panel_detail_reading ~items panel with
    | Queue_detail_loading ->
        Some
          ( "queue-detail"
          , panel.qp_keeper
          , say "대기열 요청 처리 중" "Processing queue request"
          , Some
              (say "서버 대기열 항목 응답을 기다리고 있습니다"
                 "Waiting for server queue item response")
          , Some (say "Esc:목록" "Esc:list")
          , true )
    | Queue_detail_ready _ | Queue_detail_unavailable _
    | Queue_detail_missing | Queue_detail_none -> None
  else
    let queue_busy =
      panel.qp_reading = Queue_loading
      || List.mem panel.qp_keeper state.keeper_queue_inflight
    in
    let run_next_busy =
      List.exists
        (fun (r : Masc_tui_keeper_chat_projection.request) ->
          String.equal r.keeper_name panel.qp_keeper)
        state.keeper_run_next_inflight
    in
    if run_next_busy then
      Some
        ( "queue-list"
        , "run-next:" ^ panel.qp_keeper
        , say "다음 작업 실행 중" "Running next queued turn"
        , Some (Terminal_text.single_line panel.qp_keeper)
        , Some (say "Esc:닫기" "Esc:close")
        , true )
    else if queue_busy then
      Some
        ( "queue-list"
        , "queue:" ^ panel.qp_keeper
        , say "대기열 조회·전송 중" "Updating queue"
        , Some
            (say "서버 대기열 상태와 제어 요청을 처리하고 있습니다"
               "Reading queue snapshot or applying queue action")
        , Some (say "Esc:닫기" "Esc:close")
        , false )
    else None

let queue_panel_sheet_of_spec ?started_at = function
  | None -> None
  | Some (_, _, ps_title, ps_detail, ps_action_hint, ps_blocking) ->
      Some
        { ps_title
        ; ps_detail
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint
        ; ps_blocking
        }

let queue_panel_detail_viewport state panel =
  let terminal_rows, cols = get_terminal_size () in
  let count = List.length (queue_panel_detail_lines state panel ~cols) in
  let progress_sheet = queue_panel_sheet_of_spec (queue_panel_progress_spec state panel) in
  let budget = surface_chrome_budget ?progress_sheet state ~terminal_rows in
  let height = queue_panel_window_height ~budget in
  count, height

let queue_panel_layout ?progress_sheet state (panel : queue_panel) =
  let terminal_rows, cols = get_terminal_size () in
  let progress_sheet =
    match progress_sheet with
    | Some _ as sheet -> sheet
    | None -> queue_panel_sheet_of_spec (queue_panel_progress_spec state panel)
  in
  let has_context = view_is_chat state.view
      && state.msg_target_keeper_name = Some panel.qp_keeper
      && Option.is_none panel.qp_detail in
  Masc_tui_queue_layout.choose panel.qp_layout ~has_context ~cols
    ~body_rows:(surface_chrome_budget ?progress_sheet state ~terminal_rows)
    (* Reserve status, a possible receipt and a possible selection note when
       choosing placement, so selecting or receiving a result does not move it. *)
    ~queue_fixed_rows:3
    ~queue_item_rows:(List.length (queue_panel_items state panel))

let queue_panel_list_budget state panel =
  let terminal_rows, _ = get_terminal_size () in
  let progress_sheet = queue_panel_sheet_of_spec (queue_panel_progress_spec state panel) in
  Masc_tui_queue_layout.queue_rows
    ~body_rows:(surface_chrome_budget ?progress_sheet state ~terminal_rows)
    (queue_panel_layout ?progress_sheet state panel)

let queue_panel_viewport state panel =
  let qv_placement = queue_panel_layout state panel in
  let qv_document_rows, qv_content_rows =
    if Option.is_some panel.qp_detail then queue_panel_detail_viewport state panel
    else
      let items = queue_panel_items state panel in
      List.length items,
        queue_panel_list_height ~items ~budget:(queue_panel_list_budget state panel) panel in
  {qv_placement; qv_content_rows; qv_document_rows}

let render_queue_panel (state : state) (panel : queue_panel) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let say korean english = if ko then korean else english in
  let title ?(badge = "") label =
    screen_title label ^ "  " ^ Terminal_text.single_line panel.qp_keeper
    ^ (if Option.is_some panel.qp_detail then "" else match panel.qp_layout with
       | Masc_tui_queue_layout.Adaptive -> say " · 자동" " · automatic"
       | Expanded -> say " · 전체" " · full")
    ^ badge
  in
  let spec = queue_panel_progress_spec state panel in
  let owner () = Queue_panel_presented
      (queue_panel_owner state panel ~viewport:(queue_panel_viewport state panel)) in
  if Option.is_some panel.qp_detail then begin
    Masc_tui_types.clear_progress_clock state ~slot:"queue-list";
    let detail_started_at =
      Masc_tui_types.progress_clock_option state ~slot:"queue-detail" ~now
        (Option.map (fun (_, sig_key, _, _, _, _) -> sig_key) spec)
    in
    let progress_sheet = queue_panel_sheet_of_spec ?started_at:detail_started_at spec in
    let badge =
      match progress_sheet with
      | None -> ""
      | Some sheet ->
          "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
    in
    let lines = queue_panel_detail_lines state panel ~cols in
    surface_chrome ~overflow:(Self_scrolled owner) ?progress_sheet ~now state
      ~terminal_rows ~cols
      ~surface_key:"keeper-queue-detail" ~frame:Chrome_overlay
      ~title:(title ~badge (say " 대기열 항목" " Queue item"))
      ~hints:(Masc_tui_keys.footer_hints_queue state panel)
      ~body:(fun ~budget c ->
        let count = List.length lines in
        let height = queue_panel_window_height ~budget in
        let scroll = Masc_tui_scroll.normalize ~count ~height panel.qp_detail_scroll in
        List.iteri (fun index line ->
          if index >= scroll && index < scroll + height then c.push ("  " ^ line)) lines;
        if budget > 0 then
          Option.iter c.position
            (Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count))
  end else begin
  Masc_tui_types.clear_progress_clock state ~slot:"queue-detail";
  let list_started_at =
    Masc_tui_types.progress_clock_option state ~slot:"queue-list" ~now
      (Option.map (fun (_, sig_key, _, _, _, _) -> sig_key) spec)
  in
  let progress_sheet = queue_panel_sheet_of_spec ?started_at:list_started_at spec in
  let badge =
    match progress_sheet with
    | None -> ""
    | Some sheet ->
        "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
  in
  let placement = queue_panel_layout ?progress_sheet state panel in
  let context_caption =
    let partial = Option.is_some state.msg_loaded_error || state.msg_loaded_dropped > 0
        || Option.is_some state.msg_memory_error || state.msg_memory_dropped > 0
        || Option.is_some state.msg_older_error in
    if partial then say "일부 대화만 로드됨 · Esc:전체 대화" "Partial conversation · Esc:full chat"
    else if state.msg_older_loading || Option.is_some state.msg_history_inflight then
      progress_inline ~ko ~now (say "대화 읽는 중 · Esc:전체 대화" "Reading conversation · Esc:full chat")
    else say "대화 미리보기 · Esc:전체 대화" "Conversation preview · Esc:full chat" in
  let context_lines ~cols ~height =
    Masc_tui_render_chat.queue_context_lines state ~keeper_name:panel.qp_keeper ~cols ~height in
  let sidebar = match placement with
    | Masc_tui_queue_layout.Side {context_cols; queue_cols=_} ->
        Some (context_cols, fun ~rows buf ->
          framed_top buf context_cols;
          framed_line buf context_cols context_caption;
          framed_divider buf context_cols;
          let height = max 0 (rows - 4) in
          let lines = context_lines ~cols:(framed_inner_width context_cols) ~height in
          List.iter (framed_line buf context_cols) lines;
          for _ = List.length lines to height - 1 do framed_empty buf context_cols done;
          framed_bottom buf context_cols)
    | Full | Bottom _ -> None in
  let queue_cols = match placement with
    | Masc_tui_queue_layout.Side {queue_cols; context_cols=_} -> queue_cols
    | Full | Bottom _ -> cols in
  let items = queue_panel_items state panel in
  let status = if not (server_authority_ready state) then
    say "워크스페이스 미확인 · 아래 영수증은 이전 관측입니다"
      "Workspace unconfirmed; any receipt is from the previous observation"
  else match panel.qp_reading, panel.qp_notice with
    | Queue_loading, _ ->
        progress_inline ~ko ~now ?started_at:list_started_at
          (say "읽기 또는 전송 중" "Reading or sending")
    | (Queue_current | Queue_unavailable), Some (Queue_info text | Queue_error text) -> Terminal_text.single_line text
    | Queue_current, None ->
      (match panel.qp_observation with
       | Some {waiting=Ok _; operations=Ok _; _} -> say "대기열 조회됨 · r:새로고침" "Queue read · r refreshes"
       | Some {waiting=Ok _; operations=Error _; _} -> say "목록 조회됨 · 서버 메시지 조회 불가" "Inventory read · server messages unavailable"
       | Some {waiting=Error _; operations=Ok _; _} -> say "서버 메시지 조회됨 · 목록 조회 불가" "Server messages read · inventory unavailable"
       | Some {waiting=Error _; operations=Error _; _} -> say "서버 조회 모두 불가 · r:재시도" "Both server reads unavailable · r retries"
       | None -> say "대기열 관측 불가 · r:재시도" "Queue observation unavailable · r retries")
    | Queue_unavailable, None -> say "스냅샷 조회 불가 · r:재시도" "Snapshot unavailable · r retries" in
  let hints = Masc_tui_keys.footer_hints_queue state panel in
  let frame, clamped = surface_chrome ~overflow:(Self_scrolled owner) ?progress_sheet ~now
    state ~terminal_rows ~cols
    ?sidebar
    ~surface_key:"keeper-queue" ~frame:Chrome_overlay
    ~title:(title ~badge (say " 대기열" " Queue"))
    ~hints
    ~body:(fun ~budget c ->
      let queue_budget =
        match placement with
        | Masc_tui_queue_layout.Bottom {context_rows; queue_rows=_} ->
            let ctx = min context_rows (max 0 (budget - 1)) in
            if ctx >= 2 then begin
              c.push context_caption;
              let lines = context_lines ~cols:(framed_inner_width cols) ~height:(ctx - 1) in
              List.iter c.push lines;
              for _ = List.length lines to ctx - 2 do c.push_empty () done;
              c.push_divider ();
              max 0 (budget - ctx - 1)
            end else budget
        | Full | Side _ -> budget
      in
      let budget = queue_budget in
      if budget > 0 then c.push ("  " ^ status);
      (match panel.qp_receipt with
       | Some (Queue_action_receipt (Queue_info text) | Queue_read_receipt text) when budget > 1 ->
         c.push ("  " ^ Terminal_text.single_line text)
       | Some (Queue_action_receipt (Queue_error text)) when budget > 1 ->
         c.push ("  " ^ Theme.warn () ^ Terminal_text.single_line text ^ Ansi.reset)
       | Some (Queue_action_receipt (Queue_info _ | Queue_error _) | Queue_read_receipt _)
       | None -> ());
      let note_row = 1 + (match panel.qp_receipt with Some _ -> 1 | None -> 0) in
      (match queue_panel_selection_note ~items panel with
       | Some note when budget > note_row -> c.push ("  " ^ note)
       | Some _ | None -> ());
      let height = queue_panel_list_height ~items ~budget panel in
      let scroll = queue_panel_scroll ~items ~height panel in
      let selected_index = queue_panel_selected_index ~items panel in
      List.iteri (fun index (item : Masc_tui_queue_inspection.item) ->
        if index >= scroll && index < scroll + height then begin
          let selected = selected_index = Some index in
          let marker = if selected then "› " else "  " in
          let text = match String.index_opt item.text '\n' with
            | None -> item.text
            | Some index -> String.sub item.text 0 index in
          let text = Terminal_text.single_line text in
          let text = if Message_layout.display_width (String.trim text) = 0 then
              Option.fold ~none:text ~some:(fun id ->
                Terminal_text.single_line (queue_panel_item_identity ~ko:(state.ui_language = Lang_ko) id)) item.id
            else text in
          let row =
            if selected then marker ^ Masc_tui_theme.strip_sgr text
            else marker ^ text
          in
          let row = if selected && queue_selection_visible
              ~inner_width:(framed_inner_width queue_cols) ~marker ~text then
              match queue_selection_for_item state panel item with
              | Some authority -> pressable (Press_queue_selected authority) row
              | None -> row
            else row in
          if selected then c.push_selected row else c.push row
        end) items;
      if items <> [] then
        c.position
          (Masc_tui_value.Position.row ~selected:selected_index
             ~total:(List.length items))) in
  (* Shared chrome has three leading rows and two trailing rows. Its body
     copies as separate documents, even though the terminal writes one row. *)
  frame_panes := Masc_tui_queue_layout.panes placement ~cols
      ~first_row:(strip_rows + surface_chrome_rows - 1)
      ~body_rows:(surface_chrome_budget ?progress_sheet state ~terminal_rows);
  frame, clamped
  end

(* The answering overlay, through the overlay contract. Drawn by hand, a short
   list closed the box right under the preview panel, so the footer stood on
   row 10 of a 26-row terminal. The list now fills its height, the preview
   panel sits on the frame's last rows, and the frame fills nothing because
   nothing is left. Its title was "Live Keeper Turns & Answering" with a half
   circle glyph; the key table names the overlay "answering". *)
let render_answering (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = answering_lines state in
  let paint (line : Masc_tui_answering.line) =
    let tone_prefix =
      match line.Masc_tui_answering.tone with
      | Masc_tui_answering.Heading -> Ansi.bold
      | Masc_tui_answering.Running -> (Theme.info ())
      | Masc_tui_answering.Done -> Theme.ok ()
      | Masc_tui_answering.Unknown -> Theme.warn ()
      | Masc_tui_answering.Quiet -> Ansi.dim
    in
    "  " ^ tone_prefix ^ line.Masc_tui_answering.text ^ Ansi.reset
  in
  let preview_lines =
    let cursor_preview =
      match answering_selected_target state ~lines with
      | Some keeper_name ->
          List.find_map
            (fun (row : Tui_decode.keeper_turn_row) ->
              if String.equal row.ktr_keeper_name keeper_name then
                match row.ktr_state with
                | Tui_decode.Keeper_turn_running { preview = Some preview; _ }
                  ->
                    Some (keeper_name, preview)
                | Tui_decode.Keeper_turn_running { preview = None; _ }
                | Tui_decode.Keeper_turn_idle
                | Tui_decode.Keeper_turn_unavailable _ -> None
              else None)
            state.keeper_turns
      | None -> None
    in
    match cursor_preview with
    | Some (keeper_name, preview) ->
        let doing = Terminal_text.single_line preview.Tui_decode.ktp_status_text in
        let tail =
          match
            Terminal_text.single_line preview.Tui_decode.ktp_text_tail
          with
          | "" -> ui_text state ~ko:"(아직 보고된 글 없음)" ~en:"(no text reported yet)"
          | tail -> tail
        in
        let preview_width = framed_inner_width cols in
        let name_width = min (Masc_tui_message_layout.display_width (Terminal_text.single_line keeper_name))
          (max 0 ((preview_width - 2) / 2)) in
        [ Ansi.bold ^ fit_width (Terminal_text.single_line keeper_name) name_width
          ^ Ansi.reset ^ "  " ^ (Theme.accent ())
          ^ fit_width doing (max 0 (preview_width - name_width - 2))
          ^ Ansi.reset
        ; Ansi.dim ^ tail ^ Ansi.reset
        ]
    | None ->
        [ Ansi.dim
          ^ ui_text state ~ko:"실시간 미리보기 \xc2\xb7 이 줄에는 없음"
              ~en:"live preview \xc2\xb7 none for this row"
          ^ Ansi.reset
        ; ""
        ]
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"answering"
    ~frame:Chrome_overlay
    (* Enter and Esc are in the footer row below this overlay. *)
    ~title:(screen_title (ui_text state ~ko:" 응답 중" ~en:" Answering"))
    ~hints:(Masc_tui_keys.footer_hints_answering ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      let content_height = max 1 (budget - answering_preview_rows) in
      let scroll =
        Masc_tui_scroll.normalize
          ~count:(List.length lines)
          ~height:content_height
          state.answering_scroll
      in
      let drawn = ref 0 in
      List.iteri
        (fun i line ->
          if i >= scroll && i < scroll + content_height then begin
            incr drawn;
            let is_selected =
              i = state.answering_cursor
              && Option.is_some line.Masc_tui_answering.target
            in
            if is_selected then
              c.push_selected ("\xe2\x80\xba " ^ Masc_tui_theme.strip_sgr line.Masc_tui_answering.text)
            else
              c.push (paint line)
          end)
        lines;
      for _ = !drawn + 1 to content_height do
        c.push_empty ()
      done;
      (* The fixed preview panel: what the cursor's keeper is doing right now,
         from the turns poll's live glance. Drawn empty rather than omitted so
         the list above never reflows with the cursor. *)
      if lines <> [] then
        c.position
          (Masc_tui_value.Position.row ~selected:(Some state.answering_cursor)
             ~total:(List.length lines));
      c.push_divider ();
      List.iter c.push preview_lines)
;;

(* The agenda, through the overlay contract. Its sections are usually a few
   rows, and drawn by hand the box closed under them: the footer stood on row
   11 of a 26-row terminal with the composer alone at the bottom. The title is
   the name the [;] key carries in the footer. *)
let render_agenda (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = agenda_lines state in
  let selected = Agenda.selected_index lines ~selected:state.agenda_selected in
  let paint (line : Agenda.line) =
    match line.Agenda.tone with
    | Agenda.Heading -> Ansi.bold ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Wake -> (Theme.recede ()) ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Question -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Quiet -> Ansi.dim ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Failed -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
  in
  (* Every key of the panel moves -- j/k, the page keys, g/G, Enter and Esc --
     so zone 5 names none of them (RFC tui-one-screen-grammar section 2) and
     holds the help door alone. The panel owns the keys, so the door is not
     the default ([help_key_answers] says no under a modal); [?] here opens
     the sheet on the agenda's own section. *)
  surface_chrome ~overflow:Paged_by_cursor ~help_door:true state ~terminal_rows ~cols
    ~surface_key:"agenda"
    ~frame:Chrome_overlay
    ~title:(screen_title (ui_text state ~ko:" 일정·요청" ~en:" Agenda"))
    ~hints:""
    (* [agenda_viewport] rather than the budget it is derived from: the
       keypress bounds the cursor against that pair. *)
    ~body:(fun ~budget:_ c ->
      let count, height = agenda_viewport state in
      (* Selection follows refreshes while navigating targets. Reading pages
         owns its window, so repainting cannot pull it away from schedules. *)
      let scroll = agenda_scroll_position state in
      List.iteri
        (fun index line ->
          if index >= scroll && index < scroll + height then
            if selected = Some index then
              let plain = Masc_tui_theme.strip_sgr line.Agenda.text in
              let marked =
                if String.length plain >= 2 && plain.[0] = ' ' && plain.[1] = ' ' then
                  "\xe2\x80\xba " ^ String.sub plain 2 (String.length plain - 2)
                else "\xe2\x80\xba " ^ plain
              in
              c.push_selected marked
            else
              c.push (paint line))
        lines;
      (* What falls off this panel is not more of the same: measured at 24
         rows and 100 columns, the panel drew sixteen of its twenty coming
         rows and neither of the two sections under them, and nothing said
         "Waiting on you" and "Stuck on you" were there. *)
      Option.iter c.position
        (Masc_tui_value.Position.window ~first:scroll ~shown:height ~total:count))
;;

(* The size line writes the decision's own numbers: the terminal's size now
   and the rows it needs (RFC tui-one-screen-grammar §2). The typed form
   choice drops words before numbers on a narrow terminal. *)
let terminal_too_small_quit state =
  Masc_tui_too_small_hint.quit ~ko:(state.ui_language = Lang_ko)

let terminal_too_small_hint state ~cols ~have ~need_rows =
  let ko = state.ui_language = Lang_ko in
  Masc_tui_too_small_hint.text ~ko ~have ~need_rows
    (Masc_tui_too_small_hint.choose ~ko ~cols ~have ~need_rows)
;;

let render_terminal_too_small state (reason : Render_schedule.Viewport.too_small)
    ~recovery_notice ~rows ~cols =
  (* A short terminal leads with its size. A notice that took the frame is
     itself what the frame says, so it gets no size line. *)
  let size_line = match reason with
    | Render_schedule.Viewport.Rows_short { have; need_rows } ->
        Some (terminal_too_small_hint state ~cols ~have ~need_rows)
    | Render_schedule.Viewport.Notice_needs_full_frame -> None in
  let now = Unix.gettimeofday () in
  let rejection = Masc_tui_action_notice.rejection state.last_action
      ~now ~window:Masc_tui_types.last_action_window_s in
  let csi_text = match recovery_notice with
    | Some text -> Some (if Message_layout.display_width text <= cols then text
        else Masc_tui_action_notice.csi_recovery_text)
    | None when Masc_tui_action_notice.csi_active state.last_action ->
        Some Masc_tui_action_notice.csi_recovery_text
    | None -> None in
  let csi_rows = Option.bind csi_text (fun text ->
    let parts = Message_layout.split_styled_cells ~max_cells:cols text in
    if List.length parts <= rows then Some parts else None) in
  let notice_rows =
    if Option.is_some recovery_notice || Masc_tui_action_notice.csi_active state.last_action then None
    else
      let parts = match rejection, current_quit_confirmation state ~now with
        | Some notice, (Some _ | None) ->
            let text = Masc_tui_action_notice.rejection_text notice in
            if Message_layout.display_width text <= cols then [Press_input_rejection notice, text]
            else rejection_fragments ~cols notice
        | None, Some confirmation ->
            let text = fst (Masc_tui_action_notice.quit_ordinary confirmation) in
            if Message_layout.display_width text <= cols then [Press_quit_confirmation confirmation, text]
            else quit_fragments ~cols confirmation
        | None, None -> [] in
      if parts <> [] && List.length parts <= rows then Some parts else None in
  let visible_rows = match csi_rows, notice_rows with
    | Some parts, (Some _ | None) -> Some parts
    | None, Some parts -> Some (List.map (fun (target, text) -> pressable target text) parts)
    | None, None -> None in
  match visible_rows with
  | Some parts ->
      let parts = match size_line with
        | Some line when List.length parts < rows -> line :: parts
        | Some _ | None -> parts in
      let buf = Buffer.create 64 in
      List.iter (fun text ->
        Buffer.add_string buf (fit_width text cols);
        Buffer.add_char buf '\n') parts;
      finish_terminal_too_small_frame ~cursor:Frame_presenter.Hidden ~rows ~cols buf
  | None ->
  let recovery_notice = Option.map (fun text ->
      let short = Masc_tui_action_notice.csi_recovery_text in
      if Message_layout.display_width text > cols
         && Message_layout.display_width short <= cols then short else text)
      recovery_notice in
  let now = Unix.gettimeofday () in
  let window = Masc_tui_types.last_action_window_s in
  let ordinary =
    Masc_tui_action_notice.ordinary_visible state.last_action
      ~now ~window in
  let ordinary_text = Option.bind ordinary (fun ((text, _) as ordinary) ->
      let text = Terminal_text.single_line text in
      match state.quit_armed with
      | Some arm when ordinary == Masc_tui_action_notice.quit_ordinary arm.qa_confirmation ->
          (match current_quit_confirmation state ~now with
           | Some confirmation ->
               Some (if Message_layout.display_width text <= cols then
                   pressable (Press_quit_confirmation confirmation) text
                 else ui_text state ~ko:"종료 확인을 위해 창을 넓혀 주세요" ~en:"Resize to confirm quit")
           | None when Masc_tui_action_notice.csi_active state.last_action
                       || Option.is_some (Masc_tui_action_notice.rejection state.last_action
                            ~now ~window) -> None
           | None ->
               Some (ui_text state ~ko:"종료 상태가 변경됨 · 다시 시도하세요" ~en:"Quit changed; retry"))
      | Some _ | None -> Some text) in
  let rejection =
    match recovery_notice, ordinary_text with
    | Some _, _ | None, Some _ -> None
    | None, None ->
        (match Masc_tui_action_notice.rejection state.last_action ~now ~window with
         | Some notice when
             Message_layout.display_width (Masc_tui_action_notice.rejection_text notice) <= cols ->
             Some notice
         | Some _ | None -> None) in
  let notice = match recovery_notice, rejection with
    | Some text, _ -> Some (text, None)
    | None, Some notice -> Some (Masc_tui_action_notice.rejection_text notice, Some notice)
    | None, None -> Option.map (fun text -> text, None) ordinary_text in
  let buf = Buffer.create 64 in
  let rendered (text, marked) =
    match marked with
    | Some notice -> pressable (Press_input_rejection notice) text
    | None -> text in
  (* A compact frame normally spends only two rows. A third lets an existing
     confirmation stay visible while the recovery notice gets its own row. *)
  let extra_recovery =
    if rows < 3 then None
    else match recovery_notice with
      | Some _ ->
          let text = Masc_tui_action_notice.csi_recovery_text in
          if Message_layout.display_width text <= cols then Some text else None
      | None when Masc_tui_action_notice.csi_active state.last_action -> None
      | None ->
          (match Masc_tui_action_notice.rejection state.last_action ~now ~window with
           | Some notice when
               Message_layout.display_width (Masc_tui_action_notice.rejection_text notice) <= cols ->
               Some (pressable (Press_input_rejection notice)
                       (Masc_tui_action_notice.rejection_text notice))
           | Some _ | None -> None) in
  let extra_ordinary = match ordinary_text, recovery_notice with
    | Some _, Some _ when Masc_tui_action_notice.ordinary_is_csi state.last_action -> None
    | Some text, (Some _ | None) -> Some text
    | None, (Some _ | None) -> None in
  let extra_rejection = match extra_recovery, recovery_notice with
    | Some _, Some _ when rows >= 3 + (if Option.is_some extra_ordinary then 1 else 0) ->
        (match Masc_tui_action_notice.rejection state.last_action ~now ~window with
         | Some notice when
             Message_layout.display_width (Masc_tui_action_notice.rejection_text notice) <= cols ->
             Some (pressable (Press_input_rejection notice)
                     (Masc_tui_action_notice.rejection_text notice))
         | Some _ | None -> None)
    | (Some _ | None), (Some _ | None) -> None in
  let add_row text =
    Buffer.add_string buf (fit_width text cols);
    Buffer.add_char buf '\n' in
  (match extra_recovery with
   | Some text ->
       Option.iter add_row size_line;
       Option.iter (fun ordinary -> add_row (rendered (ordinary, None))) extra_ordinary;
       add_row text;
       Option.iter add_row extra_rejection
   | None ->
       (match size_line, notice with
        | Some line, Some notice ->
            if rows <= 1 then add_row (rendered notice)
            else begin add_row line; add_row (rendered notice) end
        | Some line, None -> add_row line
        | None, Some notice -> add_row (rendered notice)
        (* The notice that took the frame does not fit even the whole of it.
           Saying the size would be false, so only the way out stays. *)
        | None, None -> add_row (terminal_too_small_quit state)));
  finish_terminal_too_small_frame ~cursor:Frame_presenter.Hidden ~rows ~cols
    buf

(** Keep every high-chrome surface out of a viewport that cannot contain the
    largest declared fixed-row budget. Main ignores hidden surface input, and
    growing the terminal restores the unchanged selected surface. *)
let render_account_login state view =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let base_title = screen_title (ui_text state ~ko:" 계정 로그인" ~en:" Account Login") in
  let title =
    match Masc_tui_account_login.progress_badge ~ko ~now view with
    | None -> base_title
    | Some badge -> base_title ^ "  " ^ Theme.info () ^ badge ^ Ansi.reset
  in
  let progress_sheet =
    Option.map
      (fun (info : Masc_tui_account_login.progress_info) ->
        { ps_title = info.title
        ; ps_detail = info.detail
        ; ps_started_at = info.started_at
        ; ps_meter =
            Option.map
              (fun (pm_done, pm_total, pm_failed) -> { pm_done; pm_total; pm_failed })
              info.meter
        ; ps_action_hint = info.action_hint
        ; ps_blocking = info.blocking
        })
      (Masc_tui_account_login.progress_info ~ko view)
  in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay ?progress_sheet ~now
    state ~terminal_rows ~cols
    ~surface_key:"account-login"
    ~title
    ~hints:(Masc_tui_account_login.hints ~ko view)
    ~body:(fun ~budget c ->
      let lines, position =
        Masc_tui_account_login.visible_lines_with_selection ~ko ~now ~height:budget ~width:(framed_inner_width cols) view in
      Option.iter c.position position;
      let width = framed_inner_width cols in
      List.iter
        (function
          | selected, Masc_tui_account_login.Text text ->
              let clean = Masc.Tui_terminal_text.sanitize_terminal_text text in
              if selected then
                c.push_selected (fit_width (Masc_tui_theme.strip_sgr clean) width)
              else c.push (fit_width clean width)
          | selected, Masc_tui_account_login.Progress text ->
              let clean = Masc.Tui_terminal_text.sanitize_terminal_text text in
              if selected then
                c.push_selected (fit_width (Masc_tui_theme.strip_sgr clean) width)
              else c.push (Theme.info () ^ fit_width clean width ^ Ansi.reset)
          | _, Masc_tui_account_login.Terminal line ->
              let rendered =
                Masc_tui_sgr_text.render
                  ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text line
              in
              c.push (fit_width rendered width))
        lines)

(* The address answers as the account server of a multi-account installation
   ([Masc_tui_types.Account_server]), which serves none of the screens. This
   one says what the address is for, where people and Admins go, and where
   the operator screens are. A browser opens the same address: its page at /
   signs a person in. Each value wraps under itself rather than being cut,
   since the words are what the screen is for. *)
let render_account_server state ~version =
  let terminal_rows, cols = get_terminal_size () in
  let say ko_text en_text = ui_text state ~ko:ko_text ~en:en_text in
  let address =
    Masc_tui_http.url_of ~host:Masc_network_defaults.masc_http_loopback_peer
      ~port:state.port ~path:""
  in
  let rows =
    [ say "주소" "Address", address
    (* The server's own string: one printable row, whatever it carries. *)
    ; say "버전" "Version", Masc.Tui_terminal_text.sanitize_terminal_text version
    ; say "사람" "People",
      say "브라우저에서 로그인 후 개인 구독·키퍼 사용"
        "Open the address in a browser, sign in, and use your own subscriptions and Keepers."
    ; "Admin",
      say "같은 주소에서 로그인 후 초대 링크·허용 계정 관리"
        "Sign in there too, then manage invitation links and allowed accounts."
    ; say "운영 화면" "Operator screens",
      say "이 주소에서 미지원 · 단일 사용자 masc 서버는 --port로 masc-tui 재실행"
        "Not served at this address. For a single-user masc server, open masc-tui again on its port (--port)."
    ]
  in
  let label_cells =
    List.fold_left (fun widest (label, _) -> max widest (Message_layout.display_width label)) 0 rows
  in
  (* [?] opens nothing here: the screen takes every key. *)
  surface_chrome ~overflow:Fits ~help_door:false ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"account-server"
    ~title:(screen_title (" " ^ say "다계정 설치" "Multi-account installation"))
    ~hints:(say "r:다시 확인  q:종료" "r:check again  q:quit")
    ~body:(fun ~budget:_ c ->
      let width = framed_inner_width cols in
      let wrapped ~indent text =
        Message_layout.split_styled_cells ~max_cells:(max 1 (width - indent)) text
      in
      List.iter (fun line -> c.push (fit_width (" " ^ line) width))
        (wrapped ~indent:1
           (say "다계정 설치의 계정 서버 주소 · 운영 화면(키퍼·작업·저장소)은 여기 없음"
              "This address is the account server of a multi-account installation. The operator screens (Keepers, Tasks, Repositories) are not served here."));
      c.push_empty ();
      let value_indent = 1 + label_cells + 2 in
      List.iter (fun (label, value) ->
        match wrapped ~indent:value_indent value with
        | [] -> c.push (fit_width (" " ^ label) width)
        | first :: rest ->
          c.push (fit_width (" " ^ fit_width label label_cells ^ "  " ^ first) width);
          List.iter (fun line -> c.push (fit_width (String.make value_indent ' ' ^ line) width)) rest)
        rows)


let render_collab state view =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let status = Masc_tui_collab.progress_status view in
  let signature =
    match status with
    | `Idle -> None
    | `Pending_write -> Some "write"
    | `Write_access_pending _ -> Some "write-access-pending"
    | `Loading -> Some "loading"
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"collab" ~now signature
  in
  let progress_sheet =
    match status with
    | `Idle -> None
    | `Pending_write ->
        Some
          { ps_title = ui_text state ~ko:"협업 상태 변경 중" ~en:"Updating collaboration"
          ; ps_detail =
              Some
                (ui_text state ~ko:"요청한 협업 변경을 서버에 반영하고 있습니다"
                   ~en:"Applying the requested collaboration change")
          ; ps_started_at = started_at
          ; ps_meter = None
          ; ps_action_hint = Some (ui_text state ~ko:"Esc:닫기" ~en:"Esc:close")
          ; ps_blocking = true
          }
    | `Write_access_pending detail ->
        Some
          { ps_title = ui_text state ~ko:"초대 변경 대기 중" ~en:"Invite change pending"
          ; ps_detail = Some (Terminal_text.single_line detail)
          ; ps_started_at = started_at
          ; ps_meter = None
          ; ps_action_hint = Some (ui_text state ~ko:"Esc:닫기" ~en:"Esc:close")
          ; ps_blocking = true
          }
    | `Loading ->
        Some
          { ps_title = ui_text state ~ko:"협업 현황 읽는 중" ~en:"Loading collaboration"
          ; ps_detail =
              Some
                (ui_text state ~ko:"협업 세션과 쓰기 권한 상태를 조회하고 있습니다"
                   ~en:"Reading collaboration sessions and write access")
          ; ps_started_at = started_at
          ; ps_meter = None
          ; ps_action_hint = Some (ui_text state ~ko:"Esc:닫기" ~en:"Esc:close")
          ; ps_blocking = false
          }
  in
  let title_badge =
    match progress_sheet with
    | None -> ""
    | Some sheet ->
        "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
  in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ?progress_sheet ~now
    ~surface_key:"collab"
    ~title:(screen_title (ui_text state ~ko:" 협업" ~en:" Collab") ^ title_badge)
    ~hints:(Masc_tui_collab.hints ~ko view)
    ~body:(fun ~budget c ->
      Option.iter c.position (Masc_tui_collab.position view);
      let width = framed_inner_width cols in
      Masc_tui_collab.lines_with_selection ~ko ~height:budget ~width view
      |> List.iter (fun (is_selected, line) ->
           if is_selected then
             c.push_selected (fit_width (Masc_tui_theme.strip_sgr line) width)
           else c.push (fit_width line width)))

let render_lane_addons state (view : Masc_tui_lane_addons.t) =
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let say ko_text en_text = ui_text state ~ko:ko_text ~en:en_text in
  let detaching_instance =
    match view.screen, view.snapshot with
    | Masc_tui_lane_addons.Detail (id, inc), Some snap ->
        List.find_opt
          (fun (inst : Masc_tui_lane_addons.instance) ->
            String.equal inst.id id && String.equal inst.incarnation inc
            && inst.phase = Masc_tui_lane_addons.Row.Detaching)
          snap.instances
    | Masc_tui_lane_addons.Detail _, None -> None
    | Masc_tui_lane_addons.Overview, (Some _ | None) ->
        (match Masc_tui_lane_addons.selected_instance view with
         | Some inst when inst.phase = Masc_tui_lane_addons.Row.Detaching -> Some inst
         | Some _ | None -> None)
  in
  let gen = string_of_int view.generation in
  let active_spec =
    match Option.bind view.installer Masc_tui_lane_installer.pending_read with
    | Some (Masc_tui_lane_installer.Read_preview path) ->
        Some
          ( "preview:" ^ gen ^ ":" ^ path
          , say "패키지 매니페스트 검사 중" "Inspecting package manifest"
          , Some (Terminal_text.single_line path)
          , Some (say "Esc:취소" "Esc:cancel")
          , true )
    | Some (Masc_tui_lane_installer.Read_catalog dir) ->
        Some
          ( "catalog:" ^ gen ^ ":" ^ Option.value ~default:"" dir
          , say "패키지 목록 읽는 중" "Reading package catalog"
          , Option.map Terminal_text.single_line dir
          , Some (say "Esc:취소" "Esc:cancel")
          , false )
    | None ->
        if view.loading then
          if Option.exists Masc_tui_lane_subscriptions.is_confirming_save view.subscription_panel then
            Some
              ( "sub-save:" ^ gen
              , say "구독 설정 저장 중" "Saving subscriptions"
              , Some (say "선택한 키퍼 구독 구성을 저장하고 있습니다"
                        "Saving Keeper subscription configuration")
              , Some (say "Esc:뒤로" "Esc:back")
              , true )
          else if Option.is_some view.subscription_panel then
            Some
              ( "sub-read:" ^ gen
              , say "구독 설정 읽는 중" "Loading subscriptions"
              , Some (say "구독 구성과 읽기 위치를 조회하고 있습니다"
                        "Reading subscriptions and reader positions")
              , Some (say "Esc:뒤로" "Esc:back")
              , false )
          else
            Some
              ( "loading:" ^ gen
              , say "플러그인 조회·처리 중" "Updating plugins"
              , Some (say "플러그인 인스턴스와 선언 상태를 갱신하고 있습니다"
                        "Refreshing plugin instances and declarations")
              , Some (say "Esc:닫기" "Esc:close")
              , false )
        else
          match view.action_receipt with
          | Some ({ Masc_tui_lane_addons.Action.state = Queued; request_id; _ }) ->
              Some
                ( "action-queued:" ^ request_id
                , say "플러그인 동작 대기 중" "Plugin action queued"
                , Some (Terminal_text.single_line request_id)
                , Some (say "Esc:닫기" "Esc:close")
                , true )
          | Some ({ Masc_tui_lane_addons.Action.state = Running; request_id; _ }) ->
              Some
                ( "action-running:" ^ request_id
                , say "플러그인 동작 실행 중" "Running plugin action"
                , Some (Terminal_text.single_line request_id)
                , Some (say "Esc:닫기" "Esc:close")
                , true )
          | Some ({ Masc_tui_lane_addons.Action.state =
                      (Confirmed | Failed_before_effect | Outcome_unknown); _ })
          | None ->
              if Masc_tui_lane_addons.Application.pending view.application_reading then
                Some
                  ( "app-read:" ^ gen
                  , say "선언 적용 상태 확인 중" "Checking declaration state"
                  , Some (say "저장된 TOML 선언이 워커에 반영되었는지 확인하고 있습니다"
                            "Checking whether saved TOML declarations applied")
                  , Some (say "Esc:닫기" "Esc:close")
                  , false )
              else
                match detaching_instance with
                | Some inst ->
                    Some
                      ( "detaching:" ^ inst.id ^ ":" ^ inst.incarnation
                      , say "워커 분리 정리 중" "Detaching worker"
                      , Some (Terminal_text.single_line inst.title)
                      , Some (say "Esc:닫기" "Esc:close")
                      , false )
                | None -> None
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"lane-addons" ~now
      (Option.map (fun (sig_key, _, _, _, _) -> sig_key) active_spec)
  in
  let progress_sheet =
    Option.map
      (fun (_, ps_title, ps_detail, ps_action_hint, ps_blocking) ->
        { ps_title
        ; ps_detail
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint
        ; ps_blocking
        })
      active_spec
  in
  let title_badge =
    match progress_sheet with
    | None -> ""
    | Some sheet ->
        "  " ^ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
  in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ?progress_sheet ~now ~surface_key:"lanes"
    ~title:(screen_title (say " 플러그인" " Plugins") ^ title_badge)
    ~hints:(if Option.is_some view.evidence_prompt then
        say "j/k:선택  Enter:보존  Esc:뒤로" "j/k:choose  Enter:preserve  Esc:back"
      else if Option.is_some view.subscription_panel && view.loading then
        say "구독 요청 진행 중  J/K:스크롤  Esc:뒤로"
          "Subscription request in progress  J/K:scroll  Esc:back"
      else if Option.is_some view.subscription_panel then
        say "j/k:선택  Enter:선택/저장  a:추가  d:제거  J/K:스크롤  r:새로고침  Esc:뒤로"
          "j/k:select  Enter:choose/save  a:add  d:remove  J/K:scroll  r:refresh  Esc:back"
      else if Option.is_some view.installer then
        Option.fold ~none:""
          ~some:(Masc_tui_lane_installer.hints ~ko:(state.ui_language = Lang_ko))
          view.installer
      else if Option.exists Masc_tui_lane_records.text_entry_open view.records
        then say "Tab:필드  ←/→:선택  Ctrl-S:검토  PgUp/PgDn:스크롤  Esc:취소"
          "Tab:field  Left/Right:choice  Ctrl-S:review  PageUp/Down:scroll  Esc:cancel"
      else if Option.is_some view.records then
        say "j/k:선택  a:추가  d:제거  PgUp/PgDn:스크롤  Esc:뒤로 · s:저장"
          "j/k:select  a:add  d:remove  PageUp/Down:scroll  Esc:back; then s saves"
      else if Option.exists (fun (menu : Masc_tui_lane_addons.action_menu) -> Option.is_some menu.form) view.action_menu
        then say "Tab:필드  ←/→:선택  Ctrl-E:항목  Ctrl-U:해제  Ctrl-S:검토  Esc:취소"
          "Tab:field  Left/Right:choice  Ctrl-E:items  Ctrl-U:unset  Ctrl-S:review  Esc:cancel"
      else if Option.is_some view.action_menu then
        say "j/k:동작 선택  Enter:1회 실행  J/K:상세 스크롤  Esc:취소"
          "j/k:choose action  Enter:run once  J/K:scroll details  Esc:cancel"
      else String.concat "  " (Masc_tui_lane_addons.overview_hints view))
    ~body:(fun ~budget c ->
      let inner_width = framed_inner_width cols in
      let lines =
        Masc_tui_lane_addons.lines_with_selection ~ko:(state.ui_language = Lang_ko)
          ~height:budget ~width:inner_width view
      in
      let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height:budget view.scroll in
      Option.iter c.position
        (Masc_tui_value.Position.window ~first:scroll ~shown:budget ~total:(List.length lines));
      lines
      |> List.filteri (fun index _ -> index >= scroll && index < scroll + budget)
      |> List.iter (fun (selected, line) ->
           if selected then c.push_selected (Masc_tui_theme.strip_sgr line)
           else c.push line))


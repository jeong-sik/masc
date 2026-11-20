(** Connectors table, Browser Lane, and Browser History screens. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Browser_lane_layout = Masc_tui_browser_lane_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection

(* Where the gate can deliver.

   Configured and reachable are separate columns because they call for
   different actions: one is a setup gap, the other is something that was
   working and is not. A connector that is set up but unreachable is the row
   an operator acts on. *)
let browser_lane_source_hint view =
  match Browser_lane_view.selected_scene_target view with
  | None -> None
  | Some node ->
      (match node.Masc.Browser_scene.source_context with
       | Masc.Browser_source_context.Unmapped -> None
       | (Located _ | Invalid _) as source ->
           Some (Masc.Browser_source_context.label source))

(* Project a backend that could not start, then the selected connection's
   current metadata and activity, together, so drawing and available-room
   calculations consume the same ephemeral rows. *)
let browser_lane_connection_rows ?(ko = false) ~now (view : Browser_lane_view.t) =
  let say korean english = if ko then korean else english in
  let selected = match view.selected_client with
    | None -> []
    | Some (client : Browser_lane_view.client) ->
        let metadata = Option.to_list (Option.map (fun row -> Theme.recede (), "  " ^ row)
          (Browser_lane_view.space_observation_row ~now client)) in
        let pending = List.map (fun (work : Browser_lane.interaction_activity) ->
          let phase = match work.phase with
            | Browser_lane.Interaction_queued -> say "대기 중" "queued"
            | Browser_lane.Interaction_running -> say "실행 중" "working" in
          Theme.info (), say "  에이전트 " "  Agent "
            ^ Terminal_text.single_line (Option.value work.actor ~default:"MASC") ^ " · " ^ phase
            ^ " · " ^ Terminal_text.single_line work.action
            ^ (match work.tab_id with
               | Some id -> say " · 탭 " " · tab " ^ string_of_int id
               | None -> "")
            ^ say " (마지막 연결 조회 기준)" " (at last connection read)") client.interactions in
        let settled = List.map (fun (settled : Browser_lane.settled_activity) ->
          let work=settled.work in
          let outcome,style=match settled.outcome with
            | Browser_lane.Activity_returned -> say "응답 완료" "returned", Theme.recede ()
            | Activity_refused -> say "미실행" "not performed", Theme.warn ()
            | Activity_partial -> say "일부 실행" "partly performed", Theme.warn ()
            | Activity_unknown -> say "결과 알 수 없음" "outcome unknown", Theme.warn () in
          style, say "  최근 · " "  Last · "
            ^ Terminal_text.single_line (Option.value work.actor ~default:"MASC")
            ^ " · " ^ Terminal_text.single_line work.action ^ " · " ^ outcome
            ^ (match work.tab_id with
               | Some id -> say " · 탭 " " · tab " ^ string_of_int id
               | None -> ""))
          client.last_activities in
        metadata @ pending @ settled in
  let inventory = match view.inventory_report with
    | Browser_lane_view.Inventory_not_reported -> []
    | Inventory_reported issues -> List.map (fun issue -> Theme.warn (),
        "  " ^ Terminal_text.single_line (Masc.Browser_connection_inventory.issue_message issue)) issues
    | Inventory_report_unreadable detail -> [Theme.warn (),
        say "  연결 목록 보고서 읽기 불가 · " "  Inventory report unreadable · "
        ^ Terminal_text.single_line detail] in
  let unavailable = Option.to_list (Option.map (fun message -> Theme.warn (),
    "  " ^ Terminal_text.single_line message) (Browser_lane_view.unavailable_notice view)) in
  unavailable @ selected @ Option.to_list (Option.map (fun detail -> Theme.warn (),
    say "  활동 새로고침 실패 · " "  Activity refresh failed · "
    ^ Terminal_text.single_line detail) view.activity_error) @ inventory

let browser_lane_fixed_rows ~connection_rows view =
  (* Status, selection, tab, URL and divider are always drawn. Where the text
     stands is on the title row, and its keys are on the footer. A source
     hint contributes a row only when the selected node has one, and a
     refused gesture its rows until the next input. Connection observations,
     pending/settled activities and refresh failures take their projected rows. *)
  5 + (if Option.is_some (browser_lane_source_hint view) then 1 else 0)
  + List.length (Browser_lane_view.unserved_rows view)
  + List.length connection_rows

(* The picker's rows besides its choices and what an empty connection list
   says: the status row, the heading and the divider above the choices, and
   the detail row for the highlighted choice below them, plus the same
   connection rows drawn before the picker. *)
let browser_picker_frame_rows connection_rows = 4 + List.length connection_rows

let browser_lane_visible_rows (state : state) ~terminal_rows view =
  let budget = surface_chrome_budget ~frame:Chrome_screen state ~terminal_rows in
  let connection_rows = browser_lane_connection_rows ~now:(Unix.gettimeofday ()) view in
  max 0 (budget - browser_lane_fixed_rows ~connection_rows view)

let browser_lane_scroll_limit state ~terminal_rows ~cols view =
  let room = browser_lane_visible_rows state ~terminal_rows view in
  max 0 (Browser_lane_layout.count (browser_lane_rows ~cols view) - room)

let browser_lane_selection_scroll state ~terminal_rows ~cols view =
  let rows = browser_lane_rows ~cols view in
  let room = browser_lane_visible_rows state ~terminal_rows view in
  let limit = max 0 (Browser_lane_layout.count rows - room) in
  let scroll = min limit view.Browser_lane_view.scroll in
  match Browser_lane_layout.selected_row rows with
  | None -> scroll
  | Some _ when room = 0 -> scroll
  | Some row when row < scroll -> row
  | Some row when row >= scroll + room -> min limit (row - room + 1)
  | Some _ -> scroll

let browser_step state = ui_text state ~ko:"브라우저" ~en:"browser"

let render_browser_lane (state : state) (view : Browser_lane_view.t) =
  let open Browser_lane_view in
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.gettimeofday () in
  let connection_rows = browser_lane_connection_rows ~ko:(state.ui_language = Lang_ko) ~now view in
  let fixed_rows = browser_lane_fixed_rows ~connection_rows view in
  let picker_frame_rows = browser_picker_frame_rows connection_rows in
  let read_status = Browser_lane_view.read_status view in
  let read_style = match read_status with
    | Read_ok -> Theme.ok ()
    | Read_failed -> Theme.bad ()
    | Reading | Operating -> Theme.info ()
    | Unread | Browser_missing -> Theme.recede ()
  in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let loading_spec =
    match view.load with
    | Loading (req_id, op) ->
        let title, blocking, hint =
          match op with
          | Discover _ ->
              ui_text state ~ko:"브라우저 연결 확인 중" ~en:"Reading browser connections", false, None
          | Read ->
              (match browser_label view with
               | Some browser ->
                   if ko then browser ^ " 읽는 중" else "Reading " ^ browser
               | None -> ui_text state ~ko:"브라우저 읽는 중" ~en:"Reading browser"), false, None
          | Read_refresh ->
              ui_text state ~ko:"브라우저 텍스트 새로고침 중" ~en:"Refreshing browser text", false, None
          | Scene_regions _ ->
              ui_text state ~ko:"페이지 영역 읽는 중" ~en:"Reading page regions", false, None
          | Scene_scroll _ ->
              ui_text state ~ko:"페이지 스크롤 및 화면 새로고침 중" ~en:"Scrolling page and refreshing scene", true, None
          | Scene_focus _ ->
              ui_text state ~ko:"선택한 페이지 영역 읽는 중" ~en:"Reading selected page region", false, None
          | Scene_read _ ->
              ui_text state ~ko:"브라우저 텍스트와 컨트롤 읽는 중" ~en:"Reading browser text and controls", false, None
          | Scene_refresh _ ->
              ui_text state ~ko:"현재 브라우저 화면 새로고침 중" ~en:"Refreshing current browser view", false, None
          | Scene_follow _ ->
              ui_text state ~ko:"관측된 브라우저 링크로 이동 중" ~en:"Following observed browser link", true, None
          | Scene_follow_refresh _ ->
              ui_text state ~ko:"이동한 브라우저 목적지 재확인 중" ~en:"Rechecking followed browser destination", false, None
          | Scene_click _ ->
              ui_text state ~ko:"관측된 브라우저 컨트롤 클릭 중" ~en:"Clicking observed browser control", true, None
          | Viewport_refresh _ | Viewport_observed _ ->
              ui_text state ~ko:"선택한 브라우저 뷰포트 새로고침 중" ~en:"Refreshing selected browser viewport", false, None
          | Viewport_pointer { action = Browser_lane.Scroll_at _; _ } ->
              ui_text state ~ko:"선택한 브라우저 뷰포트 스크롤 중" ~en:"Scrolling selected browser viewport", true, None
          | Viewport_pointer
              { action =
                  ( Browser_lane.Set_viewport _ | Browser_lane.Double_click _
                  | Browser_lane.Double_click_at _ | Browser_lane.Type_text _
                  | Browser_lane.Press_key _ | Browser_lane.Activate_tab
                  | Browser_lane.Click _ | Browser_lane.Fill _
                  | Browser_lane.Select_option _ | Browser_lane.Scroll _
                  | Browser_lane.Hover _ | Browser_lane.Drag_to _
                  | Browser_lane.Hover_at _ | Browser_lane.Click_at _
                  | Browser_lane.Tap_at _ | Browser_lane.Swipe _
                  | Browser_lane.Follow_link _ | Browser_lane.Click_node _
                  | Browser_lane.Fill_node _ | Browser_lane.Click_target _
                  | Browser_lane.Fill_target _ | Browser_lane.Hover_target _
                  | Browser_lane.Double_click_target _ )
              ; _
              } ->
              ui_text state ~ko:"선택한 브라우저 뷰포트 조작 중" ~en:"Interacting with selected browser viewport", true, None
          | Screenshot _ ->
              (match browser_label view with
               | Some browser ->
                   if ko then Printf.sprintf "선택한 %s 탭 캡처 중" browser
                   else "Capturing selected " ^ browser ^ " tab"
               | None -> ui_text state ~ko:"선택한 탭 캡처 중" ~en:"Capturing selected tab"),
              true,
              Some (ui_text state ~ko:"아무 키:미리보기 취소" ~en:"Any key:cancel preview")
        in
        Some (string_of_int req_id, title, blocking, hint)
    | Idle | Failed _ | No_browser -> None
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"browser-lane" ~now
      (Option.map (fun (sig_key, _, _, _) -> sig_key) loading_spec)
  in
  let progress_sheet =
    Option.map
      (fun (_, ps_title, ps_blocking, ps_action_hint) ->
        { ps_title
        ; ps_detail = connection_label view
        ; ps_started_at = started_at
        ; ps_meter = None
        ; ps_action_hint
        ; ps_blocking
        })
      loading_spec
  in
  let title =
    here_row ~cols state ~path:[ browser_step state ]
      ~readings:
        [ selection_label view ^ " · "
          ^ Option.value (connection_label view)
              ~default:(ui_text state ~ko:"브라우저 없음" ~en:"no browser")
        ; (match progress_sheet with
           | Some sheet ->
               progress_inline ~ko ~now ?started_at:sheet.ps_started_at
                 (Browser_lane_view.read_status_label read_status)
           | None -> read_style ^ Browser_lane_view.read_status_label read_status ^ Ansi.reset) ]
      ~position:None
  in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:(match view.client_picker with
      | Some _ -> Masc_tui_keys.footer_hints_browser_picker ~lang:state.ui_language
      | None when Option.is_some view.scene ->
          Masc_tui_keys.footer_hints_browser_scene ~lang:state.ui_language
            ~enter:(Option.bind (selected_scene_target view) scene_target_action)
            ~articles:(Browser_lane_view.scene_has_articles view)
      | None when Option.is_some view.scene_guard ->
          Masc_tui_keys.footer_hints_browser_scene_guard ~lang:state.ui_language
      | None -> Masc_tui_keys.footer_hints_browser_lane_reading ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
      let loading_text s =
        let elapsed =
          match started_at with
          | None -> ""
          | Some at ->
              let d = Masc_tui_value.Ongoing.since ~now at in
              if ko then " · " ^ d ^ " 경과" else " · " ^ d
        in
        under_way ^ " " ^ s ^ elapsed
      in
      let status, style = match view.load with
        | Loading (_, Discover _) ->
            loading_text (ui_text state ~ko:"브라우저 연결 확인 중" ~en:"Reading browser connections"), Theme.info ()
        | Loading (_, Read) ->
            loading_text
              (match browser_label view with
               | Some browser ->
                   if ko then browser ^ " 읽는 중"
                   else "Reading " ^ browser
               | None -> ui_text state ~ko:"읽는 중" ~en:"Reading"), Theme.info ()
        | Loading (_, Read_refresh) ->
            loading_text (ui_text state ~ko:"브라우저 텍스트 새로고침 중" ~en:"Refreshing browser text"), Theme.info ()
        | Loading (_, Scene_regions _) ->
            loading_text (ui_text state ~ko:"페이지 영역 읽는 중" ~en:"Reading page regions"), Theme.info ()
        | Loading (_, Scene_scroll _) ->
            loading_text (ui_text state ~ko:"페이지 스크롤 및 화면 새로고침 중" ~en:"Scrolling page and refreshing scene"), Theme.info ()
        | Loading (_, Scene_focus _) ->
            loading_text (ui_text state ~ko:"선택한 페이지 영역 읽는 중" ~en:"Reading selected page region"), Theme.info ()
        | Loading (_, Scene_read _) ->
            loading_text (ui_text state ~ko:"브라우저 텍스트와 컨트롤 읽는 중" ~en:"Reading browser text and controls"), Theme.info ()
        | Loading (_, Scene_refresh _) ->
            loading_text (ui_text state ~ko:"현재 브라우저 화면 새로고침 중" ~en:"Refreshing current browser view"), Theme.info ()
        | Loading (_, Scene_follow _) ->
            loading_text (ui_text state ~ko:"관측된 브라우저 링크로 이동 중" ~en:"Following observed browser link"), Theme.info ()
        | Loading (_, Scene_follow_refresh _) ->
            loading_text (ui_text state ~ko:"이동한 브라우저 목적지 재확인 중" ~en:"Rechecking followed browser destination"), Theme.info ()
        | Loading (_, Scene_click _) ->
            loading_text (ui_text state ~ko:"관측된 브라우저 컨트롤 클릭 중" ~en:"Clicking observed browser control"), Theme.info ()
        | Loading (_, (Viewport_refresh _ | Viewport_observed _)) ->
            loading_text (ui_text state ~ko:"선택한 브라우저 뷰포트 새로고침 중" ~en:"Refreshing selected browser viewport"), Theme.info ()
        | Loading (_, Viewport_pointer {action=Browser_lane.Scroll_at _;_}) ->
            loading_text (ui_text state ~ko:"선택한 브라우저 뷰포트 스크롤 중" ~en:"Scrolling selected browser viewport"), Theme.info ()
        | Loading
            ( _
            , Viewport_pointer
                { action =
                    ( Browser_lane.Set_viewport _ | Browser_lane.Double_click _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
                    | Browser_lane.Activate_tab | Browser_lane.Click _
                    | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Scroll _
                    | Browser_lane.Hover _ | Browser_lane.Drag_to _
                    | Browser_lane.Hover_at _ | Browser_lane.Click_at _
                    | Browser_lane.Tap_at _ | Browser_lane.Swipe _
                    | Browser_lane.Follow_link _
                    | Browser_lane.Click_node _ | Browser_lane.Fill_node _
                    | Browser_lane.Click_target _ | Browser_lane.Fill_target _
                    | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _ )
                ; _
                } ) ->
            loading_text (ui_text state ~ko:"선택한 브라우저 뷰포트 조작 중" ~en:"Interacting with selected browser viewport"), Theme.info ()
        | Loading (_, Screenshot _) ->
            loading_text
              (match browser_label view with
               | Some browser ->
                   if ko then
                     Printf.sprintf "선택한 %s 탭 캡처 중 (아무 키나 누르면 미리보기 취소)" browser
                   else
                     "Capturing selected " ^ browser ^ " tab (any key cancels preview)"
               | None ->
                   ui_text state ~ko:"선택한 탭 캡처 중 (아무 키나 누르면 미리보기 취소)"
                     ~en:"Capturing selected tab (any key cancels preview)"), Theme.info ()
        | Failed detail ->
            let retry = match view.scene_guard with
              | Some _ ->
                  ui_text state ~ko:" · 이동 대상 대기 중 · r:재확인"
                    ~en:" · followed destination pending · r:recheck"
              | None -> "" in
            ui_text state ~ko:"원인: " ~en:"Cause: " ^ Terminal_text.single_line detail ^ retry, Theme.bad ()
        | No_browser ->
            ui_text state ~ko:"브라우저 브리지가 연결되지 않음" ~en:"Browser bridge not connected", Theme.recede ()
        | Idle when Option.is_some view.scene ->
            (match view.scene with
             | Some scene ->
                 let ko = state.ui_language = Lang_ko in
                 let summary = match Browser_lane_view.scene_summary scene with
                   | None -> ""
                   | Some text -> " · " ^ text in
                 let delta = match view.scene_delta with
                   | None -> ""
                   | Some {added; removed; unchanged; changed} ->
                       let changed_text = if changed = 0 then ""
                         else Printf.sprintf (if ko then " · 변경 %d" else " · %d changed") changed in
                       Printf.sprintf
                         (if ko then " · Δ %s 신규 · %s 제거 · =%d 유지%s"
                          else " · Δ %s new · %s out · =%d same%s")
                         (Masc_tui_value.Count.increase added)
                         (Masc_tui_value.Count.decrease removed)
                         unchanged changed_text in
                 let truncation =
                   if scene.content.truncated then ui_text state ~ko:" · 일부 생략" ~en:" · truncated"
                   else ""
                 in
                 Printf.sprintf
                   (if ko then "화면 %.1f ms · 노드 %d개%s%s%s"
                    else "Scene %.1f ms · %d nodes%s%s%s")
                   scene.elapsed_ms
                   (List.length scene.content.nodes)
                   truncation summary delta, Theme.ok ()
             | None -> ui_text state ~ko:"아직 조회되지 않음" ~en:"Not read yet", Theme.recede ())
        | Idle -> (match view.reading with
            | None -> ui_text state ~ko:"아직 조회되지 않음" ~en:"Not read yet", Theme.recede ()
            | Some reading ->
                Printf.sprintf
                  (if state.ui_language = Lang_ko then "조회 %.1f ms · 탭 %d개"
                   else "Read %.1f ms · %d tabs")
                  reading.elapsed_ms (List.length reading.tabs), Theme.recede ())
      in
      (* The global coordinator status is not the result of the browser HTTP
         request. Keep it labeled, including the existing workspace warning. *)
      c.push (coordinator_status_row state ~style status);
      List.iter (fun (style, row) -> c.push_styled ~style row) connection_rows;
      match view.client_picker with
      | Some cursor ->
          c.push_styled ~style:(Theme.info ())
            (ui_text state ~ko:"  브라우저 선택" ~en:"  Choose browser");
          c.push_divider ();
          let empty_line = browser_lane_picker_empty_line ~ko:(state.ui_language = Lang_ko) view in
          let choices = browser_choices view in
          let room =
            Int.max 1 (budget - picker_frame_rows - List.length (Option.to_list empty_line)) in
          let start = max 0 (cursor - room + 1) in
          choices |> List.iteri (fun index choice ->
            if index >= start && index < start + room then
              let is_selected = index = cursor in
              let line = (if is_selected then "\xe2\x80\xba " else "  ")
                ^ Terminal_text.single_line (browser_choice_label choice)
                ^ (if browser_choice_selected view choice then
                     ui_text state ~ko:" (현재)" ~en:" (current)"
                   else "") in
              if is_selected then c.push_selected line
              else c.push_styled ~style:Ansi.reset line);
          (* One row whatever the choice, so the rows below do not move with
             the cursor. *)
          let choice = List.nth_opt choices cursor in
          let details = List.filter_map Fun.id
            [Option.bind choice (browser_choice_observation ~now);
             (if view.advanced_choices then Option.bind choice browser_choice_detail else None)] in
          c.push_styled ~style:(Theme.recede ()) ("  " ^ String.concat " · " details);
          Option.iter (c.push_styled ~style:(Theme.recede ())) empty_line
      | None ->
      List.iter (fun row -> c.push_styled ~style:(Theme.warn ()) ("  " ^ row))
        (Browser_lane_view.unserved_rows view);
      c.push_styled ~style:(Theme.info ())
        (match view.scene with
         | Some _ ->
             (match List.nth_opt (scene_targets view) view.scene_cursor with
              | Some node ->
                  let label = match node.kind with
                    | Region _ -> ui_text state ~ko:"영역" ~en:"Region"
                    | Text | Raster | Control _ -> ui_text state ~ko:"요소" ~en:"Element" in
                  Printf.sprintf
                    (if state.ui_language = Lang_ko then "  %s %d/%d: %s  n/p:선택  y:컨텍스트 복사"
                     else "  %s %d/%d: %s  n/p:select  y:copy context")
                    label (view.scene_cursor + 1) (List.length (scene_targets view)) (Terminal_text.single_line node.text)
              | None ->
                  ui_text state ~ko:"  이 화면 영역에서 관측된 요소 없음  Ctrl-O:이미지"
                    ~en:"  No observed elements in this viewport  Ctrl-O:image")
         | None -> live_connection_row view);
      let tabs, page = match view.reading with
        | None -> [], None
        | Some reading -> reading.tabs, reading.page
      in
      let tab_count = List.length tabs in
      let index =
        let rec find i = function
          | [] -> 0
          | (tab : tab) :: rest -> if Some tab.id = view.selected_tab then i else find (i + 1) rest
        in find 0 tabs
      in
      let selected = List.nth_opt tabs index in
      c.push_styled ~style:(Theme.info ())
        (match selected with
         | None ->
             ui_text state
               ~ko:"  열린 탭 없음 · 선택한 브라우저 연결에서 페이지를 여세요"
               ~en:"  No open tabs · Open a page in the selected browser connection"
         | Some tab ->
             Printf.sprintf
               (if state.ui_language = Lang_ko then "  [%d/%d] %s%s%s  [/]:탭 선택  1-9:이동"
                else "  [%d/%d] %s%s%s  [/]:select tab  1-9:jump")
               (index + 1) tab_count (Terminal_text.single_line tab.title)
               (if tab.active then ui_text state ~ko:" (활성)" ~en:" (active)" else "")
               (match tab.ego_page with None -> "" | Some page ->
                 " · " ^ (match page.label with
                   | None -> ui_text state ~ko:"미관리" ~en:"unmanaged"
                   | Some label -> Terminal_text.single_line label)
                 ^ " · " ^ (match page.opened_by with
                   | Masc.Browser_surface.Agent_created ->
                       ui_text state ~ko:"에이전트 생성" ~en:"agent-created"
                   | Unknown_origin ->
                       ui_text state ~ko:"출처 미상" ~en:"unknown origin")));
      c.push_styled ~style:(Theme.recede ())
        (match view.scene, page with
         | Some scene, _ ->
             let scope = match scene.content.view, scene.content.scope with
               | Browser_lane.Regions, _ -> ui_text state ~ko:"페이지 영역" ~en:"Page regions"
               | Content, Some target ->
                   (match view.scene_scope with
                    | Some context when context.target = target ->
                        ui_text state ~ko:"선택됨 " ~en:"Selected "
                        ^ Masc.Browser_scene.region_role_to_string context.role
                        ^ " · " ^ fit_width (Terminal_text.single_line context.label)
                            (max 8 (framed_inner_width cols - 28))
                    | None | Some _ -> ui_text state ~ko:"선택한 영역" ~en:"Selected region")
               | Content, None -> ui_text state ~ko:"페이지 본문" ~en:"Page content" in
             let viewport = Printf.sprintf
                 (if state.ui_language = Lang_ko then "스크롤 x=%.0f y=%.0f"
                  else "page scroll x=%.0f y=%.0f")
                 scene.content.scroll_x scene.content.scroll_y in
             "  " ^ scope ^ " · " ^ viewport ^ " · " ^
             Terminal_text.single_line scene.content.url
         | None, None -> ui_text state ~ko:"  페이지 본문 없음" ~en:"  No page content"
         | None, Some page ->
             Printf.sprintf "  %s · %s%s%s"
               (Terminal_text.single_line page.url)
               (if state.ui_language = Lang_ko then Printf.sprintf "%d자" page.chars
                else Masc_tui_message_layout.count_noun page.chars "char")
               (if page.truncated then ui_text state ~ko:" · 일부 생략" ~en:" · truncated" else "")
               (match view.load with
                | Idle -> ""
                | No_browser | Loading _ | Failed _ ->
                    ui_text state ~ko:" · 이전 조회" ~en:" · previous read"));
      (match browser_lane_source_hint view with
       | None -> ()
       | Some hint -> c.push_styled ~style:(Theme.recede ())
           ("  " ^ Terminal_text.single_line hint));
      c.push_divider ();
      let lines = browser_lane_rows ~cols view in
      let total = Browser_lane_layout.count lines in
      let room = max 0 (budget - fixed_rows) in
      let max_scroll = max 0 (total - room) in
      let scroll = min max_scroll view.scroll in
      (* Read the window out of the retained array. [List.filteri] walked every
         row of a 50,000-character page to reach the ones on screen. *)
      let selected_row = Browser_lane_layout.selected_row lines in
      for index = scroll to min (scroll + room - 1) (total - 1) do
        let raw = Browser_lane_layout.line lines index in
        if selected_row = Some index then
          c.push_selected ("\xe2\x80\xba " ^ Masc_tui_theme.strip_sgr raw)
        else
          c.push_styled ~style:Ansi.reset ("  " ^ raw)
      done;
      Option.iter c.position
        (Masc_tui_value.Position.window ~first:scroll ~shown:room ~total))

let browser_history_fixed_rows = 5

let browser_history_scroll_limit state ~terminal_rows ~cols history =
  let view = Browser_history.page_view history in
  let budget = surface_chrome_budget ~frame:Chrome_screen state ~terminal_rows in
  let room = max 0 (budget - browser_history_fixed_rows) in
  max 0 (Browser_lane_layout.count (browser_lane_rows ~cols view) - room)

let render_browser_history (state : state) (history : Browser_history.t) =
  let terminal_rows, cols = get_terminal_size () in
  let title =
    here_row ~cols state
      ~path:[ browser_step state
            ; Terminal_text.single_line history.keeper_name
            ; ui_text state ~ko:"관측" ~en:"observations" ]
      ~readings:[] ~position:None
  in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let history_loading_spec =
    match history.content with
    | Listing ->
        Some
          ( "listing"
          , ui_text state ~ko:"관측 기록 목록 읽는 중" ~en:"Loading browser observations"
          , Some (ui_text state ~ko:"키퍼의 최근 도구 실행 기록을 불러오고 있습니다" ~en:"Reading the Keeper's recent tool receipts") )
    | Entries { selection = Loading; _ } ->
        Some
          ( "selection"
          , ui_text state ~ko:"저장된 페이지 본문 읽는 중" ~en:"Loading saved page"
          , Some (Terminal_text.single_line history.keeper_name) )
    | List_failed _ | List_kept_back _ | Entries { selection = (Failed _ | Observed _); _ } -> None
  in
  let history_started_at =
    Masc_tui_types.progress_clock_option state ~slot:"browser-history" ~now
      (Option.map (fun (sig_key, _, _) -> sig_key) history_loading_spec)
  in
  let progress_sheet =
    Option.map
      (fun (_, ps_title, ps_detail) ->
        { ps_title
        ; ps_detail
        ; ps_started_at = history_started_at
        ; ps_meter = None
        ; ps_action_hint = Some (ui_text state ~ko:"Esc:돌아가기" ~en:"Esc:back")
        ; ps_blocking = false
        })
      history_loading_spec
  in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:(Masc_tui_keys.footer_hints_browser_observations ~lang:state.ui_language)
    ~body:(fun ~budget c ->
      let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
      let status = match history.content with
        | Listing ->
            under_way ^ " " ^ ui_text state ~ko:"키퍼의 최근 도구 실행 기록을 불러오는 중"
              ~en:"Reading the Keeper's recent tool receipts"
        | List_failed detail ->
            ui_text state ~ko:"관측 기록 조회 실패: " ~en:"Could not read observations: "
            ^ Terminal_text.single_line detail
        | List_kept_back notice -> Terminal_text.single_line notice
        | Entries {entries;cursor;selection} ->
          (* The selected observation is the position, on the title row. *)
          if entries <> [] then
            c.position
              (Masc_tui_value.Position.row ~selected:(Some cursor)
                 ~total:(List.length entries));
          ui_text state ~ko:"최근 도구 호출 100건의 관측 기록" ~en:"Observations from 100 recent tool calls"
          ^ (match selection with
             | Loading -> " · " ^ under_way ^ " " ^ ui_text state ~ko:"저장된 페이지 불러오는 중" ~en:"loading saved page"
             | Failed detail -> " · " ^ Terminal_text.single_line detail
             | Observed _ -> "") in
      c.push_styled ~style:(Theme.info ()) ("  " ^ status);
      c.push_styled ~style:(Theme.recede ())
        (ui_text state
           ~ko:"  이력 조회 모드 · 브라우저 조작과 실시간 스크린샷은 비활성 상태입니다"
           ~en:"  Historical read · browser actions and live screenshots are inactive here");
      (match Browser_history.selected history with
       | None ->
           c.push_styled ~style:(Theme.recede ())
             (ui_text state ~ko:"  선택된 관측 기록 없음" ~en:"  No selected observation")
       | Some entry -> c.push_styled ~style:(Theme.recede ())
           ("  " ^ Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_second
                     ~now:(Unix.gettimeofday ()) entry.at
            ^ " · " ^ entry.execution_id));
      (match Browser_history.observation history with
       | None ->
           if Option.is_some history_loading_spec then
             c.push
               ("  " ^ progress_inline ~ko ~now ?started_at:history_started_at
                  (ui_text state ~ko:"페이지 본문 불러오는 중" ~en:"Loading page content"))
           else
             c.push_styled ~style:(Theme.recede ())
               (ui_text state ~ko:"  페이지 본문이 아직 로드되지 않음"
                  ~en:"  Page content has not been loaded")
       | Some observation -> c.push_styled ~style:(Theme.info ())
           ("  " ^ Terminal_text.single_line observation.scene.title ^ " · "
            ^ Terminal_text.single_line observation.scene.url
            ^ (if observation.scene.truncated then
                 ui_text state ~ko:" · 부분 관측" ~en:" · partial observation"
               else
                 ui_text state ~ko:" · 관측된 화면" ~en:" · observed viewport")));
      c.push_divider ();
      let view = Browser_history.page_view history in
      let lines = browser_lane_rows ~cols view in
      let count = Browser_lane_layout.count lines in
      let room = max 0 (budget - browser_history_fixed_rows) in
      let scroll = min history.scroll (max 0 (count-room)) in
      for index=scroll to min (scroll+room-1) (count-1) do
        c.push_styled ~style:Ansi.reset ("  " ^ Browser_lane_layout.line lines index)
      done)

type connector_table_column =
  | Connector_name_column | Connector_configured_column
  | Connector_reachable_column | Connector_status_column | Connector_channel_column

let render_connectors (state : state) =
  match browser_lane_on_screen state, state.browser_history with
  | Some _, Some history ->
      Masc_tui_types.clear_progress_clock state ~slot:"browser-lane";
      Masc_tui_types.clear_progress_clock state ~slot:"connectors-op";
      render_browser_history state history
  | Some view, None ->
      Masc_tui_types.clear_progress_clock state ~slot:"browser-history";
      Masc_tui_types.clear_progress_clock state ~slot:"connectors-op";
      render_browser_lane state view
  | None, _ ->
  Masc_tui_types.clear_progress_clock state ~slot:"browser-lane";
  Masc_tui_types.clear_progress_clock state ~slot:"browser-history";
  let terminal_rows, cols = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let connectors =
    match state.connectors with
    | None -> []
    | Some s -> s.Masc.Tui_decode_connectors.cs_connectors
  in
  let shown = List.length connectors in
  let column_width = function
    | Connector_name_column -> 12
    | Connector_configured_column -> 10
    | Connector_reachable_column -> 9
    | Connector_status_column -> 12
    | Connector_channel_column -> 16
  in
  (* Configuration is secondary to whether this connector can be reached
     and which channel it serves. Name is flexible; every other field keeps
     its column even when another row has a long Unicode name. *)
  let table_inner_width = max 0 (framed_inner_width cols - 2) in
  let layout = Masc_tui_table.fit ~inner_width:table_inner_width
    ~width:column_width ~flex:Connector_name_column
    ~drop_order:[ Connector_configured_column ]
    [ Connector_name_column; Connector_configured_column; Connector_reachable_column;
      Connector_status_column; Connector_channel_column ] in
  let cells ~name ~configured ~reachable ~status ~channel =
    List.map (fun column ->
      let header, value = match column with
        | Connector_name_column ->
            ui_text state ~ko:"커넥터" ~en:"CONNECTOR", name
        | Connector_configured_column ->
            ui_text state ~ko:"설정" ~en:"CONFIGURED", configured
        | Connector_reachable_column ->
            ui_text state ~ko:"연결" ~en:"REACHABLE", reachable
        | Connector_status_column -> ui_text state ~ko:"상태" ~en:"STATUS", status
        | Connector_channel_column ->
            ui_text state ~ko:"채널" ~en:"CHANNEL", channel
      in
      let width = if column = Connector_name_column then layout.flex_width else column_width column in
      Masc_tui_table.cell ~header ~width value) layout.shown
  in
  let read_notice = connectors_read_notice state in
  let read_view = Connector_read.view state.connectors_read in
  let read_in_flight =
    match read_view with
    | Connector_read.Reading _ -> true
    | Quiet | Waiting_after_write | Failed_to_start -> false
  in
  let unbind_active = state.connector_unbind_all_inflight in
  let connectors_progress_spec =
    if unbind_active then
      Some
        ( "unbind-all"
        , ui_text state ~ko:"커넥터 전체 연결 해제 중" ~en:"Unbinding all connectors"
        , Some (ui_text state ~ko:"서버에서 모든 채널 연결을 해제하고 있습니다" ~en:"Removing all connector bindings on server")
        , true )
    else if read_in_flight then
      match read_notice with
      | Some notice ->
          Some
            ( "read:" ^ notice
            , ui_text state ~ko:"채널 상태 조회 중" ~en:"Reading channels"
            , Some (Terminal_text.single_line notice)
            , false )
      | None -> None
    else None
  in
  let connectors_started_at =
    Masc_tui_types.progress_clock_option state ~slot:"connectors-op" ~now
      (Option.map (fun (sig_key, _, _, _) -> sig_key) connectors_progress_spec)
  in
  let read_started_at =
    Masc_tui_types.progress_clock_option state ~slot:"connectors-read" ~now
      (if read_in_flight then read_notice else None)
  in
  let progress_sheet =
    Option.map
      (fun (_, ps_title, ps_detail, ps_blocking) ->
        { ps_title
        ; ps_detail
        ; ps_started_at = connectors_started_at
        ; ps_meter = None
        ; ps_action_hint = None
        ; ps_blocking
        })
      connectors_progress_spec
  in
  let title =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"채널" ~en:"channels" ]
      ~readings:
        (match progress_sheet with
         | None -> []
         | Some sheet ->
             [ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title ])
      ~position:None
  in
  surface_chrome ~overflow:Paged_by_cursor ?progress_sheet ~now state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    (* Keep the transport keys here: the shared Connectors sheet also names
       keys owned only by Browser Lane. Esc returns to Features & plugins. *)
    ~hints:(ui_text state
      ~ko:"B:Browser Lane  j/k:스크롤  b:연결  u:연결 해제  r:새로고침  Esc:기능"
      ~en:"B:Browser Lane  j/k:scroll  b:bind  u:unbind  r:refresh  Esc:features")
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        ("  "
         ^ Masc_tui_table.header_row_with_dropped
             ~ko
             ~inner_width:table_inner_width
             ~dropped:layout.dropped
             (cells ~name:"" ~configured:"" ~reachable:"" ~status:"" ~channel:""));
      c.push_divider ();
      Option.iter (fun notice ->
        if read_in_flight then
          c.push ("  " ^ progress_inline ~ko ~now ?started_at:read_started_at notice)
        else
          let style =
            match read_view with
            | Connector_read.Failed_to_start -> Theme.warn ()
            | Quiet | Waiting_after_write | Reading _ -> Theme.recede ()
          in
          c.push_styled ~style ("  " ^ Terminal_text.single_line notice)) read_notice;
      (match state.connectors_error with
       | None -> ()
       | Some detail ->
           c.push_styled ~style:(Theme.bad ())
             ("  " ^ Keeper_chat.terminal_safe_text detail);
           c.push_divider ());
      let fixed = 2 + (if Option.is_some read_notice then 1 else 0)
        + (if Option.is_some state.connectors_error then 2 else 0) in
      let room = max 1 (budget - fixed) in
      let content_height = room in
      let cursor = max 0 (min state.connectors_cursor (max 0 (shown - 1))) in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min state.connectors_scroll max_scroll) in
      let scroll =
        if shown = 0 then scroll
        else Masc_tui_scroll.ensure_visible ~cursor ~height:content_height scroll
      in
      let connectors_window = Rows.of_list ~first:scroll ~height:content_height connectors in
      report_drawn_list Connector_rows ~height:content_height;
      if shown = 0 then
        let reading = match Connector_read.view state.connectors_read with
          | Connector_read.Reading _ -> true
          | Quiet | Waiting_after_write | Failed_to_start -> false
        in
        let empty =
          match
            empty_page_of ~snapshot:state.connectors
              ~error:state.connectors_error
          with
          | Page_failed -> Some (page_failed_note ~ko:(state.ui_language = Lang_ko))
          (* The notice above the list is already saying that a read runs. *)
          | Page_unread when reading -> None
          | Page_unread -> Some (page_unread_note ~ko:(state.ui_language = Lang_ko))
          | Page_empty ->
              Some
                (ui_text state ~ko:"  (등록된 커넥터 없음)"
                   ~en:"  (no connectors registered)")
        in
        Option.iter (c.push_styled ~style:(Theme.recede ())) empty
      else begin
        for i = 0 to content_height - 1 do
          let idx = i + scroll in
          match Rows.at connectors_window idx with
          | None -> c.push_empty ()
          | Some connector ->
              let open Masc.Tui_decode_connectors in
              let available = connector_available connector in
              let connected = connector_connected connector in
              let configured_cell =
                if available then
                  Theme.ok () ^ "\xe2\x97\x8f " ^ ui_text state ~ko:"예" ~en:"yes" ^ Ansi.reset
                else
                  Theme.recede () ^ "\xe2\x97\x8b " ^ ui_text state ~ko:"아니오" ~en:"no" ^ Ansi.reset
              in
              let reachable_cell =
                if connected then
                  Theme.ok () ^ "\xe2\x97\x8f " ^ ui_text state ~ko:"예" ~en:"yes" ^ Ansi.reset
                else if available then
                  Theme.bad () ^ "\xc3\x97 " ^ ui_text state ~ko:"아니오" ~en:"no" ^ Ansi.reset
                else
                  Theme.recede () ^ "\xe2\x97\x8b " ^ ui_text state ~ko:"아니오" ~en:"no" ^ Ansi.reset
              in
              let channel_text =
                Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                  connector.cn_channel
              in
              let channel_cell =
                if String.equal channel_text Masc_tui_theme.Glyph.no_value then
                  Theme.recede () ^ channel_text ^ Ansi.reset
                else channel_text
              in
              let is_selected = idx = cursor in
              let line =
                (if is_selected then "\xe2\x80\xba " else "  ") ^ Masc_tui_table.row (cells
                  ~name:(Terminal_text.single_line connector.cn_display_name)
                  ~configured:configured_cell
                  ~reachable:reachable_cell
                  ~status:(Terminal_text.single_line (connector_status connector))
                  ~channel:channel_cell)
              in
              if is_selected then c.push_selected (Masc_tui_theme.strip_sgr line)
              else if available && not connected then
                (* Set up and unreachable is the row to act on: it was
                   working. Never configured recedes -- it is a choice, not a
                   fault. *)
                c.push_styled ~style:(Theme.bad ()) (Masc_tui_theme.strip_sgr line)
              else if not available then
                c.push_styled ~style:(Theme.recede ()) (Masc_tui_theme.strip_sgr line)
              else c.push line
        done;
        c.position
          (Masc_tui_value.Position.row ~selected:(Some cursor)
             ~total:shown)
      end)

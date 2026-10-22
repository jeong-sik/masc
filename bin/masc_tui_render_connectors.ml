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

let browser_lane_fixed_rows view =
  (* Status, selection, tab, URL, divider and text position are always drawn.
     A source hint contributes a row only when the selected node has one, and
     a refused gesture its rows until the next input. *)
  6 + (if Option.is_some (browser_lane_source_hint view) then 1 else 0)
  + List.length (Browser_lane_view.unserved_rows view)

(* The picker's rows besides its choices and what an empty connection list
   says: the status row, the heading and the divider above the choices, and
   the detail row for the highlighted choice below them. *)
let browser_picker_frame_rows = 4

(* The cells a BiDi host row has behind the surface's two-cell indent. *)
let browser_host_row_cells ~cols = max 1 (framed_inner_width cols - 2)

let browser_lane_visible_rows (state : state) ~terminal_rows view =
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  max 0 (framed_content_height ~rows:body_rows - browser_lane_fixed_rows view)

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

let render_browser_lane (state : state) (view : Browser_lane_view.t) =
  let open Browser_lane_view in
  let terminal_rows, cols = get_terminal_size () in
  let read_status = Browser_lane_view.read_status view in
  let read_style = match read_status with
    | Read_ok -> Theme.ok ()
    | Read_failed -> Theme.bad ()
    | Reading | Operating -> Theme.info ()
    | Unread | Browser_missing -> Theme.recede ()
  in
  let title = Printf.sprintf "%s  %s  %s[%s]%s"
      (screen_title " MASC Browser Lane") (selection_label view ^ " · "
       ^ Option.value (connection_label view) ~default:"no browser")
      read_style (Browser_lane_view.read_status_label read_status) Ansi.reset in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:(match view.client_picker, view.url_draft with
      | Some _, _ -> "↑/↓:choose  Enter:use browser  r:reload connections  A:advanced  Esc:cancel"
      | None, Some _ when busy view -> "Capture in flight • Enter after completion • Esc:cancel URL"
      | None, Some _ -> "Enter:go  Esc:cancel  Ctrl-U:clear  Ctrl-O:screenshot"
      | None, None when Option.is_some view.scene ->
          let action = match Option.bind (selected_scene_target view) scene_target_action with
            | Some Read_region -> "Enter:read region  "
            | Some Follow_link -> "Enter:follow link  "
            | Some Click_control -> "Enter:click  "
            | None -> "" in
          let article_hint =
            if Browser_lane_view.scene_has_articles view then "N/P:article  " else "" in
          "b:choose browser  " ^ action ^ "m:main  J/K:page scroll  Tab/Shift-Tab:action  " ^ article_hint ^ "n/p:element  v:regions  s:text  y:copy  h:observations  Ctrl-O:image"
      | None, None when Option.is_some view.scene_guard ->
          "b:choose browser  m:main  J/K:page scroll  r:recheck followed destination  s:recheck text  h:observations  Ctrl-O:image"
      | None, None -> Masc_tui_keys.footer_hints_browser_lane ^ "  s:scene  v:regions  h:observations")
    ~body:(fun ~budget c ->
      let status, style = match view.load with
        | Loading (_, Discover _) -> "Reading browser connections…", Theme.info ()
        | Loading (_, Read) ->
            (match browser_label view with
             | Some browser -> "Reading " ^ browser ^ "…"
             | None -> "Reading…"), Theme.info ()
        | Loading (_, Read_refresh) -> "Refreshing browser text…", Theme.info ()
        | Loading (_, Open_session) -> "Opening work browser…", Theme.info ()
        | Loading (_, Close_session) -> "Closing work browser…", Theme.info ()
        | Loading (_, Goto _) -> "Navigating selected browser…", Theme.info ()
        | Loading (_, Scene_regions _) -> "Reading page regions…", Theme.info ()
        | Loading (_, Scene_scroll _) -> "Scrolling page and refreshing scene…", Theme.info ()
        | Loading (_, Scene_focus _) -> "Reading selected page region…", Theme.info ()
        | Loading (_, Scene_read _) -> "Reading browser text and controls…", Theme.info ()
        | Loading (_, Scene_refresh _) -> "Refreshing current browser view…", Theme.info ()
        | Loading (_, Scene_follow _) -> "Following observed browser link…", Theme.info ()
        | Loading (_, Scene_follow_refresh _) -> "Rechecking followed browser destination…", Theme.info ()
        | Loading (_, Scene_click _) -> "Clicking observed browser control…", Theme.info ()
        | Loading (_, (Viewport_refresh _ | Viewport_cadence _)) -> "Refreshing selected browser viewport…", Theme.info ()
        | Loading (_, Viewport_pointer {action=Browser_lane.Scroll_at _;_}) -> "Scrolling selected browser viewport…", Theme.info ()
        | Loading
            ( _
            , Viewport_pointer
                { action =
                    ( Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
                    | Browser_lane.Activate_tab | Browser_lane.Click _
                    | Browser_lane.Fill _ | Browser_lane.Scroll _
                    | Browser_lane.Hover _ | Browser_lane.Drag_to _
                    | Browser_lane.Hover_at _ | Browser_lane.Click_at _
                    | Browser_lane.Drag _ | Browser_lane.Follow_link _
                    | Browser_lane.Click_node _ | Browser_lane.Fill_node _ )
                ; _
                } ) -> "Interacting with selected browser viewport…", Theme.info ()
        | Loading (_, Screenshot _) ->
            (match browser_label view with
             | Some browser -> "Capturing selected " ^ browser ^ " tab… (any key cancels preview)"
             | None -> "Capturing selected tab… (any key cancels preview)"), Theme.info ()
        | Failed detail ->
            let retry = match view.scene_guard with
              | Some _ -> " · followed destination pending · r:recheck"
              | None -> "" in
            "Cause: " ^ Terminal_text.single_line detail ^ retry, Theme.bad ()
        | No_browser ->
            (match view.source with
             | Live -> "Browser bridge not connected"
             | Automation | Stagehand -> "Browser session closed • o:open"), Theme.recede ()
        | Idle when Option.is_some view.scene ->
            (match view.scene with
             | Some scene ->
                 let summary = match Browser_lane_view.scene_summary scene with
                   | None -> ""
                   | Some text -> " • " ^ text in
                 let delta = match view.scene_delta with
                   | None -> ""
                   | Some {added; removed; unchanged; changed} ->
                       let changed_text = if changed = 0 then ""
                         else Printf.sprintf " · %d changed" changed in
                       Printf.sprintf " • Δ +%d new · -%d out · =%d same%s"
                         added removed unchanged changed_text in
                 let truncation = if scene.content.truncated then " • truncated" else "" in
                 Printf.sprintf "Scene %.1f ms • %d nodes%s%s%s" scene.elapsed_ms
                   (List.length scene.content.nodes)
                   truncation summary delta, Theme.ok ()
             | None -> "Not read yet", Theme.recede ())
        | Idle -> (match view.reading with
            | None -> "Not read yet", Theme.recede ()
            | Some reading -> Printf.sprintf "Read %.1f ms • %d tabs"
                reading.elapsed_ms (List.length reading.tabs), Theme.recede ())
      in
      (* The global coordinator status is not the result of the browser HTTP
         request. Keep it labeled, including the existing workspace warning. *)
      c.push (coordinator_status_row state ~style status);
      Option.iter (fun (client : Browser_lane_view.client) ->
        List.iter (fun (work : Browser_lane.interaction_activity) ->
          let phase = match work.phase with
            | Browser_lane.Interaction_queued -> "queued"
            | Browser_lane.Interaction_running -> "working" in
          c.push_styled ~style:(Theme.info ()) ("  Agent "
            ^ Terminal_text.single_line (Option.value work.actor ~default:"MASC") ^ " · " ^ phase
            ^ " · " ^ Terminal_text.single_line work.action ^ " · tab " ^ string_of_int work.tab_id
            ^ " (at last connection read)")) client.interactions) view.selected_client;
      match view.client_picker with
      | Some cursor ->
          c.push_styled ~style:(Theme.info ()) "  Choose browser · separate sessions do not share login";
          c.push_divider ();
          (* The rows under the choices cannot be scrolled to. Where they
             report a BiDi host, one that runs or ran, the first of them
             keep a place however many choices there are, with the row that
             says more is hidden, unless that would leave too few choices to
             choose from. *)
          let host_rows =
            (if view.advanced_choices then
               Browser_lane_view.bidi_host_rows ~width:(browser_host_row_cells ~cols) view
             else []) in
          let empty_line = browser_lane_picker_empty_line view in
          let extension_rows =
            if view.advanced_choices && Option.is_some empty_line && awaiting_browser view then
              [ Theme.info (), "  The MASC extension and its registered native host connect a live browser."
              ; Theme.recede (), "  " ^ transport_setup_row [Browser_lane.Web_extension]
              ; Theme.recede (), "  Enable the extension in your Zen/Firefox profile, then r:refresh." ]
            else [] in
          let choices = browser_choices view in
          let reports_a_host = Browser_lane_view.host_rows_report_a_host view in
          let room =
            Browser_lane_view.picker_choice_rows
              ~rows:(budget - browser_picker_frame_rows - List.length (Option.to_list empty_line))
              ~choices:(List.length choices)
              ~below:(if reports_a_host
                      then List.length host_rows + List.length extension_rows else 0) in
          let start = max 0 (cursor - room + 1) in
          choices |> List.iteri (fun index choice ->
            if index >= start && index < start + room then
              let line = "  " ^ Terminal_text.single_line (browser_choice_label choice)
                ^ (if browser_choice_selected view choice then " (current)" else "") in
              if index = cursor then c.push_selected line
              else c.push_styled ~style:Ansi.reset line);
          (* One row whatever the choice, so the rows below do not move with
             the cursor. *)
          c.push_styled ~style:(Theme.recede ())
            ("  " ^ Option.value ~default:""
               (if view.advanced_choices then Option.bind (List.nth_opt choices cursor) browser_choice_detail
                else None));
          Option.iter (c.push_styled ~style:(Theme.recede ())) empty_line;
          (* A terminal too short for everything loses rows from the end.
             With no host yet, the host's rows only say how one is started:
             they take no row from what is above them, and are drawn where
             the screen has rows left. Rows that report a host come before
             the rows on the extension. On a screen that holds all of both
             the host's rows stay together; on a shorter one the host's
             first rows are followed by the extension's, and what is cut
             from the end is the rest of the host's. *)
          let draw_host rows =
            List.iter (fun row -> c.push_styled ~style:(Theme.recede ()) ("  " ^ row)) rows in
          let draw_extension () =
            List.iter (fun (style, row) -> c.push_styled ~style row) extension_rows in
          let above =
            browser_picker_frame_rows + min room (List.length choices)
            + List.length (Option.to_list empty_line) in
          let extension = List.length extension_rows in
          if not reports_a_host then (
            draw_extension ();
            if budget > above + extension then draw_host host_rows)
          else if above + List.length host_rows + extension <= budget then (
            draw_host host_rows;
            draw_extension ())
          else (
            let head, rest = Browser_lane_view.picker_host_head host_rows in
            draw_host head;
            draw_extension ();
            draw_host rest)
      | None ->
      List.iter (fun row -> c.push_styled ~style:(Theme.warn ()) ("  " ^ row))
        (Browser_lane_view.unserved_rows view);
      c.push_styled ~style:(Theme.info ())
        (match view.url_draft with
         | Some draft -> browser_lane_url_line ~cols draft
         | None when Option.is_some view.scene ->
             (match List.nth_opt (scene_targets view) view.scene_cursor with
              | Some node ->
                  let label = match node.kind with
                    | Region _ -> "Region"
                    | Text | Raster | Control _ -> "Element" in
                  Printf.sprintf "  %s %d/%d: %s • n/p:select • y:copy context"
                    label (view.scene_cursor + 1) (List.length (scene_targets view)) (Terminal_text.single_line node.text)
              | None -> "  No observed elements in this viewport • Ctrl-O:image")
         | None -> match view.source with
             | Live -> live_connection_row view
             | Automation -> "  Work browser • b:choose browser • g:URL • o:open / x:close • A:advanced"
             | Stagehand -> "  Chromium work browser • b:choose browser • g:URL • o:open / x:close • A:advanced");
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
         | None -> "  No open tabs • Open a page in the selected browser connection"
         | Some tab -> Printf.sprintf "  [%d/%d] %s%s  [ / ]:select tab · 1-9:jump"
             (index + 1) tab_count (Terminal_text.single_line tab.title)
             (if tab.active then " (active)" else ""));
      c.push_styled ~style:(Theme.recede ())
        (match view.scene, page with
         | Some scene, _ ->
             let scope = match scene.content.view, scene.content.scope with
               | Browser_lane.Regions, _ -> "Page regions"
               | Content, Some target ->
                   (match view.scene_scope with
                    | Some context when context.target = target ->
                        "Selected " ^ Masc.Browser_scene.region_role_to_string context.role
                        ^ " · " ^ fit_width (Terminal_text.single_line context.label)
                            (max 8 (framed_inner_width cols - 28))
                    | None | Some _ -> "Selected region")
               | Content, None -> "Page content" in
             let viewport = Printf.sprintf "page scroll x=%.0f y=%.0f"
                 scene.content.scroll_x scene.content.scroll_y in
             "  " ^ scope ^ " · " ^ viewport ^ " · " ^
             Terminal_text.single_line scene.content.url
         | None, None -> "  No page content"
         | None, Some page -> Printf.sprintf "  %s • %s%s%s"
             (Terminal_text.single_line page.url) (Masc_tui_message_layout.count_noun page.chars "char")
             (if page.truncated then " • truncated" else "")
             (match view.load with Idle -> "" | No_browser | Loading _ | Failed _ -> " • previous read"));
      (match browser_lane_source_hint view with
       | None -> ()
       | Some hint -> c.push_styled ~style:(Theme.recede ())
           ("  " ^ Terminal_text.single_line hint));
      c.push_divider ();
      let lines = browser_lane_rows ~cols view in
      let total = Browser_lane_layout.count lines in
      let room = max 0 (budget - browser_lane_fixed_rows view) in
      let max_scroll = max 0 (total - room) in
      let scroll = min max_scroll view.scroll in
      (* Read the window out of the retained array. [List.filteri] walked every
         row of a 50,000-character page to reach the ones on screen. *)
      for index = scroll to min (scroll + room - 1) (total - 1) do
        c.push_styled ~style:Ansi.reset ("  " ^ Browser_lane_layout.line lines index)
      done;
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  Text %s • j/k:scroll • r:refresh • Ctrl-^ / Esc:hide lane"
           (Masc_tui_scroll.window_text ~scroll ~height:room total)))

let browser_history_fixed_rows = 6

let browser_history_scroll_limit state ~terminal_rows ~cols history =
  let view = Browser_history.page_view history in
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let room = max 0 (framed_content_height ~rows:body_rows - browser_history_fixed_rows) in
  max 0 (Browser_lane_layout.count (browser_lane_rows ~cols view) - room)

let render_browser_history (state : state) (history : Browser_history.t) =
  let terminal_rows, cols = get_terminal_size () in
  let title = screen_title (" MASC Browser Lane · " ^ Terminal_text.single_line history.keeper_name ^ " · retained observations") in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:"[/]:observation  j/k:scroll  y:copy record  r:reload list  R:recheck workspace  h/Esc:back to browser"
    ~body:(fun ~budget c ->
      let status = match history.content with
        | Listing -> "Reading the Keeper's recent tool receipts…"
        | List_failed detail -> "Could not read observations: " ^ Terminal_text.single_line detail
        | Entries {entries;cursor;selection} ->
          let position = Printf.sprintf "Observation %d/%d · from 100 recent tool calls"
            (if entries=[] then 0 else cursor+1) (List.length entries) in
          position ^ (match selection with Loading -> " · loading saved page…"
            | Failed detail -> " · " ^ Terminal_text.single_line detail | Observed _ -> "") in
      c.push_styled ~style:(Theme.info ()) ("  " ^ status);
      c.push_styled ~style:(Theme.recede ()) "  Historical read · browser actions and live screenshots are inactive here";
      (match Browser_history.selected history with
       | None -> c.push_styled ~style:(Theme.recede ()) "  No selected observation"
       | Some entry -> c.push_styled ~style:(Theme.recede ())
           ("  " ^ Terminal_text.single_line (Masc_domain.iso8601_of_unix_seconds entry.at)
            ^ " · " ^ entry.execution_id));
      (match Browser_history.observation history with
       | None -> c.push_styled ~style:(Theme.recede ()) "  Page content has not been loaded"
       | Some observation -> c.push_styled ~style:(Theme.info ())
           ("  " ^ Terminal_text.single_line observation.scene.title ^ " · "
            ^ Terminal_text.single_line observation.scene.url
            ^ (if observation.scene.truncated then " · partial observation" else " · observed viewport")));
      c.push_divider ();
      let view = Browser_history.page_view history in
      let lines = browser_lane_rows ~cols view in
      let count = Browser_lane_layout.count lines in
      let room = max 0 (budget - browser_history_fixed_rows) in
      let scroll = min history.scroll (max 0 (count-room)) in
      for index=scroll to min (scroll+room-1) (count-1) do
        c.push_styled ~style:Ansi.reset ("  " ^ Browser_lane_layout.line lines index)
      done;
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  Text %s"
           (Masc_tui_scroll.window_text ~scroll ~height:room count)))

type connector_table_column =
  | Connector_name_column | Connector_configured_column
  | Connector_reachable_column | Connector_status_column | Connector_channel_column

let render_connectors (state : state) =
  match browser_lane_on_screen state, state.browser_history with
  | Some _, Some history -> render_browser_history state history
  | Some view, None -> render_browser_lane state view
  | None, _ ->
  let terminal_rows, cols = get_terminal_size () in
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
  let layout = Masc_tui_table.fit ~inner_width:(max 0 (framed_inner_width cols - 2))
    ~width:column_width ~flex:Connector_name_column
    ~drop_order:[ Connector_configured_column ]
    [ Connector_name_column; Connector_configured_column; Connector_reachable_column;
      Connector_status_column; Connector_channel_column ] in
  let cells ~name ~configured ~reachable ~status ~channel =
    List.map (fun column ->
      let header, value = match column with
        | Connector_name_column -> "CONNECTOR", name
        | Connector_configured_column -> "CONFIGURED", configured
        | Connector_reachable_column -> "REACHABLE", reachable
        | Connector_status_column -> "STATUS", status
        | Connector_channel_column -> "CHANNEL", channel
      in
      let width = if column = Connector_name_column then layout.flex_width else column_width column in
      Masc_tui_table.cell ~header ~width value) layout.shown
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.connectors with
    | None ->
        Printf.sprintf "%s  %s  %s"
          (screen_title " MASC Connectors") timestamp
          (connection_badge state)
    | Some snapshot ->
        Printf.sprintf "%s (%d of %d available)  %s  %s"
          (screen_title " MASC Connectors")
          snapshot.Masc.Tui_decode_connectors.cs_active snapshot.Masc.Tui_decode_connectors.cs_total
          timestamp (connection_badge state)
  in
  let read_notice = connectors_read_notice state in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    (* Names the exit, which this row did not. Esc leaves for the selected
       Keeper (masc_tui.ml reads it under [Connectors]) and the key sheet
       says so, but the footer named no exit key at all. Surfaces built
       through [hints_of_bindings] cannot drift this way -- footer and sheet
       come from one list -- and this one writes its own. Esc goes last
       because [drop_hint_items] never gives it up. *)
    ~hints:"B:Browser Lane  j/k:scroll  b:bind  u:unbind  r:refresh  Esc:keeper"
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        ("  " ^ Masc_tui_table.header_row
          (cells ~name:"" ~configured:"" ~reachable:"" ~status:"" ~channel:""));
      c.push_divider ();
      Option.iter (fun notice ->
        c.push_styled ~style:(Theme.info ()) ("  " ^ notice)) read_notice;
      (match state.connectors_error with
       | None -> ()
       | Some detail ->
           c.push_styled ~style:(Theme.bad ())
             ("  " ^ Keeper_chat.terminal_safe_text detail);
           c.push_divider ());
      let fixed = 2 + (if Option.is_some read_notice then 1 else 0)
        + (if Option.is_some state.connectors_error then 2 else 0) in
      let room = max 1 (budget - fixed) in
      let overflowing = shown > room in
      let content_height = if overflowing then max 1 (room - 1) else room in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min state.connectors_scroll max_scroll) in
      let connectors_window = Rows.of_list ~first:scroll ~height:content_height connectors in
      if shown = 0 then
        let empty =
          match
            empty_page_of ~snapshot:state.connectors
              ~error:state.connectors_error
          with
          | Page_failed -> page_failed_note
          | Page_unread -> page_unread_note
          | Page_empty -> "  (no connectors registered)"
        in
        c.push_styled ~style:(Theme.recede ()) empty
      else begin
        for i = 0 to content_height - 1 do
          let idx = i + scroll in
          match Rows.at connectors_window idx with
          | None -> c.push_empty ()
          | Some connector ->
              let open Masc.Tui_decode_connectors in
              let yes_no flag = if flag then "yes" else "no" in
              let line =
                "  " ^ Masc_tui_table.row (cells
                  ~name:(Terminal_text.single_line connector.cn_display_name)
                  ~configured:(yes_no connector.cn_available)
                  ~reachable:(yes_no connector.cn_connected)
                  ~status:(Terminal_text.single_line connector.cn_status)
                  ~channel:(Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                     connector.cn_channel))
              in
              let style =
                (* Set up and unreachable is the row to act on: it was
                   working. Never configured is dim -- it is a choice, not a
                   fault. *)
                if connector.cn_available && not connector.cn_connected then
                  Theme.bad ()
                else if not connector.cn_available then Ansi.dim
                else Ansi.reset
              in
              if idx = state.connectors_cursor then c.push_selected line
              else c.push_styled ~style line
        done;
        if overflowing then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "  [connectors %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
      end)

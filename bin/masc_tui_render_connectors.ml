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
let browser_lane_connection_rows (view : Browser_lane_view.t) =
  let selected = match view.selected_client with
    | None -> []
    | Some (client : Browser_lane_view.client) ->
        let metadata = Option.to_list (Option.map (fun row -> Theme.recede (), "  " ^ row)
          (Browser_lane_view.space_observation_row client)) in
        let pending = List.map (fun (work : Browser_lane.interaction_activity) ->
          let phase = match work.phase with
            | Browser_lane.Interaction_queued -> "queued"
            | Browser_lane.Interaction_running -> "working" in
          Theme.info (), "  Agent "
            ^ Terminal_text.single_line (Option.value work.actor ~default:"MASC") ^ " · " ^ phase
            ^ " · " ^ Terminal_text.single_line work.action
            ^ (match work.tab_id with Some id -> " · tab " ^ string_of_int id | None -> "")
            ^ " (at last connection read)") client.interactions in
        let settled = List.map (fun (settled : Browser_lane.settled_activity) ->
          let work=settled.work in
          let outcome,style=match settled.outcome with
            | Browser_lane.Activity_returned -> "returned",Theme.recede ()
            | Activity_refused -> "not performed",Theme.warn ()
            | Activity_partial -> "partly performed",Theme.warn ()
            | Activity_unknown -> "outcome unknown",Theme.warn () in
          style, "  Last · "
            ^ Terminal_text.single_line (Option.value work.actor ~default:"MASC")
            ^ " · " ^ Terminal_text.single_line work.action ^ " · " ^ outcome
            ^ (match work.tab_id with Some id -> " · tab " ^ string_of_int id | None -> ""))
          client.last_activities in
        metadata @ pending @ settled in
  let inventory = match view.inventory_report with
    | Browser_lane_view.Inventory_not_reported -> []
    | Inventory_reported issues -> List.map (fun issue -> Theme.warn (),
        "  " ^ Terminal_text.single_line (Masc.Browser_connection_inventory.issue_message issue)) issues
    | Inventory_report_unreadable detail -> [Theme.warn (),
        "  Inventory report unreadable · " ^ Terminal_text.single_line detail] in
  let unavailable = Option.to_list (Option.map (fun message -> Theme.warn (),
    "  " ^ Terminal_text.single_line message) (Browser_lane_view.unavailable_notice view)) in
  unavailable @ selected @ Option.to_list (Option.map (fun detail -> Theme.warn (),
    "  Activity refresh failed · " ^ Terminal_text.single_line detail) view.activity_error) @ inventory

let browser_lane_fixed_rows ~connection_rows view =
  (* Status, selection, tab, URL, divider and text position are always drawn.
     A source hint contributes a row only when the selected node has one, and
     a refused gesture its rows until the next input. Connection observations,
     pending/settled activities and refresh failures take their projected rows. *)
  6 + (if Option.is_some (browser_lane_source_hint view) then 1 else 0)
  + List.length (Browser_lane_view.unserved_rows view)
  + List.length connection_rows

(* The picker's rows besides its choices and what an empty connection list
   says: the status row, the heading and the divider above the choices, and
   the detail row for the highlighted choice below them, plus the same
   connection rows drawn before the picker. *)
let browser_picker_frame_rows connection_rows = 4 + List.length connection_rows

let browser_lane_visible_rows (state : state) ~terminal_rows view =
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let connection_rows = browser_lane_connection_rows view in
  max 0 (framed_content_height ~rows:body_rows - browser_lane_fixed_rows ~connection_rows view)

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
  let connection_rows = browser_lane_connection_rows view in
  let fixed_rows = browser_lane_fixed_rows ~connection_rows view in
  let picker_frame_rows = browser_picker_frame_rows connection_rows in
  let read_status = Browser_lane_view.read_status view in
  let read_style = match read_status with
    | Read_ok -> Theme.ok ()
    | Read_failed -> Theme.bad ()
    | Reading | Operating -> Theme.info ()
    | Unread | Browser_missing -> Theme.recede ()
  in
  let title =
    here_row ~cols state ~path:[ browser_step state ]
      ~readings:
        [ selection_label view ^ " · "
          ^ Option.value (connection_label view) ~default:"no browser"
        ; read_style ^ Browser_lane_view.read_status_label read_status ^ Ansi.reset ]
      ~position:None
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
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
      let status, style = match view.load with
        | Loading (_, Discover _) -> "Reading browser connections…", Theme.info ()
        | Loading (_, Read) ->
            (match browser_label view with
             | Some browser -> "Reading " ^ browser ^ "…"
             | None -> "Reading…"), Theme.info ()
        | Loading (_, Read_refresh) -> "Refreshing browser text…", Theme.info ()
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
        | No_browser -> "Browser bridge not connected", Theme.recede ()
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
      List.iter (fun (style, row) -> c.push_styled ~style row) connection_rows;
      match view.client_picker with
      | Some cursor ->
          c.push_styled ~style:(Theme.info ()) "  Choose browser";
          c.push_divider ();
          let empty_line = browser_lane_picker_empty_line ~ko:(state.ui_language = Lang_ko) view in
          let choices = browser_choices view in
          let room =
            Int.max 1 (budget - picker_frame_rows - List.length (Option.to_list empty_line)) in
          let start = max 0 (cursor - room + 1) in
          choices |> List.iteri (fun index choice ->
            if index >= start && index < start + room then
              let line = "  " ^ Terminal_text.single_line (browser_choice_label choice)
                ^ (if browser_choice_selected view choice then " (current)" else "") in
              if index = cursor then c.push_selected line
              else c.push_styled ~style:Ansi.reset line);
          (* One row whatever the choice, so the rows below do not move with
             the cursor. *)
          let choice = List.nth_opt choices cursor in
          let details = List.filter_map Fun.id
            [Option.bind choice browser_choice_observation;
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
                    | Region _ -> "Region"
                    | Text | Raster | Control _ -> "Element" in
                  Printf.sprintf "  %s %d/%d: %s • n/p:select • y:copy context"
                    label (view.scene_cursor + 1) (List.length (scene_targets view)) (Terminal_text.single_line node.text)
              | None -> "  No observed elements in this viewport • Ctrl-O:image")
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
         | None -> "  No open tabs • Open a page in the selected browser connection"
         | Some tab -> Printf.sprintf "  [%d/%d] %s%s%s  [ / ]:select tab · 1-9:jump"
             (index + 1) tab_count (Terminal_text.single_line tab.title)
             (if tab.active then " (active)" else "")
             (match tab.ego_page with None -> "" | Some page ->
               " · " ^ (match page.label with None -> "unmanaged" | Some label -> Terminal_text.single_line label)
               ^ " · " ^ (match page.opened_by with Masc.Browser_surface.Agent_created -> "agent-created"
                   | Unknown_origin -> "unknown origin")));
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
      let room = max 0 (budget - fixed_rows) in
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
  let title =
    here_row ~cols state
      ~path:[ browser_step state
            ; Terminal_text.single_line history.keeper_name
            ; ui_text state ~ko:"관측" ~en:"observations" ]
      ~readings:[] ~position:None
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:(Masc_tui_keys.footer_hints_browser_observations ~lang:state.ui_language)
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
  let title =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"채널" ~en:"channels" ]
      ~readings:[] ~position:None
  in
  let read_notice = connectors_read_notice state in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    (* Keep the transport keys here: the shared Connectors sheet also names
       keys owned only by Browser Lane. Esc returns to Features & plugins. *)
    ~hints:(ui_text state
      ~ko:"B:Browser Lane  j/k:스크롤  b:연결  u:연결 해제  r:새로고침  Esc:기능"
      ~en:"B:Browser Lane  j/k:scroll  b:bind  u:unbind  r:refresh  Esc:features")
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
              let yes_no flag =
                if flag then ui_text state ~ko:"예" ~en:"yes"
                else ui_text state ~ko:"아니오" ~en:"no"
              in
              let line =
                "  " ^ Masc_tui_table.row (cells
                  ~name:(Terminal_text.single_line connector.cn_display_name)
                  ~configured:(yes_no available)
                  ~reachable:(yes_no connected)
                  ~status:(Terminal_text.single_line (connector_status connector))
                  ~channel:(Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                     connector.cn_channel))
              in
              let style =
                (* Set up and unreachable is the row to act on: it was
                   working. Never configured is dim -- it is a choice, not a
                   fault. *)
                if available && not connected then
                  Theme.bad ()
                else if not available then Ansi.dim
                else Ansi.reset
              in
              if idx = state.connectors_cursor then c.push_selected line
              else c.push_styled ~style line
        done;
        if overflowing then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf
               (if state.ui_language = Lang_ko then "  [커넥터 %s]" else "  [connectors %s]")
               (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
      end)

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
                      Keeper_portrait_equipment.Unavailable "Keeper equipment not observed"
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

(* The plain body's line count and the window the frame shows it in, for the
   keys that scroll it. *)
let context_inspector_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let count =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, _) -> List.length lines
    | Split _ -> 0
  in
  (count, surface_window_height state ~terminal_rows ~count)

(* The split detail column's body line count and its window height, for the
   keys that scroll it. The pinned header row is not theirs to scroll. *)
let context_inspector_detail_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  match context_inspector_content_lines ~cols state with
  | Plain _ -> (0, 0)
  | Split { common; right; _ } ->
      let split_height =
        context_split_pane_height ~content_height:(framed_content_height ~rows)
          ~common_len:(List.length common)
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
  let keeper =
    Option.value ~default:"no Keeper" state.context_inspector_keeper
    |> Keeper_chat.terminal_safe_text
  in
  (* What the numbers describe: a reading in flight, or one received some
     time ago. The pane does not poll, so without the age a reading from
     before the current turn read as the current turn. *)
  let refreshing =
    if state.context_inspector_loading then Ansi.dim ^ "  refreshing" ^ Ansi.reset
    else
      match state.context_inspector_reading, state.context_inspector_read_at with
      | Some _, Some read_at ->
          Ansi.dim ^ "  read " ^ Masc_tui_value.Ongoing.since ~now:(Unix.gettimeofday ()) read_at
          ^ " ago" ^ Ansi.reset
      | Some _, None | None, (Some _ | None) -> ""
  in
  (* The search query, drawn where the typing lands: the Keepers strip's
     own indicator sits on a surface this pane replaced. *)
  let search_marker = search_marker_styled state in
  let tabs =
    tab_strip
      ~width:
        (tab_strip_width ~cols
           ~before:(screen_title " MASC Context" ^ "  " ^ keeper ^ refreshing ^ "  ")
           ~after:search_marker)
      ~press:(fun tab text -> pressable (Press_context_tab tab) text)
      (List.map
         (fun (label, tab) -> (label, state.context_inspector_tab = tab, tab))
         [ ("stack", Masc_tui_context_inspector.Composition)
         ; ("request", Masc_tui_context_inspector.Exact_input)
         ; ("proof", Masc_tui_context_inspector.Input_map)
         ; ("response", Masc_tui_context_inspector.Response)
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
          surface_window_height state ~terminal_rows ~count:(List.length lines)
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
  surface_chrome ~overflow state ~terminal_rows ~cols
    ~surface_key:"context-inspector"
    ~help_door:(Option.is_none state.search)
    ~frame:Chrome_overlay
    ~title:
      (screen_title " MASC Context" ^ "  " ^ keeper ^ refreshing ^ "  " ^ tabs
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
  let retained = function
    | Some page -> Printf.sprintf " · page %d retained" page
    | None -> "" in
  let retry = function
    | Some page -> Printf.sprintf " · r retries page %d" page
    | None -> "" in
  match keeper_peer_status_for_reading state reading with
  | Some (Keeper_peer_loading {page; retained = previous; retry = failed}) ->
      Some (Theme.info (), Printf.sprintf "  Loading page %d%s%s"
        page (retained previous) (retry failed))
  | Some (Keeper_peer_arrived {page; retained = previous; retry = failed}) ->
      Some (Theme.info (), Printf.sprintf "  Page %d response received%s%s · awaiting frame"
        page (retained previous) (retry failed))
  | Some (Keeper_peer_failed {page; retained = previous; reason}) ->
      Some (Theme.warn (), keeper_peer_failure_status ~page ~retained:previous ~reason)
  | Some (Keeper_peer_kept_back {page; retained = previous; notice}) ->
      Some (Theme.warn (), Printf.sprintf "  %s · r retry · page %d%s"
        (Masc.Tui_terminal_text.sanitize_terminal_text notice) page (retained previous))
  | Some (Keeper_peer_current page) ->
      Some (Theme.recede (), Printf.sprintf "  Page %d · queued relationships" page)
  | Some Keeper_peer_unread -> Some (Theme.warn (), "  Relationship page unavailable · r retry")
  | None -> None

let detail_reading_height state reading ~terminal_rows ~count =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  match detail_peer_status state reading with
  | None -> overlay_window_height ~rows ~count
  | Some _ when surface_chrome_budget state ~terminal_rows <= 1 -> 0
  | Some _ -> overlay_window_height ~rows:(rows - 1) ~count

let detail_reading_viewport_at (state : state) reading ~terminal_rows ~cols =
  let count = List.length (detail_reading_document reading ~cols) in
  count, detail_reading_height state reading ~terminal_rows ~count

let detail_reading_viewport (state : state) reading =
  let terminal_rows, cols = get_terminal_size () in
  detail_reading_viewport_at state reading ~terminal_rows ~cols

let render_detail_reading (state : state) reading =
  let terminal_rows, cols = get_terminal_size () in
  let document = Masc_tui_detail_reading.rows_with_search
      ~width:(detail_reading_width cols) reading in
  let count = List.length document in
  let height = detail_reading_height state reading ~terminal_rows ~count in
  let scroll = Masc_tui_detail_reading.scroll ~count ~height reading in
  let source_title = Terminal_text.single_line (Masc_tui_detail_reading.title reading) in
  let title, search_hint = match Masc_tui_detail_reading.search_query reading with
    | None -> source_title, "/:find"
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
        (if editing then "Find " else "") ^ query_label ^ " · " ^ source_title,
        query_label ^ "  " ^
          (if editing then "Enter:keep  Esc:cancel" else "n/N:next/previous  /:find") in
  let hints=Option.value (Masc_tui_detail_reading.hints reading)
      ~default:"j/k:scroll  PgUp/PgDn:page  Home/End:edges  Esc:back" in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state
    ~terminal_rows ~cols ~surface_key:"detail-reading"
    ~title:(screen_title (" " ^ title))
    ~hints:(search_hint ^ "  " ^ hints)
    ~body:(fun ~budget:_ c ->
      Option.iter (fun (style, text) -> c.push_styled ~style text) (detail_peer_status state reading);
      List.iteri (fun index (row,mark) ->
        if index >= scroll && index < scroll + height then
          let text = match row with
            | Masc_tui_detail_reading.Heading text | Content text | Note text -> text in
          match mark with
          | Masc_tui_detail_reading.Current_match ->
              c.push_selected ("> " ^ Masc_tui_theme.strip_sgr text)
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

let palette_count mode count =
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
  let title, prompt, action =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump ->
        (" MASC Command palette", ":", if Option.is_some typed_question then "ask" else "run")
    | Masc_tui_types.Palette_choice { choice_question; choice_line } ->
        let names = List.length (Masc_tui_palette.code_cursor_line_symbols state) in
        ( Printf.sprintf " %s · %s on line %d" choice_question
            (palette_count state.palette_mode names) choice_line
        , "filter:", "ask" )
    | Masc_tui_types.Palette_files _ ->
        (" MASC Find file", "filter:", "open")
    | Masc_tui_types.Palette_branches _ ->
        (" MASC Branches", "filter:", "close")
    | Masc_tui_types.Palette_worktrees _ ->
        (" MASC Worktrees", "filter:", "close")
    | Masc_tui_types.Palette_search _ ->
        (" MASC Search in files", "search:",
         (match Masc_tui_palette.search_enter state with
          | Masc_tui_palette.Enter_opens _ -> "open"
          | Masc_tui_palette.Enter_searches -> "search"))
    | Masc_tui_types.Palette_locations offer ->
        let query = Masc_tui_fetched.request_key offer.clo_query in
        (Printf.sprintf " %s · %s" query.clq_question
           (Terminal_text.single_line query.clq_symbol), "filter:", "open")
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
    match state.palette_mode with
    | Palette_jump | Palette_choice _ -> []
    | Palette_worktrees _ ->
        List.map Terminal_text.single_line
          (match code_worktrees_view state with
           | Masc_tui_fetched.Absent -> [ "Worktrees are no longer active; Esc returns to Code" ]
           | Masc_tui_fetched.Loading -> [ "Reading worktrees" ]
           | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> [ detail ]
           | Masc_tui_fetched.Ready listing ->
               [ Printf.sprintf "%s · %s%s"
                   (palette_count state.palette_mode
                      (List.length listing.Tui_decode.gws_worktrees))
                   (if String.equal listing.gws_root "" then "workspace repository"
                    else listing.gws_root)
                   (if listing.gws_truncated then " · first only" else "") ])
    | Palette_branches _ ->
        List.map Terminal_text.single_line
          (match code_branches_view state with
           | Masc_tui_fetched.Absent -> [ "Branches are no longer active; Esc returns to Code" ]
           | Masc_tui_fetched.Loading -> [ "Reading branches" ]
           | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> [ detail ]
           | Masc_tui_fetched.Ready listing ->
               [ Printf.sprintf "%s · %s%s"
                   (palette_count state.palette_mode
                      (List.length listing.Tui_decode.gbs_branches))
                   (if String.equal listing.gbs_root "" then "workspace checkout"
                    else listing.gbs_root)
                   (if listing.gbs_truncated then " · newest only" else "") ])
    | Palette_search search_origin ->
        List.map Terminal_text.single_line
          (match code_search_current state with
           | None ->
               [ Printf.sprintf "Type at least %d characters, then Enter to search %s"
                   code_search_min_query_bytes
                   (match search_place search_origin with
                    | None -> "the checkout"
                    | Some dir -> "under " ^ dir) ]
           | Some (key, Masc_tui_fetched.Loading) ->
               [ "Searching for " ^ key.css_query ]
           | Some (_, (Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail))) ->
               [ detail ]
           | Some (_, Masc_tui_fetched.Ready search) ->
               (match search.Tui_decode.wss_matches, search.wss_truncated with
                | _, false -> []
                | [], true -> [ "No match could be shown · narrow the text" ]
                | shown, true ->
                    [ Printf.sprintf "Only the first %d are shown · narrow the text"
                        (List.length shown) ])
           | Some (_, Masc_tui_fetched.Absent) -> [])
    | Palette_locations offer ->
        if code_location_offer_current state offer then
          ["Choose a returned file and line · Esc keeps the current reading"]
        else ["These locations are no longer current · Esc returns to Code"]
    | Palette_files _ ->
        let catalog_note = match code_finder_catalog state with
          | Masc_tui_fetched.Absent -> "File finder is no longer active; Esc returns to Code"
          | Masc_tui_fetched.Loading -> "Reading checkout files"
          | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> detail
          | Masc_tui_fetched.Ready catalog ->
              Printf.sprintf "%s · %s"
                (palette_count state.palette_mode
                   (List.length catalog.Tui_decode.wfc_files))
                (if String.equal catalog.wfc_root "" then "workspace checkout"
                 else catalog.wfc_root) in
        let file_notes = match Masc_tui_fetched.current state.code_finder_file with
          | Some (_, Masc_tui_fetched.Loading) -> ["Opening selected file"]
          | Some (_, (Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail))) -> [detail]
          | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Ready _)) -> [] in
        List.map Terminal_text.single_line (catalog_note :: file_notes)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"palette"
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
         "Ctrl-U:clear  Esc:close"
       else
         Printf.sprintf "Enter:%s  Up/Down:select  Home/End:first/last  Ctrl-U:clear  Esc:close"
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
          c.push "   Ask about this symbol in the file open on Code"
      | None ->
          let context = match state.palette_mode with
            | Palette_jump when String.trim state.palette_query = "" ->
                [ui_text state
                   ~ko:"화면·키퍼·Task·게시글·설정 검색"
                   ~en:"Search screens, Keepers, Tasks, posts, or settings"]
            | Palette_search search_origin ->
                (match search_place search_origin with
                 | None -> []
                 | Some dir -> ["In " ^ Terminal_text.single_line dir])
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
                 c.push ("   No matching "
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
  match link_modal_card state with
  | None ->
      surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"link-modal"
        ~frame:Chrome_overlay
        ~title:
          (screen_title " MASC Link preview" ^ "  " ^ Ansi.dim ^ "(no links)"
           ^ Ansi.reset)
        ~hints:(Masc_tui_keys.footer_hints_link_preview_empty ~lang:state.ui_language)
        ~body:(fun ~budget:_ c ->
          c.push "  (no web links found in this conversation to preview)")
  | Some (_url, preview, total_links, content_height, content_lines) ->
      let site = Masc_tui_link_preview.site_label preview in
      let total = List.length content_lines in
      let max_scroll = max 0 (total - content_height) in
      let scroll = max 0 (min state.link_modal_scroll max_scroll) in
      surface_chrome state ~terminal_rows ~cols ~surface_key:"link-modal"
        ~frame:Chrome_overlay
        ~overflow:(Self_scrolled (fun () -> Link_modal_scroll scroll))
        ~title:
          (screen_title " MASC Link preview" ^ "  " ^ Ansi.bold
           ^ Terminal_text.single_line site ^ Ansi.reset)
        ~hints:
          (Masc_tui_link_preview.modal_hints ~total_links
             ~has_image:(Option.is_some preview.Masc_tui_link_preview.image_url))
        ~body:(fun ~budget:_ c ->
          (* Which link of several is the position; a preview taller than
             its rows is read through a window, which then is. *)
          if total_links > 1 then
            c.position
              (Masc_tui_value.Position.row ~selected:(Some state.link_modal_cursor)
                 ~total:total_links);
          Option.iter c.position
            (Masc_tui_value.Position.window ~first:scroll ~shown:content_height ~total);
          List.iteri
            (fun index line ->
              if index >= scroll && index < scroll + content_height then
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
    ~title:(screen_title " MASC Play invite")
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
                   "%sthe QR needs a window of %d columns by %d rows"
                   play_card_indent
                   (window_cols + max 0 (columns - width))
                   (window_rows + max 0 (rows - budget)))
          | Masc_tui_play_card.Blank -> c.push_empty ())
        (Masc_tui_play_card.draw card ~width ~rows:budget))

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
  let lines = keeper_deletions_lines state ~cols in
  let count, height = keeper_deletions_viewport state in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"keeper-deletions"
    ~frame:Chrome_overlay
    ~title:
      (let ko = state.ui_language = Lang_ko in
       screen_title (if ko then " 키퍼 삭제 기록" else " Keeper deletion records")
       ^ (if not state.keeper_deletions_loading then ""
          else if ko then " · 조회/재시도 중" else " · loading/retrying"))
    ~hints:(keeper_deletions_hints state ~scrollable:(count > height))
    (* [keeper_deletions_viewport] rather than the budget it is derived from:
       the keypress bounds the scroll against that pair. *)
    ~body:(fun ~budget:_ c ->
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

let queue_panel_item_identity = function
  | Masc_tui_queue_inspection.Local_message id -> "Local message: " ^ id
  | Server_message id -> "Queued message: " ^ id
  | Running_message id -> "Running message: " ^ id
  | Event (reference, revision) ->
    Printf.sprintf "Event: %s · incarnation %Ld" reference revision
  | Schedule (id, instance) -> "Schedule: " ^ id ^ " · instance " ^ instance

let queue_panel_detail_lines state (panel : queue_panel) ~cols =
  let reading = queue_panel_detail_reading ~items:(queue_panel_items state panel) panel in
  let content = match reading with
    | Queue_detail_ready (id, item) ->
      queue_panel_item_identity id ^ "\n\n" ^ item.text
    | Queue_detail_loading -> "Queue request in progress. The current server item is unavailable until it finishes."
    | Queue_detail_unavailable reason ->
      "This server item is unavailable in the current queue observation. Return to the list and refresh."
      ^ Option.fold ~none:"" ~some:(fun detail -> "\n\n" ^ detail) reason
    | Queue_detail_missing -> "This item is no longer in the current queue. Return to the list and refresh."
    | Queue_detail_none -> "No item is selected." in
  Message_layout.wrap_body ~max_cells:(max 1 (framed_inner_width cols - 2))
    ~sanitize:Terminal_text.single_line content

let queue_panel_detail_viewport state panel =
  let terminal_rows, cols = get_terminal_size () in
  let count = List.length (queue_panel_detail_lines state panel ~cols) in
  let budget = surface_chrome_budget state ~terminal_rows in
  let height = queue_panel_window_height ~budget in
  count, height

let queue_panel_layout state (panel : queue_panel) =
  let terminal_rows, cols = get_terminal_size () in
  let has_context = view_is_chat state.view
      && state.msg_target_keeper_name = Some panel.qp_keeper
      && Option.is_none panel.qp_detail in
  Masc_tui_queue_layout.choose panel.qp_layout ~has_context ~cols
    ~body_rows:(surface_chrome_budget state ~terminal_rows)
    (* Reserve status, a possible receipt and a possible selection note when
       choosing placement, so selecting or receiving a result does not move it. *)
    ~queue_fixed_rows:3
    ~queue_item_rows:(List.length (queue_panel_items state panel))

let queue_panel_list_budget state panel =
  let terminal_rows, _ = get_terminal_size () in
  Masc_tui_queue_layout.queue_rows
    ~body_rows:(surface_chrome_budget state ~terminal_rows) (queue_panel_layout state panel)

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
  let title label = screen_title label ^ "  " ^ Terminal_text.single_line panel.qp_keeper
    ^ (if Option.is_some panel.qp_detail then "" else match panel.qp_layout with
       | Masc_tui_queue_layout.Adaptive -> " · automatic"
       | Expanded -> " · full") in
  let owner () = Queue_panel_presented
      (queue_panel_owner state panel ~viewport:(queue_panel_viewport state panel)) in
  if Option.is_some panel.qp_detail then
    let lines = queue_panel_detail_lines state panel ~cols in
    surface_chrome ~overflow:(Self_scrolled owner) state ~terminal_rows ~cols
      ~surface_key:"keeper-queue-detail" ~frame:Chrome_overlay
      ~title:(title " MASC Queue item")
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
  else
  let placement = queue_panel_layout state panel in
  let context_caption =
    let partial = Option.is_some state.msg_loaded_error || state.msg_loaded_dropped > 0
        || Option.is_some state.msg_memory_error || state.msg_memory_dropped > 0
        || Option.is_some state.msg_older_error in
    if partial then "Partial conversation · Esc:full chat"
    else if state.msg_older_loading || Option.is_some state.msg_history_inflight then
      "Reading conversation · Esc:full chat"
    else "Conversation preview · Esc:full chat" in
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
    "Workspace unconfirmed; any receipt is from the previous observation"
  else match panel.qp_reading, panel.qp_notice with
    | Queue_loading, _ -> "Reading or sending"
    | (Queue_current | Queue_unavailable), Some (Queue_info text | Queue_error text) -> Terminal_text.single_line text
    | Queue_current, None ->
      (match panel.qp_observation with
       | Some {waiting=Ok _; operations=Ok _; _} -> "Queue read · r refreshes"
       | Some {waiting=Ok _; operations=Error _; _} -> "Inventory read · server messages unavailable"
       | Some {waiting=Error _; operations=Ok _; _} -> "Server messages read · inventory unavailable"
       | Some {waiting=Error _; operations=Error _; _} -> "Both server reads unavailable · r retries"
       | None -> "Queue observation unavailable · r retries")
    | Queue_unavailable, None -> "Snapshot unavailable · r retries" in
  let hints = Masc_tui_keys.footer_hints_queue state panel in
  let frame, clamped = surface_chrome ~overflow:(Self_scrolled owner) state ~terminal_rows ~cols
    ?sidebar
    ~surface_key:"keeper-queue" ~frame:Chrome_overlay
    ~title:(title " MASC Queue")
    ~hints
    ~body:(fun ~budget c ->
      (match placement with
       | Masc_tui_queue_layout.Bottom {context_rows; queue_rows=_} ->
           c.push context_caption;
           let lines = context_lines ~cols:(framed_inner_width cols) ~height:(context_rows-1) in
           List.iter c.push lines;
           for _ = List.length lines to context_rows - 2 do c.push_empty () done;
           c.push_divider ()
       | Full | Side _ -> ());
      let budget = Masc_tui_queue_layout.queue_rows ~body_rows:budget placement in
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
                Terminal_text.single_line (queue_panel_item_identity id)) item.id
            else text in
          let row = marker ^ (if selected then Theme.info () else "") ^ text ^ Ansi.reset in
          let row = if selected && queue_selection_visible
              ~inner_width:(framed_inner_width queue_cols) ~marker ~text then
              match queue_selection_for_item state panel item with
              | Some authority -> pressable (Press_queue_selected authority) row
              | None -> row
            else row in
          c.push row
        end) items;
      if items <> [] then
        c.position
          (Masc_tui_value.Position.row ~selected:selected_index
             ~total:(List.length items))) in
  (* Shared chrome has three leading rows and two trailing rows. Its body
     copies as separate documents, even though the terminal writes one row. *)
  frame_panes := Masc_tui_queue_layout.panes placement ~cols
      ~first_row:(strip_rows + surface_chrome_rows - 1)
      ~body_rows:(surface_chrome_budget state ~terminal_rows);
  frame, clamped

(* The answering overlay, through the overlay contract. Drawn by hand, a short
   list closed the box right under the preview panel, so the footer stood on
   row 10 of a 26-row terminal. The list now fills its height, the preview
   panel sits on the frame's last rows, and the frame fills nothing because
   nothing is left. Its title was "Live Keeper Turns & Answering" with a half
   circle glyph; the key table names the overlay "answering". *)
let render_answering (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = answering_lines state in
  let paint ~selected (line : Masc_tui_answering.line) =
    let tone_prefix =
      match line.Masc_tui_answering.tone with
      | Masc_tui_answering.Heading -> Ansi.bold
      | Masc_tui_answering.Running -> (Theme.info ())
      | Masc_tui_answering.Done -> Theme.ok ()
      | Masc_tui_answering.Unknown -> Theme.warn ()
      | Masc_tui_answering.Quiet -> Ansi.dim
    in
    (* The cursor is a gutter caret, not a full-row band: the row keeps its
       tone, and rows Enter cannot act on never wear the caret. *)
    let caret =
      if selected && Option.is_some line.Masc_tui_answering.target then Masc_tui_theme.Glyph.current_entry ^ " "
      else "  "
    in
    caret ^ tone_prefix ^ line.Masc_tui_answering.text ^ Ansi.reset
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
            c.push (paint ~selected:(i = state.answering_cursor) line)
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
            (* Full-width adaptive selection band rather than leading glyph:
               rows are already fitted to the column. *)
            if selected = Some index then
              c.push_selected (Masc_tui_theme.strip_sgr line.Agenda.text)
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
                 else "Resize to confirm quit")
           | None when Masc_tui_action_notice.csi_active state.last_action
                       || Option.is_some (Masc_tui_action_notice.rejection state.last_action
                            ~now ~window) -> None
           | None -> Some "Quit changed; retry")
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
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"account-login" ~title:(screen_title " MASC Account Login")
    ~hints:(Masc_tui_account_login.hints view)
    ~body:(fun ~budget c ->
      let lines, position =
        Masc_tui_account_login.visible_lines ~height:budget ~width:(framed_inner_width cols) view in
      Option.iter c.position position;
      let lines = lines
        |> List.map (function
          | Masc_tui_account_login.Text text -> Masc.Tui_terminal_text.sanitize_terminal_text text
          | Masc_tui_account_login.Terminal line ->
            Masc_tui_sgr_text.render ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text line) in
      List.iter (fun line -> c.push (fit_width line (framed_inner_width cols))) lines)

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
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"collab" ~title:(screen_title " MASC Collab")
    ~hints:(Masc_tui_collab.hints view)
    ~body:(fun ~budget c ->
      Option.iter c.position (Masc_tui_collab.position view);
      Masc_tui_collab.lines ~height:budget ~width:(framed_inner_width cols) view
      |> List.iter (fun line -> c.push (fit_width line (framed_inner_width cols))))

let render_lane_addons state (view : Masc_tui_lane_addons.t) =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols ~surface_key:"lanes"
    ~title:(screen_title " MASC Plugins")
    ~hints:(if Option.is_some view.evidence_prompt then "j/k:choose  Enter:preserve  Esc:back"
      else if Option.is_some view.subscription_panel then "j/k:select  Enter:choose/save  a:add  d:remove  J/K:scroll  r:refresh  Esc:back"
      else if Option.is_some view.installer then Option.fold ~none:"" ~some:Masc_tui_lane_installer.hints view.installer
      else if Option.exists Masc_tui_lane_records.text_entry_open view.records
        then "Tab:field  Left/Right:choice  Ctrl-S:review  PageUp/Down:scroll  Esc:cancel"
      else if Option.is_some view.records then "j/k:select  a:add  d:remove  PageUp/Down:scroll  Esc:back; then s saves"
      else if Option.exists (fun (menu : Masc_tui_lane_addons.action_menu) -> Option.is_some menu.form) view.action_menu
        then "Tab:field  Left/Right:choice  Ctrl-E:items  Ctrl-U:unset  Ctrl-S:review  Esc:cancel"
      else if Option.is_some view.action_menu then "j/k:choose action  Enter:run once  J/K:scroll details  Esc:cancel"
      else String.concat "  " (Masc_tui_lane_addons.overview_hints view))
    ~body:(fun ~budget c ->
      let lines = Masc_tui_lane_addons.lines ~height:budget ~width:(framed_inner_width cols) view in
      let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height:budget view.scroll in
      Option.iter c.position
        (Masc_tui_value.Position.window ~first:scroll ~shown:budget ~total:(List.length lines));
      lines
      |> List.filteri (fun index _ -> index >= scroll && index < scroll + budget)
      |> List.iter c.push)


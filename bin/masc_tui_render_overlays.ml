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
    ~surface_key:"about" ~title:(screen_title " MASC") ~hints:"c:candle  Esc:close"
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
          [ Masc_tui_theme.tone Masc_tui_theme.Accent
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
    ~cursor:Frame_presenter.Hidden ~rows:terminal_rows ~cols
    ~footer:
      (Footer_hints
         { hints = Masc_tui_keys.keeper_navigation_hints; position = None })
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
          let age = Float.max 0. (Unix.gettimeofday () -. read_at) in
          Ansi.dim ^ "  read " ^ Masc_tui_message_layout.span_text age ^ " ago" ^ Ansi.reset
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
  let hints =
    let module Inspector = Masc_tui_context_inspector in
    let turn_hint = match state.context_inspector_target with
      | Inspector.Recent _ -> "[ / ]:turn  "
      | Inspector.Pinned _ -> "" in
    match state.context_inspector_tab, state.context_inspector_exact with
    | Inspector.Response, _ ->
        "1/2/3/4 or Tab:switch  " ^ turn_hint
        ^ "j/k:scroll  PgUp/PgDn:page  Home/End:top/bottom  r:refresh  Esc:return"
    | (Inspector.Composition | Inspector.Exact_input | Inspector.Input_map), Some _ ->
        "4:response  j/k:scroll  Esc:list"
    | (Inspector.Exact_input | Inspector.Input_map), None ->
        "1/2/3/4 or Tab:switch  " ^ turn_hint
        ^ (if cols >= keeper_split_threshold_cols then
             "/:search  j/k:select or scroll  h/l:pane  Enter:open exact  "
           else "/:search  j/k:select  Enter:open exact  ")
        ^ "r:refresh  Esc:close"
    | Inspector.Composition, None ->
        "1/2/3/4 or Tab:switch  " ^ turn_hint ^ "j/k:scroll  r:refresh  Esc:close"
  in
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
            context_split_lines ~cols ~left_width:(context_split_width cols)
              ~left:
                (context_split_window ~height:body_height ~offset:left_offset
                   (List.tl left))
              ~right:
                (context_split_window ~height:body_height ~offset:right_offset
                   (List.tl right))
            |> List.iter c.push
          end)

(* The height an overlay shows [count] rows in, for the overlays that say
   which of their lines are showing: one row comes off when they overflow,
   because the "[lines a-b/n]" row is drawn inside the same body.
   [Masc_tui_scroll.content_height] owns that rule; the frame supplies the
   chrome. *)
let overlay_window_height ~rows ~count =
  Masc_tui_scroll.content_height ~rows ~chrome:framed_chrome_rows ~count
    ~preview_keep:None ~overflow_takes_row:true

(* The "[lines a-b/n]" row an overflowing overlay draws under its rows, or
   nothing when every row fits. The row's height is the one
   [overlay_window_height] took off. *)
let overlay_window_row ~scroll ~height count =
  Option.map
    (fun row -> Theme.recede () ^ row ^ Ansi.reset)
    (Masc_tui_scroll.position_row ~scroll ~height count)

let detail_reading_width cols = max 1 (framed_inner_width cols - 2)
let detail_reading_document reading ~cols =
  Masc_tui_detail_reading.rows ~width:(detail_reading_width cols) reading

let detail_reading_viewport (state : state) reading =
  let terminal_rows, cols = get_terminal_size () in
  let count = List.length (detail_reading_document reading ~cols) in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  count, overlay_window_height ~rows ~count

let render_detail_reading (state : state) reading =
  let terminal_rows, cols = get_terminal_size () in
  let document = detail_reading_document reading ~cols in
  let count, height = detail_reading_viewport state reading in
  let scroll = Masc_tui_detail_reading.scroll ~count ~height reading in
  let source_title = Terminal_text.single_line (Masc_tui_detail_reading.title reading) in
  let title, search_hint = match Masc_tui_detail_reading.search_query reading with
    | None -> source_title, "/:find"
    | Some query ->
        let query_label = Printf.sprintf "/%s (%d)"
          (Terminal_text.single_line query)
          (Masc_tui_detail_reading.search_count ~width:(detail_reading_width cols) reading) in
        let editing = Masc_tui_detail_reading.search_editing reading in
        (* The footer can collapse to its help door. Keep the query with the
           document too, ahead of its title so narrow readers can see it. *)
        (if editing then "Find " else "") ^ query_label ^ " · " ^ source_title,
        query_label ^ " " ^
          (if editing then "Enter:keep Esc:cancel" else "n/N:next/previous /:find") in
  let hints=Option.value (Masc_tui_detail_reading.hints reading)
      ~default:"j/k:scroll  PgUp/PgDn:page  Home/End:edges  Esc:back" in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state
    ~terminal_rows ~cols ~surface_key:"detail-reading"
    ~title:(screen_title (" " ^ title))
    ~hints:(search_hint ^ "  " ^ hints)
    ~body:(fun ~budget:_ c ->
      List.iteri (fun index row ->
        if index >= scroll && index < scroll + height then
          match row with
          | Masc_tui_detail_reading.Heading text -> c.push_styled ~style:Ansi.bold ("  " ^ text)
          | Content text -> c.push ("  " ^ text)
          | Note text -> c.push_styled ~style:(Theme.recede ()) ("  " ^ text)) document;
      Option.iter c.push (overlay_window_row ~scroll ~height count))

(* The sheet's rows and the viewport that shows them, at this width. One
   answer for the two readers -- the keypress that bounds the scroll and the
   frame that draws it -- so [G] cannot land the scroll a row past what the
   frame is showing, and a press the frame cannot spend is not taken. *)
let help_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let header = help_masthead state in
  let count =
    List.length
      (Masc_tui_help.sheet ~header ~cols
         (help_lines ~width:(Masc_tui_help.line_cells ~cols) state))
  in
  (count, overlay_window_height ~rows ~count)

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
    | Masc_tui_types.Palette_locations _ -> None
  in
  let explicit_question =
    match typed_question with
    | Some (question, Some symbol) -> Some (question, symbol)
    | Some (_, None) | None -> None
  in
  let matches = Masc_tui_palette.palette_matches state in
  let total = List.length matches in
  let cursor = max 0 (min state.palette_cursor (total - 1)) in
  let origin =
    if Option.is_some state.lane_addons then "Lane Add-ons"
    else match List.find_opt (fun (_, surface) -> surface = state.view)
        Masc_tui_keys.help_surfaces with
      | Some (title, _) -> title
      | None -> "current screen"
  in
  let title, prompt, action =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump ->
        (" MASC Command palette", ":", if Option.is_some typed_question then "ask" else "run")
    | Masc_tui_types.Palette_choice { choice_question; choice_line } ->
        let names = List.length (Masc_tui_palette.code_cursor_line_symbols state) in
        ( Printf.sprintf " %s · %d names on line %d" choice_question names choice_line
        , "filter:", "ask" )
    | Masc_tui_types.Palette_files _ ->
        (" MASC Find file", "filter:", "open")
    | Masc_tui_types.Palette_locations offer ->
        let query = Masc_tui_fetched.request_key offer.clo_query in
        (Printf.sprintf " %s · %s" query.clq_question
           (Terminal_text.single_line query.clq_symbol), "filter:", "open")
  in
  (* The title names the palette the way the key table does (":" command
     palette) and the prompt follows it. It was "Quick Jump & Navigation" with
     a lightning glyph between them: the glyph said nothing, and the entries
     are not all jumps -- settings, the gate modes, a task or a post run from
     the same list, which is why Enter reads "run".

     The overlay contract draws the box and fills the rows under a short list
     of matches, so the footer stays on the composer's row. *)
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
    | Palette_locations offer ->
        if code_location_offer_current state offer then
          ["Choose a returned file and line · Esc keeps the current reading"]
        else ["These locations are no longer current · Esc returns to Code"]
    | Palette_files _ ->
        let catalog_note = match code_finder_catalog state with
          | Masc_tui_fetched.Absent -> "File finder is no longer active; Esc returns to Code"
          | Masc_tui_fetched.Loading -> "Reading checkout files…"
          | Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail) -> detail
          | Masc_tui_fetched.Ready catalog ->
              Printf.sprintf "%d files · %s" (List.length catalog.Tui_decode.wfc_files)
                (if String.equal catalog.wfc_root "" then "workspace checkout"
                 else catalog.wfc_root) in
        let file_notes = match Masc_tui_fetched.current state.code_finder_file with
          | Some (_, Masc_tui_fetched.Loading) -> ["Opening selected file…"]
          | Some (_, (Masc_tui_fetched.Failed detail | Masc_tui_fetched.Stale (_, detail))) -> [detail]
          | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Ready _)) -> [] in
        List.map Terminal_text.single_line (catalog_note :: file_notes)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"palette"
    ~frame:Chrome_overlay
    ~title:
      (title ^ prompt ^ query
       ^ Masc_tui_theme.tone Masc_tui_theme.Accent ^ caret ^ Ansi.reset)
    (* [key:label] items, two spaces apart, the way every other footer is
       written. In the dotted form this row was one item with no colon, so
       {!Masc_tui_footer} could shed no whole key and keep no door: it fell
       through to the cell cut, where [Esc] survived only when the budget
       happened to reach it. test_a_row_in_another_grammar_loses_its_door
       measures that across widths. The count keeps no colon on purpose --
       it is not a key, and it is the first thing a narrow row should give
       up. *)
    ~hints:
      (Printf.sprintf "%d/%d  Enter:%s  Up/Down:select  Home/End:first/last  Ctrl-U:clear  Esc:close"
         (if total = 0 then 0 else cursor + 1)
         total action)
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        ("   From " ^ origin ^ " · Esc returns here");
      List.iter (fun note -> c.push ("   " ^ note)) finder_notes;
      match explicit_question with
      | Some (question, symbol) ->
          c.push_selected (" " ^ Masc_tui_theme.Glyph.current_entry ^ " " ^ question ^ " "
            ^ Terminal_text.single_line symbol);
          c.push "   Ask about this symbol in the file open on Code"
      | None ->
          let kind = match state.palette_mode with
            | Palette_files _ -> "files" | Palette_locations _ -> "locations"
            | Palette_jump | Palette_choice _ -> "commands" in
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "   %d %s · %d/%d · type to filter"
              total kind
              (if total = 0 then 0 else cursor + 1) total);
          let list_rows = max 0 (budget - 2 - List.length finder_notes) in
          let first = max 0 (cursor - list_rows + 1) in
          matches
          |> List.filteri (fun i _ -> i >= first && i < first + list_rows)
          |> List.iteri (fun visible_index (label, _) ->
               if first + visible_index = cursor then
                 c.push_selected (" " ^ Masc_tui_theme.Glyph.current_entry ^ " " ^ Terminal_text.single_line label)
               else c.push ("   " ^ Terminal_text.single_line label));
          if total = 0 then
            (match state.palette_mode, code_finder_catalog state with
             | Palette_files _, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                 | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Stale _) -> ()
             | (Palette_files _ | Palette_locations _ | Palette_jump | Palette_choice _),
               (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Ready _
               | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Stale _) ->
                 c.push ("   No matching " ^ kind ^ " · Ctrl-U clears the filter")))

(* The patch review overlay. [surface_chrome] owns the box, the fill and the
   footer's row, so the rows are not counted here and the keys on screen are
   the footer's alone. *)
(* The diff's rows and the rows the overlay shows, computed once for the
   renderer that draws them and the keys that scroll them. The keys used to
   move ten rows whatever the window was, and to reach the end by leaving five
   rows on screen -- a number the renderer's own clamp then corrected, which is
   why it went unnoticed. *)
let patch_modal_horizontal_limit (state : state) =
  let _, cols = get_terminal_size () in
  let width = framed_inner_width cols in
  match state.patch_modal_diff with
  | None -> 0
  | Some (_, diff) ->
      List.fold_left
        (fun limit row ->
          let body_width = max 1 (width - Message_layout.display_width (tree_diff_gutter row)) in
          let cells =
            Message_layout.display_width (Terminal_text.single_line row.Tui_decode.gdr_text)
          in
          max limit (max 0 (cells - body_width)))
        0 diff.Tui_decode.gd_rows
;;

let patch_modal_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let diff_opt =
    match state.patch_modal_diff with
    | Some (_, d) -> Some d
    | None -> None
  in
  let total =
    match diff_opt with
    | Some diff -> List.length diff.Masc.Tui_decode.gd_rows
    | None -> 0
  in
  (* The column heading and the divider under it open the body. *)
  let heading_rows = 2 in
  ( total
  , Masc_tui_scroll.content_height
      ~rows:(Masc_tui_types.surface_body_rows state ~terminal_rows)
      ~chrome:(surface_chrome_rows + heading_rows) ~count:total
      ~preview_keep:None ~overflow_takes_row:true )

let render_patch_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let path_label =
    match state.patch_modal_path with
    | Some p -> p
    | None -> "Active Working Tree"
  in
  let diff_opt =
    match state.patch_modal_diff with
    | Some (_, d) -> Some d
    | None -> None
  in
  let diff_rows =
    match diff_opt with
    | Some diff -> diff.Masc.Tui_decode.gd_rows
    | None -> []
  in
  let total, content_height = patch_modal_viewport state in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.patch_modal_scroll max_scroll) in
  let limit = patch_modal_horizontal_limit state in
  let hscroll = max 0 (min state.patch_modal_hscroll limit) in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"patch-modal"
    ~frame:Chrome_overlay
    ~overflow:(Self_scrolled (fun () -> Patch_modal_scroll (scroll, hscroll)))
    ~title:
      (screen_title " MASC Patch review" ^ "  " ^ Ansi.bold
       ^ Terminal_text.single_line path_label ^ Ansi.reset)
    ~hints:(Masc_tui_keys.footer_hints_patch_review ())
    ~body:(fun ~budget:_ c ->
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  old / new · col %d/%d" (hscroll + 1) (limit + 1));
      c.push_divider ();
      if total = 0 then
        c.push
          (Ansi.dim
           ^ (match state.patch_modal_error with
              | Some e ->
                  Printf.sprintf "   (diff load error: %s)" (Terminal_text.single_line e)
              | None ->
                  (match diff_opt with
                   | None -> "   (reading patch diff…)"
                   | Some _ -> "   (no pending patch diff loaded)"))
           ^ Ansi.reset)
      else begin
        let width = framed_inner_width cols in
        List.iteri
          (fun index row ->
            if index >= scroll && index < scroll + content_height then
              c.push
                (fit_width
                   (Masc_tui_span.render (tree_diff_row_span ~hscroll ~width row))
                   width))
          diff_rows
      end;
      (* The window's position is a body row, as on the other overlays, and
         [patch_modal_viewport] took its row off when the diff overflows. *)
      Option.iter c.push (overlay_window_row ~scroll ~height:content_height total))

(* The link preview overlay, through the same contract. The title names the
   site, so the footer carries only keys. *)
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
      (* Which link of several, and the divider under it. *)
      let nav_rows = if total_links > 1 then 2 else 0 in
      let content_height =
        max 1
          (Masc_tui_types.surface_body_rows state ~terminal_rows
           - surface_chrome_rows - nav_rows)
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
        ~hints:"Esc:close"
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
          if total_links > 1 then begin
            c.push_styled ~style:(Theme.warn ())
              (Printf.sprintf "  link %d of %d" (state.link_modal_cursor + 1)
                 total_links);
            c.push_divider ()
          end;
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
                          report = (fun scroll -> Play_invite_scroll scroll) })
    state ~terminal_rows ~cols ~surface_key:"play-invite"
    ~frame:Chrome_overlay
    ~title:(screen_title " MASC Play invite")
    ~hints:"j/k:scroll  y:copy link  Esc:close"
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
      (screen_title " 키퍼 삭제 기록"
       ^ (if state.keeper_deletions_loading then " · 조회/재시도 중" else ""))
    ~hints:(keeper_deletions_hints state ~scrollable:(count > height))
    (* [keeper_deletions_viewport] rather than the budget it is derived from:
       the keypress bounds the scroll against that pair. *)
    ~body:(fun ~budget:_ c ->
      let scroll =
        Masc_tui_scroll.normalize ~count ~height state.keeper_deletions_scroll
      in
      List.iteri
        (fun index text ->
          if index >= scroll && index < scroll + height then c.push text)
        lines;
      (* The record is one JSON document. Measured on the live server, it ran
         past every height: at 44 rows it ended mid-object on "kind":
         "delivered", and the footer named the scroll keys without saying how
         far they had to go. *)
      Option.iter c.push (overlay_window_row ~scroll ~height count))

(* The cheat sheet, through the overlay contract. It drew its box and its rows
   by hand and closed the box under the last row, so a sheet shorter than the
   screen -- a narrow filter, a tall terminal -- put the footer mid-screen. *)
let render_help (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let header = help_masthead state in
  let rendered_rows =
    Masc_tui_help.sheet ~header ~cols
      (help_lines ~width:(Masc_tui_help.line_cells ~cols) state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"help"
    ~frame:Chrome_overlay
    (* The title says what state the sheet is in; the keys that change it are
       the footer's, which draws h and Esc on this overlay and never drops Esc.
       Both rows spelled them, so the title said the footer twice. *)
    ~title:
      (screen_title " MASC Cheat Sheet" ^ "  " ^ Ansi.dim
      ^ "hints "
      ^ (if state.hints_visible then "on" else "off")
      ^ Ansi.reset)
    (* The sheet that names every other surface's keys did not name its own.
       It is longer than any terminal -- at 150x78 the later sections are
       still off screen -- so [G] is the difference between reading them and
       pressing [j] forty times, and nothing said [G] exists. The keys are
       handled at masc_tui.ml: "pageup" | "pagedown", "g", "G". *)
    ~hints:"j/k:scroll  PgUp/PgDn:page  g/G:first/last  h:hints  Esc:close"
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
      Option.iter c.push (overlay_window_row ~scroll ~height count))

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
          | "" -> "(no text reported yet)"
          | tail -> tail
        in
        let preview_width = framed_inner_width cols in
        let name_width = min (Masc_tui_message_layout.display_width (Terminal_text.single_line keeper_name))
          (max 0 ((preview_width - 2) / 2)) in
        [ Ansi.bold ^ fit_width (Terminal_text.single_line keeper_name) name_width
          ^ Ansi.reset ^ "  " ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
          ^ fit_width doing (max 0 (preview_width - name_width - 2))
          ^ Ansi.reset
        ; Ansi.dim ^ tail ^ Ansi.reset
        ]
    | None ->
        [ Ansi.dim ^ "live preview \xe2\x80\x94 none for this row" ^ Ansi.reset
        ; ""
        ]
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"answering"
    ~frame:Chrome_overlay
    (* Enter and Esc are in the footer row below this overlay. *)
    ~title:(screen_title " MASC Answering")
    ~hints:"j/k:move  PgUp/PgDn:page  Home/End  Enter:chat  Esc:close"
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
         the list above never reflows with the cursor. The rule over it says
         which of the list's rows are showing when they overflow, so it costs
         the list no row (#38623). *)
      (match overlay_window_row ~scroll ~height:content_height (List.length lines) with
       | Some row -> c.push row
       | None -> c.push_divider ());
      List.iter c.push preview_lines)
;;

(* The agenda, through the overlay contract. Its sections are usually a few
   rows, and drawn by hand the box closed under them: the footer stood on row
   11 of a 26-row terminal with the composer alone at the bottom. The title was
   "Agenda & Upcoming Timers"; the sections are what is coming up and what is
   waiting on the operator, and the other overlays open on MASC and their name. *)
let render_agenda (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let lines = agenda_lines state in
  let selected = Agenda.selected_index lines ~selected:state.agenda_selected in
  let paint ~selected (line : Agenda.line) =
    let body =
      match line.Agenda.tone with
      | Agenda.Heading -> Ansi.bold ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Wake -> (Theme.recede ()) ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Question -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Quiet -> Ansi.dim ^ line.Agenda.text ^ Ansi.reset
      | Agenda.Failed -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
    in
    (* Reversed rather than marked with a glyph: the rows are already fitted
       to the column and a leading mark would push the right half off. *)
    if selected then Ansi.reverse ^ body ^ Ansi.reset else body
  in
  (* A panel with nothing to open says so on its own footer rather than
     naming a key that would do nothing. *)
  let hints =
    match Agenda.target_indexes lines with
    | [] -> "j/k:scroll  PgUp/PgDn:page  g/G:first/last  Esc:close"
    | _ -> "j/k:move  PgUp/PgDn:page  g/G:first/last  Enter:open  Esc:close"
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"agenda"
    ~frame:Chrome_overlay
    ~title:(screen_title " MASC Agenda")
    ~hints
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
            c.push (paint ~selected:(selected = Some index) line))
        lines;
      (* What falls off this panel is not more of the same: measured at 24
         rows and 100 columns, the panel drew sixteen of its twenty coming
         rows and neither of the two sections under them, and nothing said
         "Waiting on you" and "Stuck on you" were there. *)
      Option.iter c.push (overlay_window_row ~scroll ~height count))
;;

let render_terminal_too_small state ~rows ~cols =
  (* The hint names physical terminal rows, whereas the guard receives the
     body after navigation, agenda, and composer allocation. At the minimum
     body size the composer can be absent; evaluate its policy at the proposed
     surface size rather than copying the current tiny viewport's overhead. *)
  let surface_rows =
    Render_schedule.Viewport.minimum_fixed_chrome_rows
    + Masc_tui_types.agenda_chrome_rows state
  in
  let minimum_terminal_rows =
    navigation_rows + surface_rows
    + Masc_tui_composer.rows_for ~terminal_rows:surface_rows
  in
  let buf = Buffer.create 64 in
  Buffer.add_string buf
    (fit_width
       (Printf.sprintf "terminal too small -- resize to at least %d rows; q: quit"
          minimum_terminal_rows)
       cols);
  Buffer.add_char buf '\n';
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
      let lines = Masc_tui_account_login.visible_lines ~height:budget ~width:(framed_inner_width cols) view
        |> List.map (function
          | Masc_tui_account_login.Text text -> Masc.Tui_terminal_text.sanitize_terminal_text text
          | Masc_tui_account_login.Terminal line ->
            Masc_tui_sgr_text.render ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text line) in
      List.iter (fun line -> c.push (fit_width line (framed_inner_width cols))) lines)


let render_collab state view =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols
    ~surface_key:"collab" ~title:(screen_title " MASC Collab")
    ~hints:(Masc_tui_collab.hints view)
    ~body:(fun ~budget c ->
      Masc_tui_collab.lines ~height:budget view
      |> List.iter (fun line -> c.push (fit_width
          (Masc.Tui_terminal_text.sanitize_terminal_text line) (framed_inner_width cols))))

let render_lane_addons state (view : Masc_tui_lane_addons.t) =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor ~frame:Chrome_overlay state ~terminal_rows ~cols ~surface_key:"lanes"
    ~title:(screen_title " MASC Lane Add-ons")
    ~hints:(if Option.is_some view.evidence_prompt then "j/k:choose  Enter:preserve  Esc:back"
      else if Option.is_some view.subscription_panel then "j/k:select  Enter:choose/save  a:add  d:remove  J/K:scroll  r:refresh  Esc:back"
      else if Option.is_some view.installer then Option.fold ~none:"" ~some:Masc_tui_lane_installer.hints view.installer
      else if Option.exists (fun (menu : Masc_tui_lane_addons.action_menu) -> Option.is_some menu.form) view.action_menu
        then "Tab:field  Left/Right:choice  Ctrl-E:items  Ctrl-U:unset  Ctrl-S:review  Esc:cancel"
      else if Option.is_some view.action_menu then "j/k:choose action  Enter:run once  J/K:scroll details  Esc:cancel"
      else Masc_tui_lane_addons.overview_hints view)
    ~body:(fun ~budget c ->
      let lines = Masc_tui_lane_addons.lines ~height:budget ~width:(framed_inner_width cols) view in
      let scroll = Masc_tui_scroll.normalize ~count:(List.length lines) ~height:budget view.scroll in
      lines
      |> List.filteri (fun index _ -> index >= scroll && index < scroll + budget)
      |> List.iter c.push)


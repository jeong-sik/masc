(** Rendering primitives shared across the surfaces.

    Every value here is reached by at least 10 of the screen
    renderers, and the set is closed: nothing in it refers back to a
    single surface's code. That is what lets it compile before them. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi





(* Every surface lays out against a viewport one row shorter than the
   terminal: the top row belongs to the surface strip, prepended when a frame
   is finished. Shadowing the probe here (and, via open order, in masc_tui.ml)
   keeps all sixteen surfaces' row budgets and the input layer's paging math
   in step without touching each formula. *)
(* The columns the Activity pane holds on the right of the current frame.
   [render] sets it once per frame from the reader's preference and the
   terminal's width, so every surface that reads [get_terminal_size] below
   lays out beside the pane without knowing it is there, and the input
   layer's paging math (which reads the same probe) agrees with the drawn
   frame. Zero when the pane is hidden, too narrow, or the surface is the
   Activity feed itself. *)

module Agenda = Masc_tui_agenda
module Ask_projection = Masc_tui_ask_projection
module Browser_lane_layout = Masc_tui_browser_lane_layout
module Chart = Masc_tui_chart
module Diff = Masc_tui_diff
module Keeper_chat = Masc_tui_keeper_chat_projection
module Magnitude = Masc_tui_magnitude
module Render_schedule = Masc_tui_render_schedule
module Retained_view = Masc_tui_retained_view
module Span = Masc_tui_span
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Frame_presenter = Masc_tui_frame_presenter
module Status = Masc.Keeper_status_runtime
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Keeper_control = Masc_tui_keeper_control
module Markdown = Masc_tui_markdown
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows

let acting_pane_reserved_cols = ref 0


(* What each drawn pane row acts on, and how far the pane can scroll, as of
   the last frame. A press or a wheel notch between frames is answered from
   what was on screen, which is these, not from what the next frame would
   draw. Empty when no pane was drawn, so a stale row cannot answer. *)
let acting_pane_row_targets : Masc_tui_acting_pane.row_target array ref = ref [||]

let acting_pane_scroll_max = ref 0


let navigation_rows = 1


let get_terminal_size () =
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  (max 1 (rows - navigation_rows), max 1 (cols - !acting_pane_reserved_cols))


let frame_lines buf =
  let str = Buffer.contents buf in
  let len = String.length str in
  if len = 0 then []
  else
    let limit = if str.[len - 1] = '\n' then len - 1 else len in
    let rec collect acc start idx =
      if idx >= limit then
        let last = String.sub str start (idx - start) in
        List.rev (last :: acc)
      else if str.[idx] = '\n' then
        let line = String.sub str start (idx - start) in
        collect (line :: acc) (idx + 1) (idx + 1)
      else
        collect acc start (idx + 1)
    in
    collect [] 0 0


(* Two already-drawn panes, side by side, one terminal row per line.

   The left pane's own width pads the rows it ran out of. Without that a
   short list lets the right pane's remaining lines slide to column zero,
   which reads as the detail having changed panes. Five surfaces had copied
   this loop; a sixth copy is how the padding rule drifts. *)
let write_two_panes buf ~left_cols ~left ~right =
  let left_lines = frame_lines left in
  let right_lines = frame_lines right in
  let blank_left = ref None in
  let get_blank_left () =
    match !blank_left with
    | Some s -> s
    | None ->
        let s = String.make left_cols ' ' in
        blank_left := Some s;
        s
  in
  let rec loop l_list r_list =
    match l_list, r_list with
    | [], [] -> ()
    | l :: lt, r :: rt ->
        Buffer.add_string buf l;
        Buffer.add_string buf r;
        Buffer.add_char buf '\n';
        loop lt rt
    | [], r :: rt ->
        Buffer.add_string buf (get_blank_left ());
        Buffer.add_string buf r;
        Buffer.add_char buf '\n';
        loop [] rt
    | l :: lt, [] ->
        Buffer.add_string buf l;
        Buffer.add_char buf '\n';
        loop lt []
  in
  loop left_lines right_lines

;;

(* A frame, and what it had to clamp to build itself. The clamp travels beside
   the frame rather than being written into the state mid-draw; see
   [clamped_scroll]. Surfaces that clamp nothing pass nothing. *)
let finish_frame ?clamped ?(compact_frame = false) ~surface_key ~cursor ~rows
    ~cols buf :
    Frame_presenter.frame * clamped_scroll option =
  ( { surface_key;
      compact_frame;
      terminal_rows = rows;
      terminal_cols = cols;
      cursor;
      lines = frame_lines buf;
    }
  , clamped )

;;

(* Whether tables are drawn with an outer box, read once from [tui].table_frame
   at start-up. Held here rather than threaded through every caller of
   [chat_markdown_palette]: the palette is built fresh on each render, so this
   is the one setting projected into it rather than a second copy of it. *)
let table_frame_enabled = ref false


(* Terminal dress for the markdown a keeper writes. The marker is the noise:
   a backticked identifier should read as the identifier, and a fenced diff
   should keep the alignment that made it worth fencing. Colours stay inside
   the palette the renderer already uses, so a chat row is still recognisably
   one of this TUI's rows. *)
let chat_markdown_palette ~closing : Markdown.palette =
  { strong = (Ansi.bold, closing)
    (* Slanted, not dimmed. Emphasis that recedes is the opposite of
       emphasis, and dim was standing in for an italic the theme did not
       have. It closes to the slant's own off-code so an emphasised run
       inside a coloured row leaves the row's colour alone. *)
  ; emphasis = (Ansi.italic, Ansi.no_italic)
  ; strike = (Ansi.strike, Ansi.no_strike)
  ; code = (Theme.Syntax.code_span, closing)
  (* Bold alone. [white] is a colour like any other -- on a light background
     it is the background -- so painting a heading with it hid the heading on
     exactly the terminals that read it as text. Bold already says heading. *)
  (* Which heading is inside which, said the way a terminal can: the top
     level is underlined as well as bold, the next is bold, and the rest are
     bold and dim so they still read as headings without competing with the
     two above. One span for every level drew a document with no shape. *)
  ; heading =
      (fun level ->
        if level <= 1 then (Ansi.bold ^ Ansi.underline, closing)
        else if level = 2 then (Ansi.bold, closing)
        else (Ansi.bold ^ Ansi.dim, closing))
  ; quote = (Ansi.dim, closing)
  ; link_text = (Theme.Syntax.link, closing)
  ; link_target = (Ansi.dim, closing)
  ; rule = (Theme.Syntax.rule, closing)
  ; bullet = "\xe2\x80\xa2"
  ; code_gutter = "\xe2\x94\x82 "
  (* Reverse video uses the terminal's own foreground and background, so the
     language banner stays legible on both light and dark themes. *)
  ; code_header = (Ansi.reverse, closing)
  ; code_border = (Theme.Syntax.rule, closing)
  ; quote_gutter = "\xe2\x96\x8f "
  ; table_header = (Ansi.bold, closing)
  ; table_gutter = " \xe2\x94\x82 "
  ; table_rule_gutter = "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80"
  ; table_frame = !table_frame_enabled
  (* Fenced-code tokens, inside the cyan the plain code span already uses:
     one hue per role a keeper's eye scans for -- what binds, what is data,
     what the reader can skip. *)
  ; code_keyword = (Theme.Syntax.keyword, closing)
  ; code_string = (Theme.Syntax.string, closing)
  ; code_comment = (Theme.Syntax.code_comment, closing)
  ; code_number = (Theme.Syntax.code_number, closing)
  ; code_type = (Ansi.bold ^ Theme.Syntax.code_type, closing)
  (* Changed rows follow the dedicated diff surfaces: their background runs
     through the code gutter and the unused cells, so lines of different
     lengths still read as one patch. The fixed light foreground is paired
     with the two fixed dark backgrounds by Theme; the +/- source marker and
     the background already say which side of the change this is. *)
  ; code_diff_added =
      (Theme.Syntax.diff_added_bg ^ Theme.Syntax.diff_row_foreground, closing)
  ; code_diff_removed =
      (Theme.Syntax.diff_removed_bg ^ Theme.Syntax.diff_row_foreground, closing)
  }


let markdown_with_closing ~closing ~width body =
  Markdown.render
    ~palette:(chat_markdown_palette ~closing) ~width body


(* Documents outside a conversation have no ambient role background to
   restore. Keep their former reset boundary explicit instead of inventing a
   synthetic chat role or taking a terminal-palette snapshot. *)
let document_markdown ~width body =
  markdown_with_closing ~closing:Ansi.reset ~width body


(* What a page says when it holds nothing, in one place.

   These were spelled at every surface that draws a page -- nine copies of the
   failure line and nine of the unread one -- and the unread copies said only
   that nothing had loaded. [r] is what loads it, and the reader was left to
   find that out somewhere else. Two surfaces did name the key, which is how a
   reader on the others learned there was nothing to learn. *)
let page_unread_note = "  (not loaded yet \xe2\x80\x94 press r)"

let page_failed_note = "  (load failed; nothing here is a reading)"

(* What a title says where its counts would go. A read nobody has asked for and a
   read that failed both leave the snapshot empty, and the title is the row on
   top, so it is the answer that gets read: "not loaded" after a failure sends
   the operator to [r] while the server's reason sits in red two rows below.

   The same distinction the body makes with {!page_unread_note} and
   {!page_failed_note}, in the words a title has room for. The Memory header was
   taught it in #35457; every other surface still said "not loaded" for both. *)
let title_unread = "(not loaded)"
let title_failed = "(load failed)"

let title_missing_reading ~error =
  if Option.is_some error then title_failed else title_unread


(* A level meter, only while a capture is running.

   A dead input device and a quiet room both end the same way — an empty draft
   — and nothing else distinguishes them. The bar spans -60 dB to 0, which puts
   an ordinary room near a third and speech visibly above it.

   Part of the prompt rather than drawn beside it, so the cursor column, which
   is computed from the prompt's width, does not have to know about it. *)
let voice_meter_text (state : state) =
  match state.voice_capture, state.voice_level_db with
  (* Continuous mode between utterances: no capture is running, but the row is
     still listening and the operator needs to know before speaking. *)
  | None, _ when state.voice_continuous <> None -> "[대기] "
  | None, _ -> ""
  | Some _, None -> "[듣는 중] "
  | Some _, Some db ->
    let width = 12 in
    let filled =
      if db = Float.neg_infinity
      then 0
      else max 0 (min width (int_of_float ((db +. 60.) /. 5.)))
    in
    Printf.sprintf
      "[%s%s] "
      (String.concat "" (List.init filled (fun _ -> "\xe2\x96\x88")))
      (String.concat "" (List.init (width - filled) (fun _ -> "\xc2\xb7")))

;;

let composer_prompt_text ?(voice = "") composer =
  Printf.sprintf " %s %s%s " "\xe2\x80\xba" voice (Composer.prompt composer)


(* Unfocused the row is dim and says which key opens it; focused it is drawn in
   full and carries the cursor. Either way it occupies the same single row, so
   taking focus does not move the frame above it. *)
(* The one line that tells an operator on any surface that a keeper is holding
   a tool call. Returns None when nothing is held, which is the common case. *)
let awaiting_approval_notice (state : state) =
  match state.msg_live with
  | None -> None
  | Some live -> (
      match Keeper_chat_transcript.awaiting_approval live.tl_transcript with
      | None -> None
      | Some awaiting ->
          let where =
            match state.view with
            | Keepers Keeper_message -> ""
            | Overview | Acting | Metrics | Keepers _ | Lanes | Clients | Board
            | Approvals | Planning
            | Memory | Schedules | Verification | Harness | Fusion
            | Repositories | Code | Changes | Connectors | Runtime | Config
            | Resources | Tools | System_logs ->
                "  (2 then m to answer)"
          in
          Some
            (Printf.sprintf "  %s is holding %s%s"
               (Terminal_text.single_line
                  (Masc_tui_types.turn_log_keeper_name live))
               (Terminal_text.single_line awaiting.Keeper_chat_transcript.tool_name)
               where))

;;

(* Where key hints live: the footer, and only the footer. A surface's body
   may say *state* — an armed two-step ("same key again to send"), what the
   composer's Enter will do — but never list available keys; a key listed in
   two places drifts in one of them, and a reader who has to scan the body
   for keys on one screen and the footer on another reports exactly
   "the key help keeps moving around" (2026-08-28). *)
let footer_line ?(status = []) (state : state) ~max_cells ~hints =
  (* Hints off trades the key text for status room; "?:help" stays as the
     door back. One seam for every surface, which is what makes the setting
     a setting instead of per-screen behaviour. *)
  let hints = if state.hints_visible then hints else "?:help" in
  (* An armed "/" search shows its query where every surface already looks
     for its keys. One seam instead of a per-surface indicator. *)
  let hints =
    match state.search with
    | Some query -> "/" ^ query ^ "  " ^ hints
    | None -> hints
  in
  (* What the last keypress did, in front of the keys for the same reason the
     search query is: the status tail is dropped whole before a single hint
     is, so a fact placed there cannot be read on a surface whose own keys
     already fill the row -- which is every surface at eighty columns. The
     outcomes of the editor-backed actions used to go only to the event log,
     which Overview alone draws, so an operator who pressed [a] on Workspace
     could not tell a registration from an editor that never started.

     Expired here rather than cleared by the setter: the setter is a key
     handler that has already returned, and nothing runs on a timer to come
     back for it. *)
  let hints =
    match state.last_action with
    | Some (text, set_at)
      when Unix.gettimeofday () -. set_at
           <= Masc_tui_types.last_action_window_s ->
      text ^ "  " ^ hints
    | Some _ | None -> hints
  in
  let identity =
    match state.server_identity with
    | None -> []
    | Some identity ->
        (* The health probe owns the exact path. Escape terminal controls, but
           do not trim or rewrite characters that may belong to the path. *)
        [ Masc_tui_footer.Server_build
            { version = identity.Tui_decode.sid_version
            ; commit = identity.Tui_decode.sid_binary_commit
            }
        ; Masc_tui_footer.Server_base_path
            (Terminal_text.single_line identity.Tui_decode.sid_base_path)
        ]
        @
        (* Only a definite yes warns: an older server that cannot say
           (None) must not read as either lane. *)
        (match identity.Tui_decode.sid_executable_in_worktree with
         | Some true -> [ Masc_tui_footer.Server_worktree_binary ]
         | Some false | None -> [])
        @
        (* This TUI's own embedded commit against the server's: the pair
           that told "restart masc" apart from "the feature is not merged"
           by hand every time. Silent when either side cannot testify. *)
        (match
           Masc_tui_footer.build_mismatch_item
             ~tui_commit:Masc.Build_identity.embedded_commit
             ~tui_age_s:
               (Option.map float_of_int
                  (Masc.Build_identity.embedded_commit_age_seconds
                     ~now:(Unix.gettimeofday ())))
             ~server_commit:identity.Tui_decode.sid_binary_commit
             ~server_age_s:identity.Tui_decode.sid_binary_commit_age_s
         with
         | Some item -> [ item ]
         | None -> [])
  in
  (* A workspace disagreement rides the footer every surface already draws,
     rather than replacing the screen. The reads that would be wrong under a
     mismatch are refused where they happen -- [load_local_workspace_if_safe],
     [load_live_context_if_safe], [load_keeper_logs_if_safe],
     [handle_composer_key], [handle_paste] -- and [clear_local_workspace]
     empties what a previous match had loaded. Drawing nothing but the notice
     took away Overview, Keepers, Board and Changes as well, and those read the
     server's answer, not this filesystem. *)
  let conflict =
    match state.workspace_identity with
    | Masc_tui_types.Workspace_identity_mismatch { local_base_path; _ } ->
        [ Masc_tui_footer.Workspace_mismatch
            (Terminal_text.single_line local_base_path)
        ]
    | Masc_tui_types.Workspace_identity_unread
    | Masc_tui_types.Workspace_identity_match -> []
  in
  (* Keepers mid-turn, the one this pane last messaged first: that is the
     answer the operator who walked away is waiting on. *)
  let answering =
    let running =
      List.filter_map
        (fun (row : Tui_decode.keeper_turn_row) ->
          match row.ktr_state with
          | Tui_decode.Keeper_turn_running { started_at_unix; _ } ->
              Some (row.ktr_keeper_name, started_at_unix)
          | Tui_decode.Keeper_turn_idle
          | Tui_decode.Keeper_turn_unavailable _ -> None)
        state.keeper_turns
    in
    let running =
      match state.msg_target_keeper_name with
      | Some target when List.mem_assoc target running ->
          (target, List.assoc target running)
          :: List.filter (fun (name, _) -> name <> target) running
      | Some _ | None -> running
    in
    match running with
    | [] -> []
    | (_, lead_started_at) :: _ ->
        (* The lead keeper's elapsed time rides the badge: a turn that has
           been running for twenty minutes reads as the stall it probably
           is, from every surface. Clamped so clock skew never counts up
           from the future. *)
        let lead_elapsed_s =
          Some
            (int_of_float
               (Float.max 0. (Unix.gettimeofday () -. lead_started_at)))
        in
        [ Masc_tui_footer.Keeper_answering
            { names = List.map fst running; lead_elapsed_s }
        ]
  in
  (* The glow after a finish: the newest one leads, the rest fold into +N.
     [advance_finishes] already dropped expired entries and keepers that
     started running again, but a footer drawn between polls still filters
     by its own clock so the glow dies on time, not on the next poll. *)
  let answered =
    let now = Unix.gettimeofday () in
    match
      List.filter
        (fun (_, finished_at) ->
          now -. finished_at <= Masc_tui_answering.finish_glow_ttl_seconds)
        state.keeper_turn_finishes
    with
    | [] -> []
    | (name, finished_at) :: rest ->
        [ Masc_tui_footer.Keeper_answered
            { name
            ; seconds_ago = int_of_float (Float.max 0. (now -. finished_at))
            ; more = List.length rest
            }
        ]
  in
  Masc_tui_footer.line
    ~status:(status @ identity @ conflict @ answering @ answered)
    ~dim:Ansi.dim ~reset:Ansi.reset ~max_cells ~port:state.port ~hints ()


let composer_line state ~cols =
  match browser_lane_on_screen state with
  | Some view ->
      Theme.recede () ^ fit_width (Browser_lane_view.context_label view) cols ^ Ansi.reset
  | None ->
  let composer = Composer_projection.of_state state in
  let prompt = composer_prompt_text ~voice:(voice_meter_text state) composer in
  let tone =
    match (composer.Composer.focus, composer.Composer.target) with
    | Composer.Focused, _ -> (Theme.info ())
    | Composer.Unfocused, Composer.Ready _ -> Ansi.dim
    | Composer.Unfocused, (Composer.No_target | Composer.Unreachable _) ->
        Ansi.dim
  in
  let draft = Terminal_text.single_line composer.Composer.draft in
  let hint =
    match (composer.Composer.focus, composer.Composer.target) with
    (* Shown on an empty focused draft only. A capture key nobody can see is a
       key nobody presses, and the row has space exactly while there is no
       draft to crowd. It goes away once a capture starts, because the meter
       has taken that space and says the same thing louder. *)
    | Composer.Focused, Composer.Ready _
      when state.voice_capture = None
           && state.voice_continuous = None
           && Buffer.length state.msg_input = 0 ->
        "  (^Y to speak, ^A to keep listening)"
    | Composer.Focused, _ -> ""
    | Composer.Unfocused, Composer.Ready _ ->
        Printf.sprintf "  (%s to write)" Composer.focus_key
    | Composer.Unfocused, (Composer.No_target | Composer.Unreachable _) -> ""
  in
  let body =
    if String.equal draft "" then prompt ^ hint else prompt ^ draft
  in
  (* A held tool call is drawn on whatever surface the operator is looking at.
     Its prompt lives in the chat pane, and a turn holding a call is denied
     when the wait runs out -- so an operator reading the Board would lose the
     call without ever seeing that it was waiting. This line says a keeper is
     waiting and where to answer; the answer itself stays in the chat pane,
     where it is unambiguous which keeper and which call it is for. *)
  match awaiting_approval_notice state with
  | Some notice -> (Theme.warn ()) ^ fit_width notice cols ^ Ansi.reset
  | None -> tone ^ fit_width body cols ^ Ansi.reset


let composer_cursor state ~rows ~cols =
  match browser_lane_on_screen state with
  | Some _ -> Frame_presenter.Hidden
  | None ->
  let composer = Composer_projection.of_state state in
  match composer.Composer.focus with
  | Composer.Unfocused -> Frame_presenter.Hidden
  | Composer.Focused ->
      let prompt_cells =
        (* The same string the row draws: a meter that widened the prompt
           without widening this would put the cursor inside the draft. *)
        Message_layout.display_width
          (composer_prompt_text ~voice:(voice_meter_text state) composer)
      in
      let draft_cells =
        Message_layout.display_width
          (Terminal_text.single_line composer.Composer.draft)
      in
      Frame_presenter.Visible_at
        { row = rows
        ; column = Composer.cursor_column ~prompt_cells ~draft_cells ~terminal_cols:cols
        }

;;

(* The strip above every surface: the Tab ring with the active family
   highlighted. Wider terminals see the whole ring; narrower ones see a
   window around the active entry with how many entries hide past each edge,
   so position in the cycle stays readable at any width. *)
let surface_strip (state : state) ~cols =
  (* An array because the strip is drawn by index: the width probe, the
     label and the cell each read entry [i], and a list answers that by
     walking. Ten entries make that cost nothing -- it is an array so the
     renderer holds no row lookup that walks, with no exception to carry. *)
  let ring = Array.of_list (Masc_tui_types.visible_surface_ring state) in
  let n = Array.length ring in
  let active = Masc_tui_types.visible_surface_ring_index state state.view in
  (* A count rides the entry it belongs to, so pending work is visible from
     every surface without a spare row. Zero draws nothing -- an always-on
     badge would be texture, not information. *)
  let badge surface =
    match (surface : surface) with
    | Approvals ->
        (match List.length (Masc_tui_types.approval_items state) with
         | 0 -> ""
         | pending -> Printf.sprintf "\xc2\xb7%d" pending)
    | Planning ->
        (match state.verification with
         | Some snapshot when snapshot.Masc.Tui_decode.vs_total > 0 ->
             Printf.sprintf "\xc2\xb7%d" snapshot.Masc.Tui_decode.vs_total
         | Some _ | None -> "")
    | _ -> ""
  in
  let label i =
    let surface, name = ring.(i) in
    name ^ badge surface
  in
  (* Plain-cell width of entry [i] inside a window starting at [lo]. *)
  let entry_width ~lo i =
    (* Cells, not bytes: the Approvals badge's middle dot is two bytes and
       one cell, and a byte count windows the strip one entry early. *)
    Message_layout.display_width (label i)
    + (if i = active then 1 else 0)
    + (if i > lo then 2 else 0)
  in
  let window_width lo hi =
    let rec sum i acc =
      if i > hi then acc else sum (i + 1) (acc + entry_width ~lo i)
    in
    sum lo 0
  in
  let budget = max 8 (cols - 1) in
  let lo, hi =
    if window_width 0 (n - 1) <= budget then (0, n - 1)
    else begin
      (* Markers for hidden entries cost room; reserve it up front. *)
      let budget = max 8 (budget - 10) in
      let lo = ref active and hi = ref active in
      let grew = ref true in
      while !grew do
        grew := false;
        if !hi + 1 < n && window_width !lo (!hi + 1) <= budget then begin
          incr hi;
          grew := true
        end;
        if !lo > 0 && window_width (!lo - 1) !hi <= budget then begin
          decr lo;
          grew := true
        end
      done;
      (!lo, !hi)
    end
  in
  let parts = Buffer.create 128 in
  Buffer.add_char parts ' ';
  if lo > 0 then
    Buffer.add_string parts
      (Printf.sprintf "%s\xe2\x80\xb9%d%s " Ansi.dim lo Ansi.reset);
  for i = lo to hi do
    if i > lo then Buffer.add_string parts "  ";
    let surface, _ = ring.(i) in
    let is_alert =
      match surface with
      | Approvals -> List.length (Masc_tui_types.approval_items state) > 0
      | _ -> false
    in
    if i = active then
      Buffer.add_string parts
        (Ansi.bold
        ^ (if is_alert then Theme.warn () else Theme.info ())
        ^ Masc_tui_theme.Glyph.current_entry
        ^ label i ^ Ansi.reset)
    else if is_alert then
      Buffer.add_string parts
        (Ansi.bold ^ (Theme.warn ()) ^ label i ^ Ansi.reset)
    else Buffer.add_string parts (Ansi.dim ^ label i ^ Ansi.reset)
  done;
  if hi < n - 1 then
    Buffer.add_string parts
      (Printf.sprintf " %s%d\xe2\x80\xba%s" Ansi.dim (n - 1 - hi) Ansi.reset);
  if state.burn_hud_visible then begin
    let total_cost = Masc_tui_types.fleet_total_cost_usd state in
    let spark = Masc_tui_types.fleet_token_sparkline state in
    let hud =
      Printf.sprintf "%s[HUD $%.2f %s%s%s]%s"
        (Theme.recede ()) total_cost (Theme.info ()) spark (Theme.recede ()) Ansi.reset
    in
    let hud_raw = Printf.sprintf "[HUD $%.2f %s]" total_cost spark in
    let hud_cells = Message_layout.display_width hud_raw in
    let used_cells = Message_layout.display_width (Masc_tui_theme.strip_sgr (Buffer.contents parts)) in
    if cols >= used_cells + hud_cells + 2 then begin
      let gap = String.make (max 1 (cols - used_cells - hud_cells - 1)) ' ' in
      Buffer.add_string parts gap;
      Buffer.add_string parts hud
    end
  end;
  Buffer.contents parts


(* Side-by-side panes share one threshold and one context-pane width, so
   every split surface folds at the same terminal size. *)
let keeper_split_threshold_cols = Masc_tui_roster_pane.threshold_cols

let keeper_roster_pane_cols = Masc_tui_roster_pane.pane_cols


(* Finish a frame with the strip on top. Surfaces measured cursor rows inside
   their own frame, so a visible cursor shifts down with the prepend, and the
   declared height grows back to the terminal's real row count. *)
let finish_frame_with_strip (state : state) ?clamped ~surface_key ~cursor ~rows
    ~cols buf =
  let cursor =
    match cursor with
    | Frame_presenter.Hidden -> Frame_presenter.Hidden
    | Frame_presenter.Visible_at { row; column } ->
      Frame_presenter.Visible_at { row = row + 1; column }
  in
  let framed = Buffer.create (Buffer.length buf + 160) in
  Buffer.add_string framed (surface_strip state ~cols);
  Buffer.add_char framed '\n';
  Buffer.add_buffer framed buf;
  finish_frame ?clamped ~surface_key ~cursor ~rows:(rows + 1) ~cols framed


(* The agenda strip: one row above the composer, on every surface.

   Colour splits it the way the layout does. The wake recedes -- a schedule
   that fires in an hour is ambient, and painting it warn would make the
   screen shout every hour. The badge does not: a keeper stopped on the
   operator is the half that has to be read now. *)
let agenda_line agenda ~cols =
  match
    Agenda.strip
      ~now:(Unix.gettimeofday ())
      ~localtime:Unix.localtime
      ~cols
      agenda
  with
  | None -> None
  | Some { Agenda.clock; waiting } ->
    let used =
      Message_layout.display_width clock + Message_layout.display_width waiting
    in
    let gap = String.make (max 0 (cols - used)) ' ' in
    let painted = function "" -> "" | text -> text in
    Some
      ((Theme.recede ())
      ^ painted clock
      ^ Ansi.reset
      ^ gap
      ^ (if waiting = "" then "" else (Theme.bad ()) ^ waiting ^ Ansi.reset))

;;

(* Close a surface: pad its frame to the row above the composer, then draw the
   composer on the terminal's last row.

   The padding is what keeps the two in step. Each surface computes its own
   height, and one that came out short used to leave its footer stranded
   partway up the screen; now it would push the composer up with it, and the
   row an operator reaches for would move per surface. *)
(* What the Activity pane reads, gathered from the state the surfaces
   already hold. The pane module interprets none of it: health becomes a
   mark and a tone here, the feed's status becomes its four words here, and
   the agent-core correlation ids resolve through the same trace table the
   Activity surface uses. *)
(* The address a change is listed under and the range label it carries.
   Named here, ahead of every surface, because the Activity pane lists the
   selected keeper's changes the same way the Changes surface does -- and the
   address itself is Tui_decode's now, so the row search can read the same
   one without the renderer. *)
let change_row_address = Masc.Tui_decode.file_change_address


let file_change_range_label
      (range : Masc.Keeper_file_change_evidence.line_range)
  =
  if range.start_line = range.end_line
  then Printf.sprintf "L%d" range.start_line
  else Printf.sprintf "L%d-%d" range.start_line range.end_line


let file_change_evidence_label = function
  | None -> None
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = None }) ->
    Some "empty file"
  | Some (Masc.Keeper_file_change_evidence.Written { new_range = Some range }) ->
    Some (file_change_range_label range)
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = None }) ->
    Some (Printf.sprintf "%d matches; ranges omitted" occurrence_count)
  | Some
      (Masc.Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = Some occurrences }) ->
    (match occurrences with
     | [] -> Some (Printf.sprintf "%d matches" occurrence_count)
     | first :: _ ->
       let old_range = file_change_range_label first.old_range in
       let changed =
         match first.new_range with
         | Some new_range -> old_range ^ "→" ^ file_change_range_label new_range
         | None -> old_range ^ "→deleted"
       in
       if occurrence_count = 1
       then Some changed
       else Some (Printf.sprintf "%s (+%d)" changed (occurrence_count - 1)))


(* The selected keeper's file changes as the pane's Changes tab draws
   them: the fetch helper's four states named one by one, each change
   read to the address, the kind, whether it landed, and its range. *)
let acting_pane_changes (state : state) : Masc_tui_acting_pane.changes =
  let module Pane = Masc_tui_acting_pane in
  match selected_keeper state with
  | None -> Pane.Changes_absent
  | Some (keeper : keeper) -> (
      match
        Masc_tui_fetched.view_for ~equal:String.equal state.acting_pane_changes
          ~key:keeper.k_name
      with
      | Masc_tui_fetched.Absent -> Pane.Changes_absent
      | Masc_tui_fetched.Loading -> Pane.Changes_loading
      | Masc_tui_fetched.Failed detail -> Pane.Changes_failed detail
      | Masc_tui_fetched.Ready (snapshot : Masc.Tui_decode.file_change_snapshot) ->
          let file (change : Masc.Tui_decode.file_change) =
            { Pane.file_path = change_row_address change
            ; file_kind =
                (match change.fc_kind with
                 | Masc.Tui_decode.Fc_edited _ | Masc.Tui_decode.Fc_inserted _ ->
                   Pane.File_edited
                 | Masc.Tui_decode.Fc_written _ -> Pane.File_written)
            ; file_succeeded = change.fc_succeeded
            ; file_at = change.fc_at
            ; file_where = file_change_evidence_label change.fc_line_evidence
            }
          in
          Pane.Changes_ready
            { keeper = snapshot.fcs_keeper
            ; files = List.map file snapshot.fcs_changes
            ; fetched_at =
                (* [Ready] is only ever set beside the stamp; a missing
                   stamp reads as an answer from this instant. *)
                Option.value state.acting_pane_changes_at
                  ~default:(Unix.gettimeofday ())
            ; window_hours = snapshot.fcs_window_hours
            ; calls = snapshot.fcs_calls_in_window
            ; over_budget = snapshot.fcs_over_budget
            ; malformed = snapshot.fcs_malformed
            })


let recent_chunk_projection (state : state) =
  let traces =
    List.map (fun (keeper : keeper) -> keeper.k_name, keeper.k_trace_id) state.keepers
  in
  Masc_tui_acting.refresh_projection
    ~previous:state.acting_chunk_projection ~traces state.acting


let acting_pane_input (state : state) : Masc_tui_acting_pane.input =
  let module Pane = Masc_tui_acting_pane in
  let keepers =
    List.map
      (fun (keeper : keeper) ->
        let reading = keeper_reading state keeper in
        let health = Keeper_control.health reading in
        let paused = reading.Keeper_control.paused in
        let reading_of_health = Option.map Tui_decode.keeper_health_reading health in
        let mark_tone =
          if paused then Pane.Dim
          else
            match reading_of_health with
            | Some Tui_decode.Health_running -> Pane.Ok
            | Some Tui_decode.Health_idle -> Pane.Dim
            | Some (Tui_decode.Health_stale | Tui_decode.Health_degraded) -> Pane.Warn
            | Some (Tui_decode.Health_offline | Tui_decode.Health_zombie) -> Pane.Bad
            | None -> Pane.Dim
        in
        { Pane.name = keeper.k_name
        ; mark = Masc_tui_keeper_mark.glyph ~paused reading_of_health
        ; mark_tone
        ; health = reading_of_health
        })
      state.keepers
  in
  let feed =
    match state.observer with
    | Observer_off -> Pane.Feed_off
    | Observer_opening -> Pane.Feed_opening
    | Observer_live { events; _ } -> Pane.Feed_live events
    | Observer_closed { reason; _ } -> Pane.Feed_closed reason
  in
  (* This input is built only when the pane is visible. Changes does not
     consume event chunks, so retain the previous projection without folding. *)
  let chunks = match state.acting_pane_tab with
    | Pane.Tab_changes -> []
    | Pane.Tab_fleet ->
      (* The loop normally prepared this projection. Direct render callers
         still get current chunks on a miss, without changing their state. *)
      Masc_tui_acting.projection_chunks (recent_chunk_projection state)
  in
  { Pane.now = Unix.gettimeofday ()
  ; tab = state.acting_pane_tab
  ; scope =
      (match state.view with
       | Keepers Keeper_list -> Pane.Selected_only
       | Keepers
           (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
       | Overview | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning
       | Schedules | Verification | Harness | Fusion | Repositories | Code | Changes
       | Connectors | Runtime | Config | Resources | Tools | System_logs ->
           Pane.Whole_fleet)
  ; feed
  ; keepers
  ; selected =
      Option.map (fun (keeper : keeper) -> keeper.k_name) (selected_keeper state)
  ; approvals =
      (* Every kind of pending approval the Approvals surface lists, read to
         the two facts the pane states: whose, and for which tool. *)
      List.map
        (fun (row : approval_row) ->
          match row with
          | Keeper_tool_row held ->
              { Pane.approval_keeper = held.kta_keeper; approval_tool = held.kta_tool }
          | Gate_row pending ->
              { Pane.approval_keeper = pending.gp_keeper
              ; approval_tool = pending.gp_display_tool
              }
          | Operator_row item ->
              { Pane.approval_keeper = item.ap_actor
              ; approval_tool = item.ap_delegated_tool
              })
        (Masc_tui_types.approval_items state)
  ; chunks
  ; changes = acting_pane_changes state
  }


(* A pane tone is a reading; the theme answers with the colour. *)
let acting_pane_sgr (tone : Masc_tui_acting_pane.tone) =
  match tone with
  | Masc_tui_acting_pane.Plain -> ""
  | Masc_tui_acting_pane.Dim -> Theme.recede ()
  | Masc_tui_acting_pane.Accent -> Ansi.bold ^ Theme.info ()
  | Masc_tui_acting_pane.Ok -> Theme.ok ()
  | Masc_tui_acting_pane.Warn -> Theme.warn ()
  | Masc_tui_acting_pane.Bad -> Theme.bad ()
  | Masc_tui_acting_pane.Info -> Theme.info ()


(* The pane sits on its own ground. Every span's reset would drop the row
   back to the page's ground mid-row, so the ground is re-opened after each
   one; the row ends on a full reset so the surface's next row starts on the
   page. Without a palette the ground is [""] and the row draws as before. *)
let paint_acting_pane_line ~ground (line : Masc_tui_acting_pane.line) =
  let restore = if String.equal ground "" then "" else Ansi.reset ^ ground in
  let close = if String.equal ground "" then "" else Ansi.reset in
  ground
  ^ String.concat ""
      (List.map
         (fun (span : Masc_tui_acting_pane.span) ->
           match acting_pane_sgr span.tone with
           | "" -> span.text
           | sgr -> sgr ^ span.text ^ Ansi.reset ^ restore)
         line)
  ^ close


let finish_surface (state : state) ?clamped ~surface_key ~rows ~cols buf =
  (* [surface_body_rows] removes the strip before either the frame or the
     typed scroll layout receives its body budget. Two readers of that one
     budget: the row the frame draws is the row the keypress stops short of. *)
  let agenda_rows = Masc_tui_types.agenda_chrome_rows state in
  let body_rows = Masc_tui_types.surface_body_rows state ~terminal_rows:rows in
  let drawn = frame_lines buf in
  let body =
    if List.length drawn <= body_rows then
      drawn @ List.init (body_rows - List.length drawn) (fun _ -> "")
    else
      (* A surface that came out taller than its budget loses its last rows
         rather than the composer. The body is already scrollable and the
         composer is a fixed contract -- the row an operator reaches for cannot
         be the one that disappears when a surface miscounts. *)
      List.filteri (fun index _ -> index < body_rows) drawn
  in
  (* [cols] is what the surface laid out against: the terminal less the
     Activity pane when the pane shows. The body shares its rows with the
     pane; the agenda, the composer, and the strip span the whole terminal,
     the way an editor's side bar stops above the command line. *)
  let pane_cols = !acting_pane_reserved_cols in
  let full_cols = cols + pane_cols in
  let framed = Buffer.create (String.length (Buffer.contents buf) + 256) in
  (if pane_cols > 0 then begin
     let left = Buffer.create (String.length (Buffer.contents buf) + 256) in
     List.iter
       (fun line ->
          Buffer.add_string left (Message_layout.fit_width line cols);
          Buffer.add_char left '\n')
       body;
     let rendering =
       Masc_tui_acting_pane.lines ~rows:body_rows ~cols:pane_cols
         ~scroll:state.acting_pane_scroll (acting_pane_input state)
     in
     acting_pane_row_targets := Array.of_list rendering.Masc_tui_acting_pane.targets;
     acting_pane_scroll_max := rendering.Masc_tui_acting_pane.scroll_max;
     let ground = Theme.side_pane_background () in
     let right = Buffer.create 4096 in
     List.iter
       (fun line ->
          Buffer.add_string right (paint_acting_pane_line ~ground line);
          Buffer.add_char right '\n')
       rendering.Masc_tui_acting_pane.rows;
     write_two_panes framed ~left_cols:cols ~left ~right
   end
   else begin
     acting_pane_row_targets := [||];
     acting_pane_scroll_max := 0;
     List.iter
       (fun line ->
          Buffer.add_string framed line;
          Buffer.add_char framed '\n')
       body
   end);
  (if agenda_rows > 0 then
     match agenda_line (Masc_tui_types.agenda state) ~cols:full_cols with
     | Some line -> Buffer.add_string framed (line ^ "\n")
     | None -> ());
  Buffer.add_string framed (composer_line state ~cols:full_cols ^ "\n");
  finish_frame_with_strip state ?clamped ~surface_key
    ~cursor:(composer_cursor state ~rows ~cols:full_cols) ~rows ~cols:full_cols framed


(* Exhaustive over [connection_status]: a new state is a compile error
   here rather than an unexplained [disconnected] on screen. *)
(* ── the A-family surface chrome contract ─────────────────────────────
   One owner for a borderless surface's fixed rows: top gap, title row,
   divider, height fill, bottom gap, and the status-tail footer. The body
   pushes its rows through the record and the contract counts them, so the
   hand-tallied chrome_rows constants (the fixed-chrome-row trap: add a row,
   forget the count, lose a body line) cannot drift — there is nothing left
   to tally by hand. Surfaces keep composing their own title (screen_title
   plus whatever meta) and hints; the contract owns geometry only. *)

type chrome_body = {
  push : string -> unit;
  push_styled : style:string -> string -> unit;
  push_selected : string -> unit;
  push_divider : unit -> unit;
  push_empty : unit -> unit;
}

let surface_chrome ?clamped (state : state) ~terminal_rows ~cols ~surface_key
    ~title ~hints ~(body : budget:int -> chrome_body -> unit) =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols title;
  box_divider buf cols;
  (* top + title + divider + bottom + footer: the five rows the contract
     itself draws. Everything else is the body's budget. *)
  let contract_rows = 5 in
  let budget = max 1 (rows - contract_rows) in
  let used = ref 0 in
  (* A push past the budget draws nothing. The alternative — drawing it —
     shoves the bottom gap and the footer off screen, which breaks every
     row below the surface for the whole frame. Rows a body offers past
     its budget read as cut at the bottom edge, the same truncation a
     scrolled list already means; bodies that need them all paginate
     against ~budget, as the migrated surfaces do. *)
  let counted draw arg =
    if !used < budget then begin incr used; draw arg end
  in
  let body_pushers =
    { push = counted (fun line -> box_line buf cols line)
    ; push_styled =
        (fun ~style line ->
          counted (fun line -> box_line_styled buf cols ~style line) line)
    ; push_selected = counted (fun line -> box_line_selected buf cols line)
    ; push_divider = counted (fun () -> box_divider buf cols)
    ; push_empty = counted (fun () -> box_empty buf cols)
    }
  in
  body ~budget body_pushers;
  for _ = !used + 1 to budget do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);
  (* Read after the body, because that is the only moment the value exists:
     a surface whose rows the drawing counts cannot say what it clamped to
     before it has drawn. A thunk rather than a value for the same reason. *)
  finish_surface state
    ?clamped:(match clamped with None -> None | Some read -> read ())
    ~surface_key ~rows:terminal_rows ~cols buf


let connection_status_badge (status : Masc_tui_types.connection_status) =
  (* This badge summarizes HTTP refreshes. A rejected read (for example 429)
     can fail while the independent Recent event feed remains live. *)
  let style, label =
    match status with
    | Connected -> Theme.ok (), "connected"
    | Degraded -> Theme.warn (), "partial"
    | Connecting -> Theme.warn (), "loading..."
    | Reconnecting -> Theme.warn (), "refreshing..."
    | Booting -> Theme.warn (), "server booting..."
    | Disconnected -> Theme.bad (), "refresh failed"
  in
  "HTTP " ^ style ^ "[" ^ label ^ "]" ^ Ansi.reset

;;

(* Every surface header ends with this, so a workspace the server does not
   share is said on whichever screen the operator is reading. The footer
   carries the two paths when the row has space for them; this is the part
   that has to survive a full row of key hints, because the surfaces it
   explains are the ones drawing nothing. *)
let connection_badge (state : state) =
  let connection = connection_status_badge state.connection_status in
  match state.workspace_identity with
  | Masc_tui_types.Workspace_identity_mismatch _ ->
      connection ^ " " ^ (Theme.bad ()) ^ "[workspace mismatch]" ^ Ansi.reset
  | Masc_tui_types.Workspace_identity_unread
  | Masc_tui_types.Workspace_identity_match -> connection


let count_frame_lines buf =
  let len = Buffer.length buf in
  if len = 0 then 0
  else
    let n = ref 0 in
    for i = 0 to len - 1 do
      if Buffer.nth buf i = '\n' then incr n
    done;
    if Buffer.nth buf (len - 1) = '\n' then !n
    else !n + 1


(* The roster shows when the terminal can spare its columns and the reader
   has not put it away. Width is the terminal's answer, [roster_pane_hidden]
   is theirs, and hiding survives a resize because it is a decision rather
   than a measurement. *)
let keeper_roster_pane_shown (state : state) ~cols =
  Masc_tui_roster_pane.shown ~hidden:state.roster_pane_hidden ~cols


(** Render the keeper list view *)
(* Status is shown as a glyph and a word. The glyph is the coarse reading an
   operator scans a column for -- a fiber running, a fiber sleeping, no fiber,
   nothing observed -- and the word next to it is the exact published status,
   so the column stays legible at four shapes instead of needing a distinct
   glyph per label. *)
(* One keeper is described by four separate readings, and the status cell draws
   three of them in three separate channels rather than folding them into one
   word:

     colour  what to do about it   from next_action, which the runtime derives
     glyph   whether it is paused  a person's decision, not a health reading
     word    how it is reporting   from health

   The lifecycle cell is the fourth and has its own column. The cell used to
   show a single word from [surface_status], which restates health with stale,
   degraded and zombie folded together and hides health entirely while a keeper
   is paused. *)
let keeper_action_color
    (action : Status.keeper_next_action_path option) =
  match action with
  | None -> Ansi.dim
  | Some Status.Auto_restart -> (Theme.bad ())
  | Some Status.Recover -> (Theme.warn ())
  | Some Status.Probe -> Theme.action_probe ()
  (* Green until this measurement. The cell draws four readings in four
     channels and this is the only one carried by colour alone, so the four
     colours have to stay apart for a reader who cannot separate red from
     green -- roughly one man in twelve.

     Simulated (Machado 2009, severity 1.0) over the twelve base16 schemes the
     contrast harness measures, the closest pair was not red against green but
     [Recover] against [Direct_message] -- yellow and green both arrive
     yellowish -- at 0.015 in Oklab. Magenta is the only candidate that
     improves every reading rather than trading one for another: 0.070 to
     0.121 for ordinary vision, 0.015 to 0.044 for deuteranopia, 0.019 to
     0.027 for protanopia. Blue and white came out worse than green even for
     ordinary vision, because they close on [Probe]'s cyan. *)
  | Some Status.Direct_message -> Theme.action_message ()


let keeper_state_glyph ~paused ~(health : Tui_decode.keeper_health option) =
  Masc_tui_keeper_mark.glyph ~paused
    (Option.map Tui_decode.keeper_health_reading health)


(* Runtime ids are opaque identifiers, so a fixed-width surface keeps both
   ends instead of sacrificing the distinguishing tail to a shared prefix.
   Returning the unpadded id when it already fits lets a chat header spend the
   remaining cells on context instead of blank padding. *)
let fit_runtime_id width runtime_id =
  if Message_layout.display_width runtime_id <= width then runtime_id
  else Message_layout.fit_middle width runtime_id


(* A narrow roster beside the detail: position context, not a second input
   surface -- the keys keep their detail meaning. The window follows the
   cursor the way the detail follows the selection. *)
let keeper_roster_pane ?(focused = false) (state : state) ~rows ~cols buf =
  framed_top buf cols;
  let title = " KEEPERS" in
  let hint = if focused then "ENTER OPEN" else "^B HIDE" in
  let title_gap = max 1 (framed_inner_width cols - String.length title - String.length hint) in
  let title_row = title ^ String.make title_gap ' ' ^ hint in
  framed_line buf cols
    (if focused then Theme.selection ^ title_row ^ Ansi.reset
     else
       Ansi.bold ^ title ^ Ansi.reset ^ String.make title_gap ' ' ^ Ansi.dim
       ^ hint ^ Ansi.reset);
  framed_divider buf cols;
  let content_height = max 0 (rows - framed_chrome_rows) in
  let first =
    if state.keeper_cursor < content_height then 0
    else state.keeper_cursor - content_height + 1
  in
  let keepers_window = Rows.of_list ~first:first ~height:content_height state.keepers in
  for i = 0 to content_height - 1 do
    match Rows.at keepers_window (first + i) with
    | Some (k : keeper) ->
        let selected = first + i = state.keeper_cursor in
        let name = Terminal_text.single_line k.k_name in
        let name =
          Masc_tui_roster_pane.name_window ~selected
            ~frame:state.roster_marquee_frame ~width:(max 0 (cols - 7)) name
        in
        (* The same glyph the Keepers surface draws, for the same reading.
           Without it the pane says a keeper exists and nothing else, so a
           roster of ten looks identical whether one of them is offline. *)
        let reading = keeper_reading state k in
        let glyph =
          keeper_state_glyph
            ~paused:reading.Keeper_control.paused
            ~health:(Keeper_control.health reading)
        in
        (* Reverse video is the one selection signal every terminal
           renders, colour or not, and it owns the whole row: a glyph
           tinted inside it reads as a second highlight. *)
        let line =
          if selected then
            Theme.selection ^ " " ^ glyph ^ " " ^ name ^ Ansi.reset
          else
            " "
            ^ keeper_action_color (Keeper_control.next_action reading)
            ^ glyph ^ Ansi.reset ^ " " ^ Ansi.dim ^ name ^ Ansi.reset
        in
        framed_line buf cols line
    | None -> framed_empty buf cols
  done;
  framed_bottom buf cols


(* What a boxed listing draws under its rows: the scroll line -- a row whether
   or not there is anything to report, so a list that overflows does not push
   the help line off the bottom -- then the frame's bottom, then the footer.

   Named once because three surfaces were tallying their whole chrome by hand,
   and being one row over the budget is not a visible mistake: [finish_surface]
   drops the last rows, and the last row is the footer. *)
let listing_rows_below_the_body = 3

;;

(* A narrow list beside an open detail: which row you are on, and what else
   is there. Only the label -- the columns a full list carries do not fit
   thirty cells, and a truncated author reads as a different author.

   [selected] indexes [labels]; the pane scrolls to keep that row drawn.
   [focused] says whether the arrow keys are pointed here, which is a
   different question from which row is open. *)
let write_list_sidebar buf ~rows ~cols ~title ~focused ~labels ~selected =
  framed_top buf cols;
  (* Focus wears a caret, not a key list: which keys work is the footer's
     sentence; which pane hears them is this one glyph. *)
  framed_line buf cols
    ((if focused then Ansi.bold else Ansi.dim)
     ^ Printf.sprintf " %s%s (%d)" (if focused then "\xe2\x96\xb8 " else "") title
         (List.length labels)
     ^ Ansi.reset);
  framed_divider buf cols;
  let content_height = max 0 (rows - framed_chrome_rows) in
  let first =
    if selected < content_height then 0 else selected - content_height + 1
  in
  let labels_window = Rows.of_list ~first:first ~height:content_height labels in
  for i = 0 to content_height - 1 do
    match Rows.at labels_window (first + i) with
    | Some label ->
      (* A separate name for the sanitized text. Shadowing [label] left four
         uses that read as raw ones to anything checking by name, the reader
         included. *)
      let drawn = Terminal_text.single_line label in
      framed_line buf cols
        (if first + i = selected then
           if focused then
             Theme.selection ^ " " ^ drawn
             ^ String.make
                 (max 0 (cols - 5 - Message_layout.display_width drawn))
                 ' '
             ^ Ansi.reset
           else Ansi.bold ^ " \xe2\x96\xb8 " ^ drawn ^ Ansi.reset
         else " " ^ drawn)
    | None -> framed_empty buf cols
  done;
  framed_bottom buf cols


(* The row a surface draws when its load failed. Six copies wrote the sentence
   out and each reserved [cols - 24] for the error beside it -- one cell more
   than the frame gives, so a long error was cut where its closing bracket
   should have been. The room is worked out from the sentence here, which is
   what stops the two from drifting the next time the wording changes. *)
let data_unreliable_open = "  (data unreliable: "

let data_unreliable_close = ")"


let data_unreliable_row ~cols err =
  let room =
    max 8
      (framed_inner_width cols
       - Message_layout.display_width data_unreliable_open
       - Message_layout.display_width data_unreliable_close)
  in
  (Theme.bad ())
  ^ data_unreliable_open
  ^ fit_width err room
  ^ data_unreliable_close
  ^ Ansi.reset


let fenced_document_text ~language text =
  match
    Masc_tui_markdown.non_colliding_fence_marker
      (String.split_on_char '\n' text)
  with
  | Some marker -> String.concat "\n" [ marker ^ language; text; marker ]
  | None -> text


(* The server names itself in every footer, because "which masc is this"
   is a question every surface can raise and none of them answered: the tail
   named only its listening endpoint and two checkouts there read identically. *)
(* One hue per token kind, for every surface that draws lexed rows. It was a
   local function inside the Code surface until Config started drawing the same
   segments; a second copy would be a second answer the first time one of them
   gained a kind. *)
let lexed_span (text, kind) =
  if String.length text = 0 then ""
  else
    let style =
      if String.equal kind Masc_tui_code_lexer.kind_keyword then
        Theme.Syntax.keyword
      else if String.equal kind Masc_tui_code_lexer.kind_string then
        Theme.Syntax.string
      else if String.equal kind Masc_tui_code_lexer.kind_comment then
        Theme.Syntax.code_comment
      else if String.equal kind Masc_tui_code_lexer.kind_number then
        Theme.Syntax.code_number
      else if String.equal kind Masc_tui_code_lexer.kind_type then
        Ansi.bold ^ Theme.Syntax.code_type
      else ""
    in
    if String.equal style "" then text else style ^ text ^ Ansi.reset


(* Compact "how long" text three surfaces share: the Attention panel's item
   age, the Lanes table's idle column, and the Keeper operations preview --
   which kept a byte-for-byte copy of this under its own name, 3,600 lines
   below, until the two were counted. *)
let keeper_lane_idle_text seconds =
  let seconds = max 0 seconds in
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)


(** Render one backlog task in full, from the same load the Overview list was
    projected from. The dispatch falls back to the Overview when the row is no
    longer in the backlog, so the task argument always exists here. *)
(* What a boxed surface spends on chrome before any row of content: the top
   border, its title and rule, the closing rule and border, the selected-row
   detail, and the key hints. Five surfaces subtracted the literal 10 from the
   terminal height; naming it is what makes a sixth reader able to check the
   arithmetic instead of trusting it. *)
let boxed_surface_chrome_rows = 10


(* Long question, choice, and reason text was cut to one line with a trailing
   "~", so an operator could not read the decision being asked of them. Each
   field wraps instead: the first row carries [head] (the caret and Keeper
   name, or a choice's number and mark), and every wrapped row after it is
   indented to [head]'s visible width so the text stays in one column. [head]'s
   ANSI is not counted toward the indent -- display_width reads cells, not
   escape bytes. box_line pads content to the inner width, so a row of exactly
   the inner width is filled, not truncated. *)
let box_wrapped_field buf cols ~head ~style body =
  let indent = Message_layout.display_width head in
  let avail = max 8 (framed_inner_width cols - indent) in
  match Message_layout.wrap_words ~max_cells:avail (Terminal_text.single_line body) with
  | [] -> box_line buf cols head
  | first :: rest ->
      box_line buf cols (head ^ style ^ first ^ Ansi.reset);
      let hang = String.make indent ' ' in
      List.iter
        (fun segment -> box_line buf cols (hang ^ style ^ segment ^ Ansi.reset))
        rest


(* The question the ask cursor is on, or none when nothing is waiting. The
   footer asks for it to decide which keys it can honestly name: a question
   with no choices makes [1-9] a promise the surface cannot keep. *)
let selected_ask_question (state : state) =
  match state.asks_snapshot with
  | None -> None
  | Some snapshot -> (
      match List.nth_opt (Ask_projection.open_rows snapshot) state.ask_cursor with
      | None -> None
      | Some (row : Masc.Tui_decode.ask_row) ->
          List.nth_opt row.Masc.Tui_decode.ar_questions state.ask_question_cursor)


(* Drawn into its own buffer so the pane above can be told how many rows it
   has to give up. Counting the rows a second way is what let the section draw
   its header into the one row left over and push every question off-screen. *)
let ask_section_rows buf =
  let n = ref 0 in
  String.iter (fun c -> if c = '\n' then incr n) (Buffer.contents buf);
  !n


let draw_ask_text_entry buf cols ~draft ~question (entry : ask_text_entry) =
  box_wrapped_field buf cols
    ~head:(Printf.sprintf "      %swrite: " Ansi.bold)
    ~style:Ansi.bold
    (Terminal_text.single_line entry.ate_text ^ "\xe2\x96\x8c");
  match Ask_projection.response_for draft ~question with
  | Some (Ask_projection.Draft_chose _) ->
      box_line buf cols
        (Printf.sprintf "      %ssaving replaces what you picked%s"
           Ansi.dim Ansi.reset)
  | Some (Ask_projection.Draft_wrote _)
  | Some Ask_projection.Draft_skipped
  | None -> ()


(* One question with everything the operator answers it by: the prompt, the
   choices and their marks, whatever the draft holds, and the free-text line.
   Lifted out of the panel so the panel can draw a question into a buffer of
   its own and ask how tall it came out before deciding to spend those rows. *)
let draw_ask_question buf cols (state : state) ~(row : Masc.Tui_decode.ask_row)
    ~draft ~(question : Masc.Tui_decode.ask_question) ~answering
    ~selected_question =
  (* The caret is the only thing saying where the cursor is: which question
     [a] opens while browsing, and which one the digits land on while
     answering. A blank on every row reads as no selection at all. *)
  let caret = if selected_question then ">" else " " in
  box_wrapped_field buf cols
    ~head:
      (Printf.sprintf " %s%s%s%s%s  " caret
         (if selected_question then Ansi.bold else "")
         (fit_width (Terminal_text.single_line row.Masc.Tui_decode.ar_keeper) 16)
         (if selected_question then Ansi.reset else "")
         Ansi.reset)
    ~style:(if selected_question then Ansi.bold else "")
    question.Masc.Tui_decode.aq_prompt;
  let chosen =
    match Ask_projection.response_for draft ~question with
    | Some (Ask_projection.Draft_chose ids) -> ids
    | Some (Ask_projection.Draft_wrote _)
    | Some Ask_projection.Draft_skipped
    | None -> []
  in
  List.iteri
    (fun choice_index (choice : Masc.Tui_decode.ask_choice) ->
      let picked =
        List.exists (String.equal choice.Masc.Tui_decode.ac_id) chosen
      in
      (* One mark shape per mode: a round one where only one answer fits, a
         square one where several do. The operator should not have to read the
         header to know whether picking a second choice replaces the first. *)
      let mark =
        match (question.Masc.Tui_decode.aq_mode, picked) with
        | Masc.Tui_decode.Ask_single, true -> "(o)"
        | Masc.Tui_decode.Ask_single, false -> "( )"
        | Masc.Tui_decode.Ask_multi, true -> "[x]"
        | Masc.Tui_decode.Ask_multi, false -> "[ ]"
      in
      (* Numbers only where they do something: the digits answer the question
         under the caret, and only once the operator is answering it. A number
         on every row, or one drawn while browsing, promises a key that does
         nothing. *)
      let position =
        if answering && selected_question && choice_index < 9 then
          Printf.sprintf "%d" (choice_index + 1)
        else " "
      in
      box_wrapped_field buf cols
        ~head:
          (Printf.sprintf "    %s %s %s%s%s  " position mark
             (if picked then Ansi.bold else Ansi.dim)
             (Terminal_text.single_line choice.Masc.Tui_decode.ac_id)
             Ansi.reset)
        ~style:(if picked then Ansi.bold ^ Theme.ok () else Theme.info ())
        choice.Masc.Tui_decode.ac_label;
      (* What picking this commits to. The wire carries it, the dashboard
         draws it under the label, and this pane dropped it -- so the operator
         answering from the terminal weighed a label where the one answering
         from a browser weighed a label and its consequence. *)
      match choice.Masc.Tui_decode.ac_description with
      | None -> ()
      | Some description ->
        box_wrapped_field buf cols
          ~head:"          "
          ~style:Ansi.dim
          (Terminal_text.single_line description))
    question.Masc.Tui_decode.aq_choices;
  (* What the operator has put down so far, in the two shapes a list of
     choices cannot show. *)
  (match Ask_projection.response_for draft ~question with
   | Some (Ask_projection.Draft_wrote text) ->
       box_wrapped_field buf cols
         ~head:(Printf.sprintf "      %swrote: " Ansi.bold)
         ~style:Ansi.bold text
   | Some Ask_projection.Draft_skipped ->
       box_line buf cols (Printf.sprintf "      %sskipped%s" Ansi.dim Ansi.reset)
   | Some (Ask_projection.Draft_chose _) | None -> ());
  let slot = Ask_projection.free_text_slot question in
  let aft_hint = Ask_projection.free_text_hint slot in
  (
      (* The editor belongs to one question, and the slot it holds names
         which. Matching on that rather than on the cursor means a snapshot
         arriving mid-sentence cannot move the typing onto another row. *)
      let editing_here =
        match state.ask_text_entry with
        | Some entry
          when String.equal
                 (Ask_projection.free_text_question_id entry.ate_slot)
                 question.Masc.Tui_decode.aq_id ->
            Some entry
        | Some _ | None -> None
      in
      match editing_here with
      (* The typing is drawn where it lands, with the same block caret the row
         search uses. Without it the keys went into a buffer nothing on screen
         showed, which reads as a terminal that has stopped listening. *)
      | Some entry ->
          draw_ask_text_entry buf cols ~draft ~question entry
      | None -> (
          let key =
            if not (answering && selected_question) then ""
            else match Ask_projection.alternative_position question with
              | Some position -> Printf.sprintf "[%d/t] " position
              | None -> "[t] "
          in
          let label =
            if question.Masc.Tui_decode.aq_choices = [] then "Write your answer"
            else "Other: write your own answer"
          in
          box_line buf cols
            (Printf.sprintf "      %s%s%s%s" (Theme.info ()) key label Ansi.reset);
          Option.iter (fun hint ->
            box_wrapped_field buf cols ~head:"      " ~style:Ansi.dim hint) aft_hint))


(* The reason is what separates a decision that matters from one that does
   not, so it is drawn, not hidden behind a detail view. *)
let draw_ask_context buf cols ~(row : Masc.Tui_decode.ask_row) =
  match row.Masc.Tui_decode.ar_context with
  | None -> ()
  | Some context ->
      box_wrapped_field buf cols
        ~head:(Printf.sprintf "    %swhy: " Ansi.dim)
        ~style:Ansi.dim context


(* Draw [f] into a buffer of its own and report how tall it came out. Height
   is a measured fact here rather than an estimate: a prompt wraps against the
   terminal's width, so the only honest way to know what a question costs is
   to draw it. *)
let ask_block f =
  let b = Buffer.create 256 in
  f b;
  (Buffer.contents b, ask_section_rows b)


let question_hints (state : state) =
    (* One name for the key in both modes. [ and ] call the same function
       either way -- they walk the asks -- and the surface used to call that
       "question" while browsing and "ask" while answering, which is the same
       key asking the operator to learn it twice. Named once here so the two
       footers cannot drift apart again.

       The vocabulary is the repository's: [/] walks the container a surface
       is a list of. Board says post, Changes says keeper, this says ask. *)
    let walk_asks = "[/]:ask" in
    match state.ask_answer_mode with
    | Ask_browsing ->
        Printf.sprintf
          "j/k:move  y / n:decide  w:Workspace mode  e:Outside mode  %s  a:answer a question  \
           r:refresh  Tab:next"
          walk_asks
    | Ask_answering { aam_ask_id } -> (
        match state.ask_text_entry with
        (* Typing owns the keyboard, so the footer stops offering the keys it
           has taken: the digits are text here, not choices. *)
        | Some _ -> "Enter:save  Esc:cancel"
        | None ->
            (* Say when the next Enter sends. The approval queue two panes up
               already draws its armed state; this one announced itself only as
               an event, on a surface that draws no events, so the first Enter
               looked like a key that had not landed. *)
            (match state.pending_ask_submit with
             | Some armed when String.equal armed aam_ask_id ->
                 "Press Enter again to send  |  s:skip  c:clear  Esc:back"
             | Some _ | None ->
                 (* Only the keys the selected question answers to. A question
                    can arrive with no choices at all -- the server accepts one
                    as long as it welcomes free text -- and there [1-9] does
                    nothing, which reads as a pane that has stopped listening
                    rather than as a key that was never for this question. *)
                 let question = selected_ask_question state in
                 let has_choices =
                   match question with
                   | Some (q : Masc.Tui_decode.ask_question) ->
                       q.Masc.Tui_decode.aq_choices <> []
                   | None -> false
                 in
                 let takes_text =
                   match question with
                   | Some _ -> true
                   | None -> false
                 in
                 Printf.sprintf "Left/Right:question  PgUp/PgDn:scroll  %s  %s%ss:skip  c:clear  \
                                 Enter:answer  Esc:back"
                   walk_asks
                   (if has_choices then "1-9:pick  " else "")
                   (if takes_text then "t:write  " else "")))
let question_asks (state : state) =
  match state.asks_snapshot with
  | None -> []
  | Some snapshot -> Ask_projection.open_rows snapshot


let ask_question_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let lines =
    match List.nth_opt (question_asks state) state.ask_cursor with
    | None -> ["  No questions waiting"]
    | Some row ->
        let draft = Ask_projection.draft_for state.ask_draft ~row in
        (match List.nth_opt row.ar_questions state.ask_question_cursor with
         | None -> ["  No question selected"]
         | Some question ->
             let text, _ = ask_block (fun b ->
               match state.ask_text_entry with
               | Some entry when String.equal
                   (Ask_projection.free_text_question_id entry.ate_slot) question.aq_id ->
                   (* Typing owns the keys. Keep the editor separate from
                      choices and context that can fill the reader. *)
                   box_wrapped_field b cols ~head:"  " ~style:Ansi.bold
                     question.aq_prompt;
                   draw_ask_text_entry b cols ~draft ~question entry
               | Some _ | None ->
                   draw_ask_question b cols state ~row ~draft ~question
                     ~answering:true ~selected_question:true;
                   draw_ask_context b cols ~row) in
             String.split_on_char '\n' text |> List.filter (fun line -> line <> ""))
  in
  (* title, progress, help, two dividers, outer edges and footer *)
  let room = max 1 (rows - 9) in
  (lines, room)

;;

(* The score is a reading, not text: up-voted draws ok, down-voted bad, and
   zero -- most posts -- stays muted rather than claiming a colour. *)
let board_score_style votes =
  if votes > 0 then (Theme.ok ())
  else if votes < 0 then (Theme.bad ())
  else (Theme.muted ())


(* Three steps for three bands, from the palette every other reading on this
   screen draws through. Emphasis only ever restates what the count beside it
   already says, so NO_COLOR costs a reader nothing they cannot read. *)
let magnitude_tone = function
  | Magnitude.Leading -> (Masc_tui_theme.tone Masc_tui_theme.Accent)
  | Magnitude.Ordinary -> Ansi.reset
  | Magnitude.Below_even_share -> Ansi.dim


(* One slot for the browser scene on screen. Module state rather than a field
   on [state], like [board_read_layout]: a wrapped row is a derived reading,
   not authority, and the input layer would otherwise invalidate it at every
   scroll. *)
let browser_lane_layout = Browser_lane_layout.create ()


let browser_lane_rows ~cols (view : Browser_lane_view.t) =
  (* The same three branches browser_lane_page_layout takes, so the key holds
     every input that decides a row. *)
  let content =
    match view.Browser_lane_view.scene with
    | Some scene -> Browser_lane_layout.Scene scene.content.Masc.Browser_scene.nodes
    | None ->
      (match view.Browser_lane_view.reading with
       | Some { page = Some page; _ } -> Browser_lane_layout.Page page.text
       | Some _ | None -> Browser_lane_layout.Empty)
  in
  let source =
    { Browser_lane_layout.content
    ; scene_cursor = view.Browser_lane_view.scene_cursor
    ; columns = cols
    }
  in
  Browser_lane_layout.get browser_lane_layout ~source ~render:(fun () ->
    browser_lane_page_layout ~cols view)


(* A shared, deliberately small status vocabulary for operational surfaces.
   Only the status token receives colour; titles and identifiers stay neutral,
   so colour says what changed rather than becoming row decoration. Unknown
   producer words remain visible and unranked. *)
let semantic_status_color status =
  (* Status producers already own their canonical wire vocabulary. Keeping
     that spelling intact also preserves Planning's Goal_phase SSOT: a renderer
     must not normalize domain status strings behind the decoder's back. *)
  match String.trim status with
  | "running" | "executing" | "active" | "in_progress" -> (Theme.info ())
  | "scheduled" | "due" | "pending" | "waiting" | "verifying"
  | "fallback" | "unknown" | "queued" | "degraded" | "matched_pending" ->
      (Theme.warn ())
  | "failed" | "failure" | "rejected" | "reject" | "refuted"
  | "unreadable" | "blocked" | "error" | "deny" | "denied" | "read_error"
  | "not_found" | "unrecognized_detail" | "unrecognized_receipt"
  | "missing_stimulus_id" | "invalid_stimulus_id" -> (Theme.bad ())
  | "succeeded" | "success" | "completed" | "complete" | "proven"
  | "approve" | "approved" | "answered" | "recorded" | "applied" | "ok"
  | "ready" | "pass" | "passed" | "allowed" | "matched_recorded"
  | "recognized" ->
      (Theme.ok ())
  | "cancelled" | "canceled" | "dropped" | "expired" | "skipped" ->
      Ansi.dim
  | _ -> Ansi.reset


(* The screen's word for a phase, not the wire's. [Goal_phase.to_string] is
   the value a tool filter and a stored goal carry, and one of them is
   [awaiting_confirmation] at 21 cells. The column below is as wide as the
   widest label, and TITLE gets what is left, so spelling the wire token here
   spent twelve columns of every planning row on one phase name and folded
   titles at 80 and 99 columns alike. Each label is a match arm so a new
   phase has to be given a word rather than inheriting a long one. *)
let planning_phase_label = function
  | Goal_phase.Executing -> "executing"
  | Goal_phase.Verifying -> "verifying"
  | Goal_phase.Awaiting_confirmation -> "confirming"
  | Goal_phase.Completed -> "completed"
  | Goal_phase.Dropped -> "dropped"


(* As wide as the widest phase rather than a literal. Three of the four labels
   are nine cells and the column was eight, so nearly every planning row read
   [complet~] with sixty columns of space to its right -- the mark that says
   "there was more" on a value nothing was cut from. Taken from the phase list
   so a new phase widens the column instead of losing its last letter. *)
let planning_phase_column =
  List.fold_left
    (fun widest phase ->
      max widest (Message_layout.display_width (planning_phase_label phase)))
    0
    Goal_phase.all


(* Three of the four phases are a health reading and one is not. Executing,
   Completed and Dropped are how the goal is doing; Verifying is where it
   is, and a goal under review is neither well nor unwell. It used to keep a
   raw colour for want of anywhere else to put it -- the theme had [status]
   for health, [tone] for weight and [Syntax] for what a token is, and
   nothing for a kind.

   It takes a categorical slot now (RFC-0431). Slot 4 is magenta, the hue it
   already drew, and magenta is one of the two the status axis does not
   claim -- which matters here, because the three phases beside it are
   status tokens and a slot aliasing one of those would read as a verdict.

   The count of these was thirteen. This is the last of them. *)
let planning_phase_color = function
  | Goal_phase.Executing -> (Theme.info ())
  | Goal_phase.Verifying -> Theme.category Theme.Slot_2
  | Goal_phase.Awaiting_confirmation -> Theme.warn ()
  | Goal_phase.Completed -> (Theme.ok ())
  | Goal_phase.Dropped -> (Theme.muted ())

;;

(* Planning is one operator workspace with three authorities behind it: Goal
   lifecycle, the Task verdict queue, and the verdicts the judge recorded.
   Keep their APIs separate, but make the hierarchy visible in the title
   instead of presenting unrelated top-level destinations.

   Verdicts arrived here from a top-level tab called "Harness", which named a
   mechanism rather than a thing an operator wants. It is the far half of Task
   Review: one lists what is waiting for a ruling and the other what was
   ruled, and they were a screen apart with nothing saying they were the same
   subject. *)
type planning_tab = Render_schedule.planning_tab =
  | Planning_goals
  | Planning_task_review
  | Planning_verdicts

(* [window] is the page-versus-ledger reading for the tab the reader is on,
   already formatted, e.g. " (8 of 4223)". It rides the active label because a
   count set loose at the end of the strip attaches itself to whatever label
   happens to be last: the verdict page count read as a Fusion count for as
   long as Schedules and Fusion were named here. Surfaces with nothing to
   count pass "". *)
let planning_workspace_title (state : state) ~(tab : planning_tab) ~(window : string) =
  let review_count = Option.map (fun s -> s.vs_total) state.verification in
  let verifying_count =
    Option.map
      (fun (p : planning_snapshot) -> p.pl_rollup.pr_verifying)
      state.planning
  in
  let labels =
    Render_schedule.planning_strip_plain ~tab ~review_count ~verifying_count
      ~window
  in
  let stops = [ Planning_goals; Planning_task_review; Planning_verdicts ] in
  let draw stop label =
    if stop = tab then
      (Theme.info ()) ^ Ansi.bold ^ "\xe2\x96\xb8" ^ label ^ Ansi.reset
    else Ansi.dim ^ label ^ Ansi.reset
  in
  String.concat "  "
    (screen_title " MASC Planning" :: List.map2 draw stops labels)


(* Where the goal stands with the completion judge, in one column. The phase
   reads [executing] both for a goal nobody asked about and for one the judge
   refused; without this the two are the same row. Idle is a blank rather than
   a glyph — most goals have never been asked, and a mark on all of them would
   carry no information. *)
let planning_proof_mark proof =
  let mark = Masc_tui_planning_proof_mark.glyph proof in
  match proof with
  | Tui_decode.Proof_idle -> mark
  | Tui_decode.Proof_proven _ -> (Theme.ok ()) ^ mark ^ Ansi.reset
  | Tui_decode.Proof_refuted _ -> (Theme.bad ()) ^ mark ^ Ansi.reset
  | Tui_decode.Proof_pending
  | Tui_decode.Proof_stale _
  | Tui_decode.Proof_unreadable _ ->
      (Theme.warn ()) ^ mark ^ Ansi.reset


(* The footer names the action behind each key for the keeper under the cursor,
   because which action the toggle sends depends on that keeper's state. A key
   with nothing behind it is dimmed rather than dropped, so the row of keys
   does not shift as the cursor travels. *)
(* A destructive action armed, or one already running. Status rather than a hint:
   [?] cannot recover "press d again to delete analyst", and the next unrelated
   key cancels the arm, so a footer that gives this up to fit something else
   gives up the only notice of a state the operator is standing in. The keys stay
   on the row beside it now instead of being replaced by it. *)
let keeper_action_status (state : state) : Masc_tui_footer.status_item list =
  match (state.keeper_action_inflight, state.keeper_action_pending) with
  | Some (keeper_name, action), _ ->
    [ Masc_tui_footer.Keeper_action_running
        { gerund = Keeper_control.action_gerund action
        ; keeper = Terminal_text.single_line keeper_name
        }
    ]
  | None, Some pending ->
    [ Masc_tui_footer.Keeper_action_armed
        { key = Keeper_control.action_key pending.Keeper_control.pending_action
        ; action =
            Keeper_control.action_label pending.Keeper_control.pending_action
        ; keeper =
            Terminal_text.single_line pending.Keeper_control.pending_keeper
        }
    ]
  | None, None -> []

let keeper_control_hints ?(offers_chat = true) ?(offers_back = true) state reading =
  let available =
    match reading with None -> [] | Some r -> Keeper_control.available r
  in
  (* An action that ends a fiber is toned apart from the reversible ones, so the
     key that needs two presses does not read like the keys that need one. *)
  let hint action label =
    let key_color =
      if Keeper_control.requires_confirmation action then (Theme.bad ()) else (Masc_tui_theme.tone Masc_tui_theme.Accent)
    in
    if List.mem action available then
      Printf.sprintf "%s%s%s:%s" key_color (Keeper_control.action_key action)
        Ansi.reset label
    else
      Printf.sprintf "%s%s:%s%s" Ansi.dim (Keeper_control.action_key action)
        label Ansi.reset
  in
  let toggle =
    match Option.bind reading Keeper_control.primary with
    | Some action -> hint action (Keeper_control.action_label action)
    | None -> Printf.sprintf "%sp:pause%s" Ansi.dim Ansi.reset
  in
  let gate_hint =
    match reading with
    | Some reading
      when List.mem reading.Keeper_control.name state.keeper_yolo_names ->
        (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "g" ^ Ansi.reset ^ ":auto"
    | Some _ | None -> (Theme.bad ()) ^ "g" ^ Ansi.reset ^ ":yolo"
  in
  (* [key:label] items, two spaces apart: the shape every other footer
     uses, so Masc_tui_footer can split the row, drop the lowest priority
     item when the row is tight, and keep the keys it never drops. Written
     "key label" and joined with a middle dot, the whole legend was one
     item nothing could split -- at 60 columns the row cut mid-word and
     "q quit", last in the list, went first. The two keys the footer pins
     lead with a plain key so it can read them past the colour. *)
      String.concat "  "
          [ Ansi.dim ^ "j/k:move" ^ Ansi.reset
          ; toggle
          ; hint Keeper_control.Wakeup "wake"
          (* RFC tui-server-lifecycle: with no server up, "s" starts one
             rather than shutting a keeper down, so the hint follows suit. *)
          ; (match state.connection_status with
             | Disconnected -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "s" ^ Ansi.reset ^ ":start server"
             | Connecting | Booting | Reconnecting | Degraded | Connected ->
                 hint Keeper_control.Shutdown "shutdown")
            (* Delete is the only action a keeper whose configuration failed to
               read still offers, and [primary] deliberately withholds it from
               the toggle. Without its own hint the footer showed that keeper a
               dimmed "p pause" and nothing else, so the one key that worked was
               the one key nothing named. *)
          ; hint Keeper_control.Delete "delete"
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "e" ^ Ansi.reset ^ ":settings"
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "a" ^ Ansi.reset ^ ":new"
          ; (if state.view = Keepers Keeper_detail then
               if state.detail_tab = Detail_sandbox then
                 (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "o" ^ Ansi.reset ^ ":container logs"
               else (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "o" ^ Ansi.reset ^ ":logs"
             else (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "l" ^ Ansi.reset ^ ":logs")
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "t" ^ Ansi.reset ^ ":calls"
          ; gate_hint
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent)
            ^ (if state.view = Keepers Keeper_detail then "U" else "u")
            ^ Ansi.reset ^ ":runtime"
            (* Dimmed rather than dropped, the same way an unavailable
               lifecycle key is: chat lives in detail, and a key that vanishes
               between surfaces reads as a key that does not exist. *)
          ; (if offers_chat then (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "c" ^ Ansi.reset ^ ":chat"
             else Ansi.dim ^ "c:chat" ^ Ansi.reset)
          ; (if offers_back then "Left / Esc:" ^ Ansi.dim ^ "back" ^ Ansi.reset
             else (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "right/enter" ^ Ansi.reset ^ ":detail")
          ; Ansi.dim ^ "r:refresh" ^ Ansi.reset
          ; "q:" ^ Ansi.dim ^ "quit" ^ Ansi.reset
          ]


(* One colour per level so an operator scanning the column sees severity before
   reading the text. A level this build does not name keeps its own text and
   renders unstyled rather than borrowing another level's colour. *)

(* What the footer says about the Keeper actions: the armed or running sentence
   when there is one, otherwise the keys. The sentence's words come from
   {!Masc_tui_footer}, which is also where the Keepers list reads them as a
   status item, so the two footers cannot word the same state differently. *)
let keeper_action_state_text (state : state) =
  match keeper_action_status state with
  | item :: _ ->
    Option.map
      (fun (projected : Masc_tui_footer.projected_status) ->
        Ansi.bold ^ (Theme.warn ()) ^ projected.text ^ Ansi.reset)
      (Masc_tui_footer.status_item_projection item)
  | [] -> None

let keeper_action_hints ?(offers_chat = true) ?(offers_back = true) state reading =
  match keeper_action_state_text state with
  | Some text -> text
  | None -> keeper_control_hints ~offers_chat ~offers_back state reading

let system_log_level_style : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> Ansi.dim
  | System_info -> Ansi.reset
  | System_warn -> (Theme.warn ())
  | System_error -> (Theme.bad ())
  | System_level_unknown _ -> Ansi.reset


let system_log_category_text (entry : Masc.Tui_decode.system_log_entry) =
  match entry.sl_category with
  | None -> "-"
  | Some category -> category


let fusion_run_status_color = function
  | Fusion_running -> (Theme.info ())
  | Fusion_completed -> (Theme.ok ())
  | Fusion_failed _ -> (Theme.bad ())


let fusion_run_progress_text = function
  | Fusion_stage_accepted -> "accepted; waiting for panel dispatch"
  | Fusion_stage_panel { frs_expected } ->
      Printf.sprintf "panel deliberation running across %d model(s)" frs_expected
  | Fusion_stage_judge { frs_expected; frs_answered; frs_failed } ->
      Printf.sprintf
        "panel complete: %d answered / %d failed of %d; judge running"
        frs_answered frs_failed frs_expected
  | Fusion_stage_computed { frs_expected; frs_answered; frs_failed } ->
      Printf.sprintf
        "compute complete: %d answered / %d failed of %d; awaiting durable projection"
        frs_answered frs_failed frs_expected
  | Fusion_stage_recording_evidence { frs_expected; frs_answered; frs_failed } ->
      Printf.sprintf
        "recording evidence: %d answered / %d failed of %d"
        frs_answered frs_failed frs_expected
  | Fusion_stage_completed -> "completed"
  | Fusion_stage_failed -> "failed"


let fusion_run_clock run =
  let tm = Unix.localtime run.fur_started_at in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min


let fusion_run_duration ~now run =
  match run.fur_status, run.fur_finished_at with
  | Fusion_running, _ -> Message_layout.span_text (now -. run.fur_started_at) ^ " running"
  | (Fusion_completed | Fusion_failed _), Some finished ->
      Message_layout.span_text (finished -. run.fur_started_at)
  | (Fusion_completed | Fusion_failed _), None -> "not recorded"


let fusion_run_age ~now run =
  Option.value ~default:"\xe2\x80\x94"
    (Message_layout.age_text ~now ~since:run.fur_started_at)


let repository_change_status (row : Masc.Tui_decode.repository_change) =
  if row.rc_conflicted then "conflict"
  else if row.rc_untracked then "untracked"
  else
    match row.rc_staged, row.rc_unstaged with
    | true, true -> "staged+worktree"
    | true, false -> "staged"
    | false, true -> "worktree"
    | false, false -> "unknown"


let box_line_span buf cols span =
  let inner = framed_inner_width cols in
  Buffer.add_string buf
    (Printf.sprintf "  %s  \n" (Span.render (Span.pad_to inner Span.plain (Span.truncate inner span))))


type change_context = {
  ctx_keeper : string option;
  ctx_task_id : string option;
  ctx_task_title : string option;
  ctx_task_description : string option;
  ctx_goal_id : string option;
  ctx_goal_title : string option;
  ctx_turn : int option;
  ctx_comment : string option;
  ctx_pr : Masc_tui_pr_ref.t option;
      (** An explicit PR reference -- a pull link or a PR-N token -- found in
          the task title, then its description, then the chat note. A bare
          [#n] is a list item as often as a PR and is not read as one. *)
}

let file_change_matches_path (path : string) (fc : Masc.Tui_decode.file_change) =
  match fc.Masc.Tui_decode.fc_location with
  | Masc.Tui_decode.Fc_in_repo { relative_path; _ } -> String.equal relative_path path
  | Masc.Tui_decode.Fc_in_bundle { bundle_path } -> String.equal bundle_path path
  | Masc.Tui_decode.Fc_at_absolute_path { path = p } ->
      String.equal p path || String.equal (Filename.basename p) (Filename.basename path)


let first_line_summary ?(max_len = 34) (s : string) : string =
  let lines = String.split_on_char '\n' s in
  let rec find_first = function
    | [] -> ""
    | l :: rest ->
        let tr = String.trim l in
        if String.length tr > 0 then tr else find_first rest
  in
  let line = find_first lines in
  Terminal_text.single_line (Message_layout.fit_middle max_len line)


let resolve_change_context (state : state) ~(path_opt : string option) : change_context =
  let matched_change =
    match path_opt, state.msg_file_changes with
    | Some path, Some snapshot ->
        List.find_opt
          (file_change_matches_path path)
          snapshot.Masc.Tui_decode.fcs_changes
    | _ -> None
  in
  let keeper =
    match matched_change with
    | Some fc -> Some fc.Masc.Tui_decode.fc_keeper
    | None -> state.msg_target_keeper_name
  in
  let keeper_record =
    match keeper with
    | Some name ->
        List.find_opt
          (fun (k : Masc.Tui_decode.keeper) -> String.equal k.Masc.Tui_decode.k_name name)
          state.keepers
    | None -> None
  in
  let task_id =
    match matched_change with
    | Some fc when Option.is_some fc.Masc.Tui_decode.fc_task_id -> fc.Masc.Tui_decode.fc_task_id
    | _ ->
        (match keeper_record with
         | Some k -> k.Masc.Tui_decode.k_current_task_id
         | None -> None)
  in
  let turn =
    match matched_change with
    | Some fc -> fc.Masc.Tui_decode.fc_turn
    | None -> None
  in
  let task =
    match task_id with
    | Some tid ->
        List.find_opt
          (fun (t : Masc.Tui_decode.task) -> String.equal t.Masc.Tui_decode.id tid)
          state.tasks
    | None -> None
  in
  let domain_task =
    match task_id with
    | Some tid ->
        List.find_opt
          (fun (t : Masc_domain.task) -> String.equal t.id tid)
          state.tasks_domain
    | None -> None
  in
  let task_title =
    match task with
    | Some t -> Some t.Masc.Tui_decode.title
    | None ->
        (match domain_task with
         | Some dt -> Some dt.title
         | None -> None)
  in
  let task_description =
    match domain_task with
    | Some dt when not (String.equal (String.trim dt.description) "") ->
        Some dt.description
    | _ -> None
  in
  let goal_id =
    match task with
    | Some t -> List.nth_opt t.Masc.Tui_decode.goal_ids 0
    | None -> None
  in
  let goal_title =
    match goal_id, state.planning with
    | Some gid, Some snapshot ->
        (match
           List.find_opt
             (fun (g : planning_goal) -> String.equal g.pg_id gid)
             snapshot.pl_goals
         with
         | Some g -> Some g.pg_title
         | None -> None)
    | _ -> None
  in
  let comment =
    match turn with
    | Some turn_seq ->
        let rec find_msg = function
          | [] -> None
          | (me : msg_entry) :: rest ->
              if me.me_turn_sequence = Some turn_seq
                 && not (String.equal (String.trim me.me_text) "") then
                Some me.me_text
              else
                find_msg rest
        in
        find_msg (List.rev state.msg_history)
    | None -> None
  in
  let effective_comment =
    match comment with
    | Some c -> Some c
    | None -> task_description
  in
  let pr =
    List.find_map
      (fun text -> Option.bind text Masc_tui_pr_ref.find)
      [ task_title; task_description; comment ]
  in
  { ctx_keeper = keeper
  ; ctx_task_id = task_id
  ; ctx_task_title = task_title
  ; ctx_task_description = task_description
  ; ctx_goal_id = goal_id
  ; ctx_goal_title = goal_title
  ; ctx_turn = turn
  ; ctx_comment = effective_comment
  ; ctx_pr = pr
  }


let build_change_context_lines (change_ctx : change_context) : string list =
  let line1_items = [] in
  let line1_items =
    match change_ctx.ctx_goal_id, change_ctx.ctx_goal_title with
    | Some gid, Some title ->
        Printf.sprintf "Goal: %s (%s)" gid (Message_layout.fit_middle 24 title) :: line1_items
    | Some gid, None -> ("Goal: " ^ gid) :: line1_items
    | None, _ -> line1_items
  in
  let line1_items =
    match change_ctx.ctx_task_id, change_ctx.ctx_task_title with
    | Some tid, Some title ->
        Printf.sprintf "Task: %s (%s)" tid (Message_layout.fit_middle 26 title) :: line1_items
    | Some tid, None -> ("Task: " ^ tid) :: line1_items
    | None, _ -> line1_items
  in
  let line1_items =
    match change_ctx.ctx_keeper with
    | Some k -> ("Keeper: " ^ k) :: line1_items
    | None -> line1_items
  in
  let line2_items = [] in
  let line2_items =
    match change_ctx.ctx_pr with
    | Some pr ->
        Printf.sprintf "PR: #%d" (Masc_tui_pr_ref.number pr) :: line2_items
    | None -> line2_items
  in
  let line2_items =
    match change_ctx.ctx_turn with
    | Some turn -> Printf.sprintf "Turn #%d" turn :: line2_items
    | None -> line2_items
  in
  let line2_items =
    match change_ctx.ctx_comment with
    | Some c when String.trim c <> "" ->
        ("Note: " ^ first_line_summary ~max_len:34 c) :: line2_items
    | _ -> line2_items
  in
  let l1_opt =
    if line1_items = [] then None
    else Some ("  " ^ String.concat "  |  " (List.rev line1_items))
  in
  let l2_opt =
    if line2_items = [] then None
    else Some ("  " ^ String.concat "  |  " (List.rev line2_items))
  in
  match l1_opt, l2_opt with
  | Some l1, Some l2 -> [ l1; l2 ]
  | Some l1, None -> [ l1 ]
  | None, Some l2 -> [ l2 ]
  | None, None -> []


let tree_diff_row_span ~width (row : Masc.Tui_decode.git_diff_row) =
  let background, marker =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_removed -> (Span.bg Theme.Syntax.diff_removed_bg, "-")
    | Masc.Tui_decode.Gd_added -> (Span.bg Theme.Syntax.diff_added_bg, "+")
    | Masc.Tui_decode.Gd_context -> (Span.plain, " ")
  in
  let gutter =
    Printf.sprintf "%s %s %s "
      (Diff.line_number_cell row.Masc.Tui_decode.gdr_old_line)
      (Diff.line_number_cell row.Masc.Tui_decode.gdr_new_line)
      marker
  in
  let text_style =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_context -> Span.combine background (Span.weight Ansi.dim)
    | Masc.Tui_decode.Gd_added | Masc.Tui_decode.Gd_removed -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.dim)) gutter
      ; Span.text text_style
          (Terminal_text.single_line row.Masc.Tui_decode.gdr_text)
      ]
  in
  Span.pad_to width background (Span.truncate width composed)


(* The two diff readings -- a Git Changes file against HEAD, and a change on
   the Changes tree -- draw one frame from different state. What differs is
   listed once here and the frame is drawn once below; each copy used to
   count its own chrome by hand. *)
type diff_surface =
  { ds_title : string  (** the screen title *)
  ; ds_address : string  (** what the header names beside "vs HEAD" *)
  ; ds_context_lines : string list
        (** drawn under the header, each followed by a divider *)
  ; ds_diff : Masc.Tui_decode.git_diff option  (** [None] until the tree is read *)
  ; ds_error : string option
  ; ds_scroll : int  (** the stored scroll, clamped here and reported back *)
  ; ds_unchanged : string  (** the empty line when the tree reports no change *)
  ; ds_esc_hint : string  (** what esc does on this surface *)
  ; ds_footer_hints : string
  ; ds_surface_key : string
  ; ds_clamped : int -> clamped_scroll
  }

(* Rows the frame spends outside the diff body: top border, header, its
   divider, the column caption, its divider, the status line, bottom border.
   A context line and the error line each add themselves plus a divider. *)
let diff_surface_fixed_chrome_rows = 7

let diff_surface_rows_per_context_line = 2

let diff_surface_error_rows = 2


let render_diff_surface (state : state) (ds : diff_surface) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let diff_rows =
    match ds.ds_diff with
    | None -> []
    | Some diff -> diff.Masc.Tui_decode.gd_rows
  in
  let total = List.length diff_rows in
  let header =
    Printf.sprintf "%s %s  vs HEAD  %s" (screen_title ds.ds_title) ds.ds_address
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  List.iter
    (fun ctx_line ->
      box_line buf cols ctx_line;
      box_divider buf cols)
    ds.ds_context_lines;
  box_line_styled buf cols ~style:(Theme.recede ())
    "  old   new     what the working tree holds, against its last commit";
  box_divider buf cols;
  (match ds.ds_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows =
    diff_surface_fixed_chrome_rows
    + (List.length ds.ds_context_lines * diff_surface_rows_per_context_line)
    + if Option.is_some ds.ds_error then diff_surface_error_rows else 0
  in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min ds.ds_scroll max_scroll) in
  let diff_rows_window = Rows.of_list ~first:scroll ~height:content_height diff_rows in
  if total = 0 then begin
    (* Three different facts, and none of them is the others: not read yet, a
       failed read, and a file that matches its last commit. *)
    let empty =
      match (ds.ds_diff, ds.ds_error) with
      | (Some _ | None), Some _ -> "  (the read failed; nothing here is a reading)"
      | None, None -> "  (reading the tree)"
      | Some diff, None ->
          if diff.Masc.Tui_decode.gd_has_changes then
            "  (the tree reports a change and sent no lines)"
          else ds.ds_unchanged
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match Rows.at diff_rows_window (i + scroll) with
      | None -> box_empty buf cols
      | Some row ->
          box_line_span buf cols (tree_diff_row_span ~width:(framed_inner_width cols) row)
    done;
  box_line_styled buf cols ~style:(Theme.recede ())
    (if total > content_height then
       Printf.sprintf "[%d lines, scroll %d]  %s" total scroll ds.ds_esc_hint
     else "  " ^ ds.ds_esc_hint);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:ds.ds_footer_hints);
  finish_surface state ~clamped:(ds.ds_clamped scroll)
    ~surface_key:ds.ds_surface_key ~rows:terminal_rows ~cols buf


let render_repository_changes_diff (state : state) ~path =
  let change_ctx = resolve_change_context state ~path_opt:(Some path) in
  render_diff_surface state
    { ds_title = " MASC Git Diff"
    ; ds_address = Terminal_text.single_line path
    ; ds_context_lines = build_change_context_lines change_ctx
    ; ds_diff =
        (* A diff held for another path is not this file's reading. *)
        (match state.repository_changes_diff with
         | Some (p, diff) when String.equal p path -> Some diff
         | Some _ | None -> None)
    ; ds_error = state.repository_changes_diff_error
    ; ds_scroll = state.repository_changes_diff_scroll
    ; ds_unchanged = "  (this file matches its last commit, or is untracked)"
    ; ds_esc_hint = "esc back to files"
    ; ds_footer_hints = Masc_tui_keys.footer_hints_git_diff
    ; ds_surface_key = "repository-changes-diff"
    ; ds_clamped = (fun scroll -> Repository_changes_diff_scroll scroll)
    }


(* Quota life state beside dispatchability: a dispatchable runtime whose
   provider side is refusing work for quota is "alive on paper" and the
   operator asked to see that distinction (2026-09-12). [resets_at] is the
   provider-stated deadline; its absence means a hard-quota rejection that
   claimed no reset -- cleared by the next success on the scope. *)
let runtime_quota_badge (runtime : Masc.Tui_decode.runtime_option) =
  if not runtime.ro_quota_exhausted then None
  else
    Some
      ( (Theme.warn ())
        ^ (match runtime.ro_quota_resets_at with
           | Some resets_at ->
             let tm = Unix.localtime resets_at in
             Printf.sprintf "quota exhausted (resets %02d:%02d)"
               tm.Unix.tm_hour tm.Unix.tm_min
           | None -> "quota exhausted (no reset stated)")
        ^ Ansi.reset )


let runtime_all_rows (snapshot : Masc.Tui_decode.runtime_surface_snapshot) =
  let open Masc.Tui_decode in
  List.map
    (fun (runtime : runtime_option) ->
       let lanes =
         snapshot.rss_resolved.rrs_lanes
         |> List.filter (fun (lane : runtime_resolved_lane) ->
                List.exists (String.equal runtime.ro_id) lane.rrl_runtime_ids)
         |> List.map (fun (lane : runtime_resolved_lane) -> lane.rrl_id)
       in
       runtime, lanes)
    snapshot.rss_resolved.rrs_runtimes


let tools_scrolled_for_lines state display_lines =
  { sc_count = List.length display_lines
  ; sc_chrome = if Option.is_some state.tools_error then 8 else 6
  ; sc_overflow_takes_row = true
  ; sc_preview_keep = None
  }


(* The Config surface: runtime.toml exactly as the server reads it. The
   text is the truth an editor session starts from; editing itself hands
   the terminal to $EDITOR and posts back through the preview gate. *)
(* The prompt registry as a list plus the selected caller's effective template.
   Some prompts feed a Keeper turn while others, such as Librarian, belong to
   separate exact lanes. The detail pane keeps that distinction visible before
   an operator chooses to hand the same text to [$EDITOR]. *)
(* Which of the three the Config surface is showing, and that [p] moves
   between them. This used to appear on Themes alone, as a list of names with
   no mark on it: it said the key exists and not where pressing it lands, and
   a reader on runtime.toml was told neither. *)
let config_pane_strip (state : state) =
  let name pane label =
    if state.config_pane = pane then
      Ansi.bold ^ "\xe2\x96\xb8" ^ label ^ Ansi.reset
    else Ansi.dim ^ " " ^ label ^ Ansi.reset
  in
  Ansi.dim ^ "9:Runtime  p:next  " ^ Ansi.reset
  ^ String.concat (Ansi.dim ^ " |" ^ Ansi.reset)
    [ name Config_runtime "runtime.toml"
    ; name Config_models "models"
    ; name Config_params "params"
    ; name Config_prompts "prompts"
    ; name Config_presets "presets"
    ; name Config_themes "themes"
    ; name Config_voice "voice"
    ]


let config_metadata_summary (state : state) =
  match state.runtime_config_view with
  | None -> []
  | Some reading ->
      let lines = Masc_tui_runtime_config_view.summary_lines reading.rcv_metadata in
      (match lines, state.runtime_config_view_error with
       | (tone, text) :: rest, Some _ -> (tone, "Previous read · " ^ text) :: rest
       | _ -> lines)


let runtime_config_status_lines state ~cols =
  let lines =
    (match state.runtime_config_view_error with
     | None -> []
     | Some detail -> [Masc_tui_runtime_config_view.Bad, "Read failed: " ^ detail])
    @ match state.runtime_config_view with
      | None -> [Masc_tui_runtime_config_view.Neutral, "Configuration has not been read"]
      | Some reading ->
          [Masc_tui_runtime_config_view.Neutral,
           (if Option.is_some state.runtime_config_view_error then "Previous source: " else "Source: ") ^ reading.rcv_path]
          @ Masc_tui_runtime_config_view.detail_lines reading.rcv_metadata
  in
  List.concat_map (fun (tone, text) ->
    Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols - 2))
      (Terminal_text.single_line text)
    |> List.map (fun text -> tone, text)) lines


(* The sheet's masthead. It carries no keys and no surface name: both scroll
   away with it, and both are said by rows that do not. The overlay's own title
   row is fixed chrome -- it draws "hints on/off . [h] toggle . [Esc] close" at
   every width, above the divider -- and the sheet's first section names the
   active surface two rows under this. *)
let help_ascii_banner ~cols (_state : state) =
  let inner_width = max 1 (framed_inner_width cols) in
  let bar_char = "\xe2\x94\x80" in
  let repeat_utf8 str count =
    let buf = Buffer.create (String.length str * count) in
    for _ = 1 to count do Buffer.add_string buf str done;
    Buffer.contents buf
  in
  if inner_width >= 72 then
    [ "  " ^ (Theme.info ()) ^ "\xe2\x95\x94\xe2\x95\xa6\xe2\x95\x97\xe2\x95\x94\xe2\x95\x90\xe2\x95\x97\xe2\x95\x94\xe2\x95\x90\xe2\x95\x97\xe2\x95\x94\xe2\x95\x90\xe2\x95\x97" ^ Ansi.reset
      ^ "  " ^ Ansi.bold ^ (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "M A S C" ^ Ansi.reset
      ^ "  \xc2\xb7  " ^ Ansi.bold ^ "Multi-Agent Shared Context" ^ Ansi.reset
    ; "  " ^ (Theme.info ()) ^ "\xe2\x95\x91\xe2\x95\x91\xe2\x95\x91\xe2\x95\xa0\xe2\x95\x90\xe2\x95\xa3\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x97\xe2\x95\x91    " ^ Ansi.reset
      ^ Ansi.dim ^ "Interactive Autonomous Fleet Workspace & Operations" ^ Ansi.reset
    ; "  " ^ (Theme.info ()) ^ "\xe2\x95\x9a \xe2\x95\xa9\xe2\x95\x9a \xe2\x95\xa9\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x9d\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x9d" ^ Ansi.reset
    ; "  " ^ (Theme.recede ()) ^ repeat_utf8 bar_char (min 68 (inner_width - 4)) ^ Ansi.reset
    ; ""
    ]
  else
    [ "  " ^ Ansi.bold ^ (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "[ MASC · Multi-Agent Shared Context ]" ^ Ansi.reset
    ; "  " ^ (Theme.recede ()) ^ repeat_utf8 bar_char (max 1 (inner_width - 4)) ^ Ansi.reset
    ; ""
    ]


(* The [?] help screen: every binding, grouped by the surface that answers
   it. The rows come from Masc_tui_keys -- the same table the footers read --
   so the two displays cannot drift apart. A key added to the dispatch gets
   its row there, once. *)
let help_lines (state : state) =
  let format_key key =
    let trimmed = String.trim key in
    if String.starts_with ~prefix:"[" trimmed && String.ends_with ~suffix:"]" trimmed then
      trimmed
    else
      "[" ^ trimmed ^ "]"
  in
  let section (title, entries) =
    let is_current =
      String.ends_with ~suffix:Masc_tui_keys.here_marker title
    in
    let header_line =
      if is_current then
        let marker_len = String.length Masc_tui_keys.here_marker in
        let base_title = String.sub title 0 (String.length title - marker_len) in
        (Theme.warn ()) ^ "\xe2\x97\x88 " ^ Ansi.bold ^ (Theme.info ())
        ^ "ACTIVE: " ^ String.uppercase_ascii base_title ^ Ansi.reset
      else if String.equal title "Global" then
        (Theme.info ()) ^ "\xe2\x97\x88 " ^ Ansi.bold
        ^ "GLOBAL NAVIGATION" ^ Ansi.reset
      else
        Ansi.dim ^ "\xe2\x97\x87 " ^ Ansi.reset ^ Ansi.bold ^ title ^ Ansi.reset
    in
    header_line
    :: List.map
         (fun (key, action) ->
           Printf.sprintf "  %s%-16s%s %s"
             (Masc_tui_theme.tone Masc_tui_theme.Accent)
             (format_key key)
             Ansi.reset
             action)
         entries
    @ [ "" ]
  in
  let slash_commands =
    ((Theme.warn ()) ^ "\xe2\x9a\xa1 " ^ Ansi.bold ^ "SLASH COMMANDS & WORKFLOWS" ^ Ansi.reset)
    :: List.map
         (fun (cmd : Masc_tui_command.command_help) ->
           let text = Masc_tui_command.usage cmd in
           let pad = String.make (max 2 (16 - String.length text)) ' ' in
           Printf.sprintf "  %s%s%s%s%s"
             (Theme.warn ())
             text
             Ansi.reset
             pad
             cmd.summary)
         Masc_tui_command.catalog
    @ [ "" ]
  in
  (* The first section is the reader's own surface, and it opens the sheet.
     The eleven lines of slash commands used to sit above it and pushed the
     answer past the fold; they are a reference and read as one here.

     [help_sections] puts Global first where the surface has no section of its
     own, so the head of this list is the most relevant thing either way and
     nothing has to look for it by name. *)
  match Masc_tui_keys.help_sections ~current:state.view () with
  | [] -> slash_commands
  | first :: rest ->
      section first @ slash_commands @ List.concat_map section rest


module Context_bars = Masc_tui_context_bars

let context_component_style = function
  | Turn_record.Prompt_block Prompt_block_id.Memory_os_recall ->
      Ansi.bold ^ Theme.category Theme.Slot_2
  | Turn_record.Prompt_block _ -> Ansi.bold
  | Turn_record.Tool_schemas -> (Theme.warn ())
  | Turn_record.Message_user -> (Theme.info ())
  | Turn_record.Message_tool_use | Turn_record.Message_tool_result -> (Masc_tui_theme.tone Masc_tui_theme.Accent)
  | Turn_record.Message_system | Turn_record.Message_assistant_text
  | Turn_record.Message_thinking | Turn_record.Message_redacted_thinking
  | Turn_record.Message_image | Turn_record.Message_document
  | Turn_record.Message_audio -> Ansi.reset


let context_evidence_style = function
  | Masc_tui_context_inspector.Verified_exact_text ->
      Ansi.bold ^ Theme.ok ()
  | Masc_tui_context_inspector.Serialized_turn_snapshot ->
      Ansi.bold ^ Theme.info ()
  | Masc_tui_context_inspector.Producer_digest_only ->
      Ansi.bold ^ Theme.category Theme.Slot_2
  | Masc_tui_context_inspector.Byte_count_only ->
      Ansi.bold ^ (Theme.recede ())


let context_evidence_badge evidence =
  Printf.sprintf "%s[ %s ]%s"
    (context_evidence_style evidence)
    (Masc_tui_context_inspector.input_evidence_label evidence)
    Ansi.reset


let context_split_width cols =
  let available = max 1 (framed_inner_width cols - 3) in
  min 62 (max 44 (available * 45 / 100))


let context_composition_lines ~cols ~turn_back
    (selection : Masc_tui_context_inspector.selection) =
  let module Inspector = Masc_tui_context_inspector in
  (* The usable cells after the two-space indent every row carries. No floor
     above one: a floor wider than the pane makes the rows overrun and the
     frame cut them, and every row builder here is exact at any width. *)
  let width = max 1 (framed_inner_width cols - 2) in
  let bar_width = min 60 width in
  (* Every reading outside the composition band describes the newest turn. The
     band describes the newest turn that recorded an exact composition, which
     is not always the same turn -- so the two are labelled separately rather
     than drawn as one turn's report. *)
  (* The row the operator stepped back to, or the newest one. Every
     reading in this stack describes this record; the composition band
     below keeps its own rule about which row it measured. *)
  let record =
    match List.nth_opt selection.Inspector.rows turn_back with
    | Some stepped -> stepped
    | None -> selection.Inspector.latest
  in
  (* The sentences under a bar carry what its number means, so they are folded
     to the pane rather than cut by it. *)
  let prose text =
    List.map
      (fun line -> "  " ^ Ansi.dim ^ line ^ Ansi.reset)
      (Context_bars.wrap ~width text)
  in
  (* Same folding for a row of figures, which keeps its own colour. *)
  let fact text =
    List.map (fun line -> "  " ^ line) (Context_bars.wrap ~width text)
  in
  let selected_model =
    Option.value ~default:"model not observed" record.selected_model
  in
  (* Three short rows rather than one long one. Joined, the turn number and
     the timestamp fall off the right edge of a narrow pane, and the turn
     number is what an operator matches against the chat above. *)
  let identity =
    Printf.sprintf "  %s%s%s  %s%s%s" Ansi.bold
      (Keeper_chat.terminal_safe_text selected_model)
      Ansi.reset Ansi.dim
      (Keeper_chat.terminal_safe_text record.runtime_profile)
      Ansi.reset
  in
  let turn =
    Printf.sprintf "  %sturn #%d  ·  %s%s" Ansi.dim record.absolute_turn
      (Masc_domain.iso8601_of_unix_seconds record.ts)
      Ansi.reset
  in
  let trace =
    Printf.sprintf "  %s%s%s" Ansi.dim
      (Keeper_chat.terminal_safe_text record.trace_id)
      Ansi.reset
  in
  let wire_headline =
    match record.request_wire_observation with
    | Some observation ->
        Printf.sprintf "  %s%s%s  %sprepared request  ·  %s%s" Ansi.bold
          (Inspector.format_bytes observation.body_bytes)
          Ansi.reset Ansi.dim
          (Keeper_chat.terminal_safe_text observation.runtime_profile)
          Ansi.reset
    | None ->
        Printf.sprintf "  %sProvider request bytes were not observed%s"
          (Theme.bad ()) Ansi.reset
  in
  let token_lines =
    match record.usage.scope with
    (* A cumulative counter covers the conversation, not this request, so
       dividing it by the window states an occupancy nobody measured. On
       2026-09-01 every turn whose reported input exceeded its own window --
       642 of them -- carried this scope, without a single exception. *)
    | Runtime_usage_scope.Conversation_cumulative -> (
        match record.usage.input_tokens, record.context_window with
        | Some tokens, Some maximum when maximum > 0 ->
            [ Printf.sprintf
                "  %s tokens counted across the conversation  %s(this \
                 request's own share was not reported)%s"
                (Inspector.format_tokens tokens) Ansi.dim Ansi.reset
            ; Printf.sprintf "  %sWindow %s tokens; no per-request figure to \
                              place in it%s"
                Ansi.dim (Inspector.format_tokens maximum) Ansi.reset
            ]
        | Some tokens, (None | Some _) ->
            [ Printf.sprintf
                "  %s tokens counted across the conversation  %s(window not \
                 observed)%s"
                (Inspector.format_tokens tokens) Ansi.dim Ansi.reset
            ]
        | None, _ -> [ "  Context usage was not reported for this turn" ])
    | Runtime_usage_scope.Per_request
    | Runtime_usage_scope.Usage_scope_unavailable -> (
        match record.usage.input_tokens, record.context_window with
        | Some tokens, Some maximum when maximum > 0 ->
            fact
              (Printf.sprintf
                 "%s / %s tokens  ·  %.1f%% of the window  ·  %s left"
                 (Inspector.format_tokens tokens)
                 (Inspector.format_tokens maximum)
                 (float tokens /. float maximum *. 100.)
                 (Inspector.format_tokens (max 0 (maximum - tokens))))
            @ [ "  "
                ^ Context_bars.ratio_bar ~width:bar_width ~numerator:tokens
                    ~denominator:maximum
              ]
        | Some tokens, (None | Some _) ->
            [ Printf.sprintf "  %s input tokens; window not observed"
                (Inspector.format_tokens tokens) ]
        | None, _ -> [ "  Context usage was not reported for this turn" ])
  in
  let cache_lines =
    let parts =
      List.filter_map Fun.id
        [ Option.map
            (fun n -> "cache read " ^ Inspector.format_tokens n)
            record.usage.cache_read_input_tokens
        ; Option.map
            (fun n -> "cache created " ^ Inspector.format_tokens n)
            record.usage.cache_creation_input_tokens
        ; Option.map
            (fun n -> "output " ^ Inspector.format_tokens n)
            record.usage.output_tokens
        ]
    in
    let label =
      match record.usage.scope with
      | Runtime_usage_scope.Conversation_cumulative -> "cumulative  "
      | Runtime_usage_scope.Per_request
      | Runtime_usage_scope.Usage_scope_unavailable -> ""
    in
    match parts with
    | [] -> []
    | _ -> prose (label ^ String.concat "  ·  " parts)
  in
  let history_lines =
    match record.model_input_window with
    | Some window ->
        let transmitted = window.transmitted_atoms in
        let total = window.total_atoms in
        let share =
          if total <= 0 then 0. else float transmitted /. float total *. 100.
        in
        [ Printf.sprintf "  %s%d of %d atoms%s  ·  %.1f%%  ·  %s%s%s" Ansi.bold
            transmitted total Ansi.reset share Ansi.dim
            (match window.measurement with
             | Turn_record.Wire_shape -> "wire shape"
             | Turn_record.Durable_shape -> "durable shape")
            Ansi.reset
        ; "  "
          ^ Context_bars.reach_bar ~width:bar_width ~transmitted ~total
              ~sent_style:(Theme.info ())
        ; "  " ^ Context_bars.reach_pointer ~width:bar_width ~transmitted ~total
        ]
        @ prose
            (Printf.sprintf
               "%d older atoms stayed behind. A cut falls between atoms, so a \
                tool result and the call it answers either both travel or \
                neither does."
               (max 0 (total - transmitted)))
    | None ->
        [ (Theme.bad ())
          ^ "  Conversation history window was not observed" ^ Ansi.reset
        ]
  in
  let component_lines =
    match
      (if turn_back > 0 then
         Option.map
           (fun components ->
              Masc_tui_context_inspector.
                { record; components; turns_behind_latest = 0 })
           record.Turn_record.input_components
       else selection.Inspector.attributed)
    with
    | None ->
        (if turn_back > 0 then
           [ (Theme.bad ())
             ^ Printf.sprintf
                 "  Turn #%d recorded no exact input composition"
                 record.Turn_record.absolute_turn
             ^ Ansi.reset
           ]
         else
           [ (Theme.bad ())
             ^ "  No turn on this page recorded an exact input composition"
             ^ Ansi.reset
           ; Ansi.dim ^ "  The readings above still describe the latest turn."
             ^ Ansi.reset
           ])
    | Some { Inspector.record = attributed; components; turns_behind_latest } ->
        let total =
          List.fold_left
            (fun total (component : Turn_record.input_component) ->
              total + component.bytes)
            0 components
        in
        (* The gap is the whole point of showing it: without it an operator
           reads a turn the keeper left behind as the current one. *)
        let gap =
          if turns_behind_latest = 0 then []
          else
            [ Printf.sprintf
                "  %sMeasured on turn #%d, %d turns before the readings \
                 above.%s"
                (Theme.warn ()) attributed.Turn_record.absolute_turn
                turns_behind_latest Ansi.reset
            ]
        in
        (* Biggest share first. The record's order is neither prompt order nor
           size order, and the stacked bar only reads as a picture when its
           shades run from the largest share down: there are four shades and a
           turn can carry nine components, so an unsorted row puts the repeated
           shade next to unrelated sizes. *)
        let ranked =
          List.stable_sort
            (fun (left : Turn_record.input_component)
                 (right : Turn_record.input_component) ->
              compare right.bytes left.bytes)
            components
        in
        let bar =
          if total = 0 then []
          else
            [ "  "
              ^ Context_bars.stacked_bar ~width:bar_width
                  ~segments:
                    (List.map
                       (fun (component : Turn_record.input_component) ->
                         ( context_component_style component.component
                         , component.bytes ))
                       ranked)
            ]
        in
        let rows =
          List.mapi
            (fun index (component : Turn_record.input_component) ->
              let share =
                if total = 0 then 0.
                else float component.bytes /. float total *. 100.
              in
              (* A component with bytes in it must not print as 0.0%: the
                 screen would then name a kind and deny it in the same row. *)
              let share_text =
                if component.bytes > 0 && share < 0.05 then "<0.1%"
                else Printf.sprintf "%.1f%%" share
              in
              let style = context_component_style component.component in
              Printf.sprintf "  %s%s %-22s%s %6s  %s%9s%s" style
                (Context_bars.segment_glyph index)
                (Inspector.input_component_label component.component)
                Ansi.reset share_text Ansi.dim
                (Inspector.format_bytes component.bytes)
                Ansi.reset)
            ranked
        in
        (* Attributed bytes and serialized bytes are compared on the same turn, never
           across two. They still disagree: on 2026-09-01 the attributed total
           ran about a fifth above the serialized-body figure across 1,556 turns, and the
           cause is not identified. Printing the gap is what keeps an operator
           from reading these bytes as the volume shipped. *)
        let against_wire =
          match attributed.Turn_record.request_wire_observation with
          | Some observation when total > 0 && observation.body_bytes > 0 ->
              prose
                (Printf.sprintf
                   "%s attributed here against %s in the serialized request, \
                    and the gap is unexplained. Read the shares as proportions \
                    and the prepared-request line as this turn's size."
                   (Inspector.format_bytes total)
                   (Inspector.format_bytes observation.body_bytes))
          | Some _ | None -> []
        in
        gap @ bar @ rows @ against_wire
  in
  (* The per-turn input the provider itself counted, newest first, one row
     per dispatched turn the page holds. A provider that reports its usage
     across the whole conversation gets a row that says so rather than a
     number that looks like this turn's and is not: the operator asked what
     goes in each turn, and only the provider's own per-request figure
     answers it. *)
  let recent_turns_lines =
    let row index (recent : Inspector.recent_turn) =
      let ts = Masc_domain.iso8601_of_unix_seconds recent.ts in
      (* The sentence each row can honestly carry depends on why a figure is
         absent: a conversation-cumulative provider has a number that is not
         about this turn, while a per-request provider that reported nothing
         simply reported nothing. One None in the data covers both, so the
         scope -- which the record owns -- decides. *)
      let marker = if index = turn_back then Ansi.bold ^ "▸" else " " in
      match recent.scope, recent.input_tokens with
      | Runtime_usage_scope.Conversation_cumulative, _ ->
          [ marker
            ^ Ansi.dim
            ^ Printf.sprintf
                " #%-4d %s  counted across the conversation, not per request"
                recent.turn ts
            ^ Ansi.reset
          ]
      | _, Some input ->
          fact
            (Printf.sprintf "%s #%-4d %s  in %-7s  cache read %-7s  out %s"
               (if index = turn_back then "▸" else " ")
               recent.turn ts
               (Inspector.format_tokens input)
               (match recent.cache_read with
                 | Some tokens -> Inspector.format_tokens tokens
                 | None -> "-")
               (match recent.output_tokens with
                 | Some tokens -> Inspector.format_tokens tokens
                 | None -> "-"))
      | _, None ->
          [ (if index = turn_back then Ansi.bold ^ "▸" else " ")
            ^ Ansi.dim
            ^ Printf.sprintf
                " #%-4d %s  input not reported for this turn"
                recent.turn ts
            ^ Ansi.reset
          ]
    in
    let inputs =
      List.filter_map
        (fun r ->
          match r.Inspector.input_tokens with
          | Some n when n > 0 -> Some n
          | _ -> None)
        selection.Inspector.recent
      |> List.rev
    in
    let velocity_lines =
      match inputs with
      | [] | [ _ ] -> []
      | _ ->
          let latest_tokens =
            match selection.Inspector.recent with
            | { input_tokens = Some n; _ } :: _ -> Inspector.format_tokens n
            | _ -> "-"
          in
          [ Printf.sprintf "  %sVelocity:%s %s  %s(%d turns recorded)  ·  latest %s tokens%s"
              Ansi.dim Ansi.reset
              (Chart.sparkline inputs)
              Ansi.dim
              (List.length inputs)
              latest_tokens
              Ansi.reset
          ]
    in
    [ "  "
      ^ Context_bars.band ~width ~title:"RECENT TURNS"
          ~caption:
            "input the provider counted, one row per dispatched turn"
    ]
    @ velocity_lines
    @ List.concat (List.mapi row selection.Inspector.recent)
  in
  [ identity; turn; trace; "" ]
  @ [ "  "
      ^ Context_bars.band ~width ~title:"SERIALIZED REQUEST"
          ~caption:"bytes prepared before dispatch"
    ]
  @ (wire_headline :: token_lines)
  @ cache_lines
  @ [ "" ]
  @ [ "  "
      ^ Context_bars.band ~width ~title:"HISTORY REACH"
          ~caption:"how far back this turn looked"
    ]
  @ history_lines
  @ [ "" ]
  @ [ "  "
      ^ Context_bars.band ~width ~title:"COMPOSITION"
          ~caption:"how this turn's content divides by kind"
    ]
  @ component_lines @ [ "" ]
  @ recent_turns_lines @ [ "" ]
  @ prose
      "Three measurements of one turn, not three views of one number: none of \
       them is a breakdown of another, and they do not add up."



(* The pane body comes in two shapes. The plain one scrolls as one list and
   carries the line its highlight sits on, if it has one. The split one is two
   columns with independent windows: the list keeps the cursor, the detail
   column keeps its own scroll, and neither drags the other. *)
type context_pane_body =
  | Plain of string list * int option
  | Split of
      { common : string list
      ; left : string list
      ; right : string list
      }

let context_exact_item_detail_lines ~width
    (item : Masc_tui_context_inspector.exact_input_item) =
  let module Inspector = Masc_tui_context_inspector in
  (* A message's text is wire JSON; its typed blocks are where the prose
     lives. Walking the blocks and rendering each part for what it is --
     markdown prose, a clipped JSON payload, a structural label -- is the
     difference between reading the item and re-reading the envelope. *)
  let section_lines = function
    | Retained_view.Text text ->
        document_markdown ~width (Keeper_chat.terminal_safe_text text)
    | Retained_view.Json payload ->
        String.split_on_char '\n' payload
        |> List.map (fun line ->
               (Masc_tui_theme.tone Masc_tui_theme.Accent)
               ^ Message_layout.fit_width
                   (Keeper_chat.terminal_safe_text line) width
               ^ Ansi.reset)
    | Retained_view.Marker label ->
        [ Ansi.bold
          ^ "▸ " ^ Keeper_chat.terminal_safe_text label
          ^ Ansi.reset
        ]
  in
  let body =
    Retained_view.sections ~text:item.text
    |> List.concat_map (fun group -> section_lines group @ [ "" ])
  in
  [ Ansi.bold ^ Theme.info () ^ "[ RETAINED ITEM ]" ^ Ansi.reset
  ; Ansi.bold ^ Inspector.exact_input_label item.kind ^ Ansi.reset
  ; Printf.sprintf "%s  ·  sha256 %s"
      (Inspector.format_bytes item.bytes)
      (String.sub item.sha256 0 12)
  ; ""
  ; Ansi.dim ^ "RETAINED PRE-DISPATCH CONTENT" ^ Ansi.reset
  ]
  @ body


(* Items grouped by kind, biggest group first, so the tab answers "what is
   this request made of" before it answers "what is item 34". Counted from the
   same items the list below draws, never from the composition tab's separate
   meter. *)
let context_exact_input_summary ~width
    (items : Masc_tui_context_inspector.exact_input_item list) =
  let module Inspector = Masc_tui_context_inspector in
  let tally = Hashtbl.create 8 in
  let order = ref [] in
  List.iter
    (fun (item : Inspector.exact_input_item) ->
      let key = Inspector.exact_input_category item.kind in
      match Hashtbl.find_opt tally key with
      | None ->
          order := key :: !order;
          Hashtbl.replace tally key (1, item.bytes)
      | Some (count, bytes) ->
          Hashtbl.replace tally key (count + 1, bytes + item.bytes))
    items;
  let groups =
    List.filter_map
      (fun key ->
        match Hashtbl.find_opt tally key with
        | None -> None
        | Some (count, bytes) -> Some (key, count, bytes))
      (List.rev !order)
  in
  let ranked =
    List.stable_sort
      (fun (_, _, left) (_, _, right) -> compare right left)
      groups
  in
  let total = List.fold_left (fun sum (_, _, bytes) -> sum + bytes) 0 ranked in
  let bar_width = min 60 width in
  let bar =
    if total = 0 then []
    else
      [ "  "
        ^ Context_bars.stacked_bar ~width:bar_width
            ~segments:(List.map (fun (_, _, bytes) -> "", bytes) ranked)
      ]
  in
  let rows =
    List.mapi
      (fun index (key, count, bytes) ->
        let share =
          if total = 0 then 0. else float bytes /. float total *. 100.
        in
        let share_text =
          if bytes > 0 && share < 0.05 then "<0.1%"
          else Printf.sprintf "%.1f%%" share
        in
        let label =
          key
          ^ String.make
              (max 0 (22 - Message_layout.display_width key))
              ' '
        in
        Printf.sprintf "  %s %s %s%3d %s%s  %9s  %6s"
          (Context_bars.segment_glyph index)
          label Ansi.dim count
          (if count = 1 then "item " else "items")
          Ansi.reset
          (Masc_tui_context_inspector.format_bytes bytes)
          share_text)
      ranked
  in
  ( [ "  "
      ^ Context_bars.band ~width ~title:"BY KIND"
          ~caption:
            (Printf.sprintf "%d items, %s retained" (List.length items)
               (Masc_tui_context_inspector.format_bytes total))
    ]
    @ bar @ rows
  , total )


let context_exact_input_lines ~cols state ~response ~response_parts
    (input : Masc_tui_context_inspector.provider_input) =
  let module Inspector = Masc_tui_context_inspector in
  let items = Inspector.exact_input_items input in
  let width = max 1 (framed_inner_width cols - 2) in
  match state.context_inspector_exact with
  | Some index ->
      (match List.nth_opt items index with
       | None ->
           Plain
             ( [ (Theme.bad ()) ^ "  Selected input item is no longer present"
                 ^ Ansi.reset
               ]
             , None )
       | Some item ->
           let detail =
             context_exact_item_detail_lines ~width item
             |> List.map (fun line -> "  " ^ line)
           in
           Plain (detail, None))
  | None ->
      let identity =
        Printf.sprintf "  Exact provider input  %s  %s"
          (Keeper_chat.terminal_safe_text
             (Ids.Turn_ref.to_string input.turn_ref))
          (Masc_domain.iso8601_of_unix_seconds input.captured_at)
      in
      let wire =
        Printf.sprintf "  Prepared request  %s · %s · %s · %s" input.wire.provider
          input.wire.model
          (Inspector.format_bytes input.wire.body_bytes)
          (String.sub input.wire.body_sha256 0 12)
      in
      let summary, retained = context_exact_input_summary ~width items in
      let against_wire =
        if retained > 0 && input.wire.body_bytes > 0 then
          [ Printf.sprintf "  %s%s retained here, %s in the serialized request%s"
              Ansi.dim
              (Inspector.format_bytes retained)
              (Inspector.format_bytes input.wire.body_bytes)
              Ansi.reset
          ]
        else []
      in
      (* What came back for this exact request, to the extent the turn
         record observed it. The response text lives in the chat store and
         is not joined here; the counts and the finish reason are the
         turn's own. *)
      let response_line =
        match response with
        | None -> []
        | Some (record : Turn_record.t) ->
            let parts =
              List.filter_map Fun.id
                [ Option.map
                    (fun tokens -> "output " ^ Inspector.format_tokens tokens)
                    record.usage.output_tokens
                ; Option.map
                    (fun reason ->
                       "finish "
                       ^ Keeper_chat.terminal_safe_text reason)
                    record.finish_reason
                ]
            in
            match parts with
            | [] -> []
            | _ ->
                [ Printf.sprintf "  Response  ·  %s" (String.concat "  ·  " parts) ]
      in
      (* The answer itself, to the depth one history page reaches. The cap
         keeps a long reply from taking the item list's window; the chat
         pane carries the full text and the note says so by counting. *)
      let response_block =
        match response_parts with
        | None -> []
        | Some
            { Masc_tui_context_inspector.parts = []
            ; outside_newest_page = true
            } ->
            [ "  "
              ^ Context_bars.band ~width ~title:"RESPONSE"
                  ~caption:"what came back for this request"
            ; Ansi.dim
              ^ "  This turn's reply is not in the newest history page"
              ^ Ansi.reset
            ]
        | Some { Masc_tui_context_inspector.parts; _ } ->
            let cap = 14 in
            let lines =
              List.concat_map
                (function
                  | Masc_tui_context_inspector.Reply_text text ->
                      document_markdown ~width
                        (Keeper_chat.terminal_safe_text text)
                  | Masc_tui_context_inspector.Tool_steps rows ->
                      List.map
                        (fun row ->
                           Ansi.dim
                           ^ Keeper_chat.terminal_safe_text row
                           ^ Ansi.reset)
                        rows
                  | Masc_tui_context_inspector.Reasoning_lines lines ->
                      List.map
                        (fun line ->
                           Ansi.dim ^ "· "
                           ^ Keeper_chat.terminal_safe_text line
                           ^ Ansi.reset)
                        lines)
                parts
            in
            let rec take count = function
              | [] -> ([], [])
              | line :: rest when count = 0 -> ([], line :: rest)
              | line :: rest ->
                  let shown, hidden = take (count - 1) rest in
                  (line :: shown, hidden)
            in
            let shown, hidden = take cap lines in
            ( [ "  "
                ^ Context_bars.band ~width ~title:"RESPONSE"
                    ~caption:"what came back for this request"
              ]
              @ shown
              @ (if hidden = [] then []
                 else
                   [ Ansi.dim
                     ^ Printf.sprintf
                         "  … %d more response lines; the chat pane carries                           the full reply"
                         (List.length hidden)
                     ^ Ansi.reset
                   ]) )
      in
      let common =
        [ identity; wire ] @ response_line @ [ "" ] @ summary @ against_wire
        @ response_block @ [ "" ]
      in
      (* One letter per row says where the item stands in the assembly. The
         wire is append-only, so the last message is this turn's newest
         addition and every earlier message is history the window carried
         forward; the prompt and the schemas are the fixed parts that ride
         every turn. The letter states a position on the wire, not a join
         the pane would have to invent. *)
      let last_message_index =
        List.fold_left
          (fun acc (index, (item : Inspector.exact_input_item)) ->
             match item.kind with
             | Inspector.Message _ -> Some index
             | _ -> acc)
          None
          (List.mapi (fun index item -> (index, item)) items)
      in
      let kind_letter index (item : Inspector.exact_input_item) =
        match item.kind with
        | Inspector.System_prompt -> "F"
        | Inspector.Tool_schema _ -> "S"
        | Inspector.Message _ ->
            if Some index = last_message_index then "N" else "H"
      in
      let rows width =
        List.mapi
          (fun index (item : Inspector.exact_input_item) ->
             let selected = index = state.context_inspector_cursor in
             let marker, style =
               if selected then ">", Theme.selection else " ", Ansi.reset
             in
             let label_width = max 8 (width - 20) in
             Printf.sprintf "%s %s %2d %s  %s  %9s%s" style marker (index + 1)
               (kind_letter index item)
               (fit_width (Inspector.exact_input_label item.kind) label_width)
               (Inspector.format_bytes item.bytes) Ansi.reset)
          items
      in
      let legend =
        Context_bars.wrap ~width
          "F fixed prompt · H history · N new this turn · S schema"
        |> List.map (fun line -> "  " ^ Ansi.dim ^ line ^ Ansi.reset)
      in
      let common = common @ legend @ [ "" ] in
      if cols >= keeper_split_threshold_cols then
        let left_width = context_split_width cols in
        let cursor =
          min (max 0 (List.length items - 1))
            (max 0 state.context_inspector_cursor)
        in
        let selected = List.nth_opt items cursor in
        (* The caret names the pane that hears j/k, the way the roster and
           the board say it; the keys themselves stay in the footer. *)
        let caret pane = if state.context_inspector_focus = pane then "▸ " else "" in
        let left =
          (Ansi.bold
           ^ "╭─ " ^ caret Left_pane ^ "REQUEST ITEMS"
           ^ Ansi.reset)
          :: (match rows left_width with
              | [] -> [ Ansi.dim ^ "  (no retained items)" ^ Ansi.reset ]
              | rows -> rows)
        in
        let right_width = max 8 (framed_inner_width cols - left_width - 3) in
        let selected_detail =
          match selected with
          | None -> [ Ansi.dim ^ "  Select an item with j/k" ^ Ansi.reset ]
          | Some item ->
              context_exact_item_detail_lines ~width:right_width item
        in
        (* The detail column starts at the top of its own window and keeps
           its own scroll. It used to be padded down to sit beside the
           selected row, which tied reading an item to standing on its row:
           the longer the list grew, the less of the item the pane could
           show. *)
        let right =
          (Ansi.bold
           ^ "╭─ " ^ caret Right_pane ^ "SELECTED INPUT"
           ^ Ansi.reset)
          :: selected_detail
        in
        Split { common; left; right }
      else
        let header =
          common
          @ [ "  "
              ^ Context_bars.band ~width ~title:"ITEMS"
                  ~caption:"in the order the request carries them"
            ]
        in
        let body =
          match rows (framed_inner_width cols) with
          | [] -> [ "  (this request carried no retained items)" ]
          | rows -> rows
        in
        let selected =
          if items = [] then None
          else
            Some
              (List.length header
              + min (List.length items - 1)
                  (max 0 state.context_inspector_cursor))
        in
        Plain
          ( header @ body
            @ [ ""
              ; Ansi.dim
                ^ "  Enter opens one retained item. The request digest identifies the pre-dispatch serialized body; each row carries its own retained digest."
                ^ Ansi.reset
              ]
          , selected )


let context_input_map_detail_lines ~width
    (row : Masc_tui_context_inspector.input_map_row) =
  let module Inspector = Masc_tui_context_inspector in
  let digest =
    match row.digest with
    | None -> "digest  —"
    | Some digest ->
        "digest  " ^ String.sub digest 0 (min 12 (String.length digest))
  in
  let explanation =
    match row.evidence with
    | Inspector.Verified_exact_text ->
        "The retained text, component byte count, and producer digest agree."
    | Inspector.Serialized_turn_snapshot ->
        "A same-turn pre-dispatch serialization snapshot exists, but no item-level join key binds this component row to one retained item. Inspect 2:request for the exact retained items."
    | Inspector.Producer_digest_only ->
        "The producer retained this prompt block's digest and byte count, but no same-turn exact snapshot is joined. The text cannot be verified or opened."
    | Inspector.Byte_count_only ->
        "Only the producer's component byte count is available. No exact provider snapshot is joined to this turn."
  in
  let wrap text =
    Message_layout.wrap_body ~max_cells:width
      ~sanitize:Keeper_chat.terminal_safe_text text
  in
  [ context_evidence_badge row.evidence
  ; Ansi.bold ^ Inspector.input_component_label row.component ^ Ansi.reset
  ; Printf.sprintf "%s  ·  %s"
      (Inspector.format_bytes row.bytes)
      (Inspector.input_source_label row.source)
  ; Ansi.dim ^ digest ^ Ansi.reset
  ; ""
  ]
  @ wrap explanation
  @
  match row.exact_text with
  | None -> []
  | Some text ->
      [ ""; Ansi.dim ^ "VERIFIED TEXT" ^ Ansi.reset ] @ wrap text


let context_input_map_lines ~cols state (record : Turn_record.t)
    (provider_input : Masc_tui_context_inspector.provider_input option) =
  let module Inspector = Masc_tui_context_inspector in
  let rows = Inspector.input_map_rows record provider_input in
  match state.context_inspector_exact with
  | Some index ->
      (match List.nth_opt rows index with
       | Some ({ exact_text = Some text; _ } as row) ->
           let width = max 8 (framed_inner_width cols - 4) in
           let heading =
             Printf.sprintf "  %s%s%s  ·  %s  ·  %s  ·  %s"
               Ansi.bold
               (Inspector.input_component_label row.component)
               Ansi.reset
               (Inspector.format_bytes row.bytes)
               (Inspector.input_source_label row.source)
               (context_evidence_badge row.evidence)
           in
           let digest =
             match row.digest with
             | None -> ""
             | Some digest ->
                 Printf.sprintf "  %sdigest %s%s" Ansi.dim
                   (String.sub digest 0 (min 12 (String.length digest)))
                   Ansi.reset
           in
           let body =
             Message_layout.wrap_body ~max_cells:width
               ~sanitize:Keeper_chat.terminal_safe_text text
             |> List.map (fun line -> "  " ^ line)
           in
           Plain (heading :: digest :: "" :: body, None)
       | Some _ | None ->
           Plain
             ( [ (Theme.bad ())
                 ^ "  Exact text is not retained for this component" ^ Ansi.reset
               ]
             , None ))
  | None ->
      let identity =
        Printf.sprintf "  Provider request map  %s#%d"
          (Keeper_chat.terminal_safe_text record.trace_id)
          record.absolute_turn
      in
      let joined =
        match provider_input with
        | Some input when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
            Ansi.bold ^ Theme.ok () ^ "[ EXACT TURN JOIN ]" ^ Ansi.reset
        | Some _ | None ->
            Ansi.bold ^ Theme.warn () ^ "[ NO EXACT INPUT JOIN ]" ^ Ansi.reset
      in
      let mapped width =
        List.mapi
          (fun index (row : Inspector.input_map_row) ->
             let selected = index = state.context_inspector_cursor in
             let marker, selection =
               if selected then ">", Theme.selection else " ", Ansi.reset
             in
             let branch = if index = List.length rows - 1 then "└─" else "├─" in
             let badge_cells = Inspector.input_evidence_badge_cells row.evidence in
             let label_width = max 4 (width - 17 - badge_cells) in
             Printf.sprintf "%s %s %s %s%s%s %9s %s%s"
               selection marker branch
               (context_component_style row.component)
               (fit_width (Inspector.input_component_label row.component) label_width)
               Ansi.reset
               (Inspector.format_bytes row.bytes)
               (context_evidence_badge row.evidence)
               Ansi.reset)
          rows
      in
      if cols >= keeper_split_threshold_cols then
        let left_width = context_split_width cols in
        let cursor =
          min (max 0 (List.length rows - 1))
            (max 0 state.context_inspector_cursor)
        in
        let caret pane = if state.context_inspector_focus = pane then "▸ " else "" in
        let left =
          (Ansi.bold
           ^ "╭─ " ^ caret Left_pane ^ "CONTEXT STACK"
           ^ Ansi.reset)
          :: (match mapped left_width with
              | [] -> [ Ansi.dim ^ "  (no component attribution)" ^ Ansi.reset ]
              | mapped -> mapped)
        in
        let right_width = max 8 (framed_inner_width cols - left_width - 3) in
        let selected_detail =
          match List.nth_opt rows cursor with
          | None -> [ Ansi.dim ^ "  Select a block with j/k" ^ Ansi.reset ]
          | Some row -> context_input_map_detail_lines ~width:right_width row
        in
        let right =
          (Ansi.bold
           ^ "╭─ " ^ caret Right_pane ^ "SELECTED BLOCK"
           ^ Ansi.reset)
          :: selected_detail
        in
        Split { common = [ identity; "  " ^ joined; "" ]; left; right }
      else
        let header =
          [ identity
          ; "  " ^ joined
          ; ""
          ; Ansi.bold ^ "  What the runtime prepared, and why" ^ Ansi.reset
          ]
        in
        let cursor =
          min (max 0 (List.length rows - 1))
            (max 0 state.context_inspector_cursor)
        in
        let body =
          match mapped (framed_inner_width cols) with
          | [] -> [ "  (exact component attribution unavailable)" ]
          | mapped ->
              List.mapi
                (fun index line ->
                   if index <> cursor
                   then [ line ]
                   else
                     let detail =
                       match List.nth_opt rows cursor with
                       | None -> []
                       | Some row ->
                           context_input_map_detail_lines
                             ~width:(max 8 (framed_inner_width cols - 4)) row
                           |> List.map (fun detail -> "    " ^ detail)
                     in
                     line
                     :: (Ansi.bold ^ "   ╰─ SELECTED BLOCK" ^ Ansi.reset)
                     :: detail)
                mapped
              |> List.concat
        in
        let selected =
          if rows = [] then None
          else
            Some
              (List.length header
              + min (List.length rows - 1)
                  (max 0 state.context_inspector_cursor))
        in
        Plain
          ( header @ body
            @ [ ""
              ; Ansi.dim
                ^ "  Enter opens VERIFIED text. Use 2:request for exact retained items."
                ^ Ansi.reset
              ]
          , selected )


(* The pane's rows, in either shape the tabs draw. A plain body carries the
   line its highlight sits on when it has one, so the window can follow it;
   only this module knows how many header rows a tab draws above its list,
   and a caller that guessed would scroll to the wrong row every time the
   header changed. *)
let context_inspector_content_lines ~cols state : context_pane_body =
  match state.context_inspector_reading with
  | None ->
      Plain
        ( [ (if state.context_inspector_loading then
                "  Loading provider-input evidence..."
              else "  No context reading has been requested.")
          ]
        , None )
  | Some (_, reading) ->
      (match state.context_inspector_tab with
       | Masc_tui_context_inspector.Composition ->
           (match reading.turn with
            | Ok selection ->
                Plain
                  ( context_composition_lines ~cols
                      ~turn_back:state.context_inspector_turn_back selection
                  , None )
            | Error detail ->
                Plain
                  ( [ (Theme.bad ()) ^ "  Composition unavailable: "
                      ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset
                    ]
                  , None ))
       | Masc_tui_context_inspector.Exact_input ->
           (match reading.provider_input with
            | Ok input ->
                let response, response_parts =
                  match reading.turn with
                  | Ok selection ->
                      ( Some selection.Masc_tui_context_inspector.latest
                      , (match reading.response with
                        | Ok parts -> Some parts
                        | Error _ -> None) )
                  | Error _ -> (None, None)
                in
                context_exact_input_lines ~cols state ~response
                  ~response_parts input
            | Error detail ->
                Plain
                  ( [ (Theme.bad ()) ^ "  Exact input unavailable: "
                      ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset
                    ]
                  , None ))
       | Masc_tui_context_inspector.Input_map ->
           (match reading.turn with
            | Error detail ->
                Plain
                  ( [ (Theme.bad ()) ^ "  Input map unavailable: "
                      ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset
                    ]
                  , None )
            | Ok selection -> (
                (* The newest reading keeps the attributed row -- it is the
                   row the exact provider input was fetched for, so the join
                   on this tab stays honest. A stepped-back turn names its
                   own row, snapshot or not. *)
                let viewing =
                  if state.context_inspector_turn_back = 0 then
                    Option.map
                      (fun (a : Masc_tui_context_inspector.attributed_turn) ->
                         a.record)
                      selection.Masc_tui_context_inspector.attributed
                  else
                    match
                      List.nth_opt selection.Masc_tui_context_inspector.rows
                        state.context_inspector_turn_back
                    with
                    | Some record -> Some record
                    | None ->
                        Option.map
                          (fun (a : Masc_tui_context_inspector.attributed_turn) ->
                             a.record)
                          selection.Masc_tui_context_inspector.attributed
                in
                match viewing with
                | None ->
                    (* The map is a per-component table; with no attribution
                       there are no rows to draw, and inventing them from the
                       latest turn's totals would state bytes nobody
                       measured. *)
                    Plain
                      ( [ (Theme.bad ())
                          ^ "  No turn on this page recorded an exact input \
                             composition" ^ Ansi.reset
                        ]
                      , None )
                | Some record ->
                    let provider_input =
                      match reading.provider_input with
                      | Ok input -> Some input
                      | Error _ -> None
                    in
                    context_input_map_lines ~cols state record provider_input)))


(* The rows a split body holds below the common summary: one pinned header
   row that carries both column titles and the focus caret, then the window
   the two columns share. The key handler and the frame both ask this,
   because keys that step past what the frame can show are the bug this pane
   was already carrying once. *)
let context_split_pane_height ~content_height ~common_len =
  max 0 (content_height - common_len - 1)

;;

let keeper_deletions_lines (state : state) ~cols =
  let lines = match state.keeper_deletions with
    | None -> ["삭제 기록을 불러오는 중입니다."]
    | Some (Error detail) -> ["삭제 기록 조회 실패: " ^ detail; "r: 다시 조회"]
    | Some (Ok inventory) ->
      let errors = List.map (fun error -> "종료 기록 오류: " ^ error) inventory.errors in
      let selected = List.nth_opt inventory.operations state.keeper_deletions_cursor in
      errors @ (match selected with
        | None -> ["저장된 키퍼 삭제 기록이 없습니다."]
        | Some row ->
          let status = match row.Keeper_control.operation with
            | Keeper_control.Configuration_removal receipt ->
              let label = match receipt.state with
                | Masc.Keeper_configuration_removal.Prepared -> "설정 삭제 접수"
                | Cleanup_required detail -> "설정 정리 실패: " ^ detail
                | Artifacts_removed -> "설정 파일 제거 대기"
                | Removed -> "설정 삭제 및 정리 완료" in
              Option.fold ~none:label ~some:(fun error -> label ^ ": " ^ error) receipt.last_error
            | Runtime_shutdown operation ->
              let open Masc.Keeper_shutdown_types in
              match operation.phase with
              | Finalized { completion = Completion_delivery_failed { detail; _ }; _ } ->
                "파일·설정 정리 실패: " ^ detail
              | Finalized { completion = Completion_pending _; _ } -> "파일·설정 정리 대기"
              | Blocked failure -> "종료 작업 중단: " ^ failure.detail
              | Reconciliation_required _ -> "진행 중이던 도구 실행 결과 확인 필요"
              | _ -> if row.completed then "삭제·정리 완료" else phase_to_string operation.phase in
          [Printf.sprintf "%d / %d · %s · %s"
             (state.keeper_deletions_cursor + 1) (List.length inventory.operations)
             (Keeper_control.deletion_keeper_name row) status;
           (if row.can_retry then "t: 같은 작업의 남은 정리 재시도" else "이 단계는 정리 재시도 대상이 아닙니다.");
           "종료 원장 원문 (설정·파일 정리 실패 원인 포함):"]
          @ String.split_on_char '\n'
              (Yojson.Safe.pretty_to_string (Keeper_control.deletion_json row)))
  in
  List.concat_map (fun line ->
    Message_layout.wrap_words ~max_cells:(max 1 (framed_inner_width cols))
      (Terminal_text.single_line line)) lines

;;

(* The panel behind [;]. The strip above the composer says whether anything is
   coming; this says what, and who is stopped waiting for an answer.

   Tone rather than a colour per row: the headings carry the structure, a
   held call is the one thing that needs answering now, and the wakes recede
   the same way they do on the strip. *)
let answering_lines (state : state) =
  Masc_tui_answering.overlay
    ~now:(Unix.gettimeofday ())
    ~chat_target:state.msg_target_keeper_name
    ~error:state.keeper_turns_error
    ~finishes:state.keeper_turn_finishes
    state.keeper_turns


(* The overlay ends in a fixed preview panel (divider + two lines): always
   drawn, so the list height never shifts with what the cursor is on — the
   fixed-chrome rule, applied before the panel exists rather than patched
   after (see boxed_surface_chrome_rows for the precedent). *)
let answering_preview_rows = 3

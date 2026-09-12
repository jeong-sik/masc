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

let surface_chrome (state : state) ~terminal_rows ~cols ~surface_key ~title
    ~hints ~(body : budget:int -> chrome_body -> unit) =
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
  finish_surface state ~surface_key ~rows:terminal_rows ~cols buf


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

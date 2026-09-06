(** TUI rendering functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

module Frame_presenter = Masc_tui_frame_presenter
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
module Board_comment_thread = Masc_tui_board_comment_thread
module Message_layout = Masc_tui_message_layout
module Tool_detail = Masc_tui_tool_detail
module Retained_view = Masc_tui_retained_view
module Metrics_tail = Masc_tui_metrics_tail
module Observation_layout = Masc_tui_observation_layout
module Context_state = Masc_tui_context_state
module Keeper_activity = Masc_tui_keeper_activity
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_diff = Masc_tui_keeper_chat_diff
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_schedule = Masc_tui_render_schedule
module Agenda = Masc_tui_agenda
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Keeper_control = Masc_tui_keeper_control
module Task_selection = Masc_tui_task_selection
module Tool_tree = Masc_tui_tool_tree
module Theme_choice = Masc_tui_theme_choice
module File_icon = Masc_tui_file_icon
module Approval_detail = Masc_tui_approval_detail
module Planning_detail = Masc_tui_planning_detail
module Link = Masc_tui_link
module Status = Masc.Keeper_status_runtime
module Render_tools = Masc_tui_render_tools
module Span = Masc_tui_span
module Diff = Masc_tui_diff
module Chart = Masc_tui_chart
module Render_metrics = Masc_tui_render_metrics
module Render_memory = Masc_tui_render_memory

type memory_state = Render_memory.memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error

module Board_composer = Masc_tui_board_composer

let json_assoc_member_opt = Masc_tui_json.member_opt

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
let acting_pane_reserved_cols = ref 0

(* What each drawn pane row acts on, and how far the pane can scroll, as of
   the last frame. A press or a wheel notch between frames is answered from
   what was on screen, which is these, not from what the next frame would
   draw. Empty when no pane was drawn, so a stale row cannot answer. *)
let acting_pane_row_targets : Masc_tui_acting_pane.row_target array ref = ref [||]
let acting_pane_scroll_max = ref 0

let acting_pane_target_at ~line =
  let targets = !acting_pane_row_targets in
  if line >= 0 && line < Array.length targets then targets.(line)
  else Masc_tui_acting_pane.Target_none

(* The input layer reads the last frame's pane through these, never the
   cells themselves: what it needs is the answer, and the cells stay this
   module's to set once per frame. *)
let acting_pane_drawn_cols () = !acting_pane_reserved_cols
let acting_pane_scroll_limit () = !acting_pane_scroll_max

let get_terminal_size () =
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  (max 1 (rows - 1), max 1 (cols - !acting_pane_reserved_cols))

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

(* What a boxed listing draws under its rows: the scroll line -- a row whether
   or not there is anything to report, so a list that overflows does not push
   the help line off the bottom -- then the frame's bottom, then the footer.

   Named once because three surfaces were tallying their whole chrome by hand,
   and being one row over the budget is not a visible mistake: [finish_surface]
   drops the last rows, and the last row is the footer. *)
let listing_rows_below_the_body = 3

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
  for i = 0 to content_height - 1 do
    match List.nth_opt labels (first + i) with
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
;;

(* Whether tables are drawn with an outer box, read once from [tui].table_frame
   at start-up. Held here rather than threaded through every caller of
   [chat_markdown_palette]: the palette is built fresh on each render, so this
   is the one setting projected into it rather than a second copy of it. *)
let table_frame_enabled = ref false
let set_table_frame enabled = table_frame_enabled := enabled

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

let chat_markdown ~context ~width body =
  markdown_with_closing ~closing:context.Chat_theme.markdown_close ~width body

(* Documents outside a conversation have no ambient role background to
   restore. Keep their former reset boundary explicit instead of inventing a
   synthetic chat role or taking a terminal-palette snapshot. *)
let document_markdown ~width body =
  markdown_with_closing ~closing:Ansi.reset ~width body

let fenced_document_text ~language text =
  match
    Masc_tui_markdown.non_colliding_fence_marker
      (String.split_on_char '\n' text)
  with
  | Some marker -> String.concat "\n" [ marker ^ language; text; marker ]
  | None -> text

let fenced_pretty_json text =
  let pretty =
    match Yojson.Safe.from_string text with
    | json -> Yojson.Safe.pretty_to_string json
    | exception Yojson.Json_error _ -> text
  in
  fenced_document_text ~language:"json" pretty

(* Board accepts ordinary Markdown, so JSON detection is deliberately the
   narrow whole-document case. Objects and arrays are operational payloads;
   a post containing a scalar or a JSON-shaped fragment remains exactly the
   Markdown its author wrote. *)
let board_document_source body =
  let trimmed = String.trim body in
  match Yojson.Safe.from_string trimmed with
  | (`Assoc _ | `List _) as json ->
      Yojson.Safe.pretty_to_string json
      |> fenced_document_text ~language:"json"
  | _ -> body
  | exception Yojson.Json_error _ -> body

let board_document_markdown ~width body =
  document_markdown ~width (board_document_source body)

(* The semantic Markdown palette itself is compiled into this binary. The
   generation travels separately because only a user row's ambient terminal
   background changes its closing strings. *)
let chat_markdown_theme_revision = 1

(* Large enough to hold what a scrolled pane walks.

   A frame lays out the newest [scroll + height] rows, so reading back through
   a long turn walks hundreds of messages and asks this cache for each. At a
   hundred and twenty-eight the walk evicted its own earlier answers before
   the next frame asked for them again, and every notch of the wheel rendered
   the same messages over: the pane's worst frames were spent here. The store
   finds an entry by its identity rather than by walking, so a bound this size
   costs a hash per lookup and the memory of the rows themselves. *)
let chat_markdown_cache_capacity = 1024


type chat_markdown_identity = {
  cmi_style : Message_layout.style;
  cmi_keeper_name : string;
  cmi_request_id : string;
  cmi_observed_at : float option;
  cmi_entry_index : int;
}

let chat_markdown_cache =
  Markdown_cache.create ~capacity:chat_markdown_cache_capacity

let chat_markdown_streaming ~context ~width body =
  Markdown.render_streaming
    ~palette:(chat_markdown_palette ~closing:context.Chat_theme.markdown_close)
    ~width body

let cached_chat_markdown ~theme ~(entry : Message_layout.entry) ~width =
  let context = Chat_theme.body_context theme entry.style in
  let palette_generation = context.palette_generation in
  match entry.markdown_source with
  | Message_layout.Markdown_stable
      { keeper_name; request_id; observed_at; entry_index } ->
      let source =
        Markdown_cache.Stable_source
          { identity =
              { cmi_style = entry.style;
                cmi_keeper_name = keeper_name;
                cmi_request_id = request_id;
                cmi_observed_at = Some observed_at;
                cmi_entry_index = entry_index;
              };
            text = entry.body;
          }
      in
      Markdown_cache.render chat_markdown_cache
        ~theme_revision:chat_markdown_theme_revision
        ~palette_generation ~width ~renderer:(chat_markdown ~context) ~source
  | Message_layout.Markdown_growing
      { keeper_name; request_id; entry_index } ->
      Markdown_cache.render_growing chat_markdown_cache
        ~theme_revision:chat_markdown_theme_revision
        ~palette_generation ~width
        ~renderer:(chat_markdown_streaming ~context)
        ~identity:
          { cmi_style = entry.style;
            cmi_keeper_name = keeper_name;
            cmi_request_id = request_id;
            cmi_observed_at = None;
            cmi_entry_index = entry_index;
        }
        ~text:entry.body
  | Message_layout.Markdown_streaming ->
      chat_markdown ~context ~width entry.body

(* Conversation colour names the source, not the prose. A keeper can return a
   page of Markdown; painting every byte green turns syntax, emphasis, links,
   and ordinary text into one undifferentiated status light. The compact
   reverse-video badge gives the source a background that works with the
   terminal's own light or dark palette, while the body keeps its semantic
   Markdown colours. *)
(* How many reasoning lines a folded block stands for. The count is the
   non-blank lines, matching what the unfolded block draws. *)
let folded_thinking_summary body =
  let lines =
    String.split_on_char '\n' body
    |> List.filter (fun line -> String.trim line <> "")
  in
  match lines with
  (* A fold summary is itself one line, so folding one line hides nothing and
     saves nothing. It also promised an expansion: every committed reasoning
     block is the withheld-step count alone, and Ctrl-R on it redrew the same
     sentence. A block with nothing to fold draws as itself. *)
  | [] | [ _ ] -> body
  | lines ->
      Printf.sprintf
        "Reasoning · %d line(s) folded · Ctrl-R or /thinking to expand"
        (List.length lines)

(* What a page says when it holds nothing, in one place.

   These were spelled at every surface that draws a page -- nine copies of the
   failure line and nine of the unread one -- and the unread copies said only
   that nothing had loaded. [r] is what loads it, and the reader was left to
   find that out somewhere else. Two surfaces did name the key, which is how a
   reader on the others learned there was nothing to learn. *)
let page_unread_note = "  (not loaded yet \xe2\x80\x94 press r)"
let page_failed_note = "  (load failed; nothing here is a reading)"

let tool_projection_mode (state : state) =
  match state.msg_tool_visibility with
  | Tools_compact -> Keeper_chat_transcript.Compact
  | Tools_full -> Keeper_chat_transcript.Full

let is_all_digits s =
  String.length s > 0
  &&
  let rec loop i =
    if i >= String.length s then true
    else if s.[i] >= '0' && s.[i] <= '9' then loop (i + 1)
    else false
  in
  loop 0
;;

let split_last_space s =
  match String.rindex_opt s ' ' with
  | None -> None
  | Some idx ->
    let first = String.sub s 0 idx in
    let second = String.sub s (idx + 1) (String.length s - idx - 1) in
    Some (first, second)
;;

let split_on_middle_dot (s : string) : string list =
  let len = String.length s in
  let rec scan last_pos pos acc =
    if pos + 4 > len then
      List.rev (String.sub s last_pos (len - last_pos) :: acc)
    else if Char.equal s.[pos] ' '
            && Char.equal s.[pos + 1] '\xc2'
            && Char.equal s.[pos + 2] '\xb7'
            && Char.equal s.[pos + 3] ' ' then
      let piece = String.sub s last_pos (pos - last_pos) in
      scan (pos + 4) (pos + 4) (piece :: acc)
    else
      scan last_pos (pos + 1) acc
  in
  scan 0 0 []
;;

let contains_sub s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub = 0 then true
  else if len_s < len_sub then false
  else
    let rec check i j =
      if j >= len_sub then true
      else if Char.equal s.[i + j] sub.[j] then check i (j + 1)
      else false
    in
    let rec loop i =
      if i + len_sub > len_s then false
      else if check i 0 then true
      else loop (i + 1)
    in
    loop 0
;;

let extract_tool_marker s =
  let markers = [ "✓"; "✗"; "×"; "√"; "▶"; "◌"; "!"; "?" ] in
  List.find_opt (fun m -> String.starts_with ~prefix:m s) markers
;;

let tool_marker_color = function
  | "✓" | "√" -> Theme.ok ()
  | "✗" | "×" | "!" -> Ansi.bold ^ Theme.bad ()
  | "▶" | "?" -> Theme.warn ()
  | "◌" -> Theme.info ()
  | _ -> Ansi.reset
;;

let dress_tool_clause (clause : string) : string =
  let c = String.trim clause in
  match extract_tool_marker c with
  | Some m ->
    let rest =
      String.trim (String.sub c (String.length m) (String.length c - String.length m))
    in
    let col = tool_marker_color m in
    if String.starts_with ~prefix:"Tools " rest || String.starts_with ~prefix:"Ran " rest then
      match split_last_space rest with
      | Some (word, count) when is_all_digits count ->
        Printf.sprintf "%s%s%s %s%s%s %s%s%s" col m Ansi.reset
          (Ansi.bold ^ Theme.info ()) word Ansi.reset
          (Theme.recede () ^ Ansi.dim) count Ansi.reset
      | _ ->
        Printf.sprintf "%s%s%s %s%s%s" col m Ansi.reset
          (Ansi.bold ^ Theme.info ()) rest Ansi.reset
    else
      (match String.index_opt rest ' ' with
       | Some idx ->
         let name = String.sub rest 0 idx in
         let args = String.sub rest idx (String.length rest - idx) in
         Printf.sprintf "%s%s%s %s%s%s%s" col m Ansi.reset
           (Theme.tool_origin ()) name Ansi.reset args
       | None ->
         Printf.sprintf "%s%s%s %s%s%s" col m Ansi.reset
           (Theme.tool_origin ()) rest Ansi.reset)
  | None ->
    if String.starts_with ~prefix:"Tools " c then
      match split_last_space c with
      | Some (word, count) when is_all_digits count ->
        Printf.sprintf "%s%s%s %s%s%s"
          (Ansi.bold ^ Theme.info ()) word Ansi.reset
          (Theme.recede () ^ Ansi.dim) count Ansi.reset
      | _ -> Printf.sprintf "%s%s%s" (Ansi.bold ^ Theme.info ()) c Ansi.reset
    else if contains_sub c "detail" && contains_sub c "folded" then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c Ansi.reset
    else if String.starts_with ~prefix:"Ctrl-" c || contains_sub c "carried by the transcript" then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c Ansi.reset
    else if (String.ends_with ~suffix:"ms" c || String.ends_with ~suffix:"s" c)
            && (match split_last_space c with None -> true | Some (_, _) -> false) then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c Ansi.reset
    else if contains_sub c "returned" || contains_sub c "failed" || contains_sub c "awaiting" || contains_sub c "running" then
      if contains_sub c ", " then
        let parts = String.split_on_char ',' c in
        let dressed =
          List.map
            (fun p ->
              let p = String.trim p in
              if String.ends_with ~suffix:"returned" p then
                Printf.sprintf "%s%s%s" (Theme.ok ()) p Ansi.reset
              else if contains_sub p "failed" || contains_sub p "never returned" then
                Printf.sprintf "%s%s%s" (Ansi.bold ^ Theme.bad ()) p Ansi.reset
              else if contains_sub p "awaiting" then
                Printf.sprintf "%s%s%s" (Theme.warn ()) p Ansi.reset
              else if contains_sub p "running" then
                Printf.sprintf "%s%s%s" (Theme.info ()) p Ansi.reset
              else p)
            parts
        in
        String.concat ", " dressed
      else if String.ends_with ~suffix:"returned" c then
        Printf.sprintf "%s%s%s" (Theme.ok ()) c Ansi.reset
      else if contains_sub c "failed" || contains_sub c "never returned" then
        Printf.sprintf "%s%s%s" (Ansi.bold ^ Theme.bad ()) c Ansi.reset
      else if contains_sub c "awaiting" then
        Printf.sprintf "%s%s%s" (Theme.warn ()) c Ansi.reset
      else if contains_sub c "running" then
        Printf.sprintf "%s%s%s" (Theme.info ()) c Ansi.reset
      else c
    else
      match split_last_space c with
      | Some (name, count) when is_all_digits count ->
        Printf.sprintf "%s%s%s %s%s%s"
          (Theme.tool_origin ()) name Ansi.reset
          (Theme.recede () ^ Ansi.dim) count Ansi.reset
      | _ -> c
;;

let dress_tool_summary (line : string) : string =
  let parts = split_on_middle_dot line in
  let dressed = List.map dress_tool_clause parts in
  let sep = Printf.sprintf " %s\xc2\xb7%s " (Theme.recede () ^ Ansi.dim) Ansi.reset in
  String.concat sep dressed
;;

let render_chat_row ~theme buf cols (row : Message_layout.row) =
  match row.kind with
  | Message_layout.Viewport_gap { hidden_rows = _ } ->
      (* The glyph survives NO_COLOR; the adaptive recede keeps the separator
         visible without competing with the message above and below it. *)
      box_line_styled buf cols ~style:(Theme.recede ()) row.text
  | Message_layout.Body ->
      (* The two cells reserved by the layout separate the activity column from
         its body. The semantic lead lives with the origin label, so wrapped
         prose starts at one stable column without drawing a rail on every row.
         That rail gave a continuation equal visual weight to a new event and
         made a busy turn look like a table. *)
      let text = row.text in
      let context = Chat_theme.body_context theme row.style in
      let is_tool = match row.style with Message_layout.Tool -> true | _ -> false in
      let dress rest =
        if is_tool then
          dress_tool_summary rest
        else
          Masc_tui_message_layout.dress_bare_links
            ~open_style:(Ansi.underline ^ Theme.Syntax.link)
            ~close_style:context.link_restore
            rest
      in
      (* Folded origins are the heading of each activity block. Keep them in
         the role colour and bold while the body stays neutral: after the old
         rail was removed, leaving this whole column dim made every speaker
         and tool block look like continuation metadata. An empty gutter adds
         no bytes at all, so a pane showing origins on their own rows draws
         exactly what it drew before this margin existed. *)
      (* Colour says status, and a row gets one of it. The whole gutter used to
         take the status colour and bold, so an errored turn painted its kind
         label red alongside its glyph and the row carried the same fact twice.
         The glyph keeps the colour -- it is the part that survives NO_COLOR as
         a shape -- and the label recedes into the dimmest step, saying only
         which kind of row this is.

         [gutter_label_at] is the layout's own count of the clock and mark it
         placed; measuring the glyph again here is how the two drift. *)
      let margin =
        if String.equal row.gutter "" then ""
        else
          let restore =
            if context.ambient_background then context.inline_restore
            else Ansi.reset
          in
          let width = Message_layout.display_width row.gutter in
          let at = max 0 (min row.gutter_label_at width) in
          let rail_cells = max 0 (min row.gutter_rail_cells at) in
          (* A plain prefix, not [fit_width]: that one marks an overrun with a
             trailing "~", which here would land in the middle of the gutter.
             Not [split_cells] either -- it wraps, so it hands back one piece
             even at zero cells, and a row that continues the speaker above it
             carries no mark and asks for exactly zero. That drew the clock's
             first digit twice: "222:32" for a row sent at 22:32. *)
          (* The turn rail is structure, not status, so it takes the quiet tone
             rather than the speaker's colour. An errored turn already says so
             on its own glyph; painting the bracket red as well would say it a
             second time, down the side of every row the turn touched. *)
          let rail = Message_layout.take_cells row.gutter rail_cells in
          let after_rail = Message_layout.drop_cells row.gutter rail_cells in
          let marked = Message_layout.take_cells after_rail (at - rail_cells) in
          let label = Message_layout.drop_cells after_rail (at - rail_cells) in
          let rail =
            if String.equal rail "" then ""
            else Printf.sprintf "%s%s%s" (Theme.recede ()) rail Ansi.reset
          in
          if String.equal label "" then
            Printf.sprintf "%s%s%s%s%s" rail (Chat_theme.origin row.style)
              Ansi.bold marked restore
          else
            Printf.sprintf "%s%s%s%s%s%s%s%s" rail (Chat_theme.origin row.style)
              Ansi.bold marked Ansi.reset (Theme.recede ()) label restore
      in
      if
        String.length text >= 2 && Char.equal text.[0] ' '
        && Char.equal text.[1] ' '
      then (
        let rest = String.sub text 2 (String.length text - 2) in
        (* The rail is paid for out of the two spaces that were already there,
           so a quoted block costs no cells and nothing below it shifts. It
           runs the height of the block, which is how a reader sees where the
           quotation ends without reading it.

           [Shade_none] keeps the plain gap. An ambient background is only ever
           the operator's own message, which is prose and never quoted, so the
           rail cannot land inside a span this branch would have to restore. *)
        let rail =
          match row.style, row.shade with
          | Message_layout.Journal, _ ->
              Printf.sprintf "%s┊%s " (Chat_theme.origin row.style) Ansi.reset
          | _, Message_layout.Shade_none -> "  "
          | _, Message_layout.Shade_quoted ->
              Printf.sprintf "%s\xe2\x94\x82%s " (Theme.recede ()) Ansi.reset
        in
        let body_style =
          if is_tool then Ansi.reset
          else Chat_theme.body row.style
        in
        if context.ambient_background && not is_tool then
          box_line_styled buf cols ~style:context.opening
            (Printf.sprintf "%s  %s" margin (dress rest))
        else
          box_line buf cols
            (Printf.sprintf "%s%s%s%s%s" margin rail
               body_style (dress rest) Ansi.reset))
      else
        box_line_styled buf cols
          ~style:(if is_tool then Ansi.reset else context.opening)
          (dress text)
  | Message_layout.Metadata (Message_layout.Timeline_break _) ->
      box_line_styled buf cols ~style:(Theme.info () ^ Ansi.bold) row.text
  | Message_layout.Metadata (Message_layout.Continued_at { timestamp }) ->
      box_line_styled buf cols ~style:(Theme.recede ())
        (Printf.sprintf "[%s]" timestamp)
  | Message_layout.Metadata
      (Message_layout.Origin { timestamp; role_label; request_label }) ->
      (match row.style with
       | Message_layout.Tool | Message_layout.Thinking ->
           box_line_styled buf cols ~style:(Theme.recede ())
             (Printf.sprintf "[%s]  %s  %s" timestamp
                (String.trim role_label) request_label)
       | Message_layout.User | Message_layout.Inbound | Message_layout.Keeper
       | Message_layout.Status | Message_layout.Local | Message_layout.Journal
       | Message_layout.Error | Message_layout.Skill _ ->
           (* [role_label] arrives in a fixed fourteen-to-eighteen cell column
              so the request column stays put down the pane. The label sits
              beside its mark and the remaining padding follows the badge;
              the reverse span covers only the name.

              "From" went with it. It was five cells that named no field and
              said nothing the badge does not: the row already reads
              [clock] [who] [request]. *)
           let mark, name, alignment =
             Message_layout.split_aligned_role_label ~style:row.style role_label
           in
           (* The mark keeps its colour and stays out of the badge, the way the
              inline gutter already draws it, so the two origin modes agree
              about what a speaker mark looks like. *)
           let badge =
             Printf.sprintf "%s%s%s%s%s %s %s" (Chat_theme.origin row.style)
               mark Ansi.reverse name Ansi.reset alignment Ansi.reset
           in
           box_line buf cols
             (Printf.sprintf "%s[%s]%s  %s %s%s%s" Ansi.dim timestamp Ansi.reset
                badge Ansi.dim request_label Ansi.reset))

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
        (let self = Masc.Build_identity.current () in
         match
           Masc_tui_footer.build_mismatch_item
             ~tui_commit:self.Masc.Build_identity.binary_commit
             ~tui_age_s:
               (Option.map float_of_int
                  self.Masc.Build_identity.binary_commit_age_seconds)
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

(* What a tool block's row says about state.

   A chat body is sanitized before it is drawn, so no marker inside the text
   can carry a colour; the row's own style is the only channel left. That only
   matters once a block folds: expanded, every call keeps a row and a glyph of
   its own, but folded, six calls sit behind one line where "1 failed" reads
   in the same colour as "5 returned". Live data says how much that hides --
   5,862 of 176,780 recorded calls failed, and three tools fail more often
   than they succeed.

   The projection decides which outcome the fold stands for, on the same
   precedence that picks its glyph, so the mark and the colour agree. A block
   holding a failure is a failure; one still waiting is attention; one that
   returned is the ordinary tool row it was before. *)
let tool_block_style (_projection : Keeper_chat_transcript.tool_projection) =
  Message_layout.Tool
;;

let skill_tone_of_state :
    Keeper_chat_transcript.skill_state -> Message_layout.skill_tone = function
  | Keeper_chat_transcript.Skill_calling
  | Keeper_chat_transcript.Skill_served_pending
  | Keeper_chat_transcript.Skill_delivered -> Message_layout.Skill_live
  | Keeper_chat_transcript.Skill_used -> Message_layout.Skill_used
  | Keeper_chat_transcript.Skill_served_only
  | Keeper_chat_transcript.Skill_evidence_missing -> Message_layout.Skill_attention
  | Keeper_chat_transcript.Skill_failed
  | Keeper_chat_transcript.Skill_evidence_unavailable -> Message_layout.Skill_failure
;;

(* The strip above every surface: the Tab ring with the active family
   highlighted. Wider terminals see the whole ring; narrower ones see a
   window around the active entry with how many entries hide past each edge,
   so position in the cycle stays readable at any width. *)
let surface_strip (state : state) ~cols =
  let ring = Masc_tui_types.visible_surface_ring state in
  let n = List.length ring in
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
    let surface, name = List.nth ring i in
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
    let surface, _ = List.nth ring i in
    let is_alert =
      match surface with
      | Approvals -> List.length (Masc_tui_types.approval_items state) > 0
      | _ -> false
    in
    if i = active then
      Buffer.add_string parts
        (Ansi.bold ^ (if is_alert then Theme.warn () else Theme.info ()) ^ "\xe2\x96\xb8" ^ label i ^ Ansi.reset)
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

(* The roster shows when the terminal can spare its columns and the reader
   has not put it away. Width is the terminal's answer, [roster_pane_hidden]
   is theirs, and hiding survives a resize because it is a decision rather
   than a measurement. *)
let keeper_roster_pane_shown (state : state) ~cols =
  Masc_tui_roster_pane.shown ~hidden:state.roster_pane_hidden ~cols

let keeper_roster_name_cells = Masc_tui_roster_pane.pane_cols - 7

(* The main loop uses the target identity to restart the motion when selection
   changes. A short name has no animation target and therefore costs no idle
   repaint. *)
let keeper_roster_marquee_target (state : state) ~cols =
  if not (keeper_roster_pane_shown state ~cols) then None
  else
    match state.view, selected_keeper state with
    | Keepers (Keeper_detail | Keeper_message), Some keeper ->
        let name = Terminal_text.single_line keeper.k_name in
        if Message_layout.display_width name > keeper_roster_name_cells then
          Some name
        else None
    | _ -> None

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
   Read here, ahead of every surface, because the Activity pane lists the
   selected keeper's changes the same way the Changes surface does. *)
let change_row_address (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_location with
  | Masc.Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Printf.sprintf "%s:%s" repo_id relative_path
  | Masc.Tui_decode.Fc_in_bundle { bundle_path } -> bundle_path
  | Masc.Tui_decode.Fc_at_absolute_path { path } -> path

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
        ; trace_id = keeper.k_trace_id
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
  { Pane.now = Unix.gettimeofday ()
  ; tab = state.acting_pane_tab
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
  ; entries = state.acting
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

let connection_status_badge : Masc_tui_types.connection_status -> string =
  function
  | Connected as status ->
      (Theme.ok ()) ^ "[" ^ connection_status_label status ^ "]" ^ Ansi.reset
  | (Degraded | Connecting | Reconnecting | Booting) as status ->
      (Theme.warn ()) ^ "[" ^ connection_status_label status ^ "]" ^ Ansi.reset
  | Disconnected as status ->
      (Theme.bad ()) ^ "[" ^ connection_status_label status ^ "]" ^ Ansi.reset
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
;;

let workspace_health_label = function
  | Workspace_health_critical -> "critical"
  | Workspace_health_bad -> "bad"
  | Workspace_health_risk -> "risk"
  | Workspace_health_warning -> "warning"
  | Workspace_health_degraded -> "degraded"
  | Workspace_health_initializing -> "initializing"
  | Workspace_health_ok -> "ok"
  | Workspace_health_unknown -> "unknown"

let workspace_health_color = function
  | Workspace_health_critical
  | Workspace_health_bad
  | Workspace_health_risk -> (Theme.bad ())
  | Workspace_health_warning
  | Workspace_health_degraded
  | Workspace_health_initializing
  | Workspace_health_unknown -> (Theme.warn ())
  | Workspace_health_ok -> (Theme.ok ())

let attention_severity_label = function
  | Attention_critical -> "critical"
  | Attention_bad -> "bad"
  | Attention_warning -> "warn"
  | Attention_info -> "info"

let attention_severity_color = function
  | Attention_critical | Attention_bad -> (Theme.bad ())
  | Attention_warning -> (Theme.warn ())
  | Attention_info -> (Theme.info ())

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

let task_line (task : task) =
  let status = Masc_domain.task_status_to_string task.status in
  (* The icon and the status word share one color so the row's state reads at
     a glance: in-flight rows in cyan, waiting rows dimmed. Terminal states
     never reach this list ([active_tasks_of_domain] filters them); they keep
     the default so a future caller showing one is visible rather than wrong. *)
  let status_color =
    match task.status with
    | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> (Theme.info ())
    | Masc_domain.AwaitingVerification _ -> Theme.warn ()
    | Masc_domain.Todo -> Ansi.dim
    | Masc_domain.Done _ | Masc_domain.Cancelled _ -> ""
  in
  let assignee =
    match Masc_domain.task_assignee_of_status task.status with
    | Some name -> Printf.sprintf " @%s" (Terminal_text.single_line name)
    | None -> ""
  in
  let goal_tag =
    match task.goal_ids with
    | [] -> ""
    | goal :: _ ->
        Printf.sprintf " %s%s%s" (Theme.recede ())
          (Terminal_text.single_line goal)
          Ansi.reset
  in
  Printf.sprintf "%s%s%s %s[%s]%s %s %s(%s%s)%s %s%s"
    status_color
    (task_status_icon task.status)
    Ansi.reset
    Ansi.dim
    (Terminal_text.single_line task.id)
    Ansi.reset
    (Terminal_text.single_line task.title)
    status_color
    status
    assignee
    Ansi.reset
    (priority_indicator task.priority)
    goal_tag

(** Project the shared Overview row budget and its sanitized variable inputs. *)
let overview_layout (state : state) ~terminal_rows =
  let attention_items =
    match state.overview with
    | None -> []
    | Some overview -> overview.ov_attention_items
  in
  let tasks_error = Terminal_text.optional_single_line state.tasks_error in
  let row_budget =
    Render_schedule.allocate_overview ~terminal_rows
      ~has_cluster:(Option.is_some state.overview)
      ~attention_count:(List.length attention_items)
      ~event_count:(List.length state.events)
      ~task_count:(List.length state.tasks)
      ~has_task_error:(Option.is_some tasks_error)
  in
  attention_items, tasks_error, row_budget

(** Render the Overview surface (Dashboard V2 shell/briefing summary). *)
let render_overview (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s"
    (screen_title " MASC Overview")
    (Masc_tui_theme.tone Masc_tui_theme.Accent) (Terminal_text.single_line state.workspace) Ansi.reset timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let ov = state.overview in
  let overview_error =
    Terminal_text.optional_single_line state.overview_error
  in

  (* Summary line *)
  let summary_line =
    match (ov, overview_error) with
    | _, Some err ->
        data_unreliable_row ~cols err
    | None, None ->
        Printf.sprintf "  %s(no overview data — press 'r' to refresh)%s"
          Ansi.dim Ansi.reset
    | Some o, None ->
        let health_color = workspace_health_color o.ov_workspace_health in
        let health_label = workspace_health_label o.ov_workspace_health in
        (* The tab strip's badge counts held keeper tool calls, pending gate
           rows, and confirm-queue entries together, and so does the Approvals
           screen's own header. This row counted only the third of those, off
           the confirm queue's own visible count, so a runtime holding one
           keeper tool call drew "Approvals: 0" beside a tab reading
           "Approvals·1" -- one name over two populations. All three now walk
           [approval_items].

           The "?" tail marks a count no source will stand behind, and it does
           not say which way the number is wrong, because the failures do not
           agree on that. A dropped confirm queue empties its list, leaving the
           count short. A failed held-calls or gate poll replaces nothing --
           the previous rows stay on screen, which the Approvals header calls
           "held calls stale" -- so that count can just as easily be long,
           describing rows the server no longer holds. Which list failed is a
           question that header answers; at this width the row says only that
           one did. *)
        let approval_count =
          let on_screen = List.length (Masc_tui_types.approval_items state) in
          let source_unread =
            Option.is_none state.approval_snapshot
            || Option.is_some state.approvals_error
            || Option.is_some state.keeper_tool_approvals_error
            || Option.is_some state.gate_error
            || Option.is_some state.gate_queue_unavailable
          in
          if source_unread then Printf.sprintf "%d?" on_screen
          else string_of_int on_screen
        in
        (* Keepers and MCP clients are counted apart: a row reading
           "Agents: 2" over a runtime with ten keepers named the wrong
           population.

           The incident count used to ride here too, over an Attention panel
           three lines below drawing those same incidents one per row. A
           number above the list it counts is not a summary of anything the
           reader cannot already see; where the panel cannot fit them all,
           the panel's own title says so. *)
        (* Nine Keepers with two that had stopped doing anything and one an
           operator had paused read exactly like nine running ones. The
           briefing has carried the control plane's word for each of them all
           along; only the number reached this row.

           The states that are not "active" are the ones an operator acts on,
           so those are the ones named. A fleet where every Keeper is active
           says only its number -- an always-on breakdown would be texture,
           the way an always-on tab badge would be. *)
        let keeper_note =
          let l = o.ov_keeper_liveness in
          let parts =
            List.filter_map
              (fun (count, label) ->
                if count = 0 then None
                else Some (Printf.sprintf "%d %s" count label))
              [ (l.klc_paused, "paused")
              ; (l.klc_offline, "offline")
              ; (l.klc_inactive, "inactive")
              ; (l.klc_idle, "idle")
              ; (l.klc_unreadable, "unreadable")
              ]
          in
          match parts with
          | [] -> ""
          | _ :: _ -> Printf.sprintf " (%s)" (String.concat ", " parts)
        in
        let pulse_suffix =
          if cols >= 92 then
            let activity_samples =
              match state.keeper_turn_finishes with
              | [] -> [ 0; 0; 0; 0; 0; 0; 0; 0 ]
              | finishes ->
                  let now = Unix.gettimeofday () in
                  let buckets = Array.make 8 0 in
                  List.iter
                    (fun (_, ts) ->
                      let delta = max 0.0 (now -. ts) in
                      let idx = min 7 (int_of_float (delta /. 15.0)) in
                      let slot = 7 - idx in
                      if slot >= 0 && slot < 8 then buckets.(slot) <- buckets.(slot) + 1)
                    finishes;
                  Array.to_list buckets
            in
            let spark = Chart.sparkline activity_samples in
            Printf.sprintf "  %sPulse:%s %s" Ansi.bold Ansi.reset spark
          else ""
        in
        Printf.sprintf
          "  Health: %s%s%s  Keepers: %d%s  MCP agents: %d  Approvals: %s%s"
          health_color health_label Ansi.reset o.ov_keepers keeper_note
          o.ov_mcp_agents approval_count pulse_suffix
  in
  box_line buf cols summary_line;

  (* Cluster/project line *)
  (match ov with
   | None -> ()
   | Some o ->
         (* The transport summary rides this row rather than taking one of its
            own: a narrow viewport must not trade an event line for it. A path
            that is not listening reads "off" instead of zero sessions, and
            dropped events are called out because a steady queue that drops is
            not a healthy transport. *)
         let transport_summary =
           match state.transport with
           | None -> ""
           | Some t ->
             let websocket =
               match t.th_websocket_sessions with
               | Some sessions -> Printf.sprintf "ws %d" sessions
               | None -> "ws off"
             in
             let grpc =
               match t.th_grpc_port with
               | Some port -> Printf.sprintf "grpc :%d" port
               | None -> "grpc off"
             in
             let dropped =
               if t.th_events_dropped = 0 then ""
               else Printf.sprintf "  dropped %d" t.th_events_dropped
             in
             (* No padding here: this rides the tail of the row, so a long
                value trims itself against the border instead of pushing the
                cluster and project columns around. *)
             Printf.sprintf "  %s/%s  sse %d  %s  %s%s"
               (* Both come off a closed type now, so there is no arbitrary
                  text to sanitize here. *)
               (Masc.Transport_metrics.primary_path_kind_to_string t.th_primary_path)
               (Masc.Transport_metrics.queue_pressure_kind_to_string
                  t.th_queue_pressure)
               t.th_sse_sessions websocket grpc dropped
         in
         (* The runtime event feed rides the same tail. "live N" counts the
            frames this stream has delivered; a closed feed keeps its count
            and says why it closed, so a stream that dropped after a thousand
            events and one that never opened do not read alike. *)
         let observer_summary =
           match state.observer with
           | Observer_off -> ""
           | Observer_opening -> "  feed: opening"
           | Observer_live { events; _ } -> Printf.sprintf "  feed: live %d" events
           | Observer_closed { events; _ } ->
               (* The reason is in TUI Session Events and on the Activity status
                  row; here it would push the count off a narrow row. *)
               Printf.sprintf "  feed: closed after %d" events
         in
         let cluster_line =
           Printf.sprintf "  Cluster: %s%s%s  Project: %s%s%s"
             Ansi.dim
             (fit_width (Terminal_text.single_line o.ov_cluster) 24)
             Ansi.reset
             (fit_width (Terminal_text.single_line o.ov_project) 20)
             transport_summary observer_summary
       in
       box_line buf cols cluster_line);

  box_divider buf cols;

  (* Attention panel *)
  let attention_items, tasks_error, row_budget =
    overview_layout state ~terminal_rows:rows
  in
  (* Three verticals plus two panels have to add up to the box the rest of the
     screen draws. An odd remainder used to be dropped by the division, so on
     any odd width the Attention/Events band ended one column short of every
     other row and the right edge stepped in and back out. The odd column goes
     to the right panel. *)
  let panel_width = (cols - 3) / 2 in
  let right_panel_width = cols - 3 - panel_width in
  (* The count used to ride the summary row three lines above, over the very
     rows it counted. It belongs to the panel, and it earns its place only
     where it says something the rows cannot: that some did not fit. The
     Events panel beside it states its window the same way. *)
  let attention_count = List.length attention_items in
  let attention_title =
    if attention_count = 0 then " Attention "
    else if attention_count <= row_budget.attention_rows then
      Printf.sprintf " Attention %d " attention_count
    else
      Printf.sprintf " Attention %d/%d " row_budget.attention_rows
        attention_count
  in
  (* A burst of identical lines (manual refreshes, a broadcast fan-out) folds
     into one row with a ×N tail; the window scrolls over folded rows. *)
  let collapsed_events =
    Render_schedule.collapse_consecutive
      ~key:Masc_tui_types.overview_event_collapse_key state.events
  in
  let event_count = List.length collapsed_events in
  let event_window =
    Render_schedule.project_overview_event_window ~event_count
      ~visible_rows:row_budget.attention_rows state.overview_event_scroll
  in
  let events_title =
    let title =
      if event_window.oew_first_position = 0 then " TUI Session Events "
      else
        Printf.sprintf " TUI Session Events %d-%d/%d "
          event_window.oew_first_position event_window.oew_last_position
          event_count
    in
    fit_width title (max 0 panel_width)
  in
  Buffer.add_string buf (Printf.sprintf " %s%s%s%s%s%s\n"
    Ansi.bold attention_title Ansi.reset
    (String.make (max 0 (panel_width - String.length attention_title)) ' ')
    ((Theme.recede ()) ^ Ansi.box_v ^ Ansi.reset)
    events_title);

  for i = 0 to row_budget.attention_rows - 1 do
    let attention_str =
      if i < List.length attention_items then
        let a = List.nth attention_items i in
        let sev_color = attention_severity_color a.ai_severity in
        let severity_label = attention_severity_label a.ai_severity in
        (* The age answers "why is this still here": a stamped item shows how
           long ago its evidence happened, an unstamped one (a paused keeper,
           a waiting confirmation) shows an em dash because its producer put
           no time on it -- it stands until its condition clears. A fixed
           three-cell column, like the severity label, so summaries start on
           one edge. *)
        let age_label =
          match a.ai_evidence_ts with
          | Some ts ->
              keeper_lane_idle_text
                (int_of_float (Unix.gettimeofday () -. ts))
          | None -> "\xe2\x80\x94"
        in
          (* Fitted once, by the fit that draws the row. Fitting the summary
             here as well meant guessing how many cells the label ahead of it
             spends, and the events column beside this one guessed one too
             many: every event row came out a cell over its budget and was
             marked truncated whether or not anything was cut. The severity
             label keeps its own fit -- that one is a fixed column, not a
             guess at the rest of the row. *)
          Printf.sprintf "%s[%s]%s %s%s%s %s"
            sev_color (fit_width severity_label 5) Ansi.reset
            Ansi.dim (fit_width age_label 3) Ansi.reset
            (Terminal_text.single_line a.ai_summary)
      else ""
    in
    let event_str =
      let event_index = i + event_window.oew_offset in
      if event_index < event_count then
        let e, run = List.nth collapsed_events event_index in
        let tail =
          if run > 1 then Printf.sprintf " %s\xc3\x97%d%s" Ansi.dim run Ansi.reset
          else ""
        in
        Printf.sprintf "%s[%s]%s %s%s"
          Ansi.dim e.timestamp Ansi.reset
          (Terminal_text.single_line e.content)
          tail
      else ""
    in
    Buffer.add_string buf (Printf.sprintf "  %s %s%s%s %s\n"
      (fit_width attention_str (panel_width - 2))
      (Theme.recede ()) Ansi.box_v Ansi.reset
      (fit_width event_str (right_panel_width - 2)))
  done;

  box_divider buf cols;

  (* Tasks section *)
  let task_header =
    if List.is_empty state.tasks then Printf.sprintf " %sTasks%s\n" Ansi.bold Ansi.reset
    else
      let count = List.length state.tasks in
      let done_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with Done _ -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      let active_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with InProgress _ | Claimed _ -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      let awaiting_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with AwaitingVerification _ -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      let todo_c =
        List.fold_left
          (fun acc (t : task) -> match t.status with Todo -> acc + 1 | _ -> acc)
          0 state.tasks
      in
      Printf.sprintf " %sTasks%s (%d · %s%d done%s · %s%d active%s · %s%d awaiting%s · %s%d todo%s)\n"
        Ansi.bold Ansi.reset
        count
        (Theme.ok ()) done_c Ansi.reset
        (Theme.info ()) active_c Ansi.reset
        (Theme.warn ()) awaiting_c Ansi.reset
        Ansi.dim todo_c Ansi.reset
  in
  Buffer.add_string buf task_header;

  (match tasks_error with
   | Some err when row_budget.task_error_rows > 0 ->
        box_line buf cols
          ((Theme.bad ()) ^ "  "
          ^ fit_width err (cols - 8)
          ^ Ansi.reset)
   | None | Some _ -> ());
  if row_budget.task_rows > 0 && List.is_empty state.tasks
     && Option.is_none tasks_error then
    box_line buf cols (Ansi.dim ^ "  (no tasks)" ^ Ansi.reset)
  else begin
    (* The panel is shorter than the list can get, so the cursor can sit below
       the last visible row; the window follows it the way Board's does. *)
    let task_scroll_offset =
      max 0 (state.task_cursor - row_budget.task_rows + 1)
    in
    for i = 0 to row_budget.task_rows - 1 do
      let idx = i + task_scroll_offset in
      if idx < List.length state.tasks then begin
        let t = List.nth state.tasks idx in
        let is_selected = state.task_focus = Right_pane && idx = state.task_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("> " ^ task_line t))
        else
          box_line buf cols ("  " ^ task_line t)
      end
    done
  end;

  (* Carry the frame to the bottom of the terminal. Without this the surface
     stops where its content does and the footer under it lands wherever that
     happens to be -- halfway up a tall window. *)
  for _ = 1 to row_budget.filler_rows do
    box_empty buf cols
  done;

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
       ~hints:
         (Masc_tui_keys.footer_hints_overview
            ~task_focus:(state.task_focus = Right_pane)));

  finish_surface state ~clamped:(Overview_events event_window.oew_offset) ~surface_key:"overview" ~rows:terminal_rows
      ~cols buf

(** Render one backlog task in full, from the same load the Overview list was
    projected from. The dispatch falls back to the Overview when the row is no
    longer in the backlog, so the task argument always exists here. *)
(* What a boxed surface spends on chrome before any row of content: the top
   border, its title and rule, the closing rule and border, the selected-row
   detail, and the key hints. Five surfaces subtracted the literal 10 from the
   terminal height; naming it is what makes a sixth reader able to check the
   arithmetic instead of trusting it. *)
let boxed_surface_chrome_rows = 10

(* One task's event history, appended after the detail body so it rides the
   same scroll. Loaded lazily on detail entry; the id check drops an answer
   for a task the operator already left. Rows are raw event-stream lines, so
   only the fields present are drawn. *)
let task_history_lines (state : state) task_id =
  let header = "  HISTORY" in
  let rows =
    match state.task_history with
    | Some (id, result) when String.equal id task_id -> (
        match result with
        | Ok [] -> [ "    (no events recorded)" ]
        | Ok events ->
            List.concat_map
              (fun (event : Tui_decode.task_history_event) ->
                let transition =
                  match event.Tui_decode.th_from_status, event.th_to_status with
                  | Some from_status, Some to_status ->
                      Printf.sprintf "  %s -> %s" from_status to_status
                  | Some from_status, None -> "  from " ^ from_status
                  | None, Some to_status -> "  -> " ^ to_status
                  | None, None -> ""
                in
                let actor =
                  match event.th_actor with
                  | Some actor -> "  by " ^ actor
                  | None -> ""
                in
                Printf.sprintf "    %s  %s%s%s"
                  (Planning_detail.short_ts event.th_ts)
                  event.th_label transition actor
                :: (match event.th_note with
                    | Some note -> [ "      " ^ note ]
                    | None -> []))
              events
        | Error err -> [ "    load failed: " ^ err ])
    | _ -> [ "    loading..." ]
  in
  ("" :: header :: rows)

let task_detail_pane (state : state) ~rows ~cols (task : Masc_domain.task) buf =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s"
    (screen_title " MASC Task")
    (Masc_tui_theme.tone Masc_tui_theme.Accent) (fit_width task.id 20) Ansi.reset timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols
    (Ansi.bold ^ "  "
    ^ fit_width (Terminal_text.single_line task.title) (cols - 6)
    ^ Ansi.reset);
  (* What this task serves. The task record carries no goal -- the goal-task
     registry is the source of truth -- so this reads the links the loader
     resolved rather than a field that would always be empty.

     Written as a reference so Ctrl-] can follow it: naming a goal the
     operator then has to go find by hand is the gap this closes. *)
  (match
     List.find_opt (fun (row : Tui_decode.task) -> String.equal row.id task.id)
       state.tasks
   with
   | None -> ()
   | Some row ->
     (match row.goal_ids with
      | [] ->
        box_line buf cols
          (Ansi.dim ^ "  Goal        (not linked to a goal)" ^ Ansi.reset)
      | goal_ids ->
        List.iteri
          (fun index goal_id ->
            let label = if index = 0 then "Goal" else "" in
            box_line buf cols
              (Printf.sprintf "  %-11s %s  %s" label
                 (fit_width goal_id 28)
                 (Ansi.dim ^ Link.reference Goal goal_id ^ Ansi.reset)))
          goal_ids));
  (* Each status carries its own timestamps and actors; one exhaustive match
     keeps the row and the status from disagreeing about who did what. The
     note lines stay counted so the body budget below shrinks with them --
     a verification id must not push the helper row off the screen. *)
  let status_line, note_lines =
    match task.task_status with
    | Masc_domain.Todo -> ("todo — unclaimed", [])
    | Masc_domain.Claimed { assignee; claimed_at } ->
        ( Printf.sprintf "claimed by %s at %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line claimed_at)
        , [] )
    | Masc_domain.InProgress { assignee; started_at } ->
        ( Printf.sprintf "in progress by %s since %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line started_at)
        , [] )
    | Masc_domain.AwaitingVerification
        { assignee; submitted_at; verification_id; _ } ->
        ( Printf.sprintf "awaiting verification by %s, submitted %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line submitted_at)
        , [Printf.sprintf "verification %s"
             (Terminal_text.single_line verification_id)] )
    | Masc_domain.Done { assignee; completed_at; notes } ->
        ( Printf.sprintf "done by %s at %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line completed_at)
        , match notes with None -> [] | Some note -> [note] )
    | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason } ->
        ( Printf.sprintf "cancelled by %s at %s"
            (Terminal_text.single_line cancelled_by)
            (Terminal_text.single_line cancelled_at)
        , match reason with None -> [] | Some r -> [r] )
  in
  box_line buf cols
    (Ansi.dim ^ "  status   " ^ Ansi.reset
    ^ fit_width status_line (cols - 16));
  List.iter
    (fun note ->
       box_line buf cols
         (Ansi.dim ^ "           " ^ fit_width
            (Terminal_text.single_line note) (cols - 16)
         ^ Ansi.reset))
    note_lines;
  box_line buf cols
    (Ansi.dim ^ Printf.sprintf "  created  %s by %s  priority %d  cycles %d"
       (Terminal_text.single_line task.created_at)
       (match task.created_by with
        | Some by -> Terminal_text.single_line by
        | None -> "-")
       task.priority task.cycle_count
    ^ Ansi.reset);
  box_divider buf cols;

  (* Labeled block: the label rides the first wrapped line and continuation
     lines keep the text column, so long handoff summaries stay readable. *)
  let labeled_lines label text =
    let width = max 10 (cols - 16) in
    Message_layout.wrap_words ~max_cells:width
      (Terminal_text.single_line text)
    |> List.mapi
         (fun index line ->
            if index = 0 then Printf.sprintf "  %-8s %s" label line
            else Printf.sprintf "           %s" line)
  in
  let some_lines label = function
    | None -> []
    | Some text -> labeled_lines label text
  in
  let list_lines label items =
    List.concat_map (fun item -> labeled_lines label item) items
  in
  let body_lines =
    (if String.equal task.description "" then [] else labeled_lines "what" task.description)
    @ (match task.handoff_context with
       | None -> []
       | Some handoff ->
           some_lines "why" handoff.Masc_domain.reason
           @ (if String.equal handoff.Masc_domain.summary "" then []
              else labeled_lines "handoff" handoff.Masc_domain.summary)
           @ some_lines "next" handoff.Masc_domain.next_step
           @ some_lines "failure" handoff.Masc_domain.failure_mode
           @ list_lines "evidence" handoff.Masc_domain.evidence_refs)
    @ (match task.contract with
       | None -> []
       | Some contract ->
           (if contract.Masc_domain.strict then
              ["  contract strict"]
            else [])
           @ list_lines "done-when" contract.Masc_domain.completion_contract
           @ list_lines "evidence" contract.Masc_domain.required_evidence)
    @ list_lines "file" task.files
    @ task_history_lines state task.id
  in
  let total_lines = List.length body_lines in
  (* Chrome above and below the scrolling body: top border, header, divider,
     the title block, the bottom border, the helper row and the composer row.
     Clamped through the same helper the keeper log pane uses. Ten, not nine:
     at nine the frame came out one row taller than its budget, which cost the
     surface the composer row rather than a body row. On top of the ten, the
     status note lines vary by state -- a verification id or cancellation
     reason must shrink the body, not push rows off the bottom. *)
  let content_height = max 1 (rows - boxed_surface_chrome_rows - List.length note_lines) in
  let offset =
    min state.task_detail_scroll
      (Metrics_tail.maximum_scroll ~entry_count:total_lines ~content_height)
  in
  for i = 0 to content_height - 1 do
    let line_index = i + offset in
    let text =
      if line_index < total_lines then
        List.nth body_lines line_index
      else ""
    in
    box_line buf cols
      (Ansi.dim ^ fit_width (Terminal_text.single_line text) (cols - 8)
      ^ Ansi.reset)
  done;

  box_bottom buf cols;
  offset
;;

(* The task list stays beside the task. Overview's rows are the queue
   this task sits in, and reading one used to cost the reader their
   place in it. Below the split width the detail keeps the screen. *)
let render_task_detail (state : state) (task : Masc_domain.task) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let offset =
    if cols < keeper_split_threshold_cols then
      task_detail_pane state ~rows ~cols task buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Tasks"
        ~focused:false
        ~labels:
          (List.map (fun (row : Tui_decode.task) -> row.title) state.tasks)
        ~selected:state.task_cursor;
      let answer =
        task_detail_pane state ~rows ~cols:(cols - left_cols) task right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
       ~hints:"j/k:scroll  x:cancel  left/esc:back  r:refresh");

  finish_surface state ~clamped:(Task_detail offset) ~surface_key:"task-detail" ~rows:terminal_rows ~cols buf

(** Render the Approvals surface (pending confirmations). *)
(* The ask, whole. The list row is one line through [single_line], which
   turns a newline into the six characters [\x0A] and then cuts; an [Edit]
   carrying a page of code read as its first forty characters and there was
   no second screen. This is that screen. *)
let approval_detail_pane (state : state) ~clamped ~rows ~cols (row : approval_row) buf =
  let width = max 8 (cols - 6) in
  let fields =
    match row with
    | Keeper_tool_row held ->
      [ "keeper", held.Tui_decode.kta_keeper
      ; "tool", held.Tui_decode.kta_tool
      ; "call", held.Tui_decode.kta_tool_call_id
      ; "question", held.Tui_decode.kta_question
      ; "args", held.Tui_decode.kta_args
      ]
    | Gate_row pending ->
      let phase =
        match pending.Tui_decode.gp_phase with
        | Gate_queued -> "queued"
        | Gate_judging -> "judging"
        | Gate_human_required -> "human required"
        | Gate_blocked -> "auto judge blocked"
      in
      let blocked_fields =
        match pending.Tui_decode.gp_phase with
        | Gate_blocked ->
          [ ( "reason"
            , Option.value
                ~default:"(the server recorded no detail)"
                pending.Tui_decode.gp_auto_judge_detail
              |> Keeper_chat.terminal_safe_text ~preserve_newlines:true )
          ; ( "next"
            , match pending.Tui_decode.gp_retry_request with
              | Some _ -> "R: retry Auto Judge; y/n: decide now"
              | None ->
                  "y/n: decide now (this exact attempt cannot be replayed)" )
          ]
        | Gate_queued | Gate_judging | Gate_human_required -> []
      in
      [ "keeper", pending.Tui_decode.gp_keeper
      ; "tool", pending.Tui_decode.gp_display_tool
      ; "operation", pending.Tui_decode.gp_operation
      ; "state", phase
      ]
      @ blocked_fields
      @ [
        ( "approval", pending.Tui_decode.gp_id )
      ; ( "sandbox"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_sandbox )
      ; ( "working directory"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_cwd )
      ; "input",
        (match pending.Tui_decode.gp_input_preview with
         | Some preview -> preview
         | None -> "")
      ]
    | Operator_row a ->
      [ "actor", a.Masc_tui_operator_projection.ap_actor
      ; "action", a.Masc_tui_operator_projection.ap_action_type
      ; "target", a.Masc_tui_operator_projection.ap_target_type
      ; "summary", a.Masc_tui_operator_projection.ap_summary
      ; "payload",
        Yojson.Safe.pretty_to_string a.Masc_tui_operator_projection.ap_payload
      ]
  in
  let lines = Approval_detail.of_fields ~width fields in
  box_top buf cols;
  box_line buf cols (screen_title " Approval" ^ "  " ^ Ansi.dim
    ^ "Esc: back to the list" ^ Ansi.reset);
  box_divider buf cols;
  let content_height = max 1 (rows - 6) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length lines) ~height:content_height
      state.approval_detail_scroll
  in
  (* The pane is where the field count and the drawn height meet, so the row
     it could actually use is reported back rather than recomputed outside. *)
  clamped := scroll;
  let drawn =
    lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun (line : Approval_detail.line) ->
      let text = line.Approval_detail.text in
      match line.Approval_detail.label with
      | Some _ ->
        box_line buf cols
          (Printf.sprintf "  %s%s%s" Ansi.bold (fit_width text (cols - 6)) Ansi.reset)
      | None ->
        box_line buf cols (Printf.sprintf "  %s" (fit_width text (cols - 6))))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;
  box_bottom buf cols
;;

(* The queue stays beside the ask. Reading one used to hide the rest, and the
   rest is what tells an operator whether this one is the urgent one. *)
let approval_sidebar_label (row : approval_row) =
  match row with
  | Keeper_tool_row held -> held.Tui_decode.kta_tool
  | Gate_row pending -> pending.Tui_decode.gp_display_tool
  | Operator_row item -> item.ap_action_type

let render_approval_detail (state : state) (row : approval_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll = ref state.approval_detail_scroll in
  if cols < keeper_split_threshold_cols then
    approval_detail_pane state ~clamped:scroll ~rows ~cols row buf
  else begin
    let left_cols = keeper_roster_pane_cols in
    let left_buf = Buffer.create 1024 in
    let right_buf = Buffer.create 4096 in
    (* Not "Asks": this surface already calls a Keeper's question to a human
       an ask, and these rows are the confirmations waiting on an operator. *)
    write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Approvals"
      ~focused:false
      ~labels:(List.map approval_sidebar_label (approval_items state))
      ~selected:state.approval_cursor;
    approval_detail_pane state ~clamped:scroll ~rows
      ~cols:(cols - left_cols) row right_buf;
    write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf
  end;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:scroll  y:confirm  n:deny  R:retry if offered  Esc:back");
  finish_surface state ~clamped:(Approval_detail_scroll !scroll)
    ~surface_key:"approval-detail" ~rows:terminal_rows ~cols buf

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
   with no choices makes [1-9] a promise the surface cannot keep, and one that
   refuses free text makes [t] the same. *)
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
        ~style:(if picked then Ansi.bold else Ansi.dim)
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
  match question.Masc.Tui_decode.aq_free_text with
  | Masc.Tui_decode.Ask_choices_only -> ()
  | Masc.Tui_decode.Ask_free_text_allowed { aft_hint } -> (
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
          box_wrapped_field buf cols
            ~head:(Printf.sprintf "      %swrite: " Ansi.bold)
            ~style:Ansi.bold
            (Terminal_text.single_line entry.ate_text ^ "\xe2\x96\x8c");
          (* The domain's response is one of three -- chosen, written, or
             skipped -- so saving text drops the picks. Said while the marks
             are still on screen: a choice that vanishes on Enter reads as the
             surface having lost it. *)
          (match Ask_projection.response_for draft ~question with
           | Some (Ask_projection.Draft_chose _) ->
               box_line buf cols
                 (Printf.sprintf "      %ssaving replaces what you picked%s"
                    Ansi.dim Ansi.reset)
           | Some (Ask_projection.Draft_wrote _)
           | Some Ask_projection.Draft_skipped
           | None -> ())
      | None -> (
          (* The key that opens the editor is named by the footer, which knows
             whether the question under the cursor takes text; naming it on
             every row that welcomes free text would offer [t] on rows it does
             nothing to. *)
          match aft_hint with
          | None ->
              box_line buf cols
                (Printf.sprintf "      %sfree text welcome%s" Ansi.dim Ansi.reset)
          | Some hint ->
              box_wrapped_field buf cols
                ~head:(Printf.sprintf "      %sfree text welcome -- " Ansi.dim)
                ~style:Ansi.dim hint))

(* The reason is what separates a decision that matters from one that does
   not, so it is drawn, not hidden behind a detail view. *)
let draw_ask_context buf cols ~(row : Masc.Tui_decode.ask_row) =
  match row.Masc.Tui_decode.ar_context with
  | None -> ()
  | Some context ->
      box_wrapped_field buf cols
        ~head:(Printf.sprintf "    %swhy: " Ansi.dim)
        ~style:Ansi.dim context

(* One line for an ask the cursor is not on: who is waiting and how much they
   asked. What the operator needs from a folded ask is that it exists and can
   be reached; the choices belong to the one they are on. *)
let ask_summary_line ~(row : Masc.Tui_decode.ask_row) =
  let count = List.length row.Masc.Tui_decode.ar_questions in
  Printf.sprintf " %s%s  %d question%s waiting%s" Ansi.dim
    (fit_width (Terminal_text.single_line row.Masc.Tui_decode.ar_keeper) 16)
    count
    (if count = 1 then "" else "s")
    Ansi.reset

(* Draw [f] into a buffer of its own and report how tall it came out. Height
   is a measured fact here rather than an estimate: a prompt wraps against the
   terminal's width, so the only honest way to know what a question costs is
   to draw it. *)
let ask_block f =
  let b = Buffer.create 256 in
  f b;
  (Buffer.contents b, ask_section_rows b)

let draw_ask_questions buf cols (state : state) ~budget =
  (* Questions Keepers put to a human sit under the approval queue rather than
     in it. Nothing is held waiting on them -- the Keeper that asked kept
     working -- so they are not a queue of blocked calls, but an operator
     deciding things belongs in one place either way. *)
  let answering_ask_id =
    match state.ask_answer_mode with
    | Ask_answering { aam_ask_id } -> Some aam_ask_id
    | Ask_browsing -> None
  in
  match state.asks_snapshot with
  | None -> ()
  | Some snapshot -> (
      let open_rows = Ask_projection.open_rows snapshot in
      box_divider buf cols;
      box_line buf cols
        (Printf.sprintf "%sQuestions waiting on you (%d)%s" Ansi.bold
           (List.length open_rows) Ansi.reset);
      match open_rows with
      | [] ->
          box_line buf cols
            (Printf.sprintf "  %snone -- no Keeper is waiting on a decision%s"
               Ansi.dim Ansi.reset)
      | rows ->
          (* Only the ask under the cursor keeps its questions; every other one
             folds to a line. Before this the panel drew all of them and the
             surface, which puts this block last, dropped whatever ran past its
             budget -- an ask of four questions was enough to push the rest off
             the bottom, the cursor with it, so [/] and j/k moved a selection
             nothing on screen showed. *)
          let count = List.length rows in
          let cursor = min (max 0 state.ask_cursor) (count - 1) in
          let selected = List.nth rows cursor in
          let draft = Ask_projection.draft_for state.ask_draft ~row:selected in
          let answering =
            match answering_ask_id with
            | Some ask_id -> String.equal ask_id selected.Masc.Tui_decode.ar_id
            | None -> false
          in
          let questions = selected.Masc.Tui_decode.ar_questions in
          let question_blocks =
            List.mapi
              (fun index question ->
                ask_block (fun b ->
                    draw_ask_question b cols state ~row:selected ~draft ~question
                      ~answering
                      ~selected_question:(index = state.ask_question_cursor)))
              questions
          in
          let why_text, why_rows =
            ask_block (fun b -> draw_ask_context b cols ~row:selected)
          in
          let plan =
            Ask_layout.plan ~budget ~spent:(ask_section_rows buf)
              ~question_heights:(List.map snd question_blocks)
              ~question_cursor:state.ask_question_cursor
              ~context_height:why_rows ~other_asks:(count - 1)
          in
          List.iteri
            (fun index (text, _) ->
              if
                index >= plan.Ask_layout.question_start
                && index
                   < plan.Ask_layout.question_start
                     + plan.Ask_layout.questions_shown
              then Buffer.add_string buf text)
            question_blocks;
          if plan.Ask_layout.questions_hidden > 0 then
            box_line buf cols
              (Printf.sprintf "    %s+%d more question%s -- j/k to reach%s"
                 Ansi.dim plan.Ask_layout.questions_hidden
                 (if plan.Ask_layout.questions_hidden = 1 then "" else "s")
                 Ansi.reset);
          if plan.Ask_layout.context_shown then Buffer.add_string buf why_text;
          let printed = ref 0 in
          List.iteri
            (fun index row ->
              if index <> cursor && !printed < plan.Ask_layout.summaries_shown
              then begin
                box_line buf cols (ask_summary_line ~row);
                incr printed
              end)
            rows;
          if plan.Ask_layout.summaries_hidden > 0 then
            box_line buf cols
              (Printf.sprintf "  %s+%d more ask%s -- [/] to reach%s" Ansi.dim
                 plan.Ask_layout.summaries_hidden
                 (if plan.Ask_layout.summaries_hidden = 1 then "" else "s")
                 Ansi.reset))

(* The selected row's detail, and the only one of the three detail rows whose
   height depends on which kind is selected. A held tool call answers two
   questions -- what is being asked, and why it was held -- and the ask runs
   the width of the pane, so at eighty columns the two cannot share a row.

   Built here rather than inline so the surface can ask its height before it
   spends the rows, the way [ask_section_rows] already measures the ask block
   it is about to draw. The row budget and the drawing call this, so they
   cannot disagree about how tall it is; until 2026-08-31 the second row was
   spelled as a literal ["\\n"] -- backslash and n, printed as those two
   characters -- because a real newline would have drawn a row nobody
   counted. *)
let approval_detail_line (state : state) ~approvals ~cols ~action_inflight =
    match List.nth_opt approvals state.approval_cursor with
    | Some (Operator_row a) -> (
        if action_inflight then
          Printf.sprintf "  %sApproval request in progress…%s" (Theme.warn ())
            Ansi.reset
        else
          match state.pending_approval_action with
          | Some { paa_token; paa_decision }
            when String.equal paa_token a.ap_token ->
              let key =
                match paa_decision with
                | Confirm -> "y"
                | Deny -> "n"
              in
              Printf.sprintf "  %sPress %s again: %s%s" (Theme.warn ()) key
                (fit_width (Terminal_text.single_line a.ap_summary) (cols - 22))
                Ansi.reset
          | _ ->
              let summary =
                fit_width (Terminal_text.single_line a.ap_summary) (max 8 (cols - 34))
              in
              Printf.sprintf "  %s%s%s  %s[y] Approve  [n] Reject%s"
                Ansi.dim summary Ansi.reset
                (Theme.info ()) Ansi.reset)
    | Some (Keeper_tool_row held) ->
        (* One press answers a held call, matching the chat pane's [y]. The
           question is the whole ask, so it is the row the eye lands on;
           the because is why this call was held at all — an operator
           repeating the same yes needs the reason visible, not the name
           of a policy table they cannot open. *)
        (* Two rows. This carried a literal "\n" -- backslash and n, printed as
           those two characters -- because a real newline would have drawn a
           row nobody had budgeted for. [detail_extra_rows] above budgets it. *)
        Printf.sprintf "  %s%s%s  %s[y] Allow  [n] Deny%s\n  %swhy: %s%s"
          (Theme.warn ())
          (fit_width
             (Terminal_text.single_line held.kta_question)
             (max 8 (cols - 28)))
          Ansi.reset
          (Theme.info ()) Ansi.reset
          Ansi.dim
          (fit_width
             (Terminal_text.single_line_or ~default:"(not provided)"
                held.kta_because)
             (max 8 (cols - 12)))
          Ansi.reset
    | Some (Gate_row pending) ->
        (* A durable Gate ask: it keeps until answered, and the answer goes
           through the dashboard resolve route. What the eye needs is who
           wants to touch what, and that the decision spends here. *)
        (* The name is not padded here. This is one line with nothing under
           it to line up with, so a fixed twenty both cut
           "rw-e0-r9-20260820-review" and left short names trailing spaces.
           The list above it now sizes its column to the names it holds and
           this line disagreed with it three rows apart.

           What follows absorbs the difference, which is the same order the
           list uses: the identifier is why the line exists. *)
        let keeper =
          Terminal_text.single_line pending.Tui_decode.gp_keeper
        in
        let phase, tone =
          match pending.Tui_decode.gp_phase with
          | Gate_queued -> "QUEUED", (Theme.warn ())
          | Gate_judging -> "JUDGING", (Theme.info ())
          | Gate_human_required -> "HUMAN REQUIRED", (Theme.warn ())
          | Gate_blocked -> "AUTO JUDGE BLOCKED", (Theme.bad ())
        in
        let actions = "  " ^ (Theme.info ()) ^ "[y] Approve  [n] Reject" ^ Ansi.reset in
        let headline =
          Printf.sprintf "  %s%s → %s · %s%s%s"
            tone
            keeper
            (fit_width
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
               (max 8 (cols - 56 - Message_layout.display_width keeper
                       - Message_layout.display_width phase)))
            phase
            Ansi.reset
            actions
        in
        (match pending.gp_phase with
         | Gate_blocked ->
             let detail =
               Terminal_text.single_line_or ~default:"(the server recorded no detail)"
                 pending.gp_auto_judge_detail
             in
             let next =
               match pending.gp_retry_request with
               | Some _ -> "R: retry Auto Judge; y/n: decide now"
               | None -> "y/n: decide now (this exact attempt cannot be replayed)"
             in
             Printf.sprintf "%s\n  %sreason: %s%s\n  %s%s%s"
               headline Ansi.dim
               (fit_width detail (max 8 (cols - 12))) Ansi.reset
               Ansi.dim (fit_width next (max 8 (cols - 4))) Ansi.reset
         | Gate_queued | Gate_judging | Gate_human_required -> headline)
    | None -> ""
;;


(* Rows [approval_detail_line] draws. One newline is one extra row, counted the
   same way [ask_section_rows] counts the block above it. *)
let approval_detail_rows line =
  let n = ref 1 in
  String.iter (fun c -> if c = '\n' then incr n) line;
  !n

let render_approvals (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  (* Two extra chrome rows on this surface only, both always drawn between
     the header and the divider: the Gate lane line, and the standing
     always-allow rule line under it. *)
  let gate_lane_rows = 2 in
  let approvals = approval_items state in
  let action_inflight =
    Masc_tui_operator_projection.Flow.action_inflight state.approval_flow
  in
  (* Asked of the line itself, not declared beside it. [boxed_surface_chrome_rows]
     budgets one row for this detail and every kind but one takes it; a held
     tool call takes two. Reading the height off the string the pane is about
     to draw is what keeps the two from drifting -- the same thing
     [ask_section_rows] does for the block below. *)
  let detail_line =
    approval_detail_line state ~approvals ~cols ~action_inflight
  in
  let detail_extra_rows = approval_detail_rows detail_line - 1 in
  (* What the questions may spend. The block is drawn last, and a surface that
     overruns loses its final rows, so an unbudgeted question list does not
     push the approval queue off the screen -- it pushes itself off, cursor and
     all. One row is held back for the queue, which is what the [max 1] below
     was already trying to promise and could not keep. *)
  let ask_budget =
    max 4
      (rows - boxed_surface_chrome_rows - gate_lane_rows - detail_extra_rows - 1)
  in
  (* Drawn before the queue's own budget is settled so its height is a measured
     fact rather than a second estimate that can disagree with the drawing. *)
  let ask_buf = Buffer.create 1024 in
  draw_ask_questions ask_buf cols state ~budget:ask_budget;
  let ask_rows = ask_section_rows ask_buf in
  let approval_body_rows =
    max 1
      (rows - boxed_surface_chrome_rows - gate_lane_rows - ask_rows
       - detail_extra_rows)
  in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length approvals in
  (* The count is what is on screen. It used to be the pending-confirm queue's
     own visible/total pair, and that queue is one of the three lists this
     screen draws: with seven Gate rows waiting and no confirm entries, the
     title read "(0/0, hidden 0)" while the tab beside it read "7".

     The filter clause stays -- an actor filter really does hide confirm
     entries, and [visible_entries]/[hidden_entries] partition the same list,
     so the hidden count is the whole of what the old total said. It now
     reads as a note about that queue rather than as the screen's count. *)
  let queue_note =
    match state.approval_snapshot with
    | None -> ", confirm queue unread"
    | Some snapshot ->
      if snapshot.aps_hidden_count = 0 then ""
      else
        Printf.sprintf ", %d hidden from %s" snapshot.aps_hidden_count
          (Terminal_text.single_line_or ~default:"?" snapshot.aps_actor_filter)
  in
  (* A failed held-calls poll keeps the previous rows on screen: the handler
     in [masc_tui.ml] replaces [keeper_tool_approvals] only on [Ok], so the
     count beside the title can describe a list the server no longer holds.
     The empty branch below already refuses to let an unreadable queue wear
     the face of an empty one; a stale list is the same lie with rows on it,
     and it is the one an operator decides against. *)
  let held_note =
    match state.keeper_tool_approvals_error with
    | Some _ -> ", held calls stale"
    | None -> ""
  in
  let action_badge = if action_inflight then "  [submitting]" else "" in
  let type_breakdown =
    let held_c = List.length state.keeper_tool_approvals in
    let gate_c = List.length state.gate_pending in
    let op_c = List.length (operator_approval_items state) in
    if count > 0 then
      Printf.sprintf " [%s%d held%s · %s%d gate%s · %s%d op%s]"
        (Theme.warn ()) held_c Ansi.reset
        (Theme.bad ()) gate_c Ansi.reset
        (Theme.info ()) op_c Ansi.reset
    else ""
  in
  let header =
    Printf.sprintf
      "%s (%d%s%s%s)  %s  %s%s"
      (screen_title " MASC Approvals")
      count type_breakdown queue_note held_note timestamp
      (connection_badge state) action_badge
  in

  box_top buf cols;
  box_line buf cols header;
  (* Both Gate lanes, always on screen here — one row, counted with the rule
     row below it in [gate_lane_rows] so the body arithmetic can subtract
     both as a constant. The durable rows obey
     the external lane, and an operator deciding them needs to see which
     switch they are under. The [e] that cycles the external lane is a
     footer key like any other -- it reaches the footer and the [?] help
     through the Approvals row of Masc_tui_keys, which is where it was
     missing until 2026-08-29. *)
  box_line buf cols
    (match state.gate_modes, Terminal_text.optional_single_line state.gate_error with
     | Some modes, _ ->
         Printf.sprintf
           "  %sGate workspace:%s  ·  outside services:%s%s"
           Ansi.dim
           modes.Tui_decode.glm_workspace
           modes.Tui_decode.glm_external
           Ansi.reset
     | None, Some err -> data_unreliable_row ~cols ("gate: " ^ err)
     | None, None ->
         Ansi.dim ^ "  Gate lanes: loading" ^ Ansi.reset);
  (* Standing always-allow rules, on the row under the lanes. A rule answers
     its call before the call can reach the queue, so an operator reading an
     empty queue is reading the rules' work without seeing them. One row: the
     count, and who the newest one covers. *)
  box_line buf cols
    (match state.gate_rules_unavailable, state.gate_rules with
     | Some detail, _ ->
         data_unreliable_row ~cols ("always-allow rules: " ^ detail)
     | None, [] ->
         Ansi.dim ^ "  Always-allow rules: none" ^ Ansi.reset
     | None, (newest :: _ as rules) ->
         Printf.sprintf
           "  %sAlways-allow rules: %d  ·  newest %s / %s%s%s"
           Ansi.dim
           (List.length rules)
           newest.Tui_decode.gr_keeper
           newest.Tui_decode.gr_tool
           (match newest.Tui_decode.gr_expires_at with
            | Some _ -> " (expires)"
            | None -> "")
           Ansi.reset);
  box_divider buf cols;

  let approvals_error =
    Terminal_text.optional_single_line state.approvals_error
  in
  if count = 0 then begin
    (match state.approval_snapshot, approvals_error with
     | _, Some err ->
         box_line buf cols (data_unreliable_row ~cols err);
         for _ = 1 to max 0 (approval_body_rows - 1) do
           box_empty buf cols
         done
     | None, None ->
         box_line buf cols
           (Ansi.dim ^ "  (no approval data — press 'r' to refresh)"
           ^ Ansi.reset);
         for _ = 1 to max 0 (approval_body_rows - 1) do
           box_empty buf cols
         done
     | Some _, None ->
         (* An unreadable approval-queue store and an empty queue must not
            share a face: the server says which one it was, and "no pending
            approvals" over a store nobody could read is the lie an operator
            acts on. *)
         (match state.gate_queue_unavailable with
          | Some detail ->
              box_line buf cols
                (data_unreliable_row ~cols ("approval queue unavailable: " ^ detail));
              for _ = 1 to max 0 (approval_body_rows - 1) do
                box_empty buf cols
              done
          | None ->
              box_line buf cols
                (Ansi.dim ^ "  (no pending approvals)" ^ Ansi.reset);
              for _ = 1 to max 0 (approval_body_rows - 1) do
                box_empty buf cols
              done));
  end else begin
    let content_height = approval_body_rows in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    let now_unix = Unix.gettimeofday () in
    (* The name column, sized to the names it has to hold rather than to a
       number chosen once. Sixteen cells cut "rw-e0-r9-20260820-review" to
       "rw-e0-r9-202608~", and two keepers whose names share a long prefix
       then read alike -- which is the whole job of the column.

       The cells come out of the last one, which carries the server's input
       preview. That preview is a JSON envelope, so at this width it shows
       "{\"schema\":\"ma~" and nothing a reader can act on; ten fewer of those
       characters costs nothing and buys the identifier back. The cap keeps
       one long name from taking the row. *)
    (* Sanitised here, not at the call below. These are external names and
       every path that reads one goes through [Terminal_text] -- measuring is
       a path like any other, and a measurement taken off the raw field would
       size the column to control characters the screen never draws. *)
    let approval_row_name = function
      | Operator_row a -> Terminal_text.single_line a.ap_actor
      | Keeper_tool_row held ->
        Terminal_text.single_line held.Tui_decode.kta_keeper
      | Gate_row pending ->
        Terminal_text.single_line pending.Tui_decode.gp_keeper
    in
    let name_width =
      List.fold_left
        (fun widest row ->
          max widest (Message_layout.display_width (approval_row_name row)))
        16 approvals
      |> min 26
    in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let line =
          match List.nth approvals idx with
          | Operator_row a ->
              let target_id =
                Terminal_text.single_line_or ~default:"-" a.ap_target_id
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line a.ap_actor) name_width)
                (fit_width (Terminal_text.single_line a.ap_action_type) 20)
                (fit_width (Terminal_text.single_line a.ap_target_type) 16)
                target_id
          | Keeper_tool_row held ->
              (* The remaining wait, not the age: this row disappears on its
                 own when it runs out, and what an operator weighs is how
                 long they still have. *)
              let remaining =
                max 0.
                  (held.kta_asked_at +. held.kta_timeout_sec -. now_unix)
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line held.kta_keeper) name_width)
                (fit_width
                   ("tool: " ^ Terminal_text.single_line held.kta_tool)
                   20)
                (fit_width
                   (Masc_tui_answering.duration_text remaining ^ " left")
                   16)
                (Terminal_text.single_line held.kta_question ^ " — "
                ^ Terminal_text.single_line_or ~default:"(not provided)"
                    held.kta_because)
          | Gate_row pending ->
              (* The age is not worker duration. A durable row survives after
                 Auto Judge hands off to a human or fails, so pair age with
                 the canonical phase instead of calling every row waiting. *)
              let age =
                match pending.Tui_decode.gp_waiting_s with
                | Some seconds ->
                  Masc_tui_answering.duration_text seconds
                | None -> "?"
              in
              let phase, tone =
                match pending.Tui_decode.gp_phase with
                | Gate_queued -> "queued", (Theme.warn ())
                | Gate_judging -> "judging", (Theme.info ())
                | Gate_human_required -> "human", (Theme.warn ())
                | Gate_blocked -> "blocked", (Theme.bad ())
              in
              let phase_cell =
                tone ^ fit_width (age ^ " " ^ phase) 16 ^ Ansi.reset
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width
                   (Terminal_text.single_line pending.Tui_decode.gp_keeper)
                   name_width)
                (fit_width
                   ("gate: "
                   ^ Terminal_text.single_line
                       pending.Tui_decode.gp_display_tool)
                   20)
                phase_cell
                (Terminal_text.single_line_or ~default:"(no input preview)"
                   pending.Tui_decode.gp_input_preview)
        in
        let is_selected = idx = state.approval_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("> " ^ line))
        else
          box_line buf cols ("  " ^ line)
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf (Printf.sprintf "%s\n" detail_line);

  let metadata_line, payload_line =
    match List.nth_opt approvals state.approval_cursor with
    | None -> "", ""
    | Some (Operator_row approval) ->
        let expires =
          Terminal_text.single_line_or ~default:"-" approval.ap_expires_at
        in
        let payload =
          Masc_tui_operator_projection.approval_payload_for_terminal
            approval.ap_payload
        in
        ( Printf.sprintf "  %strace=%s  created=%s  expires=%s%s" Ansi.dim
            (fit_width (Terminal_text.single_line approval.ap_trace_id) 18)
            (Terminal_text.single_line approval.ap_created_at)
            expires Ansi.reset
        , Printf.sprintf "  %spayload=%s%s" Ansi.dim
            (fit_width payload (max 8 (cols - 12)))
            Ansi.reset )
    | Some (Keeper_tool_row held) ->
        ( Printf.sprintf "  %skeeper=%s  call=%s%s" Ansi.dim
            (fit_width (Terminal_text.single_line held.kta_keeper) 20)
            (fit_width (Terminal_text.single_line held.kta_tool_call_id) 28)
            Ansi.reset
        , Printf.sprintf "  %sargs=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.preview_line held.kta_args)
               (max 8 (cols - 9)))
            Ansi.reset )
    | Some (Gate_row pending) ->
        (* The keeper name is not repeated here: the line directly above is
           "<keeper> -> <what it wants>", so this line spends its width on
           what that line cannot say. Where the command would run comes first
           among those -- the same command means different things on the host
           and in a container -- and the approval id, a uuid nobody reads off
           a screen, takes what is left. *)
        (* Ordered by what survives a narrow window. The sandbox is short and
           decides the most -- host or container -- so it goes first; the
           working directory refines it and is long, so it truncates first.
           At eighty columns the old order lost the sandbox entirely. *)
        let site =
          match
            pending.Tui_decode.gp_execution_sandbox,
            pending.Tui_decode.gp_execution_cwd
          with
          | None, None -> ""
          | sandbox, cwd ->
            Printf.sprintf "sandbox=%s  at=%s"
              (Terminal_text.single_line_or ~default:"?" sandbox)
              (Terminal_text.single_line_or ~default:"?" cwd)
        in
        (* The operation is already the right-hand side of the line above
           whenever the two agree, which is every operation but an identity
           call. Repeating it there costs the width this line needs. *)
        let operation =
          let name = Terminal_text.single_line pending.Tui_decode.gp_operation in
          if String.equal name
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
          then ""
          else Printf.sprintf "operation=%s" (fit_width name 20)
        in
        let described =
          List.filter (fun part -> part <> "") [ operation; site ]
          |> String.concat "  "
        in
        ( Printf.sprintf "  %s%s  approval=%s%s" Ansi.dim
            described
            (fit_width (Terminal_text.single_line pending.Tui_decode.gp_id)
               (max 8 (cols - 22 - Message_layout.display_width described)))
            Ansi.reset
        , Printf.sprintf "  %sinput=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.single_line_or ~default:"(no input preview)"
                  pending.Tui_decode.gp_input_preview)
               (max 8 (cols - 10)))
            Ansi.reset )
  in
  Buffer.add_string buf (Printf.sprintf "%s\n%s\n" metadata_line payload_line);

  Buffer.add_buffer buf ask_buf;

  let hints =
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
          "j/k:move  y/n:decide  e:outside lane  %s  a:answer a question  \
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
                   | Some q -> Option.is_some (Ask_projection.free_text_slot q)
                   | None -> false
                 in
                 Printf.sprintf "j/k:question  %s  %s%ss:skip  c:clear  \
                                 Enter:answer  Esc:back"
                   walk_asks
                   (if has_choices then "1-9:pick  " else "")
                   (if takes_text then "t:write  " else "")))
  in
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);

  finish_surface state ~surface_key:"approvals" ~rows:terminal_rows
      ~cols buf

(* Who wrote it, in one column. 1561 of this workspace's 2171 posts are system
   posts and 588 are automation; the 22 a person wrote are what an operator is
   scanning for, so those are the ones that get a mark. *)
(* The widths now live beside their column names in [Render_schedule], which
   is the one place the header and the rows both read. The age column is sized
   for the widest [span_text] draws, "1d00h": a board's oldest live threads are
   days old, so the day tier is the one it holds. *)

(* Four cells of lead sit ahead of the mark on the header and on every row, so
   the table gets what the frame leaves less those four. Summing the widths and
   their gaps by hand is what the column description replaced: the sum was
   written once for the rows and once for the header, and the two drifted until
   REPLIES sat past the right edge whatever the title was sized to. *)
let board_table_lead = 4

let board_title_width ~cols =
  Render_schedule.board_title_width
    ~inner_width:(max 0 (framed_inner_width cols - board_table_lead))

let board_kind_mark = function
  | Some Post_by_person -> Ansi.bold ^ (Theme.info ()) ^ "@" ^ Ansi.reset
  | Some Post_by_automation -> (Theme.warn ()) ^ "\xe2\x97\x90" ^ Ansi.reset
  | Some Post_by_system -> " "
  | Some (Post_kind_unknown _) -> (Theme.warn ()) ^ "?" ^ Ansi.reset
  | None -> " "
;;

(* The score is a reading, not text: up-voted draws ok, down-voted bad, and
   zero -- most posts -- stays muted rather than claiming a colour. *)
let board_score_style votes =
  if votes > 0 then (Theme.ok ())
  else if votes < 0 then (Theme.bad ())
  else (Theme.muted ())

(** The draft pane. For a new post the commit-message convention is stated
    on screen rather than assumed: first line is the title, the rest is the
    body. A reply sends the whole draft as one comment, so its hint drops
    the title convention. A draft taller than the viewport shows its tail,
    where the caret is -- the operator is always writing at the bottom. *)
let render_board_compose (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let draft_content = Buffer.contents state.board_draft in
  let draft_chars = String.length draft_content in
  let raw_lines = String.split_on_char '\n' draft_content in
  let line_count = List.length raw_lines in
  let kind_line =
    match state.board_compose_reply_to with
    | Some post_id ->
        Printf.sprintf "  comment on %s  Enter: newline  Ctrl-E: $EDITOR"
          (fit_width (Terminal_text.single_line post_id) 16)
    | None ->
        let hearth_label =
          match state.board_compose_hearth with
          | Some h -> "#" ^ h
          | None -> "(default)"
        in
        Printf.sprintf "  first line: title  rest: body  hearth: %s  Enter: newline  Ctrl-E: $EDITOR"
          hearth_label
  in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s(%d lines, %d chars)%s"
    (screen_title " MASC Board")
    (Masc_tui_theme.tone Masc_tui_theme.Accent)
    (match state.board_compose_reply_to with
     | Some _ -> "reply" | None -> "new post")
    Ansi.reset
    (connection_badge state)
    Ansi.dim line_count draft_chars Ansi.reset
  in
  let addressing_kind = Board_composer.analyze_addressing draft_content in
  let addressing_line = Board_composer.format_addressing_hint ~max_cells:cols addressing_kind in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line buf cols (Ansi.dim ^ kind_line ^ Ansi.reset);
  box_line buf cols addressing_line;
  (match state.board_post_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  "
         ^ fit_width (Terminal_text.single_line err) (cols - 8)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;
  let text_width = max 10 (cols - 8) in
  let draft_lines =
    raw_lines
    |> List.concat_map (fun line ->
           let w = Message_layout.wrap_words ~max_cells:text_width
             (Terminal_text.single_line line) in
           if w = [] then [ "" ] else w)
  in
  let error_rows = if Option.is_some state.board_post_error then 1 else 0 in
  let chrome_top_rows = 5 + error_rows in
  let content_height = max 1 (rows - (chrome_top_rows + 3)) in
  let visible_lines =
    let total = List.length draft_lines in
    if total > content_height then
      List.filteri
        (fun index _ -> index >= total - content_height)
        draft_lines
    else draft_lines
  in
  List.iter
    (fun line ->
       box_line buf cols
         ("  " ^ fit_width line (cols - 8)))
    visible_lines;
  box_bottom buf cols;
  let prompt =
    if state.board_compose_armed then
      let hearth_hint =
        if Option.is_none state.board_compose_reply_to then "  h:cycle hearth"
        else ""
      in
      Printf.sprintf "s:send  e:edit in $EDITOR%s  d:discard  esc:keep writing" hearth_hint
    else
      "type to write  Ctrl-E:$EDITOR  esc:menu  Tab:surfaces  q:quit"
  in
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints:prompt);
  let cursor =
    if state.board_compose_armed then
      Frame_presenter.Hidden
    else
      let (row, column) =
        Board_composer.compute_caret_position
          ~chrome_top_rows:(chrome_top_rows + 1)
          ~cols ~visible_lines
      in
      Frame_presenter.Visible_at { row = min (rows - 2) row; column }
  in
  finish_frame_with_strip state ~surface_key:"board-compose" ~cursor ~rows
    ~cols buf


(* Rows the Board list spends before any post: the box, its title and the
   hearth census under it, the column header and its rule, then the closing
   rule, the border, the detail line and the footer. Nine until the census
   line joined them; naming it is what lets a tenth reader check the
   arithmetic instead of trusting a literal that two places have to agree
   on. *)
let board_list_chrome_rows = 11

(* Three steps for three bands, from the palette every other reading on this
   screen draws through. Emphasis only ever restates what the count beside it
   already says, so NO_COLOR costs a reader nothing they cannot read. *)
let magnitude_tone = function
  | Magnitude.Leading -> (Masc_tui_theme.tone Masc_tui_theme.Accent)
  | Magnitude.Ordinary -> Ansi.reset
  | Magnitude.Below_even_share -> Ansi.dim

(* Every hearth on the board and how many posts it holds, with the one being
   read marked. [f] walked this list and drew none of it, so narrowing was a
   press into the dark: a reader could not see which hearths existed, which
   held most of the board, or where in the cycle they had got to.

   Counts come from the board's own census rather than the page on screen.
   The page is one listing of fifty and the hearth it belongs to may hold
   hundreds; a count taken from it would understate every hearth and
   understate the crowded ones most. *)
let board_hearth_census_line ~cols (state : state) =
  match state.board_hearths with
  | [] ->
      Ansi.dim
      ^ "  hearths: none counted yet \xe2\x80\x94 f narrows once they are"
      ^ Ansi.reset
  | census ->
      let total = List.fold_left (fun sum (_, count) -> sum + count) 0 census in
      (* Banded over the whole census, then cut to what fits. Banding the
         visible slice would rank each hearth against the four that happened
         to fit beside it, which is a different question from the one the row
         asks. *)
      let banded = Magnitude.of_counts census in
      let entry (name, count, band) =
        let selected = Option.equal String.equal state.board_hearth (Some name) in
        let text = Printf.sprintf "%s %d" (Terminal_text.single_line name) count in
        (* Selection wins over size: which hearth is being read is a different
           axis from how big it is, and the reverse block says the first
           without leaving the second unsaid -- the count is in the text. *)
        if selected then Ansi.reverse ^ text ^ Ansi.reset
        else magnitude_tone band ^ text ^ Ansi.reset
      in
      (* What fits, then how many it could not carry. The board here holds
         eleven hearths and a narrow pane holds four of them; a row sized by
         how many exist is a row that runs off the edge on the next one. *)
      let rec take kept used = function
        | [] -> (List.rev kept, 0)
        | ((name, count, _) as banded_entry) :: rest ->
            let width =
              Message_layout.display_width
                (Printf.sprintf "%s %d" name count)
              + if kept = [] then 0 else 3
            in
            if used + width > max 8 (cols - 26) then
              (List.rev kept, 1 + List.length rest)
            else take (banded_entry :: kept) (used + width) rest
      in
      let kept, dropped = take [] 0 banded in
      let shown =
        List.map entry kept |> String.concat (Ansi.dim ^ "  \xc2\xb7  " ^ Ansi.reset)
      in
      Printf.sprintf "  %shearths%s %s%s%s" Ansi.dim Ansi.reset shown
        (if dropped = 0 then ""
         else Printf.sprintf "%s  \xc2\xb7  +%d%s" Ansi.dim dropped Ansi.reset)
        (Printf.sprintf "%s   %d posts%s" Ansi.dim total Ansi.reset)

let render_board_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length state.board_posts in
  (* Which sub-board is being read. Said only when the list is narrowed: "all
     hearths" is what a reader assumes, and 24 of them share this board with
     1550 of 2171 posts in one, so a narrowed list that did not say so would
     look like a board that had gone quiet. *)
  let hearth =
    match state.board_hearth with
    | None -> ""
    | Some hearth ->
        Printf.sprintf "  %shearth:%s%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line hearth) Ansi.reset
  in
  let header = Printf.sprintf "%s (%d)  order:%s%s  %s  %s"
    (screen_title " MASC Board")
    count (board_sort_label state.board_sort) hearth timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  order %s · s cycles ranking"
       (board_sort_explanation state.board_sort));
  box_line buf cols (board_hearth_census_line ~cols state);
  box_divider buf cols;
  (* The header is laid out by the same arithmetic as the rows below it,
     because a header laid out by its own is a header that stops describing
     them. It did: the rows size their title to [cols - 68] and the header
     claimed a fixed 20, so at eighty columns the header ran eight cells
     long. The overflow pushed SCORE into the frame's edge and REPLIES off
     it -- two columns still drawn on every row, with nothing left saying
     what they were. The mark ahead of the id is one cell and the header
     reserved two, which put every label one cell right of its data.

     The column description in [Render_schedule] is the one place either of
     them asks. *)
  let title_w = board_title_width ~cols in
  box_line_styled buf cols ~style:(Theme.recede ())
    (String.make board_table_lead ' '
     ^ Render_schedule.board_header_row ~title_width:title_w);
  box_divider buf cols;

  let board_list_error =
    Terminal_text.optional_single_line state.board_list_error
  in
  let render_list_error err =
    box_line buf cols (data_unreliable_row ~cols err)
  in
  if count = 0 then begin
    (match board_list_error with
     | Some err -> render_list_error err
     | None ->
         box_line buf cols (Ansi.dim ^ "  (no board posts)" ^ Ansi.reset));
    for _ = 1 to rows - board_list_chrome_rows do
      box_empty buf cols
    done
  end else begin
    Option.iter render_list_error board_list_error;
    let error_rows = if Option.is_some board_list_error then 1 else 0 in
    let content_height = max 0 (rows - board_list_chrome_rows - error_rows) in
    let scroll_offset =
      if state.board_cursor >= content_height then
        state.board_cursor - content_height + 1
      else 0
    in
    (* One clock read for the whole page, so two rows drawn in the same frame
       cannot report ages a tick apart. *)
    let now_unix = Unix.gettimeofday () in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let p = List.nth state.board_posts idx in
        let is_selected = idx = state.board_cursor in
        (* The age is since the post or one of its comments last moved. A
           board's list had no timestamp at all, so "what is still alive" --
           the question the [recent] and [updated] sort orders answer -- could
           only be read off the order the rows happened to arrive in. Spelled
           with the same ladder the Approvals queue uses, so a span reads the
           same on both. *)
        let hearth_text =
          match Terminal_text.optional_single_line p.bp_hearth with
          | Some h when not (String.equal h "") -> "#" ^ h
          | _ -> ""
        in
        let score_text =
          if p.bp_votes > 0 then Printf.sprintf "▲%+d" p.bp_votes
          else if p.bp_votes < 0 then Printf.sprintf "▼%d" p.bp_votes
          else " 0"
        in
        let replies_text =
          if p.bp_comment_count > 0 then Printf.sprintf "💬%d" p.bp_comment_count
          else "c0"
        in
        let values =
          { Render_schedule.brow_mark = board_kind_mark p.bp_kind
          ; brow_id = Terminal_text.single_line p.bp_id
          ; brow_hearth = hearth_text
          ; brow_author = Terminal_text.single_line p.bp_author
          ; brow_title = Terminal_text.single_line p.bp_title
          ; brow_age = Message_layout.span_text (now_unix -. p.bp_updated_at)
          ; brow_score = score_text
          ; brow_replies = replies_text
          }
        in
        let styles =
          { Render_schedule.bstyle_id =
              Masc_tui_theme.tone Masc_tui_theme.Accent
          ; bstyle_hearth =
              if String.equal hearth_text "" then Ansi.dim else (Theme.info ())
          ; bstyle_author = Masc_tui_theme.tone Masc_tui_theme.Accent
          ; bstyle_age = Ansi.dim
          ; bstyle_score = board_score_style p.bp_votes
          ; bstyle_replies =
              if p.bp_comment_count > 0 then (Theme.ok ()) else Ansi.dim
          }
        in
        let content =
          String.make board_table_lead ' '
          ^ Render_schedule.board_row ~styles ~title_width:title_w values
        in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr content)
        else
          box_line buf cols content
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:move  PgUp/PgDn:page  right/Enter:read  s:sort  f:hearth  Y:copy link  v/V:vote  w:write  r:refresh  Tab:next");

  finish_surface state ~surface_key:"board-list" ~rows:terminal_rows
      ~cols buf

(** Render the Board surface (read view). *)
(* The read post alone -- borders, header, body, comments -- at [cols]
   wide, footer excluded, so a caller can lay it beside the post list.
   Returns the scroll the frame used. *)
let board_read_pane (state : state) (list_post : board_post) ~rows ~cols buf =
  let detail =
    Board_detail.view_for state.board_detail ~post_id:list_post.bp_id
  in
  let post =
    match detail with
    | Board_detail.Ready (detail_post, _) -> detail_post
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        list_post
  in

  let hearth_tag =
    match Terminal_text.optional_single_line post.bp_hearth with
    | Some h when not (String.equal h "") ->
        Printf.sprintf "  %s#%s%s" (Theme.info ()) h Ansi.reset
    | _ -> ""
  in
  let score_chip =
    if post.bp_votes > 0 then
      Printf.sprintf "%s▲%+d%s" (board_score_style post.bp_votes) post.bp_votes Ansi.reset
    else if post.bp_votes < 0 then
      Printf.sprintf "%s▼%d%s" (board_score_style post.bp_votes) post.bp_votes Ansi.reset
    else
      Printf.sprintf "%s 0%s" (board_score_style post.bp_votes) Ansi.reset
  in
  let replies_chip =
    if post.bp_comment_count > 0 then
      Printf.sprintf "%s💬%d%s" (Theme.ok ()) post.bp_comment_count Ansi.reset
    else
      Printf.sprintf "%sc0%s" Ansi.dim Ansi.reset
  in
  let header =
    Printf.sprintf "%s  %s[%s]%s%s  %s  %s"
      (screen_title " MASC Board")
      (Masc_tui_theme.tone Masc_tui_theme.Accent)
      (fit_width (Terminal_text.single_line post.bp_id) 12)
      Ansi.reset
      hearth_tag
      score_chip
      replies_chip
  in

  box_top buf cols;
  box_line buf cols header;
  box_line buf cols
    (Printf.sprintf "  Actions:  %s[c]%s Reply   %s[v/V]%s Vote (+/-)   %s[Y]%s Copy Link   %s[Esc]%s Back"
       (Theme.ok ()) Ansi.reset
       (Theme.warn ()) Ansi.reset
       (Theme.info ()) Ansi.reset
       (Theme.recede ()) Ansi.reset);
  box_divider buf cols;

  let title_line = Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line post.bp_title) (cols - 6))
    Ansi.reset
  in
  box_line buf cols title_line;
  let author_chip =
    let author_name = Terminal_text.single_line post.bp_author in
    match post.bp_kind with
    | Some Post_by_automation ->
        Printf.sprintf "%s@%s%s %s[Keeper]%s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          author_name
          Ansi.reset
          (Theme.warn ())
          Ansi.reset
    | Some Post_by_person ->
        Printf.sprintf "%s@%s%s %s[Author]%s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          author_name
          Ansi.reset
          (Theme.info ())
          Ansi.reset
    | _ ->
        Printf.sprintf "%s@%s%s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          author_name
          Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "  %s  %s\xc2\xb7%s  %s  %s\xc2\xb7%s  %s%s%s"
       author_chip
       Ansi.dim Ansi.reset
       (Terminal_text.single_line post.bp_created_at)
       Ansi.dim Ansi.reset
       Ansi.dim
       (Link.reference Board_post (Terminal_text.single_line post.bp_id))
       Ansi.reset);
  box_divider buf cols;

  (* Body lines *)
  let text_width = cols - 8 in
  (* Sanitised a line at a time. A newline is a control byte, so sanitising the
     body whole escaped every break and the post arrived as one unbroken run
     with "\x0A" printed through it. *)
  (* Board posts are written in markdown -- headings, fences, rules -- and were
     drawn as the source they were typed as. The chat pane has rendered them
     for a while; this surface reads the same kind of document. *)
  let body_lines =
    Message_layout.wrap_body
      ~markdown:board_document_markdown
      ~max_cells:text_width
      ~sanitize:Terminal_text.single_line
      post.bp_body
  in
  (* What this post points at, and who else points at the same thing.
     Read from the references the writer actually wrote -- [Link.scan] takes
     only what [Link.reference] could have produced. An id spelled in prose is
     not a link: a connection the writer did not make is one nobody checked,
     and following it would go somewhere they never meant.

     Appended to the body so the surface's own scroll carries them; this pane
     measures its lines rather than reserving rows. *)
  let referenced = Link.scan post.bp_body in
  let related =
    match referenced with
    | [] -> []
    | referenced ->
      state.board_posts
      |> List.filter (fun (other : board_post) ->
        (not (String.equal other.bp_id post.bp_id))
        && List.exists
             (fun hit -> List.mem hit referenced)
             (Link.scan other.bp_body))
  in
  let reference_lines =
    match referenced with
    | [] -> []
    | referenced ->
      (Ansi.dim ^ "" ^ Ansi.reset)
      :: (Ansi.bold ^ "  POINTS AT" ^ Ansi.reset)
      :: List.map
           (fun (kind, id) ->
             (* [Link.parse] percent-decodes the id segment, so a body that
                writes masc://board/%1b%5b2J hands this line real escape
                bytes. The kind is a closed variant and needs no sanitizer;
                the id is whatever the writer typed. *)
             Printf.sprintf "  %s%-10s %s%s" Ansi.reset
               (Link.kind_label kind)
               (fit_width (Terminal_text.single_line id) (max 8 (cols - 16)))
               Ansi.reset)
           referenced
  in
  let related_lines =
    match related with
    | [] -> []
    | related ->
      (Ansi.dim ^ "" ^ Ansi.reset)
      :: (Ansi.bold
          ^ Printf.sprintf "  ALSO ABOUT THIS (%d)" (List.length related)
          ^ Ansi.reset)
      :: (related
          |> List.filteri (fun index _ -> index < 5)
          |> List.map (fun (other : board_post) ->
               Printf.sprintf "  %s  %s%s%s"
                 (fit_width (Terminal_text.single_line other.bp_id) 12)
                 Ansi.dim
                 (fit_width (Terminal_text.single_line other.bp_title)
                    (max 8 (cols - 26)))
                 Ansi.reset))
  in
  let body_lines = body_lines @ reference_lines @ related_lines in
  let total_lines = List.length body_lines in
  let detail_lines =
    match detail with
    | Board_detail.Absent ->
        [Ansi.dim ^ "  Board detail unavailable" ^ Ansi.reset]
    | Board_detail.Loading ->
        [Ansi.dim ^ "  Loading Board detail..." ^ Ansi.reset]
    | Board_detail.Failed error ->
        [ (Theme.bad ()) ^ "  Board detail unavailable: "
          ^ fit_width (Terminal_text.single_line error) (max 1 (cols - 32))
          ^ Ansi.reset
        ]
    | Board_detail.Ready (_, comments) ->
        (* A reply and the thing it answers used to sit at one indent in clock
           order, so a thread read as unrelated remarks. [parent_id] has been
           on the wire since comments existed -- 152 of this workspace's 1364
           comments carry one -- and the pane simply never decoded it. *)
        Board_comment_thread.order comments
        |> List.concat_map
          (fun (depth, c) ->
             let rail =
               if depth <= 0 then ""
               else
                 let bar = (Theme.recede ()) ^ "\xe2\x94\x82 " ^ Ansi.reset in
                 let indent = String.make (2 * (min depth 4 - 1)) ' ' in
                 indent ^ bar
             in
             let author = Terminal_text.single_line c.bc_author in
             let created_at = Terminal_text.single_line c.bc_created_at in
             let author_role =
               if String.equal author (Terminal_text.single_line post.bp_author) then
                 " " ^ (Theme.info ()) ^ "[Author]" ^ Ansi.reset
               else if List.exists (fun (k : Tui_decode.keeper) -> String.equal k.k_name author) state.keepers then
                 " " ^ (Theme.warn ()) ^ "[Keeper]" ^ Ansi.reset
               else ""
             in
             let heading =
               Printf.sprintf "  %s%s@%s%s%s  %s%s%s"
                 rail
                 (Masc_tui_theme.tone Masc_tui_theme.Accent)
                 author
                 Ansi.reset
                 author_role
                 Ansi.dim
                 created_at
                 Ansi.reset
             in
             let body =
               Message_layout.wrap_body ~markdown:board_document_markdown
                 ~max_cells:
                   (max 1
                      (cols - 10 - Message_layout.display_width rail))
                 ~sanitize:Terminal_text.single_line c.bc_content
             in
             match body with
             | [ line ] -> [ heading ^ "  " ^ line ]
             | [] -> [ heading ^ "  " ^ Ansi.dim ^ "\xc2\xb7" ^ Ansi.reset ]
             | lines ->
                 heading
                 :: List.map
                      (fun line -> "  " ^ rail ^ "  " ^ line) lines)
  in
  let detail_line_count = List.length detail_lines in
  let row_budget =
    Render_schedule.allocate_board_read ~terminal_rows:rows
      ~body_line_count:total_lines
      ~comment_count:detail_line_count
  in
  let content_height = row_budget.body_rows in
  let comment_height = row_budget.comment_rows in
  let scroll =
    Render_schedule.project_board_read_scroll ~body_line_count:total_lines
      ~body_rows:content_height
      ~comment_count:detail_line_count
      ~comment_rows:comment_height state.board_scroll
  in
  for i = 0 to content_height - 1 do
    let idx = i + scroll.body_offset in
    if idx < total_lines then
      box_line buf cols ("  " ^ List.nth body_lines idx)
    else
      box_empty buf cols
  done;

  if comment_height > 0 then begin
    box_divider buf cols;
    box_line buf cols (Ansi.bold ^ "  Comments" ^ Ansi.reset);
    for i = 0 to comment_height - 1 do
      box_line buf cols (List.nth detail_lines (i + scroll.comment_offset))
    done
  end;

  box_bottom buf cols;
  scroll.normalized_scroll

(* The post list beside the read: position context with the open post
   marked, exactly the roster-beside-detail shape. *)
let board_list_pane (state : state) ~(open_post : board_post) ~rows ~cols buf =
  let selected =
    let rec find i = function
      | [] -> 0
      | (post : board_post) :: rest ->
          if String.equal post.bp_id open_post.bp_id then i
          else find (i + 1) rest
    in
    find 0 state.board_posts
  in
  let format_sidebar_post (post : board_post) =
    let hearth_prefix =
      match Terminal_text.optional_single_line post.bp_hearth with
      | Some h when not (String.equal h "") -> "#" ^ h ^ " "
      | _ -> ""
    in
    let vote_prefix =
      if post.bp_votes > 0 then Printf.sprintf "+%d " post.bp_votes
      else if post.bp_votes < 0 then Printf.sprintf "%d " post.bp_votes
      else ""
    in
    Printf.sprintf "%s%s%s" hearth_prefix vote_prefix
      (Terminal_text.single_line post.bp_title)
  in
  write_list_sidebar buf ~rows ~cols ~title:"Board"
    ~focused:(state.board_focus = Left_pane)
    ~labels:(List.map format_sidebar_post state.board_posts)
    ~selected

let render_board_read (state : state) (list_post : board_post) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let footer =
    let pane_hint =
      if cols >= keeper_split_threshold_cols && not state.board_detail_wide then
        "  h/l:pane  Ctrl-W:switch"
      else ""
    in
    footer_line state ~max_cells:cols
      ~hints:
        (Printf.sprintf
           "j/k:%s  [/]:post  PgUp/PgDn:page%s  z:wide  Y:copy link  left/Esc:back  c:reply  r:refresh  Tab:next"
           (if state.board_focus = Left_pane then "posts" else "scroll")
           pane_hint)
  in
  if cols < keeper_split_threshold_cols || state.board_detail_wide then begin
    let scroll = board_read_pane state list_post ~rows ~cols buf in
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  end
  else begin
    let left_cols = keeper_roster_pane_cols in
    let right_cols = cols - left_cols in
    let left_buf = Buffer.create 1024 in
    let right_buf = Buffer.create 4096 in
    board_list_pane state ~open_post:list_post ~rows ~cols:left_cols left_buf;
    let scroll =
      board_read_pane state list_post ~rows ~cols:right_cols right_buf
    in
    write_two_panes buf ~left_cols:left_cols ~left:left_buf
      ~right:right_buf;
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  end

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

let planning_phase_label phase = Goal_phase.to_string phase

(* As wide as the widest phase rather than a literal. Three of the four labels
   are nine cells and the column was eight, so nearly every planning row read
   [complet~] with sixty columns of space to its right -- the mark that says
   "there was more" on a value nothing was cut from. Taken from the phase list
   so a new phase widens the column instead of losing its last letter. *)
(* Rows the Planning list spends above its goals, and the row it holds below
   them for the selected goal's verdict. Both were bare numbers at the two
   places that read them, and both went up by two when the list gained the
   column names it never had. Still tallied rather than counted: the counted
   form needs the rows below the list to be certain, and being one short is
   silent -- the frame drops its last row, which is the footer. #32928 carries
   that change for the three surfaces where the tail is already established. *)
(* One more than it was: the JUDGE legend sits under the column header. *)
let planning_list_chrome_rows = 15
let planning_list_verdict_rows = 2

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

   It takes a categorical slot now (RFC-0427). Slot 4 is magenta, the hue it
   already drew, and magenta is one of the two the status axis does not
   claim -- which matters here, because the three phases beside it are
   status tokens and a slot aliasing one of those would read as a verdict.

   The count of these was thirteen. This is the last of them. *)
let planning_phase_color = function
  | Goal_phase.Executing -> (Theme.info ())
  | Goal_phase.Verifying -> Theme.category Theme.Slot_4
  | Goal_phase.Completed -> (Theme.ok ())
  | Goal_phase.Dropped -> (Theme.muted ())

(* The lifecycle as a rail, not a single word. The phase says where the goal
   is; it never said what the stages are or which way they run, so "what does
   [c] do here" was a question the screen could not answer. The occupied stop
   is bracketed and keeps its colour, the rest stay dim.

   [Dropped] is not a stop on this line -- it leaves the line -- so a dropped
   goal draws what it is and how to come back instead of highlighting a stop
   on a rail it is no longer on. *)
let planning_stage_rail (phase : Goal_phase.t) =
  let stop stage =
    let label = planning_phase_label stage in
    if stage = phase then
      planning_phase_color stage ^ Ansi.bold ^ "[" ^ label ^ "]" ^ Ansi.reset
    else Ansi.dim ^ " " ^ label ^ " " ^ Ansi.reset
  in
  let arrow = Ansi.dim ^ "\xe2\x94\x80\xe2\x96\xb6" ^ Ansi.reset in
  match phase with
  | Goal_phase.Dropped ->
    planning_phase_color Goal_phase.Dropped
    ^ Ansi.bold ^ "[dropped]" ^ Ansi.reset
    ^ Ansi.dim ^ "  (off the line; [o] puts it back on executing)" ^ Ansi.reset
  | Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Completed ->
    String.concat arrow
      [ stop Goal_phase.Executing
      ; stop Goal_phase.Verifying
      ; stop Goal_phase.Completed
      ]
;;

(* What moves this goal next, in one sentence, from the pair the operator can
   see separately but had to combine themselves: the phase and the judge's
   last word. [executing] with a refusal on the ledger is a different
   instruction from [executing] with nothing on it, and both drew the same
   word. Only the goal phase decides here -- the linked tasks have their own
   surface and their own verdicts. *)
let planning_next_step (goal : planning_goal) =
  match goal.pg_phase, goal.pg_proof with
  | Goal_phase.Executing, Tui_decode.Proof_refuted _ ->
    ( (Theme.bad ())
    , "refused - fix what the verdict names below, then [c] to resubmit" )
  | Goal_phase.Executing, _ ->
    ( Ansi.dim
    , "work the linked tasks, then [c] to submit it for verification" )
  | Goal_phase.Verifying, _ ->
    ( (Theme.warn ())
    , "with the completion judge - nothing to press; [c] re-arms the request" )
  | Goal_phase.Completed, _ -> (Ansi.dim, "reached its target - [o] reopens it")
  | Goal_phase.Dropped, _ -> (Ansi.dim, "abandoned - [o] reopens it")
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
let planning_proof_mark = function
  | Tui_decode.Proof_idle -> " "
  | Tui_decode.Proof_pending -> (Theme.warn ()) ^ "\xe2\x80\xa6" ^ Ansi.reset
  | Tui_decode.Proof_proven _ -> (Theme.ok ()) ^ "\xe2\x9c\x93" ^ Ansi.reset
  | Tui_decode.Proof_refuted _ -> (Theme.bad ()) ^ "\xe2\x9c\x97" ^ Ansi.reset
  | Tui_decode.Proof_unreadable _ -> (Theme.warn ()) ^ "!" ^ Ansi.reset
;;

(* The line under the list, for the goal the cursor is on. A verdict without its
   reason is a colour and nothing else; the reason is what the judge produced
   and the only thing that says what to do next. *)
let planning_proof_detail (goal : planning_goal) =
  match goal.pg_proof with
  | Tui_decode.Proof_proven None -> Some ((Theme.ok ()), "proven")
  | Tui_decode.Proof_proven (Some evidence) -> Some ((Theme.ok ()), "proven: " ^ evidence)
  | Tui_decode.Proof_refuted None -> Some ((Theme.bad ()), "refused")
  | Tui_decode.Proof_refuted (Some reason) -> Some ((Theme.bad ()), "refused: " ^ reason)
  | Tui_decode.Proof_pending -> Some ((Theme.warn ()), "waiting for the completion judge")
  | Tui_decode.Proof_unreadable None ->
      Some ((Theme.warn ()), "verification ledger unreadable")
  | Tui_decode.Proof_unreadable (Some detail) ->
      Some ((Theme.warn ()), "verification ledger unreadable: " ^ detail)
  | Tui_decode.Proof_idle ->
      (* Nothing from the judge. A keeper's own note is the next best thing the
         row has to say, and it is what the operator wrote there to be read. *)
      Option.map
        (fun note -> (Ansi.dim, "note: " ^ note))
        (Terminal_text.optional_single_line goal.pg_last_review_note)
;;

let planning_selected_detail (goal : planning_goal) =
  let metric =
    match
      Terminal_text.optional_single_line goal.pg_metric,
      Terminal_text.optional_single_line goal.pg_target_value
    with
    | Some name, Some target ->
        Printf.sprintf "metric: %s \xe2\x86\x92 %s" name target
    | Some name, None -> "metric: " ^ name
    | None, Some target -> "target: " ^ target
    | None, None -> "metric: \xe2\x80\x94"
  in
  match planning_proof_detail goal with
  | None -> Ansi.dim, Printf.sprintf "%s \xc2\xb7 %s" goal.pg_id metric
  | Some (colour, proof) ->
      colour,
      Printf.sprintf "%s \xc2\xb7 %s \xc2\xb7 %s" goal.pg_id metric proof
;;

(* Freshness in one short word: the exact timestamps live in the detail
   pane; the row only needs to separate "touched today" from "quiet for
   weeks". A timestamp that does not parse renders nothing here -- the raw
   string is still shown unmodified in the detail pane. *)
let planning_updated_age ~now (goal : planning_goal) =
  match goal.pg_updated_at with
  | None -> None
  | Some iso ->
      Option.map
        (fun then_ ->
           let delta = max 0. (now -. then_) in
           if delta < 60. then "now"
           else if delta < 3600. then
             Printf.sprintf "%dm" (int_of_float (delta /. 60.))
           else if delta < 86400. then
             Printf.sprintf "%dh" (int_of_float (delta /. 3600.))
           else Printf.sprintf "%dd" (int_of_float (delta /. 86400.)))
        (Masc_domain.parse_iso8601_opt iso)

(** Render the Planning surface (list view). *)

let render_planning_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now_unix = Unix.gettimeofday () in
  let now = Unix.localtime now_unix in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  order:%s  show:%s  %s  %s"
    (planning_workspace_title state ~tab:Planning_goals ~window:"")
    (planning_sort_label state.planning_sort)
    (planning_filter_label state.planning_filter)
    timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let goals =
    match state.planning with
    | None -> []
    | Some p ->
        planning_visible_goals ~filter:state.planning_filter
          ~sort:state.planning_sort p.pl_goals
  in
  let count = List.length goals in
  let planning_error =
    Terminal_text.optional_single_line state.planning_error
  in

  (match state.planning with
   | None ->
       (match planning_error with
        | Some err ->
            box_line buf cols (data_unreliable_row ~cols err)
        | None ->
            box_line buf cols (Ansi.dim ^ page_unread_note ^ Ansi.reset));
       for _ = 1 to rows - boxed_surface_chrome_rows - 1 do
         box_empty buf cols
       done
   | Some p ->
       let total_goals =
         p.pl_rollup.pr_active + p.pl_rollup.pr_verifying + p.pl_rollup.pr_done
         + p.pl_rollup.pr_dropped
       in
       let progress_pct =
         if total_goals > 0 then p.pl_rollup.pr_done * 100 / total_goals else 0
       in
       let bar_width = if cols < 90 then 8 else 12 in
       let progress_bar =
         if total_goals > 0 then
           Printf.sprintf "[%s] %2d%% (%d/%d)"
             (Masc_tui_context_bars.ratio_bar ~width:bar_width
                ~numerator:p.pl_rollup.pr_done ~denominator:total_goals)
             progress_pct p.pl_rollup.pr_done total_goals
         else "no goals"
       in
       let phase_counters =
         Printf.sprintf
           "%s● Exec: %d%s  %s◆ Ver: %d%s  %s✓ Done: %d%s  %s✕ Drop: %d%s"
           (planning_phase_color Goal_phase.Executing)
           p.pl_rollup.pr_active Ansi.reset
           (planning_phase_color Goal_phase.Verifying)
           p.pl_rollup.pr_verifying Ansi.reset
           (planning_phase_color Goal_phase.Completed)
           p.pl_rollup.pr_done Ansi.reset
           (planning_phase_color Goal_phase.Dropped)
           p.pl_rollup.pr_dropped Ansi.reset
       in
       let rollup =
         Printf.sprintf "  Goals: %s%s%s %s  %s│%s  %s"
           Ansi.bold (string_of_int total_goals) Ansi.reset
           progress_bar (Theme.recede ()) Ansi.reset phase_counters
       in
       let backlog_sep =
         Printf.sprintf " %s%s%s " (Theme.recede ())
           Masc_tui_theme.Glyph.breadcrumb_sep Ansi.reset
       in
       let backlog =
         let items =
           [ ("todo", p.pl_backlog.pb_todo, Masc_tui_theme.Glyph.task_todo ^ " todo")
           ; ("claimed", p.pl_backlog.pb_claimed, "claimed")
           ; ("running", p.pl_backlog.pb_running, Masc_tui_theme.Glyph.task_active ^ " running")
           ; ("done", p.pl_backlog.pb_done, Masc_tui_theme.Glyph.task_done ^ " done")
           ; ("cancelled", p.pl_backlog.pb_cancelled, Masc_tui_theme.Glyph.task_cancelled ^ " cancelled")
           ]
         in
         let counts = List.map (fun (k, v, _) -> k, v) items in
         let bands = Magnitude.of_counts counts in
         List.map2
           (fun (_, _, label) (_, value, band) ->
              Printf.sprintf "%s%s=%d%s" (magnitude_tone band) label value
                Ansi.reset)
           items bands
         |> String.concat backlog_sep
       in
       box_line buf cols rollup;
       box_line buf cols
         (Printf.sprintf "  %sBacklog:%s %s" Ansi.dim Ansi.reset backlog);
       box_divider buf cols;
       (* The list drew rows and never said what they were. *)
       let phase_width = planning_phase_column + 2 in
       let title_width =
         Render_schedule.planning_title_width
           ~inner_width:(max 1 (framed_inner_width cols - 2))
           ~phase_width
       in
       box_line_styled buf cols ~style:(Theme.recede ())
         ("  " ^ Render_schedule.planning_header_row ~phase_width ~title_width);
       (* What the JUDGE column's marks mean, once, under the header that
          names it. The glyphs are the only part of a row an operator cannot
          read straight off, and every one of them changes what to do next. *)
       box_line_styled buf cols ~style:Ansi.dim
         ("  JUDGE  \xe2\x80\xa6 waiting  \xe2\x9c\x93 proven  \xe2\x9c\x97 refused, back in executing  ! unreadable");
       box_divider buf cols;

       if count = 0 then begin
         (* An empty filter and an empty store are different facts: the first
            says how to see the rest, the second has nothing to show. *)
         let empty_note =
           match p.pl_goals with
           | [] -> "  (no goals)"
           | _ -> "  no goals in this filter (f to change)"
         in
         box_line buf cols (Ansi.dim ^ empty_note ^ Ansi.reset);
         for _ = 1 to rows - planning_list_chrome_rows do
           box_empty buf cols
         done
       end else begin
         (* One row is reserved below the list for the selected goal's verdict. *)
         let content_height = rows - planning_list_chrome_rows - planning_list_verdict_rows in
         let scroll_offset =
           if state.planning_cursor >= content_height then
             state.planning_cursor - content_height + 1
           else 0
         in
         for i = 0 to content_height - 1 do
           let idx = i + scroll_offset in
           if idx < count then begin
             let g = List.nth goals idx in
             let is_selected = idx = state.planning_cursor in
             let status_color = planning_phase_color g.pg_phase in
             let status_label = planning_phase_label g.pg_phase in
            (* The gap belonged to the reading before; the columns space
               themselves now, and an absent date leaves its cell empty rather
               than moving the one beside it. *)
            let due =
              match Terminal_text.optional_single_line g.pg_due_date with
              | Some d -> d
              | None -> ""
            in
             let age =
               match planning_updated_age ~now:now_unix g with
               | Some a -> a
               | None -> ""
             in
             (* What is being done about this goal, on the row itself. The
                detail panel below already resolves the same links, but only
                for the goal under the cursor: reading which of seventeen
                goals had work stuck in verification took seventeen moves.

                [state.tasks] drops terminal rows and the goal links ride
                only on it ([task_of_domain] takes goal_ids as an argument;
                the domain record does not carry them), so this counts open
                work, not progress. A "5 of 12 done" would need the server to
                carry the link on finished rows too.

                One signal, not three: verification is the one that means
                something is not moving, so it wins the cell when both are
                present. *)
             let open_note, open_style =
                let linked =
                  List.filter
                    (fun (t : Tui_decode.task) -> List.mem g.pg_id t.goal_ids)
                    state.tasks
                in
                match linked with
                | [] -> "", ""
                | _ ->
                    let tally predicate =
                      List.length (List.filter predicate linked)
                    in
                    let awaiting =
                      tally (fun (t : Tui_decode.task) ->
                          match t.status with
                          | Masc_domain.AwaitingVerification _ -> true
                          | _ -> false)
                    in
                    let running =
                      tally (fun (t : Tui_decode.task) ->
                          match t.status with
                          | Masc_domain.InProgress _ -> true
                          | _ -> false)
                    in
                    let total = List.length linked in
                    if awaiting > 0 then
                      Printf.sprintf "%d open %d ver" total awaiting, (Theme.warn ())
                    else if running > 0 then
                      Printf.sprintf "%d open %d run" total running, (Theme.info ())
                    else Printf.sprintf "%d open" total, Ansi.dim
             in
             let priority_style =
               match g.pg_priority with
               | 1 -> (Theme.bad ()) ^ Ansi.bold
               | 2 -> (Theme.warn ())
               | 3 -> Ansi.reset
               | _ -> Ansi.dim
             in
             let lead = if is_selected then "> " else "  " in
             let line =
               lead
               ^ Render_schedule.planning_row ~phase_style:status_color
                   ~priority_style ~open_style ~phase_width ~title_width
                   { Render_schedule.prow_phase = "[" ^ status_label ^ "]"
                   ; prow_proof = planning_proof_mark g.pg_proof
                   ; prow_priority = Printf.sprintf "P%d" g.pg_priority
                   ; prow_open = open_note
                   ; prow_title = Terminal_text.single_line g.pg_title
                   ; prow_age = age
                   ; prow_due = due
                   }
             in
             if is_selected then
               box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
             else
               box_line buf cols line
           end else
             box_empty buf cols
         done;
         match List.nth_opt goals state.planning_cursor with
         | None -> box_empty buf cols
         | Some selected ->
             let colour, text = planning_selected_detail selected in
             box_line buf cols
               (colour ^ "  " ^ Terminal_text.single_line text ^ Ansi.reset)
       end);

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));

  finish_surface state ~surface_key:"planning-list" ~rows:terminal_rows
      ~cols buf

(** Render the Planning surface (detail view). *)
(* Border, header, divider, title, phase, due, metric, blank, divider,
   border, footer: the eleven rows the detail draws whatever the goal says.
   A lifecycle arm, a refused request, and each present goal timestamp each
   add one more when they are there, so the block is measured against them
   rather than against a constant that would push the footer off a full
   screen. *)
(* One more than it was: the stage rail took the phase word's row and the
   next-step sentence is a row of its own. Counted here, drawn below. *)
let planning_detail_fixed_rows = 12

let planning_detail_tone (tone : Planning_detail.tone) =
  match tone with
  | Planning_detail.Proven -> (Theme.ok ())
  | Planning_detail.Refused -> (Theme.bad ())
  | Planning_detail.Waiting | Planning_detail.Unreadable -> (Theme.warn ())
  | Planning_detail.Note | Planning_detail.Quiet -> Ansi.dim

let planning_detail_pane (state : state)
    ~(armed : Goal_phase.Public_action.t option) ~rows ~cols
    (goal : planning_goal) buf =

  let status_color = planning_phase_color goal.pg_phase in
  let status_label = planning_phase_label goal.pg_phase in
  let header = Printf.sprintf "%s  %s[%s]%s  %s"
    (planning_workspace_title state ~tab:Planning_goals ~window:"")
    status_color (fit_width status_label planning_phase_column) Ansi.reset
    (fit_width (Terminal_text.single_line goal.pg_id) 20)
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols (Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line goal.pg_title) (cols - 6))
    Ansi.reset);
  let prio_color =
    match goal.pg_priority with
    | 1 -> (Theme.bad ()) ^ Ansi.bold
    | 2 -> (Theme.warn ())
    | 3 -> Ansi.reset
    | _ -> Ansi.dim
  in
  let proof_glyph = planning_proof_mark goal.pg_proof in
  box_line buf cols
    (Printf.sprintf "  Stage:   %s   %s"
       (planning_stage_rail goal.pg_phase) proof_glyph);
  let next_colour, next_text = planning_next_step goal in
  box_line buf cols
    (Printf.sprintf "  Next:    %s%s%s" next_colour next_text Ansi.reset);
  let due_text =
    match Terminal_text.optional_single_line goal.pg_due_date with
    | Some d -> d
    | None -> "\xe2\x80\x94"
  in
  let metric_text =
    match Terminal_text.optional_single_line goal.pg_metric with
    | Some m ->
        let target =
          match Terminal_text.optional_single_line goal.pg_target_value with
          | Some t -> " = " ^ t
          | None -> ""
        in
        m ^ target
    | None -> "\xe2\x80\x94"
  in
  box_line buf cols
    (Printf.sprintf "  Target:  %s   Due: %s   Priority: %sP%d%s"
       metric_text due_text prio_color goal.pg_priority Ansi.reset);
  box_line buf cols
    (Printf.sprintf "  Actions:  %s[c]%s Complete   %s[x]%s Drop   %s[o]%s Reopen"
       (Theme.ok ()) Ansi.reset
       (Theme.bad ()) Ansi.reset
       (Theme.info ()) Ansi.reset);
  (* The goal's own timeline, dim like the Board read pane's timestamps:
     when it was opened, when it last moved, when it was last reviewed. *)
  let timestamp_lines =
    List.filter_map
      (fun (label, value) ->
         Option.map
           (fun iso ->
              Planning_detail.timestamp_line ~label
                (Terminal_text.short_timestamp (Terminal_text.single_line iso)))
           value)
      [ "created", goal.pg_created_at
      ; "updated", goal.pg_updated_at
      ; "reviewed", goal.pg_last_review_at
      ]
  in
  List.iter
    (fun line -> box_line_styled buf cols ~style:Ansi.dim line)
    timestamp_lines;
  box_line_styled buf cols ~style:Ansi.dim
    ("  Link: "
     ^ Link.reference Goal (Terminal_text.single_line goal.pg_id));
  (* A lifecycle request is the one state the detail carries between frames,
     so it gets a row rather than an event log: the arm says what the next
     press of the same key would do, and the error says what the server said
     when the last one was refused. *)
  (match armed with
   | Some armed_action ->
       box_line buf cols
         ((Theme.warn ()) ^ Ansi.bold
          ^ Printf.sprintf "  ARMED: %s -- press same key again to submit, any other key to cancel"
             (match armed_action with
              | Goal_phase.Public_action.Request_complete -> "Request Completion [c]"
              | Goal_phase.Public_action.Drop -> "Drop Goal [x]"
              | Goal_phase.Public_action.Reopen -> "Reopen Goal [o]")
          ^ Ansi.reset)
   | None -> ());
  (match state.goal_action_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  Error: "
         ^ fit_width (Terminal_text.single_line err) (cols - 12)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;

  (* The verdict and the keeper's note: the two things the list draws under
     the cursor and the detail used to leave out, so opening a goal showed
     less than the row it was opened from. They wrap, so this is what the
     surface's scroll moves through. *)
  let body =
    Planning_detail.body ~width:(cols - 6) goal.pg_proof goal.pg_last_review_note
    @ Planning_detail.timeline ~width:(cols - 6) ~goal_id:goal.pg_id
        state.goal_timeline
  in
  (* What is being done about this goal. The goal record does not carry its
     tasks -- the goal-task registry is the source of truth and the loader
     resolved it onto each task -- so this reads them back the other way.
     Linear over the open tasks, which is a short list and costs nothing
     against keeping a second copy of the same links in the state.

     Capped: a goal with thirty tasks would take the whole frame and the
     proof underneath would never be seen. What is left out is said, because
     a list that stops without saying so reads as the whole list. *)
  let linked_tasks =
    List.filter
      (fun (row : Tui_decode.task) -> List.mem goal.pg_id row.goal_ids)
      state.tasks
  in
  let linked_drawn = List.filteri (fun index _ -> index < 6) linked_tasks in
  let linked_omitted = List.length linked_tasks - List.length linked_drawn in
  let linked_rows =
    match linked_tasks with
    | [] -> 1
    | _ -> 1 + List.length linked_drawn + (if linked_omitted > 0 then 1 else 0)
  in
  let chrome_rows =
    planning_detail_fixed_rows
    + List.length timestamp_lines
    + linked_rows
    + (match armed with Some _ -> 1 | None -> 0)
    + (match state.goal_action_error with Some _ -> 1 | None -> 0)
  in
  (* Drawn here, counted above: the two move together or the frame runs past
     the terminal and the presenter drops whatever fell off. *)
  (match linked_tasks with
   | [] ->
     box_line buf cols (Ansi.dim ^ "  Tasks       (none linked)" ^ Ansi.reset)
   | _ ->
     box_line buf cols (Ansi.bold ^ "  TASKS" ^ Ansi.reset);
     List.iter
       (fun (row : Tui_decode.task) ->
         box_line buf cols
           (Printf.sprintf "  %s  %s  %s"
              (fit_width (Terminal_text.single_line row.id) 22)
              (fit_width (Terminal_text.single_line row.title) (max 8 (cols - 60)))
              (Ansi.dim ^ Link.reference Task row.id ^ Ansi.reset)))
       linked_drawn;
     if linked_omitted > 0 then
       box_line buf cols
         (Printf.sprintf "%s  and %d more%s" Ansi.dim linked_omitted Ansi.reset));
  let content_height = max 1 (rows - chrome_rows) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length body) ~height:content_height
      state.planning_scroll
  in
  let drawn =
    body
    |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun (line : Planning_detail.line) ->
      box_line buf cols
        (Printf.sprintf "  %s%s%s"
           (planning_detail_tone line.Planning_detail.tone)
           (fit_width line.Planning_detail.text (cols - 6))
           Ansi.reset))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;

  box_bottom buf cols;
  scroll
;;

(* The goal list stays beside its detail. Opening one used to replace the
   other, so reading a row cost the reader their place in the list. Below the
   split width there is no room for both and the detail keeps the screen,
   which is the rule the Board read pane already follows. *)
let render_planning_detail (state : state)
    ~(armed : Goal_phase.Public_action.t option) (goal : planning_goal) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll =
    if cols < keeper_split_threshold_cols then
      planning_detail_pane state ~armed ~rows ~cols goal buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let goals =
        match state.planning with
        | None -> []
        | Some p ->
            planning_visible_goals ~filter:state.planning_filter
              ~sort:state.planning_sort p.pl_goals
      in
      let selected =
        let rec find i = function
          | [] -> 0
          | (row : planning_goal) :: rest ->
            if String.equal row.pg_id goal.pg_id then i else find (i + 1) rest
        in
        find 0 goals
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      let format_sidebar_goal (row : planning_goal) =
        let phase_badge =
          match row.pg_phase with
          | Goal_phase.Executing -> "[exec]"
          | Goal_phase.Verifying -> "[ver ]"
          | Goal_phase.Completed -> "[done]"
          | Goal_phase.Dropped -> "[drop]"
        in
        Printf.sprintf "%s P%d %s" phase_badge row.pg_priority
          (Terminal_text.single_line row.pg_title)
      in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Planning"
        ~focused:false
        ~labels:(List.map format_sidebar_goal goals)
        ~selected;
      let scroll =
        planning_detail_pane state ~armed ~rows ~cols:(cols - left_cols) goal
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      scroll
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints state.view));
  finish_surface state ~clamped:(Planning_detail_scroll scroll)
      ~surface_key:"planning-detail" ~rows:terminal_rows ~cols buf

(* The store's status vocabulary, as colours. An unknown word keeps its own
   text and no colour: the row is still a fact about the store, just one this
   build does not rank. *)
(* Who the wake reaches. The payload target names a keeper on the rows this
   list can draw; rows without one fall back to the summary, then the source,
   so every row names something.

   The kind prefix comes off first. It is "keeper:" on every row here, so it
   separates nothing and takes seven cells out of the name -- which left two
   schedules for two different keepers both reading "keeper:~". The agenda
   strip has stripped it since it was written; this list is the surface that
   did not.

   Lifted out of the row loop because the column measures itself from the
   rows now: the width and the cell have to be reading the same string. *)
let schedule_row_subject (row : Masc_tui_types.schedule_row) =
  match row.sch_payload_target with
  | Some target -> Masc_tui_agenda.short_who target
  | None -> (
    match row.sch_payload_summary with
    | Some summary -> summary
    | None -> row.sch_source)
;;

let schedule_status_color status =
  semantic_status_color status

let schedule_delivery_summary (row : schedule_row) =
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> "queue:\xe2\x80\x94"
    | Some status, None -> "queue:" ^ status
    | None, Some count -> Printf.sprintf "queue:pending=%d" count
    | Some status, Some count ->
        Printf.sprintf "queue:%s/%d pending" status count
  in
  let reaction =
    match row.sch_reaction_projection_status with
    | None -> "reaction:\xe2\x80\x94"
    | Some status -> "reaction:" ^ status
  in
  ( Printf.sprintf "%s \xc2\xb7 status:%s" row.sch_schedule_id
      row.sch_status
  , Printf.sprintf "%s \xc2\xb7 %s" queue reaction )

(** Render the Schedules surface: the scheduled-automation list, with an
    armed cancel. The server sorts active rows first by due time and caps the
    list at its own limit; [scs_truncated] and [scs_request_count] say what
    of the whole store this page is. *)
let render_schedule_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface lays
     out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s  %s"
    (screen_title " MASC Schedules")
    timestamp
    (connection_badge state) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  (match state.schedules with
   | None ->
       (match Terminal_text.optional_single_line state.schedules_error with
        | Some err ->
            box_line buf cols (data_unreliable_row ~cols err)
        | None ->
            box_line buf cols (Ansi.dim ^ page_unread_note ^ Ansi.reset));
       for _ = 1 to rows - boxed_surface_chrome_rows do
         box_empty buf cols
       done
   | Some snapshot ->
       if not (String.equal snapshot.scs_status "ok") then begin
         (* The server's "unknown" is a failed store read, not an empty list;
            the row says which, so a dead ledger cannot read as "nothing is
            scheduled". *)
         (match snapshot.scs_read_error with
          | Some err ->
              box_line buf cols (data_unreliable_row ~cols err)
          | None ->
              box_line buf cols
                ((Theme.bad ()) ^ "  (schedule store unreadable)" ^ Ansi.reset));
         for _ = 1 to rows - boxed_surface_chrome_rows do
           box_empty buf cols
         done
       end else begin
         let count_text =
           match snapshot.scs_request_count with
           | Some total when snapshot.scs_truncated ->
               Printf.sprintf "  Requests: %d  (page shows first %d)" total
                 (List.length snapshot.scs_rows)
           | Some total ->
               Printf.sprintf "  Requests: %d" total
           | None -> "  Requests: ?"
         in
         let next_due_text =
           match snapshot.scs_next_due_iso with
           | Some iso ->
               Printf.sprintf "  Next due: %s"
                 (Tui_decode.short_timestamp_for_terminal iso)
           | None -> ""
         in
         box_line buf cols (Ansi.bold ^ count_text ^ Ansi.reset);
         box_line buf cols (Ansi.dim ^ next_due_text ^ Ansi.reset);
         box_divider buf cols;

         let count = List.length snapshot.scs_rows in
         if count = 0 then begin
           box_line buf cols (Ansi.dim ^ "  (no scheduled automation)" ^ Ansi.reset);
           for _ = 1 to rows - 12 do
             box_empty buf cols
           done
         end else begin
           (* Keep two factual rows below the list for delivery state. Without
              it the list says when a wake is due but not whether the dispatch,
              queue, and reaction projections agree. Two rows keep all three
              projections readable at the 100-column regression viewport. *)
           let subject_width =
             List.fold_left
               (fun widest row ->
                 max widest
                   (Message_layout.display_width
                      (Terminal_text.single_line (schedule_row_subject row))))
               16 snapshot.scs_rows
             |> min 40
           in
           let content_height = rows - 14 in
           let scroll_offset =
             if state.schedule_cursor >= content_height then
               state.schedule_cursor - content_height + 1
             else 0
           in
           for i = 0 to content_height - 1 do
             let idx = i + scroll_offset in
             if idx < count then begin
               let row = List.nth snapshot.scs_rows idx in
               let is_selected = idx = state.schedule_cursor in
               let due =
                 match row.sch_due_at_iso with
                 | Some iso -> Tui_decode.short_timestamp_for_terminal iso
                 | None -> "-"
               in
               (* The payload target names who the wake reaches (a keeper for
                  keeper wakes); rows without one fall back to the summary,
                  then the source, so every row names something.

                  The kind prefix comes off first. It is "keeper:" on every
                  row this list can draw, so it separates nothing and takes
                  seven cells out of the name -- which left two schedules for
                  two different keepers both reading "keeper:~". The agenda
                  strip has stripped it since it was written; this list is
                  the surface that did not. *)
               let subject = schedule_row_subject row in
               let status_color = schedule_status_color row.sch_status in
               let last_wake =
                 Option.value ~default:"\xe2\x80\x94" row.sch_last_wake_status
               in
               let line =
                 Printf.sprintf "%s[%s]%s %s  %s  wake:%s%s%s  %s"
                   status_color
                   (fit_width row.sch_status 10)
                   Ansi.reset
                   due
                   (* Measured from the rows rather than given the rest of the
                      line. The subject is a keeper name on every row that has
                      a payload target, so [cols - 76] spent ninety cells on
                      [edgar.a.poe] and the recurrence past it -- which is
                      where the timezone lives -- read [daily 08:00:00 A~].
                      The fallback summary can be long, so it is capped rather
                      than trusted. *)
                   (fit_width (Terminal_text.single_line subject)
                      subject_width)
                   (schedule_status_color last_wake)
                   (fit_width (Terminal_text.single_line last_wake) 10)
                   Ansi.reset
                   (Ansi.dim ^ row.sch_recurrence_summary ^ Ansi.reset)
               in
               let content =
                 if is_selected then
                   Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
                 else
                   "  " ^ line
               in
               box_line buf cols content
             end
             else box_empty buf cols
           done;
           (match List.nth_opt snapshot.scs_rows state.schedule_cursor with
            | None ->
                box_empty buf cols;
                box_empty buf cols
            | Some selected ->
                let identity, delivery = schedule_delivery_summary selected in
                box_line_styled buf cols ~style:(Theme.recede ())
                  ("  " ^ identity);
                box_line_styled buf cols ~style:(Theme.recede ())
                  ("  " ^ delivery))
         end;
         (* The arm and the server's last refusal sit under the list, the
            same rows the goal detail carries them on. *)
         (match state.schedule_cancel_armed with
          | Some schedule_id ->
              box_line buf cols
                ((Theme.warn ())
                ^ Printf.sprintf
                    "  armed: cancel %s -- same key again to send"
                    (Terminal_text.single_line schedule_id)
                ^ Ansi.reset)
          | None -> ());
         (match state.schedule_cancel_error with
          | Some err ->
              box_line buf cols
                ((Theme.bad ()) ^ "  "
                ^ fit_width (Terminal_text.single_line err) (cols - 8)
                ^ Ansi.reset)
          | None -> ())
       end);

  box_bottom buf cols;

  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Schedules));

  finish_surface state ~surface_key:"schedules" ~rows:terminal_rows
      ~cols buf

(* What became of the wake. The pane could say a schedule fired and stop
   there: [LAST WAKE] reports the dispatch and [DELIVERY EVIDENCE] reports one
   word of verdict, and neither answers "did the Keeper do anything". The
   reaction ledger records four steps and the projection folds all four into
   that one word, so a wake delivered to a Keeper that never took a turn reads
   the same as one that did.

   Drawn only when the ledger said something. A schedule that has not fired
   has no trail, and four rows of "--" under it would be four rows saying the
   same nothing the empty [LAST WAKE] block already says. *)
let schedule_turn_rows
      ~(field : ?style:string -> string -> string -> string * string)
      (row : schedule_row) =
  let step_observed =
    [ row.sch_wake_seen
    ; row.sch_turn_started
    ; row.sch_turn_finished
    ; row.sch_queue_ack_seen
    ; row.sch_wake_cancelled
    ]
    |> List.exists Option.is_some
  in
  let metadata_observed =
    [ row.sch_reaction_keeper_name
    ; row.sch_reaction_stimulus_id
    ; row.sch_reaction_post_id
    ; row.sch_reaction_reason
    ; row.sch_stimulus_recorded_at_iso
    ; row.sch_turn_started_recorded_at_iso
    ; row.sch_turn_finished_recorded_at_iso
    ; row.sch_queue_ack_recorded_at_iso
    ; row.sch_wake_cancelled_recorded_at_iso
    ]
    |> List.exists Option.is_some
  in
  if not (step_observed || metadata_observed || Option.is_some row.sch_reaction_quarantined)
  then []
  else
    (* [None] is not [false]. A step the ledger never spoke about draws the
       same dash every unknown draws on this pane, in the dim every unknown
       takes -- claiming "no" for it would report a failure nobody observed. *)
    let step ?(bad_when_true = false) label observed recorded_at =
      match observed with
      | None -> field label "\xe2\x80\x94"
      | Some value ->
          let tone =
            if value = bad_when_true then Theme.bad () else Theme.ok ()
          in
          let at =
            match value, recorded_at with
            | true, Some timestamp ->
              " \xc2\xb7 " ^ Tui_decode.short_timestamp_for_terminal timestamp
            | _, _ -> ""
          in
          field ~style:tone label ((if value then "yes" else "no") ^ at)
    in
    let identity_rows =
      [ Option.map
          (fun keeper ->
             field "Keeper evidence"
               (Link.reference Keeper (Terminal_text.single_line keeper)))
          row.sch_reaction_keeper_name
      ; Option.map
          (fun stimulus -> field "Stimulus" stimulus)
          row.sch_reaction_stimulus_id
      ; Option.map
          (fun occurrence -> field "Occurrence" occurrence)
          row.sch_reaction_post_id
      ]
      |> List.filter_map Fun.id
    in
    [ Ansi.dim, ""
    ; Ansi.bold, "  TURN"
    ]
    @ identity_rows
    @ [ step "Wake seen" row.sch_wake_seen row.sch_stimulus_recorded_at_iso
      ; step "Turn started" row.sch_turn_started
          row.sch_turn_started_recorded_at_iso
      ; step "Turn finished" row.sch_turn_finished
          row.sch_turn_finished_recorded_at_iso
      ; step "Queue ack" row.sch_queue_ack_seen row.sch_queue_ack_recorded_at_iso
      ; step ~bad_when_true:true "Cancelled" row.sch_wake_cancelled
          row.sch_wake_cancelled_recorded_at_iso
      ; field "Reaction kind"
          (Option.value ~default:"\xe2\x80\x94" row.sch_reaction_kind)
      ; field
          ~style:(if Option.is_some row.sch_reaction_reason then Theme.warn () else Ansi.dim)
          "Reason" (Option.value ~default:"\xe2\x80\x94" row.sch_reaction_reason)
    ; field
        ~style:
          (match row.sch_reaction_quarantined with
           | Some count when count > 0 -> Theme.warn ()
           | Some _ | None -> Ansi.dim)
        "Quarantined"
        (match row.sch_reaction_quarantined with
         | None -> "\xe2\x80\x94"
         | Some count -> string_of_int count)
      ]

(* The wake block. The row carries the newest attempt and the exact lookup
   carries the retained list, so this pane reports whichever it has and says
   which: one attempt out of up to 32 read as a schedule's whole past for as
   long as the list was the only thing not projected. The three unloaded
   readings stay three sentences. *)
let schedule_wake_lines
      ~(field : ?style:string -> string -> string -> string * string)
      ~(timestamp : string option -> string) ~(row : schedule_row)
      ~(history : schedule_wake_history option)
      ~(history_error : (string * string) option) =
  let last_wake_fields =
    [ field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_last_wake_status)
        "Status" (Option.value ~default:"\xe2\x80\x94" row.sch_last_wake_status)
    ; field "Started" (timestamp row.sch_last_wake_started_at_iso)
    ; field
        ~style:(if Option.is_some row.sch_last_wake_error then Theme.bad () else Ansi.dim)
        "Error" (Option.value ~default:"\xe2\x80\x94" row.sch_last_wake_error)
    ]
  in
  match
    Render_schedule.classify_wake_reading
      ~history_error:(Option.map snd history_error)
      ~history:
        (Option.map
           (fun h -> (List.length h.swh_wakes, h.swh_retention_per_schedule))
           history)
  with
  | Render_schedule.Wake_history_failed err ->
      (Ansi.bold, "  LAST WAKE")
      :: last_wake_fields
      @ [ (Theme.bad (), "  wake history unavailable: " ^ Terminal_text.single_line err) ]
  | Render_schedule.Wake_last_only ->
      (Ansi.bold, "  LAST WAKE")
      :: last_wake_fields
      @ [ (Ansi.dim, "  (loading the rest of this schedule's wakes\xe2\x80\xa6)") ]
  | Render_schedule.Wake_never ->
      [ Ansi.bold, "  WAKES"; (Ansi.dim, "  (this schedule has not woken)") ]
  | Render_schedule.Wake_history { count; retention } ->
      let wakes =
        match history with Some h -> h.swh_wakes | None -> []
      in
        (Ansi.bold
        , Printf.sprintf "  WAKES (%d retained, ceiling %d per schedule)"
            count retention )
        :: List.concat_map
             (fun (wake : schedule_wake) ->
                let started = timestamp wake.swk_started_at_iso in
                let finished = timestamp wake.swk_finished_at_iso in
                let head =
                  ( schedule_status_color wake.swk_status
                  , Printf.sprintf "  %-12s %s \xe2\x86\x92 %s"
                      (Terminal_text.single_line wake.swk_status) started finished )
                in
                match wake.swk_error with
                | None -> [ head ]
                | Some err ->
                    [ head
                    ; ( Theme.bad ()
                      , "               " ^ Terminal_text.single_line err )
                    ])
             wakes

let schedule_detail_lines ~width (row : schedule_row)
      ~(wake_history : schedule_wake_history option)
      ~(wake_history_error : (string * string) option) =
  let field ?(style = Ansi.reset) label value =
    ( style
    , Printf.sprintf "  %-14s %s" label (Terminal_text.single_line value) )
  in
  let optional value = Option.value ~default:"\xe2\x80\x94" value in
  let timestamp value =
    match value with
    | None -> "\xe2\x80\x94"
    | Some iso -> Tui_decode.short_timestamp_for_terminal iso
  in
  let queue =
    match row.sch_queue_projection_status, row.sch_queue_pending_count with
    | None, None -> "\xe2\x80\x94"
    | Some status, None -> status
    | None, Some count -> Printf.sprintf "pending=%d" count
    | Some status, Some count -> Printf.sprintf "%s  pending=%d" status count
  in
  let reaction =
    match row.sch_reaction_projection_status, row.sch_reaction_latest_at_iso with
    | None, None -> "\xe2\x80\x94"
    | Some status, None -> status
    | None, Some at -> Tui_decode.short_timestamp_for_terminal at
    | Some status, Some at ->
        Printf.sprintf "%s  %s" status
          (Tui_decode.short_timestamp_for_terminal at)
  in
  let summary =
    Option.value ~default:"(no payload summary)" row.sch_payload_summary
  in
  let keeper_wake =
    match row.sch_payload_kind with
    | Some ("keeper_wake" | "masc.keeper_wake") -> true
    | Some _ | None -> false
  in
  let target_link =
    match keeper_wake, row.sch_payload_target with
    | true, Some keeper ->
        [ field "Keeper link"
            (Link.reference Keeper (Terminal_text.single_line keeper))
        ]
    | _, _ -> []
  in
  [ Ansi.bold, "  SCHEDULE"
  ; field "Link"
      (Link.reference Schedule
         (Terminal_text.single_line row.sch_schedule_id))
  ; field "Schedule" row.sch_schedule_id
  ; field "Instance" row.sch_schedule_instance_id
  ; field ~style:(schedule_status_color row.sch_status) "Status" row.sch_status
  ; field "Source" row.sch_source
  ; field "Requested by" row.sch_requested_by
  ; field "Scheduled by" row.sch_scheduled_by
  ; field "Requested"
      (Tui_decode.short_timestamp_for_terminal row.sch_requested_at_iso)
  ; field "Due" (timestamp row.sch_due_at_iso)
  ; field "Next due" (timestamp row.sch_next_due_at_iso)
  ; field "Expires" (timestamp row.sch_expires_at_iso)
  ; field "Recurrence" row.sch_recurrence_summary
  ; Ansi.dim, ""
  ; Ansi.bold, "  PAYLOAD"
  ; field "Kind" (optional row.sch_payload_kind)
  ; field "Support" row.sch_payload_support
  ; field "Dispatch tool" (optional row.sch_payload_dispatch_tool)
  ; field "Target" (optional row.sch_payload_target)
  ]
  @ target_link
  @ [ field "Digest" row.sch_payload_digest
  ; Ansi.bold, "  Summary"
  ]
  @ (Message_layout.wrap_body ~markdown:document_markdown
       ~max_cells:(max 1 (width - 4)) ~sanitize:Terminal_text.single_line summary
    |> List.map (fun line -> Ansi.reset, "    " ^ line))
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  PAYLOAD JSON"
    ]
  @ (document_markdown ~width:(max 1 (width - 4))
       ("```json\n" ^ Yojson.Safe.pretty_to_string row.sch_payload ^ "\n```")
    |> List.map (fun line -> Ansi.reset, "    " ^ line))
  @ [ (Ansi.dim, "") ]
  @ schedule_wake_lines ~field ~timestamp ~row ~history:wake_history
      ~history_error:wake_history_error
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  DELIVERY EVIDENCE"
    ; field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_queue_projection_status)
        "Queue" queue
    ; field
        ~style:
          (Option.fold ~none:Ansi.dim ~some:schedule_status_color
             row.sch_reaction_projection_status)
        "Reaction" reaction
    ]
  @ schedule_turn_rows ~field row
  @ (if keeper_wake then
       [ Ansi.dim, ""
       ; Ansi.bold, "  WORK RESULT"
       ; field "Attribution"
           "the turn this wake opened, bounded by its start and finish rows"
       ; field "Inspect"
           "Keeper Calls or Activity between the two recorded times"
       ]
     else [])

let schedule_detail_pane (state : state) ~rows ~cols (row : schedule_row) buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s[%s]%s"
       (screen_title " MASC Schedules \xe2\x96\xb8 details")
       (schedule_status_color row.sch_status)
       (Terminal_text.single_line row.sch_status) Ansi.reset);
  box_divider buf cols;
  let lines =
    schedule_detail_lines
      ~width:(max 1 (framed_inner_width cols))
      row
      ~wake_history:state.schedule_wake_history
      ~wake_history_error:state.schedule_wake_history_error
  in
  let content_height = max 1 (rows - 6) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.schedule_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The schedule list stays beside the schedule. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_schedule_detail (state : state) (row : schedule_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, _max_scroll =
    if cols < keeper_split_threshold_cols then
      schedule_detail_pane state ~rows ~cols row buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.schedules with
        | None -> []
        | Some snapshot ->
          List.map (fun (row : schedule_row) -> row.sch_schedule_id)
            snapshot.scs_rows
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Schedules"
        ~focused:false ~labels ~selected:state.schedule_cursor;
      let answer =
        schedule_detail_pane state ~rows ~cols:(cols - left_cols) row
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Schedules));
  finish_surface state ~clamped:(Schedule_detail_scroll scroll)
    ~surface_key:"schedule-detail" ~rows:terminal_rows ~cols buf

let render_schedules (state : state) =
  match state.schedule_detail_id, state.schedules with
  | Some schedule_id, Some snapshot ->
      (match
         List.find_opt
           (fun row -> String.equal row.sch_schedule_id schedule_id)
           snapshot.scs_rows
       with
       | Some row -> render_schedule_detail state row
       | None -> render_schedule_list state)
  | Some _, None | None, _ -> render_schedule_list state

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

(* [None] is a roster that was not read, not a health the roster could not
   name: the word says so, and it is the word the header's tally uses for
   the same keepers, so a column of ten of them and "10 unread" above it
   are one fact drawn twice rather than two. *)
let keeper_health_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> Tui_decode.keeper_health_to_string value

(* The table's variant: the normal state is silent. On a healthy fleet every
   row said "healthy" while the heading counted "11 healthy" and the summary
   said "fleet ok" — the same fact four times, and the glyph beside the word
   already carries the health colour. Only a deviation earns a word, so the
   one stale row is the only row with text in the column. The single-keeper
   chat header keeps {!keeper_health_word}: alone, the word is identity, not
   repetition. *)
let keeper_health_deviation_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> (
      match Tui_decode.keeper_health_reading value with
      | Tui_decode.Health_running -> ""
      | Tui_decode.Health_idle | Tui_decode.Health_offline
      | Tui_decode.Health_stale | Tui_decode.Health_degraded
      | Tui_decode.Health_zombie ->
          Tui_decode.keeper_health_to_string value)

(* [runtime_id] is the producer-owned runtime identity. Keep it whole instead
   of deriving a model by splitting its spelling: the phase is a separate
   typed reading, while the sanitized id is the exact identity the gate named. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> "\xe2\x80\x94"
  | Some row ->
      Printf.sprintf "%s %s"
        (Tui_decode.keeper_phase_to_string row.kr_phase)
        (Terminal_text.single_line row.kr_runtime_id)

(* Runtime ids are opaque identifiers, so a fixed-width surface keeps both
   ends instead of sacrificing the distinguishing tail to a shared prefix.
   Returning the unpadded id when it already fits lets a chat header spend the
   remaining cells on context instead of blank padding. *)
let fit_runtime_id width runtime_id =
  if Message_layout.display_width runtime_id <= width then runtime_id
  else Message_layout.fit_middle width runtime_id

let keeper_runtime_cell ~width (runtime : keeper_runtime option) =
  match runtime with
  | None -> fit_width "\xe2\x80\x94" width
  | Some row ->
      (* Running is the normal lifecycle and stays silent — eleven rows all
         reading "running" said nothing any row could act on; the cells go to
         the runtime identity instead. Every other phase keeps its word. *)
      (* A paused keeper says so instead of saying its phase. [kr_paused] is
         a separate reading from [kr_phase] and the two disagree in practice:
         on the live gate, two of sixteen keepers report phase offline with
         paused true, and a third reports offline with paused false. The word
         "offline" drew all three the same, and the difference is the one an
         operator acts on -- a person stopped that one, so nothing is wrong
         with it. The phase this replaces is still on the chat header, which
         draws [kr_phase] unconditionally. *)
      let phase =
        if row.kr_paused then "paused "
        else if Tui_decode.keeper_phase_is_running row.kr_phase then ""
        else Tui_decode.keeper_phase_to_string row.kr_phase ^ " "
      in
      let runtime_id = Terminal_text.single_line row.kr_runtime_id in
      let phase_width = Message_layout.display_width phase in
      if phase_width >= width then fit_width (keeper_runtime_label runtime) width
      else
        fit_width
          (phase ^ fit_runtime_id (width - phase_width) runtime_id)
          width

let keeper_message_identity ~max_cells state keeper_name =
  let fit_identity text =
    if Message_layout.display_width text <= max_cells then text
    else fit_width text max_cells
  in
  match
    List.find_opt
      (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
      state.keepers
  with
  | None ->
      fit_identity
        (Ansi.dim ^ "\xc3\x97 unavailable \xc2\xb7 \xe2\x80\x94" ^ Ansi.reset)
  | Some keeper ->
      let reading = keeper_reading state keeper in
      let health = Keeper_control.health reading in
      let runtime =
        match reading.Keeper_control.liveness with
        | Keeper_control.Present row -> Some row
        | Keeper_control.Absent | Keeper_control.Unobserved -> None
      in
      let status_color =
        keeper_action_color (Keeper_control.next_action reading)
      in
      (* Two stances that decide what this Keeper does with a tool call, on
         the row an operator reads before typing to it. Show defaults too:
         this is operational state, and an absent label made AUTO look like
         unknown while a visible YOLO label looked like the only real mode. *)
      let stance =
        let yolo = List.mem keeper.k_name state.keeper_yolo_names in
        let workspace_gate_mode =
          Option.map
            (fun modes -> modes.Tui_decode.glm_workspace)
            state.gate_modes
        in
        let chat_mode, gate_mode =
          keeper_chat_mode_labels ~yolo
            ~keeper_gate_mode:(List.assoc_opt keeper.k_name state.keeper_gate_modes)
            ~workspace_gate_mode
        in
        Printf.sprintf " %s%s%s %s\xc2\xb7 gate:%s%s"
          (if yolo then (Theme.bad ()) else (Theme.info ()))
          chat_mode Ansi.reset Ansi.dim
          (Terminal_text.single_line gate_mode) Ansi.reset
      in
      let status =
        String.concat ""
          [ status_color
          ; keeper_state_glyph ~paused:reading.Keeper_control.paused ~health
          ; " "
          ; keeper_health_word health
          ; Ansi.reset
          ; stance
          ]
      in
      (match runtime with
       | None ->
           fit_identity
             (status ^ Ansi.dim ^ " \xc2\xb7 \xe2\x80\x94" ^ Ansi.reset)
       | Some row ->
           let runtime_id = Terminal_text.single_line row.kr_runtime_id in
           let prefix =
             Printf.sprintf "%s%s \xc2\xb7 %s " status Ansi.dim
               (Tui_decode.keeper_phase_to_string row.kr_phase)
           in
           let prefix_width = Message_layout.display_width prefix in
           if prefix_width >= max_cells then
             fit_width (prefix ^ runtime_id ^ Ansi.reset) max_cells
           else
             prefix
             ^ fit_runtime_id (max_cells - prefix_width) runtime_id
             ^ Ansi.reset)

(* Two dispositions an operator needs before stopping anything: whether the
   keeper comes back by itself, and whether it takes turns without being
   asked. Both are on the roster row. *)
let keeper_flag_cell (runtime : keeper_runtime option) =
  match runtime with
  | None -> Ansi.dim ^ "- - -" ^ Ansi.reset
  | Some row ->
      let flag enabled letter =
        if enabled then (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ letter ^ Ansi.reset
        else Ansi.dim ^ "-" ^ Ansi.reset
      in
      (* The sandbox is a name rather than a yes/no, so it gets a letter of its
         own instead of the on/off colour the other two use: "D" reads as the
         profile it stands for, and anything this roster has not been taught
         shows its own first letter rather than being folded into "L". A word
         the reader does not recognise is better than a wrong one. *)
      let sandbox =
        match row.kr_sandbox_profile with
        | "docker" -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "D" ^ Ansi.reset
        | "microvm" -> (Theme.category Theme.Slot_4) ^ "M" ^ Ansi.reset
        | "local" -> Ansi.dim ^ "L" ^ Ansi.reset
        | other when String.length other > 0 ->
          (Theme.warn ()) ^ String.uppercase_ascii (String.sub other 0 1) ^ Ansi.reset
        | _ -> Ansi.dim ^ "?" ^ Ansi.reset
      in
      flag row.kr_autoboot_enabled "A"
      ^ " "
      ^ flag row.kr_proactive_enabled "P"
      ^ " "
      ^ sandbox

(* Column header labels line up with the cell budgets
   [Render_schedule.allocate_keeper_columns] hands out, so the arithmetic lives
   in one tested place instead of once here and once in the row. *)
let keeper_column_header (columns : Render_schedule.keeper_columns) =
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Printf.sprintf "%-*s" Render_schedule.keeper_status_width "HEALTH"
    ; " "
    ; Printf.sprintf "%-*s" columns.kcol_name "KEEPER"
    ; (if columns.kcol_show_flags then
         " " ^ Printf.sprintf "%-*s" Render_schedule.keeper_flags_width "A P S"
       else "")
    ; Printf.sprintf " %*s" Render_schedule.keeper_last_turn_width "LAST"
    ; (if columns.kcol_show_runtime then
         " " ^ fit_width "LIFECYCLE / RUNTIME" columns.kcol_runtime
       else "")
    ; " "
    ; "TASK"
    ]

(* Each cell is fitted as plain text and styled afterwards, so a long keeper
   name cannot push the columns to its right out of the frame and the style
   bytes never count toward the width. *)
let keeper_row_content ~(columns : Render_schedule.keeper_columns)
    ~now ~frame ~yolo ~paused ~health ~turn ~next_action ~keeper ~runtime =
  let status_color = keeper_action_color next_action in
  (* A running turn takes the cell whole -- both the mark and the word.
     Splitting them is what this column used to do, and it produced rows
     that argued with themselves: the mark came from the heartbeat and the
     word from the turn, so a keeper answering on a stale heartbeat drew
     "? answering". One of those was wrong and the reader could not tell
     which.

     The word is the elapsed time rather than "answering". The mark already
     says it is answering, and it says so by moving; spending eight columns
     to repeat that leaves no room for the fact the mark cannot carry, which
     is how long. Eight seconds and forty minutes are different situations
     and they used to be the same row. It also ends the truncation: this
     column is cut for "healthy", and "answering" never fit in it.

     Idle and unavailable rows keep the health word -- unavailable is the
     owner lookup failing, which the health column describes better than a
     blank would. *)
  (* A turn record that outlives the process it belongs to. The summary above
     this table read "2 offline / not running" while
     one listed keeper's own row drew a turning mark and a climbing clock: its turn
     had started and never been closed, and the process behind it had gone.
     The row that most needed reading looked like the healthiest kind.

     The elapsed stays -- a turn open two minutes is the fact -- but the mark
     stops. Motion here means work is progressing, and for a keeper the health
     reading calls offline or zombie, nothing is. *)
  let turn_is_being_worked =
    match Option.map Tui_decode.keeper_health_reading health with
    | Some (Tui_decode.Health_offline | Tui_decode.Health_zombie) -> false
    | Some
        ( Tui_decode.Health_running | Tui_decode.Health_idle
        | Tui_decode.Health_stale | Tui_decode.Health_degraded )
    | None ->
      true
  in
  let glyph, status_word, status_color =
    match (turn : Tui_decode.keeper_turn_state option) with
    | Some (Tui_decode.Keeper_turn_running { started_at_unix; _ }) ->
      ( Masc_tui_answering.running_glyph
          ~frame:(if turn_is_being_worked then frame else -1)
      , Masc_tui_answering.elapsed_text ~now started_at_unix
      , if turn_is_being_worked then (Theme.info ()) else (Theme.bad ()) )
    | Some Tui_decode.Keeper_turn_idle
    | Some (Tui_decode.Keeper_turn_unavailable _)
    | None ->
      ( keeper_state_glyph ~paused ~health
      , keeper_health_deviation_word health
      , status_color )
  in
  (* Selection is the full-row band the caller draws (box_line_selected over
     a strip_sgr'd copy of this row), so the row itself carries no marker.
     The caret's three gutter cells stay as spaces so columns do not shift
     between the selected row and its neighbours. *)
  (* Names, not prose: the Keepers table is where two keepers sharing a prefix
     have to be told apart, and the tail is what does it. See
     [Message_layout.fit_middle]. *)
  let name =
    Message_layout.fit_middle columns.kcol_name
      (Terminal_text.single_line keeper.k_name)
  in
  let task =
    fit_width
      (Terminal_text.single_line_or ~default:"\xe2\x80\x93"
         keeper.k_current_task_id)
      columns.kcol_task
  in
  String.concat ""
    [ "   "
    ; status_color ^ glyph ^ " "
      ^ fit_width status_word (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
    ; " "
    ; (* A keeper whose gate runs every call unasked wears its name in
         red: the stance has no column of its own, and the name is what
         the eye finds first. On the selected row the band folds this red
         with every other cell colour. *)
      (if yolo then (Theme.bad ()) ^ name ^ Ansi.reset else name)
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; (* The lifetime turn count said nothing an operator acts on; how long
         since this keeper last turned does. A running row already carries
         its elapsed time in the HEALTH cell, so this column answers the
         idle rows. A keeper that never turned, or one whose last turn reads
         from the future, draws the dash every unknown draws. The count
         itself still lives on the detail pane. *)
      (let last_turn_age =
         match Masc_domain.parse_iso8601_opt keeper.k_last_turn_ts with
         | None -> "\xe2\x80\x94"
         | Some since -> (
             match Message_layout.age_text ~now ~since with
             | Some text -> text
             | None -> "\xe2\x80\x94")
       in
       Printf.sprintf " %s%*s%s" Ansi.dim
         Render_schedule.keeper_last_turn_width last_turn_age Ansi.reset)
    ; (if columns.kcol_show_runtime then
         " " ^ (Theme.recede ())
         ^ keeper_runtime_cell ~width:columns.kcol_runtime runtime
         ^ Ansi.reset
       else "")
    ; " "
    ; Ansi.dim ^ task ^ Ansi.reset
    ]

(* The footer names the action behind each key for the keeper under the cursor,
   because which action the toggle sends depends on that keeper's state. A key
   with nothing behind it is dimmed rather than dropped, so the row of keys
   does not shift as the cursor travels. *)
let keeper_action_hints ?(offers_chat = true) ?(offers_back = true) state reading =
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
      Printf.sprintf "%s%s%s %s" key_color (Keeper_control.action_key action)
        Ansi.reset label
    else
      Printf.sprintf "%s%s %s%s" Ansi.dim (Keeper_control.action_key action)
        label Ansi.reset
  in
  let toggle =
    match Option.bind reading Keeper_control.primary with
    | Some action -> hint action (Keeper_control.action_label action)
    | None -> Printf.sprintf "%sp pause%s" Ansi.dim Ansi.reset
  in
  let gate_hint =
    match reading with
    | Some reading
      when List.mem reading.Keeper_control.name state.keeper_yolo_names ->
        (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "g" ^ Ansi.reset ^ " auto"
    | Some _ | None -> (Theme.bad ()) ^ "g" ^ Ansi.reset ^ " yolo"
  in
  match (state.keeper_action_inflight, state.keeper_action_pending) with
  | Some (keeper_name, action), _ ->
      Printf.sprintf "  %s%s %s\xe2\x80\xa6%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
        (Keeper_control.action_gerund action)
        (Terminal_text.single_line keeper_name)
        Ansi.reset
  | None, Some pending ->
      Printf.sprintf "  %s%spress %s again to %s %s%s" Ansi.bold (Theme.warn ())
        (Keeper_control.action_key pending.Keeper_control.pending_action)
        (Keeper_control.action_label pending.Keeper_control.pending_action)
        (Terminal_text.single_line pending.Keeper_control.pending_keeper)
        Ansi.reset
  | None, None ->
      "  "
      ^ String.concat
          (Ansi.dim ^ " \xc2\xb7 " ^ Ansi.reset)
          [ Ansi.dim ^ "j/k move" ^ Ansi.reset
          ; toggle
          ; hint Keeper_control.Wakeup "wake"
          (* RFC tui-server-lifecycle: with no server up, "s" starts one
             rather than shutting a keeper down, so the hint follows suit. *)
          ; (match state.connection_status with
             | Disconnected -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "s" ^ Ansi.reset ^ " start server"
             | Connecting | Booting | Reconnecting | Degraded | Connected ->
                 hint Keeper_control.Shutdown "shutdown")
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "e" ^ Ansi.reset ^ " settings"
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "a" ^ Ansi.reset ^ " new"
          ; (if state.view = Keepers Keeper_detail then
               if state.detail_tab = Detail_sandbox then
                 (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "o" ^ Ansi.reset ^ " container logs"
               else (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "o" ^ Ansi.reset ^ " logs"
             else (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "l" ^ Ansi.reset ^ " logs")
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "t" ^ Ansi.reset ^ " calls"
          ; gate_hint
          ; (Masc_tui_theme.tone Masc_tui_theme.Accent)
            ^ (if state.view = Keepers Keeper_detail then "U" else "u")
            ^ Ansi.reset ^ " runtime"
            (* Dimmed rather than dropped, the same way an unavailable
               lifecycle key is: chat lives in detail, and a key that vanishes
               between surfaces reads as a key that does not exist. *)
          ; (if offers_chat then (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "c" ^ Ansi.reset ^ " chat"
             else Ansi.dim ^ "c chat" ^ Ansi.reset)
          ; (if offers_back then Ansi.dim ^ "left/esc back" ^ Ansi.reset
             else (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "right/enter" ^ Ansi.reset ^ " detail")
          ; Ansi.dim ^ "r refresh" ^ Ansi.reset
          ; Ansi.dim ^ "q quit" ^ Ansi.reset
          ]

(* Counted from the same readings the rows are drawn from, so the heading
   cannot disagree with the list under it. *)
(* Tally words come from [Keeper_control.health_label], so this paints the
   health vocabulary. [unread] is the roster not answering, which is dim rather
   than any health colour. *)
let keeper_roster_status_color = function
  | "healthy" -> (Theme.ok ())
  | "stale" | "degraded" -> (Theme.warn ())
  | "zombie" -> (Theme.bad ())
  | "offline" | "idle" -> (Theme.muted ())
  | _ -> Ansi.dim

(* The tally is [Keeper_control.status_tally], so every word here is a word the
   status column shows for the same keeper. This function only paints it. *)
let keeper_roster_summary readings =
  Keeper_control.health_tally readings
  |> List.map (fun (label, count) ->
         Printf.sprintf "%s%d %s%s" (keeper_roster_status_color label) count
           label Ansi.reset)

(* The two subtractions over the fleet's name lists. They answer different
   questions and only one of them is about being stopped: a keeper the fleet
   wanted and never started is bootable minus running, while a keeper whose
   fiber is alive but whose durable demand is not admissible is running minus
   executable. Reporting the second as "not running" sent an operator to boot
   ten keepers that were already up. *)
let keeper_fleet_gap_lines (fleet : fleet_safety) =
  let subtract from_names remove_names =
    List.filter (fun name -> not (List.mem name remove_names)) from_names
  in
  let never_started = subtract fleet.fs_bootable_names fleet.fs_running_names in
  let running_without_turn =
    subtract fleet.fs_running_names fleet.fs_executable_names
  in
  List.filter_map
    (fun (names, label, color) ->
       match names with
       | [] -> None
       | _ -> Some (color, label, String.concat ", " names))
    [ (never_started, "not running", (Theme.bad ()))
    ; (running_without_turn, "running, cannot take a turn", (Theme.warn ()))
    ]


let keeper_operations_outcome_text = function
  | None -> "—"
  | Some (outcome : Tui_decode.keeper_lane_last_outcome) ->
      let state = Terminal_text.single_line outcome.klo_runtime_state in
      (match outcome.klo_selected_model with
       | Some model when String.trim model <> "" ->
           state ^ " · " ^ Terminal_text.single_line model
       | Some _ | None -> state)

(* The Keeper composite used to live only in Lanes. Keep the roster compact,
   then give the selected Keeper one exact operational line: no lifecycle fact
   is dropped, and Lanes no longer has to repeat the whole Keeper table. *)
let keeper_operations_preview (state : state) =
  match selected_keeper state with
  | None -> Ansi.dim ^ "  Keeper operations: no Keeper selected" ^ Ansi.reset
  | Some keeper ->
      (match state.lanes with
       | Some snapshot ->
           (match
              List.find_opt
                (fun (lane : Tui_decode.keeper_lane) ->
                  String.equal lane.kl_keeper keeper.k_name)
                snapshot.kls_lanes
            with
            | Some lane ->
                String.concat ""
                  [ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                  ; "  OPERATIONS"
                  ; Ansi.reset
                  ; "  lifecycle "
                  ; Terminal_text.single_line
                      (Tui_decode.keeper_lane_phase_to_string lane.kl_phase)
                  ; " · turn "
                  ; Terminal_text.single_line
                      (Tui_decode.keeper_lane_turn_phase_to_string
                         lane.kl_turn_phase)
                  ; " · idle "
                  ; keeper_lane_idle_text lane.kl_idle_seconds
                  ; " · last "
                  ; keeper_operations_outcome_text lane.kl_last_outcome
                  ; " · "
                  ; Terminal_text.single_line_or ~default:"no diagnosis"
                      lane.kl_diagnosis
                  ]
            | None ->
                Ansi.dim ^ "  OPERATIONS  no composite row for "
                ^ Terminal_text.single_line keeper.k_name ^ Ansi.reset)
       | None ->
           (match state.lanes_error with
            | Some detail ->
                (Theme.warn ()) ^ "  OPERATIONS unavailable · "
                ^ Terminal_text.single_line detail ^ Ansi.reset
            | None -> Ansi.dim ^ "  OPERATIONS loading…" ^ Ansi.reset))

let render_keeper_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let inner = max 1 (framed_inner_width cols) in
  let readings = List.map (keeper_reading state) state.keepers in
  let selected_reading =
    Option.map (keeper_reading state) (selected_keeper state)
  in

  Buffer.add_char buf '\n';

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let heading =
    screen_title
      (Printf.sprintf " MASC Keepers (%d)" (List.length state.keepers))
    ^ (match state.search with
       | Some query ->
           Printf.sprintf "  %s/%s%s\xe2\x96\x8c%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
             (Terminal_text.single_line query) Ansi.reset Ansi.reset
       | None ->
           if state.search_last = "" then ""
           else
             Printf.sprintf "  %s/%s (n/N)%s" Ansi.dim
               (Terminal_text.single_line state.search_last)
               Ansi.reset)
    ^ (match keeper_roster_summary readings with
       | [] -> ""
       | parts ->
           Ansi.dim ^ "   " ^ Ansi.reset
           ^ String.concat (Ansi.dim ^ " \xc2\xb7 " ^ Ansi.reset) parts)
  in
  (* Style bytes are zero-width to [display_width], so the gap is measured on
     the styled string rather than on a plain copy that could drift from it. *)
  let gap =
    max 1
      (inner - Message_layout.display_width heading - String.length timestamp)
  in
  box_line buf cols
    (heading ^ String.make gap ' ' ^ Ansi.dim ^ timestamp ^ Ansi.reset);

  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" (Theme.recede ()) (draw_hline (cols - 2)) Ansi.reset);

  (match (state.fleet_safety, state.fleet_safety_error) with
   | _, Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  fleet: " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None, None -> ()
   | Some fleet, None ->
       let tone =
         if fleet.fs_operator_action_required then (Theme.bad ())
         else if String.equal fleet.fs_status "ok" then (Theme.ok ())
         else (Theme.warn ())
       in
       let blocker =
         match fleet.fs_blocker with None -> "" | Some b -> "   blocker: " ^ b
       in
       box_line buf cols
         (Printf.sprintf
            "%s  fleet %s%s   running %d/%d   turn capacity %d/%d%s%s%s" tone
            fleet.fs_status Ansi.reset fleet.fs_running_count
            fleet.fs_bootable_count
            (fleet.fs_target_reaction_capacity
            - fleet.fs_reaction_capacity_shortfall)
            fleet.fs_target_reaction_capacity Ansi.dim blocker Ansi.reset);
       let counts =
         [ ("paused", fleet.fs_paused_count)
         ; ("failing", fleet.fs_failing_count)
         ; ("recovering", fleet.fs_recovering_count)
         ; ( "task owner without fiber"
           , fleet.fs_active_task_owner_without_fiber_count )
         ; ("awaiting verdict", fleet.fs_completion_authority_pending_count)
         ]
         |> List.filter (fun (_, n) -> n > 0)
         |> List.map (fun (label, n) -> Printf.sprintf "%s %d" label n)
       in
       if counts <> [] then
         box_line buf cols
           (Ansi.dim ^ "  " ^ String.concat "   " counts ^ Ansi.reset);
       List.iter
         (fun (color, label, names) ->
            box_line buf cols
              (Printf.sprintf "%s  %s: %s%s" color label
                 (Terminal_text.single_line names) Ansi.reset))
         (keeper_fleet_gap_lines fleet));

  (* The roster's own failure. The rows below still come from disk so they stay
     on screen; this says the live half of every one of them is missing, which
     is why the lifecycle keys stop offering anything. *)
  (match state.keeper_roster_error with
   | Some err ->
       box_line buf cols
         ((Theme.warn ()) ^ "  " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_roster with
   | Keeper_control.Roster_partial { observed; total } ->
       box_line buf cols
         (Printf.sprintf
            "%s  live status covers %d of %d keepers; the rest read as unknown%s"
            (Theme.warn ()) (List.length observed) total Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  let columns = Render_schedule.allocate_keeper_columns ~inner_width:inner in
  box_line_styled buf cols ~style:(Theme.recede ())
    "  Health = heartbeat/readiness   Lifecycle = keeper process   Last = time since last turn";
  box_line_styled buf cols ~style:(Theme.recede ())
    "  A = autoboot   P = autonomous turns   S = sandbox (D docker \xc2\xb7 M microvm \xc2\xb7 L local)";
  box_line_styled buf cols ~style:(Theme.recede ()) (keeper_column_header columns);
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" (Theme.recede ()) (draw_hline (cols - 2)) Ansi.reset);

  let keepers_error = Terminal_text.optional_single_line state.keepers_error in
  (match keepers_error with
   | Some err -> box_line buf cols ((Theme.bad ()) ^ "  " ^ err ^ Ansi.reset)
   | None -> ());

  (* Counted rather than recomputed: the chrome above varies with the fleet
     reading, the roster's health and the metadata error, so a second
     arithmetic copy of its height would drift from what was just emitted and
     scroll the frame. *)
  let chrome_rows = count_frame_lines buf in
  let footer_rows = 3 in
  let keeper_rows = max 0 (rows - chrome_rows - footer_rows) in
  let keeper_count = List.length state.keepers in
  let scroll_offset =
    if keeper_rows > 0 && state.keeper_cursor >= keeper_rows then
      state.keeper_cursor - keeper_rows + 1
    else 0
  in
  if keeper_count = 0 then begin
    if keeper_rows > 0 && Option.is_none keepers_error then
      box_line buf cols
        (Ansi.dim ^ "   no keeper metadata under .masc/keepers/" ^ Ansi.reset);
    let filled = if Option.is_none keepers_error then 1 else 0 in
    for _ = 1 to max 0 (keeper_rows - filled) do
      box_empty buf cols
    done
  end
  else
    for index = 0 to keeper_rows - 1 do
      let position = index + scroll_offset in
      match
        (List.nth_opt state.keepers position, List.nth_opt readings position)
      with
      | Some keeper, Some reading ->
          let runtime =
            match reading.Keeper_control.liveness with
            | Keeper_control.Present row -> Some row
            | Keeper_control.Absent | Keeper_control.Unobserved -> None
          in
          let turn =
            List.find_map
              (fun (row : Tui_decode.keeper_turn_row) ->
                if String.equal row.ktr_keeper_name keeper.k_name then
                  Some row.ktr_state
                else None)
              state.keeper_turns
          in
          let row =
            keeper_row_content ~columns
              ~now:(Unix.gettimeofday ())
              ~frame:state.activity_frame
              ~yolo:(List.mem keeper.k_name state.keeper_yolo_names)
              ~paused:reading.Keeper_control.paused
              ~health:(Keeper_control.health reading)
              ~turn
              ~next_action:(Keeper_control.next_action reading)
              ~keeper ~runtime
          in
          if position = state.keeper_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
          else box_line buf cols row
      | Some _, None | None, Some _ | None, None -> box_empty buf cols
    done;

  box_line buf cols (keeper_operations_preview state);
  Buffer.add_string buf
    (Printf.sprintf "%s%s%s%s%s\n" (Theme.recede ()) Ansi.box_bl (draw_hline (cols - 2))
       Ansi.box_br Ansi.reset);
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(keeper_action_hints ~offers_back:false state selected_reading));

  finish_surface state ~surface_key:"keeper-list" ~rows:terminal_rows
      ~cols buf

(* Through the semantic names, not the colour names. A raw [Ansi.red] is the
   terminal's red whatever the page behind it is; [Theme.bad ()] is the same
   reading lifted until it clears the readable floor on the scheme in force.
   These four are states, so they are what the rule is about. *)
let standalone_lane_status_style = function
  | Tui_decode.Standalone_running -> (Theme.warn ())
  | Tui_decode.Standalone_idle -> (Theme.ok ())
  | Tui_decode.Standalone_degraded
  | Tui_decode.Standalone_unavailable -> (Theme.bad ())
  | Tui_decode.Standalone_no_retained_observation -> (Theme.muted ())

let standalone_lane_row ~now ~frame width (lane : Tui_decode.standalone_lane) =
  let status = Tui_decode.standalone_lane_status_to_string lane.sl_status in
  (* A lane that is running says so twice and neither says for how long: the
     word "running", and a count of how many. The server has sent the start
     of the newest run all along and the decoder threw it away under an
     underscore, so the one fact an operator weighs -- is this a lane doing
     work or a lane stuck -- was decoded and dropped one layer from the
     screen.

     Same treatment as a keeper mid-turn: the mark moves while it runs, and
     the word carries the elapsed. A lane with no start recorded keeps the
     still mark rather than inventing an age. *)
  let mark, status =
    match lane.sl_status, lane.sl_last_started_at with
    | Tui_decode.Standalone_running, Some started_at ->
      ( Masc_tui_answering.running_glyph ~frame
      , status ^ " " ^ Masc_tui_answering.elapsed_text ~now started_at )
    (* One mark per colour class, so a reader who cannot tell the colours
       apart gets the split the colours make. Four states shared a single
       [\xe2\x97\x8f] while the style beside them was green, red or grey: on
       a column of identical marks, the lane failing 133 of 1095 runs looked
       exactly like the four that were fine.

       This says what the style says and no more -- the mapping is the same
       three-way split, not a second opinion about severity. *)
    | (Tui_decode.Standalone_idle | Tui_decode.Standalone_running), _ ->
      ("\xe2\x97\x8f", status)
    | ( (Tui_decode.Standalone_degraded | Tui_decode.Standalone_unavailable)
      , _ ) ->
      ("\xe2\x9c\x97", status)
    | Tui_decode.Standalone_no_retained_observation, _ -> ("\xc2\xb7", status)
  in
  (* Why the lane cannot admit, where the cell used to restate that it cannot.
     "no admitted slot" says the same thing the status word beside it already
     says; the projection carries the reason -- an unconfigured lane and a lane
     whose registry could not be read are different problems and the operator
     acts on them differently -- and nothing drew it. *)
  let slots =
    let base =
      match lane.sl_admitted_slots, lane.sl_admission_error with
      | [], Some reason -> reason
      | [], None ->
        (* CLI-only lanes are legal (RFC cli-runtimes-as-lane-slots): with a
           cli suffix declared, an empty catalog list is a shape, not a
           failure. *)
        if lane.sl_cli_slots = [] then "no admitted slot" else "cli-only"
      | admitted, None -> String.concat "," admitted
      | admitted, Some reason ->
        String.concat "," admitted ^ " \xc2\xb7 " ^ reason
    in
    let base =
      match lane.sl_cli_slots with
      | [] -> base
      | cli -> base ^ " +cli:" ^ String.concat "," cli
    in
    (* A declared slot publication could not admit is the difference between
       "configured single" and "configured double, one silently dropped" —
       the boot WARN was the only place that said so before this. *)
    match lane.sl_dropped_slots with
    | [] -> base
    | dropped -> base ^ " (dropped " ^ String.concat "," dropped ^ ")"
  in
  let observed_slots =
    match lane.sl_selected_slots with
    | [] -> "none"
    | slots ->
        slots
        |> List.map (fun slot ->
          Printf.sprintf "%s×%d" slot.slsc_slot_id slot.slsc_count)
        |> String.concat ","
  in
  let p50 =
    match lane.sl_p50_elapsed_s with
    | None -> "—"
    | Some seconds -> Printf.sprintf "%.1fs" seconds
  in
  let prefix = standalone_lane_status_style lane.sl_status in
  let line =
    Printf.sprintf
      "  %s%s %-15s %-14s%s slots %-20s active %d  runs %d  ok/fail/cancel %d/%d/%d  p50 %s  observed %s"
      prefix mark lane.sl_label status Ansi.reset slots lane.sl_running_count
      lane.sl_retained_run_count lane.sl_succeeded_count lane.sl_failed_count
      lane.sl_cancelled_count p50 observed_slots
  in
  fit_width line width

(* The row is deliberately dense for comparison, but it cannot also carry
   full slot ids, the consumer contract, and the fallback rule without
   clipping. Keep those facts in a wrapped selected-row block underneath the
   four-row matrix. The order is the execution contract: admitted catalog
   slots first, official-client runtimes only after catalog exhaustion. *)
let standalone_lane_detail_lines ~now ~width (lane : Tui_decode.standalone_lane) =
  let ordered values =
    match values with
    | [] -> "(none)"
    | values ->
      values
      |> List.mapi (fun index value ->
        Printf.sprintf "%d %s" (index + 1) (Terminal_text.single_line value))
      |> String.concat "  →  "
  in
  let wrap style text =
    Message_layout.wrap_words ~max_cells:(max 1 (width - 4)) text
    |> List.map (fun line -> style, "  " ^ line)
  in
  let purpose =
    Option.value ~default:"No consumer purpose reported by this server."
      lane.sl_purpose
  in
  let exact_lane which =
    Masc.Exact_lane_run_registry.lane_key which
    |> String.equal lane.sl_lane_id
  in
  let output_meaning, evidence_contract =
    if exact_lane Masc.Exact_lane_run_registry.Board_attention then
      ( "Output meaning: the accepted candidate judgment JSON."
      , "Evidence: structured-output generation, not a MASC tool loop; the run retains exact Input/Output, outcome, and selected slot, so no tool-call ledger exists." )
    else if exact_lane Masc.Exact_lane_run_registry.Hitl_auto_judge then
      ( "Output meaning: the validated and durably settled approval-context judgment summary."
      , "Evidence: structured-output generation, not a MASC tool loop; the run retains exact Input/Output, outcome, and selected slot, so no tool-call ledger exists." )
    else if exact_lane Masc.Exact_lane_run_registry.Librarian then
      ( "Output meaning: selected memory facts plus committed snapshot metadata."
      , "Evidence: structured-output generation, not a MASC tool loop; the run retains exact Input/Output, outcome, and selected slot, so no tool-call ledger exists." )
    else if String.equal lane.sl_lane_id Runtime.verifier_exact_lane_id then
      ( "Output meaning: Task completion or Goal proof verdict, reason, and evaluator runtime."
      , "Evidence: Verifier review records also retain MASC tool observations; open a run to inspect inputs, dispositions, excerpts, duration, and truncation." )
    else
      ( "Output meaning: open a retained run for its exact result."
      , "Evidence: this server did not report a known standalone-lane evidence contract." )
  in
  (* Three facts the server has always sent and nothing drew.

     [required] is the one that changes what an operator does about a lane
     that cannot run: an optional lane nobody configured is a choice, and a
     required one is a hole.

     [configuration_state] separates "nobody configured this" from "the
     registry could not be read", which the status word beside the lane
     collapses into one "unavailable". The block draws the admission error
     below, and those two states each carry one, so this is the typed half
     of a distinction that was only ever legible as prose.

     The last terminal run is what the totals cannot say. [ok/fail/cancel
     962/133/0] reads the same whether the failures were this morning or
     last quarter, and an idle lane says nothing at all about when it last
     did work. *)
  let obligation = if lane.sl_required then "Required" else "Optional" in
  let configuration =
    Tui_decode.standalone_lane_configuration_to_string
      lane.sl_configuration_state
  in
  let last_run =
    match lane.sl_last_outcome, lane.sl_last_terminal_at with
    | None, _ -> "no run has finished"
    | Some outcome, None -> "last run " ^ Terminal_text.single_line outcome
    | Some outcome, Some at ->
      Printf.sprintf "last run %s %s ago"
        (Terminal_text.single_line outcome)
        (Masc_tui_answering.elapsed_text ~now at)
  in
  (* By the state alone. This block draws no glyph, so a colour that also
     answered "is it required" would make a split nothing else in the block
     recovers -- the row two lines up gives every colour class its own mark
     for exactly that reason. The obligation is in the words. *)
  let state_style =
    match lane.sl_configuration_state with
    | Tui_decode.Lane_ready -> Ansi.reset
    | Tui_decode.Lane_slotless | Tui_decode.Lane_unconfigured -> Theme.warn ()
    | Tui_decode.Lane_registry_unavailable -> Theme.bad ()
  in
  wrap Ansi.bold
    (Printf.sprintf "%s · %s" (Terminal_text.single_line lane.sl_label)
       (Terminal_text.single_line purpose))
  @ wrap state_style
      (Printf.sprintf "%s lane · configuration %s · %s" obligation
         configuration last_run)
  @ wrap Ansi.dim
      (Printf.sprintf "Config: [runtime.exact_output_lanes.%s]"
         (Terminal_text.single_line lane.sl_lane_id))
  @ wrap Ansi.reset
      ("Catalog attempts (admitted order): " ^ ordered lane.sl_admitted_slots)
  @ wrap Ansi.reset
      ("Then CLI (after catalog exhaustion): " ^ ordered lane.sl_cli_slots)
  @ wrap
      (if lane.sl_dropped_slots = [] then Ansi.dim else Theme.warn ())
      ("Dropped before execution: " ^ ordered lane.sl_dropped_slots)
  @ (match lane.sl_admission_error with
     | None -> []
     | Some error ->
       wrap (Theme.bad ())
         ("Admission error: " ^ Terminal_text.single_line error))
  @ wrap Ansi.dim
      "TOML spec: slots = required non-empty catalog-ref array; cli_slots = optional official-client runtime-id array."
  @ wrap Ansi.dim
      "Lane configuration is TOML. Run Input/Output is retained JSON evidence. Press e to open this section in the preview-checked runtime.toml editor."
  @ wrap Ansi.reset output_meaning
  @ wrap Ansi.dim evidence_contract

let rec take_rows remaining acc = function
  | _ when remaining <= 0 -> List.rev acc
  | [] -> List.rev acc
  | row :: rest -> take_rows (remaining - 1) (row :: acc) rest

let render_lanes_overview (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let inner = max 1 (framed_inner_width cols) in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.standalone_lanes with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Lanes · Standalone") timestamp
          (connection_badge state)
    | Some snapshot ->
        Printf.sprintf "%s (%d lanes)  %s  %s"
          (screen_title " MASC Lanes · Standalone")
          (List.length snapshot.sls_lanes) timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let standalone_heading =
    match state.standalone_lanes with
    | None -> "  Standalone LLM lanes · READ-ONLY OBSERVATION"
    | Some snapshot ->
        let observed = Unix.localtime snapshot.sls_observed_at_unix in
        Printf.sprintf
          "  Standalone LLM lanes · READ-ONLY OBSERVATION · observed %02d:%02d:%02d"
          observed.Unix.tm_hour observed.Unix.tm_min observed.Unix.tm_sec
  in
  box_line_styled buf cols ~style:(Ansi.bold ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)) standalone_heading;
  (* The standalone rows are drawn directly rather than through a row list
     because the selection band has to land on a lane row, not on the
     windowed/stale notes that follow them. *)
  (match state.standalone_lanes with
   | Some snapshot ->
       List.iteri
         (fun index (lane : Tui_decode.standalone_lane) ->
           let row =
             standalone_lane_row ~now:(Unix.gettimeofday ())
               ~frame:state.activity_frame inner lane
           in
           if
             index = state.lanes_standalone_cursor
           then box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
           else box_line buf cols row)
         snapshot.Tui_decode.sls_lanes;
       if snapshot.sls_lanes = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           "  (no standalone lane observations)";
       if snapshot.sls_exact_run_projection_truncated then
         box_line buf cols
           (Printf.sprintf
              "%s  WINDOWED · exact runs %d/%d; counts and p50 use newest bounded window%s"
              (Theme.warn ()) snapshot.sls_exact_run_projection_count
              snapshot.sls_exact_run_source_total Ansi.reset);
       (match state.standalone_lanes_error with
        | None -> ()
        | Some detail ->
            box_line buf cols
              ((Theme.warn ()) ^ "  STALE · refresh failed: "
               ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset))
   | None ->
       box_line buf cols
         (match state.standalone_lanes_error with
          | None -> Ansi.dim ^ "  loading standalone lane observations…" ^ Ansi.reset
          | Some detail ->
              (Theme.bad ()) ^ "  standalone lane observation unavailable: "
              ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset));
  (* Use only the body's remaining rows. At small terminal heights the matrix
     stays complete and the detail truncates explicitly; at ordinary heights
     the wrapped block shows every slot id without the row's [fit_width]. *)
  (match selected_standalone_lane state with
   | None -> ()
   | Some lane ->
       let action_error_rows =
         match state.lanes_action_error with None -> 0 | Some _ -> 1
       in
       let available =
         max 0
           (rows - count_frame_lines buf - action_error_rows - 3)
       in
       if available > 0 then begin
         box_divider buf cols;
         let detail =
           standalone_lane_detail_lines ~now:(Unix.gettimeofday ())
             ~width:inner lane
         in
         let shown = take_rows available [] detail in
         let shown =
           if List.length detail <= available then shown
           else
             match List.rev shown with
             | [] -> []
             | _ :: rest ->
               List.rev ((Theme.warn (), "  … more; enlarge the terminal") :: rest)
         in
         List.iter
           (fun (style, line) -> box_line_styled buf cols ~style line)
           shown
       end);
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.warn ())
         ("  " ^ Keeper_chat.terminal_safe_text detail));
  let used_rows = count_frame_lines buf in
  for _ = 1 to max 0 (rows - used_rows - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

(* Status colours for standalone-lane runs, keyed on the decoded variant; a label
   the producer adds later decodes to [Lane_run_other] and reads muted until
   it is named here. *)
let lane_run_status_style = function
  | Tui_decode.Lane_run_succeeded
  | Tui_decode.Lane_run_approved
  | Tui_decode.Lane_run_reviewed
  | Tui_decode.Lane_run_committed -> Theme.ok ()
  | Tui_decode.Lane_run_cancelled
  | Tui_decode.Lane_run_rejected
  | Tui_decode.Lane_run_deferred
  | Tui_decode.Lane_run_review_cancelled -> Theme.warn ()
  | Tui_decode.Lane_run_failed
  | Tui_decode.Lane_run_completion_persistence_failed
  | Tui_decode.Lane_run_completion_durability_unknown
  | Tui_decode.Lane_run_infrastructure_unavailable
  | Tui_decode.Lane_run_not_reviewed
  | Tui_decode.Lane_run_commit_failed
  | Tui_decode.Lane_run_raised -> Theme.bad ()
  | Tui_decode.Lane_run_running
  | Tui_decode.Lane_run_operator_routed -> Theme.info ()
  | Tui_decode.Lane_run_other _ -> Theme.muted ()

let lane_run_clock started_at =
  let tm = Unix.localtime started_at in
  Printf.sprintf "%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let standalone_lane_label (state : state) lane_id =
  match state.standalone_lanes with
  | None -> lane_id
  | Some snapshot ->
      (match
         List.find_opt
           (fun (lane : Tui_decode.standalone_lane) ->
             String.equal lane.sl_lane_id lane_id)
           snapshot.Tui_decode.sls_lanes
       with
       | Some lane -> lane.sl_label
       | None -> lane_id)

let lane_run_subject (run : Tui_decode.lane_run_summary) =
  match run.lrs_run_kind, run.lrs_subject_id with
  | Tui_decode.Lane_run_task_verification, Some subject -> "task " ^ subject
  | Tui_decode.Lane_run_goal_verification, Some subject -> "goal " ^ subject
  | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    None ->
    run.lrs_actor
;;

(** Recent retained runs of one standalone lane. The list is the paged summary:
    no payload ever crosses it, so Enter fetches one exact detail. *)
let render_lane_run_list (state : state) ~lane_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let runs =
    match state.lane_runs with
    | None -> []
    | Some runs -> runs
  in
  let shown = List.length runs in
  let header =
    Printf.sprintf "%s · %s (%d runs)  %s"
      (screen_title " MASC Lanes")
      (fit_width
         (Terminal_text.single_line (standalone_lane_label state lane_id))
         20)
      shown (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let identity_heading =
    if String.equal lane_id Runtime.verifier_exact_lane_id then "SUBJECT"
    else "ACTOR"
  in
  (* The run id takes what the named columns leave; it used to run off the
     header with no end while the row cut it at twelve. *)
  let run_id_width =
    Render_schedule.lane_run_id_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  "
    ^ Render_schedule.lane_run_header_row ~identity_header:identity_heading
        ~run_id_width);
  box_divider buf cols;
  (match state.lane_runs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let layout = lanes_scrolled state in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.lane_runs_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.lane_runs ~error:state.lane_runs_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (no retained runs for this lane)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match List.nth_opt runs (index + scroll) with
      | None -> box_empty buf cols
      | Some (run : Tui_decode.lane_run_summary) ->
          let elapsed =
            match run.lrs_elapsed_s with
            | None -> "—"
            | Some seconds -> Printf.sprintf "%.1fs" seconds
          in
          let line =
            "  "
            ^ Render_schedule.lane_run_row ~identity_header:identity_heading
                ~status_style:(lane_run_status_style run.lrs_status)
                ~run_id_width
                { Render_schedule.lrow_started =
                    lane_run_clock run.lrs_started_at
                ; lrow_subject =
                    Terminal_text.single_line (lane_run_subject run)
                ; lrow_status =
                    Tui_decode.lane_run_status_label run.lrs_status
                ; lrow_elapsed = elapsed
                ; lrow_slot =
                    Terminal_text.single_line_or ~default:"—"
                      run.lrs_selected_slot
                ; lrow_run_id = Terminal_text.single_line run.lrs_run_id
                }
          in
          if index + scroll = state.lane_runs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d runs, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:Masc_tui_keys.footer_hints_lanes_run_list);
  finish_surface state ~surface_key:"lane-runs" ~rows:terminal_rows ~cols buf

(* A payload renders whole up to a bound; past it the frame shows the head and
   says so, rather than hanging the TUI on the kind of body that made the
   listing drop payloads. The cut lands on a line boundary so no multibyte
   sequence is split. *)
let lane_run_render_max_bytes = 65536

let lane_run_payload_lines ~width json =
  let full = Yojson.Safe.pretty_to_string json in
  let text, truncated =
    if String.length full <= lane_run_render_max_bytes then full, false
    else
      let cut =
        match String.rindex_from_opt full lane_run_render_max_bytes '\n' with
        | Some newline -> newline
        | None -> lane_run_render_max_bytes
      in
      String.sub full 0 cut, true
  in
  let rendered =
    fenced_document_text ~language:"json" text
    |> document_markdown ~width
    |> List.map (fun line -> Ansi.reset, line)
  in
  if truncated then
    rendered
    @ [ ( Theme.warn ()
        , Printf.sprintf "… truncated, total %d bytes" (String.length full) ) ]
  else rendered

let lane_run_decision_badge (detail : Tui_decode.lane_run_detail) =
  match
    Tui_decode.lane_run_decision ~run_kind:detail.lrd_run_kind
      ~status:detail.lrd_status
  with
  | Tui_decode.Lane_run_decision_approved -> Theme.ok (), "APPROVED"
  | Tui_decode.Lane_run_decision_rejected -> Theme.warn (), "REJECTED"
  | Tui_decode.Lane_run_decision_reviewed -> Theme.ok (), "REVIEWED"
  | Tui_decode.Lane_run_decision_committed -> Theme.ok (), "COMMITTED"
  | Tui_decode.Lane_run_decision_pending -> Theme.info (), "NO DECISION YET"
  | Tui_decode.Lane_run_decision_not_reached -> Theme.warn (), "NO DECISION"
  | Tui_decode.Lane_run_not_a_decision -> Theme.info (), "NOT A VERDICT"
  | Tui_decode.Lane_run_decision_unknown -> Theme.muted (), "UNKNOWN"

let lane_run_tool_disposition_presentation = function
  | Tui_decode.Lane_run_tool_completed -> Theme.ok (), "✓"
  | Tui_decode.Lane_run_tool_deferred -> Theme.warn (), "△"
  | Tui_decode.Lane_run_tool_failed -> Theme.bad (), "✗"
  | Tui_decode.Lane_run_tool_disposition_other _ -> Theme.warn (), "?"

let lane_run_tool_call_summary (tool : Tui_decode.lane_run_tool) =
  let style, mark =
    lane_run_tool_disposition_presentation tool.lrt_disposition
  in
  let disposition =
    Tui_decode.lane_run_tool_disposition_label tool.lrt_disposition
    |> Terminal_text.single_line
  in
  Printf.sprintf "%s%s%s %s%s%s ‹%s · %.0fms›%s"
    style Ansi.bold mark
    (Terminal_text.single_line tool.lrt_name)
    Ansi.reset style disposition tool.lrt_duration_ms Ansi.reset

type lane_run_tool_counts =
  { completed : int
  ; deferred : int
  ; failed : int
  ; other : int
  }

let lane_run_tool_count_summary tools =
  let counts =
    List.fold_left
      (fun counts (tool : Tui_decode.lane_run_tool) ->
         match tool.lrt_disposition with
         | Tui_decode.Lane_run_tool_completed ->
           { counts with completed = counts.completed + 1 }
         | Tui_decode.Lane_run_tool_deferred ->
           { counts with deferred = counts.deferred + 1 }
         | Tui_decode.Lane_run_tool_failed ->
           { counts with failed = counts.failed + 1 }
         | Tui_decode.Lane_run_tool_disposition_other _ ->
           { counts with other = counts.other + 1 })
      { completed = 0; deferred = 0; failed = 0; other = 0 }
      tools
  in
  [ Theme.bad (), "✗", counts.failed, "failed"
  ; Theme.warn (), "△", counts.deferred, "deferred"
  ; Theme.warn (), "?", counts.other, "other"
  ; Theme.ok (), "✓", counts.completed, "completed"
  ]
  |> List.filter_map (fun (style, mark, count, label) ->
    if count = 0 then None
    else
      Some
        (Printf.sprintf "%s%s%s %s %s %d %s" style Ansi.reverse Ansi.bold mark
           (String.uppercase_ascii label) count Ansi.reset))
  |> String.concat " "

let lane_run_tool_summary = function
  | Tui_decode.Lane_run_no_tools_by_contract ->
    Theme.muted (), "TOOLS  none · exact-output runs do not use the MASC tool loop"
  | Tui_decode.Lane_run_tools_pending ->
    Theme.info (), "TOOLS  pending · the verifier run is still in progress"
  | Tui_decode.Lane_run_tools_contract_unknown ->
    Theme.muted (), "TOOLS  unknown · this run kind has no typed tool contract"
  | Tui_decode.Lane_run_tools_observed tools ->
    let calls = List.length tools in
    let counts = lane_run_tool_count_summary tools in
    let names =
      List.map lane_run_tool_call_summary tools
      |> String.concat "  │  "
    in
    let evidence =
      [ names ]
      |> List.filter (fun value -> not (String.equal value ""))
      |> String.concat "  ·  "
    in
    let call_count =
      Printf.sprintf "%d %s" calls (if calls = 1 then "CALL" else "CALLS")
    in
    let overview =
      if String.equal counts "" then call_count else counts ^ "  ──  " ^ call_count
    in
    (* fit_width clips the right edge, so put the worst typed disposition
       immediately after the label. Even an ultra-narrow terminal retains the
       operator-significant failure/deferred badge before call metadata. *)
    ( Ansi.reset
    , Printf.sprintf "%sTOOLS%s %s%s" Ansi.bold Ansi.reset overview
        (if String.equal evidence "" then "" else "  │  " ^ evidence) )

let lane_run_skill_summary = function
  | Tui_decode.Lane_run_no_skills_by_contract ->
    Theme.muted (),
    "SKILLS  none · standalone runs do not load Keeper Skill instructions"
  | Tui_decode.Lane_run_skills_contract_unknown ->
    Theme.muted (), "SKILLS  unknown · this run kind has no typed Skill contract"

let lane_run_gate_judgment_summary = function
  | Tui_decode.Lane_run_not_gate_judgment -> None
  | Tui_decode.Lane_run_gate_judgment_pending ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %spending%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.info ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_judgment_not_reached ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %snone%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.warn ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_advisory judgment ->
    let style =
      match judgment with
      | Keeper_approval_queue_rules_types.Approve -> Theme.ok ()
      | Keeper_approval_queue_rules_types.Deny -> Theme.warn ()
      | Keeper_approval_queue_rules_types.Require_human -> Theme.info ()
    in
    let label =
      Keeper_approval_queue_rules_types.advisory_judgment_to_string judgment
      |> String.uppercase_ascii
    in
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %sADVISORY %s%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset style label Ansi.reset )

let lane_run_summary_lines (detail : Tui_decode.lane_run_detail) =
  let subject =
    match detail.lrd_run_kind, detail.lrd_subject_id with
    | Tui_decode.Lane_run_task_verification, Some subject ->
      "  ·  TASK " ^ Terminal_text.single_line subject
    | Tui_decode.Lane_run_goal_verification, Some subject ->
      "  ·  GOAL " ^ Terminal_text.single_line subject
    | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
    | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
      None ->
      ""
  in
  let elapsed =
    match detail.lrd_elapsed_s with
    | None -> ""
    | Some seconds -> Printf.sprintf "  ·  %.1fs" seconds
  in
  let slot =
    match detail.lrd_selected_slot with
    | None -> ""
    | Some slot -> "  ·  SLOT " ^ Terminal_text.single_line slot
  in
  let decision_style, decision = lane_run_decision_badge detail in
  let tool_style, tools = lane_run_tool_summary detail.lrd_tool_evidence in
  let skill_style, skills = lane_run_skill_summary detail.lrd_skill_evidence in
  let gate_judgment =
    match lane_run_gate_judgment_summary detail.lrd_gate_judgment with
    | None -> []
    | Some (style, line) -> [ style, "  " ^ line ]
  in
  [ ( Ansi.reset
    , Printf.sprintf "  LANE  %s  ·  %s%s"
        (Terminal_text.single_line detail.lrd_lane)
        (Terminal_text.single_line
           (Tui_decode.lane_run_kind_label detail.lrd_run_kind))
        subject )
  ; ( Ansi.dim
    , Printf.sprintf "  ACTOR  %s  ·  STARTED %s%s%s"
        (Terminal_text.single_line detail.lrd_actor)
        (lane_run_clock detail.lrd_started_at) elapsed slot )
  ; ( Ansi.reset
    , Printf.sprintf "  DECISION  %s%s%s  ·  RUN  %s%s%s" decision_style
        decision Ansi.reset (lane_run_status_style detail.lrd_status)
        (Terminal_text.single_line
           (Tui_decode.lane_run_status_label detail.lrd_status))
        Ansi.reset )
  ]
  @ gate_judgment
  @ [ tool_style, "  " ^ tools; skill_style, "  " ^ skills ]

let lane_run_panel_titles (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_run_kind, detail.lrd_tool_evidence with
  | Tui_decode.Lane_run_exact_output, _ ->
    "INPUT · PROMPT PAYLOAD", "OUTPUT · MODEL RESPONSE"
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    Tui_decode.Lane_run_tools_observed tools ->
    ( "INPUT · VERIFICATION REQUEST"
    , Printf.sprintf "OUTPUT · VERDICT + TOOL EVIDENCE (%d %s)"
        (List.length tools)
        (if List.length tools = 1 then "CALL" else "CALLS") )
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    (Tui_decode.Lane_run_tools_pending | Tui_decode.Lane_run_no_tools_by_contract
    | Tui_decode.Lane_run_tools_contract_unknown) ->
    "INPUT · VERIFICATION REQUEST", "OUTPUT · VERDICT + TOOL EVIDENCE"
  | Tui_decode.Lane_run_kind_other _, _ -> "INPUT", "OUTPUT"

let lane_run_output_lines ~width (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_output with
  | None ->
    [ Theme.muted (), "(run has not completed; no output recorded)" ]
  | Some output -> lane_run_payload_lines ~width output

let lane_run_stacked_lines ~width (detail : Tui_decode.lane_run_detail) =
  let input_title, output_title = lane_run_panel_titles detail in
  let indent lines = List.map (fun (style, line) -> style, "  " ^ line) lines in
  [ Ansi.bold, "  " ^ input_title ]
  @ indent (lane_run_payload_lines ~width detail.lrd_input_payload)
  @ [ Ansi.dim, ""; Ansi.bold, "  " ^ output_title ]
  @ indent (lane_run_output_lines ~width detail)

let lane_run_pane_progress ~scroll ~height total =
  if total = 0 then "0/0"
  else if height <= 0 then Printf.sprintf "0/%d" total
  else
    Printf.sprintf "%d-%d/%d" (scroll + 1) (min total (scroll + height)) total

let lane_run_split_line buf cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = " │ " in
  let divider_width = 3 in
  let right_width = max 1 (inner - left_width - divider_width) in
  let styled width (style, line) =
    fit_width (style ^ line ^ Ansi.reset) width
  in
  box_line buf cols
    (styled left_width left ^ Theme.recede () ^ divider ^ Ansi.reset
     ^ styled right_width right)

let render_lane_run_detail (state : state) ~run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let detail =
    match state.lane_run_detail with
    | Some detail when String.equal detail.Tui_decode.lrd_run_id run_id ->
        Some detail
    | Some _ | None -> None
  in
  let header =
    Printf.sprintf "%s  %s  %s"
      (screen_title " MASC Lane Run")
      (fit_width (Terminal_text.single_line run_id) 38)
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.lane_run_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       if Option.is_none detail then box_divider buf cols);
  let error_rows =
    match detail, state.lane_run_detail_error with
    | Some _, Some _ -> 1
    | None, Some _ -> 2
    | (Some _ | None), None -> 0
  in
  let scroll, max_scroll =
    match detail, state.lane_run_detail_error with
    | None, error ->
      let content_height = max 1 (rows - 5 - error_rows) in
      let line =
        match error with
        | None -> Ansi.dim, "  (loading exact run record)"
        | Some _ -> Ansi.dim, "  (load failed; nothing here is a reading)"
      in
      box_line_styled buf cols ~style:(fst line) (snd line);
      for _ = 2 to content_height do
        box_empty buf cols
      done;
      0, 0
    | Some detail, (Some _ | None) ->
      let summary = lane_run_summary_lines detail in
      List.iter
        (fun (style, line) -> box_line_styled buf cols ~style line)
        summary;
      box_divider buf cols;
      if cols >= keeper_split_threshold_cols then begin
        let inner = framed_inner_width cols in
        let divider_width = 3 in
        let left_width = max 1 ((inner - divider_width) / 2) in
        let right_width = max 1 (inner - left_width - divider_width) in
        let input_lines =
          lane_run_payload_lines ~width:left_width detail.lrd_input_payload
        in
        let output_lines = lane_run_output_lines ~width:right_width detail in
        let payload_rows =
          max 0 (rows - List.length summary - 6 - error_rows)
        in
        if payload_rows = 0
        then 0, 0
        else begin
          let content_height = payload_rows - 1 in
          let input_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length input_lines - content_height)
          in
          let output_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length output_lines - content_height)
          in
          let max_scroll = max input_max_scroll output_max_scroll in
          let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
          let input_scroll = min scroll input_max_scroll in
          let output_scroll = min scroll output_max_scroll in
          let input_title, output_title = lane_run_panel_titles detail in
          lane_run_split_line buf cols ~left_width
            ~left:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" input_title
                  (lane_run_pane_progress ~scroll:input_scroll
                     ~height:content_height (List.length input_lines)) )
            ~right:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" output_title
                  (lane_run_pane_progress ~scroll:output_scroll
                     ~height:content_height (List.length output_lines)) );
          for index = 0 to content_height - 1 do
            let left =
              Option.value
                (List.nth_opt input_lines (index + input_scroll))
                ~default:(Ansi.reset, "")
            in
            let right =
              Option.value
                (List.nth_opt output_lines (index + output_scroll))
                ~default:(Ansi.reset, "")
            in
            lane_run_split_line buf cols ~left_width ~left ~right
          done;
          scroll, max_scroll
        end
      end
      else begin
        let lines =
          lane_run_stacked_lines ~width:(max 1 (cols - 8)) detail
        in
        let content_height =
          max 0 (rows - List.length summary - 6 - error_rows)
        in
        let max_scroll =
          if content_height = 0
          then 0
          else max 0 (List.length lines - content_height)
        in
        let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
        for index = 0 to content_height - 1 do
          match List.nth_opt lines (index + scroll) with
          | None -> box_empty buf cols
          | Some (style, line) -> box_line_styled buf cols ~style line
        done;
        scroll, max_scroll
      end
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_lanes_run_detail ~scroll ~max_scroll));
  finish_surface state ~clamped:(Lane_run_detail_scroll scroll)
    ~surface_key:"lane-run" ~rows:terminal_rows ~cols buf

(* The clients roster: everyone attached to this workspace in one reading —
   directory agents, state-backed sessions, runtime fibers. The keeper
   roster answers "which Keepers exist"; this answers "who is here now",
   which includes identities no other surface lists, such as a non-keeper
   MCP client. One row per identity, sorted by name on the server, with the
   status dot, the type, the keeper a row is bound to when it is, and what
   task it holds. *)
let render_clients (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let clients =
    match state.clients_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.cls_clients
  in
  let shown = List.length clients in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.clients_surface with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Runtime · Clients") timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d attached)  %s  %s"
          (screen_title " MASC Runtime · Clients") shown timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows like the verification submitter column: a fixed
     width puts the columns after the longest name out of line with the
     rest, and session names are the column the eye scans by. *)
  let name_width =
    List.fold_left
      (fun widest (row : Masc.Tui_decode.client_row) ->
         max widest
           (Message_layout.display_width
              (Terminal_text.single_line row.Masc.Tui_decode.cr_name)))
      16 clients
    |> min 24
  in
  let col_hdr =
    Printf.sprintf "  %-9s %-*s %-10s %-16s %-9s %s" "Status" name_width
      "Name" "Type" "Keeper" "Task" "Last seen"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.clients_surface_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.clients_surface_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.clients_surface_scroll max_scroll) in
  (* The wire carries RFC3339; the roster only needs the clock, the same
     reading the header's own timestamp gives it a distance to. *)
  let clock_of_iso value =
    match String.index_opt value 'T' with
    | Some at when String.length value - at >= 9 ->
        String.sub value (at + 1) 8
    | _ -> value
  in
  if shown = 0 then begin
    let empty =
      match state.clients_surface_error with
      | Some _ -> page_failed_note
      | None -> "  (nobody attached)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt clients idx with
      | None -> box_empty buf cols
      | Some row ->
          let open Masc.Tui_decode in
          let status = client_status_to_string row.cr_status in
          let name = Terminal_text.single_line row.cr_name in
          let keeper =
            match row.cr_keeper_name with
            | Some keeper -> Terminal_text.single_line keeper
            | None -> "-"
          in
          let task =
            match row.cr_current_task with
            | Some task -> Terminal_text.single_line task
            | None -> "-"
          in
          let line =
            Printf.sprintf "  %-9s %s %-10s %-16s %-9s %s" status
              (fit_width name name_width)
              (fit_width (Terminal_text.single_line row.cr_agent_type) 10)
              (fit_width keeper 16)
              (fit_width task 9)
              (clock_of_iso row.cr_last_seen)
          in
          (* Inactive rows stay in the roster -- "who left" is part of the
             reading -- but they recede, the way the empty-state rows do. *)
          let style =
            match row.cr_status with
            | Client_inactive -> Theme.recede ()
            | _ -> Ansi.reset
          in
          if idx = state.clients_surface_cursor then
            box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d attached, scroll %d]" shown scroll);
  box_bottom buf cols;
  finish_surface state ~surface_key:"clients" ~rows:terminal_rows ~cols buf
;;

let render_lanes (state : state) =
  match state.lanes_mode with
  | Lanes_overview -> render_lanes_overview state
  | Lanes_run_list lane_id -> render_lane_run_list state ~lane_id
  | Lanes_run_detail (_, run_id) -> render_lane_run_detail state ~run_id

(** Render keeper detail view with live context and scrolling *)
(* The detail box alone -- borders, title, scrolled content -- written into
   [buf] at [cols] wide, footer excluded so a caller can lay it beside the
   roster pane. Returns the scroll the frame actually used. *)
(* What the Keeper carries to reach a service, by name.

   Values are not here to be hidden -- the producer never sends them. The
   composite body carries names, counts and a validation flag, so this pane
   cannot show a credential by accident.

   A Keeper absent from the projection list is a different reading from one
   whose projection says [absent]: the first means the producer has not
   answered for this Keeper yet, the second means it answered that no root is
   configured. Saying "none" for both would report a fact the server did not
   send. *)
let secret_lines (state : state) (k : keeper) =
  let dim line = Ansi.dim ^ line ^ Ansi.reset in
  match
    List.find_opt
      (fun (p : Masc.Tui_decode.keeper_secret_projection) ->
        String.equal p.Masc.Tui_decode.ksp_keeper k.k_name)
      state.keeper_secrets
  with
  | None -> [ dim "  (no projection reported for this Keeper)" ]
  | Some p ->
      let status = Masc.Tui_decode.keeper_secret_status_to_string p.ksp_status in
      let status_line =
        match p.ksp_status with
        | Masc.Tui_decode.Secret_ready ->
            "  Status:  " ^ (Theme.ok ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_error ->
            "  Status:  " ^ (Theme.bad ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_empty | Masc.Tui_decode.Secret_absent
        | Masc.Tui_decode.Secret_status_unknown _ ->
            "  Status:  " ^ Ansi.dim ^ status ^ Ansi.reset
      in
      let entry_lines label = function
        | [] -> [ dim (Printf.sprintf "  %s  -" label) ]
        | names ->
            List.mapi
              (fun index name ->
                let lead = if index = 0 then label else String.make (String.length label) ' ' in
                Printf.sprintf "  %s  %s" lead (Terminal_text.single_line name))
              names
      in
      [ status_line
      ; Printf.sprintf "  Root:    %s" (Terminal_text.single_line p.ksp_root)
      ; ""
      ]
      @ entry_lines "Env: " p.ksp_env_names
      @ (match p.ksp_file_paths with
         | [] -> []
         | paths -> "" :: entry_lines "Files:" paths)
      @ (match p.ksp_error with
         | None -> []
         | Some detail ->
             [ ""; (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ])
      @ [ ""
        ; dim
            (if p.ksp_values_validated then
               "  Values were read and validated. They are never sent here."
             else "  Values were not validated on the last read.")
        ]

(* The Identity tab's body. Numbering comes from
   [Masc_tui_types.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
let identity_lines (state : state) (k : keeper) ~cols providers =
  (* Everything on this pane reads the filtered list: the rows drawn, the
     number beside each one, and the row the marker is on. A screen that
     numbered the whole set while the keys acted on a subset would start the
     wrong service. *)
  let query = Option.value state.identity_filter ~default:"" in
  let connectable = Masc_tui_types.identity_connectable ~query providers in
  let tools_of id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared { idp_id; idp_tools; _ }
          when String.equal idp_id id -> Some idp_tools
        | Masc_tui_types.Identity_declared _ | Masc_tui_types.Identity_unreadable _ ->
            None)
      providers
    |> Option.join
  in
  (* Which other Keepers hold this one. Shown on both states: on an attached
     row it says the coverage, and on an unattached one it says the service
     is already in use somewhere, which is the row an operator is most likely
     to have lost track of. *)
  let switch_of id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared
            { idp_id; idp_enabled; idp_switch_problem; _ }
          when String.equal idp_id id -> Some (idp_enabled, idp_switch_problem)
        | Masc_tui_types.Identity_declared _ | Masc_tui_types.Identity_unreadable _
          -> None)
      providers
  in
  let also_on id =
    List.find_map
      (function
        | Masc_tui_types.Identity_declared { idp_id; idp_also_on; _ }
          when String.equal idp_id id -> Some idp_also_on
        | Masc_tui_types.Identity_declared _ | Masc_tui_types.Identity_unreadable _
          -> None)
      providers
    |> Option.value ~default:[]
  in
  let numbered =
    List.mapi
      (fun index (id, label) ->
        (* Attached-and-offering-nothing is a third state. Reading it as "not
           attached" would tell an operator to consent again for no reason. *)
        let row_state =
          match tools_of id with
          | None -> Ansi.dim ^ "not attached" ^ Ansi.reset
          | Some [] -> Ansi.dim ^ "attached, no tools" ^ Ansi.reset
          | Some names -> (
              (* The switch outranks the tool count: a service an operator
                 turned off is handing this keeper nothing, however many
                 tools its catalog names, and an unreadable switch store
                 must not render as on. *)
              match switch_of id with
              | Some (_, Some _) ->
                  (Theme.bad ()) ^ "switch unreadable" ^ Ansi.reset
              | Some (Some false, None) ->
                  (Theme.warn ()) ^ "off" ^ Ansi.reset
              | Some ((Some true | None), None) | None ->
                  Printf.sprintf "%s%d tools%s" (Theme.ok ())
                    (List.length names) Ansi.reset)
        in
        (* The row the arrows are on is marked rather than merely numbered:
           past nine the number is no longer a key an operator can press,
           and the marker is what says which one enter would start. *)
        let here =
          index
          = Masc_tui_types.identity_cursor_clamped ~query ~providers
              state.identity_cursor
        in
        let marker = if here then Theme.ok () ^ ">" ^ Ansi.reset else " " in
        (* Padded before it is emphasised: the escape codes are characters
           to a width specifier and nothing on screen, so padding afterwards
           shortens the column by however long the codes are. *)
        let padded = Printf.sprintf "%-24s" (Terminal_text.single_line label) in
        let shown = if here then Ansi.bold ^ padded ^ Ansi.reset else padded in
        let elsewhere =
          match also_on id with
          | [] -> ""
          | names ->
            Ansi.dim ^ "  · also " ^ String.concat ", " names ^ Ansi.reset
        in
        Printf.sprintf "%s %2d  %s %s%s" marker (index + 1) shown row_state
          elsewhere)
      connectable
  in
  let attached_tool_lines =
    connectable
    |> List.concat_map (fun (id, _) ->
           match tools_of id with
           | None | Some [] -> []
           | Some names ->
               ""
               :: (Ansi.dim ^ "  " ^ Terminal_text.single_line id ^ Ansi.reset)
               :: List.map
                    (fun name -> "    " ^ Terminal_text.single_line name)
                    names)
  in
  let rejected =
    List.filter_map
      (function
        | Masc_tui_types.Identity_declared _ -> None
        | Masc_tui_types.Identity_unreadable { idp_id; idp_problem } ->
            Some
              (Printf.sprintf "  -  %s  %s%s%s"
                 (Terminal_text.single_line idp_id)
                 (Theme.bad ())
                 (Terminal_text.single_line idp_problem)
                 Ansi.reset))
      providers
  in
  let started =
    match state.identity_login with
    | Some login when String.equal login.ils_keeper k.k_name ->
        (* Wrapped, not truncated. The URL is about nine hundred characters
           and a pane cuts it at its own width; a cut URL cannot be selected
           or copied, so the login stopped there. The TUI opens it as well --
           this is what is left when the machine has no opener. *)
        let url = Terminal_text.single_line login.ils_url in
        let width = max 20 (cols - 6) in
        let rec fold at acc =
          if at >= String.length url then List.rev acc
          else
            let take = min width (String.length url - at) in
            fold (at + take) (("    " ^ String.sub url at take) :: acc)
        in
        ("" :: (Ansi.bold ^ "  A browser should have opened to consent as "
                ^ Terminal_text.single_line login.ils_label ^ "." ^ Ansi.reset)
         :: (Ansi.dim ^ "  If it did not, the URL is here:" ^ Ansi.reset)
         :: fold 0 [])
        @ [ Ansi.dim
            ^ "  Nothing is written to this keeper until you come back."
            ^ Ansi.reset ]
    | Some _ | None -> []
  in
  (* What one attempt answered. Wrapped, because the message that matters
     most here is the long one: a provider that registers no client says what
     to make and where to put it, and a single truncated line is the half of
     that sentence an operator cannot act on. *)
  (* Built by the shared function and only coloured here: the key handler
     counts these rows to know where the list starts, and two places wrapping
     the same text at their own idea of the width would disagree. *)
  let attempt_kind =
    Option.map fst state.identity_attempt_error
  in
  let attempt =
    Masc_tui_types.identity_notice ~cols
      (Option.map
         (fun (kind, text) -> (kind, Terminal_text.single_line text))
         state.identity_attempt_error)
  in
  (* Green when it worked and red when it did not. One line reports both, and
     drawing a recorded app in the colour of a refusal is a report that reads
     as its own opposite. *)
  let attempt =
    let body =
      match attempt_kind with
      | Some Masc_tui_types.Notice_ok -> Theme.ok ()
      | Some Masc_tui_types.Notice_bad | None -> Theme.bad ()
    in
    List.mapi
      (fun index line ->
        if line = "" then line
        else if index = List.length attempt - 1 then Ansi.dim ^ line ^ Ansi.reset
        else body ^ line ^ Ansi.reset)
      attempt
  in
  (* The query, and what it left. Shown even when it matches nothing --
     otherwise an empty pane is indistinguishable from a service list that
     failed to load. *)
  let filter_rows =
    List.map
      (fun line -> if line = "" then line else Theme.ok () ^ line ^ Ansi.reset)
      (Masc_tui_types.identity_filter_rows ~providers state.identity_filter)
  in
  if numbered = [] && rejected = [] && state.identity_filter <> None then
    Masc_tui_types.identity_preamble
      ~keeper:(Terminal_text.single_line k.k_name)
      ~notice:
        (attempt @ started @ Masc_tui_types.identity_app_form_rows state.identity_app_form
        @ filter_rows)
    @ [ Ansi.dim ^ "  Nothing here matches. esc to see them all." ^ Ansi.reset ]
  else if numbered = [] && rejected = [] then
    [ Ansi.dim ^ "  Nothing is declared under config/identity/." ^ Ansi.reset ]
  else
    Masc_tui_types.identity_preamble
      ~keeper:(Terminal_text.single_line k.k_name)
      ~notice:
        (attempt @ started @ Masc_tui_types.identity_app_form_rows state.identity_app_form
        @ filter_rows)
    @ numbered @ rejected @ attached_tool_lines

let keeper_detail_pane (state : state) (k : keeper) ~framed ~rows ~cols buf =
    (* Beside the roster pane the box is the pane separator; alone on the
       surface it is the redundant outer frame, dropped. *)
    let box_top = if framed then framed_top else box_top in
    let box_divider = if framed then framed_divider else box_divider in
    let box_line = if framed then framed_line else box_line in
    let box_empty = if framed then framed_empty else box_empty in
    let box_bottom = if framed then framed_bottom else box_bottom in
    let inner = framed_inner_width cols in

    (* Build all detail lines first, then apply scroll *)
    let lines = ref [] in
    let add_line s = lines := s :: !lines in

    (* Helper to add a labeled row *)
    let add_row label value =
      add_line (Printf.sprintf "  %s%-22s%s %s" (Masc_tui_theme.tone Masc_tui_theme.Accent) label Ansi.reset value)
    in
    let add_empty () = add_line "" in
    let add_section title =
      add_line (Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset)
    in

    (* Identity section *)
    add_section "Identity";
    add_row "Name:" (Terminal_text.single_line k.k_name);
    add_row "Paused:"
      (if k.k_paused then (Theme.warn ()) ^ "yes" ^ Ansi.reset
       else Ansi.dim ^ "no" ^ Ansi.reset);
    add_empty ();

    (* Gate section. Two settings with similar names decide different things,
       so both are named rather than merged: YOLO is the in-memory stance that
       stops this chat asking and a restart clears, while the Gate mode is
       durable and is what an external effect -- a write to a service this
       Keeper is attached to -- is actually decided under. An operator reading
       one for the other is how a call gets made that nobody meant to allow. *)
    add_section "Gate";
    add_row "Chat asks (YOLO):"
      (if List.mem k.k_name state.keeper_yolo_names then
         (Theme.bad ()) ^ "skipped" ^ Ansi.reset
       else Ansi.dim ^ "asked" ^ Ansi.reset);
    add_row "Effects (Gate mode):"
      (match List.assoc_opt k.k_name state.keeper_gate_modes with
       | Some mode -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ Terminal_text.single_line mode ^ Ansi.reset
       | None -> Ansi.dim ^ "workspace" ^ Ansi.reset);
    add_row "Judge first:"
      (match List.assoc_opt k.k_name state.keeper_gate_judges with
       | Some slot -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ Terminal_text.single_line slot ^ Ansi.reset
       | None -> Ansi.dim ^ "lane order" ^ Ansi.reset);
    add_empty ();

    (* Current work section *)
    add_section "Current Work";
    add_row "Task:"
      (Terminal_text.single_line_or ~default:"-" k.k_current_task_id);
    add_empty ();

    (* Live Context section (Phase 2) *)
    add_section "Live Context";
    (match
       Context_state.reading_for_keeper ~keeper_name:k.k_name
         state.live_context
     with
     | None ->
         add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)
     | Some reading ->
         (match
            Terminal_text.optional_single_line reading.error,
            reading.observation
          with
          | Some error, _ ->
              add_row "Context:" ((Theme.bad ()) ^ error ^ Ansi.reset)
          | None, Some observation ->
              (match Observation_layout.context_summary observation with
               | Observation_layout.Context_measured observation ->
                   let ratio = observation.ratio in
                   let pct =
                     Float.of_int (Observation_layout.percentage_tenths ratio)
                     /. 10.0
                   in
                   let bar_width =
                     Masc_tui_render_schedule.keeper_context_bar_width
                       ~inner_width:inner
                   in
                   add_row "Context:"
                     (Printf.sprintf "%s%.1f%%%s  %s  %d / %d tokens"
                        (ctx_color ratio) pct Ansi.reset
                        (ctx_bar ratio bar_width) observation.tokens
                        observation.maximum);
                   add_row "Observed:"
                     (Terminal_text.short_timestamp observation.observed_at);
                   add_row "Turn Ref:"
                     (Terminal_text.single_line observation.turn_ref)
               | Observation_layout.Context_partial observation ->
                   add_row "Context:"
                     (Printf.sprintf "%d tokens; context window not observed"
                        observation.tokens);
                   add_row "Observed:"
                     (Terminal_text.short_timestamp observation.observed_at);
                   add_row "Turn Ref:"
                     (Terminal_text.single_line observation.turn_ref)
               | Observation_layout.Context_unavailable reason ->
                   add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset))
          | None, None ->
              add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)));
    add_empty ();

    (* Runtime section *)
    add_section "Runtime Stats";
    add_row "Total Turns:" (string_of_int k.k_total_turns);
    add_row "Total Tokens:" (string_of_int k.k_total_tokens);
    add_row "Total Cost:" (Printf.sprintf "$%.4f" k.k_total_cost_usd);
    add_row "Last Turn:" (Terminal_text.short_timestamp k.k_last_turn_ts);
    add_empty ();

    (* Recent activity, folded from the metrics rows already read for this
       Keeper. The window is bounded by row count, so it can fall short of the
       span; when it does, say what it reached instead of implying a full day. *)
    let activity =
      Keeper_activity.summarize
        ~since:
          (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
        state.log_entries
    in
    add_section "Last 24h";
    if not activity.Keeper_activity.aw_covered then
      add_row "Window:"
        (match activity.Keeper_activity.aw_oldest_ts with
         | Some oldest ->
           Printf.sprintf "partial, reaches %s"
             (Terminal_text.short_timestamp oldest)
         | None -> "no metrics rows read");
    add_row "Turns / Heartbeats:"
      (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
         activity.Keeper_activity.aw_heartbeats);
    add_row "Tokens In / Out:"
      (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_input_tokens
         activity.Keeper_activity.aw_output_tokens);
    add_row "Cost:"
      (Printf.sprintf "$%.4f" activity.Keeper_activity.aw_cost_usd);
    add_row "Tool Calls:"
      (string_of_int activity.Keeper_activity.aw_tool_calls);
    add_row "Top Tools:"
      (match activity.Keeper_activity.aw_top_tools with
       | [] -> "-"
       | tools ->
         tools
         |> List.map (fun (tool : Keeper_activity.tool_use) ->
                Printf.sprintf "%s x%d"
                  (Terminal_text.single_line tool.Keeper_activity.tu_name)
                  tool.Keeper_activity.tu_calls)
         |> String.concat "  ");
    add_empty ();

    add_section "Autonomy";
    add_row "Last Outcome:" k.k_last_proactive_outcome;
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (Terminal_text.short_timestamp k.k_created_at);
    add_row "Updated:" (Terminal_text.short_timestamp k.k_updated_at);

    (* Reverse to get correct order *)
    let info_lines = List.rev !lines in
    (* The non-Info tabs draw a fetched read; the stamp has to name the
       keeper on screen or the pane shows loading, never another keeper's
       answer. *)
    let stamped_or view error =
      match error with
      | Some detail -> [ (Theme.bad ()) ^ "  " ^ detail ^ Ansi.reset ]
      | None -> (
          match view with
          | Some (stamp, lines) when String.equal stamp k.k_name ->
              List.map (fun line -> "  " ^ line) lines
          | Some _ | None -> [ Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset ])
    in
    let channel_lines =
      match state.connectors_error, state.connectors with
      | Some detail, None ->
          [ (Theme.bad ()) ^ "  channel transports unavailable: "
            ^ Terminal_text.single_line detail ^ Ansi.reset
          ]
      | _, None -> [ Ansi.dim ^ "  (loading channel transports…)" ^ Ansi.reset ]
      | error, Some snapshot ->
          let connectors = snapshot.cs_connectors in
          let selected_index =
            max 0 (min state.connectors_cursor (List.length connectors - 1))
          in
          let connection_text (connector : Tui_decode.connector) =
            match connector.cn_connection with
            | Tui_decode.Connector_connected -> "CONNECTED"
            | Connector_connected_unavailable -> "CONNECTED / UNAVAILABLE"
            | Connector_disconnected -> "DISCONNECTED"
            | Connector_offline -> "UNAVAILABLE"
            | Connector_stale -> "STALE"
          in
          let connection_label (connector : Tui_decode.connector) =
            match connector.cn_connection with
            | Tui_decode.Connector_connected ->
                (Theme.ok ()) ^ "● CONNECTED" ^ Ansi.reset
            | Connector_connected_unavailable ->
                (Theme.warn ()) ^ "● CONNECTED / UNAVAILABLE" ^ Ansi.reset
            | Connector_disconnected ->
                (Theme.bad ()) ^ "● DISCONNECTED" ^ Ansi.reset
            | Connector_offline -> Ansi.dim ^ "○ UNAVAILABLE" ^ Ansi.reset
            | Connector_stale -> (Theme.warn ()) ^ "● STALE" ^ Ansi.reset
          in
          let transport_rows =
            List.mapi
              (fun index (connector : Tui_decode.connector) ->
                 let here_count =
                   List.length
                     (List.filter
                        (fun (binding : Tui_decode.connector_binding) ->
                           String.equal binding.cb_keeper_name k.k_name)
                        connector.cn_bindings)
                 in
                 let line =
                   "  " ^ (if index = selected_index then "▸ " else "  ")
                   ^ fit_width
                       (Terminal_text.single_line connector.cn_display_name)
                       14
                   ^ "  " ^ fit_width (connection_text connector) 12
                   ^ Printf.sprintf "  %d here / %d total" here_count
                       (List.length connector.cn_bindings)
                 in
                 if index = selected_index then Ansi.reverse ^ line ^ Ansi.reset
                 else line)
              connectors
          in
          let selected_lines =
            match List.nth_opt connectors selected_index with
            | None -> [ Ansi.dim ^ "  (no channel transports registered)" ^ Ansi.reset ]
            | Some connector ->
                let optional_row label value =
                  match value with
                  | None -> []
                  | Some value ->
                      [ Printf.sprintf "  %-18s %s" label
                          (Terminal_text.single_line value)
                      ]
                in
                let optional_bool_row label value =
                  optional_row label
                    (Option.map (fun present -> if present then "yes" else "no") value)
                in
                let optional_int_row label value =
                  optional_row label (Option.map string_of_int value)
                in
                let selected_binding =
                  List.nth_opt connector.cn_bindings state.connectors_binding_cursor
                in
                let keeper_is_present keeper_name =
                  List.exists
                    (fun (keeper : Tui_decode.keeper) ->
                       String.equal keeper.k_name keeper_name)
                    state.keepers
                in
                let binding_reference (binding : Tui_decode.connector_binding) =
                  match binding.cb_channel_name with
                  | None -> Terminal_text.single_line binding.cb_channel_id
                  | Some name ->
                      Printf.sprintf "%s (%s)"
                        (Terminal_text.single_line name)
                        (Terminal_text.single_line binding.cb_channel_id)
                in
                let runtime_state =
                  match connector.cn_gateway_state, connector.cn_poll_state with
                  | Some value, _ | None, Some value -> Some value
                  | None, None -> None
                in
                let store_state =
                  match connector.cn_binding_store_read_ok with
                  | Some true -> Some "readable"
                  | Some false -> Some "UNREADABLE"
                  | None -> None
                in
                let binding_lines =
                  List.mapi
                    (fun index (binding : Tui_decode.connector_binding) ->
                      let here = String.equal binding.cb_keeper_name k.k_name in
                      let selected = index = state.connectors_binding_cursor in
                      let missing_keeper =
                        not (keeper_is_present binding.cb_keeper_name)
                      in
                      let line =
                        Printf.sprintf "    %s %s → %s%s"
                          (if selected then "▸" else " ")
                          (binding_reference binding)
                          (Terminal_text.single_line binding.cb_keeper_name)
                          (if here then "  (this Keeper)"
                           else if missing_keeper then
                             "  (MISSING KEEPER · e reassign · u u remove)"
                           else "")
                      in
                      if selected then Ansi.reverse ^ line ^ Ansi.reset
                      else if missing_keeper then
                        (Theme.bad ()) ^ line ^ Ansi.reset
                      else line)
                    connector.cn_bindings
                  |> function
                  | [] -> [ Ansi.dim ^ "    (no channel bindings)" ^ Ansi.reset ]
                  | lines -> lines
                in
                [ ""
                ; Ansi.bold ^ "  Selected · "
                  ^ Terminal_text.single_line connector.cn_display_name
                  ^ Ansi.reset
                ; Printf.sprintf "  %-18s %s" "Binding target"
                    (match selected_binding with
                     | None -> "(no binding selected)"
                     | Some binding -> binding_reference binding)
                ; Printf.sprintf "  %-18s %s · %s" "Connection"
                    (connection_label connector)
                    (Terminal_text.single_line connector.cn_status)
                ; Printf.sprintf "  %-18s %s" "MASC API"
                    (Printf.sprintf "%s:%d"
                       Masc_network_defaults.masc_http_loopback_peer state.port)
                ; Printf.sprintf "  %-18s %s" "Channel type"
                    (Terminal_text.single_line_or ~default:"-" connector.cn_channel)
                ]
                @ optional_row "Runtime state" runtime_state
                @ optional_row "Status source" connector.cn_status_source
                @ optional_row "Remote endpoint" connector.cn_endpoint
                @ optional_row "Status file" connector.cn_status_path
                @ optional_row "Binding store" connector.cn_binding_store_path
                @ optional_row "Store state" store_state
                @ optional_row "Binding source" connector.cn_binding_source
                @ optional_row "Trigger policy" connector.cn_trigger_policy
                @ optional_row "Reply mode" connector.cn_reply_mode
                @ optional_row "Chat database" connector.cn_chat_db_path
                @ optional_row "Bot user" connector.cn_bot_user_name
                @ optional_row "Bot user id" connector.cn_bot_user_id
                @ optional_bool_row "Bot token ready" connector.cn_bot_token_present
                @ optional_bool_row "App token ready" connector.cn_app_token_present
                @ optional_bool_row "Gate healthy" connector.cn_gate_healthy
                @ optional_int_row "Server pid" connector.cn_pid
                @ optional_int_row "Guilds" connector.cn_guild_count
                @ optional_row "Directory state"
                    (Option.map
                       (function
                         | Tui_decode.Connector_directory_not_started ->
                           "not started"
                         | Connector_directory_refreshing -> "refreshing"
                         | Connector_directory_complete -> "complete"
                         | Connector_directory_partial -> "partial")
                       connector.cn_directory_state)
                @ optional_int_row "Servers learned"
                    connector.cn_directory_server_count
                @ optional_int_row "Channels learned"
                    connector.cn_directory_channel_count
                @ optional_int_row "People learned"
                    connector.cn_directory_person_count
                @ (match connector.cn_directory_authentication_failed with
                   | [] -> []
                   | values ->
                     [ Printf.sprintf "  %-18s %s" "Authentication"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     ])
                @ (match connector.cn_directory_permission_denied with
                   | [] -> []
                   | values ->
                     [ Printf.sprintf "  %-18s %s" "Permission limits"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     ])
                @ (match connector.cn_directory_errors with
                   | [] -> []
                   | values ->
                     [ Printf.sprintf "  %-18s %s" "Directory errors"
                         (String.concat "; "
                            (List.map Terminal_text.single_line values))
                     ])
                @ optional_row "Directory updated"
                    connector.cn_directory_updated_at
                @ optional_row "Workspace id" connector.cn_workspace_id
                @ optional_row "Server names" connector.cn_server_names_path
                @ optional_row "Channel names" connector.cn_channel_names_path
                @ optional_row "People names" connector.cn_people_names_path
                @ optional_row "Mapping scope" connector.cn_name_mapping_scope
                @ optional_row "Names read error" connector.cn_names_error
                @ optional_row "Updated" connector.cn_updated_at
                @ optional_row "Connection error" connector.cn_error
                @ optional_row "Store error" connector.cn_binding_store_error
                @ [ ""; Ansi.bold ^ "  Channel → Keeper bindings" ^ Ansi.reset ]
                @ binding_lines
                @ (match connector.cn_name_mappings with
                   | [] -> []
                   | mappings ->
                       [ ""; Ansi.bold ^ "  Known ID ↔ names" ^ Ansi.reset ]
                       @ List.map
                           (fun (mapping : Tui_decode.connector_name_mapping) ->
                              Printf.sprintf "    %-7s %s ↔ %s"
                                (match mapping.cnm_kind with
                                 | Tui_decode.Connector_channel_name -> "channel"
                                 | Connector_person_name -> "person"
                                 | Connector_server_name -> "server")
                                (Terminal_text.single_line mapping.cnm_id)
                                (Terminal_text.single_line mapping.cnm_name))
                           mappings)
                @ [ ""
                  ; Ansi.dim
                    ^ "  j/k transport · J/K binding · b bind · e reassign · u u remove"
                    ^ Ansi.reset
                  ; Ansi.dim
                    ^ "  These actions change channel routing, not the connector process."
                    ^ Ansi.reset
                  ; Ansi.dim ^ "  PgUp/PgDn scrolls this detail" ^ Ansi.reset
                  ; Ansi.dim ^ "  r reloads bindings and learned names" ^ Ansi.reset
                  ]
          in
          [ Printf.sprintf "  %d transports · %d available · actions target %s"
              snapshot.cs_total snapshot.cs_active
              (Terminal_text.single_line k.k_name)
          ]
          @ (match error with
             | None -> []
             | Some detail ->
                 [ (Theme.bad ()) ^ "  refresh failed: "
                   ^ Terminal_text.single_line detail ^ Ansi.reset
                 ])
          @ transport_rows @ selected_lines
    in
    let automation_lines =
      (* This tab reads the Keeper's own page from the server rather than
         filtering the fleet page: that page caps at its own limit with active
         rows first, so a Keeper whose schedules are terminal or further down
         was absent from it and the tab said none existed. The page it asks for
         can still truncate, which is why the absence reading stays. *)
      match state.keeper_schedules_error, state.keeper_schedules with
      | Some (keeper_name, err), _ when String.equal keeper_name k.k_name ->
          [ (Theme.bad ()) ^ "  schedules unavailable: "
            ^ Terminal_text.single_line err ^ Ansi.reset ]
      | _, Some (keeper_name, snapshot) when String.equal keeper_name k.k_name ->
          let rows = snapshot.scs_rows in
          if not (String.equal snapshot.scs_status "ok") then
            [ (Theme.bad ())
              ^ (match snapshot.scs_read_error with
                 | Some err -> "  " ^ Terminal_text.single_line err
                 | None -> "  (schedule store unreadable)")
              ^ Ansi.reset ]
          else if rows = [] then
            match
              Render_schedule.classify_keeper_schedule_absence
                ~truncated:snapshot.scs_truncated
                ~shown:(List.length snapshot.scs_rows)
                ~total:snapshot.scs_request_count
            with
            | Render_schedule.Store_has_none ->
                [ Ansi.dim ^ "  (no schedules for this Keeper)" ^ Ansi.reset ]
            | Render_schedule.Page_capped { shown; total } ->
                let of_total =
                  match total with
                  | Some total -> Printf.sprintf " -- %d of %d requests" shown total
                  | None -> ""
                in
                [ Ansi.dim
                  ^ Printf.sprintf
                      "  (none on the page the server sent%s; open Schedules \
                       for the full list)"
                      of_total
                  ^ Ansi.reset
                ]
          else
            List.map
              (fun (row : schedule_row) ->
                 Printf.sprintf "  %-12s %-18s %s"
                   (Terminal_text.single_line row.sch_status)
                   (Terminal_text.single_line row.sch_recurrence_summary)
                   (Terminal_text.single_line
                      (Option.value ~default:row.sch_schedule_id row.sch_payload_summary)))
              rows
      | _, _ ->
          [ Ansi.dim ^ "  (loading this Keeper's schedules…)" ^ Ansi.reset ]
    in
    let run_lines =
      match state.fusion_runs with
      | None -> [ Ansi.dim ^ "  (loading this Keeper's Fusion runs…)" ^ Ansi.reset ]
      | Some snapshot ->
          let runs =
            List.filter
              (fun (run : Tui_decode.fusion_run) -> String.equal run.fur_keeper k.k_name)
              snapshot.fus_runs
          in
          if runs = [] then [ Ansi.dim ^ "  (no retained Fusion runs for this Keeper)" ^ Ansi.reset ]
          else
            List.map
              (fun (run : Tui_decode.fusion_run) ->
                 Printf.sprintf "  %-12s %-16s %s"
                   (Tui_decode.fusion_run_status_to_string run.fur_status)
                   (Terminal_text.single_line run.fur_preset)
                   (Terminal_text.single_line run.fur_run_id))
              runs
    in
    let all_lines =
      match state.detail_tab with
      | Detail_info -> info_lines
      | Detail_sandbox ->
          let width = max 24 (cols - 8) in
          let status =
            stamped_or
              (Option.map
                 (fun (stamp, reading) ->
                   stamp, Masc_tui_keeper_sandbox.view_lines ~width reading)
                 state.keeper_sandbox_view)
              state.keeper_sandbox_view_error
          in
          let logs =
            match state.keeper_sandbox_logs_inflight with
            | Some (keeper_name, _) when String.equal keeper_name k.k_name ->
              [ Ansi.dim ^ "  (loading actual container logs…)" ^ Ansi.reset ]
            | Some _ | None ->
              match state.keeper_sandbox_logs_error with
              | Some (stamp, detail) when String.equal stamp k.k_name ->
                [ (Theme.bad ()) ^ "  Container logs unavailable: "
                  ^ Terminal_text.single_line detail ^ Ansi.reset
                ]
              | Some _ | None ->
                (match state.keeper_sandbox_logs with
                 | Some (stamp, logs) when String.equal stamp k.k_name ->
                   Masc_tui_keeper_sandbox.logs_view_lines ~width logs
                   |> List.map (fun line -> "  " ^ line)
                 | Some _ | None -> [])
          in
          status @ logs
      | Detail_instructions ->
          stamped_or state.keeper_config_view state.keeper_config_view_error
      | Detail_secrets -> secret_lines state k
      | Detail_github ->
          stamped_or state.github_identity_view
            state.github_identity_view_error
      | Detail_identity ->
          stamped_or
            (Option.map
               (fun (stamp, providers) ->
                 (stamp, identity_lines state k ~cols providers))
               state.identity_view)
            state.identity_view_error
      | Detail_channels -> channel_lines
      | Detail_automation -> automation_lines
      | Detail_runs -> run_lines
    in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title, with the tab walk on the same row so the chrome height the
       scroll math counts does not move. *)
    let tabs =
      Masc_tui_types.keeper_detail_tabs
      |> List.map (fun tab ->
             let label = Masc_tui_types.keeper_detail_tab_label tab in
             if tab = state.detail_tab then
               Ansi.bold ^ Ansi.underline ^ label ^ Ansi.reset
             else Ansi.dim ^ label ^ Ansi.reset)
      |> String.concat "  "
    in
    let tab_hint = Masc_tui_keys.keeper_detail_tab_hint state.detail_tab in
    let title =
      Printf.sprintf " Keepers \xe2\x96\xb8 %s%s%s   %s   %s%s%s" Ansi.bold
        (Terminal_text.single_line k.k_name)
        Ansi.reset tabs Ansi.dim tab_hint Ansi.reset
    in
    box_line buf cols title;

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom); the indicator, when the content overflows, spends one
       content row rather than growing the pane, so the pane's height is
       rows - 1 in both cases and the split's two bottoms stay level. *)
    let base_height = max 0 (rows - framed_chrome_rows) in
    let content_height =
      if total_lines > base_height then max 0 (base_height - 1)
      else base_height
    in
    let visible_lines = min content_height total_lines in
    let scroll =
      Render_schedule.normalize_keeper_detail_scroll ~line_count:total_lines
        ~content_height state.detail_scroll
    in

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (List.nth all_lines idx)
      else
        box_empty buf cols
    done;

    (* Fill remaining space *)
    for _ = visible_lines to content_height - 1 do
      box_empty buf cols
    done;

    (* Scroll indicator *)
    if total_lines > content_height then begin
      let indicator = Printf.sprintf "%s[%d/%d]%s" Ansi.dim (scroll + 1) (total_lines - content_height + 1) Ansi.reset in
      box_line buf cols indicator
    end;

    (* Bottom border *)
    box_bottom buf cols;
    scroll

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
  for i = 0 to content_height - 1 do
    match List.nth_opt state.keepers (first + i) with
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


let render_keeper_detail (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_surface state ~surface_key:"keeper-detail" ~rows:terminal_rows
      ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let footer =
      keeper_action_hints state (Some (keeper_reading state k))
    in
    let footer =
      if keeper_roster_pane_shown state ~cols then "  h/l pane" ^ footer
      else footer
    in
    (* Cut to the terminal, the way every other footer is: [footer_line] takes
       [~max_cells] and this one never did. The row is about 150 cells wide
       across its fourteen hints, and the roster pane adds ten more in front,
       so on any ordinary terminal the tail went past the edge. Autowrap is off
       while a frame draws, so nothing moved -- the last hints were simply
       dropped by the terminal, silently, with the keys still working.
       [fit_width] counts cells rather than bytes and closes the style it cut
       through. *)
    let footer = Message_layout.fit_width footer (max 1 cols) in
    if not (keeper_roster_pane_shown state ~cols) then begin
      let scroll = keeper_detail_pane state k ~framed:false ~rows ~cols buf in
      Buffer.add_string buf (footer ^ "\n");
      finish_surface state ~clamped:(Keeper_detail scroll)
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
    else begin
      (* Wide terminals keep the roster in sight beside the detail. Both
         panes draw the same number of rows, so the zip below is a plain
         row-by-row join. *)
      let left_cols = keeper_roster_pane_cols in
      let right_cols = cols - left_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      keeper_roster_pane
        ~focused:(state.keeper_detail_focus = Left_pane)
        state ~rows ~cols:left_cols left_buf;
      let scroll =
        keeper_detail_pane state k ~framed:true ~rows ~cols:right_cols right_buf
      in
      write_two_panes buf ~left_cols:left_cols ~left:left_buf
        ~right:right_buf;
      Buffer.add_string buf (footer ^ "\n");
      finish_surface state ~clamped:(Keeper_detail scroll)
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_surface state ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header =
      Printf.sprintf "%s  (%d entries)"
        (screen_title
           (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 logs"
              (Terminal_text.single_line k.k_name)))
        total_entries
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* The names come from the same description as the readings, in the module
       that owns the widths. Written here, they were eight numbers away from
       the eight they named. *)
    box_line_styled buf cols ~style:(Theme.recede ())
      Observation_layout.plain_log_header;
    box_divider buf cols;

    (match state.log_error with
      | None -> ()
      | Some error ->
          let style =
            match error with
            | Metrics_tail.Storage_error _ -> (Theme.bad ())
            | Metrics_tail.Row_errors _ -> (Theme.warn ())
          in
          let diagnostic =
            Keeper_chat.terminal_safe_text
              (Metrics_tail.error_to_string error)
          in
          box_line_styled buf cols ~style
            ("  " ^ diagnostic);
          box_divider buf cols);

    (* Content area *)
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:state.log_error
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:total_entries ~content_height
        state.log_scroll
    in

    if total_entries = 0 then begin
      box_line_styled buf cols ~style:(Theme.recede ())
        ("  " ^ Metrics_tail.empty_message state.log_error);
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end else begin
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx < total_entries then begin
          let e = List.nth state.log_entries idx in
          (* Extract just the time portion from ts *)
          let time_str = Terminal_text.clock_timestamp e.le_ts in
          let tool_names = Terminal_text.single_lines e.le_tools_used in
          let tools_str =
            if List.length tool_names > 0 then
              " "
              ^ String.concat ","
                  (List.filteri (fun i _ -> i < 2) tool_names)
            else ""
          in
          let terminal_entry =
            { e with
              le_work_kind =
                Terminal_text.optional_single_line e.le_work_kind
            }
          in
          let line =
            Observation_layout.plain_log_row ~time:time_str terminal_entry
            ^ tools_str
          in
          box_line buf cols line
        end else
          box_empty buf cols
      done
    end;

    (* Scroll indicator *)
    if total_entries > content_height then begin
      let indicator =
        Printf.sprintf "[%d/%d entries, scroll %d]" total_entries total_entries
          scroll
      in
      box_line_styled buf cols ~style:(Theme.recede ()) indicator
    end;

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints state.view));

    finish_surface state ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end

(** Render message input/conversation view *)
let keeper_message_clock at =
  let time = Unix.localtime at in
  Printf.sprintf "%02d:%02d:%02d" time.Unix.tm_hour time.Unix.tm_min
    time.Unix.tm_sec
;;

let keeper_message_timeline_bucket at =
  let time = Unix.localtime at in
  ({ tb_year = time.Unix.tm_year + 1900;
     tb_month = time.Unix.tm_mon + 1;
     tb_day = time.Unix.tm_mday;
     tb_hour = time.Unix.tm_hour;
     tb_is_dst = time.Unix.tm_isdst;
   }
    : Message_layout.timeline_bucket)
;;

type keeper_call_association =
  | Call_log_not_loaded
  | Call_log_loading
  | Call_log_unavailable of string
  | Call_execution_unrecorded
  | Call_execution_missing
  | Call_execution_ambiguous of int
  | Call_execution_exact of Tui_decode.keeper_call

let keeper_call_association state ~keeper_name
    (activity : Keeper_chat_transcript.tool_activity) =
  match activity.execution_id with
  | None -> Call_execution_unrecorded
  | Some execution_id -> (
      if
        not
          (Option.equal String.equal state.keeper_calls_keeper
             (Some keeper_name))
      then Call_log_not_loaded
      else if state.keeper_calls_loading then Call_log_loading
      else
      match state.keeper_calls_error, state.keeper_calls with
      | Some detail, _ -> Call_log_unavailable detail
      | None, None -> Call_log_not_loaded
      | None, Some snapshot
        when not (String.equal snapshot.Tui_decode.kcs_keeper keeper_name) ->
          Call_log_not_loaded
      | None, Some snapshot ->
          let matches =
            List.filter
              (fun (call : Tui_decode.keeper_call) ->
                Option.equal String.equal call.kc_execution_id
                  (Some execution_id))
              snapshot.kcs_entries
          in
          match matches with
          | [] -> Call_execution_missing
          | [ call ] -> Call_execution_exact call
          | rows -> Call_execution_ambiguous (List.length rows))

(* The tool tree's colours, out of the reader's own theme. Built per draw
   rather than held: the palette behind [Theme.*] is resolved against the
   terminal's answers and can change, and a cached record would keep drawing
   the colours the last answer produced. *)
let tool_detail_palette () : Tool_detail.palette =
  { Tool_detail.branch = Theme.recede ()
    (* A field's name and a document member's name are the same kind of
       thing, so they read in the same colour; the weight is what separates
       the tree's own labels from the names inside a payload. *)
  ; label = Ansi.bold ^ Masc_tui_theme.tone Masc_tui_theme.Accent
  ; separator = Theme.recede ()
  ; key = Masc_tui_theme.Syntax.json_key
  ; string_ = Masc_tui_theme.Syntax.string_
  ; number = Masc_tui_theme.Syntax.json_number
  ; literal = Masc_tui_theme.Syntax.json_literal
  ; punctuation = Masc_tui_theme.Syntax.json_punctuation
  ; reset = Ansi.reset
  }

(* An outcome is a reading of state, so it draws through the status names
   rather than through the tree's own default. The two that are still moving
   read as attention; the two that stopped badly read as failure. *)
let tool_outcome_tone : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started | Keeper_chat_transcript.Awaiting_result ->
      Theme.info ()
  | Keeper_chat_transcript.Returned -> Theme.ok ()
  | Keeper_chat_transcript.Failed | Keeper_chat_transcript.Never_returned ->
      Theme.bad ()
  | Keeper_chat_transcript.Outcome_unrecorded -> Theme.warn ()

let tool_outcome_label : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started -> "RUNNING · ARGUMENTS STREAMING"
  | Keeper_chat_transcript.Awaiting_result -> "RUNNING · AWAITING RESULT"
  | Keeper_chat_transcript.Returned -> "RETURNED"
  | Keeper_chat_transcript.Failed -> "FAILED"
  | Keeper_chat_transcript.Never_returned -> "NEVER RETURNED"
  | Keeper_chat_transcript.Outcome_unrecorded -> "OUTCOME UNRECORDED"

let keeper_call_schedule_label (schedule : Tui_decode.keeper_call_schedule) =
  let execution =
    match schedule.kcs_execution_mode with
    | Tui_decode.Keeper_call_serial -> "serial"
    | Tui_decode.Keeper_call_concurrent -> "concurrent"
  in
  Printf.sprintf "%s · batch %d · width %d · plan step %d" execution
    (schedule.kcs_batch_index + 1) schedule.kcs_batch_size
    (schedule.kcs_planned_index + 1)

let keeper_message_tool_activity_details state ~keeper_name
    (activity : Keeper_chat_transcript.tool_activity) =
  let association = keeper_call_association state ~keeper_name activity in
  let schedule_field, disposition_field, durable_input, output_field,
      result_field =
    match association with
    | Call_execution_exact call ->
        let schedule =
          match call.kc_schedule with
          | Some schedule -> keeper_call_schedule_label schedule
          | None -> "not recorded"
        in
        let output =
          Option.map (fun value -> "output", value) call.kc_output
        in
        let disposition =
          match call.kc_disposition with
          | None -> None
          | Some Tui_decode.Keeper_call_completed ->
              Some ("dispatch", "COMPLETED · SYNCHRONOUS", Theme.ok ())
          | Some Tui_decode.Keeper_call_deferred ->
              Some ("dispatch", "DEFERRED · ASYNC CONTINUATION", Theme.info ())
          | Some Tui_decode.Keeper_call_failed ->
              Some ("dispatch", "FAILED", Theme.bad ())
        in
        let result =
          match call.kc_result_bytes, call.kc_truncated_to with
          | None, None -> None
          | result_bytes, truncated_to ->
              let parts =
                List.filter_map Fun.id
                  [ Option.map (Printf.sprintf "%d bytes") result_bytes
                  ; Option.map (Printf.sprintf "served through %d bytes")
                      truncated_to
                  ]
              in
              Some ("result", String.concat " · " parts)
        in
        (schedule, disposition, call.kc_input, output, result)
    | Call_log_not_loaded ->
        "open full calls to load durable schedule", None, activity.args, None,
        None
    | Call_log_loading ->
        "loading durable schedule…", None, activity.args, None, None
    | Call_log_unavailable detail ->
        "unavailable · " ^ detail, None, activity.args, None, None
    | Call_execution_unrecorded ->
        "execution id not recorded", None, activity.args, None, None
    | Call_execution_missing ->
        "no durable row for this execution id", None, activity.args, None, None
    | Call_execution_ambiguous count ->
        Printf.sprintf "%d durable rows share this execution id" count,
        None, activity.args, None, None
  in
  let provider_call_id =
    match association with
    | Call_execution_exact call ->
        (match call.kc_tool_use_id with
         | Some _ as recorded -> recorded
         | None -> activity.call_id)
    | Call_log_not_loaded | Call_log_loading | Call_log_unavailable _
    | Call_execution_unrecorded | Call_execution_missing
    | Call_execution_ambiguous _ ->
        activity.call_id
  in
  let identity =
    List.filter_map Fun.id
      [ Option.map (fun value -> "execution=" ^ value) activity.execution_id
      ; Option.map (fun value -> "provider-call=" ^ value) provider_call_id
      ]
    |> function
    | [] -> "not recorded"
    | parts -> String.concat " · " parts
  in
  (* Which fields are readings of state and which are payloads, said once
     here. The tree draws a payload through the document roles and a reading
     through the tone this names; nothing downstream guesses from the label. *)
  let said label value tone =
    { Tool_detail.fd_label = label
    ; fd_value = Tool_detail.Text value
    ; fd_tone = tone
    }
  in
  let served label value =
    { Tool_detail.fd_label = label
    ; fd_value = Tool_detail.Document value
    ; fd_tone = ""
    }
  in
  let fields =
    [ Some
        (said "state"
           (tool_outcome_label activity.outcome)
           (tool_outcome_tone activity.outcome))
    ; Option.map
        (fun (label, value, tone) -> said label value tone)
        disposition_field
      (* The tool's own name, in the colour the pane already gives a tool
         row's origin. Not a status: naming Execute is not a verdict on it. *)
    ; Some (said "tool" activity.tool_name (Theme.tool_origin ()))
    ; Some (said "schedule" schedule_field "")
    ; Some
        (if String.equal durable_input "" then said "input" "(empty)" ""
         else served "input" durable_input)
    ; Option.map (fun (label, value) -> served label value) output_field
    ; Option.map (fun (label, value) -> said label value "") result_field
    ; Some (said "identity" identity "")
    ]
    |> List.filter_map Fun.id
  in
  Tool_detail.tree ~palette:(tool_detail_palette ()) fields

(* How one finished turn's tool block becomes rows: the operator's
   compact/full choice, the width the aligned badge leaves, and this keeper's
   own file changes. The committed history and the turn still streaming both
   ask this, so a diff folded into the history and the same diff arriving live
   cannot be projected two ways. *)
let keeper_message_tool_rows (state : state) ~keeper_name ~chat_cols projection =
  let role_label_column =
    Message_layout.chat_role_label_width ~pane_cells:chat_cols
  in
  let file_change_index =
    if Option.equal String.equal state.msg_file_changes_keeper (Some keeper_name)
    then state.msg_file_change_index
    else Keeper_chat_diff.empty
  in
  let mode = tool_projection_mode state in
  let rows =
    Keeper_chat_diff.rows
    ~mode
    ~max_line_cells:(max 24 (min 120 (chat_cols - role_label_column - 8)))
    ~activity_details:(keeper_message_tool_activity_details state ~keeper_name)
    file_change_index projection
  in
  (* The fold says how many rows it is holding; the key that opens them is in
     the footer, on every frame, next to the other five. Repeating it on the
     row cost thirty-eight cells of the widest line in the pane, and a screen
     with four tool blocks carried the same sentence four times -- which is
     what pushed the tool names onto a second line and broke the read of the
     conversation they sit inside. *)
  rows

(* Every committed row of one keeper's conversation, as the layout entries the
   pane draws -- the grouping, the aligned badges, the tool projections, and
   the link labels appended under each body.

   Lifted out of [render_keeper_message] so it has a second reader. A search
   over this conversation has to land the pane on a row, and a row position
   here is measured in the physical rows these entries render to; anything
   that computed it from the message list alone would be measuring a different
   document from the one on screen. The renderer never mutates state, so the
   search cannot live inside it either.

   Committed rows only. The turn still streaming is built where it is drawn:
   its row count changes on every frame, which is exactly what a stable
   position must not be measured against. *)
(* The timeline moments of one row list, computed once per list.

   [chat_projected_timeline_ats] walks the whole list with a floor per
   request id, and the chat frame asked for it twice per frame on the same
   rows: once to draw and once through [keeper_message_layout_entries]. The
   rows come from [chat_rows_for], which returns the same list until the
   conversation changes, so the list's physical identity is the key. A list
   built elsewhere (a search over a slice) replaces the slot and the next
   frame computes once more; nothing is kept stale. *)
let chat_timeline_ats_memo :
    (Masc_tui_types.msg_entry list
    * (Masc_tui_types.msg_entry * float option) list)
    option
    ref =
  ref None

let chat_rows_with_timeline_ats messages =
  match !chat_timeline_ats_memo with
  | Some (key, combined) when key == messages -> combined
  | Some _ | None ->
      let combined =
        List.combine messages (chat_projected_timeline_ats messages)
      in
      chat_timeline_ats_memo := Some (messages, combined);
      combined

(* The visibility-filtered timeline of one row list, computed once per list
   and visibility pair.

   The chat frame asks for this twice on the same inputs: once to place the
   live turn and once through [keeper_message_layout_entries]. The filter
   walks every committed row on every key, and its answer depends only on the
   row list -- replaced, not mutated, when the conversation changes -- and the
   two visibility readings, so those three are the key. Same scoping as
   [chat_timeline_ats_memo] above: a frame with different rows or a toggled
   visibility replaces the slot, and nothing is kept stale. *)
type visible_timeline_memo = {
  vtm_messages : msg_entry list;
  vtm_memory : memory_visibility;
  vtm_reasoning : reasoning_visibility;
  vtm_timeline : (msg_entry * float option) list;
}

let visible_timeline_memo : visible_timeline_memo option ref = ref None

let keeper_message_visible_timeline ?messages (state : state) ~keeper_name =
  let messages =
    match messages with
    | Some messages -> messages
    | None -> chat_rows_for state keeper_name
  in
  match !visible_timeline_memo with
  | Some memo
    when memo.vtm_messages == messages
         && memo.vtm_memory = state.msg_memory_visibility
         && memo.vtm_reasoning = state.msg_reasoning_visibility ->
      memo.vtm_timeline
  | Some _ | None ->
      let timeline =
        chat_rows_with_timeline_ats messages
        |> List.filter (fun (message, _) ->
          state.msg_memory_visibility <> Memory_hidden
          || message.me_role <> Message_memory)
        |> List.filter (fun (message, _) ->
          message.me_role <> Message_thinking
          || Masc_tui_types.reasoning_drawn state.msg_reasoning_visibility)
        |> Masc_tui_types.fold_memory_summary_runs
             ~visibility:state.msg_memory_visibility
        (* After the filters, so a hidden lane between two Gate rows does not
           split their run and draw the same approval twice. *)
        |> Masc_tui_types.fold_gate_runs
      in
      visible_timeline_memo :=
        Some
          { vtm_messages = messages;
            vtm_memory = state.msg_memory_visibility;
            vtm_reasoning = state.msg_reasoning_visibility;
            vtm_timeline = timeline;
          };
      timeline
;;

let keeper_message_visible_messages ?messages (state : state) ~keeper_name =
  keeper_message_visible_timeline ?messages state ~keeper_name
  |> List.map fst
;;

(* Which piece of its turn's bracket a row draws.

   [Turn_alone] draws nothing. One row is not a hierarchy, and marking it would
   put a rail on nearly every row of ordinary chatter, which is where a reader
   stops seeing it at all.

   The split between speech and work is the fact the pane was missing.
   Reasoning, tool calls and skills are what a turn did to arrive at what it
   said, and they were drawn at the same depth as the answer -- same column,
   same indent, same clock -- so a turn's work read as a sibling of its speech.
   They hang off the trunk instead. *)
(* Which siding a row came in on, or [None] when it is not an arrival.

   Exhaustive on purpose: a new row kind has to say whether it arrived from
   outside, and the compiler is the only thing that will ask.

   [Sent_by_operator] is not here. A prompt the operator sent from another
   surface did arrive from outside, but which surface is in the label's text
   and not in the constructor, and reading it back out of the string is the
   pane deciding something the type never recorded. *)
let siding_of_message (message : Masc_tui_types.msg_entry) =
  match message.me_role with
  | Masc_tui_types.Message_memory -> Some Message_layout.Siding_journal
  | Masc_tui_types.Message_user (Masc_tui_types.Sent_by_other _) ->
      Some Message_layout.Siding_arrival
  | Masc_tui_types.Message_user (Masc_tui_types.Sent_by_operator _)
  | Masc_tui_types.Message_keeper | Masc_tui_types.Message_autonomous
  | Masc_tui_types.Message_status | Masc_tui_types.Message_local
  | Masc_tui_types.Message_error | Masc_tui_types.Message_tool
  | Masc_tui_types.Message_skill _ | Masc_tui_types.Message_thinking ->
      None

(* [siding] only reaches the rail through [Turn_outside]: a row that owns a
   request is on the line whoever sent it, and a broadcast that opened a turn
   is that turn's first row rather than something beside it. *)
let turn_rail_of ~siding ~(edge : Masc_tui_types.turn_edge)
    ~(style : Message_layout.style) =
  match edge with
  | Turn_outside -> (
      match siding with
      | Some siding -> Message_layout.Rail_joins siding
      | None -> Message_layout.Rail_none)
  | Turn_alone -> Message_layout.Rail_none
  | Turn_opens -> Message_layout.Rail_opens
  | Turn_closes -> Message_layout.Rail_closes
  | Turn_continues -> (
      match style with
      | Message_layout.Tool | Message_layout.Skill _ | Message_layout.Thinking
        ->
          Message_layout.Rail_does
      | Message_layout.User | Message_layout.Inbound | Message_layout.Keeper
      | Message_layout.Status | Message_layout.Local | Message_layout.Journal
      | Message_layout.Error ->
          Message_layout.Rail_says)

let compute_keeper_message_layout_entries (state : state) ~keeper_name
    ~chat_cols ~start_index visible_entries =
  (* Derived once for the width and again per row, so the badge the pane
     measures is the badge it draws. *)
  let base_role_label_of (message : Masc_tui_types.msg_entry) =
    match message.me_role with
    | Message_user (Sent_by_other name) -> name
    | Message_user (Sent_by_operator label) ->
        (* Pending input is not a transcript row. Once it enters a turn this
           label can say YOU without a second queue lookup or a transient
           QUEUED identity that later changes underneath it. *)
        if String.equal label "you" then "YOU"
        else label
    | Message_keeper -> Keeper_chat.terminal_safe_text message.me_keeper_name
    | Message_autonomous -> Keeper_chat.terminal_safe_text message.me_keeper_name
    | Message_status -> "STATUS"
    | Message_local -> "LOCAL"
    | Message_error -> "ERROR"
    | Message_tool -> "TOOLS"
    | Message_skill _ -> "SKILL"
    | Message_thinking -> "THINKING"
    | Message_memory -> "JOURNAL"
  in
  (* Turn identity stays in the typed request id. The speaker glyph already
     distinguishes USER, Keeper, Tool, Skill, and Journal, so prefixes such as
     [TURN ·] and [↳] repeated or obscured the same fact instead of clarifying
     it. Adjacent rows from the exact same request still fold as continuations
     in [Message_layout]; a row resuming after another lane names its source
     again. *)
  (* Who asked for a turn is one fact per turn, not one per row. It was the
     speaker label on every autonomous row, so the same keeper answered as
     itself when a person asked and as AUTO when nobody did -- two speakers for
     one keeper, interleaved with broadcasts and journal commits on one clock.
     The turn's opening row says it; the rows continuing that turn read as the
     keeper, like every other answer it gives. *)
  let role_label_of message edge =
    match message.Masc_tui_types.me_role with
    | Message_autonomous -> (
        match edge with
        | Masc_tui_types.Turn_opens | Masc_tui_types.Turn_alone -> "AUTO"
        | Masc_tui_types.Turn_continues | Masc_tui_types.Turn_closes
        | Masc_tui_types.Turn_outside ->
            base_role_label_of message)
    | _ -> base_role_label_of message
  in
  let projected_tool_rows =
    keeper_message_tool_rows state ~keeper_name ~chat_cols
  in
  let role_label_column =
    Message_layout.chat_role_label_width ~pane_cells:chat_cols
  in
  let layout_entries =
    (* The position distinguishes rows whose durable timestamp and request
       fields tie. A history reorder can only cause a miss: the exact body is
       another cache-key field, so an index never authorizes stale rows. *)
    List.mapi
      (fun offset (message, timeline_at, edge) ->
        let entry_index = start_index + offset in
        let grouped_role_label = role_label_of message edge in
        (* Projected once: the style is read off it and the body is built
           from it, and projecting twice would let a fold decide the colour
           from one reading and the text from another. *)
        let tool_projection =
          match message.me_role with
          | Message_tool -> (
              match message.me_tool_block with
              | None -> None
              | Some block ->
                  Some
                    (Keeper_chat_transcript.project_tool_block
                       (tool_projection_mode state) block))
          | Message_user _ | Message_keeper | Message_autonomous
          | Message_status | Message_local | Message_memory | Message_error
          | Message_skill _ | Message_thinking ->
              None
        in
        let style =
          match message.me_role with
          | Message_user (Sent_by_operator _) -> Message_layout.User
          | Message_user (Sent_by_other _) -> Message_layout.Inbound
          | Message_keeper | Message_autonomous -> Message_layout.Keeper
          | Message_status -> Message_layout.Status
          | Message_local -> Message_layout.Local
          | Message_memory -> Message_layout.Journal
          | Message_error -> Message_layout.Error
          | Message_tool -> (
              match tool_projection with
              | None -> Message_layout.Tool
              | Some projection -> tool_block_style projection)
          | Message_skill state ->
              Message_layout.Skill (skill_tone_of_state state)
          | Message_thinking -> Message_layout.Thinking
        in
        let role_label = grouped_role_label in
        (* One column for every speaker so the [timestamp] speaker request
           rows line up down the pane, whatever name each row carries. *)
        let role_label =
          Message_layout.align_role_label ~column:role_label_column ~style
            role_label
        in
        let body =
          match message.me_role with
          | Message_thinking
            when state.msg_reasoning_visibility = Reasoning_folded ->
              folded_thinking_summary message.me_text
          | Message_skill _ -> (
              match message.me_skill_activity with
              | None -> message.me_text
              (* Always full, not tied to [msg_tool_visibility]: a skill row is
                 one of ours, and whether a served skill was actually delivered
                 and used is the fact the row exists to carry. Folding it behind
                 the tool toggle made "SERVED ONLY vs DELIVERED · USED" the same
                 keystroke away as a docker exec's schedule, so the operator saw
                 only a name and a state and had to expand to learn if the skill
                 did anything. A skill has few rows (the action list and one
                 proof line), so showing them costs little and the toggle still
                 governs the tool projections beside it. *)
              | Some activity ->
                  Keeper_chat_transcript.skill_rows ~full:true activity
                  |> String.concat "\n")
          (* The Memory journal's change arrives inside a ["```diff"]
             fence, so a leading [+] is fence content rather than a list
             marker and needs no escaping. The escape that used to be here
             was never consumed by the renderer, so what reached the pane
             was a literal backslash in front of every changed fact. *)
          | Message_tool -> (
              match tool_projection with
              | None -> message.me_text
              | Some projection ->
                  String.concat "\n" (projected_tool_rows projection))
          | Message_memory -> (
              match state.msg_memory_visibility with
              (* Summary uses the producer's typed compact projection. Hidden
                 rows never reach this arm (the layout filter removed them),
                 and a neutral system row with no projection remains whole. *)
              | Memory_full | Memory_hidden -> message.me_text
              | Memory_summary -> (
                  match message.me_memory_summary with
                  | Some summary -> summary ^ " · Ctrl-N: journal detail"
                  | None -> message.me_text))
          | Message_thinking | Message_user _ | Message_keeper
          | Message_autonomous
          | Message_status | Message_local | Message_error ->
              message.me_text
        in
        (* What the links in this message point at, on rows of their own
           under it. Added here because this is before the layout wraps:
           the pane's own link styling runs after wrapping and cannot add a
           cell without moving the row it sits on.

           Read out of the URL and never fetched. A keeper writes these
           links, and following one because it was mentioned would turn
           anything a keeper says into traffic this process sends.

           Not on a tool block. Tool output arrives already structured and
           already long, and a bare URL there sits in a row that says what
           it is; a URL in prose is the one standing on its own. *)
        let body =
          match message.me_role with
          | Message_tool | Message_skill _ -> body
          | Message_thinking | Message_user _ | Message_keeper
          | Message_autonomous | Message_status | Message_local
          | Message_error | Message_memory -> (
              let seen = Hashtbl.create 4 in
              let urls =
                Message_layout.bare_urls body
                |> List.filter (fun u ->
                       if Hashtbl.mem seen u then false
                       else begin
                         Hashtbl.add seen u ();
                         true
                       end)
              in
              match urls with
              | [] -> body
              | urls -> (
                  match state.link_previews_mode with
                  | `Off -> body
                  | `Compact ->
                      let badges =
                        List.filter_map
                          (fun u ->
                             let p = Masc_tui_link_preview.get_preview u in
                             Masc_tui_link_preview.render_compact_badge p)
                          urls
                      in
                      (match badges with
                       | [] -> body
                       | _ -> body ^ "\n" ^ String.concat "\n" badges)
                  | `Rich ->
                      let inner = max 20 (chat_cols - role_label_column - 6) in
                      let cards =
                        List.filter_map
                          (fun u ->
                             let p = Masc_tui_link_preview.get_preview u in
                             if Masc_tui_link_preview.has_informative_preview p then
                               Some (String.concat "\n" (Masc_tui_link_preview.render_inline_card ~width:inner p))
                             else None)
                          urls
                      in
                      (match cards with
                       | [] -> body
                       | _ -> body ^ "\n" ^ String.concat "\n" cards)))
        in
        ({ style;
             timestamp =
               Option.fold ~none:message.me_timestamp
                 ~some:keeper_message_clock timeline_at;
             timeline_bucket =
               Option.map keeper_message_timeline_bucket
                 timeline_at;
             role_label;
             role_label_mark_cells =
               Message_layout.role_label_mark_cells
                 ~column:role_label_column ~style ();
             request_label =
               Keeper_chat.compact_request_id message.me_request_id;
             body;
             markdown_source =
               Message_layout.Markdown_stable
                 { keeper_name = message.me_keeper_name;
                   request_id = message.me_request_id;
                   observed_at = message.me_at;
                   entry_index;
                 };
             turn_rail =
               turn_rail_of ~siding:(siding_of_message message) ~edge ~style;
           }
            : Message_layout.entry))
      visible_entries
  in
  layout_entries

(* One conversation's layout entries, reused per message across a change of
   the conversation.

   #32878 memoized this list whole: any landed message replaced the row
   list, and the next frame rebuilt an entry for every visible message --
   the safe text, the aligned badge, the link scan of the whole body, and a
   tool projection whose durable-call association filters the call snapshot
   per row. In an active chat, where a row lands every few seconds while
   the operator types, nearly every frame paid for the whole transcript.
   An entry is a pure function of one message and the readings below, so a
   frame whose conversation moved recomputes only the positions that
   actually moved; the rest are taken over unchanged.

   The full list of what one entry reads, and what busts its reuse:

   - the message record, compared by physical identity. Every field an
     entry is built from -- role, text, keeper name, tool block, skill
     activity, memory summary, request id, durable timestamp, observed-at --
     is a field of this record, and the row pipeline ([chat_timeline_slots],
     [chat_timeline_rows], the visibility filter) passes records through
     untouched: a conversation change replaces records rather than mutating
     them, the same contract [chat_rows_memo] and [chat_timeline_ats_memo]
     already rely on. A row rewritten in place (a queued line edited before
     sending) arrives as a fresh record and misses;
   - the entry's position in the visible timeline, baked into
     [markdown_source] as [entry_index]. The walk below compares
     positionally, so a reused entry's index is its position by
     construction; a removal or insertion above it ends the shared prefix
     and the tail is recomputed with its new indices;
   - the projected timeline moment for that position, from
     [chat_projected_timeline_ats]: a per-request floor over the whole row
     list in list order, so a row sorting in above (a late tool row joining
     its turn) can move the floor for later rows of that request. The walk
     compares the moment by value at every position, and a moved floor ends
     the sharing there;
   - the row's turn edge, from [mark_turn_edges]: whether the row opens,
     continues, closes, or is its whole turn, which the role label of an
     autonomous row reads ([AUTO] only where a turn opens). The edge of a
     position is a function of where its request's first and last rows sit
     in the visible list, so an append to an open turn flips the edge of
     the turn's previous last row; the walk compares the edge by value at
     every position, and a flipped edge ends the sharing there;
   - the keeper, the pane width, and the memory/reasoning/tool visibility
     readings, compared by value. The width decides the badge column and
     the tool-row wrap; the visibilities decide the folded thinking body,
     the journal summary body, and the compact/full tool projection (memory
     and reasoning also decide which rows the visible timeline holds at
     all, which the position comparison then sees);
   - this keeper's file-change index and durable-call snapshot readings,
     replaced wholesale when a load lands, so physical identity says whether
     they moved; the tool detail rows read both;
   - the terminal palette generation, because the tool detail rows bake the
     resolved colours into their text and a palette that arrived after
     start-up must not keep drawing the previous answer's escapes.

   Deliberately not inputs: the scroll position and the origin-display mode
   act after the entries exist ([rows_of_entry] takes them), the live turn
   is built where it is drawn, and [keeper_message_clock]'s timezone is the
   process's own for its whole life -- the assumption the whole-list memo
   already made.

   The reuse is a parallel walk over the previous and current visible
   timelines: while the record, the projected moment, and the turn edge at
   a position all agree, the entry computed for it is taken over; from the
   first position that differs, the tail is computed fresh. An append --
   the common case, every committed row landing at the newest end --
   therefore computes one entry, or two when it closes a turn's previous
   last row; a mid-list insertion recomputes the suffix below it, which
   during a live turn is the turn still settling. [Lazy.t] inside the entry
   was considered so a constructed-but-unviewed entry could skip its link
   scan and tool rows, but entries are constructed off the visible slice
   only when the readings above change wholesale -- first load, an older
   page prepending, a visibility toggle, a resize -- never on the
   per-message path this memo exists for, and a lazy [body] would change
   [Message_layout.entry] for every reader to serve a path that already
   runs once per change.

   One slot holding one conversation's entries, replaced wholesale when any
   reading changes: nothing accumulates across keepers, widths, or palette
   generations, and nothing is kept stale. Module state rather than a field
   on [state], like [chat_rows_memo]: a derived reading is not authority,
   and the input layer would otherwise have to invalidate it at every
   mutation site. *)
type layout_entries_memo = {
  lem_keeper_name : string;
  lem_chat_cols : int;
  lem_memory : memory_visibility;
  lem_reasoning : reasoning_visibility;
  lem_tools : tool_visibility;
  lem_file_changes_keeper : string option;
  lem_file_change_index : Keeper_chat_diff.index;
  lem_calls_keeper : string option;
  lem_calls_loading : bool;
  lem_calls_error : string option;
  lem_calls : keeper_calls_snapshot option;
  lem_palette_generation : int;
  lem_visible_timeline : (msg_entry * float option) list;
  lem_visible_entries : (msg_entry * float option * turn_edge) list;
  lem_entries : Message_layout.entry list;
}

let layout_entries_memo : layout_entries_memo option ref = ref None

(* The visible timeline with each row's turn edge beside it. Marking the
   edges walks the list once, so it runs only when the timeline actually
   changed; the identical-frame path below answers on the timeline's
   physical identity without paying it. *)
let keeper_message_visible_entries visible_timeline =
  let edges =
    List.map snd (Masc_tui_types.mark_turn_edges (List.map fst visible_timeline))
  in
  List.map2
    (fun (message, timeline_at) edge -> (message, timeline_at, edge))
    visible_timeline edges
;;

(* Positions whose message record, projected moment, and turn edge all
   survived a conversation change keep the entry already computed for them.
   The first position that differs ends the sharing, because the index
   baked into [markdown_source], the per-request floor walked in list
   order, and the first/last marking an edge reads are each only as good as
   every position above them. The suffix goes back as the tail cell it was
   found at, so a caller can tell "nothing shared" by physical identity
   rather than by measuring. *)
let rec shared_layout_entry_prefix reversed old_visible old_entries
    new_visible =
  match old_visible, old_entries, new_visible with
  | (old_message, old_at, old_edge) :: old_visible_rest,
    entry :: old_entries_rest,
    (message, timeline_at, edge) :: new_visible_rest
    when old_message == message
         && Option.equal Float.equal old_at timeline_at
         && old_edge = edge ->
      shared_layout_entry_prefix (entry :: reversed) old_visible_rest
        old_entries_rest new_visible_rest
  | _ -> List.rev reversed, new_visible
;;

let keeper_message_layout_entries ?messages (state : state) ~keeper_name
    ~chat_cols =
  let messages =
    match messages with
    | Some messages -> messages
    | None -> chat_rows_for state keeper_name
  in
  let visible_timeline =
    keeper_message_visible_timeline ~messages state ~keeper_name
  in
  let palette_generation =
    Masc_tui_terminal_palette.snapshot_generation
      (Masc_tui_terminal_palette.snapshot ())
  in
  let same_inputs (memo : layout_entries_memo) =
    String.equal memo.lem_keeper_name keeper_name
    && memo.lem_chat_cols = chat_cols
    && memo.lem_memory = state.msg_memory_visibility
    && memo.lem_reasoning = state.msg_reasoning_visibility
    && memo.lem_tools = state.msg_tool_visibility
    && Option.equal String.equal memo.lem_file_changes_keeper
         state.msg_file_changes_keeper
    && memo.lem_file_change_index == state.msg_file_change_index
    && Option.equal String.equal memo.lem_calls_keeper
         state.keeper_calls_keeper
    && Bool.equal memo.lem_calls_loading state.keeper_calls_loading
    && Option.equal String.equal memo.lem_calls_error
         state.keeper_calls_error
    && memo.lem_calls == state.keeper_calls
    && memo.lem_palette_generation = palette_generation
  in
  match !layout_entries_memo with
  | Some memo
    when same_inputs memo && memo.lem_visible_timeline == visible_timeline ->
      memo.lem_entries
  | Some memo when same_inputs memo ->
      let visible_entries = keeper_message_visible_entries visible_timeline in
      let prefix, suffix =
        shared_layout_entry_prefix [] memo.lem_visible_entries
          memo.lem_entries visible_entries
      in
      let entries =
        match suffix with
        | [] -> prefix
        | _ when suffix == visible_entries ->
            compute_keeper_message_layout_entries state ~keeper_name
              ~chat_cols ~start_index:0 visible_entries
        | _ ->
            prefix
            @ compute_keeper_message_layout_entries state ~keeper_name
                ~chat_cols ~start_index:(List.length prefix) suffix
      in
      layout_entries_memo :=
        Some
          { memo with
            lem_visible_timeline = visible_timeline;
            lem_visible_entries = visible_entries;
            lem_entries = entries;
          };
      entries
  | Some _ | None ->
      let visible_entries = keeper_message_visible_entries visible_timeline in
      let entries =
        compute_keeper_message_layout_entries state ~keeper_name ~chat_cols
          ~start_index:0 visible_entries
      in
      layout_entries_memo :=
        Some
          { lem_keeper_name = keeper_name;
            lem_chat_cols = chat_cols;
            lem_memory = state.msg_memory_visibility;
            lem_reasoning = state.msg_reasoning_visibility;
            lem_tools = state.msg_tool_visibility;
            lem_file_changes_keeper = state.msg_file_changes_keeper;
            lem_file_change_index = state.msg_file_change_index;
            lem_calls_keeper = state.keeper_calls_keeper;
            lem_calls_loading = state.keeper_calls_loading;
            lem_calls_error = state.keeper_calls_error;
            lem_calls = state.keeper_calls;
            lem_palette_generation = palette_generation;
            lem_visible_timeline = visible_timeline;
            lem_visible_entries = visible_entries;
            lem_entries = entries;
          };
      entries

(* Where the pane has to scroll to put a message holding [query] on screen, and
   which message that is.

   Two values, because a caller needs both: the scroll to move to, and the
   structural anchor to start the next search strictly older than. The scroll is
   measured the only way it can be -- the physical rows the entries newer than
   the match render to, at this pane's width, through the same layout the
   frame draws. Counting messages instead would land somewhere else on every
   conversation that wraps.

   Newest first. A search over a conversation starts at what was just said and
   walks back, which is also the direction [msg_scroll] counts.

   [older_than] is a causal row identity, resolved again in the current
   timeline. A broadcast or Journal backfill may be inserted before it, so a
   stored numeric position would skip an older match after refresh. A match at
   or newer than the resolved anchor is skipped, which makes repeating a
   search walk instead of returning to the newest match every time.

   Measured over committed rows only. A producer backfill can move the physical
   row, so the repeat cursor and the scroll pin both retain its causal identity
   rather than its old index. With a live turn on screen the match lands that
   turn's height above the bottom edge rather than on it -- context below a
   result, and it settles when the turn ends.

   [needle] is trimmed by its caller and case-folded inside
   {!Masc_tui_types.palette_contains}, which keeps case folding out of a
   module whose one rule about [String.lowercase_ascii] is that it does not
   appear here.

   Pure. The renderer does not mutate state, and a search that scrolled the
   pane itself would be the exception that ends that. *)
let keeper_message_find_scroll (state : state) ~keeper_name ~needle ~older_than =
  if String.equal needle "" then None
  else
    let _, cols = get_terminal_size () in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:state.roster_pane_hidden ~cols
    in
    let messages = keeper_message_visible_messages state ~keeper_name in
    let entries =
      keeper_message_layout_entries state ~keeper_name ~chat_cols
    in
    let count = List.length entries in
    let ceiling =
      match older_than with
      | None -> count
      | Some anchor ->
          Option.value ~default:count
            (msg_index_of_anchor messages anchor)
    in
    let matched =
      List.filteri (fun index _ -> index < ceiling) entries
      |> List.mapi (fun index (entry : Message_layout.entry) -> (index, entry))
      |> List.rev
      |> List.find_opt (fun (_, (entry : Message_layout.entry)) ->
             Masc_tui_types.palette_contains ~needle entry.body)
    in
    match matched with
    | None -> None
    | Some (at, matched_entry) ->
        (* Everything newer than the match, which is exactly what a scroll
           position counts back over. *)
        let newer = List.filteri (fun index _ -> index > at) entries in
        let scroll =
          Message_layout.total_rows
            ~markdown:(cached_chat_markdown ~theme:(Chat_theme.snapshot ()))
            ~origin:state.msg_origin_display
            ~previous:matched_entry
            ~inner_width:(max 1 (framed_inner_width chat_cols))
            newer
        in
        Some (scroll, msg_anchor (List.nth messages at))

(* One turn's block as the chat pane draws it: the log it comes from, where
   it goes in the committed timeline, and its rows -- built as continuations,
   the corners set once the blocks are merged with the committed rows. *)
type log_block = {
  lb_log : Masc_tui_types.turn_log;
  lb_request_id : string;
  lb_insertion : int;
  lb_entries : Message_layout.entry list;
}

(* Whose a merged row is: a committed message's, or a block's log's. *)
type tagged_row =
  | Tagged_row of Masc_tui_types.msg_entry
  | Tagged_block of Masc_tui_types.turn_log

(* A settled block, per (keeper, request), until one of its inputs moves:
   the log's transcript (its revision: durable tool facts fold in after
   settle), the committed timeline it is placed in, the knobs its rows read,
   and the width. Module state like the renderer's other memos: derived, not
   authority. Never evicted within a session, like the logs themselves. *)
type settled_block_memo = {
  sbm_log : Masc_tui_types.turn_log;
  sbm_revision : int;
  sbm_timeline : (Masc_tui_types.msg_entry * float option) list;
  sbm_messages : Masc_tui_types.msg_entry list;
  sbm_reasoning : reasoning_visibility;
  sbm_tools : tool_visibility;
  sbm_chat_cols : int;
  sbm_block : log_block;
}

let settled_block_memo : (string * string, settled_block_memo) Hashtbl.t =
  Hashtbl.create 16

(* The merged rows while no block is live: the same list across frames when
   the committed entries and every settled block are the same values, which
   is what lets the row walk keep its counts. *)
type merged_blocks_memo = {
  mbm_committed : Message_layout.entry list;
  mbm_blocks : log_block list;
  mbm_merged : (tagged_row * Message_layout.entry) list;
}

let merged_blocks_memo : merged_blocks_memo option ref = ref None

let render_keeper_message (state : state) =
  (* The chat surface draws its own composer, so it keeps the whole terminal
     rather than reserving the shared row for a second one. *)
  let rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in

  match state.msg_target_keeper_name with
  | None ->
    Buffer.add_string buf "No keeper selected.\n";
    finish_frame_with_strip state ~surface_key:"keeper-message" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  | Some keeper_name ->
    let chat_theme = Chat_theme.snapshot () in
    let display_keeper_name = Keeper_chat.terminal_safe_text keeper_name in
    let target_registered =
      keeper_available_for_new_message state keeper_name
    in
    let status_rows = keeper_message_status_rows state in
    let support_status_rows =
      keeper_message_support_status_rows state ~status_rows
    in
    (* Wide terminals keep the roster beside the chat, exactly as the detail
       view does; the chat lays out against its own pane width. *)
    let split = keeper_roster_pane_shown state ~cols in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:state.roster_pane_hidden ~cols
    in
    let title, mode_suffix =
      (* Both features put a mode indicator here: memory arrived on main
         (#30401) while this branch was open. Neither is dropped, but only a
         mode away from its default is spelled -- see
         [Tui_types.chat_visibility_summary] for why. *)
      let modes =
        chat_visibility_summary ~memory:state.msg_memory_visibility
          ~origin:state.msg_origin_display
          ~reasoning:state.msg_reasoning_visibility
          ~tools:state.msg_tool_visibility
      in
      let diff_status =
        let snapshot_status ~stale snapshot =
          let missing_ids =
            Keeper_chat_diff.missing_execution_ids
              state.msg_file_change_index
          in
          let ambiguous_ids =
            Keeper_chat_diff.ambiguous_execution_ids
              state.msg_file_change_index
          in
          let gaps =
            [ ( snapshot.Masc.Tui_decode.fcs_over_budget
              , "oversized" )
            ; (snapshot.Masc.Tui_decode.fcs_malformed, "malformed")
            ; (missing_ids, "no execution id")
            ; (ambiguous_ids, "duplicate execution ids")
            ]
            |> List.filter_map (fun (count, label) ->
              if count = 0 then None
              else Some (Printf.sprintf "%d %s" count label))
          in
          Printf.sprintf "diffs %.0fh%s%s"
            snapshot.Masc.Tui_decode.fcs_window_hours
            (if stale then " stale" else "")
            (match gaps with
             | [] -> ""
             | gaps -> " partial · " ^ String.concat " · " gaps)
        in
        match state.msg_tool_visibility with
        | Tools_compact -> ""
        | Tools_full ->
            if
              not
                (Option.equal String.equal state.msg_file_changes_keeper
                   (Some keeper_name))
            then "diffs pending"
            else if state.msg_file_changes_loading then "diffs loading"
            else
              match state.msg_file_changes_error, state.msg_file_changes with
              | Some _, Some snapshot -> snapshot_status ~stale:true snapshot
              | Some _, None -> "diffs unavailable"
              | None, Some snapshot -> snapshot_status ~stale:false snapshot
              | None, None -> "diffs pending"
      in
      let modes =
        [ modes; diff_status ]
        |> List.filter (fun item -> not (String.equal item ""))
        |> String.concat " · "
      in
      let title =
        screen_title
          (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 chat" display_keeper_name)
      in
      let mode_suffix =
        if String.equal modes "" then ""
        else Printf.sprintf "  %s%s%s" Ansi.dim modes Ansi.reset
      in
      title, mode_suffix
    in
    let inner_cells = framed_inner_width chat_cols in
    (* Title and projection are navigation facts. Runtime/gate/context are
       operational facts. Putting all of them on one row made an ordinary
       provider id consume the rest of the header and silently lose whatever
       followed it. Two fixed rows make the hierarchy visible and let the
       opaque runtime id be the only item that yields width. *)
    let title_row =
      Message_layout.chat_title_row ~inner_cells ~title ~mode_suffix
    in
    let context_separator = "  " in
    let context_item =
      if not target_registered then None
      else
        match
          Context_state.reading_for_keeper ~keeper_name state.live_context
        with
        | Some { observation = Some observation; error = None } ->
            Observation_layout.context_header_item
              ~max_cells:(min 32 (max 0 (inner_cells / 3)))
              observation
        | Some _ | None -> None
    in
    let context_cells =
      match context_item with
      | None -> 0
      | Some item ->
          Message_layout.display_width context_separator
          + Message_layout.display_width item
    in
    let identity =
      keeper_message_identity
        ~max_cells:(max 0 (inner_cells - context_cells)) state keeper_name
    in
    let identity_row =
      match context_item with
      | None -> identity
      | Some item ->
          identity ^ context_separator ^ Ansi.dim ^ item ^ Ansi.reset
    in
    if
      not
        (Message_layout.message_viewport_supported ~terminal_rows:rows
           ~terminal_cols:chat_cols ~status_rows:support_status_rows)
    then begin
      let notice =
        " Keeper chat needs a larger terminal; resize to type (Esc:back)"
      in
      Buffer.add_string buf
        (Message_layout.fit_width notice (max 1 (cols - 1)));
      finish_frame_with_strip state ~surface_key:"keeper-message"
        ~cursor:Frame_presenter.Hidden ~rows ~cols buf
    end else begin
    let chat_buf = if split then Buffer.create 4096 else buf in
    (* Header *)
    box_top chat_buf chat_cols;
    box_line chat_buf chat_cols title_row;
    box_line chat_buf chat_cols identity_row;
    box_divider chat_buf chat_cols;

    (* Message history. The fixed chrome is 8 rows — box top, two header rows,
       their divider, the input divider, the composer's first line, box bottom
       and the footer — and every variable row (status, sending, queue, errors,
       composer growth) is in [status_rows]. The old constant 10 reserved
       two rows nothing drew, so the pane stopped two short of the
       terminal's bottom edge. [message_viewport_supported] requires the same
       eight-row chrome plus three history rows, so a live-edge omission can
       still show its first row, typed gap, and latest row. *)
    let history_height =
      Message_layout.message_history_height ~terminal_rows:rows ~status_rows
    in
    (* The same pure derivation the committed rows used, asked again for the
       live ones: one call to one function with one argument, so the badge the
       streaming turn aligns to is the badge the history aligned to. *)
    let role_label_column =
      Message_layout.chat_role_label_width ~pane_cells:chat_cols
    in
    let projected_tool_rows =
      keeper_message_tool_rows state ~keeper_name ~chat_cols
    in
    let promoted = promoted_inflight_for_keeper state keeper_name in
    let committed_timeline_messages = chat_rows_for state keeper_name in
    let committed_visible_timeline =
      keeper_message_visible_timeline state ~keeper_name
    in
    let committed_messages = List.map fst committed_visible_timeline in
    let committed_layout_entries =
      keeper_message_layout_entries state ~keeper_name ~chat_cols
    in
    (* Rows for the turns this session holds as logs: every settled turn of
       this keeper that its log stands for, then the one still streaming. Each
       block follows the committed rows of its own request rather than
       escaping to a second bottom-only lane: a settled block sits after the
       request's last row of any phase before output (its failure row, if any,
       came after everything the block holds), the live block after every
       committed row of its request. A settled block is the same rows with a
       closing rail: settling changes the rail, not the words (RFC-0412 §3.3).

       A settled log is immutable but for the durable facts folded into its
       transcript, and its block depends on the committed rows only through
       the timeline it is placed in; so each block is memoized on the
       transcript's revision, the timeline's identity and the knobs the rows
       read, and the merged list is reused whole while no block is live. That
       is what keeps an idle pane holding settled turns at the same per-frame
       cost it had before they were logs. *)
    let log_projection ~committed (turn_log : Masc_tui_types.turn_log) =
      let transcript = turn_log.tl_transcript in
      let request_id = Masc_tui_types.turn_log_request_id turn_log in
      let request_label = Keeper_chat.compact_request_id request_id in
      let started_at = Keeper_chat_transcript.started_at transcript in
      let bounds_request (message : Masc_tui_types.msg_entry) =
        (not (String.equal message.me_request_id request_id))
        || committed = false
        || message.me_turn_phase <> Turn_output
      in
      let request_messages =
        List.filter bounds_request committed_timeline_messages
      in
      let bounded_timeline =
        List.filter
          (fun ((message : Masc_tui_types.msg_entry), _) -> bounds_request message)
          committed_visible_timeline
      in
      let timeline_at =
        chat_live_timeline_at ~request_id ~started_at ~request_messages
          bounded_timeline
      in
      let insertion =
        if committed
        then
          chat_settled_insertion_index ~request_id ~timeline_at
            committed_visible_timeline
        else
          chat_live_insertion_index ~request_id ~timeline_at
            committed_visible_timeline
      in
      let timeline_bucket =
        Option.map keeper_message_timeline_bucket timeline_at
      in
      let keeper_label =
        Keeper_chat.terminal_safe_text
          (Masc_tui_types.turn_log_keeper_name turn_log)
      in
      (* The turn in the order it happened, one row per stretch
         ([Keeper_chat_transcript.drawn]): a tool-call round interleaves
         reasoning, calls and reply text, and drawing them as three pooled
         blocks read as one wall of text with its calls listed elsewhere. The
         recorded reply is already reconciled in: by outcome, a differing
         terminal stretch is replaced by the recorded text and a control
         outcome ends the turn in one STATUS row.

         Indexed and filtered at once. The index is the growing-markdown cache
         key (#30290) and the filter is how hidden reasoning disappears; the
         index counts drawn positions, not surviving rows, so hiding reasoning
         does not renumber the text entries and invalidate every cached render
         below it. Every stretch rides the growing-markdown cache: a frame
         whose text did not move reuses the rows outright, and only the new
         suffix is parsed when it did.

         A superseded attempt's stretches are drawn in place with their own
         styles, each label ending in the retry mark and the number of the try
         it came from (" ↺1" = the first try, superseded). The mark goes at the
         tail because the role label keeps two thirds of its tail when it
         overruns the column. Not dimmed: the layout has no dim variant per style, and
         adding one is the 3b restyle.

         Every row is built as a continuation; the corners are set once the
         blocks are merged with the committed rows, where a turn's first and
         last row are known. *)
      let entries =
        List.filter_map Fun.id
        @@ List.mapi
             (fun entry_index (item : Keeper_chat_transcript.drawn_item) ->
               let label text =
                 match item.superseded with
                 | Some attempt ->
                     Printf.sprintf "%s \xe2\x86\xba%d" text (attempt + 1)
                 | None -> text
               in
               let markdown_source =
                 Message_layout.Markdown_growing
                   { keeper_name; request_id; entry_index }
               in
               let entry style role_label body =
                 (* One alignment, on the label the row actually carries.
                    Aligning the continuation mark and then aligning the
                    result again pays the badge's width twice, so the second
                    call trims what the first had already fitted. *)
                 Some
                   ({ style;
                      timestamp = keeper_message_clock started_at;
                      timeline_bucket;
                      role_label =
                        Message_layout.align_role_label
                          ~column:role_label_column
                          (* Same reasoning as the history rows above: the
                             column says who, not a mark inside the label. *)
                          ~style role_label;
                      role_label_mark_cells =
                        Message_layout.role_label_mark_cells
                          ~column:role_label_column ~style ();
                      request_label;
                      body;
                      markdown_source;
                      turn_rail =
                        turn_rail_of ~siding:None
                          ~edge:Masc_tui_types.Turn_continues ~style;
                    }
                     : Message_layout.entry)
               in
               match item.drawn with
               | Keeper_chat_transcript.Drawn_thinking _
                 when not
                        (Masc_tui_types.reasoning_drawn
                           state.msg_reasoning_visibility) ->
                   None
               | Keeper_chat_transcript.Drawn_thinking lines ->
                   entry Message_layout.Thinking (label "THINKING")
                     (if state.msg_reasoning_visibility = Reasoning_folded
                      then folded_thinking_summary (String.concat "\n" lines)
                      else String.concat "\n" lines)
               | Keeper_chat_transcript.Drawn_tools block ->
                   let projection =
                     Keeper_chat_transcript.project_tool_block
                       (tool_projection_mode state) block
                   in
                   entry (tool_block_style projection) (label "TOOLS")
                     (String.concat "\n" (projected_tool_rows projection))
               | Keeper_chat_transcript.Drawn_skill skill ->
                   entry
                     (Message_layout.Skill (skill_tone_of_state skill.state))
                     (label "SKILL")
                     (String.concat "\n"
                        (* Full on the block too: the same reason the
                           committed skill rows are always full — the skill's
                           delivery and observed actions are the feature this
                           row reports, not a detail behind the tool toggle. *)
                        (Keeper_chat_transcript.skill_rows ~full:true skill))
               | Keeper_chat_transcript.Drawn_text text
               | Keeper_chat_transcript.Drawn_reply text ->
                   entry Message_layout.Keeper (label keeper_label) text
               | Keeper_chat_transcript.Drawn_status text ->
                   entry Message_layout.Status (label "STATUS") text)
             (Keeper_chat_transcript.drawn transcript)
      in
      { lb_log = turn_log; lb_request_id = request_id; lb_insertion = insertion;
        lb_entries = entries }
    in
    let settled_projection (turn_log : Masc_tui_types.turn_log) =
      let key =
        ( Masc_tui_types.turn_log_keeper_name turn_log
        , Masc_tui_types.turn_log_request_id turn_log )
      in
      let revision = Keeper_chat_transcript.revision turn_log.tl_transcript in
      match Hashtbl.find_opt settled_block_memo key with
      | Some memo
        when memo.sbm_log == turn_log
             && memo.sbm_revision = revision
             && memo.sbm_timeline == committed_visible_timeline
             && memo.sbm_messages == committed_timeline_messages
             && memo.sbm_reasoning = state.msg_reasoning_visibility
             && memo.sbm_tools = state.msg_tool_visibility
             && memo.sbm_chat_cols = chat_cols ->
          memo.sbm_block
      | Some _ | None ->
          let block = log_projection ~committed:true turn_log in
          Hashtbl.replace settled_block_memo key
            { sbm_log = turn_log;
              sbm_revision = revision;
              sbm_timeline = committed_visible_timeline;
              sbm_messages = committed_timeline_messages;
              sbm_reasoning = state.msg_reasoning_visibility;
              sbm_tools = state.msg_tool_visibility;
              sbm_chat_cols = chat_cols;
              sbm_block = block;
            };
          block
    in
    (* A block with nothing to draw -- every row hidden reasoning, or a log
       of bookkeeping frames only -- is no block: it would move its request's
       corners onto rows that never close. *)
    let settled_blocks =
      Masc_tui_types.settled_logs_for_keeper state keeper_name
      |> List.filter Masc_tui_types.turn_log_holds_the_turn
      |> List.map settled_projection
      |> List.filter (fun block -> block.lb_entries <> [])
    in
    let live_block =
      match state.msg_live with
      | Some live
        when String.equal (Masc_tui_types.turn_log_keeper_name live) keeper_name
             && Option.is_none promoted -> (
          match log_projection ~committed:false live with
          | { lb_entries = []; _ } -> None
          | block -> Some block)
      | Some _ | None -> None
    in
    let blocks = settled_blocks @ Option.to_list live_block in
    let committed_tagged =
      List.combine committed_messages committed_layout_entries
      |> List.map (fun (message, entry) -> Tagged_row message, entry)
    in
    (* Each block at its own place in the committed timeline. Blocks that
       land on the same index keep their order -- settled turns in the order
       they settled, the live one last -- and a block placed past the end
       follows everything. *)
    let merge_blocks () =
      let placed =
        List.map
          (fun block ->
            ( block.lb_insertion
            , List.map (fun entry -> Tagged_block block.lb_log, entry)
                block.lb_entries ))
          blocks
      in
      let rec merge index committed placed =
        match committed with
        | [] -> List.concat_map snd placed
        | item :: rest ->
            let due, later = List.partition (fun (at, _) -> at <= index) placed in
            List.concat_map snd due @ (item :: merge (index + 1) rest later)
      in
      let merged = merge 0 committed_tagged placed in
      (* A turn opens once and closes once, wherever its rows ended up: the
         corners of every request a block belongs to are set here, over the
         merged order, so a block placed before its request's failure row
         continues and the failure row closes, and a block placed last closes
         itself. A live block's turn has not closed: its last row continues
         until the stream ends. Rows of other requests keep the corners the
         entry memo gave them. *)
      let block_requests =
        List.map (fun block -> block.lb_request_id) blocks
      in
      let live_request_id =
        Option.map (fun block -> block.lb_request_id) live_block
      in
      let request_of = function
        | Tagged_row (message : Masc_tui_types.msg_entry) ->
            message.me_request_id
        | Tagged_block log -> Masc_tui_types.turn_log_request_id log
      in
      let first = Hashtbl.create 8 and last = Hashtbl.create 8 in
      List.iteri
        (fun index (tag, _) ->
          let request_id = request_of tag in
          if List.exists (String.equal request_id) block_requests then begin
            if not (Hashtbl.mem first request_id) then
              Hashtbl.replace first request_id index;
            Hashtbl.replace last request_id index
          end)
        merged;
      List.mapi
        (fun index ((tag, (entry : Message_layout.entry)) as item) ->
          let request_id = request_of tag in
          match Hashtbl.find_opt first request_id, Hashtbl.find_opt last request_id with
          | Some opens_at, Some closes_at ->
              let opens = opens_at = index in
              let closes =
                closes_at = index
                && not (Option.equal String.equal live_request_id (Some request_id))
              in
              let edge : Masc_tui_types.turn_edge =
                match opens, closes with
                | true, true -> Turn_alone
                | true, false -> Turn_opens
                | false, true -> Turn_closes
                | false, false -> Turn_continues
              in
              let siding =
                match tag with
                | Tagged_row message -> siding_of_message message
                | Tagged_block _ -> None
              in
              ( tag
              , { entry with
                  Message_layout.turn_rail =
                    turn_rail_of ~siding ~edge
                      ~style:entry.Message_layout.style
                } )
          | Some _, None | None, Some _ | None, None -> item)
        merged
    in
    let tagged_layout_entries =
      match blocks, live_block with
      | [], _ -> committed_tagged
      | _ :: _, Some _ -> merge_blocks ()
      | _ :: _, None -> (
          match !merged_blocks_memo with
          | Some memo
            when memo.mbm_committed == committed_layout_entries
                 && List.length memo.mbm_blocks = List.length settled_blocks
                 && List.for_all2 ( == ) memo.mbm_blocks settled_blocks ->
              memo.mbm_merged
          | Some _ | None ->
              let merged = merge_blocks () in
              merged_blocks_memo :=
                Some
                  { mbm_committed = committed_layout_entries;
                    mbm_blocks = settled_blocks;
                    mbm_merged = merged;
                  };
              merged)
    in
    (* With no block drawn, the entries the walk measures are the ones
       [layout_entries_memo] holds across frames, and passing that very list
       is what lets the walk keep its row counts: a fresh list of the same
       entries is a different question to it. With settled blocks only, the
       merged list above is that stable list. *)
    let layout_entries =
      match blocks with
      | [] -> committed_layout_entries
      | _ :: _ -> List.map snd tagged_layout_entries
    in
    let inner_width = max 1 (framed_inner_width chat_cols) in
    (* Clamped here rather than where the key is handled: the limit depends on
       the terminal width and the pane's height, and a resize changes both
       under a scroll position that was legal before it. *)
    (* One capture, handed to both the measure and the draw, so the rows the
       pane counts are the rows it paints. *)
    let markdown = cached_chat_markdown ~theme:chat_theme in
    (* [msg_scroll] counts back from the row the operator was last looking at,
       not from whatever is newest now. Count the current structural suffix
       after that anchor: newly appended rows belong there, and a late input
       can move pre-existing output below an earlier phase inside its own turn.
       In both cases those rows sit between the anchor and bottom, so adding
       their height is what keeps the same anchored content still.

       A settled block's rows count only if its log was held after the pin was
       taken: the ones on screen when the operator anchored are what they
       anchored to, not rows that arrived since. *)
    let rows_since_pin =
      match state.msg_scroll_pin, live_block with
      | None, _ -> 0
      | Some _, Some _ ->
          (* A live trail has no durable row identity and may already have
             many wrapped rows when the operator first leaves the bottom.
             Treating that existing height as newly arrived double-counts it
             on the first key press. Structural compensation resumes when the
             trail settles into a block the pin can account for. *)
          0
      | Some pin, None ->
          let arrived_since_pin = function
            | Tagged_row _ -> true
            | Tagged_block log -> not (List.memq log state.msg_scroll_pin_settled)
          in
          let entries_after rest =
            List.filter_map
              (fun (tag, entry) -> if arrived_since_pin tag then Some entry else None)
              rest
          in
          let rendered_suffix =
            let rec find_visible = function
              | [] -> None
              | (Tagged_row message, entry) :: rest ->
                  if same_msg_anchor pin message
                  then Some (Some entry, entries_after rest)
                  else find_visible rest
              | (Tagged_block _, _) :: rest -> find_visible rest
            in
            match find_visible tagged_layout_entries with
            | Some _ as found -> found
            | None ->
                (* A hidden Memory/thinking row can own the logical pin but no
                   layout entry. Start at the first visible identity after it,
                   preserving the preceding entry from the full layout so an
                   hour rail is measured exactly as the frame measures it. *)
                let raw_after =
                  Option.value ~default:[]
                    (msg_entries_after_anchor (chat_rows_for state keeper_name) pin)
                in
                let after_anchors = List.map msg_anchor raw_after in
                let belongs message =
                  List.exists
                    (fun anchor -> same_msg_anchor anchor message)
                    after_anchors
                in
                let rec find_after previous = function
                  | [] -> None
                  | (Tagged_row message, entry) :: rest when belongs message ->
                      Some (previous, entry :: entries_after rest)
                  | (_, entry) :: rest -> find_after (Some entry) rest
                in
                find_after None tagged_layout_entries
          in
          (match rendered_suffix with
           | None | Some (_, []) -> 0
           | Some (previous, arrived) ->
               Message_layout.total_rows ~markdown
                 ~origin:state.msg_origin_display ?previous ~inner_width arrived)
    in
    let scroll, visible_rows =
      Message_layout.clamped_scrolled_rows ~markdown
        ~origin:state.msg_origin_display ~inner_width ~height:history_height
        ~requested:(state.msg_scroll + rows_since_pin) layout_entries
    in

    if visible_rows = [] then begin
      if history_height > 0 then
        box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
          "  (no messages yet -- type below and press Enter)";
      for _ = 1 to history_height - 1 do
        box_empty chat_buf chat_cols
      done
    end else begin
      List.iter
        (render_chat_row ~theme:chat_theme chat_buf chat_cols)
        visible_rows;
      (* Fill remaining space *)
      for _ = List.length visible_rows to history_height - 1 do
        box_empty chat_buf chat_cols
      done
    end;

    (* Queue provenance survives promotion in [inflight.origin]. While that
       request runs, draw its USER in the exact slot NEXT owned and withhold its
       session copy from the settled transcript. Settlement drops the inflight
       provenance and the durable typed turn takes over. *)
    (match promoted with
     | Some entry ->
         let request = entry.sent_request in
         box_line_styled chat_buf chat_cols ~style:(Theme.info ())
           (Printf.sprintf "  [%s]  ▶  YOU  %s"
              (keeper_message_clock entry.submitted_at)
              (Keeper_chat.compact_request_id request.request_id));
         box_line_styled chat_buf chat_cols ~style:(Theme.info ())
           ("    " ^ Terminal_text.single_line request.message)
     | None -> ());
    (* Pending input owns the exact two-row shape of the USER entry it will
       become: one lane header and one body row. [history_height] subtracts
       these rows through [keeper_message_status_rows], so promotion exchanges
       NEXT for the promoted USER without moving the divider, composer, or
       footer. The model has not seen pending input yet. *)
    let pending =
      Masc_tui_keeper_chat_queue.waiting_for_keeper state.msg_queued
        ~keeper_name
      |> keeper_message_pending_preview
    in
    List.iter
      (function
        | Pending_preview_item (position, item) ->
            let intent, style =
              match item.Masc_tui_keeper_chat_queue.intent with
              | Masc_tui_keeper_chat_queue.Next -> "NEXT", Theme.recede ()
              | Masc_tui_keeper_chat_queue.Steer_after_interrupt ->
                  "STEER", Theme.warn ()
            in
            let request = item.Masc_tui_keeper_chat_queue.request in
            box_line_styled chat_buf chat_cols ~style
              (Printf.sprintf "  %s %d · %s" intent position
                 (keeper_message_clock item.submitted_at));
            box_line_styled chat_buf chat_cols ~style
              ("    " ^ Terminal_text.single_line request.Keeper_chat.message)
        | Pending_preview_omitted omitted ->
            box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
              (Printf.sprintf
                 "  … %d pending row(s) hidden · Ctrl-K:cancel last · Ctrl-P:edit last"
                 omitted))
      pending;

    (* Input area divider *)
    box_divider chat_buf chat_cols;

    (* Input line *)
    (* This keeper's own turn first, then any other keeper's — talking here
       does not stop those, so the pane says they are going. *)
    (* One clock read for the whole group so two rows drawn in the same frame
       cannot report ages a tick apart. The age says how long the turn has
       been going, which is what separates slow from stuck: a keeper turn
       running minutes is ordinary here, and without it these rows look the
       same at three seconds and at thirteen minutes. It changes the text of
       a row, never how many there are, so the row budget is untouched. *)
    let now = Unix.gettimeofday () in
    let sending_age entry =
      match Message_layout.age_text ~now ~since:entry.sent_at with
      | None -> ""
      | Some age -> " · " ^ age
    in
    (* The request the live transcript is already drawing says everything this
       row would: its phase, its age, and the tools it is in. Drawing both put
       a second age and an opaque request id above the ACTIVE TURN line, and
       three ages in one frame read as a stuck screen. The row stays for every
       request the transcript is not covering — a second message sent to the
       same keeper still has to be visible. *)
    let live_request_id =
      match state.msg_live with
      | Some live
        when state.msg_target_keeper_name
             = Some (Masc_tui_types.turn_log_keeper_name live) ->
        Some (Masc_tui_types.turn_log_request_id live)
      | Some _ | None -> None
    in
    (match
       List.partition
         (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
         state.msg_inflight
     with
     | mine, others ->
         List.iter
           (fun entry ->
             if
               not
                 (Option.equal String.equal live_request_id
                    (Some entry.sent_request.request_id))
             then
             let activity =
               match entry.phase with
               | Turn_streaming -> "sending"
               | Turn_reconciling -> "reconciling"
             in
             box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
               (Printf.sprintf "  (%s %s%s…)" activity
                  (Keeper_chat.compact_request_id entry.sent_request.request_id)
                  (sending_age entry)))
           mine;
         List.iter
           (fun entry ->
             box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
               (Printf.sprintf "  (also sending to %s: %s%s)"
                  (Keeper_chat.terminal_safe_text
                     entry.sent_request.keeper_name)
                  (Keeper_chat.compact_request_id entry.sent_request.request_id)
                  (sending_age entry)))
           others);
    (match state.msg_loaded_error with
     | Some detail ->
         (* Cause first. The consequence -- this session only -- is the same
            sentence every time and cost 66 cells before the reader reached the
            part that differs, which the box then cut. *)
         box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
           ("  " ^ detail ^ " \xe2\x80\x94 showing this session only")
     | None -> ());
    (if state.msg_loaded_dropped > 0 then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d saved row(s) could not be read and are not shown"
            state.msg_loaded_dropped));
    (match state.msg_memory_visibility, state.msg_memory_error with
     | Memory_hidden, _ -> ()
     | (Memory_summary | Memory_full), None -> ()
     | (Memory_summary | Memory_full), Some detail ->
         box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
           ("  memory journal unavailable: " ^ detail));
    (if state.msg_memory_visibility <> Memory_hidden
        && state.msg_memory_dropped > 0 then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d memory journal row(s) could not be read and are not shown"
            state.msg_memory_dropped));
    (* Where the pane is, when it is not at the newest row. The distance and
       the key back are what the footer used to carry seventh of nine hints,
       and the footer drops hints from its tail: on a narrow pane the one
       fact that changes what the arrow keys do was among the first to go.
       The row is drawn from [scroll], which is the clamped position the
       frame actually used, so it cannot claim a distance the pane did not
       move. [keeper_message_status_rows] reserves it on the same condition.

       At the oldest row with nothing more to fetch the distance says less
       than "start" does, which is the same reading [scroll_hint] takes. *)
    (* Drawn on the stored position, which is what the budget above counted;
       worded from the clamped one, which is where the frame actually is. The
       two agree except on the single frame after a shrinking history forces a
       clamp, and there the row says so rather than reporting a distance the
       pane did not move. *)
    (if Masc_tui_types.keeper_message_reading_back state then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (if scroll <= 0 then
            "  \xe2\x86\x93 back at the newest row"
          else if state.msg_older_exist then
            Printf.sprintf
              "  \xe2\x86\x91 reading back %d row(s) \xc2\xb7 Ctrl-E returns to the newest"
              scroll
          else
            "  \xe2\x86\x91 the start of this conversation \xc2\xb7 Ctrl-E returns to the newest"));
    (* The row [keeper_message_status_rows] reserves for the older-page
       fetch. Counting it without drawing it floated the footer a row up,
       and a failed page load was silent -- the one thing it must not be. *)
    (if state.msg_older_loading then
       box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
         "  (loading older messages\xe2\x80\xa6)"
     else
       match state.msg_older_error with
       | Some detail ->
           box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
             ("  older messages could not be loaded: " ^ detail)
       | None -> ());
    (match state.msg_live with
     | Some live
       when state.msg_target_keeper_name
            = Some (Masc_tui_types.turn_log_keeper_name live) ->
         let live = live.tl_transcript in
         (* The streaming turn is the row the eye waits on: drawn in the
            accent rather than dimmed, behind the mark a running turn wears
            everywhere else on the screen.

            It wore a second one -- four braille frames of its own, stepped
            from the wall clock by the whole second. The screen repaints every
            150ms while a turn runs, so six or seven consecutive frames drew
            the same glyph and then jumped, and the four frames chosen are not
            adjacent in the braille rotation, so the jump did not read as
            turning either. [activity_frame] is the counter that ticker
            advances, and stepping from it means one repaint, one frame. *)
         let running_mark =
           Masc_tui_answering.running_glyph ~frame:state.activity_frame
         in
         (* The age belongs to the progress row, which already ends with it
            (masc #29229 pins that a turn which never started still reports
            one). Printing it here too put the same number twice in one line,
            and a number that repeats reads as a frozen screen rather than a
            clock. *)
         (* An operator who has typed while a turn runs is about to press
            Enter and does not know what it will do. The footer says it, forty
            columns away from the caret; said here it is beside the line that
            is holding them up. Only while there is something to queue. *)
         let queue_hint =
           if Buffer.length state.msg_input > 0 then
             " · Enter queues your line; it sends when this turn ends"
           else ""
         in
         (* The gate and the prompt describe the same held call. Drawn apart,
            one row asked the operator to answer while another said a judge
            was deciding, and neither said how they related — so the screen
            read as two authorities waiting on each other. The prompt says
            which one holds the call and that the operator's key still ends
            it. *)
         let gate_note =
           match
             Masc_tui_types.keeper_effects_at_the_gate state
               ~keeper_name:(Keeper_chat_transcript.keeper_name live)
           with
           | [] -> ""
           | pending -> (
             let judging =
               List.find_opt
                 (fun (row : Tui_decode.gate_pending) ->
                   row.gp_phase = Tui_decode.Gate_judging)
                 pending
             in
             match judging with
             | None -> ""
             | Some row ->
               let age =
                 match row.gp_waiting_s with
                 | Some seconds -> " " ^ Masc_tui_answering.duration_text seconds
                 | None -> ""
               in
               Printf.sprintf " · the judge is deciding%s; your answer ends it now" age)
         in
         (* [status_rows] puts the approval question first among its Attention
            rows, so the note lands on that one and not on an interrupt or a
            stream diagnostic that shares the kind. *)
         let note_unused =
           ref
             (not (String.equal gate_note "")
              && Option.is_some (Keeper_chat_transcript.awaiting_approval live))
         in
         List.iter
           (fun (kind, text) ->
             (match kind with
              | Keeper_chat_transcript.Progress ->
                  box_line_styled chat_buf chat_cols ~style:(Masc_tui_theme.tone Masc_tui_theme.Accent)
                    ("  " ^ running_mark ^ " " ^ Ansi.bold ^ "ACTIVE TURN"
                     ^ Ansi.reset ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                     ^ " · " ^ text ^ queue_hint)
              | Keeper_chat_transcript.Attention ->
                  let suffix =
                    if !note_unused then begin
                      note_unused := false;
                      gate_note
                    end
                    else ""
                  in
                  box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
                    ("  " ^ text ^ suffix)
              | Keeper_chat_transcript.Approval outcome ->
                  let style =
                    match outcome with
                    | Keeper_chat_transcript.Approved -> Theme.ok ()
                    | Keeper_chat_transcript.Denied
                    | Keeper_chat_transcript.Timed_out
                    | Keeper_chat_transcript.Displaced
                    | Keeper_chat_transcript.Approval_other _ -> Theme.warn ()
                  in
                  box_line_styled chat_buf chat_cols ~style ("  " ^ text)))
           (Keeper_chat_transcript.status_rows ~now:(Unix.gettimeofday ()) live)
     | Some _ | None -> ());
    (* Effects this Keeper is not waiting on. A deferral returns successfully
       and the Keeper carries on, so the tool row reads as a plain return and
       nothing else on this pane said the effect was still out. The phase
       vocabulary and the age are the Approvals screen's own, so the two
       surfaces cannot disagree about a row they both hold. *)
    (match state.msg_target_keeper_name with
     | None -> ()
     | Some keeper_name -> (
         match keeper_effects_at_the_gate state ~keeper_name with
         | [] -> ()
         | pending ->
             let severity (row : Tui_decode.gate_pending) =
               match row.gp_phase with
               | Tui_decode.Gate_blocked -> 3
               | Tui_decode.Gate_human_required -> 2
               | Tui_decode.Gate_queued -> 1
               | Tui_decode.Gate_judging -> 0
             in
             let worst =
               List.fold_left
                 (fun worst row ->
                   if severity row > severity worst then row else worst)
                 (List.hd pending) (List.tl pending)
             in
             let style =
               match worst.gp_phase with
               | Tui_decode.Gate_blocked -> Theme.bad ()
               | Tui_decode.Gate_queued | Tui_decode.Gate_human_required ->
                   Theme.warn ()
               | Tui_decode.Gate_judging -> Theme.info ()
             in
             let named =
               List.map
                 (fun (row : Tui_decode.gate_pending) ->
                   let phase =
                     match row.gp_phase with
                     | Tui_decode.Gate_queued -> "queued"
                     | Tui_decode.Gate_judging -> "judging"
                     | Tui_decode.Gate_human_required -> "human"
                     | Tui_decode.Gate_blocked -> "blocked"
                   in
                   let age =
                     match row.gp_waiting_s with
                     | Some seconds -> Masc_tui_answering.duration_text seconds
                     | None -> "?"
                   in
                   Printf.sprintf "%s %s %s"
                     (Keeper_chat.terminal_safe_text row.gp_display_tool)
                     age phase)
                 pending
             in
             let count = List.length pending in
             box_line_styled chat_buf chat_cols ~style
               (Printf.sprintf "  AT THE GATE · %d external effect%s out · %s"
                  count
                  (if count = 1 then "" else "s")
                  (String.concat " · " named))));
    if not target_registered then begin
      let unavailable_message =
        match state.keepers_error with
        | Some _ ->
            "  Keeper roster is unavailable; draft retained; Esc to choose another"
        | None ->
            Printf.sprintf
              "  Keeper %s is no longer registered; draft retained; Esc to choose another"
              display_keeper_name
      in
      box_line_styled chat_buf chat_cols ~style:(Theme.bad ()) unavailable_message
    end;
    let input = Buffer.contents state.msg_input in
    let composer =
      Message_layout.composer_lines
        ~max_rows:Message_layout.composer_max_rows input
      |> List.map (Message_layout.input_viewport ~max_cells:(max 0 (chat_cols - 8)))
    in
    (* The cursor sits on the last composer line, which the row budget has
       already made room for. *)
    let visible_input =
      match List.rev composer with [] -> "" | last :: _ -> last
    in
    (* Where the composer landed, not where a second copy of the pane's
       arithmetic predicted it would. The prediction only held while every row
       the pane drew was also counted in [keeper_message_status_rows]; a
       queued line was drawn and not counted, so the prompt moved down and the
       caret did not. Reading the rows already in the frame, with the same
       [frame_lines] that builds it, cannot disagree with it. *)
    let rows_above_composer = count_frame_lines chat_buf in
    List.iteri
      (fun index line ->
        (* Only the first line carries the prompt; the rest line up under it so
           a wrapped thought reads as one message rather than several. The
           prefix here is the one [Message_layout.input_cursor_column] measures
           the caret from, so both say the same constant. *)
        let prefix =
          if index = 0 then Message_layout.chat_input_prompt_prefix else "    "
        in
        box_line chat_buf chat_cols ((Masc_tui_theme.tone Masc_tui_theme.Accent) ^ prefix ^ Ansi.reset ^ line))
      composer;

    let input_row =
      min (max 1 rows) (rows_above_composer + max 1 (List.length composer))
    in

    box_bottom chat_buf chat_cols;

    (* Footer *)
    let disposition = send_disposition state ~keeper_name in
    let pending_count =
      Masc_tui_keeper_chat_queue.length_for_keeper state.msg_queued
        ~keeper_name
    in
    let enter_hint =
      (* What the key does is read once, by [send_disposition]; the in-flight
         kind only names what is happening while it does it. Answering both
         here from a subset of the state is what let the footer say
         [Enter:blocked] on a screen that also showed "queued 1". *)
      let queue_hint () =
        (* Walking back onto a waiting line makes the next Enter a replacement
           rather than a second copy. The operator has to be told which of the
           two this Enter is: the composer looks identical either way. *)
        match state.msg_recall_replaces with
        | Some _ -> "Enter:replace the queued line  Ctrl-U:leave it queued"
        | None -> (
            match pending_count with
            | 0 -> "Enter:queue for next turn"
            | waiting ->
                Printf.sprintf
                  "Enter:queue (%d waiting)  Ctrl-K:cancel last  Ctrl-P:edit last"
                  waiting)
      in
      match disposition with
      | Queues_behind _ -> queue_hint ()
      | Sends ->
          if target_registered then "Enter:send"
          else if Option.is_some state.keepers_error then
            "Enter:disabled (roster unavailable)"
          else "Enter:disabled (Keeper unavailable)"
    in
    let scroll_hint =
      Message_layout.scroll_hint ~scrolled_back:scroll
        ~older_exist:state.msg_older_exist
    in
    let return_hint () =
      match state.msg_return with
      | Keeper_chat_return_list -> "Esc:list"
      | Keeper_chat_return_detail -> "Esc:detail"
      | Keeper_chat_return_lanes -> "Esc:Lanes"
    in
    (* The hint is the dispatch's own table, not a retelling of it: both read
       Masc_tui_esc_interrupt.action, so the footer cannot advertise an
       interrupt Esc will not spend itself on, nor say "interrupt sent" after
       the grace window when Esc would leave. *)
    let escape_hint =
      match state.msg_live with
      | Some live ->
          (match
             Masc_tui_esc_interrupt.action ~now_ns:(Mtime_clock.elapsed_ns ())
               (Keeper_chat_transcript.interrupt live.tl_transcript)
           with
           | Masc_tui_esc_interrupt.Launch_interrupt -> "Esc:interrupt turn"
           | Masc_tui_esc_interrupt.Swallow -> "Esc:interrupt sent"
           | Masc_tui_esc_interrupt.Leave -> return_hint ())
      | None -> return_hint ()
    in
    (* Named beside the empty-draft Q arm in the dispatch, and reading the
       same condition it does, chat focus included: the hint exists exactly
       when the key would leave, and is absent exactly when Q is a letter
       someone is typing, the roster holds focus, or something is mid-flight
       for Esc to settle (a capture, a half-edited queued line). The compact
       footer omits it for width, not because the key went away -- the help
       sheet still names it. *)
    let leave_hint =
      if state.keeper_message_focus = Right_pane
         && Buffer.length state.msg_input = 0
         && Option.is_none state.msg_recall_replaces
         && Option.is_none state.voice_capture
      then "  Q:leave"
      else ""
    in
    let switch_hint =
      match next_keeper_message_target state with
      | Masc_tui_keeper_selection.No_alternative -> ""
      | Masc_tui_keeper_selection.Switch_to _ -> "  Ctrl-G:next Keeper"
    in
    (* A composer holding a slash word gets a footer about that word instead
       of the key list. The keys have not changed and one backspace brings
       them back; what the operator is looking at is the command they are
       part way through typing, and until now the only way to find out
       whether it existed was to send it. *)
    (* The footer is drawn dim, so a span that changes colour restores the
       foreground rather than resetting: a reset would drop the dim from
       everything after it. What is highlighted is the run the operator has
       actually pressed, which is what tells them how far along the word they
       are. *)
    let slash_hint =
      let paint (span : Masc_tui_command.hint_span) =
        match span with
        | Masc_tui_command.Typed text -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ text ^ Ansi.default_fg
        | Masc_tui_command.Wrong text -> (Theme.bad ()) ^ text ^ Ansi.default_fg
        | Masc_tui_command.Untyped text | Masc_tui_command.Detail text -> text
      in
      match
        Masc_tui_command.hint_spans
          (Masc_tui_command.hint (Buffer.contents state.msg_input))
      with
      | [] -> None
      | spans -> Some (String.concat "" (List.map paint spans))
    in
    let footer_hints =
      match slash_hint with
      | Some line -> line
      (* A capture takes the hint line for as long as it runs. The chat surface
         draws its own input row rather than the composer, so the meter that
         row carries never reaches here — and this is the one screen an
         operator speaks from. Nothing else distinguishes a microphone that is
         hearing them from one that is not: both end as an empty draft.

         It replaces the hints rather than crowding in beside them because the
         keys they name are the ones a capture is not waiting for. *)
      | None when state.voice_capture <> None ->
        let bar =
          match state.voice_level_db with
          | None -> Printf.sprintf "%s듣는 중…%s" Ansi.dim Ansi.reset
          | Some db ->
            Printf.sprintf
              "%s%s%s  %s%.0f dB%s"
              (Masc_tui_theme.tone Masc_tui_theme.Accent)
              (Masc_tui_footer.voice_bar
                 ~width:Masc_tui_footer.voice_bar_width
                 ~db:(Some db))
              Ansi.reset
              Ansi.dim
              db
              Ansi.reset
        in
        (* Both endings, because they are not the same and the difference is
           what the operator loses. ^Y keeps the sentence; Esc abandons it. *)
        Printf.sprintf
          "%s  %s^Y send · Esc discard%s"
          bar
          Ansi.dim
          Ansi.reset
      (* Between utterances in continuous mode: on, but nothing recording. A
         mode that is idle looks exactly like one that is off without this. *)
      | None when state.voice_continuous <> None ->
        Printf.sprintf
          "%s대기 중 — 말하면 잡습니다 · ^A to stop%s"
          Ansi.dim
          Ansi.reset
      | None ->
      if state.keeper_message_focus = Left_pane then
        "Up/Down:move  Enter:open  Right/Esc:chat"
      else if chat_cols < 120 then
        let compact_enter_hint =
          match disposition with
          | Queues_behind _ -> (
              match state.msg_recall_replaces with
              | Some _ -> "Enter:replace queued  Ctrl-U:leave it"
              | None ->
                  Printf.sprintf "Enter:queue(%d)  Ctrl-K:cancel  Ctrl-P:edit"
                    pending_count)
          | Sends -> enter_hint
        in
        let compact_scroll_hint =
          if scroll = 0 then "PgUp:history" else "PgDn:newest"
        in
        Masc_tui_footer.compact_chat_hints ~enter_hint:compact_enter_hint
          ~scroll_hint:compact_scroll_hint ~escape_hint
      else
        Masc_tui_footer.chat_hints ~enter_hint ~scroll_hint ~switch_hint
          ~escape_hint ~leave_hint
    in
    Buffer.add_string chat_buf
      (footer_line state ~max_cells:chat_cols ~hints:footer_hints);

    let input_column =
      Message_layout.input_cursor_column ~terminal_cols:chat_cols
        ~input:visible_input
    in
    let cursor_column =
      input_column + if split then keeper_roster_pane_cols else 0
    in
    if split then begin
      let left_buf = Buffer.create 1024 in
      keeper_roster_pane
        ~focused:(state.keeper_message_focus = Left_pane)
        state ~rows ~cols:keeper_roster_pane_cols left_buf;
      write_two_panes buf ~left_cols:keeper_roster_pane_cols ~left:left_buf
        ~right:chat_buf
    end;
    finish_frame_with_strip state ~surface_key:"keeper-message"
      ~clamped:(Message_scroll scroll)
      ~cursor:
        (if state.keeper_message_focus = Left_pane then
           Frame_presenter.Hidden
         else
           Frame_presenter.Visible_at
             { row = input_row; column = cursor_column })
      ~rows ~cols buf
    end

(* One colour per level so an operator scanning the column sees severity before
   reading the text. A level this build does not name keeps its own text and
   renders unstyled rather than borrowing another level's colour. *)
let system_log_level_style : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> Ansi.dim
  | System_info -> Ansi.reset
  | System_warn -> (Theme.warn ())
  | System_error -> (Theme.bad ())
  | System_level_unknown _ -> Ansi.reset

let system_log_level_mark : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> "\xc2\xb7"
  | System_info -> "\xe2\x80\xa2"
  | System_warn -> "!"
  | System_error -> "\xc3\x97"
  | System_level_unknown _ -> "?"

let system_log_category_text (entry : Masc.Tui_decode.system_log_entry) =
  match entry.sl_category with
  | None -> "-"
  | Some category -> category

let system_log_detail_field ~width ~style label value =
  let prefix = "  " ^ label ^ ": " in
  let continuation = String.make (Message_layout.display_width prefix) ' ' in
  match
    Message_layout.wrap_words
      ~max_cells:(max 1 (width - Message_layout.display_width prefix))
      (Terminal_text.single_line value)
  with
  | [] -> [ style, prefix ^ "-" ]
  | first :: rest ->
      (style, prefix ^ first)
      :: List.map (fun line -> style, continuation ^ line) rest

let system_log_detail_lines (state : state) ~seq ~width =
  let entry =
    Option.bind state.system_logs (fun snapshot ->
        List.find_opt
          (fun entry -> entry.Masc.Tui_decode.sl_seq = seq)
          snapshot.Masc.Tui_decode.sys_entries)
  in
  match entry with
  | None ->
      [ Theme.warn (),
        "  This log entry is no longer present in the retained page; reload or return to the list."
      ]
  | Some entry ->
      let level_style = system_log_level_style entry.sl_level in
      let keeper = Option.value ~default:"system" entry.sl_keeper in
      let turn = Option.map string_of_int entry.sl_turn |> Option.value ~default:"-" in
      let fields =
        system_log_detail_field ~width ~style:Ansi.dim "Sequence"
          (string_of_int entry.sl_seq)
        @ system_log_detail_field ~width ~style:Ansi.dim "Timestamp" entry.sl_ts
        @ system_log_detail_field ~width ~style:level_style "Level"
            (Masc.Tui_decode.system_log_level_label entry.sl_level |> String.trim)
        @ system_log_detail_field ~width ~style:Ansi.dim "Category"
            (system_log_category_text entry)
        @ system_log_detail_field ~width ~style:Ansi.dim "Source"
            (Masc.Tui_decode.system_log_source_label entry.sl_source)
        @ system_log_detail_field ~width ~style:Ansi.dim "Module" entry.sl_module
        @ system_log_detail_field ~width ~style:Ansi.dim "Keeper" keeper
        @ system_log_detail_field ~width ~style:Ansi.dim "Turn" turn
        @ system_log_detail_field ~width ~style:Ansi.reset "Message"
            entry.sl_message
      in
      let details =
        match entry.sl_details with
        | `Null -> [ Ansi.dim, "  Details: none" ]
        | json ->
            let source =
              "```json\n" ^ Yojson.Safe.pretty_to_string json ^ "\n```"
            in
            (Ansi.bold, "  Structured details")
            :: (document_markdown ~width source
                |> List.map (fun line -> Ansi.reset, "  " ^ line))
      in
      fields @ details

let render_system_log_detail (state : state) seq =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  seq %d  %s" (screen_title " MASC Log detail") seq
       (connection_badge state));
  box_divider buf cols;
  let lines = system_log_detail_lines state ~seq ~width:(max 1 (cols - 8)) in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.system_logs_detail_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints System_logs));
  finish_surface state ~clamped:(System_log_detail_scroll scroll)
    ~surface_key:"system-log-detail" ~rows:terminal_rows ~cols buf

let render_system_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let entries = Masc_tui_types.visible_system_log_entries state in
  let total_entries = List.length entries in
  let loaded_entries =
    match state.system_logs with
    | None -> 0
    | Some snapshot -> List.length snapshot.sys_entries
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  (* The active filters ride in the header, so a page trimmed to twelve rows
     says why it is twelve rather than reading as a quiet ring. *)
  let filter_note =
    let level =
      match state.system_logs_min_level with
      | None -> "  level\xe2\x89\xa5DEBUG  verbose:on"
      | Some floor ->
          Printf.sprintf "  level\xe2\x89\xa5%s  verbose:off"
            (String.trim (Masc.Tui_decode.system_log_level_label floor))
    in
    let category =
      match state.system_logs_category with
      | None -> ""
      | Some category ->
          "  category:" ^ Terminal_text.single_line category
    in
    level ^ category
  in
  let header =
    match state.system_logs with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC System Logs") timestamp
          (connection_badge state)
    | Some snapshot ->
        (* [total] counts what the ring has seen, not what this page holds.
           Showing both keeps "300 of 774273" from reading as "300 exist". *)
        Printf.sprintf "%s (%d of %d, seq %d)%s  %s  %s"
          (screen_title " MASC System Logs")
          total_entries snapshot.sys_total snapshot.sys_latest_seq filter_note
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* The message takes what the named columns leave, asked of the columns. *)
  let message_width =
    Render_schedule.system_log_message_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.system_log_header_row ~message_width
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.system_logs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The scroll indicator is a real row whenever this page has more entries
     than fit. Reserving it unconditionally keeps the bottom border and footer
     from becoming the frame's overflow casualty. *)
  let chrome_rows = system_log_listing_chrome ~error:state.system_logs_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total_entries - content_height) in
  let scroll = max 0 (min state.system_logs_scroll max_scroll) in
  if total_entries = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.system_logs ~error:state.system_logs_error
      with
      | Page_failed -> "  (load failed; the count above is not a reading)"
      | Page_unread -> page_unread_note
      | Page_empty when loaded_entries > 0 ->
          "  (no entries match the current category filter)"
      | Page_empty -> "  (no entries)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt entries idx with
      | None -> box_empty buf cols
      | Some e ->
          let keeper =
            match e.sl_keeper with None -> "-" | Some name -> name
          in
          let category = system_log_category_text e in
          let level_style = system_log_level_style e.sl_level in
          (* Every cell is fitted to the width its header is drawn at; a long
             module name used to push every column right of it out of line. *)
          let line =
            "  "
            ^ Render_schedule.system_log_row ~message_width ~level_style
                ~styles:
                  { Render_schedule.slog_time_style = Ansi.dim
                  ; slog_module_style =
                      Masc_tui_theme.tone Masc_tui_theme.Accent
                  ; slog_keeper_style = Theme.keeper_origin ()
                  ; slog_category_style = Ansi.dim
                  }
                { Render_schedule.slog_time =
                    Terminal_text.clock_timestamp e.sl_ts
                ; slog_level =
                    system_log_level_mark e.sl_level ^ " "
                    ^ Masc.Tui_decode.system_log_level_label e.sl_level
                ; slog_module = Terminal_text.single_line e.sl_module
                ; slog_keeper = Terminal_text.single_line keeper
                ; slog_category = Terminal_text.single_line category
                ; slog_message = Terminal_text.single_line e.sl_message
                }
          in
          if idx = state.system_logs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if total_entries > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d entries, scroll %d]" total_entries scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"system-logs" ~rows:terminal_rows
      ~cols buf

(* What is waiting on a verdict.

   The columns answer the questions an operator opens this for: which task,
   who submitted it, and what would move it forward. Evidence counts rather
   than paths -- a row is a queue entry, and the paths belong to whoever opens
   the task. *)
let render_verification_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let requests =
    match state.verification with None -> [] | Some s -> s.Masc.Tui_decode.vs_requests
  in
  let shown = List.length requests in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.verification with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (planning_workspace_title state ~tab:Planning_task_review ~window:"")
          timestamp (connection_badge state)
    | Some snapshot ->
        (* Both numbers, for the same reason the log surface shows both: "12"
           beside a list of 12 would read as "that is all of them". *)
        Printf.sprintf "%s  %s  %s"
          (planning_workspace_title state ~tab:Planning_task_review
             ~window:
               (Printf.sprintf " (%d of %d)" shown
                  snapshot.Masc.Tui_decode.vs_total))
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows. Sixteen was the fixed width and the longest
     submitter on the wire is thirty-seven, so every [keeper-*-agent] row
     pushed the two columns after it out of line with the rest. *)
  let submitter_width =
    List.fold_left
      (fun widest (r : Masc.Tui_decode.verification_request) ->
        max widest
          (Message_layout.display_width
             (Terminal_text.single_line r.Masc.Tui_decode.vr_submitted_by)))
      16 requests
    |> min 26
  in
  let col_hdr =
    Printf.sprintf "  %-14s %-*s %-9s %s" "Task" submitter_width
      "Submitted by" "Evidence" "What it asks for"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.verification_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* The same frame the other listings draw, and the same two rows for a load
     error -- written out here as its own 9-or-7 rather than asked for. A
     surface that re-types the count does not move when the frame does. *)
  let chrome_rows = listing_chrome ~error:state.verification_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.verification_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.verification
          ~error:state.verification_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
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
      match List.nth_opt requests idx with
      | None -> box_empty buf cols
      | Some r ->
          let open Masc.Tui_decode in
          (* Submitted against required. A request that owes three artifacts
             and has one is the row an operator acts on first, and the pair
             says that where a single count would not. *)
          let evidence =
            match r.vr_evidence_error with
            | Some _ -> "unreadable"
            | None ->
                Printf.sprintf "%d/%d"
                  (List.length r.vr_submitted_evidence)
                  (List.length r.vr_required_artifacts)
          in
          (* The task's own title. This column read [next_action] and fell
             back to [request_summary], and both are literals in the producer:
             [submit_request_spec] sets [request_summary = ""] and
             [next_action = ""] and writes them into the request. All 200
             rows on the wire carry both empty, so the column had a header and
             no content on every row that has ever been drawn.

             The title is in the same object, filled on all 200, decoded into
             [vr_task_title] already, and shown in the detail pane below --
             just not in the list. What a verification request asks for is
             that this task be verified, so the title is what it asks for. *)
          let asks = r.vr_task_title in
          let line =
            Printf.sprintf "  %-14s %s %-9s %s"
              (Terminal_text.single_line r.vr_task_id)
              (fit_width (Terminal_text.single_line r.vr_submitted_by)
                 submitter_width)
              evidence
              (Terminal_text.single_line asks)
          in
          let style =
            (* Evidence that cannot be read is the one row that cannot be
               judged as it stands, so it reads as a problem rather than as a
               queue entry. *)
            match r.vr_evidence_error with
            | Some _ -> (Theme.bad ())
            | None -> Ansi.reset
          in
          if idx = state.verification_cursor then box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d requests, scroll %d]" shown scroll);
  (* The arm and the server's last refusal sit under the list, the same rows
     the schedule cancel carries them on. *)
  (match state.verification_verdict_armed with
   | Some task_id ->
       (* No width padding on the id: padding to a reserved column pushes the
          "same key again" tail past the box on a narrow terminal, and the
          tail is the half that instructs. *)
       box_line buf cols
         ((Theme.warn ())
         ^ Printf.sprintf "  armed: approve %s -- same key again to send"
             (Terminal_text.single_line task_id)
         ^ Ansi.reset)
   | None -> ());
  (match state.verification_verdict_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  "
         ^ fit_width (Terminal_text.single_line err) (cols - 8)
         ^ Ansi.reset)
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"verification" ~rows:terminal_rows ~cols buf

let verification_detail_lines ~width
    (request : Masc.Tui_decode.verification_request) =
  let field label value =
    ( Ansi.reset
    , Printf.sprintf "  %-15s %s" label (Terminal_text.single_line value) )
  in
  let wrapped_block label text =
    (Ansi.bold, "  " ^ label)
    :: (Message_layout.wrap_body ~markdown:document_markdown
          ~max_cells:(max 1 (width - 4))
          ~sanitize:Keeper_chat.terminal_safe_text text
        |> List.map (fun line -> Ansi.reset, "    " ^ line))
  in
  let item_lines empty_label items =
    match items with
    | [] -> [ Ansi.dim, "    (" ^ empty_label ^ ")" ]
    | _ ->
        List.concat_map
          (fun item ->
             Message_layout.wrap_body ~max_cells:(max 1 (width - 6))
               ~sanitize:Keeper_chat.terminal_safe_text item
             |> List.mapi (fun index line ->
                    Ansi.reset, (if index = 0 then "    - " else "      ") ^ line))
          items
  in
  [ Ansi.bold, "  VERIFICATION REQUEST"
  ; field "Request" request.vr_request_id
  ; field "Task" request.vr_task_id
  ; field "Title" request.vr_task_title
  ; field "Submitted by" request.vr_submitted_by
  ; field "Created" request.vr_created_at
  ; Ansi.dim, ""
  ]
  (* [Kind], [What is being judged] and [What moves it forward] stood here.
     Their three fields were literals in the producer -- "normal", "" and "" --
     so the three rows read the same on every request this pane has ever
     drawn, two of them as "No X was recorded". The pane already tells a
     reader how to read the request from its artifacts and evidence, which is
     what those rows were pointing away from. *)
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  HOW TO READ THIS"
    ; ( Ansi.dim
      , "    Required artifacts say what must exist. Submitted evidence says what the verifier can inspect now." )
    ; Ansi.dim, ""
    ; Ansi.bold
    , Printf.sprintf "  REQUIRED ARTIFACTS (%d)"
        (List.length request.vr_required_artifacts)
    ]
  @ item_lines "none required" request.vr_required_artifacts
  @ [ Ansi.dim, ""
    ; Ansi.bold
    , Printf.sprintf "  SUBMITTED EVIDENCE (%d)"
        (List.length request.vr_submitted_evidence)
    ]
  @ item_lines "none submitted" request.vr_submitted_evidence
  @
  match request.vr_evidence_error with
  | None -> []
  | Some detail ->
      [ Ansi.dim, "" ]
      @ wrapped_block "Evidence projection error" detail

(* What the verifier can actually inspect: the operator evidence bundle,
   lazily fetched on detail entry. The snapshot above lists references; this
   carries artifact content prefixes (server-capped, truncation marked) and
   the typed reason when an artifact could not be read — the judge's actual
   input, drawn beside the verdict keys so approval is not blind. *)
let verification_evidence_lines (state : state) ~width task_id =
  let wrap ~prefix text =
    Message_layout.wrap_body ~max_cells:(max 1 (width - 6))
      ~sanitize:Keeper_chat.terminal_safe_text text
    |> List.mapi (fun index line ->
           Ansi.reset, (if index = 0 then prefix else "      ") ^ line)
  in
  let rows =
    match state.verification_evidence with
    | Some (id, result) when String.equal id task_id -> (
        match result with
        | Ok (Masc.Tui_decode.Evidence_items []) ->
            [ Ansi.dim, "    (no inspectable evidence)" ]
        | Ok (Masc.Tui_decode.Evidence_items items) ->
            List.concat_map
              (fun (item : Masc.Tui_decode.verification_evidence_item) ->
                match item with
                | Masc.Tui_decode.Ev_note note -> wrap ~prefix:"    - note: " note
                | Masc.Tui_decode.Ev_artifact
                    { ev_reference; ev_content; ev_bytes; ev_truncated } ->
                    (( Ansi.reset
                     , Printf.sprintf "    - artifact %s (%dB%s)"
                         (Terminal_text.single_line ev_reference) ev_bytes
                         (if ev_truncated then ", truncated" else "") )
                     :: wrap ~prefix:"      " ev_content)
                | Masc.Tui_decode.Ev_artifact_unreadable
                    { ev_u_reference; ev_u_reason } ->
                    wrap
                      ~prefix:"    - artifact unreadable: "
                      (Printf.sprintf "%s %s"
                         (Option.value ev_u_reference ~default:"(no reference)")
                         ev_u_reason))
              items
        | Ok (Masc.Tui_decode.Evidence_access_unavailable reason) ->
            wrap ~prefix:"    evidence unavailable: " reason
        | Error err -> wrap ~prefix:"    evidence load failed: " err)
    | _ -> [ Ansi.dim, "    loading..." ]
  in
  (Ansi.dim, "") :: (Ansi.bold, "  EVIDENCE CONTENT") :: rows

let verification_detail_pane (state : state) ~rows ~cols request buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s"
       (planning_workspace_title state ~tab:Planning_task_review ~window:""
        ^ " \xe2\x96\xb8 details")
       (Terminal_text.single_line request.Masc.Tui_decode.vr_task_id));
  box_divider buf cols;
  let width = max 1 (framed_inner_width cols) in
  let lines =
    verification_detail_lines ~width request
    @ verification_evidence_lines state ~width request.Masc.Tui_decode.vr_task_id
  in
  let content_height = max 1 (rows - 6) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.verification_detail_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The queue stays beside the request under review. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_verification_detail (state : state) request =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, max_scroll =
    if cols < keeper_split_threshold_cols then
      verification_detail_pane state ~rows ~cols request buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.verification with
        | None -> []
        | Some snapshot ->
          List.map (fun (row : Tui_decode.verification_request) -> row.Tui_decode.vr_task_id)
            snapshot.Tui_decode.vs_requests
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Task Review"
        ~focused:false ~labels ~selected:state.verification_cursor;
      let answer =
        verification_detail_pane state ~rows ~cols:(cols - left_cols) request
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf "%s  (%d/%d)"
            (Masc_tui_keys.footer_hints state.view) scroll max_scroll));
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

(* What the harness decided, most recent first.

   A verdict reached by a fallback evaluator is not the verdict that was asked
   for, so the row says which evaluator answered and marks the ones that were
   not the intended one. Reading a column of "approve" without that would say
   the gate is working when it may only be degrading quietly. *)
(* What the judge has decided over its whole life. The pane drew the recent
   page and nothing else, so the line promising to say "where a fallback
   answered instead" was the one thing it could not answer: 1,983 of this
   workspace's 4,197 verdicts came from the fallback gate and the screen
   showed a page of eight.

   Rates are stated against what they were computed from. [labeled_count] is
   zero here, which makes the agreement rate and the false-positive and
   false-negative counts zero for want of ground truth rather than for want
   of disagreement -- drawn as "0.0" they would read as a judge that never
   errs. The pane says which of the two it is instead of printing the
   number. *)
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
            ; Printf.sprintf "  %sgate%s    %s" Ansi.dim Ansi.reset
                (fit_width gates (max 8 (cols - 12)))
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
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
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
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (planning_workspace_title state ~tab:Planning_verdicts ~window:"")
          timestamp (connection_badge state)
    | Some snapshot ->
        (* The page and the ledger, apart. This read "(8 verdicts)" while the
           server was reporting 4,197: the eight are the recent page, and
           every proportion below is computed over the rest. A page count
           worn as the total is the one number on this screen a reader would
           act on. *)
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
        Printf.sprintf "%s  %s  %s"
          (planning_workspace_title state ~tab:Planning_verdicts
             ~window:
               (Printf.sprintf " (%d%s%s)" shown of_total by_fallback))
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* The tab name alone says nothing; the surface introduces itself. Said in
     terms of the queue next door, because that is the other half of it: Task
     Review is what is still waiting for a ruling and this is what was ruled,
     by whom, and where a fallback answered instead of the evaluator the Gate
     names. *)
  box_line_styled buf cols ~style:(Theme.recede ())
    "  Task Verdicts = automatic Gate rulings on Tasks (old Harness); not Goal proof.";
  List.iter (box_line buf cols) (harness_ledger_lines ~cols state.harness);
  (* A ledger that quietly stopped is this screen's own failure mode: it once
     starved for a month while the judge kept running, and the stale rows
     read as a working gate. Say the age instead of letting old rows pass as
     current. *)
  let stale_note =
    match verdicts with
    | [] -> None
    | newest :: _ ->
        let age_days =
          (Unix.gettimeofday () -. newest.Masc.Tui_decode.hv_at) /. 86_400.
        in
        if age_days >= 2. then
          Some (Printf.sprintf "  last verdict %.0f days ago \xe2\x80\x94 the judge runs but nothing is being recorded" age_days)
        else None
  in
  (match stale_note with
   | None -> ()
   | Some note -> box_line_styled buf cols ~style:(Theme.warn ()) note);
  (* The reason takes the cells the named columns leave. *)
  let reason_width =
    Render_schedule.harness_reason_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr = "  " ^ Render_schedule.harness_header_row ~reason_width in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.harness_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows =
    (if Option.is_some state.harness_error then 9 else 7)
    + 1
    + (if Option.is_some stale_note then 1 else 0)
  in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.harness_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.harness ~error:state.harness_error with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (no verdicts recorded)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt verdicts idx with
      | None -> box_empty buf cols
      | Some v ->
          let open Masc.Tui_decode in
          let evaluator =
            match v.hv_fallback_reason with
            | None -> v.hv_evaluator
            | Some reason ->
                Printf.sprintf "%s (fallback: %s)" v.hv_evaluator reason
          in
          let verdict = Terminal_text.single_line v.hv_verdict in
          (* A rejection arrives as "reject:<why>", and the why runs to a
             couple of hundred characters. Poured into the nine-column
             verdict cell it pushed Evaluator off the right edge, so the
             column that says who judged was readable on approvals and
             missing on exactly the rows an operator opens: the rejections.

             The ruling holds the cell; the reason follows the evaluator and
             takes what width is left. The detail pane wraps it whole. *)
          let ruling, reason =
            match String.index_opt verdict ':' with
            | None -> verdict, ""
            | Some at ->
                ( String.sub verdict 0 at
                , String.trim
                    (String.sub verdict (at + 1)
                       (String.length verdict - at - 1)) )
          in
            let line =
              "  "
              ^ Render_schedule.harness_row
                  ~verdict_style:(semantic_status_color ruling) ~reason_width
                  { Render_schedule.hrow_time =
                    Terminal_text.clock_timestamp
                      (Masc_domain.iso8601_of_unix_seconds v.hv_at)
                ; hrow_task = Terminal_text.single_line v.hv_task_id
                ; hrow_gate = Terminal_text.single_line v.hv_gate
                ; hrow_verdict = ruling
                ; hrow_evaluator = Terminal_text.single_line evaluator
                ; hrow_reason = reason
                }
          in
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
      (Printf.sprintf "[%d verdicts, scroll %d]" shown scroll);
  box_bottom buf cols;
  let link_hint =
    match List.nth_opt verdicts state.harness_cursor with
    | None -> ""
    | Some verdict ->
        "  selected:"
        ^ Link.reference Task
            (Terminal_text.single_line verdict.Masc.Tui_decode.hv_task_id)
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view ^ link_hint));
  finish_surface state ~surface_key:"harness" ~rows:terminal_rows ~cols buf

(* Which goals the judged task serves, and what those goals are aiming at.
   The verdict names a task, the task names its goals, and a goal carries the
   metric it is measured by -- three hops that were all present and never
   walked, so a verdict said "pass" without saying what it was passing
   towards. *)
let harness_goal_lines (state : state) (verdict : Masc.Tui_decode.harness_verdict) =
  let goal_ids =
    match
      List.find_opt
        (fun (row : Tui_decode.task) -> String.equal row.id verdict.hv_task_id)
        state.tasks
    with
    | Some row -> row.goal_ids
    | None -> []
  in
  let goal_of id =
    Option.bind state.planning (fun snapshot ->
      List.find_opt
        (fun (goal : Tui_decode.planning_goal) -> String.equal goal.pg_id id)
        snapshot.Tui_decode.pl_goals)
  in
  match goal_ids with
  | [] ->
    (* Two different silences, told apart. A task this screen has never seen
       (the backlog has not loaded, or the verdict judged something already
       archived) is not the same as a task that serves no goal, and drawing
       nothing for both leaves the reader unable to tell which. *)
    let known_task =
      List.exists
        (fun (row : Tui_decode.task) -> String.equal row.id verdict.hv_task_id)
        state.tasks
    in
    if known_task then
      [ Ansi.dim, "  Towards      this task is not linked to a goal" ]
    else
      [ Ansi.dim, "  Towards      the judged task is not in this backlog" ]
  | goal_ids ->
    (Ansi.bold, "  TOWARDS")
    :: List.concat_map
         (fun id ->
           match goal_of id with
           | None ->
             (* Linked to a goal this snapshot does not carry -- terminal, or
                simply not in the page that was fetched. Named rather than
                dropped: the link is a fact even when the goal is not here. *)
             [ Ansi.reset, Printf.sprintf "  %-12s %s" "Goal" id
             ; Ansi.dim, Printf.sprintf "  %-12s %s" "" (Link.reference Goal id)
             ]
           | Some goal ->
             let aim =
               match goal.pg_metric, goal.pg_target_value with
               | Some metric, Some target -> Printf.sprintf "%s -> %s" metric target
               | Some metric, None -> metric
               | None, Some target -> Printf.sprintf "target %s" target
               | None, None -> "no metric declared"
             in
             [ Ansi.reset,
               Printf.sprintf "  %-12s %s" "Goal"
                 (Terminal_text.single_line goal.pg_title)
             ; Ansi.reset, Printf.sprintf "  %-12s %s" "Aim" aim
             ; Ansi.dim, Printf.sprintf "  %-12s %s" "" (Link.reference Goal id)
             ])
         goal_ids
;;

let harness_detail_lines ~width (verdict : Masc.Tui_decode.harness_verdict) =
  let field ?(style = Ansi.reset) label value =
    style,
    Printf.sprintf "  %-12s %s" label (Terminal_text.single_line value)
  in
  let wrapped label text =
    (Ansi.bold, "  " ^ label)
    :: (Message_layout.wrap_body ~markdown:document_markdown
          ~max_cells:(max 1 (width - 6))
          ~sanitize:Keeper_chat.terminal_safe_text text
        |> List.map (fun line -> Ansi.reset, "    " ^ line))
  in
  let fallback =
    match verdict.hv_fallback_reason with
    | None -> [ Ansi.dim, "  Fallback     none; the named evaluator answered" ]
    | Some reason ->
        [ (Theme.warn ()), "  FALLBACK EVALUATION" ]
        @ wrapped "Why the requested evaluator did not run" reason
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
  [ Ansi.bold, "  EVALUATOR VERDICT"
  ; field "Task link" (Link.reference Task verdict.hv_task_id)
  ; field "Task" verdict.hv_task_id
  ]
  @ wrapped "Title" verdict.hv_task_title
  @ [ field "Agent" verdict.hv_agent
    ; Ansi.dim, ""
    ; Ansi.bold, "  DECISION"
    ; field ~style:(semantic_status_color ruling) "Verdict" ruling
    ; field "Gate" verdict.hv_gate
    ; field "Evaluator" verdict.hv_evaluator
    ; field "Recorded"
        (Masc_domain.iso8601_of_unix_seconds verdict.hv_at)
    ]
  (* The reason a task was rejected or approved is the sentence the operator came
     here to read, and it runs long. [field] is one [single_line], so it was cut at
     the pane's width and the rest existed nowhere on the surface. The title
     above already wraps for the same reason. *)
  @ (if reason = "" then [] else wrapped "Reason" reason)
  @ [ Ansi.dim, "" ]
  @ fallback

let harness_detail_pane (state : state) ~rows ~cols verdict buf =
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (planning_workspace_title state ~tab:Planning_verdicts ~window:""
        ^ " \xe2\x96\xb8 verdict")
       (Terminal_text.single_line verdict.Masc.Tui_decode.hv_task_id)
       (connection_badge state));
  box_divider buf cols;
  let lines =
    harness_detail_lines ~width:(max 1 (framed_inner_width cols)) verdict
    (* Appended rather than woven in: the verdict block is what the server
       said, and what the task is aiming at is read from two other surfaces.
       Keeping them in that order keeps the judged fact above the context. *)
    @ (match harness_goal_lines state verdict with
       | [] -> []
       | goal_lines -> (Ansi.dim, "") :: goal_lines)
  in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.harness_detail_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (scroll + index) with
    | Some (style, line) -> box_line_styled buf cols ~style line
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The verdict list stays beside the verdict. A verdict is a judgement
   about one task among many, and which ones came out the same way is
   most of what it means. Below the split width the detail keeps the
   screen. *)
let render_harness_detail (state : state) verdict =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll, max_scroll =
    if cols < keeper_split_threshold_cols then
      harness_detail_pane state ~rows ~cols verdict buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let labels =
        match state.harness with
        | None -> []
        | Some snapshot ->
          List.map (fun (row : Tui_decode.harness_verdict) -> row.Tui_decode.hv_task_id)
            snapshot.Tui_decode.hs_verdicts
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Verdicts"
        ~focused:false ~labels ~selected:state.harness_cursor;
      let answer =
        harness_detail_pane state ~rows ~cols:(cols - left_cols) verdict
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf
            "j/k:scroll (%d/%d)  PgUp/PgDn:page  left/Esc:list  Y:copy task  r:refresh"
            scroll max_scroll));
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

let fusion_run_status_color = function
  | Fusion_running -> (Theme.info ())
  | Fusion_completed -> (Theme.ok ())
  | Fusion_failed _ -> (Theme.bad ())

let fusion_run_stage_compact = function
  | Fusion_stage_accepted -> "accepted"
  | Fusion_stage_panel { frs_expected } ->
      Printf.sprintf "panel(%d)" frs_expected
  | Fusion_stage_judge { frs_answered; frs_failed; _ } ->
      Printf.sprintf "judge(%d/%d)" frs_answered frs_failed
  | Fusion_stage_computed { frs_answered; frs_failed; _ } ->
      Printf.sprintf "computed(%d/%d)" frs_answered frs_failed
  | Fusion_stage_recording_evidence { frs_answered; frs_failed; _ } ->
      Printf.sprintf "recording(%d/%d)" frs_answered frs_failed
  | Fusion_stage_completed -> "completed"
  | Fusion_stage_failed -> "failed"

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
  Terminal_text.clock_timestamp
    (Masc_domain.iso8601_of_unix_seconds run.fur_started_at)

let fusion_run_age ~now run =
  Option.value ~default:"\xe2\x80\x94"
    (Message_layout.age_text ~now ~since:run.fur_started_at)

let fusion_run_summary run =
  let flow = "Flow: Question \xe2\x86\x92 Panel \xe2\x86\x92 Judge \xe2\x86\x92 Evidence" in
  match run.fur_status with
  | Fusion_running ->
      ((Masc_tui_theme.tone Masc_tui_theme.Accent), flow ^ " \xc2\xb7 " ^ fusion_run_progress_text run.fur_stage)
  | Fusion_completed ->
      (match run.fur_decision, run.fur_summary with
       | Some decision, Some summary ->
           ( (Theme.ok ())
           , Terminal_text.single_line decision ^ " \xc2\xb7 "
             ^ Terminal_text.single_line summary )
       | (Some _ | None), (Some _ | None) ->
           ( (Theme.ok ())
           , flow ^ " \xc2\xb7 evidence retained; Enter opens panel and judge" ))
  | Fusion_failed failure ->
      ( (Theme.bad ())
      , Printf.sprintf "%s \xc2\xb7 failed [%s]: %s" flow
          (Terminal_text.single_line failure.frs_failure_code)
          (Terminal_text.single_line failure.frs_error) )

let render_fusion_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let runs =
    match state.fusion_runs with
    | None -> []
    | Some snapshot -> snapshot.fus_runs
  in
  let shown = List.length runs in
  let now_epoch = Unix.gettimeofday () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.fusion_runs with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Fusion") timestamp
          (connection_badge state)
    | Some _ ->
        let completed_count =
          List.fold_left
            (fun acc (r : Tui_decode.fusion_run) ->
               if r.fur_status = Tui_decode.Fusion_completed then acc + 1 else acc)
            0 runs
        in
        let failed_count =
          List.fold_left
            (fun acc (r : Tui_decode.fusion_run) ->
               match r.fur_status with Tui_decode.Fusion_failed _ -> acc + 1 | _ -> acc)
            0 runs
        in
        let running_count = Stdlib.max 0 (shown - completed_count - failed_count) in
        let stats_note =
          Printf.sprintf " (%d runs · %s%d done%s · %s%d run%s%s)"
            shown
            (Theme.ok ()) completed_count Ansi.reset
            (Theme.info ()) running_count Ansi.reset
            (if failed_count > 0 then Printf.sprintf " · %s%d fail%s" (Theme.bad ()) failed_count Ansi.reset else "")
        in
        Printf.sprintf "%s%s  %s  %s"
          (screen_title " MASC Fusion") stats_note timestamp
          (connection_badge state)
  in
  (* Measured from the rows, the way the Approvals table measures its own
     name column. Eighteen of twenty-eight keepers were cut at sixteen while
     RUN, a [kmsg-] and thirty-two hex digits nobody reads off a screen, sat
     whole beside them -- and the detail pane already carries that id in full
     under Link. RUN is last, so what it loses is the end of an identifier the
     pane below repeats. *)
  let keeper_width =
    List.fold_left
      (fun widest (run : Tui_decode.fusion_run) ->
        max widest
          (Message_layout.display_width
             (Terminal_text.single_line run.fur_keeper)))
      16 runs
    |> min 26
  in
  (* The run id takes what the named columns leave, once the keeper column has
     been sized to the names it actually holds. *)
  let run_width =
    Render_schedule.fusion_run_width ~keeper_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Render_schedule.fusion_header_row ~keeper_width ~run_width);
  box_divider buf cols;
  (match state.fusion_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.fusion_error in
  (* The selected run's lifecycle is a reading, not footer help. Reserve one
     row for it so every run says where it is in the four-stage flow. *)
  let content_height = max 1 (rows - chrome_rows - 1) in
  let scroll =
    if state.fusion_cursor >= content_height then
      state.fusion_cursor - content_height + 1
    else 0
  in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.fusion_runs ~error:state.fusion_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (no retained Fusion runs)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      let row_index = index + scroll in
      match List.nth_opt runs row_index with
      | None -> box_empty buf cols
      | Some run ->
          let status = fusion_run_status_to_string run.fur_status in
          let state_text =
            match run.fur_status with
            | Fusion_running -> fusion_run_stage_compact run.fur_stage
            | Fusion_completed | Fusion_failed _ -> status
          in
          let line =
            Render_schedule.fusion_row ~keeper_width ~run_width
              ~state_style:(fusion_run_status_color run.fur_status)
              { Render_schedule.frow_time = fusion_run_clock run
              ; frow_age = fusion_run_age ~now:now_epoch run
              ; frow_state = state_text
              ; frow_keeper = Terminal_text.single_line run.fur_keeper
              ; frow_preset = Terminal_text.single_line run.fur_preset
              ; frow_run = Terminal_text.single_line run.fur_run_id
              }
          in
          if row_index = state.fusion_cursor then
            box_line buf cols (Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line)
          else box_line buf cols ("  " ^ line)
    done;
  (match List.nth_opt runs state.fusion_cursor with
   | None -> box_empty buf cols
   | Some selected ->
       let style, summary = fusion_run_summary selected in
       box_line_styled buf cols ~style ("  " ^ summary));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints Fusion));
  finish_surface state ~surface_key:"fusion-list" ~rows:terminal_rows ~cols buf

(* The panel as marks, one per model, filled where the model answered.

   Which preset ran and whether the panel that fed the judge was whole is the
   first thing an operator reads off a run, and the pane said it in a sentence
   of counts -- "judge-of-judges  first x3  meta x1" -- with the failures
   counted somewhere else entirely. A model that did not answer is a hole in
   the row here, so a thin panel is seen before it is read.

   Past the cap the row would stop being countable at a glance, so it becomes
   the two numbers it was drawn from. *)
let fusion_panel_dots ~answered ~failed =
  let cap = 24 in
  let filled = "\xe2\x97\x8f" in
  let hollow = "\xe2\x97\x8b" in
  let run style mark n =
    if n <= 0 then ""
    else style ^ String.concat "" (List.init n (fun _ -> mark)) ^ Ansi.reset
  in
  match answered + failed with
  | 0 -> ""
  | total when total > cap ->
    Printf.sprintf "%s%d\xc3\x97%s%s  %s%d\xc3\x97%s%s"
      (Theme.ok ()) answered filled Ansi.reset
      (Theme.bad ()) failed hollow Ansi.reset
  | _ -> run (Theme.ok ()) filled answered ^ run (Theme.bad ()) hollow failed
;;

let fusion_wrapped_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  String.split_on_char '\n' text
  |> List.concat_map (fun raw ->
         let safe = Terminal_text.single_line raw in
         if String.equal safe "" then [ indent ^ "(empty)" ]
         else
           Message_layout.wrap_words ~max_cells:body_width safe
           |> List.map (fun line -> indent ^ line))
  |> List.map (fun line -> Ansi.reset, line)

let fusion_markdown_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  if String.equal (String.trim text) "" then [ Ansi.dim, indent ^ "(empty)" ]
  else
    document_markdown ~width:body_width text
    |> List.map (fun line -> Ansi.reset, indent ^ line)

let fusion_labeled_markdown ~width ~label text =
  (Ansi.bold, "  " ^ label)
  :: fusion_markdown_block ~width ~indent:"    " text

let fusion_tool_actor_text actor =
  match actor.fta_phase with
  | Fusion_tool_panel -> "panel/" ^ Terminal_text.single_line actor.fta_identity
  | Fusion_tool_judge role ->
      Printf.sprintf "judge/%s/%s" (fusion_judge_role_label role)
        (Terminal_text.single_line actor.fta_identity)

let fusion_tool_agent_suffix actor agent_name =
  if String.equal actor.fta_identity agent_name
  then ""
  else "  agent=" ^ Terminal_text.single_line agent_name

let fusion_tool_preview_lines ~width ~label preview =
  let size =
    if preview.ftp_truncated
    then Printf.sprintf "%d bytes; preview truncated" preview.ftp_bytes
    else Printf.sprintf "%d bytes" preview.ftp_bytes
  in
  let payload_text =
    if preview.ftp_truncated
    then preview.ftp_text
    else
      try
        preview.ftp_text
        |> Yojson.Safe.from_string
        |> Yojson.Safe.pretty_to_string
      with
      | Yojson.Json_error _ -> preview.ftp_text
  in
  let trimmed = String.trim payload_text in
  let body =
    if String.starts_with ~prefix:"{" trimmed
       || String.starts_with ~prefix:"[" trimmed
    then "```json\n" ^ payload_text ^ "\n```"
    else payload_text
  in
  [ Ansi.dim, Printf.sprintf "    %s (%s)" label size ]
  @ fusion_markdown_block ~width ~indent:"      " body

let fusion_tool_event_lines ~width = function
  | Fusion_tool_called event ->
      [ ( (Masc_tui_theme.tone Masc_tui_theme.Accent)
        , Printf.sprintf "  [called] %s%s  %s  turn %d/%d  id=%s"
            (fusion_tool_actor_text event.fte_actor)
            (fusion_tool_agent_suffix event.fte_actor event.fte_agent_name)
            (Terminal_text.single_line event.fte_tool_name)
            event.fte_turn event.fte_planned_index
            (Terminal_text.single_line event.fte_tool_use_id) )
      ]
      @ fusion_tool_preview_lines ~width ~label:"Input" event.fte_input
  | Fusion_tool_completed event ->
      let status, style, output, failure_suffix =
        match event.fte_completion with
        | Fusion_tool_succeeded output -> ("succeeded", Theme.ok (), output, "")
        | Fusion_tool_failed { ftc_output; ftc_recoverable; ftc_error_class }
          ->
          ( "failed"
          , Theme.bad ()
          , ftc_output
          , Printf.sprintf "  recoverable=%b%s" ftc_recoverable
              (match ftc_error_class with
               | Some class_ -> " class=" ^ Terminal_text.single_line class_
               | None -> " class=unavailable") )
      in
      [ ( style
        , Printf.sprintf "  [%s] %s%s  %s  turn %d/%d  id=%s%s" status
            (fusion_tool_actor_text event.fte_actor)
            (fusion_tool_agent_suffix event.fte_actor event.fte_agent_name)
            (Terminal_text.single_line event.fte_tool_name)
            event.fte_turn event.fte_planned_index
            (Terminal_text.single_line event.fte_tool_use_id)
            failure_suffix )
      ]
      @ fusion_tool_preview_lines ~width ~label:"Output" output

let fusion_tool_trace_lines ~width (trace : Tui_decode.fusion_tool_trace) =
      let coverage =
        if trace.ftt_complete
        then
          ( Theme.ok ()
          , Printf.sprintf "  Coverage: complete across %d AGENT_CORE actor(s)"
              (List.length trace.ftt_observed_actors) )
        else
          ( Theme.warn ()
          , Printf.sprintf
              "  Coverage: partial across %d actor(s) (%d dropped event(s), %d gap(s))"
              (List.length trace.ftt_observed_actors)
              trace.ftt_dropped_events (List.length trace.ftt_gaps) )
      in
      let observed =
        match trace.ftt_observed_actors with
        | [] -> [ Ansi.dim, "  Observed actors: (none)" ]
        | actors ->
            fusion_wrapped_block ~width ~indent:"  "
              ("Observed actors: "
               ^ String.concat ", " (List.map fusion_tool_actor_text actors))
      in
      let gaps =
        List.map
          (fun gap ->
             ( Theme.warn ()
             , Printf.sprintf "  Gap: %s [%s]"
                 (fusion_tool_actor_text gap.ftg_actor)
                 (Terminal_text.single_line gap.ftg_reason) ))
          trace.ftt_gaps
      in
      let events =
        match trace.ftt_events with
        | [] when trace.ftt_complete ->
            [ Ansi.dim, "  No Tool calls were observed for instrumented actors" ]
        | [] -> [ Ansi.dim, "  No Tool events retained in this partial ledger" ]
        | events ->
            events
            |> List.concat_map (fun event ->
                   (Ansi.dim, "") :: fusion_tool_event_lines ~width event)
      in
      (coverage :: observed) @ gaps @ events

let fusion_pipeline_diagram (run : Tui_decode.fusion_run) =
  let glyph_done = (Theme.ok ()) ^ "\xe2\x97\x8f" ^ Ansi.reset in
  let glyph_active = (Theme.warn ()) ^ "\xe2\x97\x90" ^ Ansi.reset in
  let glyph_waiting = Ansi.dim ^ "\xe2\x97\x8b" ^ Ansi.reset in
  let glyph_failed = (Theme.bad ()) ^ "\xc3\x97" ^ Ansi.reset in
  let arrow = " " ^ (Theme.recede ()) ^ "\xe2\x96\xb8" ^ Ansi.reset ^ " " in
  let status =
    match run.fur_status with
    | Fusion_completed -> `Completed
    | Fusion_running -> `Running
    | Fusion_failed _ -> `Failed
  in
  let stage, panel_answered, panel_expected =
    match run.fur_stage with
    | Fusion_stage_accepted -> `Accepted, 0, 0
    | Fusion_stage_panel { frs_expected } -> `Panel, 0, frs_expected
    | Fusion_stage_judge { frs_expected; frs_answered; _ } -> `Judge, frs_answered, frs_expected
    | Fusion_stage_computed { frs_answered; frs_expected; _ }
    | Fusion_stage_recording_evidence { frs_answered; frs_expected; _ } -> `Evidence, frs_answered, frs_expected
    | Fusion_stage_completed -> `Completed, 0, 0
    | Fusion_stage_failed -> `Failed, 0, 0
  in
  Render_schedule.fusion_pipeline_diagram
    ~glyph_done ~glyph_active ~glyph_waiting ~glyph_failed ~arrow
    ~status ~stage ~panel_answered ~panel_expected ()

let fusion_detail_lines ~width (detail : fusion_detail) =
  let run = detail.fud_run in
  let status = fusion_run_status_to_string run.fur_status in
  let now = Unix.gettimeofday () in
  let tm = Unix.localtime run.fur_started_at in
  let date_time =
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let age = fusion_run_age ~now run in
  let started_text = Printf.sprintf "%s (%s ago)" date_time age in
  let pipeline = fusion_pipeline_diagram run in
  let run_lines =
    [ Ansi.bold, "  RUN"
    ; (Masc_tui_theme.tone Masc_tui_theme.Accent), "  Flow: Question \xe2\x86\x92 Panel \xe2\x86\x92 Judge \xe2\x86\x92 Evidence"
    ; Ansi.reset, "  Pipeline: " ^ pipeline
    ; ( Ansi.reset
      , Printf.sprintf "  Actions: %s[Y]%s Copy Link   %s[PgUp/PgDn]%s Page   %s[Esc]%s Back to Runs"
          (Theme.info ()) Ansi.reset
          (Theme.info ()) Ansi.reset
          (Theme.info ()) Ansi.reset )
    ; ( Ansi.dim
      , "  Link: "
        ^ Link.reference Fusion_run
            (Terminal_text.single_line run.fur_run_id) )
    ; ( Ansi.reset
      , Printf.sprintf "  Caller: %s@%s%s %s[Keeper]%s  \xc2\xb7  %s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line run.fur_keeper)
          Ansi.reset
          (Theme.warn ())
          Ansi.reset
          (Link.reference Keeper (Terminal_text.single_line run.fur_keeper)) )
    ; fusion_run_status_color run.fur_status, "  Status: " ^ status
    ; (Masc_tui_theme.tone Masc_tui_theme.Accent), "  Stage: " ^ fusion_run_stage_to_string run.fur_stage
    ; Ansi.dim, "  Progress: " ^ fusion_run_progress_text run.fur_stage
    ; ( Ansi.reset
    , "  Configuration: " ^ Terminal_text.single_line run.fur_preset ^ " \xc2\xb7 "
      ^ Fusion_types.fusion_topology_to_string run.fur_topology )
    ; Ansi.dim, "  Started: " ^ started_text
    ]
    @
    match run.fur_status with
    | Fusion_running -> []
    | Fusion_completed ->
        (match run.fur_decision, run.fur_summary with
         | Some decision, Some summary ->
             [ (Theme.ok ()), "  Outcome: " ^ Terminal_text.single_line decision ]
             @ fusion_labeled_markdown ~width ~label:"Outcome summary" summary
         | (Some _ | None), (Some _ | None) -> [])
    | Fusion_failed failure ->
        [ (Theme.bad ())
        , Printf.sprintf "  Registry failure [%s]: %s"
            (Terminal_text.single_line failure.frs_failure_code)
            (Terminal_text.single_line failure.frs_error)
        ]
  in
  let evidence_lines =
    match detail.fud_evidence_status, detail.fud_evidence with
    | Fusion_evidence_pending, None ->
        [ (Theme.warn ()), "  Evidence: pending (run is still running)" ]
    | Fusion_evidence_absent, None ->
        [ (Theme.warn ())
        , "  Evidence: absent (no current Board projection for this retained run)"
        ]
    | Fusion_evidence_recorded, Some evidence ->
        let answered, failed, input_tokens, output_tokens =
          List.fold_left
            (fun (answered, failed, input_tokens, output_tokens) result ->
              match result with
              | Fusion_panel_answered answer ->
                  ( answered + 1
                  , failed
                  , input_tokens + answer.fpa_input_tokens
                  , output_tokens + answer.fpa_output_tokens )
              | Fusion_panel_failed _ ->
                  answered, failed + 1, input_tokens, output_tokens)
            (0, 0, 0, 0) evidence.fe_panel
        in
        let panel_lines =
          evidence.fe_panel
          |> List.mapi (fun index result ->
                 match result with
                 | Fusion_panel_answered answer ->
                     [ ( (Theme.ok ())
                       , Printf.sprintf
                           "  Panel %d [answered] %s  (%d in / %d out)"
                           (index + 1)
                           (Terminal_text.single_line answer.fpa_model)
                           answer.fpa_input_tokens answer.fpa_output_tokens )
                     ]
                     @ fusion_markdown_block ~width ~indent:"    "
                         answer.fpa_answer
                 | Fusion_panel_failed failure ->
                     [ ( (Theme.bad ())
                       , Printf.sprintf "  Panel %d [failed] %s  [%s]"
                           (index + 1)
                           (Terminal_text.single_line failure.fpf_model)
                           (Terminal_text.single_line failure.fpf_reason_code) )
                     ]
                     @ fusion_wrapped_block ~width ~indent:"    "
                         failure.fpf_reason_detail)
          |> List.concat
        in
        let panel_token_items =
          List.filter_map
            (function
              | Fusion_panel_answered answer ->
                  Some
                    { Chart.name = Terminal_text.single_line answer.fpa_model
                    ; count = answer.fpa_input_tokens + answer.fpa_output_tokens
                    ; style = Some (Chart.Status Masc_tui_theme.Ok)
                    }
              | Fusion_panel_failed failure ->
                  Some
                    { Chart.name = Terminal_text.single_line failure.fpf_model
                    ; count = 0
                    ; style = Some (Chart.Status Masc_tui_theme.Bad)
                    })
            evidence.fe_panel
        in
        let panel_chart_lines =
          if List.length panel_token_items >= 2 then
            (Ansi.dim, "  Model token distribution:")
            :: List.map (fun row -> (Ansi.reset, row)) (Chart.distribution_bars ~width panel_token_items)
            @ [ Ansi.dim, "" ]
          else []
        in
        let judge_lines =
          match evidence.fe_judge with
          | Fusion_judge_synthesized judge ->
              [ ( (Theme.info ())
                , "  Judge [synthesized] "
                  ^ Terminal_text.single_line judge.fj_decision )
              ]
              @ fusion_labeled_markdown ~width ~label:"Resolved"
                  judge.fj_resolved_answer
              @ fusion_labeled_markdown ~width ~label:"Reason" judge.fj_reason
          | Fusion_judge_failed failure ->
              [ ( (Theme.bad ())
                , "  Judge [failed] ["
                  ^ Terminal_text.single_line failure.fj_failure_code
                  ^ "]" )
              ]
              @ fusion_wrapped_block ~width ~indent:"    " failure.fj_error
        in
        (* RFC-0284 judge nodes. The canonical [Judge] row above is the final
           synthesis; this block is the topology it came through -- first the
           observed shape as one line, then one card per first-pass lens.
           Meta/stage/final nodes stay in the shape line only: their output
           is intermediate synthesis, and printing it next to the final one
           would render the same deliberation twice. Pre-RFC posts decode
           with no nodes and draw none of this. *)
        let judges_lines =
          match evidence.fe_judges with
          | [] -> []
          | nodes ->
              let count_role wanted =
                List.fold_left
                  (fun n node ->
                    if node.fjn_role = wanted then n + 1 else n)
                  0 nodes
              in
              let firsts = count_role Judge_first in
              let metas = count_role Judge_meta in
              let stage_metas = count_role Judge_stage_meta in
              let final_metas = count_role Judge_final_meta in
              let refines = count_role Judge_refine in
              let singles = count_role Judge_single in
              let shape =
                (* Same reading the dashboard's shape classifier makes: a
                   first-pass judge only exists in a judge-of-judges run,
                   and stage/final metas only in the staged one. *)
                if stage_metas > 0 || final_metas > 0 then "staged judge-of-judges"
                else if firsts > 0 then "judge-of-judges"
                else if refines > 0 then "refine"
                else "single"
              in
              let counts =
                List.filter_map
                  (fun (label, n) ->
                    if n > 0 then Some (Printf.sprintf "%s \xc3\x97%d" label n) else None)
                  [ ("first", firsts); ("meta", metas); ("stage-meta", stage_metas)
                  ; ("final-meta", final_metas); ("refine", refines)
                  ; ("single", singles) ]
              in
              let first_cards =
                nodes
                |> List.filter (fun node -> node.fjn_role = Judge_first)
                |> List.mapi (fun index node ->
                       match node.fjn_outcome with
                       | Judge_node_synthesized synthesized ->
                           [ ( (Theme.info ())
                             , Printf.sprintf
                                 "  First %d [synthesized] %s  (%d in / %d out)"
                                 (index + 1)
                                 (Terminal_text.single_line node.fjn_identity)
                                 synthesized.fjno_input_tokens
                                 synthesized.fjno_output_tokens )
                           ]
                           @ fusion_labeled_markdown ~width
                               ~label:
                                 (Printf.sprintf "First %d %s" (index + 1)
                                    (Terminal_text.single_line node.fjn_identity))
                               synthesized.fjno_resolved_answer
                       | Judge_node_failed failed ->
                           let clock =
                             match (failed.fjno_timed_out, failed.fjno_elapsed_s) with
                             | true, _ -> "  (timed out)"
                             | false, Some seconds ->
                                 Printf.sprintf "  (%.0fs)" seconds
                             | false, None -> ""
                           in
                           [ ( (Theme.bad ())
                             , Printf.sprintf
                                 "  First %d [failed] %s  [%s]%s"
                                 (index + 1)
                                 (Terminal_text.single_line node.fjn_identity)
                                 (Terminal_text.single_line failed.fjno_failure_code)
                                 clock )
                           ]
                           @ fusion_wrapped_block ~width ~indent:"    "
                               failed.fjno_error)
                |> List.concat
              in
              [ Ansi.dim, "" ]
              (* The counts are already in pipeline order, so joining them
                 with the same arrow the Goal stage rail uses draws the run
                 rather than describing it. The shape name stays, at the end,
                 because it is what the preset is called. *)
              @ ( Ansi.dim
                , Printf.sprintf "  %s  \xe2\x94\x80\xe2\x96\xb6  %s  \xc2\xb7  %s"
                    (fusion_panel_dots ~answered ~failed)
                    (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " counts)
                    shape )
              :: first_cards
        in
        let tool_lines =
          fusion_tool_trace_lines ~width evidence.fe_tool_trace
        in
        [ Ansi.bold, "  Title: " ^ Terminal_text.single_line evidence.fe_title
        ; Ansi.dim, ""
        ; Ansi.bold, "  1  QUESTION"
        ]
        @ fusion_markdown_block ~width ~indent:"    " evidence.fe_question
        @ [ Ansi.dim, ""
          ; Ansi.bold, "  2  PANEL RESPONSES"
          ; ( Ansi.dim
            , Printf.sprintf
                "  %d answered / %d failed  \xc2\xb7  %d input / %d output tokens"
                answered failed input_tokens output_tokens )
        ]
        @ [ Ansi.dim, "" ]
        @ panel_chart_lines
        @ panel_lines
        @ [ Ansi.dim, ""
          ; Ansi.bold, "  3  JUDGE"
          ]
        @ judge_lines
        @ judges_lines
        @ [ Ansi.dim, ""
          ; Ansi.bold, "  4  TOOL EXECUTIONS"
          ]
        @ tool_lines
        @ [ Ansi.dim, ""
          ; Ansi.bold, "  5  EVIDENCE RECORDED"
          ; ( Ansi.dim
            , "  Board link: "
              ^ Link.reference Board_post
                  (Terminal_text.single_line evidence.fe_post_id) )
          ]
    | Fusion_evidence_recorded, None
    | Fusion_evidence_pending, Some _
    | Fusion_evidence_absent, Some _ ->
        (* The strict decoder makes these states unreachable. Keeping the row
           explicit protects locally-constructed test state from looking like
           a legitimate empty reading. *)
        [ (Theme.bad ()), "  Fusion evidence invariant violated" ]
  in
  run_lines @ [ Ansi.dim, "" ] @ evidence_lines

let fusion_detail_pane (state : state) ~rows ~cols run_id buf =
  let detail =
    match state.fusion_detail with
    | Some detail when String.equal detail.fud_run.fur_run_id run_id ->
        Some detail
    | Some _ | None -> None
  in
  let header =
    Printf.sprintf "%s  %s  %s" (screen_title " MASC Fusion")
      (fit_width (Terminal_text.single_line run_id) 38)
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.fusion_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       box_divider buf cols);
  let chrome_rows =
    if Option.is_some state.fusion_detail_error then 7 else 5
  in
  let content_height = max 1 (rows - chrome_rows) in
  let lines =
    match detail, state.fusion_detail_error with
    | None, None -> [ Ansi.dim, "  (loading exact Fusion detail)" ]
    | None, Some _ ->
        [ Ansi.dim, "  (load failed; nothing here is a reading)" ]
    | Some detail, (Some _ | None) ->
        fusion_detail_lines ~width:(max 1 (cols - 8)) detail
  in
  let total = List.length lines in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.fusion_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (index + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  scroll, max_scroll
;;

(* The run list stays beside the run. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_fusion_detail (state : state) run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let scroll, max_scroll =
    if cols < keeper_split_threshold_cols then
      fusion_detail_pane state ~rows ~cols run_id buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let format_sidebar_fusion (row : Tui_decode.fusion_run) =
        let status =
          match row.fur_status with
          | Tui_decode.Fusion_running -> "run "
          | Tui_decode.Fusion_completed -> "done"
          | Tui_decode.Fusion_failed _ -> "fail"
        in
        let time = fusion_run_clock row in
        let keeper = Terminal_text.single_line row.fur_keeper in
        let run_id = Terminal_text.single_line row.fur_run_id in
        Render_schedule.fusion_sidebar_label ~status ~time ~keeper ~run_id
      in
      let labels =
        match state.fusion_runs with
        | None -> []
        | Some snapshot ->
          List.map format_sidebar_fusion snapshot.Tui_decode.fus_runs
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Fusion"
        ~focused:false ~labels ~selected:state.fusion_cursor;
      let answer =
        fusion_detail_pane state ~rows ~cols:(cols - left_cols) run_id
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_fusion_detail ~scroll ~max_scroll));
  finish_surface state ~clamped:(Fusion_detail_scroll scroll)
    ~surface_key:"fusion-detail" ~rows:terminal_rows ~cols buf

(* The repositories a keeper can work in.  The server sends both the stored
   path spelling and the absolute path it actually resolves.  The latter is
   what an operator needs before opening a shell or comparing another
   checkout; resolving the stored spelling again in the TUI would use the
   TUI's cwd instead of the server's base path. *)
let repository_context_lines ~width (repo : Masc.Tui_decode.repository) =
  let wrap label value =
    Message_layout.wrap_words ~max_cells:(max 1 width)
      (Printf.sprintf "  %s: %s" label (Terminal_text.single_line value))
  in
  let stored_path =
    if String.equal repo.rp_local_path repo.rp_resolved_local_path then []
    else wrap "Stored as" repo.rp_local_path
  in
  let keepers =
    match repo.rp_keepers with
    | [] -> "none assigned"
    | names -> String.concat ", " names
  in
  wrap "Path" repo.rp_resolved_local_path
  @ stored_path
  @ wrap "Keepers" keepers

let render_repository_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let repos =
    match state.repositories with
    | None -> []
    | Some s -> s.Masc.Tui_decode.rs_repositories
  in
  let shown = List.length repos in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.repositories with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Workspace") timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d)  %s  %s"
          (screen_title " MASC Workspace") shown timestamp
          (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"repositories"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      (* The path takes what the named columns leave, asked of the columns
         rather than of a constant standing in for their total. *)
      let path_width =
        Render_schedule.workspace_path_width
          ~inner_width:(max 1 (framed_inner_width cols - 2))
      in
      c.push_styled ~style:(Theme.recede ())
        ("  " ^ Render_schedule.workspace_header_row ~path_width);
      c.push_divider ();
      (match state.repositories_error with
       | None -> ()
       | Some detail ->
           c.push_styled ~style:(Theme.bad ())
             ("  " ^ Keeper_chat.terminal_safe_text detail);
           c.push_divider ());
      let context_lines =
        match List.nth_opt repos state.repositories_cursor with
        | None -> []
        | Some repo -> repository_context_lines ~width:(cols - 6) repo
      in
      let context_rows =
        match context_lines with [] -> 0 | _ -> 1 + List.length context_lines
      in
      let fixed =
        2 + context_rows
        + (if Option.is_some state.repositories_error then 2 else 0)
      in
      let room = max 1 (budget - fixed) in
      let overflowing = shown > room in
      let content_height = if overflowing then max 1 (room - 1) else room in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min state.repositories_scroll max_scroll) in
      if shown = 0 then
        let empty =
          match
            empty_page_of ~snapshot:state.repositories
              ~error:state.repositories_error
          with
          | Page_failed -> page_failed_note
          | Page_unread -> page_unread_note
          | Page_empty -> "  (no repositories registered)"
        in
        c.push_styled ~style:(Theme.recede ()) empty
      else begin
        for i = 0 to content_height - 1 do
          let idx = i + scroll in
          match List.nth_opt repos idx with
          | None -> c.push_empty ()
          | Some r ->
              let open Masc.Tui_decode in
              let line =
                "  "
                ^ Render_schedule.workspace_row ~path_width
                    { Render_schedule.wrow_name =
                        Terminal_text.single_line r.rp_name
                    ; wrow_branch =
                        Terminal_text.single_line r.rp_default_branch
                    ; wrow_status = Terminal_text.single_line r.rp_status
                    ; wrow_sync = (if r.rp_auto_sync then "auto" else "manual")
                    ; wrow_path =
                        Terminal_text.single_line r.rp_resolved_local_path
                    }
              in
              if idx = state.repositories_cursor then c.push_selected line
              else c.push line
        done;
        if overflowing then
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "[%d repositories, scroll %d]" shown scroll)
      end;
      (match context_lines with
       | [] -> ()
       | lines ->
           c.push_divider ();
           List.iter (c.push_styled ~style:(Theme.recede ())) lines))

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
      match List.nth_opt diff_rows (i + scroll) with
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

let render_repository_changes (state : state) =
  match state.repository_changes_diff_path with
  | Some path -> render_repository_changes_diff state ~path
  | None ->
      let terminal_rows, cols = get_terminal_size () in
      let changes =
        match state.repository_changes with
        | Some snapshot -> snapshot.Masc.Tui_decode.rcs_changes
        | None -> []
      in
      let scope_name =
        match state.repository_changes_scope, state.repositories with
        | Some Tui_decode.Repository_change_project, _ -> "Project workspace"
        | Some (Tui_decode.Repository_change_repository id), Some snapshot ->
            (match
               List.find_opt
                 (fun (repo : Masc.Tui_decode.repository) ->
                   String.equal repo.rp_id id)
                 snapshot.rs_repositories
             with
             | Some repo -> repo.rp_name
             | None -> id)
        | Some (Tui_decode.Repository_change_repository id), None -> id
        | None, _ -> "Git workspace"
      in
      let title =
        Printf.sprintf " MASC Git Changes — %s (%d)  %s"
          (Terminal_text.single_line scope_name) (List.length changes)
          (connection_badge state)
      in
      let selected_path =
        match List.nth_opt changes state.repository_changes_cursor with
        | Some row -> Some row.rc_path
        | None -> None
      in
      let change_ctx = resolve_change_context state ~path_opt:selected_path in
      let context_lines = build_change_context_lines change_ctx in
      surface_chrome state ~terminal_rows ~cols ~surface_key:"repository-changes"
        ~title ~hints:Masc_tui_keys.footer_hints_git_changes
        ~body:(fun ~budget c ->
          List.iter
            (fun ctx_line ->
              c.push ctx_line;
              c.push_divider ())
            context_lines;
          c.push_styled ~style:(Theme.recede ())
            (Printf.sprintf "  %-18s %s" "State" "Path");
          c.push_divider ();
          (match state.repository_changes_error with
           | None -> ()
           | Some detail ->
               c.push_styled ~style:(Theme.bad ())
                 ("  " ^ Keeper_chat.terminal_safe_text detail);
               c.push_divider ());
          let fixed =
            2
            + (List.length context_lines * 2)
            + if Option.is_some state.repository_changes_error then 2 else 0
          in
          let room = max 1 (budget - fixed) in
          if changes = [] then
            c.push_styled ~style:(Theme.recede ())
              (match state.repository_changes, state.repository_changes_error with
               | None, None -> "  (loading Git changes)"
               | Some _, None -> "  (working tree clean)"
               | _, Some _ -> "  (Git changes unavailable)")
          else
            for i = 0 to room - 1 do
              let idx = state.repository_changes_scroll + i in
              match List.nth_opt changes idx with
              | None -> c.push_empty ()
              | Some row ->
                  let attr =
                    match state.msg_file_changes with
                    | Some snap ->
                        (match
                           List.find_opt
                             (file_change_matches_path row.rc_path)
                             snap.Masc.Tui_decode.fcs_changes
                         with
                         | Some fc ->
                             let t =
                               match fc.fc_task_id with
                               | Some tid -> tid
                               | None -> fc.fc_keeper
                             in
                             " [" ^ t ^ "]"
                         | None -> "")
                    | None -> ""
                  in
                  let line =
                    Printf.sprintf "  %-18s %s%s"
                      (repository_change_status row)
                      (Message_layout.fit_middle (max 8 (cols - 28 - String.length attr))
                         (Terminal_text.single_line row.rc_path))
                      attr
                  in
                  if idx = state.repository_changes_cursor then c.push_selected line
                  else c.push line
            done)

let render_memory (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let open Masc.Tui_decode in
  let keepers =
    match state.memory_health with
    | None -> []
    | Some s -> s.mhs_keepers
  in
  let shown = List.length keepers in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.memory_health with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Memory") timestamp
          (connection_badge state)
    | Some s ->
        Printf.sprintf
          "%s (%d keepers · %d failed/no ordinary · %d ordinary facts [o%d/d%d] · %d support-invalidated · %d source facts)  %s  %s"
          (screen_title " MASC Memory") shown s.mhs_starving_keepers
          s.mhs_total_facts s.mhs_total_observed_facts s.mhs_total_derived_facts
          s.mhs_total_support_invalidations s.mhs_total_source_facts timestamp
          (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"memory"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      Render_memory.render_memory_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

let render_memory_facts (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let open Masc.Tui_decode in
  let keeper_name = Option.value state.memory_facts_keeper ~default:"" in
  let rows = Masc_tui_types.memory_fact_rows state in
  let total = List.length rows in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let filter_label =
    Masc_tui_types.memory_category_filter_label state.memory_facts_category
  in
  let sort_label = Masc_tui_types.memory_sort_order_label state.memory_facts_sort in
  let query_label =
    match state.search with
    | Some q when String.length (String.trim q) > 0 ->
        Printf.sprintf " · find \"%s\"" (Terminal_text.single_line (String.trim q))
    | Some _ -> " · find \"\""
    | None ->
        if String.length (String.trim state.search_last) > 0 then
          Printf.sprintf " · filter \"%s\"" (Terminal_text.single_line (String.trim state.search_last))
        else ""
  in
  let title =
    match state.memory_facts with
    | None ->
        Printf.sprintf "%s \xe2\x96\xb8 %s  (not loaded)  %s  %s"
          (screen_title " MASC Memory") keeper_name timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s \xe2\x96\xb8 %s (%d facts · %s · sort: %s%s)  %s  %s"
          (screen_title " MASC Memory") keeper_name total filter_label sort_label query_label
          timestamp (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"memory-facts"
    ~title ~hints:Masc_tui_keys.footer_hints_memory_facts
    ~body:(fun ~budget c ->
      Render_memory.render_memory_facts_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

let render_repositories (state : state) =
  if state.repository_changes_open then render_repository_changes state
  else render_repository_list state

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

(* One line of what the change put there. An edit shows the text it wrote
   rather than the text it removed: the question a reader has is what the file
   says now. A write shows its size, because the whole body is never one row
   and a truncated first line of a new file says less than its length. *)
let change_row_summary (change : Masc.Tui_decode.file_change) =
  let content =
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { after; _ } -> Terminal_text.preview_line after
    | Masc.Tui_decode.Fc_inserted { text; _ } -> Terminal_text.preview_line text
    | Masc.Tui_decode.Fc_written { content } ->
      Printf.sprintf "(wrote %d bytes)" (String.length content)
  in
  match file_change_evidence_label change.fc_line_evidence with
  | None -> content
  | Some label ->
    Printf.sprintf "%s%s[%s]%s %s" Ansi.bold (Theme.info ()) label Ansi.reset
      content

let change_kind_badge (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited _ -> Theme.category Theme.Slot_4, "EDIT"
  | Masc.Tui_decode.Fc_inserted _ -> Theme.category Theme.Slot_4, "MEMO"
  | Masc.Tui_decode.Fc_written _ -> (Masc_tui_theme.tone Masc_tui_theme.Accent), "WRITE"

let change_result_badge (change : Masc.Tui_decode.file_change) =
  if change.Masc.Tui_decode.fc_succeeded then Theme.ok (), "APPLIED"
  else Theme.bad (), "FAILED"

(* A row of the diff, drawn as layers rather than as one styled string.

   Three styles overlap on every line: the row's background, the gutter's
   weight, and the text's own colour. Concatenating them would let the
   gutter's reset close the background, and the line would lose its colour
   from the marker onward -- the fault [Masc_tui_span] exists for. *)
let diff_row_span ~width (row : Diff.row) =
  let background, marker, text =
    match row with
    | Diff.Removed line -> (Span.bg Theme.Syntax.diff_removed_bg, "-", line)
    | Diff.Added line -> (Span.bg Theme.Syntax.diff_added_bg, "+", line)
    | Diff.Context line -> (Span.plain, " ", line)
  in
  (* Context is dim so the changed lines are what an eye lands on. The marker
     is bold against the same background, which is what tells the two apart
     where the terminal has no colour. *)
  let text_style =
    match row with
    | Diff.Context _ -> Span.combine background (Span.weight Ansi.dim)
    | Diff.Removed _ | Diff.Added _ -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.bold)) (marker ^ " ")
      ; Span.text text_style (Terminal_text.single_line text)
      ]
  in
  (* Padded to the full width with the row's own background: colour that stops
     at the last character makes lines of different lengths look like
     different kinds of line. Truncated first, because padding does not
     shorten. *)
  Span.pad_to width background (Span.truncate width composed)

(* The two halves of one change. A write has no removed half: its before is
   empty, so every line arrives as an addition, which is what a new file is. *)
let change_diff_halves (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited { before; after; _ } -> (before, after)
  | Masc.Tui_decode.Fc_inserted { text; _ } -> ("", text)
  | Masc.Tui_decode.Fc_written { content } -> ("", content)

let render_changes_diff (state : state) (change : Masc.Tui_decode.file_change) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let before, after = change_diff_halves change in
  let diff_rows = Diff.rows ~before ~after in
  let removed, added = Diff.counts diff_rows in
  let total = List.length diff_rows in
  let header =
    Printf.sprintf "%s %s  -%d +%d  %s"
      (screen_title " MASC Change")
      (Terminal_text.single_line (change_row_address change))
      removed added
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Facts about the change the rows themselves cannot carry. *)
  let notes =
    let turn =
      Printf.sprintf "  turn %s  task %s  %s"
        (Option.fold ~none:"-" ~some:string_of_int change.Masc.Tui_decode.fc_turn)
        (Terminal_text.single_line
           (Option.value ~default:"-" change.Masc.Tui_decode.fc_task_id))
        (if change.Masc.Tui_decode.fc_succeeded then "applied"
         else "the call failed; this is what it tried to write")
    in
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { replace_all = true; _ } ->
        (* Every occurrence changed, and the log records the text once. Showing
           one pair without saying so would undercount the change. *)
        [ turn; "  replace_all: every occurrence changed; the log holds the text once" ]
    | Masc.Tui_decode.Fc_edited { replace_all = false; _ }
    | Masc.Tui_decode.Fc_inserted _
    | Masc.Tui_decode.Fc_written _ -> [ turn ]
  in
  let notes =
    match file_change_evidence_label change.fc_line_evidence with
    | None -> notes
    | Some label -> notes @ [ "  producer lines " ^ label ]
  in
  List.iter (fun note -> box_line_styled buf cols ~style:(Theme.recede ()) note) notes;
  box_divider buf cols;
  (* Counted, not tallied. The tally read "7 + notes - 1" against four fixed
     rows plus the notes, which left the surface one row over its budget --
     and the row [finish_surface] then dropped was the footer, so the diff was
     the one screen that did not say how to leave it. *)
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.changes_diff_scroll max_scroll) in
  if total = 0 then begin
    box_line_styled buf cols ~style:(Theme.recede ())
      "  (the call recorded no text; there is nothing to compare)";
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match List.nth_opt diff_rows (i + scroll) with
      | None -> box_empty buf cols
      | Some row -> box_line_span buf cols (diff_row_span ~width:(framed_inner_width cols) row)
    done;
  if total > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d lines, scroll %d]  esc closes" total scroll)
  else box_line_styled buf cols ~style:(Theme.recede ()) "  esc closes";
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"j/k:scroll  left/esc:back  o:open in editor  q:quit");
  finish_surface state ~clamped:(Changes_diff_scroll scroll)
    ~surface_key:"changes" ~rows:terminal_rows ~cols buf

let render_changes_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let changes =
    match state.changes with
    | None -> []
    | Some s -> s.Masc.Tui_decode.fcs_changes
  in
  let shown = List.length changes in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let whose =
    match state.changes_keeper with
    | None -> "(no keeper selected)"
    | Some name -> Terminal_text.single_line name
  in
  let header =
    match state.changes with
    | None ->
        Printf.sprintf "%s %s  (not loaded)  %s  %s"
          (screen_title " MASC Changes") whose timestamp
          (connection_badge state)
    | Some s ->
        (* The window and the call count are stated because the list alone
           does not say what was looked at: no changes in a window and no
           calls in a window are different facts. *)
        Printf.sprintf "%s %s (%d in %.0fh of %d calls)  %s  %s"
          (screen_title " MASC Changes") whose shown
          s.Masc.Tui_decode.fcs_window_hours s.Masc.Tui_decode.fcs_calls_in_window
          timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* What the turn did takes the cells the named columns leave. *)
  let summary_width =
    Render_schedule.change_summary_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.change_header_row ~summary_width
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.changes_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* Changes the log could not carry are said out loud. A list that showed
     only what it had would tell an operator the turn wrote less than it did. *)
  let budget_note =
    match state.changes with
    | Some s when s.Masc.Tui_decode.fcs_over_budget > 0 ->
        Some
          (Printf.sprintf
             "  %d change(s) outgrew the tool-call log's inline budget; their text is not on disk"
             s.Masc.Tui_decode.fcs_over_budget)
    | Some _ | None -> None
  in
  (match budget_note with
   | None -> ()
   | Some note ->
       box_line_styled buf cols ~style:(Theme.recede ()) note;
       box_divider buf cols);
  (* The chrome and the preview's share both come from [scrolled_surface],
     which the keypress reads too. Working them out again here is what drifted
     the last time: this counted the over-budget note's two rows and the bound
     did not, and then the preview took half the body and the bound still did
     not know. *)
  let chrome_rows, preview_keep =
    match scrolled_surface state Changes with
    | Some s -> (s.sc_chrome, s.sc_preview_keep)
    | None -> (listing_chrome ~error:state.changes_error, None)
  in
  let total_content = max 1 (rows - chrome_rows) in
  (* The cursor row's recorded diff previews under the list, from the same
     local snapshot Enter renders -- no request rides a keypress. The list
     keeps at least [changes_preview_keep_rows] rows; the preview takes what
     remains.

     The split comes from Masc_tui_scroll because the keypress has to obey
     the height this draws. It also cannot depend on which row the cursor is
     on: reading the unclamped scroll to decide whether there is a preview
     made the height depend on the value that height was bounding, and the
     rows past the shortened list became unreachable. *)
  let preview_height =
    match preview_keep with
    | None -> 0
    | Some _ when shown = 0 -> 0
    | Some keep -> Masc_tui_scroll.preview_height ~total:total_content ~keep
  in
  let content_height = max 1 (total_content - preview_height) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.changes_scroll max_scroll) in
  (* The marked row, not the window's top row. They were the same field, so
     the mark never left the first drawn row: every row below it was visible
     and unselectable, and Enter always opened whichever change the window
     happened to start on. *)
  let cursor = max 0 (min state.changes_cursor (max 0 (shown - 1))) in
  let cursor_change = List.nth_opt changes cursor in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.changes ~error:state.changes_error with
      | Page_failed -> page_failed_note
      | Page_unread -> "  (pick a keeper on the Keepers surface, then press r)"
      | Page_empty -> "  (this keeper wrote no files in the window)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt changes idx with
      | None -> box_empty buf cols
      | Some change ->
          let kind_style, kind = change_kind_badge change in
          let result_style, result = change_result_badge change in
          let line =
            "  "
            ^ Render_schedule.change_row ~op_style:kind_style ~result_style
                ~summary_width
                { Render_schedule.crow_turn =
                    Option.fold ~none:"-" ~some:string_of_int
                      change.Masc.Tui_decode.fc_turn
                ; crow_task =
                    Terminal_text.single_line
                      (Option.value ~default:"-"
                         change.Masc.Tui_decode.fc_task_id)
                ; crow_op = kind
                ; crow_result = result
                ; crow_file =
                    Terminal_text.single_line (change_row_address change)
                ; crow_summary = change_row_summary change
                }
          in
          (* A call that failed still changed what the keeper tried to do, and
             it is the row an operator is looking for. Dim marks it as an
             attempt rather than hiding it. *)
          if idx = cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  (match cursor_change with
   | None -> ()
   | Some change when preview_height >= 2 ->
       let before, after = change_diff_halves change in
       let diff_rows = Diff.rows ~before ~after in
       let removed, added = Diff.counts diff_rows in
       box_divider buf cols;
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "  preview %s  -%d +%d  (Enter opens, scrolls)"
            (Terminal_text.single_line (change_row_address change))
            removed added);
       let body_height = preview_height - 2 in
       for i = 0 to body_height - 1 do
         match List.nth_opt diff_rows i with
         | Some row ->
             box_line_span buf cols (diff_row_span ~width:(framed_inner_width cols) row)
         | None -> box_empty buf cols
       done
   | Some _ -> ());
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d changes, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"j/k:move  right/Enter:diff  [/]:keeper  d:tree diff  v:code  o:editor  r:refresh  q:quit");
  finish_surface state ~surface_key:"changes" ~rows:terminal_rows ~cols buf


(* What the tree holds for the file the cursor names. Separate from the
   tool-call reading by decision, not by accident: one says what the keeper
   tried to write and the other what survived, and a single view would make
   whichever it drew look like the whole answer. *)
let render_changes_tree_diff (state : state)
    (change : Masc.Tui_decode.file_change) =
  render_diff_surface state
    { ds_title = " MASC Tree"
    ; ds_address = Terminal_text.single_line (change_row_address change)
    ; ds_context_lines = []
    ; ds_diff = state.changes_tree_diff
    ; ds_error = state.changes_tree_diff_error
    ; ds_scroll = state.changes_diff_scroll
    ; ds_unchanged = "  (this file matches its last commit)"
    ; ds_esc_hint = "esc closes"
    ; ds_footer_hints = "j/k:scroll  left/esc:back  o:open in editor  q:quit"
    ; ds_surface_key = "changes"
    ; ds_clamped = (fun scroll -> Changes_diff_scroll scroll)
    }

(* The surface has two readings: the list, and one change opened. The open row
   is held as an index, so a refresh that shortens the list closes the diff
   rather than drawing a change the answer no longer holds. *)
let render_changes (state : state) =
  let opened =
    match (state.changes_diff_row, state.changes) with
    | Some row, Some snapshot ->
        List.nth_opt snapshot.Masc.Tui_decode.fcs_changes row
    | Some _, None | None, (Some _ | None) -> None
  in
  match opened with
  | Some change ->
      (* A path being read names the tree reading. Both readings of the same
         row exist at once; which one is drawn is the operator's last key, not
         whichever answer arrived last. *)
      if Option.is_some state.changes_tree_diff_path then
        render_changes_tree_diff state change
      else render_changes_diff state change
  | None -> render_changes_list state

(* Where the gate can deliver.

   Configured and reachable are separate columns because they call for
   different actions: one is a setup gap, the other is something that was
   working and is not. A connector that is set up but unreachable is the row
   an operator acts on. *)
let render_connectors (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let connectors =
    match state.connectors with
    | None -> []
    | Some s -> s.Masc.Tui_decode.cs_connectors
  in
  let shown = List.length connectors in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.connectors with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Connectors") timestamp
          (connection_badge state)
    | Some snapshot ->
        Printf.sprintf "%s (%d of %d available)  %s  %s"
          (screen_title " MASC Connectors")
          snapshot.Masc.Tui_decode.cs_active snapshot.Masc.Tui_decode.cs_total
          timestamp (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"connectors" ~title
    ~hints:"j/k:scroll  b:bind  u:unbind  Tab:next  q:quit  r:refresh"
    ~body:(fun ~budget c ->
      c.push_styled ~style:(Theme.recede ())
        (Printf.sprintf "  %-16s %-11s %-11s %-10s %s" "Connector"
           "Configured" "Reachable" "Status" "Channel");
      c.push_divider ();
      (match state.connectors_error with
       | None -> ()
       | Some detail ->
           c.push_styled ~style:(Theme.bad ())
             ("  " ^ Keeper_chat.terminal_safe_text detail);
           c.push_divider ());
      let fixed = 2 + (if Option.is_some state.connectors_error then 2 else 0) in
      let room = max 1 (budget - fixed) in
      let overflowing = shown > room in
      let content_height = if overflowing then max 1 (room - 1) else room in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min state.connectors_scroll max_scroll) in
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
          match List.nth_opt connectors idx with
          | None -> c.push_empty ()
          | Some connector ->
              let open Masc.Tui_decode in
              let yes_no flag = if flag then "yes" else "no" in
              let line =
                Printf.sprintf "  %-16s %-11s %-11s %-10s %s"
                  (Terminal_text.single_line connector.cn_display_name)
                  (yes_no connector.cn_available)
                  (yes_no connector.cn_connected)
                  (Terminal_text.single_line connector.cn_status)
                  (Terminal_text.single_line_or ~default:"-"
                     connector.cn_channel)
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
            (Printf.sprintf "[%d connectors, scroll %d]" shown scroll)
      end)

let runtime_refresh_badge refresh_state =
  let open Masc.Tui_decode in
  let label, style =
    match refresh_state with
    | Runtime_probe_fresh -> "fresh", (Theme.ok ())
    | Runtime_probe_recent -> "recent", (Theme.info ())
    | Runtime_probe_served_stale -> "stale", (Theme.warn ())
    | Runtime_probe_warming_up -> "warming", (Theme.warn ())
  in
  style ^ label ^ Ansi.reset

let runtime_overall_badge status =
  let open Masc.Tui_decode in
  let style =
    match status with
    | Runtime_probe_reachable -> (Theme.ok ())
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Ansi.dim
    | Runtime_probe_degraded -> (Theme.warn ())
    | Runtime_probe_unreachable -> (Theme.bad ())
  in
  style ^ runtime_probe_status_to_string status ^ Ansi.reset

let runtime_route_badge (runtime : Masc.Tui_decode.runtime_option) =
  if runtime.ro_dispatchable then (Theme.info ()) ^ "ready" ^ Ansi.reset
  else (Theme.bad ()) ^ "blocked" ^ Ansi.reset

let runtime_probe_badge = function
  | None -> Ansi.dim ^ "unobserved" ^ Ansi.reset
  | Some (probe : Masc.Tui_decode.runtime_provider_probe) ->
      let open Masc.Tui_decode in
      let style =
        match probe.rpp_status with
        | Runtime_provider_reachable -> (Theme.ok ())
        | Runtime_provider_skipped_cli -> Ansi.dim
        | Runtime_provider_missing_auth | Runtime_provider_auth_failed ->
            (Theme.warn ())
        | Runtime_provider_network_error
        | Runtime_provider_server_error
        | Runtime_provider_endpoint_not_found
        | Runtime_provider_http_error
        | Runtime_provider_unknown_http_status
        | Runtime_provider_invalid_endpoint
        | Runtime_provider_invalid_execution_transport -> (Theme.bad ())
      in
      let label =
        match probe.rpp_status with
        | Runtime_provider_skipped_cli -> "CLI not probed"
        | status -> runtime_provider_status_to_string status
      in
      style ^ label ^ Ansi.reset

let runtime_probe_detail = function
  | None -> []
  | Some (probe : Masc.Tui_decode.runtime_provider_probe) ->
      let latency =
        Option.map (fun value -> Printf.sprintf "%.0fms" value) probe.rpp_latency_ms
      in
      let http =
        Option.map (fun value -> Printf.sprintf "HTTP %d" value) probe.rpp_http_status
      in
      let error = Terminal_text.optional_single_line probe.rpp_error in
      let checked =
        Some ("checked " ^ Terminal_text.clock_timestamp probe.rpp_checked_at)
      in
      List.filter_map Fun.id [ latency; http; error; checked ]

let runtime_column_widths cols =
  if cols >= 140 then 18, 30, 30, 22
  else if cols >= 120 then 14, 24, 24, 22
  else 10, 20, 20, 22

let runtime_column width text =
  let clipped = fit_width text width in
  clipped
  ^ String.make
      (max 0 (width - Message_layout.display_width clipped))
      ' '

(* A column that holds names rather than prose. Lane and candidate ids share
   long prefixes -- glm-coding-…-a, glm-coding-…-b -- and at eighty columns
   the lane column is ten cells, so cutting from the end drew four different
   lanes as four identical "glm-codin~". The tail is what tells them apart,
   which is the same reason the Keepers table fits its names from the middle.

   Padded to the column afterwards, like {!runtime_column}, so the columns to
   the right do not move. *)
let runtime_name_column width text =
  let clipped = Message_layout.fit_middle width text in
  clipped
  ^ String.make
      (max 0 (width - Message_layout.display_width clipped))
      ' '

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

let runtime_detail_field ~width ~style label value =
  let prefix = "  " ^ label ^ ": " in
  let continuation = String.make (Message_layout.display_width prefix) ' ' in
  let lines =
    Message_layout.wrap_words
      ~max_cells:(max 1 (width - Message_layout.display_width prefix))
      (Terminal_text.single_line value)
  in
  match lines with
  | [] -> [ style, prefix ^ "—" ]
  | first :: rest ->
      (style, prefix ^ first)
      :: List.map (fun line -> style, continuation ^ line) rest

let runtime_bool = function true -> "yes" | false -> "no"

let runtime_detail_lines state target ~width =
  let open Masc.Tui_decode in
  let reading =
    match state.runtime_surface, target with
    | None, _ -> None
    | Some snapshot, Runtime_lane_candidate { lane_id; runtime_id } ->
        snapshot.rss_candidates
        |> List.find_opt (fun row ->
               String.equal row.rcr_lane_id lane_id
               && String.equal row.rcr_runtime.ro_id runtime_id)
        |> Option.map (fun row ->
               ( row.rcr_runtime
               , [ row.rcr_lane_id ]
               , Some (row.rcr_position, row.rcr_candidate_count)
               , row.rcr_preferred_at_ts
               , row.rcr_probe ))
    | Some snapshot, Runtime_catalog_entry { runtime_id } ->
        runtime_all_rows snapshot
        |> List.find_opt (fun (runtime, _) -> String.equal runtime.ro_id runtime_id)
        |> Option.map (fun (runtime, lanes) ->
               let probe =
                 Option.bind snapshot.rss_probe (fun probe_snapshot ->
                     List.find_opt
                       (fun row -> String.equal row.rpp_runtime_id runtime.ro_id)
                       probe_snapshot.rps_providers)
               in
               runtime, lanes, None, None, probe)
  in
  match reading with
  | None ->
      [ Theme.warn (),
        "  This runtime row is no longer present in the refreshed projection"
      ]
  | Some (runtime, lanes, position, preferred_at, probe) ->
      let fields =
        runtime_detail_field ~width ~style:Ansi.reset "Runtime ID" runtime.ro_id
        @ runtime_detail_field ~width ~style:Ansi.reset "Provider" runtime.ro_provider
        @ runtime_detail_field ~width ~style:Ansi.reset "Model" runtime.ro_model
        @ runtime_detail_field ~width ~style:Ansi.reset "Used by lanes"
            (match lanes with [] -> "unassigned" | values -> String.concat ", " values)
        @ runtime_detail_field ~width ~style:Ansi.reset "Dispatchable"
            (runtime_bool runtime.ro_dispatchable)
        @ runtime_detail_field ~width ~style:Ansi.reset "Default runtime"
            (runtime_bool runtime.ro_is_default)
      in
      let candidate =
        match position with
        | None -> []
        | Some (at, total) ->
            runtime_detail_field ~width ~style:Ansi.reset "Lane position"
              (Printf.sprintf "%d of %d" at total)
      in
      let blocker =
        match runtime.ro_blocked_reason with
        | None -> []
        | Some reason ->
            runtime_detail_field ~width ~style:(Theme.bad ()) "Blocked because" reason
      in
      let sticky =
        match preferred_at with
        | None -> []
        | Some at ->
            runtime_detail_field ~width ~style:Ansi.dim "Last successful at"
              (Masc_domain.iso8601_of_unix_seconds at)
      in
      let probe_lines =
        match probe with
        | None -> [ Ansi.dim, "  Probe: unobserved" ]
        | Some row ->
            let transport =
              match row.rpp_transport with
              | Runtime_probe_http -> "http"
              | Runtime_probe_cli -> "cli"
            in
            runtime_detail_field ~width ~style:Ansi.reset "Probe status"
              (runtime_provider_status_to_string row.rpp_status)
            @ runtime_detail_field ~width ~style:Ansi.reset "Probe transport" transport
            @ runtime_detail_field ~width ~style:Ansi.reset "Checked at" row.rpp_checked_at
            @ (match row.rpp_reachable with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "Reachable"
                     (runtime_bool value))
            @ (match row.rpp_http_status with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "HTTP status"
                     (string_of_int value))
            @ (match row.rpp_latency_ms with
               | None -> []
               | Some value ->
                   runtime_detail_field ~width ~style:Ansi.reset "Latency"
                     (Printf.sprintf "%.0fms" value))
            @ (match row.rpp_error with
               | None -> []
               | Some error ->
                   runtime_detail_field ~width ~style:(Theme.bad ()) "Probe error" error)
      in
      fields @ candidate @ blocker @ sticky @ probe_lines

let render_runtime_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let target_label =
    match target with
    | Runtime_lane_candidate { lane_id; runtime_id } -> lane_id ^ " / " ^ runtime_id
    | Runtime_catalog_entry { runtime_id } -> runtime_id
  in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s" (screen_title " MASC Runtime detail")
       (Terminal_text.single_line target_label) (connection_badge state));
  box_divider buf cols;
  let lines = runtime_detail_lines state target ~width:(max 1 (cols - 8)) in
  let content_height = max 1 (rows - 5) in
  let max_scroll = max 0 (List.length lines - content_height) in
  let scroll = max 0 (min state.runtime_detail_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (scroll + index) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:scroll  PgUp/PgDn:page  left/Esc:list  r:refresh  Tab:next");
  finish_surface state ~clamped:(Runtime_detail_scroll scroll)
    ~surface_key:"runtime-detail" ~rows:terminal_rows ~cols buf

(* Lane candidates come from /runtime/resolved; reachability comes from the
   cached runtime-probe document. Exact runtime-id joining happened in the
   decoder module, so drawing never parses ids or reconstructs a lane. *)
let render_runtime (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ( runtime_lane_width
      , runtime_candidate_width
      , runtime_identity_width
      , runtime_status_width ) =
    runtime_column_widths cols
  in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let candidates =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.rss_candidates
  in
  (* The roster the lane view cannot show: every runtime the workspace can
     call, with the lanes that name it. A runtime no lane names has an empty
     [lanes] and is exactly what an operator is looking for when they ask why
     a model they configured is nowhere on this screen. *)
  let all_runtimes =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> runtime_all_rows snapshot
  in
  let shown =
    match state.runtime_mode with
    | Masc_tui_types.Runtime_lanes -> List.length candidates
    | Masc_tui_types.Runtime_all -> List.length all_runtimes
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.runtime_surface with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Runtime") timestamp
          (connection_badge state)
    | Some snapshot ->
        let lane_count = List.length snapshot.rss_resolved.rrs_lanes in
        let probe_status =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> (Theme.warn ()) ^ "probe unavailable" ^ Ansi.reset
          | Some probe ->
              runtime_overall_badge probe.rps_status ^ " / "
              ^ runtime_refresh_badge probe.rps_refresh_state
        in
        let probe_read =
          if Option.is_some snapshot.rss_probe_error then
            (Theme.warn ()) ^ " / read failed" ^ Ansi.reset
          else ""
        in
        let tab ~active label =
          if active then
            (Theme.info ()) ^ Ansi.bold ^ "\xe2\x96\xb8" ^ label ^ Ansi.reset
          else Ansi.dim ^ label ^ Ansi.reset
        in
        let all_count =
          List.length snapshot.rss_resolved.Masc.Tui_decode.rrs_runtimes
        in
        let lanes_active = state.runtime_mode = Masc_tui_types.Runtime_lanes in
        Printf.sprintf "%s  %s  %s  %s%s  %s  %s"
          (screen_title " MASC Runtime")
          (tab ~active:lanes_active
             (Printf.sprintf "Lanes (%d lanes, %d slots)" lane_count shown))
          (tab ~active:(not lanes_active)
             (Printf.sprintf "All runtimes (%d)" all_count))
          probe_status probe_read timestamp (connection_badge state)
  in
  let authority_line =
    match state.runtime_surface with
    | None ->
        "  SSOT: runtime.toml  projections: /api/v1/runtime/resolved + runtime-probe"
    | Some snapshot ->
        let config =
          Terminal_text.single_line_or ~default:"config path unavailable"
            snapshot.rss_resolved.rrs_config_path
        in
        let summary_text =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> "probe unavailable"
          | Some probe ->
              let summary = probe.rps_summary in
              Printf.sprintf "%d reachable / %d failed / %d skipped"
                summary.rpsu_reachable summary.rpsu_failed summary.rpsu_skipped
        in
        let probe_note =
          match snapshot.rss_probe_error, snapshot.rss_probe with
          | Some detail, _ -> "  probe: " ^ Terminal_text.single_line detail
          | None, Some probe ->
              (match probe.rps_errors with
               | detail :: _ -> "  probe: " ^ Terminal_text.single_line detail
               | [] -> "")
          | None, None -> ""
        in
        let probe_only_note =
          match snapshot.rss_unassigned_probe_count with
          | 0 -> ""
          | count -> Printf.sprintf "  %d probe-only" count
        in
        Printf.sprintf
          "  SSOT: runtime.toml  projections: resolved + probe  %s  %s%s%s"
          summary_text config probe_only_note probe_note
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let authority_style =
    match state.runtime_surface with
    | Some snapshot when Option.is_some snapshot.rss_probe_error -> (Theme.warn ())
    | Some _ | None -> Ansi.dim
  in
  box_line_styled buf cols ~style:authority_style authority_line;
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  "
     ^ runtime_column runtime_lane_width
         (match state.runtime_mode with
          | Masc_tui_types.Runtime_lanes -> "LANE"
          | Masc_tui_types.Runtime_all -> "USED BY")
     ^ " "
     ^ runtime_column runtime_candidate_width
         (match state.runtime_mode with
          | Masc_tui_types.Runtime_lanes -> "CANDIDATE"
          | Masc_tui_types.Runtime_all -> "RUNTIME")
     ^ " "
     ^ runtime_column runtime_identity_width "PROVIDER / MODEL" ^ " "
     ^ runtime_column runtime_status_width "ROUTE / PROBE"
     ^ " DETAIL");
  box_divider buf cols;
  (match state.runtime_surface_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (match state.runtime_lane_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  lane write refused: " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (match state.runtime_lane_pick with
   | None -> ()
   | Some lane ->
       box_line_styled buf cols ~style:(Theme.info ())
         (Printf.sprintf
            "  adding a failover candidate to %s \xe2\x80\x94 j/k move, Enter append, e cancel"
            (Terminal_text.single_line lane));
       (* Three rows of the ranked list, not one: a picker that shows only the
          highlighted entry gives no reason to move, and the reason to move is
          that the next one is a different provider. *)
       let already =
         match state.runtime_surface with
         | None -> []
         | Some snapshot ->
             snapshot.Masc.Tui_decode.rss_resolved.Masc.Tui_decode.rrs_lanes
             |> List.find_opt (fun (l : Masc.Tui_decode.runtime_resolved_lane) ->
                  String.equal l.Masc.Tui_decode.rrl_id lane)
             |> (function
                  | Some l -> l.Masc.Tui_decode.rrl_runtime_ids
                  | None -> [])
       in
       let lane_providers =
         already
         |> List.filter_map (fun id ->
              List.find_opt
                (fun (r : Masc.Tui_decode.runtime_option) ->
                   String.equal r.Masc.Tui_decode.ro_id id)
                state.runtime_catalog
              |> Option.map (fun (r : Masc.Tui_decode.runtime_option) ->
                   r.Masc.Tui_decode.ro_provider))
       in
       let ranked =
         Masc_tui_types.runtimes_for_lane_picker ~lane_providers ~already
           state.runtime_catalog
       in
       if ranked = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           "  (runtime catalogue unread)"
       else
         List.iteri
           (fun offset (runtime : Masc.Tui_decode.runtime_option) ->
              let index = state.runtime_lane_pick_cursor + offset in
              match List.nth_opt ranked index with
              | None -> ()
              | Some _ ->
                  let note =
                    if List.exists
                         (String.equal runtime.Masc.Tui_decode.ro_id) already
                    then "  (already a candidate)"
                    else if not runtime.Masc.Tui_decode.ro_dispatchable then
                      "  (blocked)"
                    else if
                      List.exists
                        (String.equal runtime.Masc.Tui_decode.ro_provider)
                        lane_providers
                    then "  (same provider as a current candidate)"
                    else ""
                  in
                  box_line buf cols
                    (Printf.sprintf "  %s %s   %s / %s%s"
                       (if offset = 0 then ">" else " ")
                       (Terminal_text.single_line runtime.Masc.Tui_decode.ro_id)
                       (Terminal_text.single_line
                          runtime.Masc.Tui_decode.ro_provider)
                       (Terminal_text.single_line runtime.Masc.Tui_decode.ro_model)
                       (Ansi.dim ^ note ^ Ansi.reset)))
           (List.filteri
              (fun i _ ->
                 i >= state.runtime_lane_pick_cursor
                 && i < state.runtime_lane_pick_cursor + 3)
              ranked);
       box_divider buf cols);
  let chrome_rows = runtime_listing_chrome ~error:state.runtime_surface_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.runtime_surface_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.runtime_surface
          ~error:state.runtime_surface_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty ->
          (match state.runtime_mode with
           | Masc_tui_types.Runtime_lanes -> "  (no runtime lanes configured)"
           | Masc_tui_types.Runtime_all -> "  (no runtimes configured)")
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match state.runtime_mode with
      | Masc_tui_types.Runtime_all ->
          (match List.nth_opt all_runtimes (index + scroll) with
           | None -> box_empty buf cols
           | Some (runtime, lanes) ->
               let open Masc.Tui_decode in
               let used_by =
                 match lanes with
                 | [] -> (Theme.recede ()) ^ "unassigned" ^ Ansi.reset
                 | [ one ] -> one
                 | many -> Printf.sprintf "%d lanes" (List.length many)
               in
               let detail =
                 String.concat " \xc2\xb7 "
                   ((if runtime.ro_is_default then [ "default" ] else [])
                    @ (match
                         Terminal_text.optional_single_line runtime.ro_blocked_reason
                       with
                       | Some reason -> [ "blocked: " ^ reason ]
                       | None -> [])
                    @ (match lanes with [] -> [] | l -> [ String.concat ", " l ]))
               in
               let line =
                 "  " ^ runtime_column runtime_lane_width used_by ^ " "
                 ^ runtime_column runtime_candidate_width
                     (Terminal_text.single_line runtime.ro_id) ^ " "
                 ^ runtime_column runtime_identity_width
                     (Terminal_text.single_line
                        (runtime.ro_provider ^ " / " ^ runtime.ro_model)) ^ " "
                 ^ runtime_column runtime_status_width (runtime_route_badge runtime)
                 ^ " " ^ Ansi.dim ^ detail ^ Ansi.reset
               in
               if index + scroll = state.runtime_cursor then
                 box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
               else box_line buf cols line)
      | Masc_tui_types.Runtime_lanes ->
      match List.nth_opt candidates (index + scroll) with
      | None -> box_empty buf cols
      | Some candidate ->
          let open Masc.Tui_decode in
          let runtime = candidate.rcr_runtime in
          let candidate_label =
            Printf.sprintf "%d/%d %s" candidate.rcr_position
              candidate.rcr_candidate_count
              (Terminal_text.single_line runtime.ro_id)
          in
          let provider_model =
            Terminal_text.single_line
              (runtime.ro_provider ^ " / " ^ runtime.ro_model)
          in
          let route_probe =
            runtime_route_badge runtime ^ " / "
            ^ runtime_probe_badge candidate.rcr_probe
          in
          let route_detail =
            if runtime.ro_dispatchable then []
            else
              match Terminal_text.optional_single_line runtime.ro_blocked_reason with
              | Some reason -> [ "blocked: " ^ reason ]
              | None -> []
          in
          let lane_fact =
            match candidate.rcr_preferred_at_ts with
            | Some at ->
                [ "last success "
                  ^ Terminal_text.clock_timestamp
                      (Masc_domain.iso8601_of_unix_seconds at)
                ]
            | None when candidate.rcr_candidate_count = 1 -> [ "single candidate" ]
            | None -> []
          in
          let default_fact = if runtime.ro_is_default then [ "default" ] else [] in
          let detail =
            String.concat " \xc2\xb7 "
              (route_detail @ default_fact @ lane_fact
               @ runtime_probe_detail candidate.rcr_probe)
          in
          let line =
            "  "
            ^ runtime_name_column runtime_lane_width
                (Terminal_text.single_line candidate.rcr_lane_id)
            ^ " " ^ runtime_name_column runtime_candidate_width candidate_label
            ^ " " ^ runtime_column runtime_identity_width provider_model
            ^ " " ^ runtime_column runtime_status_width route_probe
            ^ " " ^ detail
          in
          if index + scroll = state.runtime_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  let scroll_hint =
    if shown > content_height then
      Printf.sprintf "[%d candidates, scroll %d]  " shown scroll
    else ""
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf
            "%sj/k:scroll  Enter:detail  p:%s  Tab:next  q:quit  r:live refresh"
            scroll_hint
            (match state.runtime_mode with
             | Masc_tui_types.Runtime_lanes -> "all runtimes"
             | Masc_tui_types.Runtime_all -> "service lanes")
          ^ (match state.runtime_mode with
             | Masc_tui_types.Runtime_lanes -> "  e:add failover"
             | Masc_tui_types.Runtime_all -> "")));
  finish_surface state ~surface_key:"runtime" ~rows:terminal_rows ~cols buf

let tools_scrolled_for_lines state display_lines =
  { sc_count = List.length display_lines
  ; sc_chrome = if Option.is_some state.tools_error then 7 else 5
  ; sc_overflow_takes_row = true
  ; sc_preview_keep = None
  }
;;

let tools_scrolled state =
  tools_scrolled_for_lines state (Render_tools.tools_display_lines state)
;;

let render_tools (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    (* The strip replaces the old subtitle. "effective Keeper + registered
       catalog" named two of the five sections and the header is where a
       reader looks for what a surface holds. *)
    Printf.sprintf "%s  %s  %s  %s"
      (screen_title " MASC Tools") (Render_tools.tools_pane_strip state) timestamp
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.tools_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let display_lines = Render_tools.tools_display_lines state in
  let layout = tools_scrolled_for_lines state display_lines in
  let drawable = layout.sc_count in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:drawable ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (drawable - content_height) in
  let scroll = max 0 (min state.tools_scroll max_scroll) in
  for i = 0 to content_height - 1 do
    match List.nth_opt display_lines (i + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  if drawable > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d rows, scroll %d]" drawable scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf

(** Dispatch a normal-height render based on the current surface. *)
(* One keeper's durable tool-call log, using the same row vocabulary as the
   chat pane: the finished glyph for a call that returned, the failure glyph
   for one that returned an error, and the exact fields recorded for it. The
   server's own freshness verdict rides the header - a stale page must not
   read as a quiet keeper. *)
let render_keeper_calls (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let keeper_name =
    match List.nth_opt state.keepers state.keeper_cursor with
    | Some keeper -> keeper.k_name
    | None -> "?"
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.keeper_calls with
    | Some snapshot when state.keeper_calls_loading ->
        Printf.sprintf
          " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls (%d)  refreshing...  %s  %s"
          (Terminal_text.single_line keeper_name)
          (List.length snapshot.Masc.Tui_decode.kcs_entries)
          timestamp (connection_badge state)
    | None when state.keeper_calls_loading ->
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls  (loading...)  %s  %s"
          (Terminal_text.single_line keeper_name)
          timestamp (connection_badge state)
    | None ->
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls  (not loaded yet)  %s  %s"
          (Terminal_text.single_line keeper_name)
          timestamp
          (connection_badge state)
    | Some snapshot ->
        (* The verdict says what is wrong with the log; the reason says why,
           and it is not always the verdict said twice. Four of the words
           this route can send come with a reason derived from themselves --
           "empty" arrives with "no_entries" -- but "coverage_gap" carries
           the gap record's own message, which nothing else on this header
           can supply.

           The "ok" arm that used to open this match built the same string
           the arm below it builds, so it decided nothing, and matched a
           health word by its spelling to do it. *)
        let freshness =
          let reason =
            match snapshot.Masc.Tui_decode.kcs_stale_reason with
            | None -> ""
            | Some reason -> " · " ^ Terminal_text.single_line reason
          in
          match
            (snapshot.Masc.Tui_decode.kcs_health,
             snapshot.Masc.Tui_decode.kcs_latest_age_s)
          with
          | health, Some age ->
            Printf.sprintf "%s · latest %.0fs ago%s" health age reason
          | health, None -> health ^ reason
        in
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls (%d)  %s  %s  %s"
          (Terminal_text.single_line keeper_name)
          (List.length snapshot.Masc.Tui_decode.kcs_entries)
          freshness timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line_styled buf cols ~style:Ansi.bold header;
  box_divider buf cols;
  let col_hdr =
    "  j/k rows · exact fields: tool | input | output"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.keeper_calls_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (match state.keeper_calls with
   | Some snapshot when snapshot.Masc.Tui_decode.kcs_mismatched > 0 ->
       box_line_styled buf cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d row(s) named another keeper and were not drawn"
            snapshot.Masc.Tui_decode.kcs_mismatched);
       box_divider buf cols
   | Some _ | None -> ());
  let entries =
    match state.keeper_calls with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.kcs_entries
  in
  let shown = List.length entries in
  (* The error row and the mismatch row are drawn above; counting the buffer
     asks what was drawn rather than restating the two conditions. *)
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  let content_height = max 1 (rows - chrome_rows) in
  (* The scroll unit is one rendered row, not one call. A canonical proposal
     identity plus its input and output cannot fit a two-row short viewport;
     compressing those fields into the two rows made the rightmost identity
     disappear permanently. Each exact field therefore owns rows that j/k can
     reach independently. *)
  let inner_cells = max 1 (framed_inner_width cols) in
  let labeled_rows ~call_index ~style ~label value =
    let prefix = Printf.sprintf "  #%d %s " (call_index + 1) label in
    let value = Terminal_text.single_line value in
    let value = if String.equal value "" then "(empty)" else value in
    let narrow_rows () =
      (* Drop decorative indentation before wrapping the exact header. The
         TUI requests at most 100 entries, so even [#100
         provenance] fits the 15-cell framed body of a 19-column terminal. *)
      let field_header =
        Printf.sprintf "#%d %s" (call_index + 1) label
      in
      let header_rows =
        Message_layout.split_cells ~max_cells:inner_cells field_header
        |> List.map (fun part -> call_index, style, part)
      in
      let value_rows =
        Message_layout.split_cells ~max_cells:inner_cells value
        |> List.map (fun part -> call_index, style, part)
      in
      List.concat_map
        (fun value_row -> header_rows @ [ value_row ] @ header_rows)
        value_rows
    in
    if Message_layout.display_width prefix < inner_cells then
      let body_cells = inner_cells - Message_layout.display_width prefix in
      let parts = Message_layout.split_cells ~max_cells:body_cells value in
      if
        List.for_all
          (fun part -> Message_layout.display_width part <= body_cells)
          parts
      then List.map (fun part -> call_index, style, prefix ^ part) parts
      else narrow_rows ()
    else
      (* On a narrow terminal the full field prefix may consume the framed
         width. Keeping it inline would make every value byte permanently
         unreachable after [box_line_styled] clips the row. Draw the exact
         call/field label on both sides of every value chunk so a two-row
         viewport never separates a continuation from its field context. *)
      narrow_rows ()
  in
  let rows =
    entries
    |> List.mapi (fun call_index (call : Masc.Tui_decode.keeper_call) ->
         let open Masc.Tui_decode in
         let glyph, style =
           if call.kc_success then ("✓", Ansi.reset)
           else ("✗", (Theme.bad ()))
         in
         let duration =
           match call.kc_duration_ms with
           | Some ms -> Masc_tui_acting.elapsed_text ms
           | None -> "-"
         in
         let turn =
           match call.kc_turn with Some value -> string_of_int value | None -> "-"
         in
         let summary =
           Printf.sprintf "  #%d %s %s · %s · turn %s"
             (call_index + 1)
             (Terminal_text.clock_timestamp
                (Masc_domain.iso8601_of_unix_seconds call.kc_at))
             glyph duration turn
         in
         let exact_rows =
           labeled_rows ~call_index ~style:Ansi.dim ~label:"tool" call.kc_tool
           @ labeled_rows ~call_index ~style:Ansi.dim ~label:"input" call.kc_input
         in
         let output_rows =
           match
             Option.bind call.kc_output (fun result ->
               Masc.Keeper_chat_tool_trail.tool_result_digest ~result)
           with
           | None -> []
           | Some digest ->
             labeled_rows ~call_index
               ~style:(if call.kc_success then Ansi.dim else (Theme.bad ()))
               ~label:"output" digest
         in
         (call_index, style, summary) :: exact_rows @ output_rows)
    |> List.concat
  in
  let total_rows = List.length rows in
  let max_scroll = max 0 (total_rows - content_height) in
  let scroll = max 0 (min state.keeper_calls_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      if state.keeper_calls_loading && Option.is_none state.keeper_calls then
        "  (loading exact call records...)"
      else
      match (state.keeper_calls, state.keeper_calls_error) with
      | _, Some _ -> page_failed_note
      | None, None -> page_unread_note
      | Some _, None -> "  (no calls recorded)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else begin
    let visible_rows =
      rows
      |> List.filteri (fun index _ ->
           index >= scroll && index < scroll + content_height)
    in
    List.iter
      (fun (_, style, text) -> box_line_styled buf cols ~style text)
      visible_rows;
    for _ = List.length visible_rows + 1 to content_height do
      box_empty buf cols
    done
  end;
  if scroll > 0 || total_rows > content_height then
    let last_visible = min total_rows (scroll + content_height) in
    let detailed_footer =
      Printf.sprintf "[%d calls · rows %d-%d of %d]" shown (scroll + 1)
        last_visible total_rows
    in
    let compact_footer =
      Printf.sprintf "[%d/%d]" (scroll + 1) total_rows
    in
    let footer =
      if Message_layout.display_width detailed_footer <= framed_inner_width cols
      then detailed_footer
      else compact_footer
    in
    box_line_styled buf cols ~style:(Theme.recede ())
      footer
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~clamped:(Keeper_calls scroll) ~surface_key:"keeper-calls" ~rows:terminal_rows ~cols buf

(* The runtime's event feed, newest first, for watching every keeper act at
   once. Rows are built from the events the TUI holds; the filter decides
   which kinds draw; a completed call is paired with its start for a
   duration. Scrolling away from the newest row freezes the view and counts
   what arrives above it, so an operator reading the past is not pushed off
   it by the present. *)
let render_acting (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let module Acting = Masc_tui_acting in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let held = List.length state.acting in
  (* The agent_core family names its runtime lane, not the keeper; the
     keeper is the one whose trace the event's correlation id carries. *)
  let traces =
    List.map (fun keeper -> (keeper.k_name, keeper.k_trace_id)) state.keepers
  in
  (* Visible entries, newest first, paired with the events older than each
     -- in a newest-first list, the tail after it -- so a completed call on
     the page can look up its start. Rows are built only for the page: the
     pairing walks the older events, and doing it for a thousand held
     entries on every frame is work the screen never shows. *)
  let visible =
    let rec walk acc = function
      | [] -> List.rev acc
      | entry :: older ->
          if Acting.visible state.acting_filter entry.Acting.ae_event then
            walk ((entry, older) :: acc) older
          else walk acc older
    in
    walk [] state.acting
  in
  let row_of (entry, older) =
    let event = entry.Acting.ae_event in
    let duration_ms =
      match event with
      | Masc_tui_observer.Agent_core
          ({ Masc_tui_observer.kind = Masc_tui_observer.Tool_completed; _ } as
           completed) ->
          Acting.duration_of_completion
            ~before:(List.map (fun e -> e.Acting.ae_event) older)
            completed
      | Masc_tui_observer.Agent_core _ | Masc_tui_observer.Keeper_heartbeat _
      | Masc_tui_observer.Keeper_tool_call _
      | Masc_tui_observer.Keeper_turn_complete _
      | Masc_tui_observer.Keeper_composite_changed _
      | Masc_tui_observer.Keeper_chat_appended _
      | Masc_tui_observer.Keeper_chat_stream_frame _
      | Masc_tui_observer.Keeper_waiting_inventory_changed _
      | Masc_tui_observer.Fusion_run_status _
      | Masc_tui_observer.Snapshot _
      | Masc_tui_observer.Other _ ->
          None
    in
    let row = Acting.row_of_entry ~duration_ms entry in
    { row with Acting.keeper = Acting.keeper_of_event ~traces event }
  in
  (* [Turns] folds the whole ring into per-turn rows; the flat filters keep
     the page-lazy pairing above. *)
  let chunked =
    match state.acting_filter with
    | Acting.Turns -> Some (Acting.chunk_rows ~traces state.acting)
    | Acting.Actions | Acting.Everything -> None
  in
  let shown =
    match chunked with
    | Some rows -> List.length rows
    | None -> List.length visible
  in
  let row_at idx =
    match chunked with
    | Some rows -> List.nth_opt rows idx
    | None -> Option.map row_of (List.nth_opt visible idx)
  in
  let feed =
    match state.observer with
    | Observer_off -> "feed: off"
    | Observer_opening -> "feed: opening"
    | Observer_live { events; _ } -> Printf.sprintf "feed: live %d" events
    | Observer_closed { events; reason; _ } ->
        Printf.sprintf "feed: closed after %d (%s)" events
          (Terminal_text.single_line reason)
  in
  let header =
    Printf.sprintf "%s  %s  %s"
      (screen_title
         (Printf.sprintf " MASC Activity (%d of %d held, %s)" shown held
            (Acting.filter_label state.acting_filter)))
      timestamp
      (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let dropped =
    if state.acting_dropped = 0 then ""
    else Printf.sprintf "  dropped %d" state.acting_dropped
  in
  let undecodable =
    match state.acting_undecodable_last with
    | None -> ""
    | Some reason ->
        Printf.sprintf "  undecodable %d (last: %s)" state.acting_undecodable
          (Terminal_text.single_line reason)
  in
  let unseen =
    if state.acting_unseen = 0 then ""
    else Printf.sprintf "  %d new above (g)" state.acting_unseen
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  %s%s%s%s" feed dropped undecodable unseen);
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Acting.filter_explanation state.acting_filter);
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %-16s %s %-16s %s" "Time" "Keeper" " " "Event"
      "Detail"
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.acting_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match state.observer with
      | Observer_off | Observer_opening -> "  (no events yet: the feed is not open)"
      | Observer_live _ ->
          if held = 0 then "  (no events yet)"
          else "  (nothing under this filter; f shows everything)"
      | Observer_closed _ ->
          if held = 0 then "  (the feed closed before any event arrived)"
          else "  (nothing under this filter; f shows everything)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match row_at idx with
      | None -> box_empty buf cols
      | Some row ->
          let style =
            match row.Acting.glyph with
            | Acting.Call_started -> (Theme.info ())
            | Acting.Call_returned -> (Theme.ok ())
            | Acting.Turn_boundary -> Ansi.reset
            | Acting.Turn_settled -> Ansi.bold
            | Acting.Failure -> (Theme.bad ())
            | Acting.Attention -> (Theme.warn ())
            | Acting.Quiet -> Ansi.dim
          in
          (* Every row carries the moment the TUI received it, so there is no
             longer a clockless row to draw a blank for. *)
          let clock =
            Terminal_text.clock_timestamp
              (Masc_domain.iso8601_of_unix_seconds row.Acting.at)
          in
          (* The Event column is sized for the two-word labels the taught
             events carry ("agent start", "waiting queue"). A type this build
             was not taught has no such label -- its name is all there is, and
             it is a wire identifier, so it ran off the column at every width:
             [approval:summar~], [transport_healt~]. Those rows have no detail
             either, so the label takes the empty column rather than the
             reader losing the only thing the row says. *)
          let detail = Terminal_text.single_line row.Acting.detail in
          let label = Terminal_text.single_line row.Acting.label in
          let line =
            if detail = "" then
              Printf.sprintf "  %-8s %-16s %s %s" clock
                (fit_width (Terminal_text.single_line row.Acting.keeper) 16)
                (Acting.glyph_text row.Acting.glyph)
                label
            else
              Printf.sprintf "  %-8s %-16s %s %-16s %s" clock
                (fit_width (Terminal_text.single_line row.Acting.keeper) 16)
                (Acting.glyph_text row.Acting.glyph)
                (fit_width label 16) detail
          in
          box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "[%d rows, scroll %d]" shown scroll)
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:scroll  g:newest  G:oldest  f:turns/actions/everything  Tab:next  q:quit");
  finish_surface state ~clamped:(Acting scroll) ~surface_key:"acting" ~rows:terminal_rows ~cols buf

let render_metrics (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec
  in
  let sec_label = Masc_tui_types.metrics_section_label state.metrics_section in
  let title =
    Printf.sprintf "%s  [%s]  %s  %s"
      (screen_title " MASC Metrics & Performance Telemetry")
      sec_label timestamp (connection_badge state)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"metrics"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      Render_metrics.render_metrics_body ~cols ~budget state
        ~push:c.push ~push_styled:c.push_styled ~push_selected:c.push_selected
        ~push_divider:c.push_divider ~push_empty:c.push_empty)

(** Render the runtime picker: the dispatchable catalogue, with the keeper it
    is choosing for and where that keeper points today in the header. *)
let render_runtime_pick (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let keeper_name =
    Terminal_text.single_line_or ~default:"?" state.runtime_pick_keeper
  in
  let current =
    match
      List.find_opt
        (fun (a : Tui_decode.runtime_assignment) ->
          match state.runtime_pick_keeper with
          | Some keeper -> String.equal a.ra_keeper keeper
          | None -> false)
        state.runtime_assignments
    with
    | Some a ->
        Printf.sprintf "%s (%s)"
          (Terminal_text.single_line_or ~default:"-" a.ra_target_id)
          (Terminal_text.single_line a.ra_source)
    | None -> "-"
  in
  (* Only what a keeper can actually be pointed at. The catalogue also lists
     rows the dispatcher refuses; offering one would end in the server's
     rejection, so the picker does not draw them. *)
  let options =
    List.filter
      (fun (o : Tui_decode.runtime_option) -> o.ro_dispatchable)
      state.runtime_catalog
  in
  let count = List.length options in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %scurrent: %s%s"
       (screen_title
         (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 runtime" keeper_name))
       Ansi.dim current Ansi.reset);
  box_divider buf cols;
  (match Terminal_text.optional_single_line state.runtime_catalog_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ()) ^ "  (catalogue unreliable: "
         ^ fit_width err (max 8 (cols - 28))
         ^ ")" ^ Ansi.reset)
   | None ->
       if count = 0 then
         box_line buf cols
           (Ansi.dim ^ "  (loading runtime catalogue\xe2\x80\xa6)" ^ Ansi.reset));
  let content_height = max 0 (rows - 7) in
  let scroll_offset =
    if content_height > 0 && state.runtime_pick_cursor >= content_height then
      state.runtime_pick_cursor - content_height + 1
    else 0
  in
  for i = 0 to content_height - 1 do
    let idx = i + scroll_offset in
    match List.nth_opt options idx with
    | Some option ->
        let is_selected = idx = state.runtime_pick_cursor in
        let line =
          Printf.sprintf "  %s  %s%s"
            (fit_width (Terminal_text.single_line option.ro_id) 44)
            (fit_width
               (Terminal_text.single_line
                  (option.ro_provider ^ " / " ^ option.ro_model))
               (max 8 (cols - 56)))
            (if option.ro_is_default then " [default]" else "")
        in
        box_line buf cols
          (if is_selected then Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
           else "  " ^ line)
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf "%sj/k%s move  %senter%s assign  %sd%s back to default  esc cancel"
            (Masc_tui_theme.tone Masc_tui_theme.Accent) Ansi.reset (Masc_tui_theme.tone Masc_tui_theme.Accent) Ansi.reset (Masc_tui_theme.tone Masc_tui_theme.Accent) Ansi.reset));
  finish_surface state ~surface_key:"runtime-pick" ~rows:terminal_rows ~cols
    buf

(* The Resources surface: the MCP resource inventory on the left, the
   selected read on the right. Wide terminals show both; narrow ones show
   the list, and Enter swaps to the content until Esc. *)

(* The Code surface: one directory level on the left, the opened file on the
   right. Entries come from the lazy /workspace/children route; the file is
   lexed once at load (masc_tui_code_lexer) and drawn as styled spans.
   fit_width measures cells past the SGR bytes and closes a cut style, so a
   long row truncates without bleeding colour into the margin. *)
(* The file pane's usable rows: top gap, title, divider, bottom gap, and
   the footer. One owner — the dispatch keeps the cursor visible against the
   same number the renderer draws with. *)
let code_pane_content_height (state : state) =
  let terminal_rows, _ = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  framed_content_height ~rows

let render_code (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  let list_rows_budget = framed_content_height ~rows in
  let entries = state.code_entries in
  let total = List.length entries in
  let cursor = max 0 (min state.code_cursor (total - 1)) in
  let span = lexed_span in
  let list_pane ~framed pane_buf pane_cols =
    (* Beside the file pane the box is the pane separator; alone on a narrow
       terminal it is the redundant outer frame every other surface dropped
       (same rule as keeper_detail_pane). *)
    let framed_top = if framed then framed_top else box_top in
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
    let status_rows =
      match state.code_entries_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          1
      | None ->
          if total = 0 then begin
            framed_line pane_buf pane_cols
              (Ansi.dim ^ " (loading\xe2\x80\xa6)" ^ Ansi.reset);
            1
          end
          else 0
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    for i = 0 to list_rows_budget - 1 do
      match List.nth_opt entries (first + i) with
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
              if selected then "\xe2\x96\xb8 "
              else (Theme.category Theme.Slot_1) ^ "\xe2\x96\xb8 " ^ Ansi.reset
            else
              let kind =
                File_icon.kind_of_name node.Masc.Tui_decode.wt_label
              in
              let glyph = File_icon.glyph kind in
              if selected then glyph ^ " "
              else
                let colour =
                  (* Six kinds, six categorical slots (RFC-0427). These were
                     constant SGR codes, so a file list was one of the places
                     a theme could not reach: everything around it moved when
                     the terminal answered with its palette and these did not.

                     Six kinds and five slots, so Script and Media share
                     one. They did before too -- magenta and bright magenta,
                     a hue apart -- and the honest form of that is the same
                     hue with two marks rather than two hues a reader cannot
                     separate. Media had red for one commit, which is [bad]
                     to the byte: a .png in the listing drew the same escape
                     as the blame failure on its own half of the row.

                     Plain recedes through the theme rather than a constant
                     [dim], for the same reason the six above it do. *)
                  match kind with
                  | File_icon.Code -> Theme.category Theme.Slot_1
                  | File_icon.Data -> Theme.category Theme.Slot_2
                  | File_icon.Prose -> Theme.category Theme.Slot_3
                  | File_icon.Script | File_icon.Media ->
                    Theme.category Theme.Slot_4
                  | File_icon.Web -> Theme.category Theme.Slot_5
                  | File_icon.Plain -> Theme.recede ()
                in
                colour ^ glyph ^ Ansi.reset ^ " "
          in
          let line =
            if selected then
              Theme.selection ^ " " ^ marker ^ name
              ^ String.make
                  (max 0
                     (pane_cols - 7
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
  let content_pane pane_buf pane_cols =
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
              Printf.sprintf "%s  (col %d)" path
                (state.code_file_hscroll + 1)
            else path
          in
          let base =
            if notes_showing then "notes: " ^ path
            else if diff_showing then "diff vs HEAD: " ^ path
            else if history_showing then "history: " ^ path
            else path
          in
          (* The note (a language-server answer, a PR link) rides the title
             in every view: the history's Enter writes one too. *)
          let with_note =
            match state.code_lsp_note with
            | Some note ->
                base ^ "  " ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                ^ Terminal_text.single_line note ^ Ansi.reset
            | None -> base
          in
          (* A blame that did not come back has no pane of its own to say so
             in -- the margin is beside the code, not instead of it -- so the
             refusal rides the title the way a language-server answer does.
             In the bad tone rather than the accent: this one is a failure. *)
          (* The margin has no pane of its own to speak in, so both the
             refusal and the wait ride the title. *)
          (match Masc_tui_fetched.current state.code_blame with
           | Some (_, Masc_tui_fetched.Failed detail) ->
               with_note ^ "  " ^ Theme.bad () ^ "blame: "
               ^ Terminal_text.single_line detail ^ Ansi.reset
           | Some (_, Masc_tui_fetched.Loading) ->
               with_note ^ "  " ^ Theme.recede () ^ "blame 읽는 중…" ^ Ansi.reset
           | Some (_, (Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent))
           | None -> with_note)
      | None -> "(Enter opens the selected file)"
    in
    box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.code_focus_file = Right_pane then Ansi.bold else Ansi.dim)
       ^ " " ^ title
       ^ (if state.code_focus_file = Right_pane then "  [j/k]" else "")
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = code_pane_content_height state in
    (if notes_showing then
       (* The memos are the file's own comments, so the overlay lists what
          the lexed rows hold and has no reading state of its own. *)
       let memos =
         match Masc_tui_fetched.current state.code_file with
         | Some (_, Masc_tui_fetched.Ready rows) -> Masc_tui_memo.of_rows rows
         | Some
             ( _
             , ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
               | Masc_tui_fetched.Failed _ ) )
         | None -> []
       in
       match memos with
       | [] ->
           box_line pane_buf pane_cols
             (Ansi.dim
             ^ "  (no memo in this file: a comment on its own row reading \
                masc(name): text)"
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | _ :: _ ->
           let total = List.length memos in
           let max_scroll = max 0 (total - content_height) in
           let scroll = max 0 (min state.code_notes_scroll max_scroll) in
           for i = 0 to content_height - 1 do
             match List.nth_opt memos (scroll + i) with
             | Some (Masc_tui_memo.Memo_at (line, memo)) ->
                 let kind =
                   match Ide_memo.kind_word memo.Ide_memo.kind with
                   | None -> ""
                   | Some word -> " (" ^ word ^ ")"
                 in
                 box_line pane_buf pane_cols
                   (Printf.sprintf "  %s%-6s%s %s%s%s%s  %s" Ansi.dim
                      (Printf.sprintf "L%d" line)
                      Ansi.reset
                      (Masc_tui_theme.tone Masc_tui_theme.Accent)
                      (Terminal_text.single_line memo.Ide_memo.author)
                      kind Ansi.reset
                      (Terminal_text.single_line memo.Ide_memo.text))
             | Some (Masc_tui_memo.Broken_at (line, why)) ->
                 box_line pane_buf pane_cols
                   (Printf.sprintf "  %s%-6s%s %smemo unreadable: %s%s" Ansi.dim
                      (Printf.sprintf "L%d" line)
                      Ansi.reset (Theme.bad ())
                      (Terminal_text.single_line why)
                      Ansi.reset)
             | None -> box_empty pane_buf pane_cols
           done
     else if diff_showing then
       match Masc_tui_fetched.current state.code_diff with
       | Some (_, Masc_tui_fetched.Failed detail) ->
           box_line pane_buf pane_cols
             ((Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Loading) ->
           box_line pane_buf pane_cols
             (Ansi.dim ^ "  (reading the tree)" ^ Ansi.reset);
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
                 ^ (if diff.Masc.Tui_decode.gd_has_changes then
                      "  (the tree reports a change and sent no lines)"
                    else "  (this file matches its last commit)")
                 ^ Ansi.reset);
               for _ = 2 to content_height do
                 box_empty pane_buf pane_cols
               done
           | rows ->
               let total = List.length rows in
               let max_scroll = max 0 (total - content_height) in
               let scroll =
                 max 0 (min state.code_diff_scroll max_scroll)
               in
               (* An add or context row is the working tree's own line, so
                  the lexed row the pane already holds is its exact
                  colouring -- resolved by the row's new-line number, not by
                  matching text. A delete row is the old blob's content,
                  which was never lexed; it keeps the plain red band. Each
                  lexed segment's reset is followed by re-opening the diff
                  background, so the band survives the lexer's own resets. *)
               let lexed_line index =
                 match Masc_tui_fetched.current state.code_file with
                 | Some (_, Masc_tui_fetched.Ready file_rows) ->
                   List.nth_opt file_rows (index - 1)
                 | Some (_, _) | None -> None
               in
               for i = 0 to content_height - 1 do
                 match List.nth_opt rows (scroll + i) with
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
                     let lexed =
                       match row.gdr_kind, row.gdr_new_line with
                       | (Gd_added | Gd_context), Some line ->
                           lexed_line line
                       | _ -> None
                     in
                     let body =
                       match lexed with
                       | Some segments -> (
                           match row.gdr_kind with
                           | Gd_added ->
                               let bg = Theme.Syntax.diff_added_bg in
                               bg
                               ^ String.concat ""
                                   (List.map
                                      (fun segment ->
                                        span segment ^ bg)
                                      segments)
                               ^ Ansi.reset
                           | Gd_context | Gd_removed ->
                               String.concat "" (List.map span segments))
                       | None -> (
                           let text =
                             Terminal_text.single_line row.gdr_text
                           in
                           match row.gdr_kind with
                           | Gd_removed ->
                               Theme.Syntax.diff_removed_bg ^ text
                               ^ Ansi.reset
                           | Gd_added ->
                               Theme.Syntax.diff_added_bg ^ text ^ Ansi.reset
                           | Gd_context -> Ansi.dim ^ text ^ Ansi.reset)
                     in
                     box_line pane_buf pane_cols
                       (Ansi.dim ^ gutter ^ Ansi.reset ^ body)
                 | None -> box_empty pane_buf pane_cols
               done)
     else if history_showing then
       (* "(loading history)" used to be what an unasked overlay said as well
          as a reading one. Now it is only the reading one. *)
       match Masc_tui_fetched.current state.code_history with
       | Some (_, Masc_tui_fetched.Failed detail) ->
           box_line pane_buf pane_cols
             ((Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
             ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Loading) ->
           box_line pane_buf pane_cols
             (Ansi.dim ^ "  (loading history)" ^ Ansi.reset);
           for _ = 2 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready { chl_entries = []; chl_activity_note }) ->
           box_line pane_buf pane_cols
             (Ansi.dim
              ^ "  (no commit or exact Keeper change touches this file)"
              ^ Ansi.reset);
           box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
             ("  " ^ Terminal_text.single_line chl_activity_note);
           for _ = 3 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready { chl_entries; chl_activity_note }) ->
           box_line_styled pane_buf pane_cols ~style:(Theme.recede ())
             ("  " ^ Terminal_text.single_line chl_activity_note);
           let list_height = max 1 (content_height - 1) in
           let total = List.length chl_entries in
           let max_scroll = max 0 (total - list_height) in
           let scroll = max 0 (min state.code_history_scroll max_scroll) in
           let at_of ms =
             let t = Unix.localtime (ms /. 1000.) in
             Printf.sprintf "%02d-%02d %02d:%02d" (t.Unix.tm_mon + 1)
               t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
           in
           for i = 0 to list_height - 1 do
             match List.nth_opt chl_entries (scroll + i) with
             | Some (Hist_keeper_change change) ->
                 let open Masc.Tui_decode in
                 (* File-change rows carry Unix seconds; git history carries
                    epoch milliseconds. [at_of] takes the latter because the
                    two kinds are sorted in that unit too. *)
                 let at = at_of (change.fc_at *. 1000.) in
                 let anchor =
                   Option.value ~default:"L?"
                     (file_change_evidence_label change.fc_line_evidence)
                 in
                 let kind =
                   match change.fc_kind with
                   | Fc_edited _ -> "EDIT"
                   | Fc_inserted _ -> "MEMO"
                   | Fc_written _ -> "WRITE"
                 in
                 let result_style, result =
                   if change.fc_succeeded
                   then Theme.ok (), "✓"
                   else Theme.bad (), "✗"
                 in
                 let provenance =
                   [ Option.map (fun task -> "task " ^ task) change.fc_task_id
                   ; Option.map
                       (fun turn -> Printf.sprintf "turn %d" turn)
                       change.fc_turn
                   ; Option.map (fun id -> "exec " ^ id) change.fc_execution_id
                   ]
                   |> List.filter_map Fun.id
                   |> String.concat " · "
                 in
                 box_line pane_buf pane_cols
                   (Printf.sprintf
                      "  %s%s%s  %s%s%s  %s%s%s %-5s  %s%s%s  %s"
                      Ansi.dim at Ansi.reset Ansi.dim (fit_width anchor 12)
                      Ansi.reset result_style result Ansi.reset kind (Masc_tui_theme.tone Masc_tui_theme.Accent)
                      (Terminal_text.single_line change.fc_keeper)
                      Ansi.reset
                      (Terminal_text.single_line provenance))
             | Some (Hist_commit row) ->
                 let open Masc.Tui_decode in
                 box_line pane_buf pane_cols
                   (Printf.sprintf "  %s%s%s  %s%s%s  %s  %s" Ansi.dim
                      (at_of row.gl_at_ms) Ansi.reset
                      (Masc_tui_theme.tone Masc_tui_theme.Accent)
                      row.gl_hash Ansi.reset
                      (Terminal_text.single_line row.gl_author)
                      (Terminal_text.single_line row.gl_subject))
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
       | Some (_, Masc_tui_fetched.Failed detail) -> say (Theme.bad ()) detail
       | Some (path, Masc_tui_fetched.Loading) ->
           say (Theme.recede ()) (path ^ " 읽는 중…")
       | Some (_, Masc_tui_fetched.Absent) | None ->
           for _ = 1 to content_height do
             box_empty pane_buf pane_cols
           done
       | Some (_, Masc_tui_fetched.Ready file_rows) ->
           let total_lines = List.length file_rows in
           let max_scroll = max 0 (total_lines - content_height) in
           let scroll = max 0 (min state.code_file_scroll max_scroll) in
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
               (Masc_tui_memo.of_rows file_rows)
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
             | _ -> []
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
             | Some _ | None -> []
           in
           let blame_now_s = Unix.gettimeofday () in
           (* One name per run, not one per line: the run boundary is the fact
              worth drawing, and repeating the author down every line of a
              block is what hides it. Continuation rows hold the same cells in
              blanks so the code stays in one column.

              No colour of its own. The theme's three tones are Normal, Dim
              and the single accent, and a colour outside them is a claim
              about state -- blame carries no state, only who and when. So
              the answer (the name) draws Normal and the qualifier (the age)
              draws Dim, and nothing here competes with the lexer's own
              colours in the code beside it. *)
           let blame_cell line =
             match blame_blocks with
             | [] -> ""
             | _ -> (
               match Masc.Tui_decode.blame_block_at blame_blocks line with
               | Some (block, true) ->
                   Printf.sprintf "%s%s %s%s%s "
                     (Masc_tui_theme.tone Masc_tui_theme.Normal)
                     (Message_layout.fit_width block.bb_author
                        blame_author_cells)
                     Ansi.dim
                     (Message_layout.fit_width
                        (blame_age_text ~now_s:blame_now_s block.bb_at_ms)
                        blame_age_cells)
                     Ansi.reset
               | Some (_, false) | None -> String.make blame_margin_cells ' ')
           in
           for i = 0 to content_height - 1 do
             match List.nth_opt file_rows (scroll + i) with
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
                     (Masc_tui_theme.tone Masc_tui_theme.Accent)
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
    box_bottom pane_buf pane_cols
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane ~framed:true left_buf left_cols;
     content_pane right_buf right_cols;
     write_two_panes buf ~left_cols:left_cols ~left:left_buf
       ~right:right_buf
   end
   else if state.code_focus_file = Right_pane then content_pane buf cols
   else list_pane ~framed:false buf cols);
  let code_pane =
    if state.code_focus_file <> Right_pane then Masc_tui_keys.Code_tree
    else if
      state.code_history_open || state.code_diff_open || state.code_notes_open
    then Masc_tui_keys.Code_overlay
    else Masc_tui_keys.Code_file
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_code ~pane:code_pane));
  finish_surface state ~surface_key:"code" ~rows:terminal_rows ~cols buf

let resource_display_name (resource : Masc_tui_mcp.resource) =
  match resource.title with
  | Some title when String.trim title <> "" -> title
  | Some _ | None -> resource.name

let resource_mime_essence mime =
  match String.split_on_char ';' (String.lowercase_ascii (String.trim mime)) with
  | essence :: _ -> String.trim essence
  | [] -> ""

let resource_language_of_mime mime =
  let mime = resource_mime_essence mime in
  if
    String.equal mime "application/json"
    || String.equal mime "text/json"
    || String.ends_with ~suffix:"+json" mime
  then Some "json"
  else if List.mem mime [ "application/toml"; "text/toml"; "text/x-toml" ]
  then Some "toml"
  else if
    List.mem mime
      [ "application/yaml"; "application/x-yaml"; "text/yaml"; "text/x-yaml" ]
  then Some "yaml"
  else None

let resource_mime_is_markdown mime =
  List.mem (resource_mime_essence mime)
    [ "text/markdown"; "text/x-markdown"; "application/markdown" ]

let pretty_resource_text ~mime text =
  match resource_language_of_mime mime with
  | Some "json" -> fenced_pretty_json text
  | Some language -> fenced_document_text ~language text
  | None when resource_mime_is_markdown mime -> text
  | None -> text

let resource_document (resource : Masc_tui_mcp.resource)
    (contents : Masc_tui_mcp.resource_content list option) ~error ~requested =
  let present = function
    | Some text when String.trim text <> "" -> text
    | Some _ | None -> "not supplied"
  in
  let size =
    match resource.size with
    | Some bytes -> Printf.sprintf "%d bytes" bytes
    | None -> "size unknown"
  in
  let mime = present resource.mime_type in
  let metadata =
    String.concat "\n\n"
      [ "MCP resource — read-only data exposed by this server."
      ; "**About:** " ^ present resource.description
      ; "**URI:** `" ^ resource.uri ^ "`"
      ; "**Name:** " ^ resource.name
      ; "**Type:** `" ^ mime ^ "` · **Size:** " ^ size
      ]
  in
  let part_document index (part : Masc_tui_mcp.resource_content) =
    let part_mime = Option.value part.rc_mime_type ~default:mime in
    let body =
      match part.rc_kind with
      | Masc_tui_mcp.Resource_text text ->
          pretty_resource_text ~mime:part_mime text
      | Masc_tui_mcp.Resource_blob { base64_bytes } ->
          Printf.sprintf
            "Binary data · `%s` · %d base64 bytes · preview unavailable"
            part_mime base64_bytes
    in
    match contents with
    | Some (_ :: _ :: _) ->
        Printf.sprintf "### Part %d · %s\n\n%s" index part_mime body
    | Some (_ :: []) | Some [] | None -> body
  in
  let body =
    match (error, contents) with
    | Some detail, _ -> "**Read failed:** " ^ detail
    | None, None when requested -> "(reading resource…)"
    | None, None -> "(Enter reads the selected resource.)"
    | None, Some parts ->
        parts |> List.mapi (fun index part -> part_document (index + 1) part)
        |> String.concat "\n\n"
  in
  metadata ^ "\n\n---\n\n" ^ body

let render_resources (state : state) =
  let drawn_resource_scroll = ref state.resource_scroll in
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  let list_rows_budget = framed_content_height ~rows in
  let rows_list =
    match state.resources_list with Some rows -> rows | None -> []
  in
  let total = List.length rows_list in
  let cursor = max 0 (min state.resources_cursor (total - 1)) in
  let list_pane ~framed pane_buf pane_cols =
    (* Same rule as the code surface: beside the content pane the box is the
       pane separator; alone on a narrow terminal it is the redundant outer
       frame every other surface dropped. *)
    let framed_top = if framed then framed_top else box_top in
    let framed_divider = if framed then framed_divider else box_divider in
    let framed_line = if framed then framed_line else box_line in
    let framed_empty = if framed then framed_empty else box_empty in
    let framed_bottom = if framed then framed_bottom else box_bottom in
    framed_top pane_buf pane_cols;
    let list_focused = state.resource_focus = Left_pane in
    framed_line pane_buf pane_cols
      ((if list_focused then Ansi.bold else Ansi.dim) ^ " Resources"
       ^ (if total = 0 then "" else Printf.sprintf " (%d)" total)
       ^ (if list_focused then "  [j/k]" else "")
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* The status line spends one of the budgeted rows, not an extra one:
       an extra row pushed the pane past its height and the frame's last
       casualty was the footer. *)
    let status_rows =
      match state.resources_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          1
      | None ->
          if total = 0 then begin
            framed_line pane_buf pane_cols
              (Ansi.dim ^ " (loading\xe2\x80\xa6)" ^ Ansi.reset);
            1
          end
          else 0
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    for i = 0 to list_rows_budget - 1 do
      match List.nth_opt rows_list (first + i) with
      | Some resource ->
          let selected = first + i = cursor in
          let name = resource_display_name resource in
          let line =
            if selected then
              Theme.selection ^ " " ^ name
              ^ String.make
                  (max 0
                     (pane_cols - 5 - Message_layout.display_width name))
                  ' '
              ^ Ansi.reset
            else " " ^ name
          in
          framed_line pane_buf pane_cols line
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane pane_buf pane_cols =
    let selected_resource = List.nth_opt rows_list cursor in
    let error_uri = Option.map fst state.resource_content_error in
    let content_uri = Option.map fst state.resource_content in
    let shown_uri =
      match state.resource_pending_uri, error_uri, content_uri with
      | Some uri, _, _ -> Some uri
      | None, Some uri, _ -> Some uri
      | None, None, Some uri -> Some uri
      | None, None, None -> Option.map (fun resource -> resource.Masc_tui_mcp.uri) selected_resource
    in
    let shown_resource =
      Option.bind shown_uri (fun uri ->
          List.find_opt
            (fun (resource : Masc_tui_mcp.resource) ->
               String.equal resource.uri uri)
            rows_list)
    in
    let title =
      match shown_resource with
      | Some resource -> "Resource · " ^ resource_display_name resource
      | None -> "Resource detail"
    in
    box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.resource_focus = Right_pane then Ansi.bold else Ansi.dim)
       ^ " " ^ title
       ^ (if state.resource_focus = Right_pane then "  [j/k]" else "")
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = framed_content_height ~rows in
    (match shown_resource with
     | None ->
         for _ = 1 to content_height do
           box_empty pane_buf pane_cols
         done
     | Some resource ->
         let contents =
           match state.resource_content, shown_uri with
           | Some (content_uri, parts), Some uri
             when String.equal content_uri uri -> Some parts
           | Some _, (Some _ | None) | None, _ -> None
         in
         let error =
           match state.resource_content_error, shown_uri with
           | Some (error_uri, detail), Some uri
             when String.equal error_uri uri -> Some detail
           | Some _, (Some _ | None) | None, _ -> None
         in
         let requested =
           match state.resource_pending_uri, shown_uri with
           | Some pending_uri, Some uri -> String.equal pending_uri uri
           | Some _, None | None, _ -> false
         in
         let rendered =
           Message_layout.wrap_body ~markdown:document_markdown
             ~max_cells:(max 1 (pane_cols - 8))
             ~sanitize:Terminal_text.single_line
             (resource_document resource contents ~error ~requested)
         in
         let total_lines = List.length rendered in
         let max_scroll = max 0 (total_lines - content_height) in
         let scroll = max 0 (min state.resource_scroll max_scroll) in
         (* The pane is the only place that knows how many rows the text
            actually used, so it reports the row it could draw back out. *)
         drawn_resource_scroll := scroll;
         for i = 0 to content_height - 1 do
           match List.nth_opt rendered (scroll + i) with
           | Some line -> box_line pane_buf pane_cols ("  " ^ line)
           | None -> box_empty pane_buf pane_cols
         done);
    box_bottom pane_buf pane_cols
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane ~framed:true left_buf left_cols;
     content_pane right_buf right_cols;
     write_two_panes buf ~left_cols:left_cols ~left:left_buf
       ~right:right_buf
   end
   else if state.resource_focus = Right_pane then content_pane buf cols
   else list_pane ~framed:false buf cols);
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_resources
            ~detail_focus:(state.resource_focus = Right_pane)));
  finish_surface state ~clamped:(Resource_scroll !drawn_resource_scroll)
    ~surface_key:"resources" ~rows:terminal_rows ~cols buf

(* How long ago the running binary's commit landed. Coarse on purpose: the
   question is "is this the build I think it is", and minutes answer it while
   seconds only look precise. *)
let binary_age_text = function
  | None -> "age unknown"
  | Some seconds when seconds < 60. -> "built just now"
  | Some seconds when seconds < 3600. ->
      Printf.sprintf "built %.0fm ago" (seconds /. 60.)
  | Some seconds when seconds < 86400. ->
      Printf.sprintf "built %.0fh ago" (seconds /. 3600.)
  | Some seconds -> Printf.sprintf "built %.0fd ago" (seconds /. 86400.)

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
  String.concat (Ansi.dim ^ " |" ^ Ansi.reset)
    [ name Config_runtime "runtime.toml"
    ; name Config_models "models"
    ; name Config_params "params"
    ; name Config_prompts "prompts"
    ; name Config_presets "presets"
    ; name Config_themes "themes"
    ; name Config_voice "voice"
    ]
  ^ Ansi.dim ^ "  p:next" ^ Ansi.reset

(* The Runtime_params registry. A view, not a second place values live:
   overrides are written by the server to .masc/runtime_params.json, and this
   shows what is there beside what it would be without them.

   runtime.toml sits in the pane next door and answers a different question --
   which runtimes and lanes exist. One value claimed by two files is how "I set
   it and it did not take" happens, so these stay two panes over one store. *)
let render_runtime_params (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title " MASC Config")
       (config_pane_strip state)
       (connection_badge state));
  (match state.runtime_params_notice with
   | None ->
     box_line_styled buf cols ~style:(Theme.recede ())
       "  Enter edits by type · E is advanced JSON · overrides persist in .masc/runtime_params.json"
   | Some (ok, detail) ->
     box_line_styled buf cols ~style:(if ok then Theme.ok () else Theme.bad ())
       ("  " ^ Terminal_text.single_line detail));
  let selected = List.nth_opt state.runtime_params state.runtime_params_cursor in
  let selected_contract =
    match selected with
    | None -> "  Select a row to see its contract"
    | Some row ->
      let open Tui_decode in
      let type_name =
        if String.trim row.rpr_value_type = "" then "typed value"
        else row.rpr_value_type
      in
      let bounds =
        [ Option.map (fun value -> "min " ^ value) row.rpr_min_json
        ; Option.map (fun value -> "max " ^ value) row.rpr_max_json
        ]
        |> List.filter_map Fun.id
        |> String.concat " · "
      in
      String.concat " · "
        (List.filter (fun text -> String.trim text <> "")
           [ "  " ^ type_name; bounds; row.rpr_description ])
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    (fit_width (Terminal_text.single_line selected_contract) (max 1 (cols - 1)));
  box_divider buf cols;
  let editing = Option.is_some state.runtime_param_edit in
  (* Editing adds a divider and two form rows.  Spend those rows out of the
     list budget so the footer remains visible instead of falling underneath
     the always-present composer. *)
  let content_height = max 1 (rows - (if editing then 10 else 7)) in
  let count = List.length state.runtime_params in
  let cursor = max 0 (min state.runtime_params_cursor (count - 1)) in
  let first = if cursor < content_height then 0 else cursor - content_height + 1 in
  (match state.runtime_params_error with
   | Some detail ->
     box_line buf cols ((Theme.bad ()) ^ "설정을 읽지 못했습니다: " ^ Ansi.reset
                        ^ Terminal_text.single_line detail);
     for _ = 2 to content_height do box_empty buf cols done
   | None ->
     if state.runtime_params_loading && state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  (loading runtime parameters…)" ^ Ansi.reset);
       for _ = 2 to content_height do box_empty buf cols done
     end
     else if state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  등록된 설정 없음" ^ Ansi.reset);
       for _ = 2 to content_height do box_empty buf cols done
     end else begin
       for index = 0 to content_height - 1 do
         match List.nth_opt state.runtime_params (first + index) with
         | None -> box_empty buf cols
         | Some row ->
           let open Tui_decode in
           let line =
             Printf.sprintf "  %s %-43s %-16s%s"
               (if row.rpr_has_override then "●" else "○")
               (Terminal_text.single_line row.rpr_key)
               (Terminal_text.single_line
                  (runtime_param_value_text ~value_type:row.rpr_value_type
                     row.rpr_current_json))
               (if row.rpr_has_override
                then Printf.sprintf "  default %s"
                       (Terminal_text.single_line
                          (runtime_param_value_text
                             ~value_type:row.rpr_value_type
                             row.rpr_default_json))
                else "")
           in
           if first + index = cursor then box_line_selected buf cols line
           else
             box_line_styled buf cols
               ~style:(if row.rpr_has_override then (Masc_tui_theme.tone Masc_tui_theme.Accent) else Ansi.dim) line
       done
     end);
  (match state.runtime_param_edit with
   | None -> ()
   | Some edit ->
     let friendly_bool =
       edit.rpe_mode = Friendly_value
       && List.mem (runtime_param_type_name edit.rpe_value_type)
            [ "bool"; "boolean" ]
     in
     let field_label =
       match edit.rpe_mode with
       | Advanced_json -> "JSON>"
       | Friendly_value when friendly_bool -> "choice>"
       | Friendly_value -> "value>"
     in
     let draft = Terminal_text.single_line edit.rpe_draft in
     let draft =
       if edit.rpe_replace_on_type && not friendly_bool
       then Theme.selection ^ draft ^ Ansi.reset
       else draft
     in
     box_divider buf cols;
     box_line buf cols
       (Printf.sprintf "  %s%s%s %s" Ansi.bold field_label Ansi.reset
          (fit_width draft (max 1 (cols - 12))));
     box_line_styled buf cols ~style:(Theme.recede ())
       (Printf.sprintf "  editing %s · %s"
          (Terminal_text.single_line edit.rpe_key)
          (match edit.rpe_mode with
           | Advanced_json -> "advanced JSON · Enter apply · Esc cancel"
           | Friendly_value when friendly_bool ->
             "Left/Right/Space toggle · Enter apply · Esc cancel"
           | Friendly_value ->
             "type to replace · Enter apply · Esc cancel")));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (match state.runtime_param_edit with
          | Some edit
            when edit.rpe_mode = Friendly_value
                 && List.mem (runtime_param_type_name edit.rpe_value_type)
                      [ "bool"; "boolean" ] ->
            "Left/Right/Space:toggle  Enter:apply  Esc:cancel"
          | Some { rpe_mode = Friendly_value; _ } ->
            "type:value  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | Some { rpe_mode = Advanced_json; _ } ->
            "type JSON  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | None ->
            "j/k:select  Enter/e:edit  E:advanced JSON  x:default  p:next"));
  finish_surface state ~surface_key:"config-params" ~rows:terminal_rows ~cols buf
;;

let render_prompt_registry (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let prompt_rows =
    match prompts with
    | Masc_tui_fetched.Ready snapshot ->
        Tui_decode.prompt_rows_for_operator
          ~show_fragments:state.prompts_show_fragments snapshot
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ ->
        []
  in
  let all_prompt_count =
    match prompts with
    | Masc_tui_fetched.Ready snapshot -> List.length snapshot.Tui_decode.ps_rows
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ -> 0
  in
  let total = List.length prompt_rows in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt prompt_rows cursor in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s%d/%d개 · %s%s  %s  %s"
       (screen_title " MASC 프롬프트")
       Ansi.dim total all_prompt_count
       (if state.prompts_show_fragments then "내부 조각 포함" else "주 프롬프트")
       Ansi.reset
       (config_pane_strip state)
       (connection_badge state));
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row =
    match prompts with
    | Masc_tui_fetched.Ready _ -> None
    | Masc_tui_fetched.Absent -> None
    | Masc_tui_fetched.Loading -> Some ((Theme.recede ()), "프롬프트 목록을 읽는 중…")
    | Masc_tui_fetched.Failed detail ->
      Some ((Theme.bad ()), Terminal_text.single_line detail)
  in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let combined_height = max 2 (rows - 9 - error_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_height = max 1 (combined_height - list_height) in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match status_row with
   | Some (style, text) ->
     box_line buf cols (style ^ "  " ^ fit_width text (cols - 6) ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  List.iteri
    (fun index (row : Tui_decode.prompt_row) ->
      if index >= first && index < first + list_height then begin
        incr drawn;
        let mark =
          match row.Tui_decode.pr_source with
          | Tui_decode.Prompt_override -> (Theme.warn ()) ^ "*" ^ Ansi.reset
          | Tui_decode.Prompt_file -> " "
          | Tui_decode.Prompt_missing -> (Theme.bad ()) ^ "!" ^ Ansi.reset
        in
        let category =
          match row.Tui_decode.pr_category with
          | "keeper" -> "키퍼"
          | "librarian" -> "기억"
          | "verification" -> "검증"
          | "judge" -> "판정"
          | "general" -> "일반"
          | category -> Terminal_text.single_line category
        in
        let surface =
          match row.Tui_decode.pr_operator_surface with
          | Tui_decode.Prompt_primary -> ""
          | Tui_decode.Prompt_fragment -> "조각"
        in
        let label =
          Printf.sprintf "%s %-4s %-4s %s  %s"
            mark
            (fit_width category 4)
            surface
            (fit_width (Terminal_text.single_line row.Tui_decode.pr_key) 30)
            (Ansi.dim
             ^ fit_width
                 (Terminal_text.single_line row.Tui_decode.pr_description)
                 (max 4 (cols - 52))
             ^ Ansi.reset)
        in
        if index = cursor then
          box_line buf cols (Theme.selection ^ " " ^ label ^ Ansi.reset)
        else box_line buf cols (" " ^ label)
      end)
    prompt_rows;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  (match selected with
   | None ->
       box_line_styled buf cols ~style:(Theme.recede ()) "  선택한 프롬프트가 없습니다";
       box_line_styled buf cols ~style:(Theme.recede ()) "  입력 계약을 표시할 수 없습니다";
       box_divider buf cols;
       for _ = 1 to detail_height do
         box_empty buf cols
       done
   | Some row ->
       let source =
         match row.Tui_decode.pr_source with
         | Tui_decode.Prompt_override -> "재정의"
         | Tui_decode.Prompt_file -> "파일"
         | Tui_decode.Prompt_missing -> "없음"
       in
       box_line buf cols
         (Printf.sprintf "  유효 템플릿  %s \xc2\xb7 %s \xc2\xb7 %s"
            (Terminal_text.single_line row.pr_key)
            (Terminal_text.single_line source)
            (Terminal_text.single_line row.pr_file_path));
       let input_contract =
         if String.equal row.pr_category "librarian" then
           "입력: Keeper 지침 | 현재 기억 | 제한된 대화 | 상대 관측 | 사실 최대 바이트"
         else
           match row.pr_template_variables with
           | [] -> "템플릿 입력: 없음"
           | variables -> "템플릿 입력: " ^ String.concat " | " variables
       in
       box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ input_contract);
       box_divider buf cols;
       let body_width = max 1 (cols - 6) in
       let effective_lines =
         Message_layout.wrap_body ~markdown:document_markdown
           ~max_cells:body_width ~sanitize:Terminal_text.single_line
           row.pr_effective
       in
       let actual_input_lines =
         if not (String.equal row.pr_category "librarian") then []
         else if state.prompts_librarian_input_loading then
           [ "최근 실제 Librarian 입력"; "(Admin 실행 상세를 불러오는 중...)"; "" ]
         else
           match state.prompts_librarian_input_error with
           | Some detail ->
               [ "최근 실제 Librarian 입력"
               ; "불러올 수 없음: " ^ Terminal_text.single_line detail
               ; ""
               ]
           | None ->
               (match state.prompts_librarian_input with
                | Some (key, lines) when String.equal key row.pr_key ->
                    lines @ [ "" ]
                | Some _ | None -> [])
       in
       let rendered = actual_input_lines @ ("유효 템플릿 본문" :: effective_lines) in
       let max_scroll = max 0 (List.length rendered - detail_height) in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       for index = 0 to detail_height - 1 do
         match List.nth_opt rendered (scroll + index) with
         | Some line -> box_line buf cols ("  " ^ line)
         | None -> box_empty buf cols
       done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:선택  PgUp/PgDn:읽기  a:내부 조각  i:최근 입력  e:편집  x:재정의 삭제  o:런타임 자산");
  finish_surface state ~surface_key:"prompts" ~rows:terminal_rows ~cols buf

(* The raw text assets are distributed with the binary and deliberately have
   no override contract.  They use the same Config page as the editable
   Markdown registry, but a distinct mode makes the missing edit controls an
   explicit capability boundary rather than an accidental omission. *)
let render_runtime_prompt_assets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let assets =
    match prompts with
    | Masc_tui_fetched.Ready snapshot -> snapshot.Tui_decode.ps_runtime_assets
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ ->
        []
  in
  let total = List.length assets in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt assets cursor in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s%d개 · 읽기 전용%s  %s  %s"
       (screen_title " MASC 런타임 프롬프트 자산")
       Ansi.dim total Ansi.reset
       (config_pane_strip state)
       (connection_badge state));
  box_line_styled buf cols ~style:(Theme.recede ())
    "  배포된 .txt 지시문 · registry override 대상이 아님";
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row =
    match prompts with
    | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent -> None
    | Masc_tui_fetched.Loading -> Some ((Theme.recede ()), "프롬프트 목록을 읽는 중…")
    | Masc_tui_fetched.Failed detail ->
      Some ((Theme.bad ()), Terminal_text.single_line detail)
  in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let combined_height = max 2 (rows - 10 - error_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_height = max 1 (combined_height - list_height) in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match status_row with
   | Some (style, text) ->
     box_line buf cols (style ^ "  " ^ fit_width text (cols - 6) ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  List.iteri
    (fun index (asset : Tui_decode.runtime_prompt_asset) ->
       if index >= first && index < first + list_height then begin
         incr drawn;
         let mark = if asset.pra_file_exists then " " else (Theme.bad ()) ^ "!" ^ Ansi.reset in
         let line =
           Printf.sprintf "%s %-32s %s"
             mark
             (fit_width (Terminal_text.single_line asset.pra_path) 32)
             (Ansi.dim
             ^ (if asset.pra_file_exists then "런타임 파일" else "동기화 후 누락")
              ^ Ansi.reset)
         in
         if index = cursor then box_line buf cols (Theme.selection ^ " " ^ line ^ Ansi.reset)
         else box_line buf cols (" " ^ line)
       end)
    assets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  (match selected with
   | None ->
     box_line_styled buf cols ~style:(Theme.recede ()) "  런타임 프롬프트 자산이 없습니다";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  서버가 오래되었거나 배포 자산을 아직 동기화하지 않았을 수 있습니다";
     box_divider buf cols;
     for _ = 1 to detail_height do box_empty buf cols done
   | Some asset ->
     let source = if asset.pra_file_exists then "런타임 파일" else "누락" in
     box_line buf cols
       (Printf.sprintf "  읽기 전용 자산  %s · %s · %s"
          (Terminal_text.single_line asset.pra_path)
          source
          (Terminal_text.single_line asset.pra_file_path));
     box_line_styled buf cols ~style:(Theme.recede ())
       "  이 자산은 registry override·편집 대상이 아닙니다";
     box_divider buf cols;
     let body_width = max 1 (cols - 6) in
     let rendered =
       Message_layout.wrap_body ~markdown:document_markdown
         ~max_cells:body_width ~sanitize:Terminal_text.single_line asset.pra_value
     in
     let max_scroll = max 0 (List.length rendered - detail_height) in
     let scroll = max 0 (min state.config_scroll max_scroll) in
     for index = 0 to detail_height - 1 do
       match List.nth_opt rendered (scroll + index) with
       | Some line -> box_line buf cols ("  " ^ line)
       | None -> box_empty buf cols
     done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:선택  PgUp/PgDn:읽기  o:레지스트리  r:새로고침");
  finish_surface state ~surface_key:"prompt-runtime-assets" ~rows:terminal_rows ~cols buf
;;

let render_prompts (state : state) =
  if state.prompts_show_runtime_assets
  then render_runtime_prompt_assets state
  else render_prompt_registry state
;;

(* The row the reader is on. A check rather than a colour, because the point
   of this screen is that colours are about to change. *)
let chosen_mark = "\xe2\x9c\x93"

(* Everything right of the theme name has a fixed cell budget: the palette
   blocks, page kind, and contrast result. Give the name what remains, up to
   the longest bundled name. Unlike a printf width this counts terminal cells
   and truncates, so gruvbox-material-light-medium cannot push the next three
   columns sideways. *)
let theme_name_width ~cols =
  let fixed_cells = 45 in
  max 8 (min 29 (framed_inner_width cols - fixed_cells))
;;

(* Prompt presets (#32777). A preset is one named snapshot of three
   surfaces the operator changes together: the prompt override table, each
   keeper's instructions, and runtime.toml's assignments and exact-output
   lanes. The pane lists them, saves the live state under a typed name, and
   restores one behind a two-press arm — a restore rewrites all three, and
   the report below the list is the only place it says what it skipped and
   whether runtime.toml committed. *)
let render_presets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let presets =
    match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_presets
  in
  let unreadable =
    match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_unreadable
  in
  let total = List.length presets in
  let cursor = max 0 (min state.presets_cursor (total - 1)) in
  let selected = List.nth_opt presets cursor in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s%d개%s  %s  %s"
       (screen_title " MASC 프리셋")
       Ansi.dim total Ansi.reset
       (config_pane_strip state)
       (connection_badge state));
  box_divider buf cols;
  let error_rows = if Option.is_some state.presets_error then 1 else 0 in
  let entry_rows = if Option.is_some state.preset_save_draft then 1 else 0 in
  let combined_height = max 2 (rows - 9 - error_rows - entry_rows) in
  let list_height = min 8 (max 1 (combined_height / 3)) in
  let detail_height = max 1 (combined_height - list_height) in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match state.presets_error with
   | Some detail ->
     box_line buf cols
       (Theme.bad () ^ "  " ^ fit_width (Terminal_text.single_line detail) (cols - 6)
        ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  if total = 0 then begin
    incr drawn;
    box_line_styled buf cols ~style:(Theme.recede ())
      (match state.presets_snapshot with
       | None -> "  불러오는 중..."
       | Some _ -> "  아직 프리셋이 없습니다 · s 로 지금 상태를 저장하세요")
  end;
  List.iteri
    (fun index (manifest : Tui_decode.preset_manifest) ->
      if index >= first && index < first + list_height then begin
        incr drawn;
        let armed =
          state.preset_restore_armed = Some manifest.Tui_decode.pm_name
        in
        let mark = if armed then Theme.warn () ^ "r" ^ Ansi.reset else " " in
        let label =
          mark ^ " "
          ^ fit_width
              (Terminal_text.single_line (Masc_tui_preset_text.pane_row manifest))
              (max 4 (cols - 6))
        in
        if index = cursor then box_line buf cols (Theme.selection ^ " " ^ label ^ Ansi.reset)
        else box_line buf cols (" " ^ label)
      end)
    presets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  let detail =
    Masc_tui_preset_text.detail_lines
      ~selected
      ~detail:
        (match selected with
         | None -> Masc_tui_fetched.Absent
         | Some (m : Tui_decode.preset_manifest) ->
           Masc_tui_fetched.view_for
             ~equal:String.equal
             state.preset_detail
             ~key:m.Tui_decode.pm_name)
      ~report:state.preset_report
    @ List.map
        (fun (name, reason) -> Printf.sprintf "! %s — %s" name reason)
        unreadable
  in
  let max_scroll = max 0 (List.length detail - detail_height) in
  let scroll = max 0 (min state.config_scroll max_scroll) in
  for index = 0 to detail_height - 1 do
    match List.nth_opt detail (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ fit_width (Terminal_text.single_line line) (max 4 (cols - 6)))
    | None -> box_empty buf cols
  done;
  (match state.preset_save_draft with
   | Some draft ->
     box_line buf cols
       (Theme.info () ^ "  이름: " ^ Ansi.reset
        ^ fit_width (Terminal_text.single_line draft) (max 4 (cols - 14))
        ^ Ansi.dim ^ "  Enter:저장  Esc:취소" ^ Ansi.reset)
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:선택  PgUp/PgDn:읽기  n:저장  u,u:되돌리기  r:새로고침");
  finish_surface state ~surface_key:"presets" ~rows:terminal_rows ~cols buf

let render_themes (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let all_entries = Theme_choice.entries () in
  let dark_count =
    List.fold_left
      (fun count (entry : Theme_choice.entry) ->
        if not entry.light then count + 1 else count)
      0 all_entries
  in
  let light_count = List.length all_entries - dark_count in
  let entries =
    match state.theme_filter with
    | `All -> all_entries
    | `Dark ->
        List.filter
          (fun (entry : Theme_choice.entry) -> not entry.light)
          all_entries
    | `Light ->
        List.filter
          (fun (entry : Theme_choice.entry) -> entry.light)
          all_entries
  in
  let native_count =
    List.fold_left
      (fun count (entry : Theme_choice.entry) ->
        if entry.lifted = 0 then count + 1 else count)
      0 entries
  in
  let show_sample = rows >= 20 in
  let chrome_rows = if show_sample then 11 else 8 in
  let content_height = max 1 (rows - chrome_rows) in
  let cursor =
    max 0 (min state.theme_cursor (max 0 (List.length entries - 1)))
  in
  let scroll = max 0 (cursor - content_height + 1) in
  let lift_on = Masc_tui_theme.lift_is_enabled () in
  let name_width = theme_name_width ~cols in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title
          (Printf.sprintf " MASC Themes · %d themes · %d native-pass"
             (List.length entries) native_count))
       (config_pane_strip state)
       (connection_badge state));
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    ("  " ^ fit_width "theme" (name_width + 2) ^ " "
     ^ fit_width "colours" 16 ^ "  " ^ fit_width "page" 9 ^ " "
     ^ fit_width "contrast" 12)
  ;
  let filter_tag =
    let chip label active count =
      if active then "[" ^ label ^ " " ^ string_of_int count ^ "]"
      else label ^ " " ^ string_of_int count
    in
    Printf.sprintf "Filter: [f] %s · %s · %s"
      (chip "All" (state.theme_filter = `All) (List.length all_entries))
      (chip "Dark" (state.theme_filter = `Dark) dark_count)
      (chip "Light" (state.theme_filter = `Light) light_count)
  in
  let explanation =
    if cols >= 92 then
      "  ·  "
      ^ (if lift_on then "native 7/7=no lift · lift N/7=N raised"
         else "native 7/7=all pass · N/7 low=below 4.5:1")
    else ""
  in
  box_line_styled buf cols ~style:Ansi.dim ("  " ^ filter_tag ^ explanation);
  let chosen = state.theme_choice in
  List.iteri
    (fun index (entry : Theme_choice.entry) ->
      if index >= scroll && index < scroll + content_height then begin
        let picked =
          match chosen with
          | Some name -> String.equal name entry.name
          | None -> false
        in
        let swatch =
          entry.Theme_choice.swatch
          |> List.map (fun rgb ->
               Masc_tui_theme.Sgr.background (Masc_tui_terminal_palette.best_color rgb)
               ^ "  \027[49m")
          |> String.concat ""
        in
        let row =
          Printf.sprintf "  %s %s " (if picked then chosen_mark else " ")
            (fit_width (Terminal_text.single_line entry.name) name_width)
          ^ swatch
          ^ "  "
          ^ fit_width (if entry.light then "light" else "dark") 9
          ^ " "
          ^ fit_width (Theme_choice.contrast_status ~lift_on entry) 12
        in
        if index = cursor then box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
        else box_line buf cols row
      end)
    entries;
  let drawn = min content_height (List.length entries) in
  for _ = drawn to content_height - 1 do
    box_empty buf cols
  done;
  if show_sample then begin
    box_divider buf cols;
    box_line buf cols
      (Printf.sprintf "  Sample: %s[● Ok]%s  %s[▲ Warn]%s  %s[× Bad]%s  %s[◆ Info]%s  %s[@keeper]%s  %s[⚡ tool]%s"
         (Theme.ok ()) Ansi.reset
         (Theme.warn ()) Ansi.reset
         (Theme.bad ()) Ansi.reset
         (Theme.info ()) Ansi.reset
         (Theme.keeper_origin ()) Ansi.reset
         (Theme.tool_origin ()) Ansi.reset);
    box_line buf cols
      (Printf.sprintf "  Syntax: %slet%s x = %s\"val\"%s in %s123%s  %s(+gain)%s  %s(-loss)%s"
         Theme.Syntax.keyword Ansi.reset
         Theme.Syntax.string Ansi.reset
         Theme.Syntax.code_number Ansi.reset
         Theme.Syntax.diff_added Ansi.reset
         Theme.Syntax.diff_removed Ansi.reset);
  end;
  box_line_styled buf cols ~style:Ansi.dim
    (match chosen with
     | None ->
       "  following the terminal's own colours \xe2\x80\x94 Enter picks a theme, f filters"
     | Some name ->
       Printf.sprintf "  %s \xe2\x80\x94 Enter picks another, x follows terminal, f filters"
         (Terminal_text.single_line name));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"themes" ~rows:terminal_rows ~cols buf

(* The model knobs sit in different tables -- [reasoning-effort] and
   [temperature] under [models.NAME], [max-tokens] under
   [PROVIDER.NAME] -- and runtime.toml is 2,300 lines, so reading it top to
   bottom never puts them side by side. On 2026-08-29 nine of ten
   ollama_cloud bindings carried neither; a request with no reasoning_effort
   has Ollama turn thinking on by itself, and one keeper spent a turn
   producing 2,000 characters of reasoning and no answer. This pane is the
   same source the runtime.toml pane shows, arranged so a missing knob is a
   column and not an absence.

   Read-only. Editing lands in the runtime.toml pane next door, which already
   has the preview-checked write path. *)
let render_config_models (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows_avail = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note =
    match state.runtime_config_view with
    | Some (path, _) -> Ansi.dim ^ path ^ Ansi.reset
    | None -> Ansi.dim ^ "(not loaded)" ^ Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "%s  %s  %s  %s" (screen_title " MASC Models")
       (config_pane_strip state) path_note (connection_badge state));
  box_divider buf cols;
  let content_height = max 1 (rows_avail - 5) in
  (match state.runtime_config_view_error, state.runtime_config_view with
   | Some detail, _ ->
       box_line buf cols
         (Theme.bad () ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, None ->
       box_line buf cols (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, Some _ ->
       let detail =
         List.nth_opt state.config_models_rows state.config_models_cursor
         |> Option.map Masc_tui_model_runtime_table.detail_lines
         |> Option.value ~default:[]
       in
       (* Keep the explanation attached to the selected row. Five rows are
          enough to name both owning sections without adding another modal or
          another editor path. On a very short terminal the table still keeps
          one visible row. *)
       let detail_height = min (List.length detail) (max 0 (content_height - 2)) in
       let table_height =
         max 1 (content_height - detail_height - if detail_height > 0 then 1 else 0)
       in
       (* [box_line] spends cells on the two border glyphs and the padding
          either side, and this pane adds two more for its own indent. A
          width that ignores them wraps the last column onto its own row,
          which reads as a blank value. *)
       let table =
         Masc_tui_model_runtime_table.render
           ~width:(max 40 (cols - 6 - 2))
           state.config_models_rows
       in
       let total = List.length table in
       let max_scroll = max 0 (total - table_height) in
       (* The window follows the cursor rather than the other way round: a
          cursor the frame does not draw is a selection the reader cannot
          see, and [e] would act on a row that is off screen. *)
       let cursor_line = state.config_models_cursor + 1 in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       let scroll =
         if cursor_line < scroll then cursor_line
         else if cursor_line >= scroll + table_height
         then min max_scroll (cursor_line - table_height + 1)
         else scroll
       in
       (* Row 0 of [table] is the header, so a cursor over the data rows is
          one lower than the line it marks. *)
       for i = 0 to table_height - 1 do
         let index = scroll + i in
         match List.nth_opt table index with
         | Some line ->
             let marked =
               if index = 0 then "  " ^ Ansi.bold ^ line ^ Ansi.reset
               else if index = cursor_line then Ansi.bold ^ Theme.info () ^ "> " ^ line ^ Ansi.reset
               else "  " ^ line
             in
             box_line buf cols marked
         | None -> box_empty buf cols
       done;
       if detail_height > 0
       then (
         box_divider buf cols;
         List.iteri
           (fun i line ->
             if i < detail_height
             then (
               let line =
                 "  " ^ fit_width (Terminal_text.single_line line) (max 1 (cols - 6))
               in
               if i = 0
               then box_line_styled buf cols ~style:(Ansi.bold ^ Theme.info ()) line
               else box_line_styled buf cols ~style:(Theme.recede ()) line))
           detail));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:row  e:open [models.NAME]  p:next pane  r:reload  Tab:next");
  finish_surface state ~surface_key:"config_models" ~rows:terminal_rows ~cols buf

let config_content_height (state : state) =
  let terminal_rows, _ = get_terminal_size () in
  max 1 (Masc_tui_types.surface_body_rows state ~terminal_rows - 7)

(* What voice resolved to, and on which microphone.

   Three facts an operator cannot get from runtime.toml. Whether the config
   loaded at all: a section that does not parse reads the same as one that was
   never written, and telling those apart took six days once. Which STT
   endpoint answers first, since a local server that is down falls back to a
   paid one silently. And the input device, because a capture that comes back
   empty is more often the wrong microphone than a threshold. *)
let render_voice (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  let field name value =
    box_line buf cols
      (Printf.sprintf "  %s%-18s%s %s" Ansi.dim name Ansi.reset value)
  in
  let member path json =
    List.fold_left
      (fun acc key ->
        match acc with
        | Some (`Assoc fields) -> List.assoc_opt key fields
        | Some _ | None -> None)
      (Some json) path
  in
  let string_of path json =
    match member path json with
    | Some (`String v) -> Some v
    | Some (`Bool b) -> Some (if b then "yes" else "no")
    | Some (`Int i) -> Some (string_of_int i)
    | Some _ | None -> None
  in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %s  %s"
       (screen_title " MASC Voice")
       (config_pane_strip state)
       (connection_badge state));
  box_line buf cols "";
  (match (state.voice_config, state.voice_config_error) with
   | _, Some message ->
       (* The distinction the pane exists for, said in words rather than drawn
          as an empty section. *)
       box_line_styled buf cols ~style:(Theme.warn ()) "  voice did not load";
       box_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim message Ansi.reset)
   | None, None ->
       box_line buf cols (Printf.sprintf "  %sreading…%s" Ansi.dim Ansi.reset)
   | Some json, None ->
       field "status" (Option.value (string_of [ "status" ] json) ~default:"?");
       box_line buf cols "";
       box_line buf cols (Printf.sprintf "  %sTTS%s" Ansi.bold Ansi.reset);
       field "model"
         (Option.value (string_of [ "tts"; "default_model" ] json) ~default:"—");
       field "voice"
         (Option.value (string_of [ "tts"; "default_voice" ] json) ~default:"—");
       box_line buf cols "";
       box_line buf cols (Printf.sprintf "  %sSTT%s" Ansi.bold Ansi.reset);
       field "model"
         (Option.value (string_of [ "stt"; "default_model" ] json) ~default:"—");
       field "endpoint"
         (Option.value
            (string_of [ "stt"; "active_endpoint"; "enabled" ] json)
            ~default:"—");
       field "fallback"
         (Option.value
            (string_of [ "stt"; "active_endpoint"; "fallback_configured" ] json)
            ~default:"—"));
  box_line buf cols "";
  box_line buf cols (Printf.sprintf "  %sInput%s" Ansi.bold Ansi.reset);
  field "device" (Option.value state.voice_input_device ~default:"unknown");
  box_line buf cols "";
  box_line buf cols
    (Printf.sprintf
       "  %sruntime.toml [voice] declares this; the server says what loaded%s"
       Ansi.dim Ansi.reset);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"p:next pane  r:refresh");
  finish_surface state ~surface_key:"voice" ~rows:terminal_rows ~cols buf
;;

let render_config (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note =
    match state.runtime_config_view with
    | Some (path, _) -> Ansi.dim ^ path ^ Ansi.reset
    | None -> Ansi.dim ^ "(not loaded)" ^ Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "%s  %s  %s  %s  %s" (screen_title " MASC Config")
       (config_pane_strip state) path_note
       (Printf.sprintf "%s%s%s" Ansi.dim
          (let now = Unix.localtime (Unix.gettimeofday ()) in
           Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
             now.Unix.tm_sec)
          Ansi.reset)
       (connection_badge state));
  (* Where this server reads from, and how old the binary serving it is. A
     stale binary answers every request as confidently as a current one, so
     the age is the only thing on screen that separates them. *)
  (match state.server_identity with
   | None -> box_line buf cols (Ansi.dim ^ "  (server identity unread)" ^ Ansi.reset)
   | Some identity ->
       box_line buf cols
         (Printf.sprintf "%s  base %s   masc %s   binary %s%s" Ansi.dim
            (fit_width identity.Tui_decode.sid_base_path 28)
            (fit_width identity.Tui_decode.sid_masc_root 32)
            (binary_age_text identity.Tui_decode.sid_binary_commit_age_s)
            Ansi.reset));
  box_divider buf cols;
  let content_height = config_content_height state in
  (match state.runtime_config_view_error, state.runtime_config_view with
   | Some detail, _ ->
       box_line buf cols ((Theme.bad ()) ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, None ->
       box_line buf cols (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, Some (_, rows) ->
       let total = List.length rows in
       let max_scroll = max 0 (total - content_height) in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       for i = 0 to content_height - 1 do
         match List.nth_opt rows (scroll + i) with
         | Some segments ->
             (* Painted through [lexed_span], the table the Code surface reads.
                The runtime config is TOML and the lexer already answers for it;
                what was missing was anyone asking. *)
             let line = String.concat "" (List.map lexed_span segments) in
             let line =
               Printf.sprintf "%s%4d%s  %s" Ansi.dim (scroll + i + 1)
                 Ansi.reset line
             in
             if scroll + i = state.runtime_config_cursor then
               box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
             else box_line buf cols line
         | None -> box_empty buf cols
       done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         "j/k:value field  PgUp/PgDn:page  e:edit (preview-checked)  r:reload  Tab:next");
  finish_surface state ~surface_key:"config" ~rows:terminal_rows ~cols buf

let render_surface (state : state) =
  match state.view with
  | Overview ->
      (* Same fallback shape as Board/Planning detail: a detail id whose row
         left the backlog renders the list, not a frame for a missing task. *)
      (match state.task_detail_id with
       | Some _ -> (
           match
             Task_selection.detail_row
               ~detail_id:state.task_detail_id
               ~tasks:state.tasks_domain
           with
           | Some task -> render_task_detail state task
           | None -> render_overview state )
       | None -> render_overview state)
  | Keepers Keeper_list ->
      if state.repository_changes_open then render_repository_changes state
      else render_keeper_list state
  | Keepers Keeper_detail ->
      if state.repository_changes_open then render_repository_changes state
      else render_keeper_detail state
  | Keepers Keeper_logs -> render_keeper_logs state
  | Keepers Keeper_calls -> render_keeper_calls state
  | Keepers Keeper_message ->
      if state.repository_changes_open then render_repository_changes state
      else render_keeper_message state
  | Keepers Keeper_runtime_pick -> render_runtime_pick state
  | Lanes -> render_lanes state
  | Clients -> render_clients state
  | Board ->
      (match state.board_mode with
       | Board_list -> render_board_list state
       | Board_compose -> render_board_compose state
       | Board_read post_id ->
           match List.find_opt (fun p -> p.bp_id = post_id) state.board_posts with
           | Some post -> render_board_read state post
           | None -> render_board_list state)
  | Planning ->
      (match state.planning_mode with
       | Planning_list -> render_planning_list state
       | Planning_detail goal_id ->
           let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
           match List.find_opt (fun g -> g.pg_id = goal_id) goals with
           | Some goal ->
               render_planning_detail state
                 ~armed:(goal_action_armed_for state goal_id) goal
           | None -> render_planning_list state)
  | Approvals ->
      (* Open on the row the cursor is on. An ask that resolves while it is
         open takes the row with it, so the detail closes rather than showing
         something the queue no longer holds. *)
      (match
         if state.approval_detail_open then
           List.nth_opt (approval_items state) state.approval_cursor
         else None
       with
       | Some row -> render_approval_detail state row
       | None -> render_approvals state)
  | Verification -> render_verification state
  | Harness -> render_harness state
  | Fusion ->
      (match state.fusion_mode with
       | Fusion_list -> render_fusion_list state
       | Fusion_detail run_id -> render_fusion_detail state run_id)
  | Memory ->
      if Option.is_some state.memory_facts_keeper then
        render_memory_facts state
      else render_memory state
  | Repositories -> render_repositories state
  | Changes -> render_changes state
  | Connectors -> render_connectors state
  | Runtime ->
      (match state.runtime_detail_target with
       | None -> render_runtime state
       | Some target -> render_runtime_detail state target)
  | Config -> (
    match state.config_pane with
    | Config_prompts -> render_prompts state
    | Config_presets -> render_presets state
    | Config_themes -> render_themes state
    | Config_runtime -> render_config state
    | Config_models -> render_config_models state
    | Config_params -> render_runtime_params state
    | Config_voice -> render_voice state)
  | Resources -> render_resources state
  | Code ->
      if state.repository_changes_open then render_repository_changes state
      else render_code state
  | Tools -> render_tools state
  | Acting -> render_acting state
  | Metrics -> render_metrics state
  | System_logs ->
      (match state.system_logs_detail_seq with
       | None -> render_system_logs state
       | Some seq -> render_system_log_detail state seq)
  | Schedules -> render_schedules state

let help_surface_name (surface : surface) =
  match surface with
  | Overview -> "Overview"
  | Acting -> "Activity"
  | Metrics -> "Metrics"
  | Keepers _ -> "Keepers"
  | Memory -> "Memory"
  | Approvals -> "Approvals"
  | Board -> "Board"
  | Planning | Verification | Harness -> "Planning"
  | Fusion -> "Fusion"
  | Repositories | Code | Changes -> "Workspace"
  | Runtime | Lanes | Clients -> "Runtime"
  | Config | Resources | Tools -> "Config"
  | Connectors | Schedules -> "Keepers"
  | System_logs -> "Activity"

let help_ascii_banner ~cols (state : state) =
  let inner_width = max 1 (framed_inner_width cols) in
  let surface_label = help_surface_name state.view in
  let hints_status = if state.hints_visible then "on" else "off" in
  let bar_char = "\xe2\x94\x80" in
  let repeat_utf8 str count =
    let buf = Buffer.create (String.length str * count) in
    for _ = 1 to count do Buffer.add_string buf str done;
    Buffer.contents buf
  in
  if inner_width >= 72 then
    [ "  " ^ (Theme.info ()) ^ "\xe2\x95\x94\xe2\x95\xa6\xe2\x95\x97\xe2\x95\x94\xe2\x95\x90\xe2\x95\x97\xe2\x95\x94\xe2\x95\x90\xe2\x95\x97\xe2\x95\x94\xe2\x95\x90\xe2\x95\x97" ^ Ansi.reset
      ^ "  " ^ Ansi.bold ^ (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "M A S C" ^ Ansi.reset
      ^ "  \xc2\xb7  " ^ Ansi.bold ^ "Multi-Agent System Coordinator" ^ Ansi.reset
    ; "  " ^ (Theme.info ()) ^ "\xe2\x95\x91\xe2\x95\x91\xe2\x95\x91\xe2\x95\xa0\xe2\x95\x90\xe2\x95\xa3\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x97\xe2\x95\x91    " ^ Ansi.reset
      ^ Ansi.dim ^ "Interactive Autonomous Fleet Workspace & Operations" ^ Ansi.reset
    ; "  " ^ (Theme.info ()) ^ "\xe2\x95\x9a \xe2\x95\xa9\xe2\x95\x9a \xe2\x95\xa9\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x9d\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x9d" ^ Ansi.reset
      ^ "  Active: " ^ (Theme.warn ()) ^ "[" ^ surface_label ^ "]" ^ Ansi.reset
      ^ Ansi.dim ^ "  \xc2\xb7  [?] Close  \xc2\xb7  [h] Hints (" ^ hints_status ^ ")" ^ Ansi.reset
    ; "  " ^ (Theme.recede ()) ^ repeat_utf8 bar_char (min 68 (inner_width - 4)) ^ Ansi.reset
    ; ""
    ]
  else
    [ "  " ^ Ansi.bold ^ (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "[ MASC · Multi-Agent System Coordinator ]" ^ Ansi.reset
    ; "  Active: " ^ (Theme.warn ()) ^ "[" ^ surface_label ^ "]" ^ Ansi.reset
      ^ Ansi.dim ^ " · [?] Close · [h] Hints (" ^ hints_status ^ ")" ^ Ansi.reset
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
      Ansi.bold ^ Theme.category Theme.Slot_4
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
      Ansi.bold ^ Theme.category Theme.Slot_4
  | Masc_tui_context_inspector.Byte_count_only ->
      Ansi.bold ^ (Theme.recede ())

let context_evidence_badge evidence =
  Printf.sprintf "%s[ %s ]%s"
    (context_evidence_style evidence)
    (Masc_tui_context_inspector.input_evidence_label evidence)
    Ansi.reset

let context_split_lines ~cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = Theme.recede () ^ " │ " ^ Ansi.reset in
  let right_width = max 1 (inner - left_width - 3) in
  let count = max (List.length left) (List.length right) in
  List.init count (fun index ->
      let left = Option.value ~default:"" (List.nth_opt left index) in
      let right = Option.value ~default:"" (List.nth_opt right index) in
      fit_width left left_width ^ divider ^ fit_width right right_width)

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

(* The plain body's line count, for the keys that scroll it. *)
let context_inspector_viewport state =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let count =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, _) -> List.length lines
    | Split _ -> 0
  in
  (count, framed_content_height ~rows)

(* The rows a split body holds below the common summary: one pinned header
   row that carries both column titles and the focus caret, then the window
   the two columns share. The key handler and the frame both ask this,
   because keys that step past what the frame can show are the bug this pane
   was already carrying once. *)
let context_split_pane_height ~content_height ~common_len =
  max 0 (content_height - common_len - 1)

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

let render_context_inspector state =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let keeper =
    Option.value ~default:"no Keeper" state.context_inspector_keeper
    |> Keeper_chat.terminal_safe_text
  in
  let refreshing =
    if state.context_inspector_loading then Ansi.dim ^ "  refreshing" ^ Ansi.reset
    else ""
  in
  let tab_label tab number label =
    if state.context_inspector_tab = tab then
      Ansi.bold ^ (Theme.info ()) ^ number ^ ":" ^ label ^ Ansi.reset
    else Ansi.dim ^ number ^ ":" ^ label ^ Ansi.reset
  in
  (* The search query, drawn where the typing lands: the Keepers strip's
     own indicator sits on a surface this pane replaced. *)
  let search_marker =
    match state.search with
    | Some query ->
        Printf.sprintf "  %s/%s▌%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line query)
          Ansi.reset
    | None ->
        if state.search_last = "" then ""
        else
          Printf.sprintf "  %s/%s (n/N)%s" Ansi.dim
            (Terminal_text.single_line state.search_last)
            Ansi.reset
  in
  framed_top buf cols;
  framed_line buf cols
    (Printf.sprintf "%s Context  %s%s  %s  %s"
       (screen_title "") keeper refreshing
       (tab_label Masc_tui_context_inspector.Composition "1" "stack")
       (tab_label Masc_tui_context_inspector.Exact_input "2" "request")
       ^ "  "
       ^ (tab_label Masc_tui_context_inspector.Input_map "3" "proof")
       ^ search_marker);
  framed_divider buf cols;
  let content_height = framed_content_height ~rows in
  let drawn =
    match context_inspector_content_lines ~cols state with
    | Plain (lines, selected) ->
        let scroll =
          Masc_tui_scroll.normalize ~count:(List.length lines)
            ~height:content_height state.context_inspector_scroll
        in
        (* The cursor names a row, the window follows it: on the single-column
           shapes nothing lives under the row, so the smallest move that keeps
           it drawn is the right one. *)
        let scroll =
          match selected with
          | None -> scroll
          | Some cursor ->
              Masc_tui_scroll.normalize ~count:(List.length lines)
                ~height:content_height
                (Masc_tui_scroll.ensure_visible ~cursor ~height:content_height scroll)
        in
        let window =
          lines
          |> List.filteri (fun index _ ->
               index >= scroll && index < scroll + content_height)
        in
        List.iter (framed_line buf cols) window;
        List.length window
    | Split { common; left; right } ->
        (* The summary clips to the frame rather than overflowing it: on a
           short terminal the split gives way before the pane draws a row
           past its last. *)
        let common_rows =
          common |> List.filteri (fun index _ -> index < content_height)
        in
        List.iter (framed_line buf cols) common_rows;
        let split_height =
          context_split_pane_height ~content_height
            ~common_len:(List.length common)
        in
        let split_drawn =
          if split_height <= 0 then 0
          else begin
            (* Both columns are header :: rows, so the heads are total. The
               header row stays pinned above the windows -- it carries the
               focus caret, and a caret that scrolls away stops saying which
               pane hears j/k. *)
            let pinned =
              context_split_lines ~cols ~left_width:(context_split_width cols)
                ~left:[ List.hd left ] ~right:[ List.hd right ]
            in
            List.iter (framed_line buf cols) pinned;
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
            let window =
              context_split_lines ~cols ~left_width:(context_split_width cols)
                ~left:
                  (context_split_window ~height:body_height ~offset:left_offset
                     (List.tl left))
                ~right:
                  (context_split_window ~height:body_height ~offset:right_offset
                     (List.tl right))
            in
            List.iter (framed_line buf cols) window;
            split_height
          end
        in
        List.length common_rows + split_drawn
  in
  for _ = 1 to max 0 (content_height - drawn) do
    framed_line buf cols ""
  done;
  framed_bottom buf cols;
  let hints =
    match state.context_inspector_exact with
    | Some _ -> "j/k:scroll  Esc:list"
    | None -> (
        match
          state.context_inspector_tab, cols >= keeper_split_threshold_cols
        with
        | (Masc_tui_context_inspector.Exact_input | Masc_tui_context_inspector.Input_map), true ->
            "1/2/3 or Tab:switch  [/] turn  /:search  j/k:select or scroll  h/l:pane  Enter:open exact  r:refresh  Esc:close"
        | _ ->
            "1/2/3 or Tab:switch  [/] turn  /:search  j/k:select  Enter:open exact  r:refresh  Esc:close")
  in
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);
  finish_surface state ~surface_key:"context-inspector" ~rows:terminal_rows
    ~cols buf

(* What the help overlay can show right now: the rows its sheet folds to at
   this width, and the height it draws them in. The key handler bounds its
   step against this, so a press that the frame cannot spend is not taken. *)
let help_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let header = help_ascii_banner ~cols state in
  ( List.length (Masc_tui_help.sheet ~header ~cols (help_lines state))
  , framed_content_height ~rows )

(* The [:] palette: a typed filter over every jump the strip and roster
   offer. The list is the same [palette_matches] the Enter key resolves, so
   what is highlighted is what will run. *)
let render_palette (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 2048 in
  let matches = Masc_tui_types.palette_matches state in
  let total = List.length matches in
  let cursor = max 0 (min state.palette_cursor (total - 1)) in
  framed_shadow_top buf cols;
  (* A choice says which question, how many names and which line; the
     prompt is a filter over those names, not a jump query. *)
  let title, prompt, action =
    match state.palette_mode with
    | Masc_tui_types.Palette_jump -> (" Quick Jump & Navigation", ":", "Jump")
    | Masc_tui_types.Palette_choice { choice_question; choice_line } ->
        let names = List.length (Masc_tui_types.code_cursor_line_symbols state) in
        ( Printf.sprintf " %s \xc2\xb7 %d name%s on line %d" choice_question names
            (if names = 1 then "" else "s") choice_line
        , "filter:"
        , "Ask" )
  in
  framed_shadow_line buf cols
    (screen_title title ^ "  "
     ^ (Theme.warn ()) ^ "\xe2\x9a\xa1" ^ Ansi.reset ^ "  "
     ^ Ansi.bold ^ prompt ^ Ansi.reset ^ " "
     ^ (Terminal_text.single_line state.palette_query)
     ^ ((Masc_tui_theme.tone Masc_tui_theme.Accent) ^ "\xe2\x96\x8c" ^ Ansi.reset));
  framed_shadow_divider buf cols;
  let content_height = framed_content_height ~rows in
  let first =
    if cursor < content_height then 0
    else cursor - content_height + 1
  in
  matches
  |> List.filteri (fun i _ -> i >= first && i < first + content_height)
  |> List.iteri (fun visible_index (label, _) ->
       let selected = first + visible_index = cursor in
       if selected then
         framed_shadow_line_styled buf cols ~style:Theme.selection (" \xe2\x96\xb8 " ^ label)
       else
         framed_shadow_line buf cols ("   " ^ label));
  if total = 0 then
    framed_shadow_line buf cols (Ansi.dim ^ "   (no match)" ^ Ansi.reset);
  framed_shadow_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Printf.sprintf "%d/%d · [Enter] %s · [Up/Down] Navigate · [Esc] Close"
            (if total = 0 then 0 else cursor + 1)
            total action));
  finish_surface state ~surface_key:"palette" ~rows:terminal_rows ~cols buf

let render_patch_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let path_label =
    match state.patch_modal_path with
    | Some p -> p
    | None -> (match state.repository_changes_diff_path with Some p -> p | None -> "Active Working Tree")
  in
  framed_shadow_top buf cols;
  framed_shadow_line buf cols
    (screen_title " Patch & Diff Review" ^ "  "
     ^ (Theme.info ()) ^ "\xe2\x9a\xa1 " ^ Ansi.reset
     ^ Ansi.bold ^ Terminal_text.single_line path_label ^ Ansi.reset);
  framed_shadow_divider buf cols;
  framed_shadow_line_styled buf cols ~style:(Theme.recede ())
    "  old   new     diff preview (syntax colored)";
  framed_shadow_divider buf cols;
  let diff_opt =
    match state.patch_modal_diff with
    | Some (_, d) -> Some d
    | None -> (match state.repository_changes_diff with Some (_, d) -> Some d | None -> None)
  in
  let diff_rows =
    match diff_opt with
    | Some diff -> diff.Masc.Tui_decode.gd_rows
    | None -> []
  in
  let total = List.length diff_rows in
  let fixed_chrome = 9 in
  let content_height = max 1 (rows - fixed_chrome) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.patch_modal_scroll max_scroll) in
  state.patch_modal_scroll <- scroll;
  if total = 0 then begin
    let msg =
      match state.patch_modal_error with
      | Some e -> Printf.sprintf "(diff load error: %s — Esc to close)" e
      | None ->
          (match state.repository_changes_diff_error with
           | Some e -> Printf.sprintf "(diff load error: %s — Esc to close)" e
           | None -> "(no pending patch diff loaded — Esc to close)")
    in
    framed_shadow_line buf cols (Ansi.dim ^ "   " ^ msg ^ Ansi.reset);
    for _ = 1 to content_height - 1 do
      framed_shadow_empty buf cols
    done
  end else begin
    let diff_array = Array.of_list diff_rows in
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      if idx >= total then
        framed_shadow_empty buf cols
      else
        let row = diff_array.(idx) in
        let inner = framed_inner_width (cols - 1) in
        let span = tree_diff_row_span ~width:inner row in
        let rendered_line = Masc_tui_span.render span in
        framed_shadow_line buf cols (fit_width rendered_line inner)
    done
  end;
  framed_shadow_divider buf cols;
  framed_shadow_line buf cols
    (Printf.sprintf "  %s[e]%s Edit ($EDITOR)   %s[j/k]%s Scroll   %s[g/G]%s Top/Bottom   %s[Esc/q]%s Close"
       (Theme.info ()) Ansi.reset
       (Theme.info ()) Ansi.reset
       (Theme.info ()) Ansi.reset
       (Theme.recede ()) Ansi.reset);
  framed_shadow_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Printf.sprintf "[%d lines, scroll %d]  e:edit  j/k:scroll  g/G:top/bottom  Esc/q:close" total scroll));
  finish_surface state ~surface_key:"patch-modal" ~rows:terminal_rows ~cols buf
;;

let render_link_preview_modal (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let url_opt =
    match state.link_modal_url with
    | Some u -> Some u
    | None ->
        (match state.link_modal_links with
         | first :: _ -> Some first
         | [] -> None)
  in
  match url_opt with
  | None ->
      framed_shadow_top buf cols;
      framed_shadow_line buf cols
        (screen_title " Web Link Preview & Embed" ^ "  "
         ^ (Theme.info ()) ^ "\xf0\x9f\x8c\x90 " ^ Ansi.reset
         ^ Ansi.dim ^ "(no links)" ^ Ansi.reset);
      framed_shadow_divider buf cols;
      let fixed_chrome = 7 in
      let content_height = max 1 (rows - fixed_chrome) in
      framed_shadow_line buf cols "  (no web links found in this conversation to preview — Esc to close)";
      for _ = 2 to content_height do
        framed_shadow_empty buf cols
      done;
      framed_shadow_divider buf cols;
      framed_shadow_line buf cols
        (Printf.sprintf "  %s[Esc/q]%s Close" (Theme.recede ()) Ansi.reset);
      framed_shadow_bottom buf cols;
      Buffer.add_string buf
        (footer_line state ~max_cells:cols ~hints:"Esc:close");
      finish_surface state ~surface_key:"link-modal" ~rows:terminal_rows ~cols buf
  | Some url ->
      let preview = Masc_tui_link_preview.get_preview url in
      framed_shadow_top buf cols;
      framed_shadow_line buf cols
        (screen_title " Web Link Preview & Embed" ^ "  "
         ^ (Theme.info ()) ^ "\xf0\x9f\x8c\x90 " ^ Ansi.reset
         ^ Ansi.bold ^ Terminal_text.single_line (Masc_tui_link_preview.site_label preview) ^ Ansi.reset);
      framed_shadow_divider buf cols;
      let total_links = List.length state.link_modal_links in
      let nav_line_count =
        if total_links > 1 then begin
          let nav =
            Printf.sprintf "  %s[Link %d of %d]%s  [n] Next link   [p] Previous link   [o] Open in browser"
              (Theme.warn ()) (state.link_modal_cursor + 1) total_links Ansi.reset
          in
          framed_shadow_line buf cols nav;
          framed_shadow_divider buf cols;
          2
        end else 0
      in
      let fixed_chrome = 7 + nav_line_count in
      let content_height = max 1 (rows - fixed_chrome) in
      let content_lines =
        Masc_tui_link_preview.render_modal_card
          ~width:(framed_inner_width (cols - 1)) ~height:content_height preview
      in
      let total = List.length content_lines in
      let max_scroll = max 0 (total - content_height) in
      let scroll = max 0 (min state.link_modal_scroll max_scroll) in
      state.link_modal_scroll <- scroll;
      let lines_array = Array.of_list content_lines in
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx >= total then
          framed_shadow_empty buf cols
        else
          let line = lines_array.(idx) in
          framed_shadow_line buf cols line
      done;
      framed_shadow_divider buf cols;
      framed_shadow_line buf cols
        (Printf.sprintf "  %s[o]%s Browser   %s[y]%s Copy URL   %s[v]%s View Image   %s[j/k]%s Scroll   %s[Esc/q]%s Close"
           (Theme.ok ()) Ansi.reset
           (Theme.info ()) Ansi.reset
           (Theme.info ()) Ansi.reset
           (Theme.recede ()) Ansi.reset
           (Theme.recede ()) Ansi.reset);
      framed_shadow_bottom buf cols;
      Buffer.add_string buf
        (footer_line state ~max_cells:cols
           ~hints:(Printf.sprintf "[%s] o:browser  y:copy  v:image  n/p:cycle  j/k:scroll  Esc:close"
                     (Masc_tui_link_preview.site_label preview)));
      finish_surface state ~surface_key:"link-modal" ~rows:terminal_rows ~cols buf
;;

let render_help (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  framed_top buf cols;
  framed_line buf cols
    (screen_title " MASC Cheat Sheet" ^ "  " ^ Ansi.dim
    ^ "hints "
    ^ (if state.hints_visible then "on" else "off")
    ^ " \xc2\xb7 [h] toggle \xc2\xb7 [Esc] close" ^ Ansi.reset);
  framed_divider buf cols;
  let header = help_ascii_banner ~cols state in
  let lines = help_lines state in
  let rendered_rows = Masc_tui_help.sheet ~header ~cols lines in
  let content_height = framed_content_height ~rows in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length rendered_rows) ~height:content_height state.help_scroll
  in
  rendered_rows
  |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun line -> framed_line buf cols line);
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"j/k:scroll  h:hints  Esc:close");
  finish_surface state ~surface_key:"help" ~rows:terminal_rows ~cols buf

(* Rows the agenda panel can show, and how many it has. The keypress bounds
   the scroll from the same pair the frame draws with -- the shape
   [Masc_tui_scroll] exists to keep in one place. *)
let agenda_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let lines =
    Agenda.overlay
      ~now:(Unix.gettimeofday ())
      ~localtime:Unix.localtime
      ~cols:(framed_inner_width cols)
      (Masc_tui_types.agenda state)
  in
  (List.length lines, framed_content_height ~rows)
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

let answering_viewport (state : state) =
  let terminal_rows, _cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  ( List.length (answering_lines state)
  , max 1 (framed_content_height ~rows - answering_preview_rows) )

let render_answering (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 2048 in
  framed_top buf cols;
  framed_line
    buf
    cols
    (screen_title " Live Keeper Turns & Answering" ^ "  "
     ^ (Theme.info ()) ^ "\xe2\x97\x90" ^ Ansi.reset ^ "  "
     ^ Ansi.dim ^ "· [Enter] Chat · [Esc] Close" ^ Ansi.reset);
  framed_divider buf cols;
  let lines = answering_lines state in
  let content_height =
    max 1 (framed_content_height ~rows - answering_preview_rows)
  in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length lines)
      ~height:content_height
      state.answering_scroll
  in
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
      if selected && Option.is_some line.Masc_tui_answering.target then "\xe2\x96\xb8 "
      else "  "
    in
    caret ^ tone_prefix ^ line.Masc_tui_answering.text ^ Ansi.reset
  in
  lines
  |> List.mapi (fun i line -> (i, line))
  |> List.filter (fun (i, _) -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun (i, line) ->
         framed_line buf cols (paint ~selected:(i = state.answering_cursor) line));
  (* The fixed preview panel: what the cursor's keeper is doing right now,
     from the turns poll's live glance. Drawn empty rather than omitted so
     the list above never reflows with the cursor. *)
  framed_divider buf cols;
  let preview_lines =
    let cursor_preview =
      match List.nth_opt lines state.answering_cursor with
      | Some { Masc_tui_answering.target = Some keeper_name; _ } ->
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
      | Some _ | None -> None
    in
    match cursor_preview with
    | Some (keeper_name, preview) ->
        let doing =
          match preview.Tui_decode.ktp_current_tool with
          | Some tool_name -> "\xe2\x96\xb6 " ^ tool_name
          | None -> "\xe2\x96\xb6 writing"
        in
        let tail =
          match
            Terminal_text.single_line preview.Tui_decode.ktp_text_tail
          with
          | "" -> "(no text yet \xe2\x80\x94 tool calls only)"
          | tail -> tail
        in
        [ Ansi.bold ^ keeper_name ^ Ansi.reset ^ "  " ^ (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ doing
          ^ Ansi.reset
        ; Ansi.dim ^ tail ^ Ansi.reset
        ]
    | None ->
        [ Ansi.dim ^ "live preview \xe2\x80\x94 none for this row" ^ Ansi.reset
        ; ""
        ]
  in
  List.iter (fun line -> framed_line buf cols line) preview_lines;
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:"[j/k] Move · [Enter] Open Chat · [Esc] Close");
  finish_surface state ~surface_key:"answering" ~rows:terminal_rows ~cols buf
;;

let render_agenda (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 2048 in
  framed_top buf cols;
  framed_line
    buf
    cols
    (screen_title " Agenda & Upcoming Timers" ^ "  " ^ Ansi.dim ^ "· [j/k] Scroll · [Esc] Close" ^ Ansi.reset);
  framed_divider buf cols;
  let lines =
    Agenda.overlay
      ~now:(Unix.gettimeofday ())
      ~localtime:Unix.localtime
      ~cols:(framed_inner_width cols)
      (Masc_tui_types.agenda state)
  in
  let content_height = framed_content_height ~rows in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length lines)
      ~height:content_height
      state.agenda_scroll
  in
  let paint (line : Agenda.line) =
    match line.Agenda.tone with
    | Agenda.Heading -> Ansi.bold ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Wake -> (Theme.recede ()) ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Question -> (Theme.bad ()) ^ line.Agenda.text ^ Ansi.reset
    | Agenda.Quiet -> Ansi.dim ^ line.Agenda.text ^ Ansi.reset
  in
  lines
  |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun line -> framed_line buf cols (paint line));
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"[j/k] Scroll · [Esc] Close");
  finish_surface state ~surface_key:"agenda" ~rows:terminal_rows ~cols buf
;;

let render_terminal_too_small ~rows ~cols =
  let buf = Buffer.create 64 in
  Buffer.add_string buf
    (fit_width
       (Printf.sprintf "terminal too small -- resize to at least %d rows; q: quit"
          Render_schedule.Viewport.minimum_fixed_chrome_rows)
       cols);
  Buffer.add_char buf '\n';
  finish_frame ~compact_frame:true ~surface_key:"terminal-too-small"
    ~cursor:Frame_presenter.Hidden ~rows ~cols buf

(** Keep every high-chrome surface out of a viewport that cannot contain the
    largest declared fixed-row budget. Main ignores hidden surface input, and
    growing the terminal restores the unchanged selected surface. *)
let render (state : state) =
  (* Decide the pane before any surface measures the terminal. Modals draw
     over the whole terminal and the Activity feed already fills its own
     screen, so neither reserves the columns. *)
  (acting_pane_reserved_cols :=
     let _rows, terminal_cols = Masc_tui_ansi.get_terminal_size () in
     let modal =
       state.palette_open || state.context_inspector_open || state.help_open
       || state.agenda_open || state.answering_open
     in
     if modal || state.view = Acting then 0
     else if
       Masc_tui_acting_pane.shown ~hidden:state.acting_pane_hidden
         ~cols:terminal_cols
     then Masc_tui_acting_pane.pane_cols
     else 0);
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  if Render_schedule.Viewport.requires_compact_frame ~rows
  then
    let frame, clamped = render_terminal_too_small ~rows ~cols in
    (frame, clamped, None)
  else if state.palette_open then
    let frame, clamped = render_palette state in
    (frame, clamped, None)
  else if state.context_inspector_open then
    let frame, clamped = render_context_inspector state in
    (frame, clamped, None)
  else if state.help_open then
    let frame, clamped = render_help state in
    (frame, clamped, None)
  else if state.agenda_open then
    let frame, clamped = render_agenda state in
    (frame, clamped, None)
  else if state.answering_open then
    let frame, clamped = render_answering state in
    (frame, clamped, None)
  else if state.patch_modal_open then
    let frame, clamped = render_patch_modal state in
    (frame, clamped, None)
  else if state.link_modal_open then
    let frame, clamped = render_link_preview_modal state in
    (frame, clamped, None)
  else
    let frame, clamped = render_surface state in
    let presented_approval =
      match state.view with
      | Approvals ->
          List.nth_opt (approval_items state) state.approval_cursor
      | Overview | Acting | Metrics | Keepers _ | Memory | Lanes | Clients | Board
      | Planning
      | Schedules | Verification | Harness | Fusion | Repositories | Changes
      | Connectors | Runtime | Config | Resources | Code | Tools
      | System_logs -> None
    in
    (frame, clamped, presented_approval)

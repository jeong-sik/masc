(** Board list, composer and post reading. The screen dispatcher calls these
    entry points; the read cache and Board row layout live with this surface. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Frame_presenter = Masc_tui_frame_presenter
module Board_read_layout = Masc_tui_board_read_layout
module Board_detail = Masc_tui_board_detail
module Magnitude = Masc_tui_magnitude
module Board_comment_thread = Masc_tui_board_comment_thread
module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Render_schedule = Masc_tui_render_schedule
module Layout = Masc_tui_layout
module Link = Masc_tui_link
module Board_composer = Masc_tui_board_composer

(* Board accepts ordinary Markdown, so JSON detection is deliberately the
   narrow whole-document case. Objects and arrays are operational payloads;
   a post containing a scalar or a JSON-shaped fragment remains exactly the
   Markdown its author wrote. *)
let board_document_source body =
  let rec starts_with_json i =
    if i >= String.length body then false
    else
      match body.[i] with
      | ' ' | '\t' | '\n' | '\r' | '\012' -> starts_with_json (i + 1)
      | '{' | '[' | '/' -> true
      | _ -> false
  in
  if not (starts_with_json 0) then body
  else
    let trimmed = String.trim body in
    match Yojson.Safe.from_string trimmed with
    | (`Assoc _ | `List _) as json ->
        Yojson.Safe.pretty_to_string json
        |> fenced_document_text ~language:"json"
    | _ -> body
    | exception Yojson.Json_error _ -> body

let board_document_markdown ~width body =
  document_markdown ~width (board_document_source body)

(* Who wrote it, in one column. 1561 of this workspace's 2171 posts are system
   posts and 588 are automation; the 22 a person wrote are what an operator is
   scanning for, so those are the ones that get a mark. *)
(* The widths now live beside their column names in [Render_schedule], which
   is the one place the header and the rows both read. The age column is sized
   for the widest [span_text] draws, "99d23h": a board's oldest live threads are
   days old, so the day tier is the one it holds. *)

(* Four cells of lead sit ahead of the mark on the header and on every row, so
   the table gets what the frame leaves less those four. Summing the widths and
   their gaps by hand is what the column description replaced: the sum was
   written once for the rows and once for the header, and the two drifted until
   REPLIES sat past the right edge whatever the title was sized to. *)
let board_table_lead = 4

let board_layout ~cols =
  Render_schedule.board_layout
    ~inner_width:(max 0 (framed_inner_width cols - board_table_lead))

(* Colour here, the glyph in {!Masc_tui_board_kind_mark}, which the help sheet
   reads from the same function. Nothing explained these marks anywhere before:
   a reader met "@" in the first column and had to guess. *)
let board_kind_mark kind =
  let mark = Masc_tui_board_kind_mark.glyph kind in
  match kind with
  | Some Post_by_person -> Ansi.bold ^ (Theme.info ()) ^ mark ^ Ansi.reset
  | Some Post_by_automation -> (Theme.warn ()) ^ mark ^ Ansi.reset
  | Some (Post_kind_unknown _) -> (Theme.warn ()) ^ mark ^ Ansi.reset
  | Some Post_by_system | None -> mark

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
  (* What the draft is and where it goes. The keys are the footer's: this
     row carried "Enter: newline  Ctrl-E: $EDITOR" over a footer spelling
     Ctrl-E its own way and not naming Enter at all. *)
  let kind_line =
    match state.board_compose_reply_to with
    | Some post_id ->
        Printf.sprintf "  comment on %s"
          (Terminal_text.single_line post_id)
    | None ->
        let hearth_label =
          match state.board_compose_hearth with
          | Some h -> "#" ^ h
          | None -> "(default)"
        in
        Printf.sprintf "  first line: title  rest: body  hearth: %s" hearth_label
  in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s(%s, %s)%s"
    (screen_title " MASC Board")
    (Masc_tui_theme.tone Masc_tui_theme.Accent)
    (match state.board_compose_reply_to with
     | Some _ -> "reply" | None -> "new post")
    Ansi.reset
    (connection_badge state)
    Ansi.dim (Masc_tui_message_layout.count_noun line_count "line") (Masc_tui_message_layout.count_noun draft_chars "char") Ansi.reset
  in
  let addressing_kind = Board_composer.analyze_addressing draft_content in
  let addressing_line = Board_composer.format_addressing_hint ~max_cells:(framed_inner_width cols) addressing_kind in
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
  for _ = List.length visible_lines to content_height - 1 do
    box_line buf cols ""
  done;
  box_bottom buf cols;
  let prompt =
    if state.board_compose_armed then
      Masc_tui_keys.footer_hints_board_compose_armed
        ~reply:(Option.is_some state.board_compose_reply_to)
    else
      (* Projected from the key table; the table says why there is no [q]. *)
      Masc_tui_keys.footer_hints_board_compose_writing
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
  finish_frame_beside_acting_pane state ~surface_key:"board-compose" ~cursor
    ~rows ~cols buf


(* A tail this heading can do without. The two rows above the board each end
   in something atomic -- a key hint, the clause that finishes a sentence --
   and a cut one says nothing a reader can act on: "H:choo" names no key, and
   "f narrows once" stops before the condition. So the tail is drawn whole or
   not at all, the way the footer drops a hint rather than cutting it. What
   the row drops is under [?], which the footer already points at. *)
let board_heading_with_tail ~cols head tail =
  if Message_layout.display_width head + Message_layout.display_width tail
     <= framed_inner_width cols
  then head ^ tail
  else head

(* Every hearth on the board and how many posts it holds, with the one being
   read marked. [f] walked this list and drew none of it, so narrowing was a
   press into the dark: a reader could not see which hearths existed, which
   held most of the board, or where in the cycle they had got to.

   Counts come from the board's own census rather than the page on screen.
   The page is one listing of fifty and the hearth it belongs to may hold
   hundreds; a count taken from it would understate every hearth and
   understate the crowded ones most. *)
(* Between two hearths on the census row. Its width is what the row budgets
   with, so the two cannot drift apart. *)
let census_separator = "  \xc2\xb7  "

(* What the board holds behind this page: the census over the whole board, or
   over the hearth being read when one is narrowed, since the listing itself
   is narrowed server-side. A hearth the census has not counted leaves the
   page to speak for itself.

   The list's title and the reader's index both state it, so it is read once
   here rather than derived twice. *)
let board_holding (state : state) =
  match state.board_hearth with
  | Some hearth -> List.assoc_opt hearth state.board_hearths
  | None -> (
      match state.board_hearths with
      | [] -> None
      | census ->
          Some (List.fold_left (fun sum (_, count) -> sum + count) 0 census))

let board_hearth_census_line ~cols (state : state) =
  match state.board_hearths with
  | [] ->
      Ansi.dim
      (* The row above this one always names H, so the empty census says
         only what is its own to say: that nothing is counted yet, and
         that f walks hearths once something is. It used to open with
         "H:choose hearth" too, which put that key on two adjacent rows
         whenever the board had no counted hearth. *)
      ^ board_heading_with_tail ~cols "  f/F:next/previous · none counted yet"
          " \xe2\x80\x94 f narrows once they are"
      ^ Ansi.reset
  | census ->
      let total = List.fold_left (fun sum (_, count) -> sum + count) 0 census in
      (* Banded over the whole census, then cut to what fits. Banding the
         visible slice would rank each hearth against the four that happened
         to fit beside it, which is a different question from the one the row
         asks. *)
      let banded = Magnitude.of_counts census in
      (* Each hearth's text is made printable once, here, and the budget below
         and [entry] both read that one string. Measured as it arrived, a name
         with a control byte in it counts that byte as no cells, and the row
         draws it as a four-cell escape. The name as it arrived stays beside
         the text for the selection check, since [board_hearth] holds it in
         that form. *)
      let hearths =
        List.map
          (fun (name, count, band) ->
             ( name
             , Printf.sprintf "%s %d" (Terminal_text.single_line name) count
             , band ))
          banded
      in
      let entry (name, text, band) =
        let selected = Option.equal String.equal state.board_hearth (Some name) in
        (* Selection wins over size: which hearth is being read is a different
           axis from how big it is, and the reverse block says the first
           without leaving the second unsaid -- the count is in the text. *)
        if selected then Ansi.reverse ^ text ^ Ansi.reset
        else magnitude_tone band ^ text ^ Ansi.reset
      in
      (* What fits, then how many it could not carry. The board here holds
         eleven hearths and a narrow pane holds four of them; a row sized by
         how many exist is a row that runs off the edge on the next one.

         Every piece is measured where it is drawn. The budget used to count
         three cells for the separator this row draws five wide, and to leave
         a fixed 26 for a lead and a tail it never measured: live, eight
         hearths ran past the frame and "198 posts" -- the reading the row
         ends on -- was cut to "19". *)
      let cells = Message_layout.display_width in
      let label = "hearths" in
      let lead = "  " ^ label ^ " " in
      let tail =
        Printf.sprintf "   %s" (Masc_tui_message_layout.count_noun total "post")
      in
      let dropped_note count = Printf.sprintf "%s+%d" census_separator count in
      let room = framed_inner_width cols - cells lead - cells tail in
      (* The hearths that fit in [budget] cells, in census order, and how many
         are left over. *)
      let take budget =
        let rec go kept used = function
          | [] -> (List.rev kept, 0)
          | ((_, text, _) as hearth) :: rest ->
              let width =
                cells text + if kept = [] then 0 else cells census_separator
              in
              if used + width > budget then (List.rev kept, 1 + List.length rest)
              else go (hearth :: kept) (used + width) rest
        in
        go [] 0 hearths
      in
      (* The note is drawn only when a hearth is dropped, so it takes room only
         then. Setting it aside before filling would, at a width that holds
         every hearth but not the note as well, drop the last hearth and draw
         "+1" for a hearth that had room.

         So the first pass sets nothing aside. A pass that drops hearths runs
         again with room for the note that drop needs. Dropping more can add a
         digit to the count, and a pass whose note is wider than what it set
         aside runs once more with that width. Each pass sets aside more than
         the one before, and no note is wider than the one for the whole
         census, so this ends. *)
      let rec fit ~note_cells =
        match take (room - note_cells) with
        | kept, 0 -> (kept, None)
        | kept, dropped ->
            let note = dropped_note dropped in
            if cells note <= note_cells then (kept, Some note)
            else fit ~note_cells:(cells note)
      in
      let kept, note = fit ~note_cells:0 in
      let shown =
        List.map entry kept
        |> String.concat (Ansi.dim ^ census_separator ^ Ansi.reset)
      in
      Printf.sprintf "  %s%s%s %s%s%s" Ansi.dim label Ansi.reset shown
        (match note with
         | None -> ""
         | Some note -> Printf.sprintf "%s%s%s" Ansi.dim note Ansi.reset)
        (Printf.sprintf "%s%s%s" Ansi.dim tail Ansi.reset)

let render_board_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length state.board_posts in
  (* Read once for the whole list: the header word and every row's number name
     the same time, and they would drift the moment two readings of the sort
     disagreed. *)
  let age_time = board_sort_time state.board_sort in
  let age_header = board_age_header age_time in
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
  let board_list_error =
    Terminal_text.optional_single_line state.board_list_error
  in
  (* No sort here. The row under this one says it in the words that answer
     what the order is -- "latest changed first" rather than "updated" -- and
     it is the row with space for them. "updated" is the token the board list
     is asked for (the request's sort_by) and the token the workspace config
     keeps, so a title that spelled it showed the operator a protocol value.

     A count only once a list has answered. Before that, or after a first
     read that failed, "(0)" read as a board with nothing on it. A count
     already on screen stays when a later refresh fails: those posts are
     still the last reading. *)
  let holding = board_holding state in
  let header = Printf.sprintf "%s %s%s  %s  %s"
    (screen_title " MASC Board")
    (match state.board_posts, board_list_page state ~error:board_list_error with
     | _ :: _, _ | [], Page_empty ->
         list_count_text ~loaded:count ~holding
     | [], (Page_unread | Page_failed) ->
         title_missing_reading ~error:board_list_error)
    hearth timestamp
    (connection_badge state) in

  let layout = board_layout ~cols in
  (* The frame, its fill and the footer are the contract's: this surface
     counted them by hand and counted two rows it no longer draws, so the
     footer stood two rows above the composer. *)
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"board-list"
    ~title:header ~hints:(Masc_tui_keys.footer_hints ~detail_open:false state.view)
    ~body:(fun ~budget c ->
      (* The header is laid out by the same arithmetic as the rows below it,
         because a header laid out by its own is a header that stops
         describing them. It did: the rows size their title to [cols - 68]
         and the header claimed a fixed 20, so at eighty columns the header
         ran eight cells long. The overflow pushed SCORE into the frame's edge
         and REPLIES off it -- two columns still drawn on every row, with
         nothing left saying what they were. The mark ahead of the id is one
         cell and the header reserved two, which put every label one cell
         right of its data.

         The column description in [Render_schedule] is the one place either
         of them asks.

         Each entry draws one row, so the list's height is asked of the rows
         above it rather than kept beside them as a number. *)
      let heading =
        [ (fun () ->
            (* The sort first. It has no other home on this surface now, and
               this row is cut to the frame's inner width: at 34 columns the
               key hint alone spent all 30 cells, so the order the rows are in
               was invisible while the key to change it was not. H is in the
               sheet under [?]. *)
            c.push_styled ~style:(Theme.recede ())
              (board_heading_with_tail ~cols
                 (Printf.sprintf "  Sort [s]: %s"
                    (board_sort_explanation state.board_sort))
                 " · H:choose hearth"))
        ; (fun () -> c.push (board_hearth_census_line ~cols state))
        ; c.push_divider
        ; (fun () ->
            c.push_styled ~style:(Theme.recede ())
              (String.make board_table_lead ' '
               ^ Render_schedule.board_header_row ~age_header ~layout))
        ; c.push_divider
        ]
      in
      List.iter (fun draw -> draw ()) heading;
      let render_list_error err = c.push (data_unreliable_row ~cols err) in
      if count = 0 then
        (match board_list_page state ~error:board_list_error with
         | Page_failed -> Option.iter render_list_error board_list_error
         | Page_unread -> c.push (Ansi.dim ^ page_unread_note ^ Ansi.reset)
         | Page_empty ->
             c.push (Ansi.dim ^ "  (no board posts)" ^ Ansi.reset))
      else begin
        Option.iter render_list_error board_list_error;
        let error_rows = if Option.is_some board_list_error then 1 else 0 in
        let content_height =
          max 0 (budget - List.length heading - error_rows)
        in
        let scroll_offset =
          if state.board_cursor >= content_height then
            state.board_cursor - content_height + 1
          else 0
        in
        (* One clock read for the whole page, so two rows drawn in the same
           frame cannot report ages a tick apart. *)
        let now_unix = Unix.gettimeofday () in
        let board_posts_window =
          Rows.of_list ~first:scroll_offset ~height:content_height
            state.board_posts
        in
        for i = 0 to content_height - 1 do
          let idx = i + scroll_offset in
          match Rows.at board_posts_window idx with
          | None -> ()
          | Some p ->
            let is_selected = idx = state.board_cursor in
            (* The age is since the post or one of its comments last moved.
               A board's list had no timestamp at all, so "what is still
               alive" -- the question the [recent] and [updated] sort orders
               answer -- could only be read off the order the rows happened
               to arrive in. Spelled with the same ladder the Approvals queue
               uses, so a span reads the same on both. *)
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
              if p.bp_comment_count > 0 then
                Printf.sprintf "%d" p.bp_comment_count
              else "0"
            in
            (* task-1758/#39356: the list row has no spare column for
               closed state, so it goes into the title text itself, the
               same way a closed dashboard row puts its badge next to the
               title rather than in a new column. *)
            let title_text =
              match p.bp_closed with
              | Some _ -> "\xf0\x9f\x94\x92 " ^ Terminal_text.single_line p.bp_title
              | None -> Terminal_text.single_line p.bp_title
            in
            let values =
              { Render_schedule.brow_mark = board_kind_mark p.bp_kind
              ; brow_id = Terminal_text.single_line p.bp_id
              ; brow_hearth = hearth_text
              ; brow_author = Terminal_text.single_line p.bp_author
              ; brow_title = title_text
              ; brow_age =
                  (* The time the sort ordered by, not always the last move:
                     four of the five orders rank or break ties on the moment
                     the post appeared, and under those a column of last-move
                     spans did not climb with the rows. A post replied to a
                     minute ago sat sixth under "newest post first" reading
                     "25s". *)
                  Render_schedule.board_age_text ~now:now_unix
                    (board_age_source ~time:age_time
                       ~posted:p.bp_created_at_unix ~changed:p.bp_updated_at)
              ; brow_score = score_text
              ; brow_replies = replies_text
              }
            in
            let styles =
              { Render_schedule.bstyle_id = Theme.recede ()
              ; bstyle_hearth =
                  if String.equal hearth_text "" then Ansi.dim
                  else Theme.info ()
              ; bstyle_author = Theme.ok ()
              ; bstyle_age = Ansi.dim
              ; bstyle_score = board_score_style p.bp_votes
              ; bstyle_replies =
                  if p.bp_comment_count > 0 then Theme.ok () else Ansi.dim
              }
            in
            let content =
              String.make board_table_lead ' '
              ^ Render_schedule.board_row ~styles ~age_header ~layout
                  values
            in
            if is_selected then
              c.push_selected (Masc_tui_theme.strip_sgr content)
            else c.push content
        done
      end)

(* Owned by the single render loop, like the chat Markdown cache. Only the
   currently read document is retained; input and live status are never cached. *)
let board_read_layout = Board_read_layout.create ()
;;

(* The thread beside the post, one screen row at a time (p-7784d032). Owns
   its own allocation and scroll projection so [board_read_pane] only ever
   touches the shared [board_read_allocation] the stacked layout uses -- the
   shape test_tui_http_ast.ml's AST contract checks for: each layout
   consumes its own row budget through the calls that produced it, not by
   re-reading the record across two branches inside one binding. *)
let draw_board_read_side buf (state : state) document ~rows ~body_cols
    ~comment_cols ~total_lines ~detail_line_count ~detail_comment_count =
  let side_budget =
    Layout.allocate_board_read_side ~terminal_rows:rows
      ~body_line_count:total_lines ~comment_line_count:detail_line_count
  in
  (* The heading spends the comment column's first row; only what is
     left under it can hold thread lines. *)
  let comment_header_rows = if side_budget.comment_rows > 0 then 1 else 0 in
  let comment_content_rows =
    max 0 (side_budget.comment_rows - comment_header_rows)
  in
  let scroll =
    Layout.project_board_read_scroll
      ~body_line_count:total_lines
      ~body_rows:side_budget.body_rows
      ~comment_line_count:detail_line_count
      ~comment_rows:comment_content_rows
      ~body_scroll:state.board_scroll
      ~comment_scroll:(match state.board_comment_landing with
        | None -> state.board_comment_scroll
        | Some comment_id ->
            (match Board_read_layout.initial_comment_offset document ~comment_id with
             | Some offset -> offset
             | None -> state.board_comment_scroll))
  in
  (* box_top/box_bottom draw no border in the borderless geometry this
     pane already uses (see their definitions) -- they would only add
     two blank rows the row budget above never reserved. The two
     columns are plain content, exactly [rows_drawn] lines each, so
     [write_two_panes] zips them without falling back to its blank-pad
     case. *)
  let rows_drawn = max side_budget.body_rows side_budget.comment_rows in
  let body_buf = Buffer.create (4 * 1024) in
  let comment_buf = Buffer.create (4 * 1024) in
  for i = 0 to rows_drawn - 1 do
    if i < side_budget.body_rows then
      let idx = i + scroll.body_offset in
      if idx < total_lines then
        box_line body_buf body_cols
          ("  " ^ Board_read_layout.body_line document idx)
      else box_empty body_buf body_cols
    else box_empty body_buf body_cols
  done;
  for i = 0 to rows_drawn - 1 do
    if i = 0 && comment_header_rows > 0 then
      box_line comment_buf comment_cols
        (Ansi.bold
        ^ Printf.sprintf "%sComments (%d)"
            (if state.board_focus = Right_pane && state.board_comments_focused
             then "> " else "  ")
            detail_comment_count
        ^ Ansi.reset)
    else if i < side_budget.comment_rows then
      let idx = i - comment_header_rows + scroll.comment_offset in
      if idx >= 0 && idx < detail_line_count then
        box_line comment_buf comment_cols
          (Board_read_layout.comment_line document idx)
      else box_empty comment_buf comment_cols
    else box_empty comment_buf comment_cols
  done;
  write_two_panes buf ~left_cols:body_cols ~left:body_buf ~right:comment_buf;
  (scroll, side_budget.body_rows, comment_content_rows)
;;

(** Render the Board surface (read view). *)
(* The read post alone -- borders, header, body, comments -- at [cols]
   wide, footer excluded, so a caller can lay it beside the post list.
   Returns the scroll the frame used. *)
let board_read_pane (state : state) (list_post : board_post) ~rows ~cols buf =
  let prep_started = Masc_tui_frame_timing.start_stage () in
  let detail =
    Board_detail.view_for state.board_detail ~post_id:list_post.bp_id
  in
  let post =
    match detail with
    | Board_detail.Ready (detail_post, _, _) -> detail_post
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        list_post
  in

  let header =
    board_read_title ~screen:(screen_title " MASC Board")
      ~id:(Terminal_text.single_line post.bp_id)
      ~hearth:(Terminal_text.optional_single_line post.bp_hearth)
      ~votes:post.bp_votes ~replies:post.bp_comment_count
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let title_line = Printf.sprintf "%s%s%s%s"
    (if state.board_focus = Right_pane && not state.board_comments_focused
     then "> " else "  ")
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
       (Terminal_text.short_timestamp post.bp_created_at)
       Ansi.dim Ansi.reset
       Ansi.dim
       (Link.reference Board_post (Terminal_text.single_line post.bp_id))
       Ansi.reset);
  (* task-1758/#39356: a closed post's detail shows who closed it and,
     when named, the successor to keep reading in and the summary the
     closer left -- the same information the dashboard's detail badge
     carries, drawn as its own line rather than a badge this renderer has
     no widget for. *)
  (match post.bp_closed with
   | None -> ()
   | Some c ->
     let successor_text =
       match c.bpc_successor_id with
       | Some sid -> Printf.sprintf ", successor: %s" sid
       | None -> ""
     in
     box_line buf cols
       (Printf.sprintf "  %sclosed by %s%s%s"
          (Theme.warn ())
          (Terminal_text.single_line c.bpc_closed_by)
          successor_text
          Ansi.reset);
     (match c.bpc_summary with
      | Some summary ->
        box_line buf cols
          (Printf.sprintf "  %ssummary: %s%s" Ansi.dim
             (Terminal_text.single_line summary) Ansi.reset)
      | None -> ()));
  box_divider buf cols;

  (* The thread sits beside the post, not under it, when the pane is wide
     enough for both columns to stay readable (p-7784d032). A narrow pane
     keeps the stacked layout below -- the same rows, drawn the way they were
     before the side arrangement existed. Decided here, before the document
     below wraps a single word of it, so the body and comment text get
     wrapped to the column that will actually draw them -- not the full pane
     width every layout used to assume, which is what let a wide-formatted
     comment line get clipped down to its author chip in the narrow column
     (p-7784d032 follow-up). *)
  let has_detail_content =
    match detail with
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        false
    | Board_detail.Ready (_, comments, _) -> comments <> []
  in
  let side_layout =
    if has_detail_content then Layout.board_read_side_layout ~cols
    else None
  in
  let body_wrap_cols =
    match side_layout with Some (body_cols, _) -> body_cols | None -> cols
  in
  let comment_wrap_cols =
    match side_layout with
    | Some (_, comment_cols) -> comment_cols
    | None -> cols
  in

  let source : Board_read_layout.source =
    { post; detail; related_posts = state.board_posts;
      keeper_names = List.map (fun (k : Tui_decode.keeper) -> k.k_name) state.keepers;
      columns = cols;
      styles = [ Theme.info (); Theme.warn (); Theme.bad (); Theme.recede ();
                 Masc_tui_theme.tone Masc_tui_theme.Accent ];
      table_frame = !table_frame_enabled }
  in
  Masc_tui_frame_timing.finish_stage ~name:"board.pane_prep" prep_started;
  let document =
    Board_read_layout.get board_read_layout ~source ~render:(fun () ->
      (* Body lines *)
      let text_width = body_wrap_cols - 8 in
      (* Sanitised a line at a time. A newline is a control byte, so sanitising the
         body whole escaped every break and the post arrived as one unbroken run
         with "\x0A" printed through it. *)
      (* Board posts are written in markdown -- headings, fences, rules -- and were
         drawn as the source they were typed as. The chat pane has rendered them
         for a while; this surface reads the same kind of document. *)
      let body_lines =
        Masc_tui_frame_timing.time_stage ~name:"board.post.wrap"
          (fun () ->
            Message_layout.wrap_body
              ~markdown:board_document_markdown
              ~max_cells:text_width
              ~sanitize:Terminal_text.single_line
              post.bp_body)
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
                   (fit_width (Terminal_text.single_line id)
                      (max 8 (body_wrap_cols - 16)))
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
                        (max 8 (body_wrap_cols - 26)))
                     Ansi.reset))
      in
      let body_lines = body_lines @ reference_lines @ related_lines in
      let initial_comment_offset = ref None in
      let detail_lines =
        match detail with
        | Board_detail.Absent ->
            [Ansi.dim ^ "  Board detail unavailable" ^ Ansi.reset]
        | Board_detail.Loading ->
            [Ansi.dim ^ "  Loading Board detail..." ^ Ansi.reset]
        | Board_detail.Failed error ->
            [ (Theme.bad ()) ^ "  "
              ^ fit_width (Terminal_text.single_line error)
                  (max 1 (framed_inner_width comment_wrap_cols - 2))
              ^ Ansi.reset
            ]
        | Board_detail.Ready (_, comments, landing) ->
            (* A reply and the thing it answers used to sit at one indent in clock
               order, so a thread read as unrelated remarks. [parent_id] has been
               on the wire since comments existed -- 152 of this workspace's 1364
               comments carry one -- and the pane simply never decoded it. *)
            let ordered =
              Masc_tui_frame_timing.time_stage ~name:"board.thread.order"
                (fun () -> Board_comment_thread.order comments)
            in
            let comment_lines =
              Masc_tui_frame_timing.time_stage ~name:"board.thread.rows_wrap"
                (fun () ->
                  let row_offset = ref 0 in
                  ordered
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
                 let created_at = Terminal_text.short_timestamp c.bc_created_at in
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
                 (* Wrap for the rows that will draw the body. Only a whole
                    single-line reply that fits beside the metadata joins it;
                    paragraphs below the heading use the entire comment pane. *)
                 let inner_width = framed_inner_width comment_wrap_cols in
                 let heading_width = Message_layout.display_width heading in
                 let joined_budget = inner_width - heading_width - 2 in
                 let content_prefix = "  " ^ rail ^ "  " in
                 let content_width =
                   max 1
                     (inner_width - Message_layout.display_width content_prefix)
                 in
                 let lines =
                   Message_layout.wrap_body
                     ~markdown:board_document_markdown
                     ~max_cells:content_width
                     ~sanitize:Terminal_text.single_line c.bc_content
                 in
                 let rendered = match lines with
                 | [ line ] when Message_layout.display_width line <= joined_budget ->
                     [ heading ^ "  " ^ line ]
                 | lines ->
                     let metadata =
                       if heading_width <= inner_width then [ heading ]
                       else
                         let identity =
                           Printf.sprintf "  %s%s@%s%s%s" rail
                             (Masc_tui_theme.tone Masc_tui_theme.Accent)
                             author Ansi.reset author_role
                         in
                         let timestamp =
                           Printf.sprintf "  %s%s%s%s" rail Ansi.dim created_at
                             Ansi.reset
                         in
                         [ identity; timestamp ]
                     in
                     metadata
                     @ List.map (fun line -> content_prefix ^ line) lines in
                 if landing = Some c.bc_id then
                   initial_comment_offset := Some (c.bc_id, !row_offset);
                 row_offset := !row_offset + List.length rendered;
                 rendered))
            in
            if List.length comments < post.bp_comment_count then begin
              initial_comment_offset := Option.map (fun (id, row) -> id, row + 1) !initial_comment_offset;
              Printf.sprintf "  Showing %d of %d comments (o: all comments)"
                (List.length comments) post.bp_comment_count
              :: comment_lines
            end else
              (* The post header already counts the complete thread. Keep
                 the small comment viewport for its actual comment rows. *)
              comment_lines
      in
      (body_lines, detail_lines, !initial_comment_offset))
  in
  let rows_started = Masc_tui_frame_timing.start_stage () in
  let total_lines = Board_read_layout.body_line_count document in
  let detail_line_count = Board_read_layout.comment_line_count document in
  let detail_comment_count =
    match detail with
    | Board_detail.Ready (_, comments, _) -> List.length comments
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ -> 0
  in
  (* [board_read_allocation] and [board_read_side_allocation] share field
     names but are different record types, so this match cannot return one
     of them -- only the scroll and the two drawn-row counts survive it. *)
  let scroll, body_lines_drawn, comment_lines_drawn =
    match side_layout with
    | Some (body_cols, comment_cols) ->
        draw_board_read_side buf state document ~rows ~body_cols
          ~comment_cols ~total_lines ~detail_line_count ~detail_comment_count
    | None ->
        let row_budget =
          Layout.allocate_board_read ~terminal_rows:rows
            ~body_line_count:total_lines ~comment_line_count:detail_line_count
        in
        let content_height = row_budget.body_rows in
        let comment_height = row_budget.comment_rows in
        let scroll =
          Layout.project_board_read_scroll
            ~body_line_count:total_lines ~body_rows:content_height
            ~comment_line_count:detail_line_count ~comment_rows:comment_height
            ~body_scroll:state.board_scroll
            ~comment_scroll:(match state.board_comment_landing with
              | None -> state.board_comment_scroll
              | Some comment_id ->
                  (match Board_read_layout.initial_comment_offset document ~comment_id with
                   | Some offset -> offset
                   | None -> state.board_comment_scroll))
        in
        for i = 0 to content_height - 1 do
          let idx = i + scroll.body_offset in
          if idx < total_lines then
            box_line buf cols ("  " ^ Board_read_layout.body_line document idx)
          else box_empty buf cols
        done;
        if comment_height > 0 then begin
          box_divider buf cols;
          box_line buf cols
            (Ansi.bold
             ^ (if state.board_focus = Right_pane
                   && state.board_comments_focused
                then "> Comments" else "  Comments")
             ^ Ansi.reset);
          for i = 0 to comment_height - 1 do
            box_line buf cols
              (Board_read_layout.comment_line document (i + scroll.comment_offset))
          done
        end;
        (scroll, content_height, comment_height)
  in
  (* Reading without a position is guessing: the post body and the comment
     thread each name where they stand, in the window the other reading
     surfaces draw.

     Both halves count wrapped rows, and the row says so. The comment half
     read "comments 1-10/6085" beside a header drawing the thread's own
     "157", because a comment becomes an identity row, a timestamp row and
     one row per wrapped line. Two numbers under one word on one screen, and
     the larger one is the one a reader has no way to place. *)
  if
    total_lines > body_lines_drawn || detail_line_count > comment_lines_drawn
  then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "%s%s"
         (Masc_tui_scroll.window_reading ~noun:"post rows"
            ~scroll:scroll.body_offset ~height:body_lines_drawn total_lines)
         (if detail_line_count > comment_lines_drawn then
            "  \xc2\xb7  "
            ^ Masc_tui_scroll.window_reading ~noun:"comment rows"
                ~scroll:scroll.comment_offset ~height:comment_lines_drawn
                detail_line_count
          else ""));
  box_bottom buf cols;
  Masc_tui_frame_timing.finish_stage ~name:"board.frame_rows" rows_started;
  scroll.body_offset, scroll.comment_offset

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
    ~holding:(board_holding state)
    ~labels:(List.map format_sidebar_post state.board_posts)
    ~selected

let render_board_read (state : state) (list_post : board_post) =
  let prep_started = Masc_tui_frame_timing.start_stage () in
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let layout =
    Masc_tui_types.board_read_layout ~cols ~wide:state.board_detail_wide
  in
  let buf = Buffer.create 4096 in
  let footer =
    footer_line state ~max_cells:cols
      ~hints:
        (Masc_tui_keys.footer_hints_board_read
           ~focus_posts:(state.board_focus = Left_pane)
           ~focus_comments:state.board_comments_focused
           ~full_history:(state.board_history_post_id = Some list_post.bp_id)
           ~layout)
  in
  Masc_tui_frame_timing.finish_stage ~name:"board.render_prep" prep_started;
  match layout with
  | Board_read_wide | Board_read_one_pane ->
    let scroll = board_read_pane state list_post ~rows ~cols buf in
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  | Board_read_split ->
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

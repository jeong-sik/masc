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
module Board_attachments = Masc_tui_board_attachments

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

(* The header and every row start with the kind mark at the frame's content
   column, so the table gets the frame's whole inner width. Summing the widths
   and their gaps by hand is what the column description replaced: the sum was
   written once for the rows and once for the header, and the two drifted until
   REPLIES sat past the right edge whatever the title was sized to. *)
let board_layout ~cols =
  Render_schedule.board_layout ~inner_width:(framed_inner_width cols)

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
        Printf.sprintf "comment on %s"
          (Terminal_text.single_line post_id)
    | None ->
        let hearth_label =
          match state.board_compose_hearth with
          | Some h -> "#" ^ h
          | None -> "(default)"
        in
        Printf.sprintf "first line: title  rest: body  hearth: %s" hearth_label
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
  (* Staged files ride the post being written; a comment has no attachment
     wire, so like the hearth they are not named on a reply's pane. *)
  let attachments_line =
    match state.board_compose_reply_to, state.board_compose_attachments with
    | None, _ :: _ ->
        Some
          (Printf.sprintf "attachments: %s"
             (String.concat " \xc2\xb7 "
                (List.map
                   (fun (staged : board_staged_attachment) ->
                      board_upload_kind_to_wire staged.sa_kind
                      ^ " " ^ Terminal_text.single_line staged.sa_name)
                   state.board_compose_attachments)))
    | None, [] | Some _, _ -> None
  in
  (* The path being typed after Ctrl-A, on a row of its own. The footer drops
     a hint that does not fit, and a path is longer than any hint: riding
     there, it vanished while it was being typed. A path too long for the row
     keeps both ends -- the start says which tree, the end is the file name
     and the part being typed. *)
  let attach_input_line =
    match state.board_compose_attach_input with
    | Some input ->
        let label = "attach file: " in
        let room =
          max 1
            (Board_composer.draft_cells ~cols - Message_layout.display_width label)
        in
        let path = Terminal_text.single_line (Buffer.contents input) in
        let shown = Message_layout.truncate_middle room path in
        Some (label ^ shown ^ Ansi.reverse ^ " " ^ Ansi.reset)
    | None -> None
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line buf cols (Ansi.dim ^ kind_line ^ Ansi.reset);
  box_line buf cols addressing_line;
  (match attachments_line with
   | Some line -> box_line buf cols (Ansi.dim ^ line ^ Ansi.reset)
   | None -> ());
  (match attach_input_line with
   | Some line -> box_line buf cols line
   | None -> ());
  (match state.board_post_error with
   | Some err ->
       box_line buf cols
         ((Theme.bad ())
         ^ fit_width (Terminal_text.single_line err) (framed_inner_width cols)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;
  let text_width = Board_composer.draft_cells ~cols in
  let draft_lines =
    raw_lines
    |> List.concat_map (fun line ->
           let w = Message_layout.wrap_words ~max_cells:text_width
             (Terminal_text.single_line line) in
           if w = [] then [ "" ] else w)
  in
  let error_rows = if Option.is_some state.board_post_error then 1 else 0 in
  let attachment_rows = if Option.is_some attachments_line then 1 else 0 in
  let attach_input_rows = if Option.is_some attach_input_line then 1 else 0 in
  let chrome_top_rows = 5 + error_rows + attachment_rows + attach_input_rows in
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
    (fun line -> box_line buf cols (fit_width line text_width))
    visible_lines;
  for _ = List.length visible_lines to content_height - 1 do
    box_line buf cols ""
  done;
  box_bottom buf cols;
  let prompt =
    match state.board_compose_attach_input with
    | Some _ ->
        (* The path input owns the keys, so the footer names its two; the
           path itself is on the pane above. *)
        Masc_tui_keys.footer_hints_board_attach_input
    | None ->
        if state.board_compose_armed then
          Masc_tui_keys.footer_hints_board_compose_armed
            ~reply:(Option.is_some state.board_compose_reply_to)
        else
          (* Projected from the key table; the table says why there is no [q]. *)
          Masc_tui_keys.footer_hints_board_compose_writing
            ~reply:(Option.is_some state.board_compose_reply_to)
  in
  let cursor =
    if state.board_compose_armed || Option.is_some state.board_compose_attach_input then
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
    ~rows ~cols ~footer:(Footer_hints { hints = prompt; position = None }) buf

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

(* Retained values stay readable here, with their availability. The title and
   reader index only borrow totals from a received, non-pending census. *)
let board_hearth_census_line ~cols (state : state) =
  let observation,pending=board_census_reading state in
  let status=match observation with
    | Masc_tui_fetched.Absent -> Some (if pending then "reading census" else "census not read")
    | Loading -> Some "reading census"
    | Ready _ -> if pending then Some "refreshing; last observed" else None
    | Stale (_,detail) -> Some ((if pending then "refreshing; " else "")
        ^ "last observed; unavailable: " ^ Terminal_text.single_line detail)
    | Failed detail -> Some ((if pending then "retrying; " else "")
        ^ "unavailable: " ^ Terminal_text.single_line detail) in
  let tone=match observation with
    | Masc_tui_fetched.Stale _ | Failed _ -> Theme.bad ()
    | Absent | Loading | Ready _ -> Ansi.dim in
  let notice text = tone
    ^ Message_layout.truncate_middle (framed_inner_width cols) ("hearths · " ^ text) ^ Ansi.reset in
  match Masc_tui_fetched.value observation with
  | None -> notice (match status with Some text -> text | None -> "census not observed")
  | Some [] -> notice (match status with Some text -> "last census empty; " ^ text | None -> "census empty")
  | Some census ->
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
      let tail =
        Printf.sprintf "   %s" (Masc_tui_message_layout.count_noun total "post")
      in
      let dropped_note count = Printf.sprintf "%s+%d" census_separator count in
      let label_gap = " " in
      let label=match status with
        | None -> "hearths"
        | Some text -> Message_layout.truncate_middle
            (max 0 (framed_inner_width cols - cells label_gap - cells tail
              - cells (dropped_note (List.length hearths)))) ("hearths · " ^ text) in
      let lead = label ^ label_gap in
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
      Printf.sprintf "%s%s%s%s%s%s%s" tone label Ansi.reset label_gap shown
        (match note with
         | None -> ""
         | Some note -> Printf.sprintf "%s%s%s" Ansi.dim note Ansi.reset)
        (Printf.sprintf "%s%s%s" Ansi.dim tail Ansi.reset)

let board_posts_status state =
  let observation,pending=board_posts_reading state in
  let status=match observation with
    | Masc_tui_fetched.Absent -> Some "posts not read"
    | Loading -> Some "reading posts"
    | Ready _ -> if pending then Some "refreshing posts; last observed" else None
    | Stale _ -> Some (if pending then "refreshing posts; last failure retained" else "last observed posts; unavailable")
    | Failed _ -> Some (if pending then "retrying posts; unavailable" else "posts unavailable") in
  match board_posts_snapshot state with
  | Some snapshot when not (board_listing_matches_requested state) ->
      let origin=Printf.sprintf "last observed: %s; requested: %s"
        (Terminal_text.single_line (board_query_label snapshot.bl_query))
        (Terminal_text.single_line (board_query_label (board_query state))) in
      Some (origin ^ (match status with None -> "" | Some status -> "; " ^ status))
  | Some _ | None -> status

let render_board_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length (board_posts state) in
  (* Read once for the whole list: the header word and every row's number name
     the same time, and they would drift the moment two readings of the sort
     disagreed. *)
  let query = board_posts_query state in
  let age_time = board_sort_time query.bq_sort in
  let age_header = board_age_header age_time in
  (* Which sub-board is being read. Said only when the list is narrowed: "all
     hearths" is what a reader assumes, and 24 of them share this board with
     1550 of 2171 posts in one, so a narrowed list that did not say so would
     look like a board that had gone quiet. *)
  let hearth =
    match query.bq_hearth with
    | None -> ""
    | Some hearth ->
        Printf.sprintf "  %shearth:%s%s" (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line hearth) Ansi.reset
  in
  let observation,pending=board_posts_reading state in
  let list_error =
    Terminal_text.optional_single_line (board_listing_error state)
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
  let holding = board_census_holding state ~hearth:query.bq_hearth in
  let header = Printf.sprintf "%s %s%s  %s  %s"
    (screen_title " MASC Board")
    (match Masc_tui_fetched.value observation with
     | Some _ ->
         list_count_text ~loaded:count ~holding
     | None -> if pending then "(reading posts)" else title_missing_reading ~error:list_error)
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
                 (Printf.sprintf "%sSort [s]: %s"
                    (match board_posts_status state with None -> "" | Some status -> status ^ " · ")
                    (board_sort_explanation query.bq_sort))
                 " · H:choose hearth"))
        ; (fun () -> c.push (board_hearth_census_line ~cols state))
        ; (fun () ->
            match List.nth_opt (board_posts state)
                (max 0 (min state.board_cursor (count - 1))) with
            | None -> c.push_empty ()
            | Some post ->
                c.push ("Selected post · " ^ Ansi.bold
                  ^ Terminal_text.single_line post.bp_title ^ Ansi.reset))
        ; c.push_divider
        ; (fun () ->
            c.push_styled ~style:(Theme.recede ())
              (Render_schedule.board_header_row ~age_header ~layout))
        ; c.push_divider
        ]
      in
      List.iter (fun draw -> draw ()) heading;
      let render_list_error err = c.push (data_unreliable_row ~cols err) in
      if count = 0 then
        (match observation with
         | Masc_tui_fetched.Failed _ | Stale _ -> Option.iter render_list_error list_error
         | Absent -> c.push (Ansi.dim ^ page_unread_note ^ Ansi.reset)
         | Loading -> c.push (Ansi.dim ^ "  (reading Board posts)" ^ Ansi.reset)
         | Ready _ -> c.push (Ansi.dim
             ^ (if pending then "  (last listing empty; reading posts)"
                else if not (board_listing_matches_requested state) then "  (last listing empty; requested query not observed)"
                else "  (no board posts)") ^ Ansi.reset))
      else begin
        Option.iter render_list_error list_error;
        let error_rows = if Option.is_some list_error then 1 else 0 in
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
            (board_posts state)
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
              Render_schedule.board_row ~styles ~age_header ~layout values
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

(* The comment v/V votes on while the comments have focus, so the one the
   gutter marks. With the post body focused the keys vote on the post, and
   no comment is marked. *)
let selected_comment (state : state) =
  if state.board_focus = Right_pane && state.board_comments_focused then
    state.board_comment_cursor
  else None

let comment_gutter = String.make Board_read_layout.comment_gutter_cells ' '

(* Same cell count as [comment_gutter]: a marker cell, then blanks. *)
let selected_comment_gutter () =
  Masc_tui_theme.tone Masc_tui_theme.Accent ^ Ansi.bold ^ ">" ^ Ansi.reset
  ^ String.make (Board_read_layout.comment_gutter_cells - 1) ' '

let comment_row_gutter (state : state) =
  let selected = selected_comment state in
  let marker = selected_comment_gutter () in
  fun comment_id ->
    match selected with
    | Some id when String.equal id comment_id -> marker
    | Some _ | None -> comment_gutter

(* Where the comment column is asked to stand this frame. A first read's
   landing comment comes first; then a cursor move's request to bring the
   selected comment on screen; otherwise the reader's own scroll, which
   PgUp/PgDn move by rows. *)
let requested_comment_scroll (state : state) document ~viewport_rows =
  match state.board_comment_landing with
  | Some comment_id -> (
      match Board_read_layout.initial_comment_offset document ~comment_id with
      | Some offset -> offset
      | None -> state.board_comment_scroll)
  | None -> (
      let followed =
        if state.board_comment_follow then selected_comment state else None
      in
      match
        Option.bind followed (fun comment_id ->
            Board_read_layout.comment_span document ~comment_id)
      with
      | None -> state.board_comment_scroll
      | Some (first_row, row_count) ->
          Masc_tui_board_comment_cursor.reveal_scroll
            ~scroll:state.board_comment_scroll ~viewport_rows ~first_row
            ~row_count)

(* The thread beside the post, one screen row at a time (p-7784d032). Owns
   its own allocation and scroll projection so [board_read_pane] only ever
   touches the shared [board_read_allocation] the stacked layout uses. *)
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
      ~comment_scroll:
        (requested_comment_scroll state document
           ~viewport_rows:comment_content_rows)
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
  let gutter = comment_row_gutter state in
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
          (Board_read_layout.comment_line document ~gutter idx)
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
    (fit_width (Terminal_text.single_line post.bp_title) (framed_inner_width cols - 2))
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
    | Some (Post_by_system | Post_kind_unknown _) | None -> Printf.sprintf "%s@%s%s"
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
    { post; detail; related_posts = (board_posts state);
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
      let text_width = framed_inner_width body_wrap_cols - 4 in
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
          (board_posts state)
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
                      (max 8 (framed_inner_width body_wrap_cols - 12)))
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
                        (max 8 (framed_inner_width body_wrap_cols - 22)))
                     Ansi.reset))
      in
      (* The post's own attachments, ahead of the derived references: what
         the author attached is content, what the body points at is relation.
         [Board_attachments.label] owns the one-line wording; this only
         fits it to the column. Each line carries the number the open key
         answers to ([Board_attachments.attachment_at_index] counts the same
         order, a broken entry included). Appended like the sections above
         so the surface's own scroll carries it. *)
      let attachment_lines =
        match post.bp_attachments with
        | [] -> []
        | attachments ->
          (Ansi.dim ^ "" ^ Ansi.reset)
          :: (Ansi.bold ^ "  ATTACHMENTS" ^ Ansi.reset)
          :: List.mapi
               (fun index (entry : board_attachment_entry) ->
                 Printf.sprintf "  [%d] %s%s%s" (index + 1) Ansi.reset
                   (fit_width
                      (Terminal_text.single_line (Board_attachments.label entry))
                      (max 8 (framed_inner_width body_wrap_cols - 8)))
                   Ansi.reset)
               attachments
      in
      let closure_lines = match post.bp_closed with
        | None -> []
        | Some closed ->
            let field label value =
              Masc_tui_text_block.rows ~max_cells:(max 1 text_width) (label ^ value)
              |> List.map (fun line -> "  " ^ line) in
            [Ansi.bold ^ "  Resolution" ^ Ansi.reset]
            @ field "Closed by " closed.bpc_closed_by
            @ (match closed.bpc_closed_at with
               | None -> []
               | Some at ->
                   (match Board_read_layout.close_time at with
                    | Ok time -> field "Closed at " time
                    | Error raw -> field "Close time unavailable · raw Unix seconds "
                        (Printf.sprintf "%.17g" raw)))
            @ (match closed.bpc_successor_id with
               | None -> []
               | Some successor ->
                   field (if String.trim successor<>"" && not (String.equal successor post.bp_id)
                          then "Successor · S:open · " else "Successor · ")
                     (Link.reference Board_post successor))
            @ (match closed.bpc_summary with
               | None -> []
               | Some summary ->
                   Message_layout.wrap_body ~markdown:board_document_markdown
                     ~max_cells:(max 1 text_width) ~sanitize:Terminal_text.single_line summary)
            @ [""] in
      let body_lines =
        closure_lines @ body_lines @ attachment_lines @ reference_lines @ related_lines
      in
      let initial_comment_offset = ref None in
      let detail_lines =
        match detail with
        | Board_detail.Absent ->
            [ Board_read_layout.Thread_note
                (Ansi.dim ^ "  Board detail unavailable" ^ Ansi.reset) ]
        | Board_detail.Loading ->
            [ Board_read_layout.Thread_note
                (Ansi.dim ^ "  Loading Board detail..." ^ Ansi.reset) ]
        | Board_detail.Failed error ->
            [ Board_read_layout.Thread_note
                ((Theme.bad ()) ^ "  "
                 ^ fit_width (Terminal_text.single_line error)
                     (max 1 (framed_inner_width comment_wrap_cols - 2))
                 ^ Ansi.reset)
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
                 let score = board_comment_score c.bc_votes in
                 (* Every row below is drawn after the comment gutter, which
                    marks the selected comment; it is not part of the text,
                    so its cells are counted here and spent at draw time. *)
                 let heading =
                   Printf.sprintf "%s%s@%s%s%s  %s%s%s  %s%s%s"
                     rail
                     (Masc_tui_theme.tone Masc_tui_theme.Accent)
                     author
                     Ansi.reset
                     author_role
                     Ansi.dim
                     created_at
                     Ansi.reset
                     (board_score_style score)
                     (board_score_text score)
                     Ansi.reset
                 in
                 (* Wrap for the rows that will draw the body. Only a whole
                    single-line reply that fits beside the metadata joins it;
                    paragraphs below the heading use the entire comment pane. *)
                 let inner_width =
                   framed_inner_width comment_wrap_cols
                   - Board_read_layout.comment_gutter_cells
                 in
                 let heading_width = Message_layout.display_width heading in
                 let joined_budget = inner_width - heading_width - 2 in
                 let content_prefix = rail ^ "  " in
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
                           Printf.sprintf "%s%s@%s%s%s  %s%s%s" rail
                             (Masc_tui_theme.tone Masc_tui_theme.Accent)
                             author Ansi.reset author_role
                             (board_score_style score)
                             (board_score_text score)
                             Ansi.reset
                         in
                         let timestamp =
                           Printf.sprintf "%s%s%s%s" rail Ansi.dim created_at
                             Ansi.reset
                         in
                         [ identity; timestamp ]
                     in
                     metadata
                     @ List.map (fun line -> content_prefix ^ line) lines in
                 if landing = Some c.bc_id then
                   initial_comment_offset := Some (c.bc_id, !row_offset);
                 row_offset := !row_offset + List.length rendered;
                 List.map
                   (fun text ->
                     Board_read_layout.Comment_text { comment_id = c.bc_id; text })
                   rendered))
            in
            if List.length comments < post.bp_comment_count then begin
              (* The retained comment identity is only a scroll anchor here;
                 rendered link ids still pass through Terminal_text above. *)
              initial_comment_offset :=
                Option.map (fun (comment_id, row) -> comment_id, row + 1)
                  !initial_comment_offset;
              Board_read_layout.Thread_note
                (Printf.sprintf "  Showing %d of %d comments (o: all comments)"
                   (List.length comments) post.bp_comment_count)
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
            ~comment_scroll:
              (requested_comment_scroll state document
                 ~viewport_rows:comment_height)
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
          let gutter = comment_row_gutter state in
          for i = 0 to comment_height - 1 do
            box_line buf cols
              (Board_read_layout.comment_line document ~gutter
                 (i + scroll.comment_offset))
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
  (* What the numbered attachment keys last did, or why one could not.
     Recede-styled like the readings above; replaced by the next action and
     cleared when another post is opened. *)
  (match state.board_attachment_status with
   | Some status ->
       let status = Terminal_text.single_line status in
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "  %s" (fit_width status (framed_inner_width cols - 2)))
   | None -> ());
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
    find 0 (board_posts state)
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
  let title=match board_posts_status state with None -> "Board" | Some status -> "Board · " ^ status in
  write_list_sidebar buf ~rows ~cols ~title
    ~focused:(state.board_focus = Left_pane)
    ~holding:(board_census_holding state ~hearth:(board_posts_query state).bq_hearth)
    ~labels:(List.map format_sidebar_post (board_posts state))
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
           ~layout
           ~has_attachments:(List.length list_post.bp_attachments > 0)
           ~has_successor:(Option.is_some (board_successor state)))
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

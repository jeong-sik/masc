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

let words state ko en = ui_text state ~ko ~en

(* The step the Board screens take from Work. *)
let board_step state = words state "게시판" "board"

let board_sort_text state sort =
  if state.ui_language <> Lang_ko then board_sort_explanation sort
  else match sort with
    | Board_hot -> "점수 높은 순 · 같으면 최신 글"
    | Board_trending -> "점수와 게시 경과 기준"
    | Board_recent -> "최신 글부터"
    | Board_updated -> "최근 바뀐 글부터"
    | Board_discussed -> "댓글 많은 순 · 같으면 최신 글"

let board_query_text state query =
  board_sort_text state query.bq_sort ^ " · "
  ^ (match query.bq_hearth with
     | None -> words state "전체 게시판" "all hearths"
     | Some hearth -> "#" ^ Terminal_text.single_line hearth)

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

(* The header and rows use one aligned column layout inside the frame. *)
let board_layout ~hide_hearth ~sort_column ~cols =
  Render_schedule.board_layout ~hide_hearth ~sort_column
    ~inner_width:(max 1 (framed_inner_width cols - 2))

(* Deterministic per-author identity colour on the Board, lifted for WCAG 4.5:1
   against the terminal's ground. People stand out in bold [info] matching the
   [@] mark; system posts recede so human and keeper voices pop; keepers and
   automations hash deterministically across four non-red palette hues so
   every author forms a scannable colour column without colliding with [bad]. *)
let board_author_style ~kind author =
  match kind with
  | Some Post_by_person -> Ansi.bold ^ Theme.info ()
  | Some Post_by_system -> Theme.recede ()
  | Some (Post_by_automation | Post_kind_unknown _) | None ->
      let len = String.length author in
      let rec hash acc i =
        if i >= len then acc
        else hash (((acc * 31) + Char.code author.[i]) land 0x3fffffff) (i + 1)
      in
      (match hash 0 0 mod 4 with
       | 0 -> Theme.category Theme.Slot_1
       | 1 -> Theme.category Theme.Slot_2
       | 2 -> Theme.ok ()
       | _ -> Theme.warn ())

let board_sort_column_of_sort = function
  | Board_hot | Board_trending -> Render_schedule.Sort_score
  | Board_recent | Board_updated -> Render_schedule.Sort_age
  | Board_discussed -> Render_schedule.Sort_replies

(* Colour here, the glyph in {!Masc_tui_board_kind_mark}, which the help sheet
   reads from the same function. Nothing explained these marks anywhere before:
   a reader met "@" in the first column and had to guess. *)
let board_kind_mark kind =
  let mark = Masc_tui_board_kind_mark.glyph kind in
  match kind with
  | Some Post_by_person -> Ansi.bold ^ (Theme.info ()) ^ mark ^ Ansi.reset
  (* An automation's post is not a warning (RFC tui-one-screen-grammar 7.3):
     it recedes, so the person's posts the column exists for stand out. *)
  | Some Post_by_automation -> (Theme.recede ()) ^ mark ^ Ansi.reset
  | Some (Post_kind_unknown _) -> (Theme.warn ()) ^ mark ^ Ansi.reset
  | Some Post_by_system | None -> mark

(** The draft pane. For a new post the commit-message convention is stated
    on screen rather than assumed: first line is the title, the rest is the
    body. A reply sends the whole draft as one comment, so its hint drops
    the title convention. A draft taller than the viewport shows its tail,
    where the caret is -- the operator is always writing at the bottom. *)
let board_write_progress_sheet ~now (state : state) =
  let spec =
    match state.board_write with
    | Board_idle -> None
    | Board_posting _ ->
        Some
          ( "posting"
          , words state "게시글 등록 중" "Publishing Board post"
          , Some (words state "서버에서 새 게시글을 저장하고 있습니다" "Saving new post on server") )
    | Board_commenting _ ->
        Some
          ( "commenting"
          , words state "댓글 등록 중" "Posting comment"
          , Some (words state "서버에서 댓글을 저장하고 있습니다" "Saving comment on server") )
  in
  let started_at =
    Masc_tui_types.progress_clock_option state ~slot:"board-write" ~now
      (Option.map (fun (sig_key, _, _) -> sig_key) spec)
  in
  Option.map
    (fun (_, ps_title, ps_detail) ->
      { ps_title
      ; ps_detail
      ; ps_started_at = started_at
      ; ps_meter = None
      ; ps_action_hint = None
      ; ps_blocking = true
      })
    spec
;;

let render_board_compose (state : state) =
  let (rows, cols) = get_terminal_size () in
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let write_sheet = board_write_progress_sheet ~now state in
  let buf = Buffer.create 4096 in
  let draft_content = Buffer.contents state.board_draft in
  let raw_lines = String.split_on_char '\n' draft_content in
  (* What the draft is and where it goes. The keys are the footer's: this
     row carried "Enter: newline  Ctrl-E: $EDITOR" over a footer spelling
     Ctrl-E its own way and not naming Enter at all. *)
  let compose_detail_started =
    Masc_tui_types.progress_clock_option state ~slot:"board-detail" ~now
      (match state.board_compose_reply_to with
       | Some post_id ->
           (match Board_detail.view_for state.board_detail ~post_id with
            | Loading -> Some post_id
            | Ready _ | Failed _ | Absent -> None)
       | None -> None)
  in
  let context_lines =
    match state.board_compose_reply_to with
    | Some post_id ->
        let target = words state "댓글 대상: " "Reply to: " in
        let unidentified = target ^ Terminal_text.single_line post_id in
        (match Board_detail.view_for state.board_detail ~post_id with
         | Ready (post, _, _) when String.equal post.bp_id post_id ->
             [ target ^ Terminal_text.single_line post.bp_title
             ; Theme.recede () ^ Terminal_text.single_line post.bp_author ^ " · "
               ^ Ansi.reset ^ Terminal_text.preview_line post.bp_body
             ]
         | Loading ->
             [ unidentified
             ; progress_inline ~ko ~now ?started_at:compose_detail_started
                 (words state "원문 조회 중" "Loading original post")
             ]
         | Failed detail ->
             [ unidentified
             ; (Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset
             ]
         | Absent ->
             [ unidentified
             ; words state "원문 미조회" "Original post not loaded"
             ]
         | Ready _ ->
             [ unidentified
             ; words state "조회한 글이 댓글 대상과 다릅니다"
                 "Loaded post does not match the reply target"
             ])
    | None ->
        let hearth_label =
          match state.board_compose_hearth with
          | Some h -> "#" ^ Terminal_text.single_line h
          | None -> words state "기본" "default"
        in
        let addressing = Board_composer.analyze_addressing draft_content in
        [ words state "첫 줄은 제목, 나머지는 본문 · 게시판: "
            "First line: title · rest: body · hearth: " ^ hearth_label
        ; Board_composer.format_addressing_hint
            ~ko
            ~max_cells:(framed_inner_width cols) addressing
        ]
  in
  let header =
    here_row ~cols state
      ~path:
        [ board_step state
        ; (match state.board_compose_reply_to with
           | Some _ -> words state "댓글" "reply"
           | None -> words state "새 글" "new post") ]
      ~readings:
        (match write_sheet with
         | None -> []
         | Some sheet ->
             [ progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title ])
      ~position:None
  in
  (* Staged files ride the post being written; a comment has no attachment
     wire, so like the hearth they are not named on a reply's pane. *)
  let attachments_line =
    match state.board_compose_reply_to, state.board_compose_attachments with
    | None, _ :: _ ->
        Some
          (words state "첨부: " "attachments: "
           ^ String.concat " \xc2\xb7 "
               (List.map
                  (fun (staged : board_staged_attachment) ->
                     board_upload_kind_to_wire staged.sa_kind
                     ^ " " ^ Terminal_text.single_line staged.sa_name)
                  state.board_compose_attachments))
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
        let label = words state "첨부할 파일: " "attach file: " in
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
  List.iter (box_line buf cols) context_lines;
  (match attachments_line with
   | Some line -> box_line buf cols (Theme.recede () ^ line ^ Ansi.reset)
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
  let chrome_top_rows =
    3 + List.length context_lines + error_rows + attachment_rows + attach_input_rows
  in
  let raw_content_height = max 1 (rows - (chrome_top_rows + 3)) in
  let sheet_lines =
    match write_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:raw_content_height
          ~width:(framed_inner_width cols) sheet
  in
  let content_height = max 0 (raw_content_height - List.length sheet_lines) in
  let visible_lines =
    let total = List.length draft_lines in
    if content_height = 0 then []
    else if total > content_height then
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
  List.iter (box_line buf cols) sheet_lines;
  box_bottom buf cols;
  let footer =
    match state.board_compose_attach_input with
    | Some _ ->
        (* The path input owns the keys, so the footer names its two; the
           path itself is on the pane above. *)
        Footer_hints
          { hints = Masc_tui_keys.footer_hints_board_attach_input ~lang:state.ui_language
          ; position = None
          }
    | None ->
        if Option.is_some write_sheet then
          Footer_hints
            { hints =
                ui_text state ~ko:"전송 중 · Esc:메뉴" ~en:"Submitting · Esc:menu"
            ; position = None
            }
        else if state.board_compose_armed then
          let menu =
            Masc_tui_keys.board_compose_menu_hints ~lang:state.ui_language
              ~reply:(Option.is_some state.board_compose_reply_to)
          in
          Footer_choices { choices = menu.choices; hints = menu.hints }
        else
          (* Projected from the key table; the table says why there is no [q]. *)
          Footer_hints
            { hints =
                Masc_tui_keys.footer_hints_board_compose_writing ~lang:state.ui_language
                  ~reply:(Option.is_some state.board_compose_reply_to)
            ; position = None
            }
  in
  let cursor =
    if Option.is_some write_sheet || state.board_compose_armed || Option.is_some state.board_compose_attach_input then
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
    ~rows ~cols ~footer buf

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

(* "Refreshing" on this surface is the pane's own poll in flight -- its
   resting state between answers. Drawing the word for every poll made the
   title and the census row flicker at read cadence; the word now waits out
   the pending display bar the Keeper header rows share, so it names a read
   that is actually slow. First reads keep their plain words: the pane has
   nothing else to say. *)
let board_dataset_refresh_slow state dataset =
  match Surface_read_order.pending_dataset_age state.http_surface_reads dataset with
  | Some age when past_pending_display_bar age -> true
  | Some _ | None -> false

(* Retained values stay readable here, with their availability. The title and
   reader index only borrow totals from a received, non-pending census. *)
let board_hearth_census_line ~cols (state : state) =
  let words ko en = words state ko en in
  let observation,pending=board_census_reading state in
  let slow=board_dataset_refresh_slow state Surface_read_order.Board_hearths in
  let status=match observation with
    | Masc_tui_fetched.Absent -> Some (if pending then (words "게시판 집계 조회 중" "reading census") else (words "게시판 집계 미조회" "census not read"))
    | Loading -> Some (words "게시판 집계 조회 중" "reading census")
    | Ready _ -> if slow then Some (words "갱신 중 · 이전 관측" "refreshing; last observed") else None
    | Stale (_,detail) -> Some ((if slow then (words "갱신 중 · " "refreshing; ") else "")
        ^ (words "이전 관측 · 조회 실패: " "last observed; unavailable: ") ^ Terminal_text.single_line detail)
    | Failed detail -> Some ((if slow then (words "재조회 중 · " "retrying; ") else "")
        ^ (words "조회 실패: " "unavailable: ") ^ Terminal_text.single_line detail) in
  let tone=match observation with
    | Masc_tui_fetched.Stale _ | Failed _ -> Theme.bad ()
    | Absent | Loading | Ready _ -> Theme.recede () in
  let notice text = tone
    ^ Message_layout.truncate_middle (framed_inner_width cols) ((words "게시판 · " "hearths · ") ^ text) ^ Ansi.reset in
  match Masc_tui_fetched.value observation with
  | None -> notice (match status with Some text -> text | None -> (words "집계 미조회" "census not read"))
  | Some [] -> notice (match status with Some text -> (words "이전 집계는 비어 있음 · " "last census empty; ") ^ text | None -> (words "집계 결과 없음" "census empty"))
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
           axis from how big it is, and the adaptive selection highlight says
           the first without leaving the second unsaid -- the count is in the
           text. *)
        if selected then
          match Theme.sidebar_selection_background () with
          | Some bg when not (String.equal bg "") ->
              Masc_tui_theme.paint_row_background ~bg
                (Theme.accent () ^ Ansi.bold ^ text ^ Ansi.reset)
          | Some _ | None ->
              Theme.selection_style () ^ Ansi.bold ^ text ^ Ansi.reset
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
        Printf.sprintf "   %s" (count_reading state Masc_tui_value.Count.Post total)
      in
      (* Hearths cut off at the row's end: a cut-off count, never "+N"
         (RFC tui-one-screen-grammar 6.3). *)
      let dropped_note count =
        census_separator
        ^ Masc_tui_value.Count.more ~ko:(state.ui_language = Lang_ko) count in
      let label_gap = " " in
      let label=match status with
        | None -> words "게시판" "hearths"
        | Some text -> Message_layout.truncate_middle
            (max 0 (framed_inner_width cols - cells label_gap - cells tail
              - cells (dropped_note (List.length hearths)))) ((words "게시판 · " "hearths · ") ^ text) in
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
        |> String.concat (Theme.recede () ^ census_separator ^ Ansi.reset)
      in
      Printf.sprintf "%s%s%s%s%s%s%s" tone label Ansi.reset label_gap shown
        (match note with
         | None -> ""
         | Some note -> Printf.sprintf "%s%s%s" (Theme.recede ()) note Ansi.reset)
        (Printf.sprintf "%s%s%s" (Theme.recede ()) tail Ansi.reset)

let board_posts_status state =
  let words ko en = words state ko en in
  let observation,_=board_posts_reading state in
  let slow=board_dataset_refresh_slow state Surface_read_order.Board_posts in
  let status=match observation with
    | Masc_tui_fetched.Absent -> Some (words "글 미조회" "posts not read")
    | Loading -> Some (words "글 조회 중" "reading posts")
    | Ready _ -> if slow then Some (words "글 갱신 중 · 이전 관측" "refreshing posts; last observed") else None
    | Stale _ -> Some (if slow then (words "글 갱신 중 · 이전 실패" "refreshing posts; last failure retained") else (words "이전 글 목록 · 조회 실패" "last observed posts; unavailable"))
    | Failed _ -> Some (if slow then (words "글 재조회 중 · 조회 실패" "retrying posts; unavailable") else (words "글 조회 실패" "posts unavailable")) in
  match board_posts_snapshot state with
  | Some snapshot when not (board_listing_matches_requested state) ->
      let origin=Printf.sprintf (if state.ui_language = Lang_ko then "이전 관측: %s · 요청: %s" else "last observed: %s; requested: %s")
        (board_query_text state snapshot.bl_query)
        (board_query_text state (board_query state)) in
      Some (origin ^ (match status with None -> "" | Some status -> "; " ^ status))
  | Some _ | None -> status

(* Single-entry render-loop cache for the Board_list docked preview body.
   Invalidates whenever post identity, body, closed resolution summary, width,
   UI language, table frame flag, or any Markdown/preview theme style changes. *)
type board_list_preview_cache_key =
  { blpk_post_id : string
  ; blpk_body : string
  ; blpk_resolution : string option
  ; blpk_width : int
  ; blpk_language : ui_language
  ; blpk_table_frame : bool
  ; blpk_styles : string list
  }

let equal_board_list_preview_cache_key (a : board_list_preview_cache_key)
    (b : board_list_preview_cache_key) =
  String.equal a.blpk_post_id b.blpk_post_id
  && String.equal a.blpk_body b.blpk_body
  && Option.equal String.equal a.blpk_resolution b.blpk_resolution
  && Int.equal a.blpk_width b.blpk_width
  && a.blpk_language = b.blpk_language
  && Bool.equal a.blpk_table_frame b.blpk_table_frame
  && List.equal String.equal a.blpk_styles b.blpk_styles

let board_list_preview_cache : (board_list_preview_cache_key * string list) option ref =
  ref None

let board_preview_style_signature () =
  [ Theme.recede ()
  ; Theme.warn ()
  ; Theme.category Theme.Slot_1
  ; Theme.category Theme.Slot_2
  ; Theme.Syntax.code_span ()
  ; Theme.Syntax.link ()
  ; Theme.Syntax.rule ()
  ; Theme.Syntax.keyword ()
  ; Theme.Syntax.string ()
  ; Theme.Syntax.code_comment ()
  ; Theme.Syntax.code_number ()
  ; Theme.Syntax.code_type ()
  ; Theme.Syntax.json_key ()
  ; Theme.Syntax.json_number ()
  ; Theme.Syntax.json_literal ()
  ; Theme.Syntax.diff_added_bg ()
  ; Theme.Syntax.diff_added_fg ()
  ; Theme.Syntax.diff_removed_bg ()
  ; Theme.Syntax.diff_removed_fg ()
  ]

let board_preview_wrapped_body (state : state) ~width (post : board_post) =
  let width = max 1 width in
  let resolution =
    Option.bind post.bp_closed (fun closed -> closed.bpc_summary)
  in
  let key =
    { blpk_post_id = post.bp_id
    ; blpk_body = post.bp_body
    ; blpk_resolution = resolution
    ; blpk_width = width
    ; blpk_language = state.ui_language
    ; blpk_table_frame = !table_frame_enabled
    ; blpk_styles = board_preview_style_signature ()
    }
  in
  match !board_list_preview_cache with
  | Some (cached_key, cached_lines)
    when equal_board_list_preview_cache_key cached_key key ->
      cached_lines
  | Some _ | None ->
      let resolution_lines =
        match resolution with
        | Some summary when not (String.equal (String.trim summary) "") ->
            (Theme.warn () ^ Ansi.bold ^ words state "종료 결론" "Resolution" ^ Ansi.reset)
            :: Message_layout.wrap_body
                 ~markdown:board_document_markdown ~max_cells:width
                 ~sanitize:Terminal_text.single_line summary
        | Some _ | None -> []
      in
      let body_lines =
        match String.trim post.bp_body with
        | "" -> []
        | _ ->
            Message_layout.wrap_body
              ~markdown:board_document_markdown ~max_cells:width
              ~sanitize:Terminal_text.single_line post.bp_body
      in
      let combined =
        match resolution_lines, body_lines with
        | [], [] -> [ Theme.recede () ^ Masc_tui_theme.Glyph.no_value ^ Ansi.reset ]
        | res, [] -> res
        | [], body -> body
        | res, body -> res @ [ "" ] @ body
      in
      board_list_preview_cache := Some (key, combined);
      combined

(* Matches [Masc_tui_doc.docked_preview] chrome allocation when both eyebrow
   and footer hints are present: hairline + header on top (2 rows when
   [rows >= 2], else 1), footer hint bar on the bottom when [rows - top >= 2]. *)
let board_preview_body_budget ~rows =
  if rows <= 0 then 0
  else
    let top_count = if rows >= 2 then 2 else 1 in
    let bottom_count = if rows - top_count >= 2 then 1 else 0 in
    max 0 (rows - top_count - bottom_count)

let slice_window ~offset ~limit lines =
  let rec drop n xs =
    if n <= 0 then xs
    else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest
  in
  let rec take n acc xs =
    if n <= 0 then List.rev acc
    else match xs with [] -> List.rev acc | x :: rest -> take (n - 1) (x :: acc) rest
  in
  take limit [] (drop offset lines)

(* The selected post under the list, the same docked preview Goals and
   Verdicts draw. It returns exactly [rows] lines, so the list rows above it
   stay where they are while the cursor moves. Space grows it, J/K scroll long
   bodies inside it, Esc folds it back, Enter opens the post as before. The
   title is not repeated: the selected row above already shows it. *)
let board_preview_lines (state : state) ~now ~age_time ~hide_hearth ~cols ~rows
    (post : board_post) =
  let width = max 1 (framed_inner_width cols) in
  let ko = state.ui_language = Lang_ko in
  let stage =
    match state.board_preview_mode with
    | Preview_compact -> words state "미리보기 확장" "expand"
    | Preview_half -> words state "최대" "full"
    | Preview_full -> words state "접기" "compact"
  in
  let wrapped_body = board_preview_wrapped_body state ~width post in
  let body_budget = board_preview_body_budget ~rows in
  let total_lines = List.length wrapped_body in
  let max_scroll =
    if body_budget <= 0 then 0 else max 0 (total_lines - body_budget)
  in
  let requested_scroll =
    match state.board_list_preview_post_id with
    | Some id when String.equal id post.bp_id -> state.board_list_preview_scroll
    | Some _ | None -> 0
  in
  let clamped_scroll =
    if body_budget <= 0 then 0
    else Masc_tui_scroll.normalize ~count:total_lines ~height:body_budget requested_scroll
  in
  let visible_body =
    if body_budget <= 0 then []
    else slice_window ~offset:clamped_scroll ~limit:body_budget wrapped_body
  in
  let scroll_arrow =
    if max_scroll <= 0 then ""
    else
      match clamped_scroll > 0, clamped_scroll < max_scroll with
      | true, true -> " \xe2\x96\xb2\xe2\x96\xbc"
      | true, false -> " \xe2\x96\xb2"
      | false, true -> " \xe2\x96\xbc"
      | false, false -> ""
  in
  let comments =
    let n = Masc_tui_value.Count.grouped post.bp_comment_count in
    if ko then "댓글 " ^ n
    else if post.bp_comment_count = 1 then "1 comment"
    else n ^ " comments"
  in
  let hearth_meta =
    if hide_hearth then None
    else
      match Terminal_text.optional_single_line post.bp_hearth with
      | Some h when not (String.equal h "") -> Some ("#" ^ h)
      | Some _ | None -> None
  in
  let age_meta =
    Option.map (Masc_tui_value.Ongoing.since ~now)
      (board_age_source ~time:age_time
         ~posted:post.bp_created_at_unix ~changed:post.bp_updated_at)
  in
  let score_meta =
    if post.bp_votes > 0 then
      Some ("\xe2\x96\xb2" ^ Masc_tui_value.Count.increase post.bp_votes)
    else if post.bp_votes < 0 then
      Some ("\xe2\x96\xbc" ^ Masc_tui_value.Count.decrease (-post.bp_votes))
    else None
  in
  let attachments_meta =
    match List.length post.bp_attachments with
    | 0 -> None
    | count ->
        let n = Masc_tui_value.Count.grouped count in
        Some
          (if ko then "첨부 " ^ n
           else if count = 1 then "1 attachment"
           else n ^ " attachments")
  in
  let closed_meta =
    match post.bp_closed with
    | Some _ -> Some (words state "종료됨" "closed")
    | None -> None
  in
  let meta_parts =
    [ Some ("@" ^ Terminal_text.single_line post.bp_author)
    ; hearth_meta
    ; age_meta
    ; Some comments
    ; score_meta
    ; attachments_meta
    ; closed_meta
    ]
    |> List.filter_map Fun.id
  in
  let footer_hints =
    { Masc_tui_card.key = "Space"; label = stage }
    :: (if max_scroll > 0 then
          [ { Masc_tui_card.key = "J/K"; label = words state "본문 스크롤" "scroll" } ]
        else [])
    @ [ { Masc_tui_card.key = "Enter"; label = words state "읽기" "read" }
      ; { Masc_tui_card.key = "Esc"; label = words state "닫기/뒤로" "back" }
      ]
  in
  let lines =
    Masc_tui_doc.docked_preview ~width ~height:rows ~indent:0
      ~eyebrow:(words state "선택한 글" "Selected post" ^ scroll_arrow)
      ~meta:(String.concat " · " meta_parts)
      ~footer_hints
      visible_body
  in
  (lines, clamped_scroll, max_scroll, body_budget)

let render_board_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in

  let count = List.length (board_posts state) in
  let cursor =
    if count = 0 then 0 else max 0 (min state.board_cursor (count - 1))
  in
  (* Read once for the whole list: the header word and every row's number name
     the same time, and they would drift the moment two readings of the sort
     disagreed. *)
  let query = board_posts_query state in
  let age_time = board_sort_time query.bq_sort in
  let ko = state.ui_language = Lang_ko in
  let age_header = if ko then (match age_time with Board_time_posted -> "게시 후" | Board_time_changed -> "변경 후")
    else board_age_header age_time in
  (* Which sub-board is being read. Said only when the list is narrowed: "all
     hearths" is what a reader assumes, and 24 of them share this board with
     1550 of 2171 posts in one, so a narrowed list that did not say so would
     look like a board that had gone quiet. *)
  let hearth =
    match query.bq_hearth with
    | None -> ""
    | Some hearth ->
        Printf.sprintf (if state.ui_language = Lang_ko then "%s게시판:%s%s" else "%shearth:%s%s") (Theme.accent ())
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
  let now = Unix.gettimeofday () in
  let write_sheet = board_write_progress_sheet ~now state in
  let list_loading_started =
    Masc_tui_types.progress_clock_option state ~slot:"board-list" ~now
      (if pending || observation = Masc_tui_fetched.Loading then Some "loading" else None)
  in
  let progress_sheet =
    match write_sheet with
    | Some _ as s -> s
    | None ->
        if count = 0 && (pending || observation = Masc_tui_fetched.Loading) then
          Some
            { ps_title = words state "게시글 목록 읽는 중" "Loading Board posts"
            ; ps_detail =
                Option.map
                  (fun h -> (if ko then "게시판:" else "hearth:") ^ Terminal_text.single_line h)
                  query.bq_hearth
            ; ps_started_at = list_loading_started
            ; ps_meter = None
            ; ps_action_hint = None
            ; ps_blocking = false
            }
        else None
  in
  let holding = board_census_holding state ~hearth:query.bq_hearth in
  let header =
    here_row ~cols state ~path:[ board_step state ]
      ~readings:
        [ (match write_sheet, Masc_tui_fetched.value observation with
           | Some sheet, _ ->
               progress_inline ~ko ~now ?started_at:sheet.ps_started_at sheet.ps_title
           | None, Some _ ->
               if pending then
                 progress_inline ~ko ~now ?started_at:list_loading_started
                   (words state "글 갱신 중" "refreshing posts")
               else ""
           | None, None ->
               if pending || observation = Masc_tui_fetched.Loading then
                 progress_inline ~ko ~now ?started_at:list_loading_started
                   (words state "글 조회 중" "reading posts")
               else here_missing_reading state ~error:list_error)
        ; hearth ]
      ~position:
        (match Masc_tui_fetched.value observation with
         | None -> None
         | Some _ when count = 0 -> None
         | Some _ ->
             let selected = Some cursor in
             Some
               (match holding with
                | Some total when total > count ->
                    Masc_tui_value.Position.partial ~selected ~loaded:count ~total
                | Some _ | None -> Masc_tui_value.Position.row ~selected ~total:count))
  in

  let hide_hearth = Option.is_some query.bq_hearth in
  let sort_column = board_sort_column_of_sort query.bq_sort in
  let layout = board_layout ~hide_hearth ~sort_column ~cols in
  let drawn_list_scroll = ref 0 in
  let drawn_preview_post_id = ref None in
  let drawn_preview_scroll = ref 0 in
  let drawn_preview_max_scroll = ref 0 in
  let drawn_preview_body_rows = ref 0 in
  (* The frame, its fill and the footer are the contract's: this surface
     counted them by hand and counted two rows it no longer draws, so the
     footer stood two rows above the composer. *)
  surface_chrome
    ~overflow:
      (Self_scrolled
         (fun () ->
           Board_list_scroll
             { list_scroll = !drawn_list_scroll
             ; preview_post_id = !drawn_preview_post_id
             ; preview_scroll = !drawn_preview_scroll
             ; preview_max_scroll = !drawn_preview_max_scroll
             ; preview_body_rows = !drawn_preview_body_rows
             }))
    ?progress_sheet ~now state ~terminal_rows ~cols ~surface_key:"board-list"
    ~title:header ~hints:(Masc_tui_keys.footer_hints ~lang:state.ui_language ~detail_open:false state.view)
    ~body:(fun ~budget c ->
      (* Every post still occupies one row. Count the headings drawn above
         those rows in the same content budget used for cursor paging. *)
      let heading =
        [ (fun () ->
            (* The sort first. It has no other home on this surface now, and
               this row is cut to the frame's inner width: at 34 columns the
               key hint alone spent all 30 cells, so the order the rows are in
               was invisible while the key to change it was not. H is in the
               sheet under [?]. *)
            c.push_styled ~style:(Theme.recede ())
              (board_heading_with_tail ~cols
                 (Printf.sprintf
                    (if state.ui_language = Lang_ko then "%s정렬 [s]: %s"
                     else "%sSort [s]: %s")
                    (match board_posts_status state with None -> "" | Some status -> status ^ " · ")
                    (board_sort_text state query.bq_sort))
                 (words state " · H:게시판 선택" " · H:choose hearth")))
        ; (fun () -> c.push (board_hearth_census_line ~cols state))
        ; (fun () ->
            c.push_styled ~style:(Theme.recede ())
              ("  "
               ^ Render_schedule.board_header_row_with_dropped ~sort_column ~ko
                   ~inner_width:(max 0 (framed_inner_width cols - 2))
                   ~age_header ~layout))
        ; c.push_divider
        ]
      in
      List.iter (fun draw -> draw ()) heading;
      let render_list_error err = c.push (data_unreliable_row ~cols err) in
      if count = 0 then
        (match observation with
         | Masc_tui_fetched.Failed _ | Stale _ -> Option.iter render_list_error list_error
         | Absent -> c.push (Theme.recede () ^ page_unread_note ~ko:(state.ui_language = Lang_ko) ^ Ansi.reset)
         | Loading ->
             c.push
               ("  " ^ progress_inline ~ko ~now ?started_at:list_loading_started
                  (words state "글 조회 중" "Reading Board posts"))
         | Ready _ ->
             if pending then
               c.push
                 ("  " ^ progress_inline ~ko ~now ?started_at:list_loading_started
                    (words state "이전 목록은 비어 있음 · 글 조회 중" "Last listing empty · reading posts"))
             else
               c.push (Theme.recede ()
                 ^ (if not (board_listing_matches_requested state) then (words state "  (이전 목록은 비어 있음 · 요청한 목록 미조회)" "  (last listing empty; requested query not read)")
                    else (words state "  (게시글 없음)" "  (no board posts)")) ^ Ansi.reset))
      else begin
        Option.iter render_list_error list_error;
        let error_rows = if Option.is_some list_error then 1 else 0 in
        let selected_post = List.nth_opt (board_posts state) cursor in
        let split =
          docked_vertical_split
            ~total_rows:(max 0 (budget - List.length heading - error_rows))
            ~mode:state.board_preview_mode
            ~has_selection:(Option.is_some selected_post)
        in
        let content_height = split.list_rows in
        let scroll_offset =
          if content_height = 0 then 0
          else
            let normalized =
              Masc_tui_scroll.normalize ~count ~height:content_height
                state.board_list_scroll
            in
            Masc_tui_scroll.ensure_visible ~cursor ~height:content_height
              normalized
        in
        drawn_list_scroll := scroll_offset;
        (* One clock read for the whole page, so two rows drawn in the same
           frame cannot report ages a tick apart. *)
        let now_unix = Unix.gettimeofday () in
        let board_posts_window =
          Rows.of_list ~first:scroll_offset ~height:content_height
            (board_posts state)
        in
        report_drawn_list Board_post_rows ~height:content_height;
        for i = 0 to content_height - 1 do
          let idx = i + scroll_offset in
          match Rows.at board_posts_window idx with
          | None ->
              (* A short list keeps the preview docked at the bottom rather
                 than drawn directly under its last row. *)
              if split.preview_rows > 0 then c.push ""
          | Some p ->
            let is_selected = idx = cursor in
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
              if p.bp_votes > 0 then
                "\xe2\x96\xb2" ^ Masc_tui_value.Count.increase p.bp_votes
              else if p.bp_votes < 0 then
                "\xe2\x96\xbc" ^ Masc_tui_value.Count.decrease (-p.bp_votes)
              else "0"
            in
            let replies_text =
              Masc_tui_value.Count.grouped p.bp_comment_count
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
              { Render_schedule.bstyle_hearth =
                  if String.equal hearth_text "" then Theme.recede ()
                  else Theme.info ()
              ; bstyle_author = board_author_style ~kind:p.bp_kind p.bp_author
              ; bstyle_age = Theme.recede ()
              ; bstyle_score = board_score_style p.bp_votes
              ; bstyle_replies =
                  if p.bp_comment_count > 0 then Theme.ok () else Theme.recede ()
              }
            in
            let content =
              Render_schedule.board_row ~ko ~styles ~age_header ~layout values
            in
            if is_selected then
              c.push_selected_styled
                (Theme.accent () ^ Ansi.bold ^ "\xe2\x80\xba " ^ Ansi.reset ^ content)
            else c.push ("  " ^ content)
        done;
        if split.preview_rows > 0 then
          Option.iter
            (fun post ->
              let lines, preview_scroll, preview_max_scroll, preview_body_rows =
                board_preview_lines state ~now:now_unix ~age_time ~hide_hearth
                  ~cols ~rows:split.preview_rows post
              in
              drawn_preview_post_id := Some post.bp_id;
              drawn_preview_scroll := preview_scroll;
              drawn_preview_max_scroll := preview_max_scroll;
              drawn_preview_body_rows := preview_body_rows;
              List.iter c.push lines)
            selected_post
      end)

(* Owned by the single render loop, like the chat Markdown cache. Only the
   currently read document is retained; input and live status are never cached. *)
let board_read_layout = Board_read_layout.create ()
;;

(* The comment v/V votes on while the comments have focus, so the one the
   gutter marks. With the post body focused the keys vote on the post, and
   no comment is marked. *)
let selected_comment ~(focus : pane_focus) (state : state) =
  if focus = Right_pane && state.board_comments_focused then
    state.board_comment_cursor
  else None

let comment_gutter = String.make Board_read_layout.comment_gutter_cells ' '

(* Same cell count as [comment_gutter]: a marker cell, then blanks. *)
let selected_comment_gutter () =
  Theme.accent () ^ Ansi.bold ^ "\xe2\x80\xba" ^ Ansi.reset
  ^ String.make (Board_read_layout.comment_gutter_cells - 1) ' '

let comment_row_gutter ~focus (state : state) =
  let selected = selected_comment ~focus state in
  let marker = selected_comment_gutter () in
  fun comment_id ->
    match selected with
    | Some id when String.equal id comment_id -> marker
    | Some _ | None -> comment_gutter

(* Where the comment column is asked to stand this frame. A first read's
   landing comment comes first; then a cursor move's request to bring the
   selected comment on screen; otherwise the reader's own scroll, which
   PgUp/PgDn move by rows. *)
let requested_comment_scroll ~focus (state : state) document ~viewport_rows =
  match state.board_comment_landing with
  | Some comment_id -> (
      match Board_read_layout.initial_comment_offset document ~comment_id with
      | Some offset -> offset
      | None -> state.board_comment_scroll)
  | None -> (
      let followed =
        if state.board_comment_follow then selected_comment ~focus state else None
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
let draw_board_read_side ~focus buf (state : state) document ~rows ~body_cols
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
        (requested_comment_scroll ~focus state document
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
  let gutter = comment_row_gutter ~focus state in
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
        (Ansi.bold ^ Theme.section_heading ()
        ^ Printf.sprintf (if state.ui_language = Lang_ko then "%s댓글 (%d)" else "%sComments (%d)")
            (if focus = Right_pane && state.board_comments_focused
             then "\xe2\x96\xb8 " else "  ")
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
let board_read_pane ~focus ~layout (state : state) (list_post : board_post) ~rows
    ~cols buf =
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

  (* The title names where the focused half stands, known once the rows are
     laid out, so the pane is drawn first and the title put above it. *)
  let header ~position =
    here_row ~cols state
      ~path:
        (board_step state
         :: (match Terminal_text.optional_single_line post.bp_hearth with
             | None -> []
             | Some hearth -> [ "#" ^ hearth ]))
      ~readings:[] ~position
  in
  let outer = buf in
  let buf = Buffer.create 8192 in

  let title_line = Printf.sprintf "%s%s%s%s"
    (if focus = Right_pane && not state.board_comments_focused
     then "\xe2\x96\xb8 " else "  ")
    Ansi.bold
    (fit_width (Terminal_text.single_line post.bp_title) (framed_inner_width cols - 2))
    Ansi.reset
  in
  box_line buf cols title_line;
  let author_chip =
    let author_name = Terminal_text.single_line post.bp_author in
    let author_style = board_author_style ~kind:post.bp_kind post.bp_author in
    match post.bp_kind with
    | Some Post_by_automation ->
        Printf.sprintf
          (if state.ui_language = Lang_ko then "%s@%s%s %s[자동 게시]%s"
           else "%s@%s%s %s[Automation]%s")
          author_style
          author_name
          Ansi.reset
          (Theme.warn ())
          Ansi.reset
    | Some Post_by_person ->
        Printf.sprintf (if state.ui_language = Lang_ko then "%s@%s%s %s[작성자]%s" else "%s@%s%s %s[Author]%s")
          author_style
          author_name
          Ansi.reset
          (Theme.info ())
          Ansi.reset
    | Some (Post_by_system | Post_kind_unknown _) | None -> Printf.sprintf "%s@%s%s"
          author_style
          author_name
          Ansi.reset
  in
  let sep = Theme.recede () ^ " · " ^ Ansi.reset in
  let state_chip =
    match post.bp_closed with
    | None -> Theme.ok () ^ words state "열린 글" "open" ^ Ansi.reset
    | Some _ -> Theme.warn () ^ words state "종료된 글" "closed" ^ Ansi.reset
  in
  let score_part =
    if post.bp_votes = 0 then ""
    else sep ^ board_score_style post.bp_votes ^ board_score_text post.bp_votes ^ Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "  %s%s%s%s%s%s%s%s%s%d%s"
       author_chip sep
       (Theme.recede ()) (Terminal_text.short_timestamp post.bp_created_at) Ansi.reset
       sep state_chip sep
       (Theme.recede () ^ words state "댓글 " "replies " ^ Ansi.reset)
       post.bp_comment_count score_part);
  box_divider buf cols;

  (* The thread sits beside the post, not under it, when the pane is wide
     enough for both columns to stay readable (p-7784d032) and the post list
     is not hidden: [z] gives the thread the whole width under the post
     (#40134). Otherwise it keeps the stacked layout below -- the same rows,
     drawn the way they were before the side arrangement existed. Decided
     here, before the document below wraps a single word of it, so the body
     and comment text get wrapped to the column that will actually draw them
     -- not the full pane width every layout used to assume, which is what let
     a wide-formatted comment line get clipped down to its author chip in the
     narrow column (p-7784d032 follow-up). *)
  let has_detail_content =
    match detail with
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        false
    | Board_detail.Ready (_, comments, _) -> comments <> []
  in
  let arrangement =
    Masc_tui_types.board_read_arrangement layout ~cols
      ~has_comments:has_detail_content
  in
  let body_wrap_cols, comment_wrap_cols =
    match arrangement with
    | Layout.Side { body_cols; comment_cols } -> (body_cols, comment_cols)
    | Layout.Stacked -> (cols, cols)
  in

  let source : Board_read_layout.source =
    { post; detail; related_posts = (board_posts state);
      keeper_names = List.map (fun (k : Tui_decode.keeper) -> k.k_name) state.keepers;
      body_columns = body_wrap_cols; comment_columns = comment_wrap_cols;
      language = state.ui_language;
      styles = [ Theme.info (); Theme.warn (); Theme.bad (); Theme.recede ();
                 Theme.accent (); Theme.ok ();
                 Theme.category Theme.Slot_1; Theme.category Theme.Slot_2 ];
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
          ""
          :: (Ansi.bold ^ Theme.section_heading () ^ words state "  연결" "  Points at" ^ Ansi.reset)
          :: List.map
               (fun (kind, id) ->
                 (* [Link.parse] percent-decodes the id segment, so a body that
                    writes masc://board/%1b%5b2J hands this line real escape
                    bytes. The kind is a closed variant and needs no sanitizer;
                    the id is whatever the writer typed. *)
                 Printf.sprintf "  %s%-10s%s %s" (Theme.recede ())
                   (Link.kind_label kind) Ansi.reset
                   (fit_width (Terminal_text.single_line id)
                      (max 8 (framed_inner_width body_wrap_cols - 12))))
               referenced
      in
      let related_lines =
        match related with
        | [] -> []
        | related ->
          ""
          :: (Ansi.bold ^ Theme.section_heading ()
              ^ Printf.sprintf (if state.ui_language = Lang_ko then "  같은 대상을 다룬 글 (%d)" else "  Also about this (%d)") (List.length related)
              ^ Ansi.reset)
          :: (related
              |> List.filteri (fun index _ -> index < 5)
              |> List.map (fun (other : board_post) ->
                   Printf.sprintf "  %s  %s%s%s"
                     (fit_width (Terminal_text.single_line other.bp_id) 12)
                     (Theme.recede ())
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
          ""
          :: (Ansi.bold ^ Theme.section_heading () ^ words state "  첨부" "  Attachments" ^ Ansi.reset)
          :: List.mapi
               (fun index (entry : board_attachment_entry) ->
                 Printf.sprintf "  %s[%d]%s %s" Ansi.bold (index + 1) Ansi.reset
                   (fit_width
                      (Terminal_text.single_line
                        (Board_attachments.label ~ko:(state.ui_language = Lang_ko) entry))
                      (max 8 (framed_inner_width body_wrap_cols - 8))))
               attachments
      in
      let closure_lines, closure_provenance = match post.bp_closed with
        | None -> [], []
        | Some closed ->
            let field label value =
              Masc_tui_text_block.rows ~max_cells:(max 1 text_width) (label ^ value)
              |> List.map (fun line -> "  " ^ line) in
            let provenance =
              field (words state "종료한 사람 " "Closed by ") closed.bpc_closed_by
              @ (match closed.bpc_closed_at with
               | None -> []
               | Some at ->
                   (match Board_read_layout.close_time ~now:(Unix.gettimeofday ()) at with
                    | Ok time -> field (words state "종료 시각 " "Closed at ") time
                    | Error raw -> field (words state "종료 시각을 읽을 수 없음 · 원래 Unix 초 " "Close time unreadable · raw Unix seconds ")
                        (Printf.sprintf "%.17g" raw))) in
            let conclusion =
              (match closed.bpc_successor_id with
               | None -> []
               | Some successor ->
                   field (if String.trim successor<>"" && not (String.equal successor post.bp_id)
                          then words state "후속 글 · S:열기 · " "Successor · S:open · " else words state "후속 글 · " "Successor · ")
                     (Link.reference Board_post successor))
            @ (match closed.bpc_summary with
               | None -> []
               | Some summary ->
                   Message_layout.wrap_body ~markdown:board_document_markdown
                     ~max_cells:(max 1 text_width) ~sanitize:Terminal_text.single_line summary) in
            let heading = Ansi.bold ^ words state "  종료 결론" "  Resolution" ^ Ansi.reset in
            (* Read the outcome before the original; its provenance stays after it.
               Without an outcome, retain the existing trailing closure record. *)
            let has_conclusion = Option.is_some closed.bpc_successor_id
              || Option.exists (fun summary -> String.trim summary <> "") closed.bpc_summary in
            if has_conclusion then heading :: conclusion @ [""], "" :: provenance
            else [], heading :: provenance @ conclusion @ [""] in
      let body_lines =
        closure_lines @ body_lines @ closure_provenance
        @ attachment_lines @ reference_lines @ related_lines
        @ [""; "  " ^ words state "글 주소 · " "Post reference · "
            ^ Link.reference Board_post (Terminal_text.single_line post.bp_id)]
      in
      let initial_comment_offset = ref None in
      let detail_lines =
        match detail with
        | Board_detail.Absent ->
            [ Board_read_layout.Thread_note
                (Theme.recede () ^ (words state "  상세 미조회" "  Board detail not read") ^ Ansi.reset) ]
        | Board_detail.Loading ->
            let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
            [ Board_read_layout.Thread_note
                (Theme.info () ^ "  " ^ under_way ^ " "
                 ^ words state "상세 조회 중" "Loading Board detail" ^ Ansi.reset) ]
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
                     " " ^ (Theme.info ()) ^ (words state "[작성자]" "[Author]") ^ Ansi.reset
                   else if List.exists (fun (k : Tui_decode.keeper) -> String.equal k.k_name author) state.keepers then
                     " " ^ (Theme.warn ()) ^ (words state "[키퍼]" "[Keeper]") ^ Ansi.reset
                   else ""
                 in
                 let author_style =
                   let kind =
                     if String.equal author (Terminal_text.single_line post.bp_author) then
                       post.bp_kind
                     else
                       List.find_map
                         (fun (other : board_post) ->
                           if String.equal (Terminal_text.single_line other.bp_author) author
                           then other.bp_kind
                           else None)
                         (board_posts state)
                   in
                   board_author_style ~kind c.bc_author
                 in
                 let score = board_comment_score c.bc_votes in
                 (* Every row below is drawn after the comment gutter, which
                    marks the selected comment; it is not part of the text,
                    so its cells are counted here and spent at draw time. *)
                 let heading =
                   Printf.sprintf "%s%s@%s%s%s  %s%s%s  %s%s%s"
                     rail
                     author_style
                     author
                     Ansi.reset
                     author_role
                     (Theme.recede ())
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
                             author_style
                             author Ansi.reset author_role
                             (board_score_style score)
                             (board_score_text score)
                             Ansi.reset
                         in
                         let timestamp =
                           Printf.sprintf "%s%s%s%s" rail (Theme.recede ()) created_at
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
                (Printf.sprintf (if state.ui_language = Lang_ko then "  댓글 %d/%d개  o:전체 댓글" else "  Showing %d of %d comments  o:all comments")
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
  let ko = state.ui_language = Lang_ko in
  let now = Unix.gettimeofday () in
  let detail_started =
    Masc_tui_types.progress_clock_option state ~slot:"board-detail" ~now
      (match detail with
       | Board_detail.Loading -> Some post.bp_id
       | Board_detail.Absent | Board_detail.Ready _ | Board_detail.Failed _ -> None)
  in
  let write_sheet = board_write_progress_sheet ~now state in
  let active_sheet =
    match write_sheet with
    | Some _ as s -> s
    | None ->
        (match detail with
         | Board_detail.Loading ->
             Some
               { ps_title = words state "게시글 상세 조회 중" "Loading Board detail"
               ; ps_detail = Some (Terminal_text.single_line post.bp_title)
               ; ps_started_at = detail_started
               ; ps_meter = None
               ; ps_action_hint = Some (words state "Esc:목록" "Esc:back")
               ; ps_blocking = false
               }
         | Board_detail.Absent | Board_detail.Ready _ | Board_detail.Failed _ -> None)
  in
  let attach_rows = if Option.is_some state.board_attachment_status then 1 else 0 in
  let raw_content_rows = max 0 (rows - attach_rows) in
  let sheet_avail =
    max 0 (raw_content_rows - Layout.board_read_box_rows - Layout.board_read_footer_rows)
  in
  let sheet_lines =
    match active_sheet with
    | None -> []
    | Some sheet ->
        render_progress_sheet ~ko ~now ~available:sheet_avail
          ~width:(framed_inner_width cols) sheet
  in
  let content_rows = max 0 (raw_content_rows - List.length sheet_lines) in
  (* [board_read_allocation] and [board_read_side_allocation] share field
     names but are different record types, so this match cannot return one
     of them -- only the scroll and the two drawn-row counts survive it. *)
  let scroll, body_lines_drawn, comment_lines_drawn =
    match arrangement with
    | Layout.Side { body_cols; comment_cols } ->
        draw_board_read_side ~focus buf state document ~rows:content_rows ~body_cols
          ~comment_cols ~total_lines ~detail_line_count ~detail_comment_count
    | Layout.Stacked ->
        let row_budget =
          Layout.allocate_board_read ~terminal_rows:content_rows
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
              (requested_comment_scroll ~focus state document
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
            (Ansi.bold ^ Theme.section_heading ()
             ^ (if focus = Right_pane && state.board_comments_focused
                then words state "\xe2\x96\xb8 댓글" "\xe2\x96\xb8 Comments" else words state "  댓글" "  Comments")
             ^ Ansi.reset);
          let gutter = comment_row_gutter ~focus state in
          for i = 0 to comment_height - 1 do
            box_line buf cols
              (Board_read_layout.comment_line document ~gutter
                 (i + scroll.comment_offset))
          done
        end;
        (scroll, content_height, comment_height)
  in
  (* The focused half names where its window stands, on the title row. Both
     halves count wrapped rows. *)
  let position =
    if state.board_comments_focused then
      Masc_tui_value.Position.window ~first:scroll.comment_offset
        ~shown:comment_lines_drawn ~total:detail_line_count
    else
      Masc_tui_value.Position.window ~first:scroll.body_offset
        ~shown:body_lines_drawn ~total:total_lines
  in
  (* What the numbered attachment keys last did, or why one could not.
     Recede-styled like the readings above; replaced by the next action and
     cleared when another post is opened. *)
  (match state.board_attachment_status with
   | Some status ->
       let status = Terminal_text.single_line status in
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "  %s" (fit_width status (framed_inner_width cols - 2)))
   | None -> ());
  List.iter (box_line buf cols) sheet_lines;
  box_bottom buf cols;
  box_top outer cols;
  box_line outer cols (header ~position);
  Buffer.add_buffer outer buf;
  Masc_tui_frame_timing.finish_stage ~name:"board.frame_rows" rows_started;
  Masc_tui_types.board_read_presented_frame state ~post_id:list_post.bp_id
    ~body:(total_lines, body_lines_drawn)
    ~comments:(detail_line_count, comment_lines_drawn);
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
  let narrowed_hearth = Option.is_some (board_posts_query state).bq_hearth in
  let format_sidebar_post (post : board_post) =
    let hearth_prefix =
      if narrowed_hearth then ""
      else
        match Terminal_text.optional_single_line post.bp_hearth with
        | Some h when not (String.equal h "") -> "#" ^ h ^ " "
        | _ -> ""
    in
    let vote_prefix =
      if post.bp_votes > 0 then Masc_tui_value.Count.increase post.bp_votes ^ " "
      else if post.bp_votes < 0 then
        Masc_tui_value.Count.decrease (-post.bp_votes) ^ " "
      else ""
    in
    Printf.sprintf "%s%s%s" hearth_prefix vote_prefix
      (Terminal_text.single_line post.bp_title)
  in
  let title=match board_posts_status state with None -> words state "게시판" "Board" | Some status -> words state "게시판 · " "Board · " ^ status in
  write_list_sidebar ~list:Board_read_sidebar_rows buf ~rows ~cols ~title
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
  (* The pane the keys act on, which is the stored choice only while the post
     list is drawn; the footer and the pane cues name this one (#39014). *)
  let focus = Masc_tui_types.board_read_focus state ~cols in
  let buf = Buffer.create 4096 in
  let footer =
    footer_line state ~max_cells:cols
      ~hints:
        (Masc_tui_keys.footer_hints_board_read ~lang:state.ui_language
           ~focus_posts:(focus = Left_pane)
           ~focus_comments:state.board_comments_focused
           ~full_history:(state.board_history_post_id = Some list_post.bp_id)
           ~layout
           ~has_attachments:(List.length list_post.bp_attachments > 0)
           ~has_successor:(Option.is_some (board_successor state)))
  in
  Masc_tui_frame_timing.finish_stage ~name:"board.render_prep" prep_started;
  match layout with
  | Board_read_wide | Board_read_one_pane ->
    let scroll = board_read_pane ~focus ~layout state list_post ~rows ~cols buf in
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
      board_read_pane ~focus ~layout state list_post ~rows ~cols:right_cols
        right_buf
    in
    write_two_panes buf ~left_cols:left_cols ~left:left_buf
      ~right:right_buf;
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf

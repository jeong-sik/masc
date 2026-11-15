open Masc_tui_types
module Layout = Masc_tui_board_read_layout
module Detail = Masc_tui_board_detail

let post =
  { bp_id = "post"; bp_author = "author"; bp_title = "Thread";
    bp_body = "Body"; bp_votes = 0; bp_comment_count = 128;
    bp_created_at = "2026-09-08"; bp_created_at_unix = None; bp_updated_at = None;
    bp_hearth = None; bp_kind = None; bp_closed = None; bp_attachments = [] }

let comments = List.init 128 (fun index ->
  { bc_id = string_of_int index; bc_parent_id = None; bc_author = "keeper";
    bc_content = Printf.sprintf "comment-%03d 한글 **Markdown**" index;
    bc_created_at = "2026-09-08"; bc_votes = { bcv_up = 0; bcv_down = 0 } })

let source : Layout.source =
  { post; detail = Detail.Ready (post, comments, None); related_posts = [post];
    keeper_names = ["keeper"]; body_columns = 100; comment_columns = 100;
    language = Masc_tui_types.Lang_en; styles = ["cyan"];
    table_frame = false }

let render source () =
  let body = [source.Layout.post.bp_body] in
  let rows = match source.detail with
    | Detail.Ready (_, comments, _) ->
        List.map (fun c ->
          Layout.Comment_text { comment_id = c.bc_id; text = c.bc_content }) comments
    | Detail.Absent -> [Layout.Thread_note "absent"]
    | Detail.Loading -> [Layout.Thread_note "loading"]
    | Detail.Failed error -> [Layout.Thread_note error]
  in
  body, rows, None

(* The fixtures read text, not the selection mark. *)
let no_gutter _comment_id = ""

let row_text = function
  | Layout.Thread_note text -> text
  | Layout.Comment_text { text; _ } -> text

let test_long_thread_scroll_reuses_rows () =
  let cache = Layout.create () in
  let renders = ref 0 in
  let get source = Layout.get cache ~source ~render:(fun () ->
    incr renders; render source ()) in
  let first = get source in
  for index = 0 to 127 do
    let rows = get {source with keeper_names = List.map Fun.id source.keeper_names} in
    Alcotest.(check string) "all comments remain reachable"
      (List.nth comments index).bc_content
      (Layout.comment_line rows ~gutter:no_gutter index)
  done;
  Alcotest.(check int) "one layout across scrolling" 1 !renders;
  Alcotest.(check int) "entire thread retained" 128
    (Layout.comment_line_count first);
  (* A JSON refresh creates fresh records even when the document is unchanged. *)
  let copied = List.map (fun c -> {c with bc_content = String.concat "" [c.bc_content; ""]}) comments in
  ignore (get {source with detail = Detail.Ready (post, copied, None)});
  Alcotest.(check int) "equal refresh reuses wrapping" 1 !renders

let test_live_inputs_replace_rows () =
  let cases =
    [ "body", {source with post = {post with bp_body = "edited body"}};
      "post author", {source with post = {post with bp_author = "new-author"}};
      "comment edit", {source with detail = Detail.Ready (post,
        List.map (fun c -> if c.bc_id = "127" then {c with bc_content = "edited tail"} else c) comments, None)};
      "append", {source with detail = Detail.Ready (post,
        comments @ [{(List.hd comments) with bc_id = "128"; bc_content = "new reply"}], None)};
      "reply parent", {source with detail = Detail.Ready (post,
        List.map (fun c -> if c.bc_id = "127" then {c with bc_parent_id = Some "0"} else c) comments, None)};
      "related posts", {source with related_posts = [{post with bp_body = "new reference"}]};
      "keeper roles", {source with keeper_names = []};
      "post width", {source with body_columns = 60};
      "comment width", {source with comment_columns = 60};
      "language", {source with language = Masc_tui_types.Lang_ko};
      "style", {source with styles = ["dark cyan"]};
      "tables", {source with table_frame = true};
      "loading", {source with detail = Detail.Loading};
      "error", {source with detail = Detail.Failed "offline"};
      "absent", {source with detail = Detail.Absent} ] in
  List.iter (fun (label, changed) ->
    let cache = Layout.create () in
    ignore (Layout.get cache ~source ~render:(render source));
    let renders = ref 0 in
    let rows = Layout.get cache ~source:changed ~render:(fun () ->
      incr renders; render changed ()) in
    Alcotest.(check int) label 1 !renders;
    let expected_body, expected_comments, _ = render changed () in
    Alcotest.(check string) (label ^ " body") (List.hd expected_body) (Layout.body_line rows 0);
    List.iteri (fun index expected ->
      Alcotest.(check string) (label ^ " comment") (row_text expected)
        (Layout.comment_line rows ~gutter:no_gutter index)) expected_comments
  ) cases

let test_failed_render_and_single_document () =
  let cache = Layout.create () in
  let initial = Layout.get cache ~source ~render:(render source) in
  let changed = {source with body_columns = 80} in
  (try ignore (Layout.get cache ~source:changed ~render:(fun () -> raise Exit)) with Exit -> ());
  let recovered = Layout.get cache ~source ~render:(fun () -> Alcotest.fail "lost good rows") in
  Alcotest.(check bool) "failed render keeps previous complete rows" true (initial == recovered);
  ignore (Layout.get cache ~source:changed ~render:(render changed));
  let renders = ref 0 in
  ignore (Layout.get cache ~source ~render:(fun () -> incr renders; render source ()));
  Alcotest.(check int) "only one document retained" 1 !renders

(* Whether the post list is on screen is the layout's answer, asked every time;
   the operator's earlier choice cannot keep it true after the terminal narrows
   (#39014). Nothing here pins how the screen looks. *)
let test_leaving_the_acting_pane_keeps_a_choice_the_layout_hides () =
  let state = create_state ~workspace:"" ~port:0 () in
  let split_cols = Masc_tui_roster_pane.threshold_cols in
  state.board_focus <- Right_pane;
  Alcotest.(check bool) "the split closes the cycle at the list" true
    (board_focus_on_leaving_acting_pane state ~cols:split_cols = Left_pane);
  Alcotest.(check bool) "below the split the stored choice stands" true
    (board_focus_on_leaving_acting_pane state ~cols:(split_cols - 1) = Right_pane);
  state.board_focus <- Left_pane;
  Alcotest.(check bool) "a stored list choice is not rewritten below the split" true
    (board_focus_on_leaving_acting_pane state ~cols:(split_cols - 1) = Left_pane);
  state.board_focus <- Right_pane;
  state.board_detail_wide <- true;
  Alcotest.(check bool) "the wide layout has no list to return to" true
    (board_focus_on_leaving_acting_pane state ~cols:split_cols = Right_pane)

let test_focus_follows_the_layout () =
  let state = create_state ~workspace:"" ~port:0 () in
  let split_cols = Masc_tui_roster_pane.threshold_cols in
  let focus ~cols = board_read_focus state ~cols in
  state.board_focus <- Left_pane;
  Alcotest.(check bool) "the split gives the list its keys" true
    (focus ~cols:split_cols = Left_pane);
  Alcotest.(check bool) "narrowed below the split, the open post has the keys" true
    (focus ~cols:(split_cols - 1) = Right_pane);
  Alcotest.(check bool) "narrowing does not rewrite the stored choice" true
    (state.board_focus = Left_pane);
  Alcotest.(check bool) "widening again gives the choice back" true
    (focus ~cols:split_cols = Left_pane);
  state.board_detail_wide <- true;
  Alcotest.(check bool) "the wide layout draws no list either" true
    (focus ~cols:split_cols = Right_pane);
  state.board_detail_wide <- false;
  state.board_focus <- Right_pane;
  Alcotest.(check bool) "a choice of the post stays the post at any width" true
    (focus ~cols:split_cols = Right_pane && focus ~cols:(split_cols - 1) = Right_pane)

(* PageDown and PageUp move by the window the last frame drew for this post:
   [Masc_tui_scroll.page_step] of that height, so one row of the old page stays
   on screen. Nothing here pins how the screen looks; the inputs are the counts
   and heights the frame reported. *)
let test_paging_uses_the_window_the_frame_drew () =
  let state = create_state ~workspace:"" ~port:0 () in
  let page direction = page_board_read state ~direction in
  state.board_mode <- Board_read "p1";
  page 1;
  Alcotest.(check int) "before any frame there is no window to page by" 0 state.board_scroll;
  board_read_presented_frame state ~post_id:"p1" ~body:(20, 6) ~comments:(30, 4);
  page 1;
  Alcotest.(check int) "a page down moves the window less the kept row" 5 state.board_scroll;
  page 1;
  page 1;
  Alcotest.(check int) "the last page stops at the end" 14 state.board_scroll;
  page (-1);
  Alcotest.(check int) "a page up from the end" 9 state.board_scroll;
  state.board_comments_focused <- true;
  page 1;
  Alcotest.(check int) "focused comments page by their own window" 3 state.board_comment_scroll;
  Alcotest.(check int) "the body keeps its place while the comments are paged" 9 state.board_scroll;
  state.board_comments_focused <- false;
  state.board_mode <- Board_read "p2";
  page 1;
  Alcotest.(check int) "a frame drawn for another post pages nothing" 9 state.board_scroll;
  state.board_mode <- Board_list;
  page 1;
  Alcotest.(check int) "outside the reader nothing is paged" 9 state.board_scroll

(* [z] hides the post list so the thread can be read wider (#40134). The cells
   counted here are the ones the decision wraps the thread to -- the pane under
   the post, the comment column beside it -- not a drawn screen. *)
let thread_cells ~pane_cols = function
  | Masc_tui_layout.Stacked -> pane_cols
  | Masc_tui_layout.Side { comment_cols; _ } -> comment_cols

let split_pane_cols ~terminal_cols = terminal_cols - Masc_tui_roster_pane.pane_cols

(* Every width from the split's threshold up to one far past the side layout's
   minimum in both layouts. *)
let two_pane_terminal_widths =
  List.init 300 (fun extra -> Masc_tui_roster_pane.threshold_cols + extra)

let test_z_never_narrows_the_thread () =
  List.iter (fun terminal_cols ->
    let split_cols = split_pane_cols ~terminal_cols in
    let split =
      thread_cells ~pane_cols:split_cols
        (board_read_arrangement Board_read_split ~cols:split_cols ~has_comments:true)
    in
    let wide =
      thread_cells ~pane_cols:terminal_cols
        (board_read_arrangement Board_read_wide ~cols:terminal_cols ~has_comments:true)
    in
    if wide < split then
      Alcotest.failf "%d columns: z wrapped the thread to %d cells instead of %d"
        terminal_cols wide split)
    two_pane_terminal_widths

let test_the_split_keeps_the_thread_beside_the_post () =
  let side_cols = Masc_tui_layout.board_read_side_minimum_cols in
  let beside = function
    | Masc_tui_layout.Side _ -> true
    | Masc_tui_layout.Stacked -> false
  in
  Alcotest.(check bool) "a split pane that holds both columns" true
    (beside (board_read_arrangement Board_read_split ~cols:side_cols ~has_comments:true));
  Alcotest.(check bool) "a split pane one cell short stacks" false
    (beside (board_read_arrangement Board_read_split ~cols:(side_cols - 1) ~has_comments:true));
  Alcotest.(check bool) "a post without comments has no column to place" false
    (beside (board_read_arrangement Board_read_split ~cols:side_cols ~has_comments:false));
  for cols = 1 to Masc_tui_roster_pane.threshold_cols - 1 do
    if beside (board_read_arrangement Board_read_one_pane ~cols ~has_comments:true) then
      Alcotest.failf "one pane of %d columns put the thread beside the post" cols
  done

(* [z] changes which layout draws; where the reader stands in the post and in
   the thread stays as stored, for the next frame to measure. *)
let test_z_keeps_the_stored_place () =
  let state = create_state ~workspace:"" ~port:0 () in
  let split_cols = Masc_tui_roster_pane.threshold_cols in
  state.board_mode <- Board_read "p1";
  state.board_scroll <- 7;
  state.board_comment_scroll <- 11;
  state.board_focus <- Left_pane;
  toggle_board_read_wide state ~cols:split_cols;
  Alcotest.(check bool) "z hides the list" true state.board_detail_wide;
  Alcotest.(check bool) "the open post takes the keys" true (state.board_focus = Right_pane);
  Alcotest.(check (pair int int)) "z keeps the post and thread place" (7, 11)
    (state.board_scroll, state.board_comment_scroll);
  toggle_board_read_wide state ~cols:split_cols;
  Alcotest.(check bool) "z gives the list back" false state.board_detail_wide;
  Alcotest.(check (pair int int)) "and still keeps the place" (7, 11)
    (state.board_scroll, state.board_comment_scroll);
  toggle_board_read_wide state ~cols:(split_cols - 1);
  Alcotest.(check bool) "on one pane z leaves no flag for the next widening" false
    state.board_detail_wide

let () = Alcotest.run "Board document layout"
  ["scroll and refresh", [
    Alcotest.test_case "128 comments scroll without re-layout" `Quick test_long_thread_scroll_reuses_rows;
    Alcotest.test_case "every live layout input invalidates" `Quick test_live_inputs_replace_rows;
    Alcotest.test_case "failed rendering and one document ownership" `Quick test_failed_render_and_single_document;
    Alcotest.test_case "keys follow the pane the layout draws" `Quick test_focus_follows_the_layout;
    Alcotest.test_case "leaving the acting pane keeps a choice the layout hides" `Quick
      test_leaving_the_acting_pane_keeps_a_choice_the_layout_hides;
    Alcotest.test_case "paging uses the window the frame drew" `Quick
      test_paging_uses_the_window_the_frame_drew];
   "z and the thread", [
    Alcotest.test_case "z never narrows the thread" `Quick test_z_never_narrows_the_thread;
    Alcotest.test_case "the split keeps the thread beside the post" `Quick
      test_the_split_keeps_the_thread_beside_the_post;
    Alcotest.test_case "z keeps the stored place" `Quick test_z_keeps_the_stored_place]]

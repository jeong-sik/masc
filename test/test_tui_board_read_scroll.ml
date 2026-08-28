open Alcotest

module Detail = Masc_tui_board_detail
module Schedule = Masc_tui_render_schedule

(* The Board read pane measures its comment section from the detail view:
   Ready renders one line per comment (or more), while the Loading, Absent,
   and Failed projections render a single placeholder line. This mirrors
   [board_read_pane]'s data flow -- view, line count, scroll projection --
   closely enough to judge what a refresh tick does to the reader's scroll,
   without linking the pane out of the executable. *)
let comment_line_count = function
  | Detail.Ready comments -> List.length comments
  | Detail.Absent | Detail.Loading | Detail.Failed _ -> 1

let project_view_scroll view ~terminal_rows ~body_line_count scroll =
  let comment_count = comment_line_count view in
  let allocation =
    Schedule.allocate_board_read ~terminal_rows ~body_line_count
      ~comment_count
  in
  Schedule.project_board_read_scroll ~body_line_count
    ~body_rows:allocation.body_rows ~comment_count
    ~comment_rows:allocation.comment_rows scroll

let started = function
  | Detail.Started (state, request) -> state, request
  | Detail.Already_loading -> fail "expected a new Board detail request"

let test_refresh_tick_does_not_clamp_board_read_scroll () =
  let terminal_rows = 14 and body_line_count = 3 in
  let loading, request1 = Detail.start Detail.initial ~post_id:"A" |> started in
  let ready =
    Detail.complete loading request1
      (Ok [ "c1"; "c2"; "c3"; "c4"; "c5" ])
  in
  (* The reader has scrolled as far as the real comment section allows. *)
  let ready_view = Detail.view_for ready ~post_id:"A" in
  let deep =
    (project_view_scroll ready_view ~terminal_rows ~body_line_count max_int)
      .normalized_scroll
  in
  check bool "five comments give the reader somewhere to scroll to" true
    (deep > 0);
  (* The mechanism the bug ran through: a Loading frame measures one
     placeholder line, so the same scroll is clamped down -- and the pane
     writes the clamped value back over the reader's position. *)
  let collapsed =
    (project_view_scroll Detail.Loading ~terminal_rows ~body_line_count deep)
      .normalized_scroll
  in
  check bool "the loading placeholder collapses the scroll window" true
    (collapsed < deep);
  (* The fix: a refresh tick revalidates the post already shown, and the view
     keeps the last good detail, so the frame's scroll projection leaves the
     reader's position alone. *)
  let refreshing =
    match Detail.start ready ~post_id:"A" with
    | Detail.Started (state, _request) -> state
    | Detail.Already_loading -> fail "revalidation was suppressed"
  in
  let refreshing_view = Detail.view_for refreshing ~post_id:"A" in
  let preserved =
    (project_view_scroll refreshing_view ~terminal_rows ~body_line_count deep)
      .normalized_scroll
  in
  check int "a refresh tick preserves the reader's scroll" deep preserved

let () =
  run "tui_board_read_scroll"
    [ ( "board read scroll"
      , [ test_case "refresh tick preserves scroll" `Quick
            test_refresh_tick_does_not_clamp_board_read_scroll
        ] )
    ]

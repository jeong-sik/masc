open Alcotest
open Masc_tui_types
module Detail = Masc_tui_board_detail

let post ?successor id =
  { bp_id=id; bp_author="author"; bp_title="Thread";
    bp_body="masc://board/body-reference-is-not-a-successor";
    bp_votes=0; bp_comment_count=0; bp_created_at="2026-10-18";
    bp_created_at_unix=None; bp_updated_at=None; bp_hearth=None; bp_kind=None;
    bp_closed=Some {bpc_closed_by="closer";bpc_closed_at=None;
      bpc_successor_id=successor;bpc_summary=None}; bp_attachments=[] }

let state posts =
  let state = create_state ~workspace:"board-successor-test" ~port:8935 ~refresh_interval:2. () in
  state.view <- Board;
  state.board_mode <- Board_read "A";
  ignore (apply_board_posts_load state {bpr_query=board_query state;bpr_result=Ok posts});
  state

let check_target label expected state =
  check (option (pair string string)) label expected (board_successor state)

let test_metadata_owns_target () =
  check_target "body cannot invent successor" None (state [post "A"]);
  let exact = "post / + 한국어" in
  check_target "keep exact typed identifier" (Some ("A", exact))
    (state [post ~successor:exact "A"]);
  check_target "self pointer does not navigate" None (state [post ~successor:"A" "A"]);
  check_target "blank pointer does not navigate" None (state [post ~successor:" " "A"])

let test_open_post_owns_target () =
  let state = state [post ~successor:"C" "B"; post ~successor:"D" "A"] in
  state.board_cursor <- 0;
  check_target "list cursor cannot redirect open post" (Some ("A","D")) state;
  state.board_mode <- Board_list;
  check_target "list has no open successor action" None state

let test_detail_scope_owns_target () =
  let state = state [post ~successor:"old" "A"] in
  let loading, request = match Detail.start state.board_detail ~post_id:"A" with
    | Started (detail, request) -> detail, request
    | Already_loading -> fail "unexpected pending request" in
  state.board_detail <- Detail.complete loading request
      (Ok (post ~successor:"new" "A",[],None));
  check_target "current detail replaces list metadata" (Some ("A","new")) state;
  let loading, request = match Detail.start (Detail.clear state.board_detail) ~post_id:"A" with
    | Started (detail, request) -> detail, request
    | Already_loading -> fail "unexpected pending request" in
  state.board_detail <- Detail.complete loading request
      (Ok (post ~successor:"wrong" "B",[],None));
  check_target "different returned post cannot redirect" None state

let test_close_time_boundary () =
  List.iter (fun at ->
    check bool "calendar rejects invalid source value" true
      (Result.is_error (Masc_tui_board_read_layout.close_time at)))
    [nan; infinity; neg_infinity; 1e30; -1e30];
  List.iter (fun at ->
    check bool "supported calendar value remains readable" true
      (Result.is_ok (Masc_tui_board_read_layout.close_time at)))
    [0.; -1.; 1792332000.]

let () = run "board successor ownership"
  ["target", [test_case "metadata" `Quick test_metadata_owns_target;
              test_case "open post" `Quick test_open_post_owns_target;
              test_case "detail scope" `Quick test_detail_scope_owns_target;
              test_case "calendar boundary" `Quick test_close_time_boundary]]

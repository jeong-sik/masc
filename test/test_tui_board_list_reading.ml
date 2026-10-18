(** Board list availability, independent ownership and selection continuity. *)
open Masc_tui_types

let state () = create_state ~workspace:"test" ~local_base_path:"/workspace/board-list"
    ~port:0 ~refresh_interval:0. ()

let post id : board_post =
  {bp_id=id;bp_author="author";bp_title=id;bp_body="body";bp_votes=0;bp_comment_count=0;
   bp_created_at="2026-10-19";bp_created_at_unix=None;bp_updated_at=None;
   bp_hearth=None;bp_kind=None;bp_closed=None;bp_attachments=[]}

let dispatch state =
  let reads,request=Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
    ~needs:{nothing with needs_board=true} ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;request

(* Workspace/refresh admission has separate scenarios. These exercise the
   original opaque dataset owner and production snapshot transition. *)
let deliver state request result =
  let reads,accepted=Surface_read_order.take_dataset state.http_surface_reads request Surface_read_order.Board_posts in
  state.http_surface_reads <- reads;
  if accepted then apply_board_posts_load state result;
  accepted

let test_initial_loading_empty_and_failure_are_distinct () =
  let fresh=state () in
  Alcotest.(check bool) "unread has no observation" true
    (board_posts_reading fresh=(Masc_tui_fetched.Absent,false));
  List.iter (fun result ->
    let current=state () in
    let request=dispatch current in
    Alcotest.(check bool) "initial owner projects loading without an empty result" true
      (board_posts_reading current=(Masc_tui_fetched.Loading,true));
    Alcotest.(check bool) "owned result is admitted once" true (deliver current request result);
    Alcotest.(check bool) "census remains pending independently after posts settle" true
      (Surface_read_order.pending_dataset current.http_surface_reads Surface_read_order.Board_hearths
       && not (Surface_read_order.pending_dataset current.http_surface_reads Surface_read_order.Board_posts));
    (match result with
     | Ok rows -> Alcotest.(check bool) "received empty is a real successful observation" true
         (board_posts_reading current=(Masc_tui_fetched.Ready rows,false)
          && board_listing_error current=None)
     | Error detail -> Alcotest.(check bool) "first failure has no invented empty observation" true
         (board_posts_reading current=(Masc_tui_fetched.Failed detail,false)
          && board_listing_error current=Some detail));
    Alcotest.(check bool) "duplicate cannot replace the settled dataset" false
      (deliver current request (Ok [post "late"]))) [Ok [];Error "network unavailable"]

let test_retained_rows_detail_receipt_and_selection_keep_their_meaning () =
  let current=state () in
  let a=post "a" and b=post "b" and c=post "c" in
  apply_board_posts_load current (Ok [a;b]);
  current.board_cursor <- 1;
  current.board_mode <- Board_compose;
  Buffer.add_string current.board_draft "unsent draft";
  current.board_compose_reply_to <- Some "original-thread";
  let request=dispatch current in
  Alcotest.(check bool) "reread retains rows and pending ownership" true
    (board_posts_reading current=(Masc_tui_fetched.Ready [a;b],true));
  Alcotest.(check bool) "failed owned reread settles" true
    (deliver current request (Error "network unavailable"));
  Alcotest.(check bool) "failure retains selection and compose input with its diagnostic" true
    (board_posts_reading current=(Masc_tui_fetched.Stale ([a;b],"network unavailable"),false)
     && current.board_cursor=1 && current.board_mode=Board_compose
     && Buffer.contents current.board_draft="unsent draft"
     && current.board_compose_reply_to=Some "original-thread");
  let retry=dispatch current in
  current.board_mode <- Board_read "a";
  let updated={a with bp_body="detail body"} in
  enrich_board_list_post current updated;
  Alcotest.(check bool) "detail cannot clear list failure or pending ownership" true
    (board_posts_reading current=(Masc_tui_fetched.Stale ([updated;b],"network unavailable"),true)
     && current.board_cursor=1 && current.board_mode=Board_read "a");
  Alcotest.(check bool) "list replacement reconciles open detail identity" true
    (deliver current retry (Ok [updated;c;b]) && current.board_cursor=0);
  current.board_mode <- Board_list;
  let next=dispatch current in
  Alcotest.(check bool) "selected identity survives reordering" true
    (deliver current next (Ok [b;updated]) && current.board_cursor=1
     && board_listing_error current=None && board_posts current=[b;updated]
     && Buffer.contents current.board_draft="unsent draft")

let test_missing_result_old_cleanup_and_workspace_withdrawal () =
  let current=state () in
  let a=post "a" in
  apply_board_posts_load current (Ok [a]);
  let old=dispatch current in
  let latest=dispatch current in
  finish_http_surface_read current old;
  Alcotest.(check bool) "old cleanup cannot mark successor unavailable" true
    (board_posts_reading current=(Masc_tui_fetched.Ready [a],true)
     && not (deliver current old (Ok [post "old"])));
  let datasets=take_http_surface_datasets current latest in
  Alcotest.(check bool) "unapplied terminal reservation retains rows as unavailable" true
    (List.mem Surface_read_order.Board_posts datasets
     && match board_posts_reading current with
        | Masc_tui_fetched.Stale ([retained],_),false -> retained=a
        | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> false);
  apply_board_posts_load current (Ok []);
  finish_http_surface_read current latest;
  Alcotest.(check bool) "actual terminal empty restores received availability" true
    (board_posts_reading current=(Masc_tui_fetched.Ready [],false));
  let unfinished=dispatch current in
  finish_http_surface_read current unfinished;
  Alcotest.(check bool) "missing result after empty remains unavailable" true
    (match board_posts_reading current with
     | Masc_tui_fetched.Stale ([],_),false -> true
     | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> false);
  let retired=dispatch current in
  suspend_workspace_readings current;
  finish_http_surface_read current retired;
  Alcotest.(check bool) "withdrawal clears candidates and rejects old results" true
    (board_posts_reading current=(Masc_tui_fetched.Absent,false)
     && board_posts current=[] && not (deliver current retired (Ok [a])))

let () = Alcotest.run "tui_board_list_reading"
  ["availability and continuity",
   [Alcotest.test_case "initial loading empty and failure" `Quick test_initial_loading_empty_and_failure_are_distinct;
    Alcotest.test_case "retained rows detail receipt and selected identity" `Quick
      test_retained_rows_detail_receipt_and_selection_keep_their_meaning;
    Alcotest.test_case "missing result successor and workspace ownership" `Quick
      test_missing_result_old_cleanup_and_workspace_withdrawal]]

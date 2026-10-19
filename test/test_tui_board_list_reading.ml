(** Board list availability, independent ownership and selection continuity. *)
open Masc_tui_types

let initial_query={bq_sort=Board_hot;bq_hearth=None}
let snapshot rows={bl_query=initial_query;bl_posts=rows}
let receipt result={bpr_query=initial_query;bpr_result=result}

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
let observe_delivery state request reading =
  let reads,accepted=Surface_read_order.take_dataset state.http_surface_reads request Surface_read_order.Board_posts in
  state.http_surface_reads <- reads;
  if accepted then Some (apply_board_posts_load state reading) else None

let deliver_receipt state request reading = Option.is_some (observe_delivery state request reading)

let deliver state request result = deliver_receipt state request (receipt result)

let test_initial_loading_empty_and_failure_are_distinct () =
  let fresh=state () in
  Alcotest.(check bool) "unread has no observation" true
    (board_posts_reading fresh=(Masc_tui_fetched.Absent,false));
  List.iter (fun result ->
    let current=state () in
    let request=dispatch current in
    Alcotest.(check bool) "initial owner projects loading without an empty result" true
      (board_posts_reading current=(Masc_tui_fetched.Loading,true));
    let application=match observe_delivery current request (receipt result) with
      | Some application -> application | None -> Alcotest.fail "initial result not owned" in
    Alcotest.(check bool) "owned application captures current request controls" true
      (application.bpa_requested_query=initial_query);
    Alcotest.(check bool) "census remains pending independently after posts settle" true
      (Surface_read_order.pending_dataset current.http_surface_reads Surface_read_order.Board_hearths
       && not (Surface_read_order.pending_dataset current.http_surface_reads Surface_read_order.Board_posts));
    (match result with
     | Ok rows -> Alcotest.(check bool) "received empty is a real successful observation" true
         (board_posts_reading current=(Masc_tui_fetched.Ready (snapshot rows),false)
          && board_listing_error current=None
          && application.bpa_delivery=Board_posts_received initial_query
          && application.bpa_listing_query=Some initial_query)
     | Error detail -> Alcotest.(check bool) "first failure has no invented empty observation" true
         (board_posts_reading current=(Masc_tui_fetched.Failed detail,false)
          && board_listing_error current=Some detail
          && application.bpa_delivery=Board_posts_failed initial_query
          && application.bpa_listing_query=None));
    Alcotest.(check bool) "duplicate cannot replace the settled dataset" false
      (deliver current request (Ok [post "late"]))) [Ok [];Error "network unavailable"]

let test_retained_rows_detail_receipt_and_selection_keep_their_meaning () =
  let current=state () in
  let a=post "a" and b=post "b" and c=post "c" in
  ignore (apply_board_posts_load current (receipt (Ok [a;b])));
  current.board_cursor <- 1;
  current.board_mode <- Board_compose;
  Buffer.add_string current.board_draft "unsent draft";
  current.board_compose_reply_to <- Some "original-thread";
  let request=dispatch current in
  Alcotest.(check bool) "reread retains rows and pending ownership" true
    (board_posts_reading current=(Masc_tui_fetched.Ready (snapshot [a;b]),true));
  Alcotest.(check bool) "failed owned reread settles" true
    (deliver current request (Error "network unavailable"));
  Alcotest.(check bool) "failure retains selection and compose input with its diagnostic" true
    (board_posts_reading current=(Masc_tui_fetched.Stale (snapshot [a;b],"network unavailable"),false)
     && current.board_cursor=1 && current.board_mode=Board_compose
     && Buffer.contents current.board_draft="unsent draft"
     && current.board_compose_reply_to=Some "original-thread");
  let retry=dispatch current in
  current.board_mode <- Board_read "a";
  let updated={a with bp_body="detail body"} in
  enrich_board_list_post current updated;
  Alcotest.(check bool) "detail cannot clear list failure or pending ownership" true
    (board_posts_reading current=(Masc_tui_fetched.Stale (snapshot [updated;b],"network unavailable"),true)
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
  ignore (apply_board_posts_load current (receipt (Ok [a])));
  let old=dispatch current in
  let latest=dispatch current in
  finish_http_surface_read current old;
  Alcotest.(check bool) "old cleanup cannot mark successor unavailable" true
    (board_posts_reading current=(Masc_tui_fetched.Ready (snapshot [a]),true)
     && not (deliver current old (Ok [post "old"])));
  let datasets=take_http_surface_datasets current latest in
  Alcotest.(check bool) "unapplied terminal reservation retains rows as unavailable" true
    (List.mem Surface_read_order.Board_posts datasets
     && match board_posts_reading current with
        | Masc_tui_fetched.Stale (retained,_),false -> retained=snapshot [a]
        | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> false);
  ignore (apply_board_posts_load current (receipt (Ok [])));
  finish_http_surface_read current latest;
  Alcotest.(check bool) "actual terminal empty restores received availability" true
    (board_posts_reading current=(Masc_tui_fetched.Ready (snapshot []),false));
  let unfinished=dispatch current in
  finish_http_surface_read current unfinished;
  Alcotest.(check bool) "missing result after empty remains unavailable" true
    (match board_posts_reading current with
     | Masc_tui_fetched.Stale (retained,_),false -> retained=snapshot []
     | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> false);
  let retired=dispatch current in
  suspend_workspace_readings current;
  finish_http_surface_read current retired;
  Alcotest.(check bool) "withdrawal clears candidates and rejects old results" true
    (board_posts_reading current=(Masc_tui_fetched.Absent,false)
     && board_posts current=[] && not (deliver current retired (Ok [a])))


(* The response is captured before controls move. Neither early nor terminal
   delivery may reconstruct its origin from those controls. Source inspection
   separately covers the private producer and application entry points. *)
let test_query_change_keeps_origin_detail_draft_and_empty_result () =
  let current=state () in
  let original={bq_sort=Board_recent;bq_hearth=Some "alpha"} in
  current.board_sort <- original.bq_sort;current.board_hearth <- original.bq_hearth;
  let first=dispatch current in
  let a=post "a" and b=post "b" in
  let captured={bpr_query=board_query current;bpr_result=Ok [a;b]} in
  current.board_sort <- Board_updated;current.board_hearth <- Some "beta";
  let wanted=board_query current in
  let first_application=match observe_delivery current first captured with
    | Some application -> application | None -> Alcotest.fail "initial posts not owned" in
  Alcotest.(check bool) "early receipt settles its posts slot with its original query" true
    (first_application.bpa_delivery=Board_posts_received original
     && first_application.bpa_requested_query=wanted && first_application.bpa_listing_query=Some original
     && board_posts_query current=original && not (board_listing_matches_requested current)
     && board_sort_time (board_posts_query current).bq_sort=Board_time_posted);
  let reads,taken=Surface_read_order.take_dataset current.http_surface_reads first Surface_read_order.Board_hearths in
  current.http_surface_reads <- reads;
  if not taken then Alcotest.fail "census was not independently owned";
  apply_board_census_load current (Ok ["alpha",7;"beta",2]);
  Alcotest.(check bool) "list total uses the observed hearth, independently of the requested one" true
    (board_census_holding current ~hearth:(board_posts_query current).bq_hearth=Some 7
     && board_census_holding current ~hearth:current.board_hearth=Some 2);
  current.board_cursor <- 1;current.board_mode <- Board_compose;
  Buffer.add_string current.board_draft "keep original draft";
  let reread=dispatch current in
  let failure={bpr_query=wanted;bpr_result=Error "new query failed"} in
  current.board_sort <- Board_trending;current.board_hearth <- Some "third";
  let requested_at_failure=board_query current in
  let failed_application=match observe_delivery current reread failure with
    | Some application -> application | None -> Alcotest.fail "replacement posts not owned" in
  Alcotest.(check bool) "failure keeps delivered, requested and retained queries distinct" true
    (failed_application.bpa_delivery=Board_posts_failed wanted
     && failed_application.bpa_requested_query=requested_at_failure
     && failed_application.bpa_listing_query=Some original
     && board_posts_query current=original && board_posts current=[a;b]
     && not (board_listing_matches_requested current) && current.board_cursor=1);
  current.board_sort <- wanted.bq_sort;current.board_hearth <- wanted.bq_hearth;
  let retry=dispatch current in
  current.board_mode <- Board_read "b";
  enrich_board_list_post current {b with bp_body="detail enriched"};
  Alcotest.(check bool) "detail preserves query, failed list, pending owner and compose input" true
    (board_posts_query current=original && board_listing_error current=Some "new query failed"
     && Surface_read_order.pending_dataset current.http_surface_reads Surface_read_order.Board_posts
     && Buffer.contents current.board_draft="keep original draft");
  let empty_application=match observe_delivery current retry {bpr_query=wanted;bpr_result=Ok []} with
    | Some application -> application | None -> Alcotest.fail "empty replacement not owned" in
  Alcotest.(check bool) "empty replacement updates its observation without rewriting earlier failure" true
    (empty_application.bpa_delivery=Board_posts_received wanted
     && empty_application.bpa_listing_query=Some wanted
     && failed_application.bpa_delivery=Board_posts_failed wanted
     && failed_application.bpa_requested_query=requested_at_failure
     && failed_application.bpa_listing_query=Some original
     && first_application.bpa_requested_query=wanted
     && first_application.bpa_listing_query=Some original
     && board_posts_query current=wanted && board_listing_matches_requested current
     && board_posts current=[] && current.board_mode=Board_read "b"
     && board_sort_time (board_posts_query current).bq_sort=Board_time_changed
     && Buffer.contents current.board_draft="keep original draft")

let test_superseded_query_and_terminal_fallback_keep_original_owner () =
  let current=state () in
  let reads,old=Surface_read_order.dispatch ~kind:Surface_read_order.Full
    ~needs:{nothing with needs_board=true} ~started_ns:0L current.http_surface_reads in
  current.http_surface_reads <- reads;
  let older={bpr_query=board_query current;bpr_result=Ok [post "older"]} in
  current.board_sort <- Board_discussed;current.board_hearth <- Some "new";
  let latest=dispatch current in
  let newer={bpr_query=board_query current;bpr_result=Ok [post "newer"]} in
  current.board_sort <- Board_trending;current.board_hearth <- None;
  Alcotest.(check bool) "superseded delivery has no application observation" true
    (observe_delivery current old older=None);
  let old_datasets=take_http_surface_datasets current old in
  finish_http_surface_read current old;
  Alcotest.(check bool) "superseded terminal bundle cannot take successor posts" true
    (not (List.mem Surface_read_order.Board_posts old_datasets)
     && Surface_read_order.owns_dataset current.http_surface_reads latest Surface_read_order.Board_posts);
  let remaining=take_http_surface_datasets current latest in
  let application=if List.mem Surface_read_order.Board_posts remaining then
      Some (apply_board_posts_load current newer) else None in
  finish_http_surface_read current latest;
  Alcotest.(check bool) "terminal fallback preserves captured origin despite later controls" true
    (Option.fold ~none:false ~some:(fun observation ->
       observation.bpa_delivery=Board_posts_received newer.bpr_query
       && observation.bpa_requested_query=board_query current
       && observation.bpa_listing_query=Some newer.bpr_query) application
     && board_posts_query current=newer.bpr_query && board_posts current=[post "newer"]
     && not (board_listing_matches_requested current)
     && not (deliver_receipt current latest older));
  current.board_sort <- newer.bpr_query.bq_sort;current.board_hearth <- newer.bpr_query.bq_hearth;
  Alcotest.(check bool) "returning to the observed query can reuse the same receipt" true
    (board_listing_matches_requested current)

let test_empty_query_origin_survives_missing_result_and_is_withdrawn () =
  let current=state () in
  current.board_hearth <- Some "empty-origin";
  let original=board_query current in
  ignore (apply_board_posts_load current {bpr_query=original;bpr_result=Ok []});
  current.board_hearth <- Some "other";
  let missing=dispatch current in
  let remaining=take_http_surface_datasets current missing in
  let missing_application=if List.mem Surface_read_order.Board_posts remaining then
      Some (observe_board_posts_application current Board_posts_missing) else None in
  finish_http_surface_read current missing;
  Alcotest.(check bool) "owned missing data has no invented delivery query and retains empty origin" true
    (Option.fold ~none:false ~some:(fun application ->
       application.bpa_delivery=Board_posts_missing
       && application.bpa_requested_query=board_query current
       && application.bpa_listing_query=Some original) missing_application
     && board_posts_snapshot current=Some {bl_query=original;bl_posts=[]}
     && not (board_listing_matches_requested current) && Option.is_some (board_listing_error current));
  let retired=dispatch current in
  suspend_workspace_readings current;
  finish_http_surface_read current retired;
  Alcotest.(check bool) "withdrawal removes origin and produces no observation for a retired receipt" true
    (board_posts_snapshot current=None && board_posts current=[]
     && observe_delivery current retired {bpr_query=original;bpr_result=Ok [post "late"]}=None
     && Option.fold ~none:false ~some:(fun application -> application.bpa_listing_query=Some original)
       missing_application)

let () = Alcotest.run "tui_board_list_reading"
  ["availability and continuity",
   [Alcotest.test_case "initial loading empty and failure" `Quick test_initial_loading_empty_and_failure_are_distinct;
    Alcotest.test_case "retained rows detail receipt and selected identity" `Quick
      test_retained_rows_detail_receipt_and_selection_keep_their_meaning;
    Alcotest.test_case "missing result successor and workspace ownership" `Quick
      test_missing_result_old_cleanup_and_workspace_withdrawal;
    Alcotest.test_case "query origin detail draft and empty receipt" `Quick
      test_query_change_keeps_origin_detail_draft_and_empty_result;
    Alcotest.test_case "superseded query and owned terminal fallback" `Quick
      test_superseded_query_and_terminal_fallback_keep_original_owner;
    Alcotest.test_case "empty query missing result and withdrawal" `Quick
      test_empty_query_origin_survives_missing_result_and_is_withdrawn]]

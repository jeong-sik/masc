(** Unit tests for Board_sort — the extracted Hot/Trending ranking SSOT. *)

open Masc
module Board_sort = Masc_board_handlers.Board_sort

let post_id_exn s =
  match Board.Post_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid post_id fixture: %s" s)

let agent_id_exn s =
  match Board.Agent_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid agent_id fixture: %s" s)

(** Minimal fixture post. [votes_up]/[votes_down]/[reply_count]/[created_at]
    are the only fields Board_sort's formulas read; everything else is a
    fixed placeholder. *)
let make_post ~id ~created_at ~votes_up ~votes_down ~reply_count () : Board.post =
  { id = post_id_exn id
  ; author = agent_id_exn "sort-test-author"
  ; title = ""
  ; body = "fixture"
  ; post_kind = Board.Human_post
  ; meta_json = None
  ; visibility = Board.Public
  ; audience = None
  ; created_at
  ; content_updated_at = created_at
  ; updated_at = created_at
  ; expires_at = created_at +. (30.0 *. Masc_time_constants.day)
  ; votes_up
  ; votes_down
  ; reply_count
  ; pinned = false
  ; hearth = None
  ; thread_id = None
  ; origin = None
  ; closed = None
  }

(* Regression for the pre-Board_sort formula ((net + reply_count * 2) /
   sqrt(age)), which let a heavily-downvoted, high-reply post outrank a
   cleanly upvoted, low-reply post of the same age (e.g. net -98 with 80
   replies beat net +40 with 0 replies). Trending must rank on net vote
   only. *)
let test_trending_ranks_net_vote_not_reply_count () =
  let now = 1_000_000.0 in
  let hour = Masc_time_constants.hour in
  let downvoted_high_reply =
    make_post ~id:"p-downvoted" ~created_at:(now -. hour) ~votes_up:1 ~votes_down:99
      ~reply_count:80 ()
  in
  let upvoted_low_reply =
    make_post ~id:"p-upvoted" ~created_at:(now -. hour) ~votes_up:40 ~votes_down:0
      ~reply_count:0 ()
  in
  let sorted =
    List.sort (Board_sort.trending_compare ~now) [ downvoted_high_reply; upvoted_low_reply ]
  in
  Alcotest.(check string)
    "upvoted low-reply post ranks first despite fewer replies"
    "p-upvoted"
    (Board.Post_id.to_string (List.hd sorted).id)

let test_trending_tiebreaks_on_created_at_desc () =
  let now = 1_000_000.0 in
  let hour = Masc_time_constants.hour in
  (* net_vote / sqrt(age_hours) ties at 5.0 for both (10/sqrt(4) = 5/sqrt(1) = 5.0)
     despite different ages and net votes; only created_at should distinguish
     the order. *)
  let older = make_post ~id:"p-older" ~created_at:(now -. (4.0 *. hour)) ~votes_up:10
      ~votes_down:0 ~reply_count:0 ()
  in
  let newer = make_post ~id:"p-newer" ~created_at:(now -. hour) ~votes_up:5 ~votes_down:0
      ~reply_count:3 ()
  in
  Alcotest.(check bool)
    "fixture actually ties on trending_score (else this isn't testing the tiebreak)"
    true
    (Board_sort.trending_score ~now older = Board_sort.trending_score ~now newer);
  let sorted = List.sort (Board_sort.trending_compare ~now) [ older; newer ] in
  Alcotest.(check string)
    "newer post wins the tiebreak"
    "p-newer"
    (Board.Post_id.to_string (List.hd sorted).id)

let test_hot_post_set_matches_hot_compare () =
  let now = 1_000_000.0 in
  let p_high =
    make_post ~id:"p-high" ~created_at:(now -. 100.0) ~votes_up:10 ~votes_down:2
      ~reply_count:0 ()
  in
  let p_tie_newer =
    make_post ~id:"p-tie-b" ~created_at:(now -. 10.0) ~votes_up:5 ~votes_down:0
      ~reply_count:0 ()
  in
  let p_tie_older_a =
    make_post ~id:"p-tie-a" ~created_at:(now -. 50.0) ~votes_up:5 ~votes_down:0
      ~reply_count:10 ()
  in
  let p_tie_older_b =
    make_post ~id:"p-tie-c" ~created_at:(now -. 50.0) ~votes_up:5 ~votes_down:0
      ~reply_count:1 ()
  in
  let posts = [ p_tie_older_b; p_high; p_tie_older_a; p_tie_newer ] in
  let sorted_ids =
    List.sort Board_sort.hot_compare posts
    |> List.map (fun (p : Board.post) -> Board.Post_id.to_string p.id)
  in
  let index_ids =
    List.fold_left
      (fun acc (p : Board.post) ->
        Board.Hot_post_set.add (Board.hot_post_key_of_post p) acc)
      Board.Hot_post_set.empty
      posts
    |> Board.Hot_post_set.to_seq
    |> List.of_seq
    |> List.map (fun (k : Board.hot_post_key) -> k.post_id)
  in
  Alcotest.(check (list string))
    "Hot_post_set order matches hot_compare total order"
    [ "p-high"; "p-tie-b"; "p-tie-a"; "p-tie-c" ]
    sorted_ids;
  Alcotest.(check (list string))
    "Hot_post_set sequence equals sorted_ids"
    sorted_ids
    index_ids;
  let recent_ids =
    List.fold_left
      (fun acc (p : Board.post) ->
        Board.Recent_post_set.add (Board.recent_post_key_of_post p) acc)
      Board.Recent_post_set.empty
      posts
    |> Board.Recent_post_set.to_seq
    |> List.of_seq
    |> List.map (fun (k : Board.recent_post_key) -> k.recent_post_id)
  in
  Alcotest.(check (list string))
    "Recent_post_set orders created_at desc then post_id asc"
    [ "p-tie-b"; "p-tie-a"; "p-tie-c"; "p-high" ]
    recent_ids

let () =
  Alcotest.run "Board_sort"
    [ ( "trending"
      , [ Alcotest.test_case "ranks net vote, not reply count" `Quick
            test_trending_ranks_net_vote_not_reply_count
        ; Alcotest.test_case "tiebreaks on created_at desc" `Quick
            test_trending_tiebreaks_on_created_at_desc
        ; Alcotest.test_case "Hot_post_set matches hot_compare total order" `Quick
            test_hot_post_set_matches_hot_compare
        ] )
    ]

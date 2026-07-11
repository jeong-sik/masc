(** Unit tests for Board_sort — the extracted Hot/Best ranking SSOT. *)

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
  ; content = "fixture"
  ; post_kind = Board.Human_post
  ; meta_json = None
  ; visibility = Board.Public
  ; created_at
  ; updated_at = created_at
  ; expires_at = created_at +. (30.0 *. Masc_time_constants.day)
  ; votes_up
  ; votes_down
  ; reply_count
  ; pinned = false
  ; hearth = None
  ; thread_id = None
  ; origin = None
  }

(* Hot's time-decay term (see Board_sort.hot_score) is what let the old
   Trending sort surface newer, lower-vote posts ahead of older,
   higher-vote ones — a raw net-vote Hot (pre-#58) could not do this.
   Post B has 1/10th the net vote of Post A but is one full decay window
   (hot_decay_seconds) newer, which exactly cancels the log10(10) = 1.0
   vote-order gap, so B ties A on score and then wins the tiebreak. *)
let test_hot_score_decays_newer_lower_vote_ties_older_higher_vote () =
  let older =
    make_post ~id:"p-older" ~created_at:Board_sort.hot_epoch_seconds
      ~votes_up:10 ~votes_down:0 ~reply_count:0 ()
  in
  let newer =
    make_post ~id:"p-newer"
      ~created_at:(Board_sort.hot_epoch_seconds +. Board_sort.hot_decay_seconds)
      ~votes_up:1 ~votes_down:0 ~reply_count:0 ()
  in
  Alcotest.(check bool)
    "fixture actually ties on hot_score (else this isn't testing decay)"
    true
    (Stdlib.Float.equal (Board_sort.hot_score older) (Board_sort.hot_score newer));
  let sorted = List.sort Board_sort.hot_compare [ older; newer ] in
  Alcotest.(check string)
    "newer, lower-vote post wins the tie via decay + created_at tiebreak"
    "p-newer"
    (Board.Post_id.to_string (List.hd sorted).id)

let test_hot_score_downvote_heavy_ranks_below_upvoted () =
  let now = Board_sort.hot_epoch_seconds +. (100.0 *. Board_sort.hot_decay_seconds) in
  let downvoted = make_post ~id:"p-downvoted" ~created_at:now ~votes_up:1 ~votes_down:99
      ~reply_count:80 ()
  in
  let upvoted = make_post ~id:"p-upvoted" ~created_at:now ~votes_up:40 ~votes_down:0
      ~reply_count:0 ()
  in
  let sorted = List.sort Board_sort.hot_compare [ downvoted; upvoted ] in
  Alcotest.(check string)
    "upvoted post ranks first regardless of reply count"
    "p-upvoted"
    (Board.Post_id.to_string (List.hd sorted).id)

let test_wilson_lower_bound_zero_votes_is_zero () =
  Alcotest.(check (float 0.0)) "n=0 -> 0.0" 0.0
    (Board_sort.wilson_lower_bound ~ups:0 ~downs:0)

let test_wilson_lower_bound_all_upvotes_below_one () =
  (* n=1, ups=1: the interval lower bound must stay well below the raw
     ratio (1.0) — that gap is the entire point of using Wilson instead
     of a raw ratio for a single data point. *)
  let lb = Board_sort.wilson_lower_bound ~ups:1 ~downs:0 in
  Alcotest.(check bool) "single upvote scores far below 1.0" true (lb < 0.5)

let test_wilson_lower_bound_larger_n_same_ratio_scores_higher () =
  (* Same 90% upvote ratio at two sample sizes: the larger sample must
     score higher because its confidence interval is tighter — this is
     the exact failure mode Wilson corrects that a raw ratio (or a naive
     Beta posterior mean, see Reputation.thompson_confidence_for_agent)
     cannot: a single upvote would tie a 9/1 split under a raw-ratio
     comparison. *)
  let small_n = Board_sort.wilson_lower_bound ~ups:9 ~downs:1 in
  let large_n = Board_sort.wilson_lower_bound ~ups:90 ~downs:10 in
  Alcotest.(check bool) "n=100 at 90% scores higher than n=10 at 90%" true
    (large_n > small_n)

let test_best_compare_ranks_confidence_not_raw_net_vote () =
  (* Raw net vote (votes_up - votes_down) favors 1 upvote / 0 downvotes
     (net +1) over 98 upvotes / 2 downvotes (net +96) only if net vote
     itself were the metric being compared here — it isn't the point of
     this fixture. Pick a pair where net vote and Wilson bound actually
     disagree: 1 upvote/0 downvotes (net +1, ratio 100%, n=1) vs.
     49 upvotes/51 downvotes (net -2, ratio ~49%, n=100). Net vote ranks
     the first higher (+1 > -2); Wilson must rank the second higher
     because its huge sample size pins the bound near the true ~49%
     ratio, which safely clears the single-vote post's low-n bound. *)
  let now = Board_sort.hot_epoch_seconds in
  let single_upvote = make_post ~id:"p-single" ~created_at:now ~votes_up:1 ~votes_down:0
      ~reply_count:0 ()
  in
  let large_sample = make_post ~id:"p-large" ~created_at:now ~votes_up:49 ~votes_down:51
      ~reply_count:0 ()
  in
  Alcotest.(check bool) "net vote would (wrongly) favor the single upvote" true
    (Board_sort.net_vote single_upvote > Board_sort.net_vote large_sample);
  let sorted = List.sort Board_sort.best_compare [ single_upvote; large_sample ] in
  Alcotest.(check string)
    "Best ranks the large, evenly-split sample above the single upvote"
    "p-large"
    (Board.Post_id.to_string (List.hd sorted).id)

let test_best_compare_tiebreaks_on_created_at_desc () =
  let older = make_post ~id:"p-older" ~created_at:1_000_000.0 ~votes_up:5 ~votes_down:0
      ~reply_count:0 ()
  in
  let newer = make_post ~id:"p-newer" ~created_at:1_000_100.0 ~votes_up:5 ~votes_down:0
      ~reply_count:3 ()
  in
  let sorted = List.sort Board_sort.best_compare [ older; newer ] in
  Alcotest.(check string) "newer post wins the tiebreak on identical votes"
    "p-newer"
    (Board.Post_id.to_string (List.hd sorted).id)

let () =
  Alcotest.run "Board_sort"
    [ ( "hot"
      , [ Alcotest.test_case "decay lets a newer, lower-vote post tie an older, higher-vote one" `Quick
            test_hot_score_decays_newer_lower_vote_ties_older_higher_vote
        ; Alcotest.test_case "downvote-heavy high-reply post still ranks below upvoted" `Quick
            test_hot_score_downvote_heavy_ranks_below_upvoted
        ] )
    ; ( "wilson_lower_bound"
      , [ Alcotest.test_case "n=0 returns 0.0" `Quick
            test_wilson_lower_bound_zero_votes_is_zero
        ; Alcotest.test_case "single upvote scores far below the raw 1.0 ratio" `Quick
            test_wilson_lower_bound_all_upvotes_below_one
        ; Alcotest.test_case "larger n at the same ratio scores higher" `Quick
            test_wilson_lower_bound_larger_n_same_ratio_scores_higher
        ] )
    ; ( "best"
      , [ Alcotest.test_case "ranks confidence-weighted ratio, not raw net vote" `Quick
            test_best_compare_ranks_confidence_not_raw_net_vote
        ; Alcotest.test_case "tiebreaks on created_at desc" `Quick
            test_best_compare_tiebreaks_on_created_at_desc
        ] )
    ]

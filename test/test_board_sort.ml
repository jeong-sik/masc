(** Unit tests for Board_sort — the extracted Hot/Trending ranking SSOT. *)

open Masc

let post_id_exn s =
  match Board_types.Post_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid post_id fixture: %s" s)

let agent_id_exn s =
  match Board_types.Agent_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid agent_id fixture: %s" s)

(** Minimal fixture post. [votes_up]/[votes_down]/[reply_count]/[created_at]
    are the only fields Board_sort's formulas read; everything else is a
    fixed placeholder. *)
let make_post ~id ~created_at ~votes_up ~votes_down ~reply_count () : Board_types.post =
  { id = post_id_exn id
  ; author = agent_id_exn "sort-test-author"
  ; title = ""
  ; body = "fixture"
  ; content = "fixture"
  ; post_kind = Board_types.Human_post
  ; meta_json = None
  ; visibility = Board_types.Public
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
    (Board_types.Post_id.to_string (List.hd sorted).id)

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
    (Board_types.Post_id.to_string (List.hd sorted).id)

let () =
  Alcotest.run "Board_sort"
    [ ( "trending"
      , [ Alcotest.test_case "ranks net vote, not reply count" `Quick
            test_trending_ranks_net_vote_not_reply_count
        ; Alcotest.test_case "tiebreaks on created_at desc" `Quick
            test_trending_tiebreaks_on_created_at_desc
        ] )
    ]

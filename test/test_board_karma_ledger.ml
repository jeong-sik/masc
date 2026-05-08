(** Test Board karma ledger contract.

    Exercises the karma ledger contract defined in {!Board_votes} and
    exposed via {!Board_dispatch}: scoring rules, attribution,
    auditability via {!Board.build_karma_ledger}, and the
    rebuild/replay consistency invariant. *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

(** Fresh isolated MASC_BASE_PATH for each test *)
let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-karma-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

(** Run [f] inside an Eio runtime with an isolated JSONL board *)
let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()

(** Create a post and fail the test on error *)
let create_post_exn ~author ~content =
  match
    Board_dispatch.create_post ~author ~content ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

(** Cast a vote and fail the test on error *)
let vote_exn ~voter ~post_id ~direction =
  match Board_dispatch.vote ~voter ~post_id ~direction with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e)

(** Cast a comment vote and fail the test on error *)
let vote_comment_exn ~voter ~comment_id ~direction =
  match Board_dispatch.vote_comment ~voter ~comment_id ~direction with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e)

(** {1 Scoring contract} *)

let test_up_scores_one () =
  Alcotest.(check int) "Up → +1"
    1 (Board_dispatch.karma_score_for_direction Board.Up)

let test_down_scores_zero () =
  Alcotest.(check int) "Down → 0"
    0 (Board_dispatch.karma_score_for_direction Board.Down)

(** {1 Empty ledger} *)

let test_empty_ledger () =
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "empty store gives empty ledger" 0 (List.length events)

(** {1 Single upvote produces one event} *)

let test_upvote_produces_one_event () =
  let post = create_post_exn ~author:"alice" ~content:"hello" in
  let pid = Board.Post_id.to_string post.id in
  vote_exn ~voter:"bob" ~post_id:pid ~direction:Board.Up;
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "one upvote → one karma event" 1 (List.length events);
  let (ev : Board.karma_event) = List.hd events in
  Alcotest.(check string) "recipient is author" "alice" ev.recipient;
  Alcotest.(check string) "voter is voter" "bob" ev.voter;
  Alcotest.(check string) "target_kind is post" "post" ev.target_kind;
  Alcotest.(check string) "target_id matches post" pid ev.target_id;
  Alcotest.(check int) "delta is +1" 1 ev.delta

(** {1 Downvote does NOT produce a karma event} *)

let test_downvote_no_event () =
  let post = create_post_exn ~author:"alice" ~content:"controversial" in
  let pid = Board.Post_id.to_string post.id in
  vote_exn ~voter:"bob" ~post_id:pid ~direction:Board.Down;
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "downvote → no karma event" 0 (List.length events)

(** {1 Self-upvotes do NOT produce karma} *)

let test_self_post_upvote_no_karma () =
  let post = create_post_exn ~author:"alice" ~content:"self vote" in
  let pid = Board.Post_id.to_string post.id in
  vote_exn ~voter:" alice " ~post_id:pid ~direction:Board.Up;
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "self post upvote → no karma event" 0 (List.length events);
  Alcotest.(check int) "self post upvote excluded from agent karma" 0
    (Board_dispatch.get_agent_karma ~agent_name:"alice");
  Alcotest.(check (list (pair string int))) "self post upvote excluded from all karma"
    [] (Board_dispatch.get_all_karma ());
  match Board_dispatch.get_post ~post_id:pid with
  | Ok updated ->
      Alcotest.(check int) "self vote still affects board score" 1 updated.votes_up
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_self_post_upvote_no_economy_credit () =
  with_env "MASC_ECONOMY_ENABLED" "true" (fun () ->
    Agent_economy.reset_cache ();
    let base_path = Sys.getenv "MASC_BASE_PATH" in
    let post = create_post_exn ~author:"alice" ~content:"economy self vote" in
    let pid = Board.Post_id.to_string post.id in
    let before =
      Agent_economy.get_balance ~base_path ~agent_name:"alice"
    in
    vote_exn ~voter:" alice " ~post_id:pid ~direction:Board.Up;
    let after_self_vote =
      Agent_economy.get_balance ~base_path ~agent_name:"alice"
    in
    Alcotest.(check (float 0.0001)) "self upvote does not earn economy credit"
      before after_self_vote)

(** {1 Comment upvote produces an event} *)

let test_comment_upvote_produces_event () =
  let post = create_post_exn ~author:"alice" ~content:"parent post" in
  let pid = Board.Post_id.to_string post.id in
  let comment =
    match
      Board_dispatch.add_comment ~post_id:pid ~author:"charlie"
        ~content:"nice post" ()
    with
    | Ok c -> c
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let cid = Board.Comment_id.to_string comment.id in
  vote_comment_exn ~voter:"dave" ~comment_id:cid ~direction:Board.Up;
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "comment upvote → one karma event" 1 (List.length events);
  let (ev : Board.karma_event) = List.hd events in
  Alcotest.(check string) "recipient is comment author" "charlie" ev.recipient;
  Alcotest.(check string) "target_kind is comment" "comment" ev.target_kind;
  Alcotest.(check string) "target_id matches comment" cid ev.target_id

(** {1 Comment self-upvotes do NOT produce karma} *)

let test_self_comment_upvote_no_karma () =
  let post = create_post_exn ~author:"alice" ~content:"parent post" in
  let pid = Board.Post_id.to_string post.id in
  let comment =
    match
      Board_dispatch.add_comment ~post_id:pid ~author:"charlie"
        ~content:"self-voted comment" ()
    with
    | Ok c -> c
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let cid = Board.Comment_id.to_string comment.id in
  vote_comment_exn ~voter:" charlie " ~comment_id:cid ~direction:Board.Up;
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "self comment upvote → no karma event" 0 (List.length events);
  Alcotest.(check int) "self comment upvote excluded from agent karma" 0
    (Board_dispatch.get_agent_karma ~agent_name:"charlie")

(** {1 Multiple voters each produce distinct events} *)

let test_multiple_voters () =
  let post = create_post_exn ~author:"alice" ~content:"popular post" in
  let pid = Board.Post_id.to_string post.id in
  List.iter
    (fun voter -> vote_exn ~voter ~post_id:pid ~direction:Board.Up)
    [ "v1"; "v2"; "v3" ];
  let events = Board_dispatch.get_karma_ledger () in
  Alcotest.(check int) "3 upvotes → 3 events" 3 (List.length events);
  List.iter
    (fun (ev : Board.karma_event) ->
       Alcotest.(check string) "all events for alice" "alice" ev.recipient)
    events

(** {1 Agent filter} *)

let test_agent_filter () =
  let post_a = create_post_exn ~author:"alice" ~content:"alice post" in
  let post_b = create_post_exn ~author:"bob" ~content:"bob post" in
  vote_exn ~voter:"v" ~post_id:(Board.Post_id.to_string post_a.id) ~direction:Board.Up;
  vote_exn ~voter:"v" ~post_id:(Board.Post_id.to_string post_b.id) ~direction:Board.Up;
  let alice_events = Board_dispatch.get_karma_ledger ~agent:"alice" () in
  let bob_events = Board_dispatch.get_karma_ledger ~agent:"bob" () in
  Alcotest.(check int) "alice filter" 1 (List.length alice_events);
  Alcotest.(check int) "bob filter" 1 (List.length bob_events);
  Alcotest.(check string) "alice event recipient" "alice"
    (List.hd alice_events).recipient

(** {1 Limit parameter} *)

let test_limit () =
  let post = create_post_exn ~author:"alice" ~content:"multi-voter" in
  let pid = Board.Post_id.to_string post.id in
  List.iter
    (fun voter -> vote_exn ~voter ~post_id:pid ~direction:Board.Up)
    [ "u1"; "u2"; "u3"; "u4"; "u5" ];
  let capped = Board_dispatch.get_karma_ledger ~limit:3 () in
  Alcotest.(check int) "limit=3 caps result" 3 (List.length capped)

(** {1 Rebuild / replay invariant}

    [totals_of_karma_ledger (build_karma_ledger store)] must equal
    [get_all_karma store] for every recipient present in the store. *)

let test_replay_invariant () =
  let post = create_post_exn ~author:"alice" ~content:"rebuild test" in
  let pid = Board.Post_id.to_string post.id in
  List.iter
    (fun voter -> vote_exn ~voter ~post_id:pid ~direction:Board.Up)
    [ "p"; "q"; "r" ];
  (* Mix in a downvote to make sure it does not shift totals *)
  ignore (Board_dispatch.vote ~voter:"s" ~post_id:pid ~direction:Board.Down);
  let ledger_totals =
    Board_dispatch.get_karma_ledger ()
    |> Board.totals_of_karma_ledger
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  let direct_totals =
    Board_dispatch.get_all_karma ()
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  Alcotest.(check (list (pair string int)))
    "ledger totals == get_all_karma" direct_totals ledger_totals

let file_contains path needle =
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop () =
          match input_line ic with
          | line ->
              (String.length needle > 0
               && String.contains line needle.[0]
               && String_util.contains_substring line needle)
              || loop ()
          | exception End_of_file -> false
        in
        loop ())

let test_delete_post_rewrites_persisted_snapshots () =
  let post = create_post_exn ~author:"alice" ~content:"delete me" in
  let pid = Board.Post_id.to_string post.id in
  let comment =
    match
      Board_dispatch.add_comment ~post_id:pid ~author:"bob"
        ~content:"also delete" ()
    with
    | Ok c -> c
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let cid = Board.Comment_id.to_string comment.id in
  vote_exn ~voter:"carol" ~post_id:pid ~direction:Board.Up;
  (match
     Board_dispatch.toggle_reaction ~target_type:Board.Reaction_post
       ~target_id:pid ~user_id:"dave" ~emoji:"👍"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match Board_dispatch.delete_post ~post_id:pid with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match Board_dispatch.get_post ~post_id:pid with
   | Ok _ -> Alcotest.fail "deleted post remained readable"
   | Error _ -> ());
  let check_absent label path needle =
    Alcotest.(check bool) label false (file_contains path needle)
  in
  check_absent "posts snapshot removes deleted post" (Board.persist_path ()) pid;
  check_absent "comments snapshot removes deleted comment" (Board.comments_path ()) cid;
  check_absent "vote snapshot removes deleted post vote" (Board_votes.vote_log_path ()) pid;
  check_absent "reaction snapshot removes deleted post reaction" (Board.reactions_path ()) pid

(** {1 JSON serialisation} *)

let test_karma_event_json_fields () =
  let post = create_post_exn ~author:"alice" ~content:"json test" in
  let pid = Board.Post_id.to_string post.id in
  vote_exn ~voter:"bob" ~post_id:pid ~direction:Board.Up;
  let ev = List.hd (Board_dispatch.get_karma_ledger ()) in
  let json = Board.karma_event_to_yojson ev in
  let get_string key =
    match json with
    | `Assoc pairs ->
        (match List.assoc_opt key pairs with
         | Some (`String s) -> s
         | _ -> Alcotest.fail (Printf.sprintf "missing string key: %s" key))
    | _ -> Alcotest.fail "expected assoc"
  in
  let get_int key =
    match json with
    | `Assoc pairs ->
        (match List.assoc_opt key pairs with
         | Some (`Int n) -> n
         | _ -> Alcotest.fail (Printf.sprintf "missing int key: %s" key))
    | _ -> Alcotest.fail "expected assoc"
  in
  Alcotest.(check string) "json recipient" "alice" (get_string "recipient");
  Alcotest.(check string) "json voter" "bob" (get_string "voter");
  Alcotest.(check string) "json target_kind" "post" (get_string "target_kind");
  Alcotest.(check string) "json target_id" pid (get_string "target_id");
  Alcotest.(check int)    "json delta" 1 (get_int "delta");
  let ts_iso = get_string "ts_iso" in
  (* Minimal ISO-8601 UTC sanity check *)
  Alcotest.(check bool) "ts_iso ends with Z" true
    (String.length ts_iso > 0 && ts_iso.[String.length ts_iso - 1] = 'Z')

(** {1 Events sorted oldest-first} *)

let test_events_sorted_oldest_first () =
  let post = create_post_exn ~author:"alice" ~content:"sorted" in
  let pid = Board.Post_id.to_string post.id in
  (* Votes are cast in rapid succession; ts order should still be non-
     decreasing because each uses the current wall clock. *)
  vote_exn ~voter:"w1" ~post_id:pid ~direction:Board.Up;
  vote_exn ~voter:"w2" ~post_id:pid ~direction:Board.Up;
  let events = Board_dispatch.get_karma_ledger () in
  (match events with
   | e1 :: e2 :: _ ->
       Alcotest.(check bool) "older event first" true
         (Float.compare e1.ts e2.ts <= 0)
   | _ -> ())

(** {1 Test runner} *)

let () =
  Alcotest.run "Board_karma_ledger" [
    "scoring", [
      Alcotest.test_case "Up = +1" `Quick test_up_scores_one;
      Alcotest.test_case "Down = 0" `Quick test_down_scores_zero;
    ];
    "ledger", [
      Alcotest.test_case "empty ledger" `Quick (with_eio test_empty_ledger);
      Alcotest.test_case "upvote produces event" `Quick
        (with_eio test_upvote_produces_one_event);
      Alcotest.test_case "downvote no event" `Quick
        (with_eio test_downvote_no_event);
      Alcotest.test_case "self post upvote no karma" `Quick
        (with_eio test_self_post_upvote_no_karma);
      Alcotest.test_case "self post upvote no economy credit" `Quick
        (with_eio test_self_post_upvote_no_economy_credit);
      Alcotest.test_case "comment upvote event" `Quick
        (with_eio test_comment_upvote_produces_event);
      Alcotest.test_case "self comment upvote no karma" `Quick
        (with_eio test_self_comment_upvote_no_karma);
      Alcotest.test_case "multiple voters" `Quick
        (with_eio test_multiple_voters);
      Alcotest.test_case "events sorted oldest first" `Quick
        (with_eio test_events_sorted_oldest_first);
    ];
    "query", [
      Alcotest.test_case "agent filter" `Quick (with_eio test_agent_filter);
      Alcotest.test_case "limit" `Quick (with_eio test_limit);
    ];
    "replay", [
      Alcotest.test_case "rebuild invariant" `Quick
        (with_eio test_replay_invariant);
      Alcotest.test_case "delete post rewrites persisted snapshots" `Quick
        (with_eio test_delete_post_rewrites_persisted_snapshots);
    ];
    "serialisation", [
      Alcotest.test_case "json fields" `Quick
        (with_eio test_karma_event_json_fields);
    ];
  ]

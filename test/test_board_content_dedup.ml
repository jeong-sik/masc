(** Tests for Board post content deduplication.
    Verifies that identical (author, body) pairs are collapsed into a
    single post, preventing the 3-6x duplication observed in production
    keeper board writes (0s gap between duplicates). *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-dedup-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()

let test_exact_duplicate_returns_same_post () =
  let first =
    match Board_dispatch.create_post ~author:"dedup-test"
             ~content:"identical body text"
             ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let second =
    match Board_dispatch.create_post ~author:"dedup-test"
             ~content:"identical body text"
             ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  Alcotest.(check string) "dedup returns same post id"
    (Board.Post_id.to_string first.id)
    (Board.Post_id.to_string second.id)

let test_different_body_creates_separate_post () =
  let _first =
    match Board_dispatch.create_post ~author:"dedup-test"
             ~content:"body A"
             ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let second =
    match Board_dispatch.create_post ~author:"dedup-test"
             ~content:"body B"
             ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let pid = Board.Post_id.to_string second.id in
  Alcotest.(check string) "different body gets new id"
    "body B" second.content;
  match Board_dispatch.get_post ~post_id:pid with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Printf.sprintf "second post should exist: %s"
                                (Board.show_board_error e))

let test_different_author_creates_separate_post () =
  let _first =
    match Board_dispatch.create_post ~author:"agent-alpha"
             ~content:"shared body"
             ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let second =
    match Board_dispatch.create_post ~author:"agent-beta"
             ~content:"shared body"
             ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  Alcotest.(check bool) "different author => different post id" true
    (not (String.equal
            (Board.Post_id.to_string _first.id)
            (Board.Post_id.to_string second.id)))

let test_triple_duplicate_count_stays_at_one () =
  let content = "triple-dup-content" in
  let p1 =
    match Board_dispatch.create_post ~author:"triple-test"
             ~content ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let _p2 =
    match Board_dispatch.create_post ~author:"triple-test"
             ~content ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let _p3 =
    match Board_dispatch.create_post ~author:"triple-test"
             ~content ~post_kind:Board.Human_post () with
    | Ok p -> p
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let posts = Board_dispatch.list_posts () in
  let same_id_count =
    List.filter (fun (p : Board.post) ->
      String.equal
        (Board.Post_id.to_string p.id)
        (Board.Post_id.to_string p1.id))
      posts
    |> List.length
  in
  Alcotest.(check int) "only one post with this id" 1 same_id_count

let create_post_or_fail ~author ~content =
  match
    Board_dispatch.create_post ~author ~content ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

let add_comment_or_fail ~post_id ~author ~content ?parent_id () =
  match Board_dispatch.add_comment ~post_id ~author ~content ?parent_id () with
  | Ok comment -> comment
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_exact_duplicate_comment_returns_same_comment () =
  let post = create_post_or_fail ~author:"comment-dedup" ~content:"post body" in
  let post_id = Board.Post_id.to_string post.id in
  let keeper_comment_signals = ref 0 in
  let sse_comment_events = ref 0 in
  Board_dispatch.set_keeper_board_signal_hook (fun signal ->
    match signal.kind with
    | Board_dispatch.Board_comment_added -> incr keeper_comment_signals
    | Board_dispatch.Board_post_created -> ());
  Board_dispatch.set_board_sse_hook (function
    | Board_dispatch.Comment_added _ -> incr sse_comment_events
    | Board_dispatch.Post_created _
    | Board_dispatch.Post_voted _
    | Board_dispatch.Comment_voted _
    | Board_dispatch.Reaction_changed _ ->
      ());
  let first =
    add_comment_or_fail
      ~post_id
      ~author:"comment-dedup"
      ~content:"same comment"
      ()
  in
  let second =
    add_comment_or_fail
      ~post_id
      ~author:"comment-dedup"
      ~content:"same comment"
      ()
  in
  Alcotest.(check string)
    "dedup returns same comment id"
    (Board.Comment_id.to_string first.id)
    (Board.Comment_id.to_string second.id);
  let comments =
    match Board_dispatch.get_comments ~post_id with
    | Ok comments -> comments
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  Alcotest.(check int) "only one comment persisted" 1 (List.length comments);
  let updated_post =
    match Board_dispatch.get_post ~post_id with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  Alcotest.(check int) "reply_count increments once" 1 updated_post.reply_count;
  Alcotest.(check int)
    "fresh comment emits one keeper signal"
    1
    !keeper_comment_signals;
  Alcotest.(check int)
    "fresh comment emits one sse event"
    1
    !sse_comment_events

let test_comment_parent_is_part_of_dedup_key () =
  let post = create_post_or_fail ~author:"comment-parent" ~content:"post body" in
  let post_id = Board.Post_id.to_string post.id in
  let parent =
    add_comment_or_fail ~post_id ~author:"comment-parent" ~content:"parent" ()
  in
  let top_level =
    add_comment_or_fail ~post_id ~author:"comment-parent" ~content:"same" ()
  in
  let reply =
    add_comment_or_fail
      ~post_id
      ~author:"comment-parent"
      ~content:"same"
      ~parent_id:(Board.Comment_id.to_string parent.id)
      ()
  in
  Alcotest.(check bool)
    "same body under different parent creates separate comment"
    true
    (not
       (String.equal
          (Board.Comment_id.to_string top_level.id)
          (Board.Comment_id.to_string reply.id)))

let () =
  Alcotest.run "board_content_dedup"
    [ ( "exact dedup",
        [ Alcotest.test_case "duplicate returns same post" `Quick
            (with_eio test_exact_duplicate_returns_same_post)
        ; Alcotest.test_case "triple duplicate count stays at one" `Quick
            (with_eio test_triple_duplicate_count_stays_at_one)
        ; Alcotest.test_case "duplicate comment returns same comment" `Quick
            (with_eio test_exact_duplicate_comment_returns_same_comment)
        ] )
    ; ( "non-duplicate",
        [ Alcotest.test_case "different body creates separate post" `Quick
            (with_eio test_different_body_creates_separate_post)
        ; Alcotest.test_case "different author creates separate post" `Quick
            (with_eio test_different_author_creates_separate_post)
        ; Alcotest.test_case "comment parent participates in dedup" `Quick
            (with_eio test_comment_parent_is_part_of_dedup_key)
        ] )
    ]

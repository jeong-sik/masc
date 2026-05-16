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

let () =
  Alcotest.run "board_content_dedup"
    [ ( "exact dedup",
        [ Alcotest.test_case "duplicate returns same post" `Quick
            (with_eio test_exact_duplicate_returns_same_post)
        ; Alcotest.test_case "triple duplicate count stays at one" `Quick
            (with_eio test_triple_duplicate_count_stays_at_one)
        ] )
    ; ( "non-duplicate",
        [ Alcotest.test_case "different body creates separate post" `Quick
            (with_eio test_different_body_creates_separate_post)
        ; Alcotest.test_case "different author creates separate post" `Quick
            (with_eio test_different_author_creates_separate_post)
        ] )
    ]

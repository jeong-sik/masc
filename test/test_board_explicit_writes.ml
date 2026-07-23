open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-test-board-explicit-%d-%06x"
         (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let with_board f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()
;;

let create_post ~content =
  match
    Board_dispatch.create_post
      ~author:"explicit-writer"
      ~content
      ~post_kind:Board.Human_post
      ()
  with
  | Ok post -> post
  | Error error -> Alcotest.fail (Board.show_board_error error)
;;

let test_identical_posts_are_distinct_writes () =
  let first = create_post ~content:"intentional duplicate" in
  let second = create_post ~content:"intentional duplicate" in
  Alcotest.(check bool)
    "distinct ids"
    true
    (not
       (String.equal
          (Board.Post_id.to_string first.id)
          (Board.Post_id.to_string second.id)));
  Alcotest.(check int)
    "both persisted"
    2
    (List.length (Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:10 ()))
;;

let test_identical_comments_are_distinct_writes () =
  let post = create_post ~content:"comment target" in
  let post_id = Board.Post_id.to_string post.id in
  let add () =
    match
      Board_dispatch.add_comment
        ~post_id
        ~author:"explicit-writer"
        ~content:"intentional duplicate comment"
        ()
    with
    | Ok comment -> comment
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let first = add () in
  let second = add () in
  Alcotest.(check bool)
    "distinct ids"
    true
    (not
       (String.equal
          (Board.Comment_id.to_string first.id)
          (Board.Comment_id.to_string second.id)));
  match Board_dispatch.get_post ~post_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok updated -> Alcotest.(check int) "reply count" 2 updated.reply_count
;;

let test_long_post_is_not_locally_rejected () =
  let content = String.make 20_000 'x' in
  let post = create_post ~content in
  Alcotest.(check int) "full content persisted" 20_000 (String.length post.content)
;;

let () =
  Alcotest.run
    "Board explicit writes"
    [ ( "writes"
      , [ Alcotest.test_case
            "identical posts remain distinct"
            `Quick
            (with_board test_identical_posts_are_distinct_writes)
        ; Alcotest.test_case
            "identical comments remain distinct"
            `Quick
            (with_board test_identical_comments_are_distinct_writes)
        ; Alcotest.test_case
            "long post has no local content cap"
            `Quick
            (with_board test_long_post_is_not_locally_rejected)
        ] )
    ]
;;

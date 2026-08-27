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
  Alcotest.(check int) "full content persisted" 20_000 (String.length post.body)
;;

(* [content] duplicated [body] byte for byte and [score] restated
   [votes_up - votes_down]; the decoder refused any row where the two
   disagreed, so a vote written without a matching score recount dropped the
   post on the next load. Both keys are gone from the row. *)
let retired_post_keys = [ "content"; "score" ]

let test_persisted_post_row_carries_no_retired_key () =
  let post = create_post ~content:"row shape" in
  let rows =
    In_channel.with_open_text (Board.persist_path ()) In_channel.input_lines
    |> List.filter (fun line -> not (String.equal (String.trim line) ""))
  in
  Alcotest.(check int) "one row" 1 (List.length rows);
  let fields =
    match Yojson.Safe.from_string (List.hd rows) with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "persisted post row is not a JSON object"
  in
  List.iter
    (fun key ->
       Alcotest.(check bool)
         (Printf.sprintf "row has no %S" key)
         false
         (List.mem_assoc key fields))
    retired_post_keys;
  Alcotest.(check string)
    "body still carries the text"
    "row shape"
    (match List.assoc "body" fields with
     | `String body -> body
     | _ -> Alcotest.fail "body is not a string");
  ignore post
;;

let test_row_carrying_a_retired_key_is_refused () =
  let post = create_post ~content:"row shape" in
  let fields =
    match Board.post_to_yojson post with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "encoded post is not a JSON object"
  in
  Alcotest.(check bool)
    "the row this build writes still reads"
    true
    (Option.is_some (Board.post_of_yojson (`Assoc fields)));
  List.iter
    (fun key ->
       let revived = `Assoc (fields @ [ key, `String "anything" ]) in
       Alcotest.(check bool)
         (Printf.sprintf "a row carrying %S is refused" key)
         true
         (Option.is_none (Board.post_of_yojson revived)))
    retired_post_keys
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
        ; Alcotest.test_case
            "persisted row carries no retired key"
            `Quick
            (with_board test_persisted_post_row_carries_no_retired_key)
        ; Alcotest.test_case
            "a row carrying a retired key is refused"
            `Quick
            (with_board test_row_carrying_a_retired_key_is_refused)
        ] )
    ]
;;

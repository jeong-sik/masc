(** Contract test for {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_posts} and
    {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_comments}.

    The current contract returns [(int, Board.board_error) result]. Missing
    files are empty current state; malformed JSON or a non-current row makes
    the complete Board snapshot reset-required. *)

open Masc

let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-loader-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let test_load_persisted_posts_missing_file () =
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store () in
  match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
  | Ok 0 -> ()
  | Ok n -> Alcotest.failf "expected Ok 0 for missing file, got Ok %d" n
  | Error error ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error %s"
      (Board.show_board_error error)
;;

let test_load_persisted_comments_missing_file () =
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store () in
  match Masc_board_handlers.Board_votes_json.load_persisted_comments store with
  | Ok 0 -> ()
  | Ok n -> Alcotest.failf "expected Ok 0 for missing file, got Ok %d" n
  | Error error ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error %s"
      (Board.show_board_error error)
;;

let expect_reset_required = function
  | Error (Board.Persistence_reset_required _) -> ()
  | Error error ->
    Alcotest.failf
      "expected Persistence_reset_required, got %s"
      (Board.show_board_error error)
  | Ok count ->
    Alcotest.failf "expected Persistence_reset_required, loaded %d rows" count
;;

let write_malformed_snapshot path =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path "{malformed-json}\n"
;;

let test_load_persisted_posts_malformed_json () =
  let _dir = fresh_test_base_path () in
  write_malformed_snapshot (Board.persist_path ());
  Board_core.create_store ()
  |> Masc_board_handlers.Board_votes_json.load_persisted_posts
  |> expect_reset_required
;;

let test_load_persisted_comments_malformed_json () =
  let _dir = fresh_test_base_path () in
  write_malformed_snapshot (Board.comments_path ());
  Board_core.create_store ()
  |> Masc_board_handlers.Board_votes_json.load_persisted_comments
  |> expect_reset_required
;;

let test_load_persisted_posts_rejects_retired_field () =
  let _dir = fresh_test_base_path () in
  let now = Time_compat.now () in
  let row =
    `Assoc
      [ "id", `String "retired-field-row"
      ; "author", `String "current-writer"
      ; "title", `String "Current fields plus one retired field"
      ; "body", `String "body"
      ; "post_kind", `String "human"
      ; "content", `String "body"
      ; "visibility", `String "internal"
      ; "created_at", `Float now
      ; "updated_at", `Float now
      ; "expires_at", `Float 0.0
      ; "votes_up", `Int 0
      ; "votes_down", `Int 0
      ; "score", `Int 0
      ; "reply_count", `Int 0
      ; "pinned", `Bool false
      ; "meta_json", `String "{}"
      ]
  in
  let path = Board.persist_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path (Yojson.Safe.to_string row ^ "\n");
  Board_core.create_store ()
  |> Masc_board_handlers.Board_votes_json.load_persisted_posts
  |> expect_reset_required
;;

let () =
  Random.self_init ();
  Alcotest.run
    "board_persistence_load_contract"
    [ ( "loader_contract"
      , [ Alcotest.test_case
            "posts loader returns Ok 0 when file absent"
            `Quick
            test_load_persisted_posts_missing_file
        ; Alcotest.test_case
            "comments loader returns Ok 0 when file absent"
            `Quick
            test_load_persisted_comments_missing_file
        ; Alcotest.test_case
            "posts loader rejects malformed JSON"
            `Quick
            test_load_persisted_posts_malformed_json
        ; Alcotest.test_case
            "comments loader rejects malformed JSON"
            `Quick
            test_load_persisted_comments_malformed_json
        ; Alcotest.test_case
            "posts loader rejects retired fields"
            `Quick
            test_load_persisted_posts_rejects_retired_field
        ] )
    ]
;;

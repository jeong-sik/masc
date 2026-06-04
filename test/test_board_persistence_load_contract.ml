(** Contract test for {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_posts} and
    {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_comments}.

    Prior to this contract change, the loaders had signature
    [store -> unit] and swallowed any [exn] from the JSONL read into an
    in-function [Log.BoardLog.error].  Callers could not distinguish a
    successful "no file" load from a partially-loaded store after an IO
    failure.

    The current contract returns [(int, string * exn) result] and forces
    callers to acknowledge failure.  These tests pin the [Ok 0] branch
    that is exercised on every fresh server start (no persistence file
    yet). *)

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
  | Error (path, e) ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error (%s, %s)"
      path
      (Printexc.to_string e)
;;

let test_load_persisted_comments_missing_file () =
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store () in
  match Masc_board_handlers.Board_votes_json.load_persisted_comments store with
  | Ok 0 -> ()
  | Ok n -> Alcotest.failf "expected Ok 0 for missing file, got Ok %d" n
  | Error (path, e) ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error (%s, %s)"
      path
      (Printexc.to_string e)
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
        ] )
    ]
;;

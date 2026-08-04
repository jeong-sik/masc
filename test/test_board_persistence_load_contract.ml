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

let () = Mirage_crypto_rng_unix.use_default ()

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

let remove_key json key =
  match json with
  | `Assoc fields ->
    `Assoc (List.filter (fun (name, _) -> not (String.equal name key)) fields)
  | other -> other
;;

let prepend_field json field =
  match json with
  | `Assoc fields -> `Assoc (field :: fields)
  | other -> other
;;

let replace_key json key value =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, current) ->
            if String.equal name key then name, value else name, current)
         fields)
  | other -> other
;;

let test_loader_keeps_only_current_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let source_store = Board_core.create_store () in
  let post =
    match
      Board_core.create_post
        source_store
        ~author:"current-writer"
        ~content:"current persisted row"
        ~post_kind:Board.Human_post
        ()
    with
    | Ok post -> post
    | Error error ->
      Alcotest.failf "create_post failed: %s" (Board.show_board_error error)
  in
  let canonical = Board_core.post_to_yojson post in
  let path = Board.persist_path () in
  let append json =
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n")
  in
  append (remove_key canonical "pinned");
  append (prepend_field canonical ("meta_json", `String "{}"));
  append (replace_key canonical "votes_up" (`String "0"));
  let loaded_store = Board_core.create_store () in
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts loaded_store with
   | Ok 1 -> ()
   | Ok count -> Alcotest.failf "expected exactly one current row, loaded %d" count
   | Error (load_path, error) ->
     Alcotest.failf
       "load failed: %s (%s)"
       load_path
       (Printexc.to_string error));
  Alcotest.(check bool)
    "canonical post is present"
    true
    (Result.is_ok
       (Board_core.get_post
          loaded_store
          ~post_id:(Board.Post_id.to_string post.id)))
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
            "loader keeps only exact current rows"
            `Quick
            test_loader_keeps_only_current_rows
        ] )
    ]
;;

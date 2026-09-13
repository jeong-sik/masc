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
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "invalid persisted schemas must report partial-source failure");
  Alcotest.(check bool) "schema failure remains available to evidence readers" true
    (Result.is_error loaded_store.posts_load_result);
  Alcotest.(check bool)
    "canonical post is present"
    true
    (Result.is_ok
       (Board_core.get_post
          loaded_store
          ~post_id:(Board.Post_id.to_string post.id)));
  Out_channel.with_open_bin path (fun _ -> ());
  Alcotest.(check bool) "empty successful reload discards prior partial rows" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts loaded_store = Ok 0);
  Alcotest.(check int) "old post is not trusted after empty reload" 0 (Hashtbl.length loaded_store.posts);
  Alcotest.(check int) "old post count is cleared" 0 !(loaded_store.post_count);
  let comment = match Board_core.add_comment source_store
      ~post_id:(Board.Post_id.to_string post.id) ~author:"fixture-author"
      ~content:"retained partial comment" ~ttl_hours:0 () with
    | Ok comment -> Board_core.comment_to_yojson comment
    | Error error -> Alcotest.failf "create_comment failed: %s" (Board.show_board_error error) in
  let comments_path = Board.comments_path () in
  Out_channel.with_open_bin comments_path (fun out ->
    output_string out (Yojson.Safe.to_string comment ^ "\n{bad-json\n"));
  Alcotest.(check bool) "mixed valid/corrupt comments fail completeness" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_comments loaded_store));
  Alcotest.(check int) "best-effort valid comment remains" 1 (Hashtbl.length loaded_store.comments);
  Out_channel.with_open_bin comments_path (fun _ -> ());
  Alcotest.(check bool) "empty comments reload succeeds" true
    (Masc_board_handlers.Board_votes_json.load_persisted_comments loaded_store = Ok 0);
  Alcotest.(check int) "old comments removed on healthy reload" 0 (Hashtbl.length loaded_store.comments);
  Alcotest.(check int) "comment index cleared on healthy reload" 0 (Hashtbl.length loaded_store.comments_by_post);
  Out_channel.with_open_bin path (fun out ->
    output_string out (Yojson.Safe.to_string (replace_key canonical "expires_at" (`Float 1.)) ^ "\n"));
  let expired_store = Board_core.create_store () in
  Alcotest.(check bool) "valid expired posts are not corrupt source rows" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts expired_store = Ok 0);
  Alcotest.(check bool) "expired-only source remains complete" true
    (expired_store.posts_load_result = Ok ())
;;

let test_source_failure_clears_only_after_successful_reload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let dir = fresh_test_base_path () in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_BASE_PATH" (Option.value ~default:"" previous);
    if Sys.file_exists dir then Fs_compat.remove_tree dir) (fun () ->
    let store = Board_core.create_store () in
    let loaders = [
      (Board.persist_path (), Masc_board_handlers.Board_votes_json.load_persisted_posts,
       (fun () -> store.Board.posts_load_result));
      (Board.comments_path (), Masc_board_handlers.Board_votes_json.load_persisted_comments,
       (fun () -> store.Board.comments_load_result))] in
    List.iter (fun (path, load, health) ->
      Fs_compat.mkdir_p (Filename.dirname path);
      let write text = Out_channel.with_open_bin path (fun out -> output_string out text) in
      List.iter (fun malformed ->
        write malformed;
        Alcotest.(check bool) "invalid source fails load" true (Result.is_error (load store));
        Alcotest.(check bool) "failure retained" true (Result.is_error (health ())))
        ["{secret-not-json\n"; "{}\n"];
      (* Editing the file cannot erase the last load outcome by itself. *)
      write "";
      Alcotest.(check bool) "failure stays until reloaded" true (Result.is_error (health ()));
      Alcotest.(check bool) "empty file is legitimate" true (load store = Ok 0);
      Alcotest.(check bool) "successful reload clears failure" true (health () = Ok ());
      Sys.remove path;
      Unix.mkdir path 0o700;
      Alcotest.(check bool) "unreadable source is not a missing file" true
        (Result.is_error (load store));
      Unix.rmdir path;
      Alcotest.(check bool) "missing file is legitimate" true (load store = Ok 0)) loaders)
;;

let () =
  Random.self_init ();
  Alcotest.run
    "board_persistence_load_contract"
    [ ( "loader_contract"
      , [ Alcotest.test_case "source failures survive until a complete successful reload" `Quick
            test_source_failure_clears_only_after_successful_reload
        ; Alcotest.test_case
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

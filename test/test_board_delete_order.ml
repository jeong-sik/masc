open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let fresh_store base_path =
  Board_dispatch.reset_for_test ();
  Board.reset_global_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl ~base_path
    ~recipient_lookup:Recipient_lookup.none_declared ());
  Board.global ()

let post store content = match Board.create_post store
    ~lookup:Recipient_lookup.none_declared ~author:"delete-owner"
    ~content ~post_kind:Board.Human_post ~ttl_hours:0 () with
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let comment store (parent : Board.post) content = require (Board.add_comment store
    ~lookup:Recipient_lookup.none_declared ~post_id:(Board.Post_id.to_string parent.id)
    ~author:"delete-reader" ~content ~ttl_hours:0 ())

let require_pending = function
  | Ok (Board.Deletion_persistence_pending _) -> ()
  | Ok Board.Durable_deletion -> Alcotest.fail "failed deletion prerequisite reported durable completion"
  | Error error -> Alcotest.fail (Board.show_board_error error)

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-delete-order-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    let module Paths = Masc_board_handlers.Board_paths in
    let workspace_masc_dir = Common.masc_dir_from_base_path ~base_path in
    List.iter (fun kind -> Fs_compat.invalidate_cached_writer (Paths.file_path ~workspace_masc_dir kind))
      [Paths.Posts; Comments; Votes; Reactions; Sub_boards];
    (match before with None -> Unix.unsetenv "MASC_BASE_PATH"
     | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base_path)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_refused_parent_preserves_comments_after_flush base_path =
  let stale = fresh_store base_path in
  let parent = post stale "parent retained when its deletion refuses" in
  let reply = comment stale parent "reply must not disappear beneath a retained parent" in
  let other = fresh_store base_path in
  let foreign = post other "another writer's accepted post" in
  let posts_path = Board.persist_path stale and comments_path = Board.comments_path stale in
  let posts_before = Fs_compat.load_file posts_path and comments_before = Fs_compat.load_file comments_path in
  require_pending (Board.delete_post stale ~post_id:(Board.Post_id.to_string parent.id));
  List.iter (fun load -> Alcotest.(check bool) "pending deletion refuses partial model reload" true
    (Result.is_error (load stale)))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments];
  Alcotest.(check string) "refused parent deletion preserves comments" comments_before
    (Fs_compat.load_file comments_path);
  Board.flush_dirty stale;
  Alcotest.(check string) "retry flush preserves the failed parent's source" posts_before
    (Fs_compat.load_file posts_path);
  Alcotest.(check string) "retry flush retains the deletion dependency" comments_before
    (Fs_compat.load_file comments_path);
  let restarted = fresh_store base_path in
  List.iter (fun (expected : Board.post) ->
    Alcotest.(check string) "both accepted posts survive a fresh load" expected.body
      (require (Board.get_post restarted ~post_id:(Board.Post_id.to_string expected.id))).body)
    [parent; foreign];
  Alcotest.(check string) "the retained parent still has its accepted reply" reply.content
    (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id))).content

let () =
  Alcotest.run "board_delete_order"
    ["actual writers and retry",
      [Alcotest.test_case "refused parent retains comments through retry and restart" `Quick
         (with_fixture test_refused_parent_preserves_comments_after_flush)]]

open Masc

module Rows = Masc_board_handlers.Board_votes_json

let () = Mirage_crypto_rng_unix.use_default ()

let require = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_error error)

let load_sources store =
  List.iter (fun load -> match load store with
    | Ok _ -> ()
    | Error (path, error) -> Alcotest.failf "load %s: %s" path (Printexc.to_string error))
    [Rows.load_persisted_posts; Rows.load_persisted_comments]

let new_store base_path =
  let store = Board.create_store ~base_path () in
  load_sources store;
  store

let seed base_path =
  let store = new_store base_path in
  let post = match Board.create_post store ~lookup:Recipient_lookup.none_declared
      ~author:"comments-source-writer" ~content:"shared parent"
      ~post_kind:Board.Human_post ~ttl_hours:0 () with
    | Ok post -> post
    | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error) in
  store, post

let append store (post : Board.post) content =
  Board.add_comment store ~lookup:Recipient_lookup.none_declared
    ~post_id:(Board.Post_id.to_string post.id) ~author:"comments-source-reader"
    ~content ~ttl_hours:0 ()

let has_comment store (comment : Board.comment) =
  Result.is_ok (Board.get_comment store ~comment_id:(Board.Comment_id.to_string comment.id))

let require_io_error = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "unadmitted source change succeeded"

let readable store = Board.with_persist_lock store (fun () ->
  Board.require_comments_source_readable store)

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  let base_path = Filename.temp_dir "masc-board-comments-source-" "" in
  Fun.protect ~finally:(fun () -> match before with
    | None -> Unix.unsetenv "MASC_BASE_PATH"
    | Some value -> Unix.putenv "MASC_BASE_PATH" value)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_stale_append_requires_full_reload base_path =
  let first, post = seed base_path in
  let stale = new_store base_path in
  let retained = require (append first post "first store's durable comment") in
  let path = Board.comments_path first in
  let bytes = Fs_compat.load_file path in
  require_io_error (append stale post "not admitted against an old source");
  Alcotest.(check string) "stale append does not change the source" bytes (Fs_compat.load_file path);
  Alcotest.(check int) "failed append is absent from memory" 0 (Hashtbl.length stale.comments);
  load_sources stale;
  Alcotest.(check bool) "reload installs the foreign comment" true (has_comment stale retained);
  let next = require (append stale post "after a complete reload") in
  let restarted = new_store base_path in
  Alcotest.(check bool) "first comment survives restart" true (has_comment restarted retained);
  Alcotest.(check bool) "reloaded writer's comment survives restart" true (has_comment restarted next)

let test_stale_snapshot_keeps_foreign_append base_path =
  let first, post = seed base_path in
  let first_comment = require (append first post "first store snapshot") in
  let second = new_store base_path in
  let foreign_comment = require (append second post "second store append") in
  let path = Board.comments_path first in
  let bytes = Fs_compat.load_file path in
  Board.flush_dirty first;
  Alcotest.(check string) "stale flush preserves both rows" bytes (Fs_compat.load_file path);
  Alcotest.(check bool) "refused comments work remains scheduled" true first.dirty_comments;
  require_io_error (readable first);
  let restarted = new_store base_path in
  Alcotest.(check bool) "own comment is retained" true (has_comment restarted first_comment);
  Alcotest.(check bool) "foreign comment is retained" true (has_comment restarted foreign_comment)

let () = Alcotest.run "board comments source"
  ["persistence",
    [Alcotest.test_case "stale append requires model reload" `Quick (with_fixture test_stale_append_requires_full_reload);
     Alcotest.test_case "stale flush retains foreign append" `Quick (with_fixture test_stale_snapshot_keeps_foreign_append)]]

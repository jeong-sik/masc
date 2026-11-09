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

let test_same_inode_same_length_edit_is_not_overwritten base_path =
  let store, post = seed base_path in
  let comment = require (append store post "aaaa") in
  let path = Board.comments_path store in
  Board.with_persist_lock store (fun () ->
    let snapshot = Board.with_lock store (fun () -> Board.capture_comments_snapshot store) in
    let before = Unix.stat path in
    let changed = { comment with content = "bbbb" } in
    let bytes = Yojson.Safe.to_string (Board.comment_to_yojson changed) ^ "\n" in
    Out_channel.with_open_bin path (fun output -> output_string output bytes);
    let after = Unix.stat path in
    Alcotest.(check (pair int int)) "fixture retains inode and length"
      (before.Unix.st_ino, before.Unix.st_size) (after.Unix.st_ino, after.Unix.st_size);
    require_io_error (Board.save_comments_snapshot store snapshot);
    Alcotest.(check string) "exact bytes fence the stale snapshot" bytes (Fs_compat.load_file path));
  load_sources store;
  let reloaded = require (Board.get_comment store ~comment_id:(Board.Comment_id.to_string comment.id)) in
  Alcotest.(check string) "healthy reload replaces the model" "bbbb" reloaded.content

let test_present_loss_and_transient_obstruction base_path =
  let store, post = seed base_path in
  let first = require (append store post "retained original") in
  let path = Board.comments_path store in
  let saved = path ^ ".fixture-original" in
  Unix.rename path saved;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir path; Unix.rename saved path) (fun () ->
    require_io_error (append store post "blocked by a nonregular path"));
  let next = require (append store post "retry against the restored exact source") in
  Unix.rename path saved;
  Fun.protect ~finally:(fun () -> Unix.rename saved path) (fun () ->
    Alcotest.(check bool) "loss after Present is refused" true
      (Result.is_error (Rows.load_persisted_comments store));
    require_io_error (readable store);
    Alcotest.(check bool) "refusal never recreates missing data" false (Sys.file_exists path));
  load_sources store;
  Alcotest.(check bool) "reload retains first row" true (has_comment store first);
  Alcotest.(check bool) "reload retains successful retry" true (has_comment store next)

let test_unknown_rewrite_requires_explicit_recovery_and_reload base_path =
  let _, post = seed base_path in
  let armed = ref false in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        if !armed then (armed := false; raise (Failure "injected comments parent sync")))
    ; close_fd = Unix.close } in
  let store = Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  load_sources store;
  let comment = require (append store post "real row before an uncertain rewrite") in
  ignore (require (Board.vote_comment store ~voter:"comments-source-voter"
    ~comment_id:(Board.Comment_id.to_string comment.id) ~direction:Board.Up));
  Board.with_persist_lock store (fun () ->
    let snapshot = Board.with_lock store (fun () -> Board.capture_comments_snapshot store) in
    armed := true;
    require_io_error (Board.save_comments_snapshot store snapshot));
  let pending = match store.comments_source with
    | Board.Comments_unsettled { pending; _ } -> pending
    | _ -> Alcotest.fail "actual published rewrite must retain uncertainty" in
  Alcotest.(check bool) "ordinary reload cannot settle" true
    (Result.is_error (Rows.load_persisted_comments store));
  require_io_error (readable store);
  let receipt = Board.with_persist_lock store (fun () -> require (Board.settle_comments_source store)) in
  (match receipt with
   | Some receipt ->
     Alcotest.(check string) "recovery returns the interrupted intended bytes"
       pending.intended_bytes receipt.interrupted.intended_bytes
   | None -> Alcotest.fail "an unsettled write requires an actual recovery receipt");
  require_io_error (readable store);
  load_sources store;
  require (readable store);
  Alcotest.(check bool) "full reload retains the durable row" true (has_comment store comment)

let test_reserved_cleanup_finishes_known_append_publication base_path =
  let _, post = seed base_path in
  let armed = ref false and lock_path = ref None in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ -> ())
    ; close_fd = (fun fd ->
        let stat = Unix.fstat fd in
        let target = Option.map Unix.lstat !lock_path in
        Unix.close fd;
        match !armed, target with
        | true, Some lock when stat.Unix.st_dev = lock.Unix.st_dev
                               && stat.Unix.st_ino = lock.Unix.st_ino ->
          armed := false;
          raise Eio.Time.Timeout
        | false, (None | Some _) | true, None | true, Some _ -> ()) } in
  let store = Board.create_store_with_comments_io_for_testing ~base_path ~io () in
  load_sources store;
  (* The stable sibling name is the actual Fs JSONL lock protocol. Only that
     descriptor's post-close cleanup is failed; data writes already succeeded. *)
  lock_path := Some (Board.comments_path store ^ ".lock");
  armed := true;
  (match append store post "known append before reserved cleanup" with
   | _ -> Alcotest.fail "reserved descriptor cleanup was swallowed"
   | exception Eio.Time.Timeout -> ());
  require (readable store);
  let comment = match List.of_seq (Hashtbl.to_seq_values store.comments) with
    | [comment] -> comment
    | _ -> Alcotest.fail "known append must finish its one model publication" in
  let restarted = new_store base_path in
  Alcotest.(check bool) "the same published row survives restart" true (has_comment restarted comment)

let test_unfinished_publication_cannot_adopt_foreign_rows base_path =
  let store, post = seed base_path in
  let original = require (append store post "existing published row") in
  let uncommitted = { original with id = Board.Comment_id.generate (); content = "unpublished append" } in
  let receipt = Board.with_persist_lock store (fun () -> require (Board.append_comment store uncommitted)) in
  require_io_error (readable store);
  Alcotest.(check bool) "reload cannot erase unfinished model publication" true
    (Result.is_error (Rows.load_persisted_comments store));
  let other = new_store base_path in
  let foreign = require (append other post "foreign row after the actual receipt") in
  let path = Board.comments_path store in
  let bytes = Fs_compat.load_file path in
  Board.with_persist_lock store (fun () ->
    Board.with_lock store (fun () ->
      Board.mark_dirty_comment store (Board.Comment_id.to_string uncommitted.id));
    require (Board.publish_comment_append store receipt));
  Board.rewrite_comments store;
  Alcotest.(check string) "owned cleanup cannot erase an intervening foreign row"
    bytes (Fs_compat.load_file path);
  let restarted = new_store base_path in
  Alcotest.(check bool) "foreign row remains available" true (has_comment restarted foreign);
  (* Cleanup was refused and its intent is volatile. This test does not claim
     durable rollback of the rejected/unpublished row across restart. *)
  Alcotest.(check bool) "unsettled cleanup is not silently reported durable" true
    (has_comment restarted uncommitted)

let () = Alcotest.run "board comments source"
  ["persistence",
    [Alcotest.test_case "stale append requires model reload" `Quick (with_fixture test_stale_append_requires_full_reload);
     Alcotest.test_case "stale flush retains foreign append" `Quick (with_fixture test_stale_snapshot_keeps_foreign_append);
     Alcotest.test_case "same inode and size do not authorize overwrite" `Quick
       (with_fixture test_same_inode_same_length_edit_is_not_overwritten);
     Alcotest.test_case "known nonwrite retries but observed loss refuses" `Quick
       (with_fixture test_present_loss_and_transient_obstruction);
     Alcotest.test_case "unknown rewrite requires recovery and reload" `Quick
       (with_fixture test_unknown_rewrite_requires_explicit_recovery_and_reload);
     Alcotest.test_case "known append publishes before reserved cleanup escapes" `Quick
       (with_fixture test_reserved_cleanup_finishes_known_append_publication);
     Alcotest.test_case "unfinished publication retains exact cleanup receipt" `Quick
       (with_fixture test_unfinished_publication_cannot_adopt_foreign_rows)]]

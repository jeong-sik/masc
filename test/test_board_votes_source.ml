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

let read_post store (parent : Board.post) =
  match Board.read_post store ~post_id:(Board.Post_id.to_string parent.id) with
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.show_board_read_error error)

let post store content =
  match Board.create_post store ~lookup:Recipient_lookup.none_declared
      ~author:"vote-source-owner" ~content ~post_kind:Board.Human_post
      ~ttl_hours:0 () with
  | Ok value -> value
  | Error error -> Alcotest.fail (Board.Post_publication_failure.to_string error)

let cast store (parent : Board.post) voter =
  Board.vote store ~post_id:(Board.Post_id.to_string parent.id)
    ~voter ~direction:Board.Up

let require_io_error = function
  | Error (Board.Io_error _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "unavailable vote source was accepted"

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-board-votes-source-" "" in
  let before = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    let module Paths = Masc_board_handlers.Board_paths in
    let workspace_masc_dir = Common.masc_dir_from_base_path ~base_path in
    List.iter (fun kind -> Fs_compat.invalidate_cached_writer
      (Paths.file_path ~workspace_masc_dir kind))
      [Paths.Posts; Comments; Votes; Reactions; Sub_boards];
    (match before with None -> Unix.unsetenv "MASC_BASE_PATH"
     | Some value -> Unix.putenv "MASC_BASE_PATH" value);
    remove_tree base_path)
    (fun () -> Unix.putenv "MASC_BASE_PATH" base_path; f base_path)

let test_stale_snapshot_preserves_accepted_vote base_path =
  let stale = fresh_store base_path in
  let parent = post stale "both accepted votes must survive an old flush" in
  ignore (require (cast stale parent "first-voter"));
  let other = fresh_store base_path in
  ignore (require (cast other parent "foreign-voter"));
  let path = Board.vote_log_path stale in
  let accepted = Fs_compat.load_file path in
  Board.flush_dirty stale;
  Alcotest.(check string) "stale full ledger cannot remove the foreign vote" accepted
    (Fs_compat.load_file path);
  let restarted = fresh_store base_path in
  let loaded = read_post restarted parent in
  Alcotest.(check int) "fresh counts include both accepted votes" 2 loaded.votes_up;
  List.iter (fun voter ->
    match require (Board.current_vote_for_post restarted ~voter
        ~post_id:(Board.Post_id.to_string parent.id)) with
    | Some Board.Up -> ()
    | Some Board.Down | None -> Alcotest.fail "an accepted vote disappeared")
    ["first-voter"; "foreign-voter"]

let test_stale_append_cannot_adopt_a_foreign_ledger base_path =
  let stale = fresh_store base_path in
  let parent = post stale "a stale append cannot make an incomplete model authoritative" in
  let other = fresh_store base_path in
  ignore (require (cast other parent "foreign-voter"));
  let path = Board.vote_log_path stale in
  let accepted = Fs_compat.load_file path in
  require_io_error (cast stale parent "stale-voter");
  Alcotest.(check string) "refused append leaves the accepted ledger unchanged" accepted
    (Fs_compat.load_file path);
  Alcotest.(check int) "refused append does not publish a new model vote" 0
    (read_post stale parent).votes_up;
  let restarted = fresh_store base_path in
  Alcotest.(check int) "fresh counts retain the one accepted vote" 1
    (read_post restarted parent).votes_up;
  (match require (Board.current_vote_for_post restarted ~voter:"stale-voter"
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | None -> ()
   | Some _ -> Alcotest.fail "a refused append was replayed")

let vote_fault_store base_path io =
  let store = Board.create_store_with_votes_io_for_testing ~base_path ~io () in
  List.iter (fun load -> match load store with
    | Ok _ -> ()
    | Error (path, error) ->
      Alcotest.failf "load %s: %s" path (Printexc.to_string error))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments];
  ignore (require (Board.reload_votes store));
  store

let test_unknown_rewrite_retains_exact_deletion_bytes base_path =
  let seeded = fresh_store base_path in
  let parent = post seeded "delete a post with an accepted vote" in
  let armed = ref false and calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ ->
        incr calls;
        if !armed then (armed := false; raise (Failure "votes parent sync")))
    ; close_fd = (fun fd -> incr calls; Unix.close fd) } in
  let store = vote_fault_store base_path io in
  ignore (require (cast store parent "accepted-before-deletion"));
  armed := true;
  (match require (Board.delete_post store
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Deletion_persistence_pending _ -> ()
   | Board.Durable_deletion -> Alcotest.fail "an uncertain vote rewrite reported durable deletion");
  Alcotest.(check bool) "the real post-rename fault was reached" false !armed;
  let visible = Fs_compat.load_file (Board.vote_log_path store) in
  Alcotest.(check string) "rename published the empty ledger, without a durability proof" "" visible;
  let check_retained () = match store.Board.votes_source with
    | Board.Votes_unsettled { vote_pending; _ } ->
      Alcotest.(check string) "the exact interrupted deletion bytes remain owned"
        visible vote_pending.vote_intended_bytes
    | Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_refused _ ->
      Alcotest.fail "the uncertain rewrite lost its pending source evidence" in
  check_retained ();
  let before = !calls in
  require_io_error (Board.reload_votes store);
  require_io_error (cast store parent "not-replayed");
  Board.flush_dirty store;
  Alcotest.(check int) "reload, cast and retry do not replay uncertain votes IO" before !calls;
  check_retained ();
  let restarted = fresh_store base_path in
  Alcotest.(check int) "a fresh store can observe the current empty ledger" 0
    (require (Board.reload_votes restarted));
  Alcotest.(check bool) "the completed parent deletion is visible to a fresh store" true
    (Result.is_error (Board.get_post restarted ~post_id:(Board.Post_id.to_string parent.id)));
  check_retained ()

let test_known_append_publishes_before_reserved_cleanup base_path =
  let seeded = fresh_store base_path in
  let parent = post seeded "accepted votes survive reserved cleanup" in
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
  let store = vote_fault_store base_path io in
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.vote_log_path store));
  armed := true;
  (match cast store parent "cleanup-voter" with
   | _ -> Alcotest.fail "the original reserved cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  Alcotest.(check bool) "the actual stable-lock descriptor close failed" false !armed;
  (match store.Board.votes_source with
   | Board.Votes_readable _ -> ()
   | Votes_unobserved | Votes_publishing _ | Votes_refused _ | Votes_unsettled _ ->
     Alcotest.fail "a known append did not acknowledge its successful model publication");
  (match require (Board.current_vote_for_post store ~voter:"cleanup-voter"
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | Some Board.Up -> ()
   | Some Board.Down | None -> Alcotest.fail "known append was not published before cleanup escaped");
  Alcotest.(check int) "the accepted vote changed the model exactly once" 1
    (require (Board.get_post store ~post_id:(Board.Post_id.to_string parent.id))).votes_up;
  ignore (require (cast store parent "next-voter"));
  let restarted = fresh_store base_path in
  Alcotest.(check int) "the known append and a subsequent cast both survive a fresh store" 2
    (require (Board.get_post restarted ~post_id:(Board.Post_id.to_string parent.id))).votes_up

let () =
  Alcotest.run "board_votes_source"
    ["actual writers and fresh loads",
      [Alcotest.test_case "stale snapshot retains another writer's vote" `Quick
         (with_fixture test_stale_snapshot_preserves_accepted_vote);
       Alcotest.test_case "stale append cannot adopt a newer ledger" `Quick
         (with_fixture test_stale_append_cannot_adopt_a_foreign_ledger)];
     "actual transaction settlement",
      [Alcotest.test_case "unknown deletion rewrite retains bytes without replay" `Quick
         (with_fixture test_unknown_rewrite_retains_exact_deletion_bytes);
       Alcotest.test_case "known append publishes before reserved cleanup escapes" `Quick
         (with_fixture test_known_append_publishes_before_reserved_cleanup)]]

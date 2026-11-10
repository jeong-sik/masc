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
  let retry_errors_before = Board.persist_error_count () in
  Board.flush_dirty stale;
  Alcotest.(check bool) "refused retry is recorded by the source writer" true
    (Board.persist_error_count () > retry_errors_before);
  Alcotest.(check string) "retry flush preserves the failed parent's source" posts_before
    (Fs_compat.load_file posts_path);
  Alcotest.(check string) "retry flush retains the deletion dependency" comments_before
    (Fs_compat.load_file comments_path);
  let restarted = fresh_store base_path in
  List.iter (fun (expected : Board.post) ->
    Alcotest.(check string) "both accepted posts survive a fresh load" expected.body
      (require (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator
                  ~post_id:(Board.Post_id.to_string expected.id))).body)
    [parent; foreign];
  Alcotest.(check string) "the retained parent still has its accepted reply" reply.content
    (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id))).content

let test_refused_comments_preserve_foreign_votes_and_reactions base_path =
  let stale = fresh_store base_path in
  let parent = post stale "parent deletion can land before a comments refusal" in
  let other = fresh_store base_path in
  let reply = comment other parent "another writer's accepted reply" in
  let comment_id = Board.Comment_id.to_string reply.id in
  ignore (require (Board.vote_comment other ~comment_id ~voter:"foreign-voter" ~direction:Board.Up));
  ignore (require (Board.toggle_reaction other ~target_type:Board.Reaction_comment
    ~target_id:comment_id ~user_id:"foreign-reactor" ~emoji:"👍"));
  let comments_path = Board.comments_path stale in
  let votes_path = Board.vote_log_path stale and reactions_path = Board.reactions_path stale in
  let preserved = List.map (fun path -> path, Fs_compat.load_file path)
      [comments_path; votes_path; reactions_path] in
  List.iter (fun (_, bytes) -> Alcotest.(check bool) "fixture has accepted dependent data" false
    (String.equal bytes "")) preserved;
  require_pending (Board.delete_post stale ~post_id:(Board.Post_id.to_string parent.id));
  Alcotest.(check string) "parent rewrite actually succeeded before comments refused" ""
    (Fs_compat.load_file (Board.persist_path stale));
  List.iter (fun (path, bytes) -> Alcotest.(check string) "failed comments prerequisite preserves later sources"
    bytes (Fs_compat.load_file path)) preserved;
  Board.flush_dirty stale;
  List.iter (fun (path, bytes) -> Alcotest.(check string) "retry preserves foreign comments, votes and reactions"
    bytes (Fs_compat.load_file path)) preserved;
  let restarted = fresh_store base_path in
  Alcotest.(check int) "valid orphan comment retains its accepted vote" 1
    (require (Board.get_comment restarted ~comment_id)).votes_up;
  let reactions = require (Board.list_reactions restarted ~target_type:Board.Reaction_comment
      ~target_id:comment_id ()) in
  Alcotest.(check bool) "valid orphan comment retains its accepted reaction" true
    (List.exists (fun (summary : Board.reaction_summary) ->
       String.equal summary.emoji "👍" && summary.count = 1) reactions)

let test_reserved_parent_cleanup_retains_deletion_order base_path =
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
          armed := false; raise Eio.Time.Timeout
        | false, (None | Some _) | true, None | true, Some _ -> ()) } in
  let stale = Board.create_store_with_source_io_for_testing ~base_path ~io:{ posts = Some io } () in
  List.iter (fun load -> match load stale with
    | Ok _ -> ()
    | Error (path, error) -> Alcotest.failf "load %s: %s" path (Printexc.to_string error))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments];
  let parent = post stale "known parent deletion before reserved cleanup" in
  let reply = comment stale parent "pending dependent cleanup" in
  let comments_path = Board.comments_path stale in
  let comments_before = Fs_compat.load_file comments_path in
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.persist_path stale));
  armed := true;
  (match Board.delete_post stale ~post_id:(Board.Post_id.to_string parent.id) with
   | _ -> Alcotest.fail "original reserved cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  Alcotest.(check string) "parent publication is known before the cleanup exception" ""
    (Fs_compat.load_file (Board.persist_path stale));
  Alcotest.(check string) "reserved settlement defers dependent cleanup" comments_before
    (Fs_compat.load_file comments_path);
  let other = fresh_store base_path in
  let foreign = post other "a new post after the known deletion" in
  Board.flush_dirty stale;
  Alcotest.(check string) "a later posts refusal still defers comment cleanup" comments_before
    (Fs_compat.load_file comments_path);
  let restarted = fresh_store base_path in
  Alcotest.(check string) "foreign post survives the retry" foreign.body
    (require (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator
                ~post_id:(Board.Post_id.to_string foreign.id))).body;
  Alcotest.(check string) "valid orphan reply survives the retry" reply.content
    (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id))).content

let () =
  Alcotest.run "board_delete_order"
    ["actual writers and retry",
      [Alcotest.test_case "refused parent retains comments through retry and restart" `Quick
         (with_fixture test_refused_parent_preserves_comments_after_flush);
       Alcotest.test_case "refused comments retain foreign votes and reactions" `Quick
         (with_fixture test_refused_comments_preserve_foreign_votes_and_reactions);
       Alcotest.test_case "reserved parent cleanup retains deletion ordering" `Quick
         (with_fixture test_reserved_parent_cleanup_retains_deletion_order)]]

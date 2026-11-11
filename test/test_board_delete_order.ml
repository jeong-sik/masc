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

let comment store (parent : Board.post) content = require (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator store
    ~lookup:Recipient_lookup.none_declared ~post_id:(Board.Post_id.to_string parent.id)
    ~author:"delete-reader" ~content ~ttl_hours:0 ())

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
  (match Board.delete_post stale ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "stale parent must refuse before a deletion decision");
  let module Paths = Masc_board_handlers.Board_paths in
  Alcotest.(check bool) "refused guard records no decision" false
    (Sys.file_exists (Paths.store_file_path stale Paths.Deletion));
  Alcotest.(check string) "refused parent deletion preserves comments" comments_before
    (Fs_compat.load_file comments_path);
  Board.flush_dirty stale;
  Alcotest.(check string) "retry flush preserves the failed parent's source" posts_before
    (Fs_compat.load_file posts_path);
  Alcotest.(check string) "retry flush retains the deletion dependency" comments_before
    (Fs_compat.load_file comments_path);
  let restarted = fresh_store base_path in
  Alcotest.(check string) "foreign accepted post survives recovery" foreign.body
    (require (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator
                ~post_id:(Board.Post_id.to_string foreign.id))).body;
  ignore (require (Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id)));
  (match Board.read_post_for_evidence restarted ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok kept -> Alcotest.(check string) "fresh initialization preserves unrecorded target" parent.body kept.body
   | Error error -> Alcotest.fail (Board.show_board_read_error error));
  (match require (Board.delete_post restarted ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Durable_deletion -> ()
   | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail);
  let after_explicit_request = fresh_store base_path in
  (match Board.read_post_for_evidence after_explicit_request ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Read_post_not_found _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_read_error error)
   | Ok _ -> Alcotest.fail "explicit authorized deletion was lost");
  match Board.get_comment after_explicit_request ~comment_id:(Board.Comment_id.to_string reply.id) with
  | Error (Board.Comment_not_found _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "original reply was not deleted with its parent"

let test_stale_comments_refuse_before_decision base_path =
  let stale = fresh_store base_path in
  let parent = post stale "parent deletion can land before a comments refusal" in
  let other = fresh_store base_path in
  let reply = comment other parent "another writer's accepted reply" in
  let comment_id = Board.Comment_id.to_string reply.id in
  ignore (require (Board.vote_comment other ~reader:Masc_board_handlers.Board_access.Operator ~comment_id ~voter:"foreign-voter" ~direction:Board.Up));
  ignore (require (Board.toggle_reaction other ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_comment
    ~target_id:comment_id ~user_id:"foreign-reactor" ~emoji:"👍"));
  let comments_path = Board.comments_path stale in
  let votes_path = Board.vote_log_path stale and reactions_path = Board.reactions_path stale in
  let preserved = List.map (fun path -> path, Fs_compat.load_file path)
      [comments_path; votes_path; reactions_path] in
  List.iter (fun (_, bytes) -> Alcotest.(check bool) "fixture has accepted dependent data" false
    (String.equal bytes "")) preserved;
  let posts_before = Fs_compat.load_file (Board.persist_path stale) in
  (match Board.delete_post stale ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id) with
   | Error (Board.Io_error _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "pre-decision foreign child was omitted from a deletion decision");
  let module Paths = Masc_board_handlers.Board_paths in
  Alcotest.(check bool) "stale comments guard records no decision" false
    (Sys.file_exists (Paths.store_file_path stale Paths.Deletion));
  Alcotest.(check string) "comments refusal preserves the parent source" posts_before
    (Fs_compat.load_file (Board.persist_path stale));
  List.iter (fun (path, bytes) -> Alcotest.(check string) "failed comments prerequisite preserves later sources"
    bytes (Fs_compat.load_file path)) preserved;
  Board.flush_dirty stale;
  List.iter (fun (path, bytes) -> Alcotest.(check string) "retry preserves foreign comments, votes and reactions"
    bytes (Fs_compat.load_file path)) preserved;
  let restarted = fresh_store base_path in
  (match Board.read_post_for_evidence restarted ~post_id:(Board.Post_id.to_string parent.id) with
   | Ok kept -> Alcotest.(check string) "restart preserves unrecorded parent" parent.body kept.body
   | Error error -> Alcotest.fail (Board.show_board_read_error error));
  Alcotest.(check bool) "foreign comment remains in its post index" true
    (match Hashtbl.find_opt restarted.comments_by_post (Board.Post_id.to_string parent.id) with
     | None -> false | Some ids -> List.mem comment_id ids);
  Alcotest.(check int) "preexisting child retains its accepted vote" 1
    (require (Board.get_comment restarted ~comment_id)).votes_up;
  let reactions = require (Board.list_reactions restarted ~target_type:Board.Reaction_comment
      ~target_id:comment_id ()) in
  Alcotest.(check bool) "preexisting child retains its accepted reaction" true
    (List.exists (fun (summary : Board.reaction_summary) ->
       String.equal summary.emoji "👍" && summary.count = 1) reactions);
  (match require (Board.delete_post restarted ~authorization:Board.Operator_deletion
      ~post_id:(Board.Post_id.to_string parent.id)) with
   | Board.Durable_deletion -> ()
   | Board.Deletion_decision_pending detail | Board.Deletion_persistence_pending detail -> Alcotest.fail detail);
  let after_explicit_request = fresh_store base_path in
  (match Board.get_comment after_explicit_request ~comment_id with
   | Error (Board.Comment_not_found _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "fresh explicit deletion omitted its preexisting child");
  Alcotest.(check int) "fresh explicit deletion removes its child vote" 0
    (Hashtbl.length after_explicit_request.vote_log);
  Alcotest.(check int) "fresh explicit deletion removes its child reaction" 0
    (Hashtbl.length after_explicit_request.reactions)

let test_reserved_parent_cleanup_retains_deletion_order base_path =
  let armed = ref false and lock_path = ref None and posts_path = ref None in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ -> ())
    ; close_fd = (fun fd ->
        let stat = Unix.fstat fd in
        let target = Option.map Unix.lstat !lock_path in
        Unix.close fd;
        match !armed, target with
        | true, Some lock when stat.Unix.st_dev = lock.Unix.st_dev
                               && stat.Unix.st_ino = lock.Unix.st_ino
                               && (match !posts_path with
                                   | None -> false
                                   | Some path -> String.equal ""
                                       (In_channel.with_open_bin path In_channel.input_all)) ->
          armed := false; raise Eio.Time.Timeout
        | false, (None | Some _) | true, None | true, Some _ -> ()) } in
  let stale = Board.create_store_with_source_io_for_testing ~base_path ~io:{ posts = Some io } () in
  List.iter (fun load -> match load stale with
    | Ok _ -> ()
    | Error (path, error) -> Alcotest.failf "load %s: %s" path (Printexc.to_string error))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments];
  ignore (require (Board.reload_votes stale));
  ignore (require (Board.reload_reactions stale));
  let parent = post stale "known parent deletion before reserved cleanup" in
  let reply = comment stale parent "pending dependent cleanup" in
  let comments_path = Board.comments_path stale in
  let comments_before = Fs_compat.load_file comments_path in
  lock_path := Some (Fs_compat.private_jsonl_lock_path (Board.persist_path stale));
  posts_path := Some (Board.persist_path stale);
  armed := true;
  (match Board.delete_post stale ~authorization:Board.Operator_deletion ~post_id:(Board.Post_id.to_string parent.id) with
   | _ -> Alcotest.fail "original reserved cleanup cause was swallowed"
   | exception Eio.Time.Timeout -> ());
  Alcotest.(check string) "parent publication is known before the cleanup exception" ""
    (Fs_compat.load_file (Board.persist_path stale));
  Alcotest.(check string) "reserved settlement defers dependent cleanup" comments_before
    (Fs_compat.load_file comments_path);
  Board.flush_dirty stale;
  Alcotest.(check string) "owned flush resumes dependent cleanup" ""
    (Fs_compat.load_file comments_path);
  let restarted = fresh_store base_path in
  match Board.get_comment restarted ~comment_id:(Board.Comment_id.to_string reply.id) with
  | Error (Board.Comment_not_found _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "original reply resurrected after recovery"

let () =
  Alcotest.run "board_delete_order"
    ["actual writers and retry",
      [Alcotest.test_case "stale parent refuses before decision and preserves files" `Quick
         (with_fixture test_refused_parent_preserves_comments_after_flush);
       Alcotest.test_case "pre-decision foreign child refuses stale deletion" `Quick
         (with_fixture test_stale_comments_refuse_before_decision);
       Alcotest.test_case "reserved parent cleanup retains deletion ordering" `Quick
         (with_fixture test_reserved_parent_cleanup_retains_deletion_order)]]
